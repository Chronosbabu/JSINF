from flask import Flask, request, jsonify
import json
import os
import re
import datetime
import secrets
import string
import logging
import sys

app = Flask(__name__)
DATA_DIR = "school_data"
os.makedirs(DATA_DIR, exist_ok=True)

KEYS_FILE            = os.path.join(DATA_DIR, "keys_store.json")
IDS_FILE             = os.path.join(DATA_DIR, "ids_store.json")
PENDING_FILE         = os.path.join(DATA_DIR, "pending_payments.json")
MOBILE_PAYMENTS_FILE = os.path.join(DATA_DIR, "mobile_payments.json")
SCHOOLS_FILE         = os.path.join(DATA_DIR, "schools_registry.json")

ADMIN_PASSWORD = "edupay_admin_2026"

AIRTEL_MERCHANT_ID  = os.environ.get('AIRTEL_MERCHANT_ID', '')
AIRTEL_API_KEY      = os.environ.get('AIRTEL_API_KEY', '')
ORANGE_MERCHANT_ID  = os.environ.get('ORANGE_MERCHANT_ID', '')
ORANGE_API_KEY      = os.environ.get('ORANGE_API_KEY', '')
VODACOM_MERCHANT_ID = os.environ.get('VODACOM_MERCHANT_ID', '')
VODACOM_API_KEY     = os.environ.get('VODACOM_API_KEY', '')

MONTHS = [
    'Septembre', 'Octobre', 'Novembre', 'Decembre',
    'Janvier', 'Fevrier', 'Mars', 'Avril', 'Mai', 'Juin'
]

# ====================================================================
# ⚡ NOUVEAU — CONFIGURATION DES LOGS
# ====================================================================
# On log sur stdout explicitement : c'est ce que Render capture et
# affiche dans l'onglet "Logs" de votre service, en temps réel.
# Format : [HEURE] NIVEAU nom_logger: message
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s %(name)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    stream=sys.stdout,
)
logger = logging.getLogger("edupay")

# ⚡ Log de démarrage : liste le contenu actuel de school_data/.
# Très utile pour diagnostiquer le problème de stockage éphémère :
# si ce log montre un dossier VIDE juste après un redémarrage alors
# que des écoles avaient été sauvegardées avant, c'est la preuve
# que les données ne survivent pas aux redémarrages du service.
def _log_startup_state():
    try:
        files = os.listdir(DATA_DIR)
        school_files = [
            f for f in files
            if f.endswith('.json') and f not in {
                'keys_store.json', 'ids_store.json',
                'pending_payments.json', 'mobile_payments.json',
                'schools_registry.json',
            }
        ]
        logger.info(
            "=== DEMARRAGE SERVEUR === DATA_DIR='%s' | %d fichier(s) école "
            "trouvé(s) au démarrage : %s",
            os.path.abspath(DATA_DIR), len(school_files), school_files,
        )
        if not school_files:
            logger.warning(
                "⚠️ Aucun fichier école trouvé au démarrage. Si vous aviez "
                "déjà des écoles sauvegardées avant ce redémarrage, cela "
                "confirme que le stockage local n'est PAS persistant "
                "(disque éphémère) et que les données ont été perdues."
            )
    except Exception as e:
        logger.error("Erreur lors du log de démarrage : %s", e)


_log_startup_state()


def _load_json(path, default):
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return default


def _save_json(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _generate_registration_id():
    chars  = string.ascii_uppercase + string.digits
    groups = [''.join(secrets.choice(chars) for _ in range(4))
              for _ in range(3)]
    return f"EDU-{'-'.join(groups)}"


def _generate_school_code(school_name):
    words   = school_name.strip().upper().split()
    base    = words[0][:8] if words else "SCHOOL"
    schools = _load_json(SCHOOLS_FILE, {})
    code    = base
    counter = 1
    while any(s.get('school_code') == code for s in schools.values()):
        code    = f"{base}{counter}"
        counter += 1
    return code


def _get_all_ids_except(school_code):
    all_ids = set()
    skip = {
        'keys_store.json', 'ids_store.json',
        'pending_payments.json', 'mobile_payments.json',
        'schools_registry.json',
    }
    for fname in os.listdir(DATA_DIR):
        if not fname.endswith('.json') or fname in skip:
            continue
        if fname == f"{school_code.lower()}.json":
            continue
        fpath = os.path.join(DATA_DIR, fname)
        try:
            with open(fpath, 'r', encoding='utf-8') as f:
                data = json.load(f)
            for yd in data.get('history', {}).values():
                for e in yd.get('eleves', []):
                    eid = e.get('id', '')
                    if eid:
                        all_ids.add(eid)
        except Exception:
            pass
    return all_ids


def _resolve_id_conflicts(school_code, backup_data):
    other_ids = _get_all_ids_except(school_code)
    if not other_ids:
        return backup_data, {}

    own_ids = set()
    for yd in backup_data.get('history', {}).values():
        for e in yd.get('eleves', []):
            eid = e.get('id', '')
            if eid:
                own_ids.add(eid)

    all_used    = other_ids | own_ids
    corrections = {}

    for yd in backup_data.get('history', {}).values():
        for e in yd.get('eleves', []):
            old_id = e.get('id', '')
            if not old_id or old_id not in other_ids:
                continue
            match = re.match(r'^(.*?)(\d+)$', old_id)
            base  = match.group(1) if match else old_id + '_'
            counter = 1
            new_id  = f"{base}{counter}"
            while new_id in all_used:
                counter += 1
                new_id  = f"{base}{counter}"
            corrections[old_id] = new_id
            e['id'] = new_id
            all_used.add(new_id)
            all_used.discard(old_id)

    if corrections:
        logger.info(
            "Conflits d'ID résolus pour l'école '%s' : %s",
            school_code, corrections,
        )

    return backup_data, corrections


def mobile_money_available():
    return bool(AIRTEL_API_KEY or ORANGE_API_KEY or VODACOM_API_KEY)


# ====================================================================
# DISTRIBUTION MULTI-MOIS (logique identique à handlePayment Flutter)
# ====================================================================
def _get_required_for_month(config, section, mois):
    """
    Résolution du montant requis pour un mois donné.
    Priorité : exception par section > frais par section > défaut 35000.
    """
    exceptions = config.get('monthlyExceptionsBySection', {}).get(section, {})
    if mois in exceptions:
        return float(exceptions[mois])
    fee = config.get('feesBySection', {}).get(section)
    if fee is not None:
        return float(fee)
    return 35000.0


def _distribute_payment(config, eleve, start_mois, total_amount):
    """
    Distribue un montant à travers les mois à partir de start_mois,
    exactement comme handlePayment() dans frais_scolaires.dart.
    Retourne une liste de {'mois': str, 'amount': float}.
    """
    index = MONTHS.index(start_mois) if start_mois in MONTHS else -1
    if index == -1:
        return []

    section   = eleve.get('section', '')
    paid_map  = eleve.get('paid', {})
    remaining = float(total_amount)
    entries   = []

    while remaining > 0 and index < len(MONTHS):
        current_month = MONTHS[index]
        required      = _get_required_for_month(config, section, current_month)
        already_paid  = float(paid_map.get(current_month, 0))
        needed        = required - already_paid

        if needed > 0:
            to_add    = min(remaining, needed)
            entries.append({'mois': current_month, 'amount': to_add})
            remaining -= to_add

        index += 1

    return entries


# ====================================================================
# ⚡ NOUVEAU — LOG DE CHAQUE REQUÊTE ENTRANTE
# ====================================================================
# Log générique avant chaque requête : méthode, chemin, IP d'origine.
# Permet de voir dans la console Render CHAQUE appel reçu, même ceux
# qui échouent avant d'atteindre la logique métier (utile pour
# vérifier si le PC arrive même à contacter le serveur).
@app.before_request
def _log_incoming_request():
    logger.info(
        "→ %s %s | IP=%s",
        request.method, request.path, request.remote_addr,
    )


# ====================================================================
# ENREGISTREMENT DES ÉCOLES
# ====================================================================

@app.route('/admin/register_school', methods=['POST'])
def admin_register_school():
    try:
        data = request.get_json()
        if data.get('admin_password') != ADMIN_PASSWORD:
            logger.warning("Tentative d'enregistrement école avec mauvais mot de passe admin")
            return jsonify({"error": "Mot de passe admin incorrect"}), 401

        school_name  = data.get('school_name', '').strip()
        city         = data.get('city', '').strip()
        director     = data.get('director', '').strip()
        phone        = data.get('phone', '').strip()
        email        = data.get('email', '').strip()
        address      = data.get('address', '').strip()
        bank_name    = data.get('bank_name', '').strip()
        bank_account = data.get('bank_account', '').strip()
        bank_branch  = data.get('bank_branch', '').strip()

        if not school_name or not city or not director:
            return jsonify({
                "error": "Nom, ville et directeur sont obligatoires"
            }), 400

        schools     = _load_json(SCHOOLS_FILE, {})
        school_code = _generate_school_code(school_name)
        reg_id      = _generate_registration_id()

        all_reg_ids = {s.get('registration_id') for s in schools.values()}
        while reg_id in all_reg_ids:
            reg_id = _generate_registration_id()

        schools[school_code] = {
            "school_code":     school_code,
            "school_name":     school_name,
            "city":            city,
            "address":         address,
            "director":        director,
            "phone":           phone,
            "email":           email,
            "bank_name":       bank_name,
            "bank_account":    bank_account,
            "bank_branch":     bank_branch,
            "registration_id": reg_id,
            "activated":       False,
            "registered_at":   datetime.datetime.now().isoformat(),
            "activated_at":    None,
        }
        _save_json(SCHOOLS_FILE, schools)

        logger.info(
            "✅ École enregistrée : code='%s' nom='%s' registration_id='%s'",
            school_code, school_name, reg_id,
        )

        return jsonify({
            "message":         "École enregistrée avec succès",
            "school_code":     school_code,
            "school_name":     school_name,
            "registration_id": reg_id,
        }), 200
    except Exception as e:
        logger.exception("Erreur admin_register_school")
        return jsonify({"error": str(e)}), 500


@app.route('/school/verify_registration_id', methods=['POST'])
def verify_registration_id():
    try:
        data   = request.get_json()
        reg_id = data.get('registration_id', '').strip().upper()
        if not reg_id:
            return jsonify({"valid": False, "error": "ID manquant"}), 400

        schools = _load_json(SCHOOLS_FILE, {})
        for school_code, school in schools.items():
            if school.get('registration_id', '').upper() == reg_id:
                if school.get('activated'):
                    logger.info(
                        "verify_registration_id : reg_id='%s' déjà utilisé (code='%s')",
                        reg_id, school_code,
                    )
                    return jsonify({
                        "valid":       False,
                        "already_used": True,
                        "school_code": school_code,
                        "school_name": school.get('school_name'),
                        "error":       "Cet ID a déjà été utilisé.",
                    }), 200
                logger.info(
                    "verify_registration_id : reg_id='%s' valide (code='%s')",
                    reg_id, school_code,
                )
                return jsonify({
                    "valid":        True,
                    "school_code":  school_code,
                    "school_name":  school.get('school_name'),
                    "city":         school.get('city'),
                    "director":     school.get('director'),
                    "phone":        school.get('phone'),
                    "bank_name":    school.get('bank_name'),
                    "bank_account": school.get('bank_account'),
                }), 200

        logger.warning("verify_registration_id : reg_id='%s' introuvable", reg_id)
        return jsonify({
            "valid": False,
            "error": "ID invalide. Vérifiez auprès de l'administrateur EduPay.",
        }), 200
    except Exception as e:
        logger.exception("Erreur verify_registration_id")
        return jsonify({"error": str(e)}), 500


@app.route('/school/get_info_by_reg_id', methods=['POST'])
def get_info_by_reg_id():
    """
    ⚡ NOUVEAU — Retourne le vrai school_code d'une école à partir
    de son registration_id, même si elle est déjà activée.
    Utilisé par recovery_screen.dart pour corriger le bug du login
    sur Windows (l'ID de registration était utilisé comme school_code).
    """
    try:
        data   = request.get_json()
        reg_id = data.get('registration_id', '').strip().upper()
        if not reg_id:
            return jsonify({"found": False}), 400

        schools = _load_json(SCHOOLS_FILE, {})
        for school_code, school in schools.items():
            if school.get('registration_id', '').upper() == reg_id:
                logger.info(
                    "get_info_by_reg_id : reg_id='%s' → code='%s'",
                    reg_id, school_code,
                )
                return jsonify({
                    "found":        True,
                    "school_code":  school_code,
                    "school_name":  school.get('school_name'),
                    "activated":    school.get('activated', False),
                }), 200

        logger.warning("get_info_by_reg_id : reg_id='%s' introuvable", reg_id)
        return jsonify({"found": False}), 404
    except Exception as e:
        logger.exception("Erreur get_info_by_reg_id")
        return jsonify({"error": str(e)}), 500


@app.route('/school/activate', methods=['POST'])
def activate_school():
    try:
        data     = request.get_json()
        reg_id   = data.get('registration_id', '').strip().upper()
        password = data.get('password', '').strip()

        if not reg_id or not password:
            return jsonify({"error": "Données manquantes"}), 400

        schools     = _load_json(SCHOOLS_FILE, {})
        target_code = None
        for sc, school in schools.items():
            if school.get('registration_id', '').upper() == reg_id:
                if school.get('activated'):
                    logger.warning(
                        "activate_school : reg_id='%s' déjà activé (code='%s')",
                        reg_id, sc,
                    )
                    return jsonify({"error": "Cet ID a déjà été utilisé."}), 400
                target_code = sc
                break

        if not target_code:
            logger.warning("activate_school : reg_id='%s' invalide", reg_id)
            return jsonify({"error": "ID invalide"}), 404

        schools[target_code]['activated']    = True
        schools[target_code]['activated_at'] = datetime.datetime.now().isoformat()
        _save_json(SCHOOLS_FILE, schools)

        school_info = schools[target_code]
        final_name  = school_info.get('school_name', '')
        filepath    = os.path.join(DATA_DIR, f"{target_code.lower()}.json")

        if not os.path.exists(filepath):
            initial_data = {
                "config": {
                    "schoolName":                 final_name,
                    "sections":                   ["Maternelle", "Primaire", "Secondaire"],
                    "feesBySection":              {},
                    "feesByClasse":               {},
                    "monthlyExceptionsBySection": {},
                    "monthlyExceptionsByClasse":  {},
                    "classesBySection":           {},
                    "subClassesByClasse":         {},
                    "administrations":            [],
                    "bankName":                   school_info.get('bank_name', ''),
                    "bankAccount":                school_info.get('bank_account', ''),
                    "bankBranch":                 school_info.get('bank_branch', ''),
                    "city":                       school_info.get('city', ''),
                    "director":                   school_info.get('director', ''),
                    "phone":                      school_info.get('phone', ''),
                    "email":                      school_info.get('email', ''),
                },
                "currentYear":    "2025-2026",
                "localIdCounter": 0,
                "history": {"2025-2026": {"eleves": []}},
                "backup_password": password,
            }
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(initial_data, f, ensure_ascii=False, indent=2)
            logger.info(
                "✅ École activée + fichier initial créé : code='%s' nom='%s' path='%s'",
                target_code, final_name, filepath,
            )
        else:
            logger.info(
                "✅ École activée (fichier déjà existant) : code='%s' nom='%s'",
                target_code, final_name,
            )

        return jsonify({
            "message":     "Compte activé avec succès. Bienvenue sur EduPay !",
            "school_code": target_code,
            "school_name": final_name,
        }), 200
    except Exception as e:
        logger.exception("Erreur activate_school")
        return jsonify({"error": str(e)}), 500


@app.route('/admin/list_schools', methods=['POST'])
def list_schools():
    try:
        data = request.get_json()
        if data.get('admin_password') != ADMIN_PASSWORD:
            return jsonify({"error": "Accès refusé"}), 401
        schools = _load_json(SCHOOLS_FILE, {})
        summary = [{
            "school_code":   sc,
            "school_name":   s.get('school_name'),
            "city":          s.get('city'),
            "director":      s.get('director'),
            "activated":     s.get('activated', False),
            "registered_at": s.get('registered_at'),
            "activated_at":  s.get('activated_at'),
        } for sc, s in schools.items()]
        logger.info("list_schools : %d école(s) enregistrée(s)", len(summary))
        return jsonify({"schools": summary, "total": len(summary)}), 200
    except Exception as e:
        logger.exception("Erreur list_schools")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# BACKUP / RESTORE
# ====================================================================

@app.route('/backup', methods=['POST'])
def backup():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        backup_data = data.get('data')
        if not school_code or not backup_data:
            logger.warning("backup : données invalides reçues (school_code ou data manquant)")
            return jsonify({"error": "Données invalides"}), 400

        # ⚡ Compte le nombre total d'élèves envoyés, toutes années confondues
        nb_eleves = sum(
            len(yd.get('eleves', []))
            for yd in backup_data.get('history', {}).values()
        )
        logger.info(
            "📥 BACKUP reçu : école='%s' | %d élève(s) | années=%s",
            school_code, nb_eleves, list(backup_data.get('history', {}).keys()),
        )

        corrected_data, corrections = _resolve_id_conflicts(
            school_code, backup_data)

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(corrected_data, f, ensure_ascii=False, indent=2)

        # ⚡ Vérification immédiate que le fichier a bien été écrit sur disque
        file_size = os.path.getsize(filepath) if os.path.exists(filepath) else 0
        logger.info(
            "✅ BACKUP écrit avec succès : école='%s' path='%s' taille=%d octets "
            "| %d correction(s) d'ID",
            school_code, filepath, file_size, len(corrections),
        )

        return jsonify({
            "message":     "Sauvegarde réussie",
            "school_code": school_code,
            "corrections": corrections,
        }), 200
    except Exception as e:
        logger.exception("❌ Erreur lors du BACKUP pour école='%s'", request.get_json(silent=True) or {})
        return jsonify({"error": str(e)}), 500


@app.route('/restore', methods=['GET'])
def restore():
    school_code = request.args.get('school_code')
    if not school_code:
        logger.warning("restore : code manquant")
        return jsonify({"error": "Code manquant"}), 400
    filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
    if os.path.exists(filepath):
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        nb_eleves = sum(
            len(yd.get('eleves', []))
            for yd in data.get('history', {}).values()
        )
        logger.info(
            "📤 RESTORE : école='%s' trouvée | %d élève(s)",
            school_code, nb_eleves,
        )
        data.pop('backup_password', None)
        return jsonify(data), 200
    logger.warning(
        "❌ RESTORE : aucune sauvegarde trouvée pour école='%s' (fichier attendu : '%s')",
        school_code, filepath,
    )
    return jsonify({"error": "Aucune sauvegarde trouvée"}), 404


# ====================================================================
# PAIEMENTS EN ATTENTE (sous-utilisateur)
# ====================================================================

@app.route('/record_payment', methods=['POST'])
def record_payment():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        annee       = data.get('annee')
        eleve_id    = data.get('eleve_id')
        mois        = data.get('mois')
        amount      = data.get('amount')

        if not all([school_code, annee, eleve_id, mois]) or amount is None:
            return jsonify({"error": "Données manquantes"}), 400

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            logger.warning("record_payment : école introuvable code='%s'", school_code)
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)

        year_data = saved.get('history', {}).get(annee)
        if not year_data:
            return jsonify({"error": "Année introuvable"}), 404

        eleve = next(
            (e for e in year_data.get('eleves', [])
             if e.get('id') == eleve_id), None)
        if eleve is None:
            return jsonify({"error": "Élève introuvable"}), 404

        pending_store = _load_json(PENDING_FILE, {})
        school_key    = school_code.lower()
        pending_list  = pending_store.get(school_key, [])

        payment_id = (
            f"pay_{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"
            f"_{os.urandom(3).hex()}"
        )
        pending_list.append({
            "id":       payment_id,
            "eleve_id": eleve_id,
            "annee":    annee,
            "nom":      eleve.get('nom', ''),
            "postNom":  eleve.get('postNom', ''),
            "prenom":   eleve.get('prenom', ''),
            "section":  eleve.get('section', ''),
            "classe":   eleve.get('classe', ''),
            "mois":     mois,
            "amount":   amount,
            "date":     datetime.date.today().isoformat(),
        })
        pending_store[school_key] = pending_list
        _save_json(PENDING_FILE, pending_store)

        logger.info(
            "💰 record_payment : école='%s' élève='%s' mois='%s' montant=%s → pending_id='%s'",
            school_code, eleve_id, mois, amount, payment_id,
        )

        return jsonify({
            "message":    "Paiement reçu, en attente de validation",
            "pending_id": payment_id
        }), 200
    except Exception as e:
        logger.exception("Erreur record_payment")
        return jsonify({"error": str(e)}), 500


@app.route('/get_pending_payments', methods=['GET'])
def get_pending_payments():
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        pending_store = _load_json(PENDING_FILE, {})
        pending_list  = pending_store.get(school_code.lower(), [])
        logger.info(
            "get_pending_payments : école='%s' → %d en attente",
            school_code, len(pending_list),
        )
        return jsonify({"pending_payments": pending_list}), 200
    except Exception as e:
        logger.exception("Erreur get_pending_payments")
        return jsonify({"error": str(e)}), 500


@app.route('/validate_payments', methods=['POST'])
def validate_payments():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        payment_ids = data.get('payment_ids')

        if not school_code:
            return jsonify({"error": "Code manquant"}), 400

        school_key = school_code.lower()
        filepath   = os.path.join(DATA_DIR, f"{school_key}.json")
        if not os.path.exists(filepath):
            logger.warning("validate_payments : école introuvable code='%s'", school_code)
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)
        history = saved.get('history', {})

        pending_store = _load_json(PENDING_FILE, {})
        pending_list  = pending_store.get(school_key, [])

        if payment_ids:
            to_validate = [p for p in pending_list if p.get('id') in payment_ids]
            remaining   = [p for p in pending_list if p.get('id') not in payment_ids]
        else:
            to_validate = pending_list
            remaining   = []

        validated_count = 0
        for entry in to_validate:
            year_data = history.get(entry.get('annee'))
            if not year_data:
                continue
            eleve = next(
                (e for e in year_data.get('eleves', [])
                 if e.get('id') == entry.get('eleve_id')), None)
            if not eleve:
                continue
            eleve.setdefault('paid', {})
            eleve['paid'][entry['mois']] = (
                eleve['paid'].get(entry['mois'], 0) + entry['amount'])
            eleve.setdefault('transactions', [])
            eleve['transactions'].append({
                'date':         entry.get('date'),
                'mois':         entry['mois'],
                'amount':       entry['amount'],
                'from_subuser': True,
                'validated':    True,
            })
            validated_count += 1

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(saved, f, ensure_ascii=False, indent=2)

        pending_store[school_key] = remaining
        _save_json(PENDING_FILE, pending_store)

        logger.info(
            "✅ validate_payments : école='%s' | %d validé(s) | %d restant(s)",
            school_code, validated_count, len(remaining),
        )

        return jsonify({
            "message":           "Paiements validés",
            "validated_count":   validated_count,
            "remaining_pending": len(remaining),
        }), 200
    except Exception as e:
        logger.exception("Erreur validate_payments")
        return jsonify({"error": str(e)}), 500


@app.route('/reject_payment', methods=['POST'])
def reject_payment():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        payment_id  = data.get('payment_id')
        if not school_code or not payment_id:
            return jsonify({"error": "Données manquantes"}), 400

        school_key    = school_code.lower()
        pending_store = _load_json(PENDING_FILE, {})
        pending_list  = pending_store.get(school_key, [])
        pending_list  = [p for p in pending_list if p.get('id') != payment_id]
        pending_store[school_key] = pending_list
        _save_json(PENDING_FILE, pending_store)
        logger.info("reject_payment : école='%s' payment_id='%s' rejeté", school_code, payment_id)
        return jsonify({"message": "Paiement rejeté"}), 200
    except Exception as e:
        logger.exception("Erreur reject_payment")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# PAIEMENTS MOBILE MONEY (parent) — AVEC DISTRIBUTION MULTI-MOIS
# ====================================================================

@app.route('/payment/status', methods=['GET'])
def payment_status():
    return jsonify({
        "mobile_money_available": mobile_money_available(),
        "networks_available": {
            "airtel":  bool(AIRTEL_API_KEY),
            "orange":  bool(ORANGE_API_KEY),
            "vodacom": bool(VODACOM_API_KEY),
        }
    }), 200


@app.route('/parent/find_student', methods=['GET'])
def parent_find_student():
    try:
        student_id = request.args.get('student_id', '').strip().upper()
        if not student_id:
            logger.warning("parent_find_student : ID manquant dans la requête")
            return jsonify({"found": False, "error": "ID manquant"}), 400

        logger.info("👨‍👩‍👧 parent_find_student : recherche de l'ID '%s'", student_id)

        skip = {
            'keys_store.json', 'ids_store.json',
            'pending_payments.json', 'mobile_payments.json',
            'schools_registry.json',
        }
        fichiers_ecoles = [
            f for f in os.listdir(DATA_DIR)
            if f.endswith('.json') and f not in skip
        ]
        logger.info(
            "parent_find_student : %d fichier(s) école à scanner : %s",
            len(fichiers_ecoles), fichiers_ecoles,
        )

        for fname in fichiers_ecoles:
            fpath = os.path.join(DATA_DIR, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    data = json.load(f)
            except Exception as e:
                logger.error("parent_find_student : impossible de lire '%s' : %s", fpath, e)
                continue

            school_code  = fname.replace('.json', '').upper()
            school_name  = data.get('config', {}).get('schoolName', school_code)
            current_year = data.get('currentYear', '')
            config       = data.get('config', {})

            for yd in data.get('history', {}).values():
                for e in yd.get('eleves', []):
                    if e.get('id', '').upper() == student_id:
                        logger.info(
                            "✅ parent_find_student : ID '%s' TROUVÉ dans école='%s' (%s)",
                            student_id, school_code, school_name,
                        )
                        return jsonify({
                            "found":   True,
                            "student": {
                                "id":      e.get('id'),
                                "nom":     e.get('nom', ''),
                                "postNom": e.get('postNom', ''),
                                "prenom":  e.get('prenom', ''),
                                "classe":  e.get('classe', ''),
                                "section": e.get('section', ''),
                            },
                            "school_code":  school_code,
                            "school_name":  school_name,
                            "current_year": current_year,
                            "config": {
                                "feesBySection":
                                    config.get('feesBySection', {}),
                                "monthlyExceptionsBySection":
                                    config.get('monthlyExceptionsBySection', {}),
                            }
                        }), 200

        logger.warning(
            "❌ parent_find_student : ID '%s' INTROUVABLE dans les %d fichier(s) scanné(s)",
            student_id, len(fichiers_ecoles),
        )
        return jsonify({
            "found": False,
            "error": "Aucun élève trouvé avec cet ID"
        }), 404
    except Exception as e:
        logger.exception("Erreur parent_find_student")
        return jsonify({"error": str(e)}), 500


@app.route('/parent/get_payment_history', methods=['GET'])
def parent_get_payment_history():
    try:
        student_id  = request.args.get('student_id', '').strip().upper()
        school_code = request.args.get('school_code', '').strip()
        if not student_id or not school_code:
            return jsonify({"error": "Paramètres manquants"}), 400

        logger.info(
            "parent_get_payment_history : élève='%s' école='%s'",
            student_id, school_code,
        )

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            logger.warning(
                "parent_get_payment_history : école introuvable code='%s' (path='%s')",
                school_code, filepath,
            )
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)

        config       = data.get('config', {})
        current_year = data.get('currentYear', '')
        year_data    = data.get('history', {}).get(current_year, {})

        for e in year_data.get('eleves', []):
            if e.get('id', '').upper() == student_id:
                logger.info(
                    "✅ parent_get_payment_history : historique trouvé pour élève='%s'",
                    student_id,
                )
                return jsonify({
                    "paid":               e.get('paid', {}),
                    "transactions":       e.get('transactions', []),
                    "fees_by_section":    config.get('feesBySection', {}),
                    "monthly_exceptions": config.get('monthlyExceptionsBySection', {}),
                    "fees_by_classe":     config.get('feesByClasse', {}),
                    "current_year":       current_year,
                }), 200

        logger.warning(
            "❌ parent_get_payment_history : élève='%s' introuvable dans école='%s'",
            student_id, school_code,
        )
        return jsonify({"error": "Élève introuvable"}), 404
    except Exception as e:
        logger.exception("Erreur parent_get_payment_history")
        return jsonify({"error": str(e)}), 500


@app.route('/parent/preview_payment', methods=['POST'])
def parent_preview_payment():
    """
    ⚡ NOUVEAU — Calcule et retourne la distribution multi-mois
    avant que le parent confirme son paiement.
    Le parent voit exactement quels mois seront couverts.
    """
    try:
        data        = request.get_json()
        student_id  = data.get('student_id', '').strip().upper()
        school_code = data.get('school_code', '').strip()
        start_mois  = data.get('start_mois', '')
        amount      = float(data.get('amount', 0))

        if not all([student_id, school_code, start_mois]) or amount <= 0:
            return jsonify({"error": "Données manquantes"}), 400

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)

        config       = saved.get('config', {})
        current_year = saved.get('currentYear', '')
        year_data    = saved.get('history', {}).get(current_year, {})

        eleve = next(
            (e for e in year_data.get('eleves', [])
             if e.get('id', '').upper() == student_id), None)
        if eleve is None:
            return jsonify({"error": "Élève introuvable"}), 404

        distribution = _distribute_payment(config, eleve, start_mois, amount)
        total_covered = sum(d['amount'] for d in distribution)
        remainder     = amount - total_covered  # montant non utilisé (excédent)

        logger.info(
            "parent_preview_payment : élève='%s' montant=%s → %d mois couverts",
            student_id, amount, len(distribution),
        )

        return jsonify({
            "distribution": distribution,
            "total_covered": total_covered,
            "remainder":     max(0.0, remainder),
        }), 200
    except Exception as e:
        logger.exception("Erreur parent_preview_payment")
        return jsonify({"error": str(e)}), 500


@app.route('/parent/submit_mobile_payment', methods=['POST'])
def parent_submit_mobile_payment():
    """
    ⚡ CORRIGÉ — Accepte maintenant soit un seul mois, soit une liste
    de month_entries (distribution multi-mois calculée côté client).
    Crée une entrée en attente par mois couvert.
    """
    try:
        data = request.get_json()
        return _store_pending_mobile_payment(data)
    except Exception as e:
        logger.exception("Erreur parent_submit_mobile_payment")
        return jsonify({"error": str(e)}), 500


def _store_pending_mobile_payment(data):
    """
    ⚡ CORRIGÉ — Gère la distribution multi-mois.

    Le client peut envoyer :
    - Cas A (ancien) : mois + amount → on distribue automatiquement
    - Cas B (nouveau) : month_entries = [{'mois': ..., 'amount': ...}, ...]
    """
    try:
        student_id    = data.get('student_id', '').strip().upper()
        school_code   = data.get('school_code', '').strip()
        network       = data.get('network', '')
        parent_name   = data.get('parent_name', 'Parent')
        month_entries = data.get('month_entries')  # Cas B : liste pré-calculée
        start_mois    = data.get('mois')           # Cas A : mois de départ
        total_amount  = data.get('amount', 0)

        logger.info(
            "💳 submit_mobile_payment : élève='%s' école='%s' réseau='%s'",
            student_id, school_code, network,
        )

        if not student_id or not school_code:
            return jsonify({"error": "Données manquantes"}), 400

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            logger.warning(
                "submit_mobile_payment : école introuvable code='%s'", school_code,
            )
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)

        config       = saved.get('config', {})
        current_year = saved.get('currentYear', '')
        year_data    = saved.get('history', {}).get(current_year, {})

        eleve = next(
            (e for e in year_data.get('eleves', [])
             if e.get('id', '').upper() == student_id), None)
        if eleve is None:
            logger.warning(
                "submit_mobile_payment : élève='%s' introuvable dans école='%s'",
                student_id, school_code,
            )
            return jsonify({"error": "Élève introuvable"}), 404

        # Cas A : calculer la distribution si pas déjà fournie
        if not month_entries:
            if not start_mois or not total_amount:
                return jsonify({"error": "Mois et montant requis"}), 400
            month_entries = _distribute_payment(
                config, eleve, start_mois, float(total_amount))

        if not month_entries:
            return jsonify({
                "error": "Aucune distribution possible "
                         "(mois déjà payés ou montant nul)"
            }), 400

        mobile_store  = _load_json(MOBILE_PAYMENTS_FILE, {})
        school_key    = school_code.lower()
        mobile_list   = mobile_store.get(school_key, [])
        today         = datetime.date.today().isoformat()
        created_ids   = []

        # Créer UNE entrée par mois couvert
        for entry in month_entries:
            payment_id = (
                f"mob_{datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')}"
                f"_{os.urandom(3).hex()}"
            )
            mobile_list.append({
                "id":          payment_id,
                "type":        "mobile_money",
                "eleve_id":    student_id,
                "annee":       current_year,
                "nom":         eleve.get('nom', ''),
                "postNom":     eleve.get('postNom', ''),
                "prenom":      eleve.get('prenom', ''),
                "section":     eleve.get('section', ''),
                "classe":      eleve.get('classe', ''),
                "mois":        entry['mois'],
                "amount":      entry['amount'],
                "network":     network,
                "parent_name": parent_name,
                "date":        today,
                "status":      "pending",
                "mode":        "manual",
            })
            created_ids.append(payment_id)

        mobile_store[school_key] = mobile_list
        _save_json(MOBILE_PAYMENTS_FILE, mobile_store)

        total_sent = sum(e['amount'] for e in month_entries)
        logger.info(
            "✅ submit_mobile_payment : élève='%s' | %d mois créés | total=%s",
            student_id, len(month_entries), total_sent,
        )
        return jsonify({
            "success":       True,
            "mode":          "manual",
            "message":       "Demande envoyée. En attente de confirmation par l'école.",
            "months_covered": len(month_entries),
            "total_sent":    total_sent,
            "payment_ids":   created_ids,
        }), 200

    except Exception as e:
        logger.exception("Erreur _store_pending_mobile_payment")
        return jsonify({"error": str(e)}), 500


@app.route('/get_mobile_payments', methods=['GET'])
def get_mobile_payments():
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        mobile_store = _load_json(MOBILE_PAYMENTS_FILE, {})
        mobile_list  = mobile_store.get(school_code.lower(), [])
        logger.info(
            "get_mobile_payments : école='%s' → %d paiement(s) mobile en attente",
            school_code, len(mobile_list),
        )
        return jsonify({
            "mobile_payments": mobile_list,
            "count":           len(mobile_list)
        }), 200
    except Exception as e:
        logger.exception("Erreur get_mobile_payments")
        return jsonify({"error": str(e)}), 500


@app.route('/confirm_mobile_payments', methods=['POST'])
def confirm_mobile_payments():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        payment_ids = data.get('payment_ids')

        if not school_code:
            return jsonify({"error": "Code manquant"}), 400

        school_key = school_code.lower()
        filepath   = os.path.join(DATA_DIR, f"{school_key}.json")
        if not os.path.exists(filepath):
            logger.warning("confirm_mobile_payments : école introuvable code='%s'", school_code)
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)
        history = saved.get('history', {})

        mobile_store = _load_json(MOBILE_PAYMENTS_FILE, {})
        mobile_list  = mobile_store.get(school_key, [])

        if payment_ids:
            to_confirm = [p for p in mobile_list if p.get('id') in payment_ids]
            remaining  = [p for p in mobile_list if p.get('id') not in payment_ids]
        else:
            to_confirm = mobile_list
            remaining  = []

        confirmed_count = 0
        for entry in to_confirm:
            year_data = history.get(entry.get('annee'))
            if not year_data:
                continue
            eleve = next(
                (e for e in year_data.get('eleves', [])
                 if e.get('id', '').upper() == str(
                     entry.get('eleve_id', '')).upper()), None)
            if not eleve:
                continue
            eleve.setdefault('paid', {})
            eleve['paid'][entry['mois']] = (
                eleve['paid'].get(entry['mois'], 0) + entry['amount'])
            eleve.setdefault('transactions', [])
            eleve['transactions'].append({
                'date':        entry.get('date'),
                'mois':        entry['mois'],
                'amount':      entry['amount'],
                'network':     entry.get('network', ''),
                'from_parent': True,
                'validated':   True,
            })
            confirmed_count += 1

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(saved, f, ensure_ascii=False, indent=2)

        mobile_store[school_key] = remaining
        _save_json(MOBILE_PAYMENTS_FILE, mobile_store)

        logger.info(
            "✅ confirm_mobile_payments : école='%s' | %d confirmé(s) | %d restant(s)",
            school_code, confirmed_count, len(remaining),
        )

        return jsonify({
            "message":         "Paiements confirmés",
            "confirmed_count": confirmed_count,
            "remaining":       len(remaining),
        }), 200
    except Exception as e:
        logger.exception("Erreur confirm_mobile_payments")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# WEBHOOKS (à remplir quand les APIs arrivent)
# ====================================================================

@app.route('/webhook/airtel', methods=['POST'])
def webhook_airtel():
    data = request.get_json()
    logger.info("webhook_airtel reçu : status='%s'", data.get('status'))
    if data.get('status') != 'SUCCESS':
        return jsonify({"ok": True}), 200
    ref   = data.get('transaction', {}).get('id', '')
    parts = ref.replace('EDU_', '').split('_')
    if len(parts) >= 2:
        _auto_confirm_payment(
            parts[0], parts[1],
            float(data.get('transaction', {}).get('amount', 0)),
            'airtel'
        )
    return jsonify({"ok": True}), 200


@app.route('/webhook/orange', methods=['POST'])
def webhook_orange():
    return jsonify({"ok": True}), 200


@app.route('/webhook/vodacom', methods=['POST'])
def webhook_vodacom():
    return jsonify({"ok": True}), 200


def _auto_confirm_payment(eleve_id, mois, amount, network):
    skip = {
        'keys_store.json', 'ids_store.json',
        'pending_payments.json', 'mobile_payments.json',
        'schools_registry.json',
    }
    for fname in os.listdir(DATA_DIR):
        if not fname.endswith('.json') or fname in skip:
            continue
        fpath = os.path.join(DATA_DIR, fname)
        try:
            with open(fpath, 'r', encoding='utf-8') as f:
                saved = json.load(f)
        except Exception:
            continue

        current_year = saved.get('currentYear', '')
        year_data    = saved.get('history', {}).get(current_year, {})

        for e in year_data.get('eleves', []):
            if e.get('id', '').upper() != eleve_id.upper():
                continue
            e.setdefault('paid', {})
            e['paid'][mois] = e['paid'].get(mois, 0) + amount
            e.setdefault('transactions', [])
            e['transactions'].append({
                'date':        datetime.date.today().isoformat(),
                'mois':        mois,
                'amount':      amount,
                'network':     network,
                'from_parent': True,
                'validated':   True,
                'auto':        True,
            })
            with open(fpath, 'w', encoding='utf-8') as f:
                json.dump(saved, f, ensure_ascii=False, indent=2)
            logger.info(
                "✅ _auto_confirm_payment : élève='%s' mois='%s' montant=%s (réseau=%s)",
                eleve_id, mois, amount, network,
            )
            return


# ====================================================================
# AUTRES ROUTES
# ====================================================================

@app.route('/verify_password', methods=['POST'])
def verify_password():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        password    = data.get('password')
        if not school_code or not password:
            return jsonify({"error": "Données manquantes"}), 400
        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if os.path.exists(filepath):
            with open(filepath, 'r', encoding='utf-8') as f:
                saved_data = json.load(f)
            if saved_data.get('backup_password') == password:
                return jsonify({"valid": True}), 200
            logger.warning("verify_password : mot de passe incorrect pour école='%s'", school_code)
            return jsonify({
                "valid": False, "error": "Mot de passe incorrect"
            }), 401
        logger.warning("verify_password : aucune sauvegarde pour école='%s'", school_code)
        return jsonify({"error": "Aucune sauvegarde trouvée"}), 404
    except Exception as e:
        logger.exception("Erreur verify_password")
        return jsonify({"error": str(e)}), 500


@app.route('/generate_key', methods=['POST'])
def generate_key():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        section     = data.get('section')
        if not school_code or not section:
            return jsonify({"error": "Données manquantes"}), 400
        key  = (
            f"{school_code.upper()}*{section.upper()[:3]}"
            f"*{os.urandom(4).hex()}"
        )
        keys      = _load_json(KEYS_FILE, {})
        keys[key] = {"school_code": school_code, "section": section}
        _save_json(KEYS_FILE, keys)
        logger.info(
            "🔑 generate_key : école='%s' section='%s' → clé générée",
            school_code, section,
        )
        return jsonify({"key": key, "section": section}), 200
    except Exception as e:
        logger.exception("Erreur generate_key")
        return jsonify({"error": str(e)}), 500


@app.route('/verify_key', methods=['POST'])
def verify_key():
    try:
        data = request.get_json()
        key  = data.get('key')
        if not key:
            return jsonify({"valid": False, "error": "Clé manquante"}), 400
        keys = _load_json(KEYS_FILE, {})
        info = keys.get(key)
        if not info:
            logger.warning("verify_key : clé invalide/introuvable")
            return jsonify({"valid": False, "error": "Clé invalide"}), 404
        school_code  = info["school_code"]
        filepath     = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        school_name  = school_code
        current_year = None
        if os.path.exists(filepath):
            with open(filepath, 'r', encoding='utf-8') as f:
                saved = json.load(f)
            school_name  = saved.get('config', {}).get('schoolName', school_code)
            current_year = saved.get('currentYear')
        logger.info("verify_key : clé valide pour école='%s' section='%s'", school_code, info["section"])
        return jsonify({
            "valid":        True,
            "school_code":  school_code,
            "section":      info["section"],
            "school_name":  school_name,
            "current_year": current_year,
        }), 200
    except Exception as e:
        logger.exception("Erreur verify_key")
        return jsonify({"error": str(e)}), 500


@app.route('/revoke_key', methods=['POST'])
def revoke_key():
    try:
        data = request.get_json()
        key  = data.get('key')
        if not key:
            return jsonify({"error": "Clé manquante"}), 400
        keys = _load_json(KEYS_FILE, {})
        if key in keys:
            del keys[key]
            _save_json(KEYS_FILE, keys)
            logger.info("revoke_key : clé révoquée")
        return jsonify({"message": "Clé révoquée"}), 200
    except Exception as e:
        logger.exception("Erreur revoke_key")
        return jsonify({"error": str(e)}), 500


@app.route('/generate_student_id', methods=['POST'])
def generate_student_id():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        nom         = data.get('nom', '')
        year        = data.get('year', '2025-2026')
        proposed_id = data.get('proposed_id')

        if not school_code or not nom:
            return jsonify({"error": "Données manquantes"}), 400

        ids_store = _load_json(IDS_FILE, {})
        used_ids  = set(ids_store.get(school_code.lower(), []))

        if proposed_id and proposed_id not in used_ids:
            candidate = proposed_id
        else:
            school_name   = data.get('school_name', '')
            year_short    = year[-2:] if len(year) >= 2 else "26"
            school_letter = school_name[0].upper() if school_name else "B"
            name_prefix   = nom.strip()[:2].upper() if nom.strip() else "XX"
            base_id       = f"{name_prefix}{year_short}{school_letter}"
            counter       = 1
            candidate     = f"{base_id}{counter}"
            while candidate in used_ids:
                counter  += 1
                candidate = f"{base_id}{counter}"

        used_ids.add(candidate)
        ids_store[school_code.lower()] = list(used_ids)
        _save_json(IDS_FILE, ids_store)
        logger.info("generate_student_id : école='%s' → id='%s'", school_code, candidate)
        return jsonify({"id": candidate}), 200
    except Exception as e:
        logger.exception("Erreur generate_student_id")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# ⚡ NOUVEAU — ROUTE DE DIAGNOSTIC
# ====================================================================
# Permet de vérifier en un coup d'œil (navigateur ou Postman) l'état
# actuel du stockage : combien d'écoles sont présentes MAINTENANT sur
# le disque du serveur, sans exposer les données sensibles.
# Utile pour confirmer si les données survivent à un redémarrage :
# notez le résultat, attendez 20-30 min sans requête, puis rappelez
# cette route et comparez.
@app.route('/admin/health', methods=['GET'])
def admin_health():
    try:
        skip = {
            'keys_store.json', 'ids_store.json',
            'pending_payments.json', 'mobile_payments.json',
            'schools_registry.json',
        }
        fichiers_ecoles = [
            f for f in os.listdir(DATA_DIR)
            if f.endswith('.json') and f not in skip
        ]
        details = []
        for fname in fichiers_ecoles:
            fpath = os.path.join(DATA_DIR, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    d = json.load(f)
                nb_eleves = sum(
                    len(yd.get('eleves', []))
                    for yd in d.get('history', {}).values()
                )
                details.append({
                    "school_code": fname.replace('.json', '').upper(),
                    "school_name": d.get('config', {}).get('schoolName', ''),
                    "nb_eleves":   nb_eleves,
                })
            except Exception:
                details.append({"school_code": fname, "error": "fichier corrompu"})

        logger.info("admin_health : %d école(s) actuellement sur le disque", len(details))
        return jsonify({
            "server_time":     datetime.datetime.now().isoformat(),
            "data_dir":        os.path.abspath(DATA_DIR),
            "nb_ecoles":       len(details),
            "ecoles":          details,
        }), 200
    except Exception as e:
        logger.exception("Erreur admin_health")
        return jsonify({"error": str(e)}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=10000)