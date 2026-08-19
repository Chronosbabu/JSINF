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

# ====================================================================
# ⚡⚡⚡ NOUVEAU — STOCKAGE SUR DISQUE PERSISTANT RENDER
# ====================================================================
# Vous avez ajouté un disque persistant Render (1 Go) monté sur le
# chemin /var/data. Tant que ce disque est attaché au service, tout ce
# qui est écrit dans ce dossier survit aux redéploiements, redémarrages
# et mises à jour du serveur — contrairement au disque local du
# conteneur (éphémère), qui est effacé à chaque déploiement.
#
# DATA_DIR pointe maintenant vers un sous-dossier "school_data" DANS
# le disque persistant (/var/data/school_data), pour garder toutes vos
# données bien organisées à l'intérieur du point de montage.
#
# Vous pouvez surcharger ce chemin via la variable d'environnement
# DATA_DIR si besoin (utile pour tester en local sans le disque Render
# monté), sinon la valeur par défaut est bien /var/data/school_data.
#
# ⚠️ IMPORTANT côté Render : le "Mount Path" du disque doit être
# /var/data (exactement ce que vous avez indiqué), et ce disque doit
# être attaché à CE service précis. Rien d'autre à faire côté code :
# os.makedirs(DATA_DIR, exist_ok=True) ci-dessous crée automatiquement
# le sous-dossier school_data au premier démarrage si besoin.
DATA_DIR = os.environ.get("DATA_DIR", "/var/data/school_data")
os.makedirs(DATA_DIR, exist_ok=True)

KEYS_FILE                  = os.path.join(DATA_DIR, "keys_store.json")
IDS_FILE                   = os.path.join(DATA_DIR, "ids_store.json")
PENDING_FILE                = os.path.join(DATA_DIR, "pending_payments.json")
MOBILE_PAYMENTS_FILE        = os.path.join(DATA_DIR, "mobile_payments.json")
SCHOOLS_FILE                = os.path.join(DATA_DIR, "schools_registry.json")
# ⚡ NOUVEAU — Module Discipline
ATTENDANCE_FILE             = os.path.join(DATA_DIR, "attendance_records.json")
MESSAGES_FILE                = os.path.join(DATA_DIR, "parent_messages.json")
# ⚡⚡ NOUVEAU — Clés multi-usages : inscriptions et autres frais en attente
PENDING_REGISTRATIONS_FILE  = os.path.join(DATA_DIR, "pending_registrations.json")
PENDING_AUTRES_FRAIS_FILE   = os.path.join(DATA_DIR, "pending_autres_frais.json")
# ⚡⚡⚡ NOUVEAU — Système d'abonnement / clés de reconnexion
SUBSCRIPTION_KEYS_FILE      = os.path.join(DATA_DIR, "subscription_keys.json")

ADMIN_PASSWORD = "edupay_admin_2026"

AIRTEL_MERCHANT_ID  = os.environ.get('AIRTEL_MERCHANT_ID', '')
AIRTEL_API_KEY      = os.environ.get('AIRTEL_API_KEY', '')
ORANGE_MERCHANT_ID  = os.environ.get('ORANGE_MERCHANT_ID', '')
ORANGE_API_KEY      = os.environ.get('ORANGE_API_KEY', '')
VODACOM_MERCHANT_ID = os.environ.get('VODACOM_MERCHANT_ID', '')
VODACOM_API_KEY     = os.environ.get('VODACOM_API_KEY', '')

# ====================================================================
# ⚡⚡⚡ NOUVEAU — GESTION DE L'ABONNEMENT (LICENCE)
# ====================================================================
# Chaque école dispose d'une période d'abonnement qui démarre au moment
# de son activation (/school/activate) et qui est redémarrée à chaque
# fois qu'une CLÉ DE RECONNEXION valide (générée par l'admin depuis
# admin_panel.py) est consommée via /school/redeem_reconnection_key.
#
# ⚡ MODE TEST : la durée est fixée à 60 secondes (1 minute), comme
# demandé, pour pouvoir tester rapidement tout le scénario complet
# (activation -> expiration -> clé de reconnexion -> nouvel accès).
#
# 🚀 POUR LA PRODUCTION : il suffit de mettre SUBSCRIPTION_TEST_MODE à
# False ci-dessous. La durée passera automatiquement à 30 jours, sans
# rien changer d'autre dans le code.
SUBSCRIPTION_TEST_MODE = True
SUBSCRIPTION_DURATION_SECONDS = 60 if SUBSCRIPTION_TEST_MODE else 30 * 24 * 60 * 60

MONTHS = [
    'Septembre', 'Octobre', 'Novembre', 'Decembre',
    'Janvier', 'Fevrier', 'Mars', 'Avril', 'Mai', 'Juin'
]

# ⚡⚡ NOUVEAU — Types d'accès possibles pour une clé générée par l'admin.
# PAY  = paiement des frais scolaires mensuels (comportement historique)
# DISC = discipline (absences, convocations, communiqués)
# INSC = inscription de nouveaux élèves
# AFR  = paiement des "autres frais" (frais ponctuels/annexes)
KEY_TYPES = {'PAY', 'DISC', 'INSC', 'AFR'}

# ⚡ Liste centrale des fichiers "système" (non-écoles) à exclure de tout
# scan de dossier qui s'attend à ne trouver que des fichiers école.
# IMPORTANT : chaque nouveau fichier de stockage global (comme
# ATTENDANCE_FILE et MESSAGES_FILE ci-dessus) DOIT être ajouté ici,
# sinon il sera scanné à tort comme un fichier école par parent_find_student,
# _get_all_ids_except, _auto_confirm_payment, admin_health, etc.
SYSTEM_FILES = {
    'keys_store.json', 'ids_store.json',
    'pending_payments.json', 'mobile_payments.json',
    'schools_registry.json',
    'attendance_records.json', 'parent_messages.json',
    'pending_registrations.json', 'pending_autres_frais.json',
    'subscription_keys.json',
}

# ====================================================================
# ⚡ CONFIGURATION DES LOGS
# ====================================================================
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s %(name)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    stream=sys.stdout,
)
logger = logging.getLogger("edupay")


def _log_startup_state():
    try:
        files = os.listdir(DATA_DIR)
        school_files = [
            f for f in files
            if f.endswith('.json') and f not in SYSTEM_FILES
        ]
        logger.info(
            "=== DEMARRAGE SERVEUR === DATA_DIR='%s' | %d fichier(s) école "
            "trouvé(s) au démarrage : %s | mode_abonnement=%s (%ds)",
            os.path.abspath(DATA_DIR), len(school_files), school_files,
            "TEST" if SUBSCRIPTION_TEST_MODE else "PRODUCTION",
            SUBSCRIPTION_DURATION_SECONDS,
        )
        if not school_files:
            logger.warning(
                "⚠️ Aucun fichier école trouvé au démarrage. Si vous aviez "
                "déjà des écoles sauvegardées avant ce redémarrage, vérifiez "
                "que le disque persistant Render est bien attaché à ce "
                "service et monté sur '/var/data' — sinon les données "
                "peuvent avoir été perdues (stockage éphémère)."
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
    for fname in os.listdir(DATA_DIR):
        if not fname.endswith('.json') or fname in SYSTEM_FILES:
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
# ⚡⚡⚡ NOUVEAU — HELPERS ABONNEMENT / CLÉ DE RECONNEXION
# ====================================================================

def _find_school_entry(school_code):
    """Recherche insensible à la casse d'une école dans le registre.
    Renvoie (code_reel, dict_ecole) ou (None, None) si introuvable."""
    if not school_code:
        return None, None
    schools = _load_json(SCHOOLS_FILE, {})
    target = school_code.strip().upper()
    for code, school in schools.items():
        if code.upper() == target:
            return code, school
    return None, None


def _generate_reconnection_key_str():
    chars  = string.ascii_uppercase + string.digits
    groups = [''.join(secrets.choice(chars) for _ in range(4)) for _ in range(3)]
    return f"RECO-{'-'.join(groups)}"


def _start_new_subscription_period(school):
    """Démarre (ou redémarre) une période d'abonnement complète pour
    l'école donnée : maintenant -> maintenant + SUBSCRIPTION_DURATION_SECONDS.
    Modifie le dict `school` EN PLACE (celui-ci doit provenir d'un
    dictionnaire chargé depuis SCHOOLS_FILE, pour que la modification
    soit bien sauvegardée par l'appelant via _save_json)."""
    now     = datetime.datetime.now()
    expires = now + datetime.timedelta(seconds=SUBSCRIPTION_DURATION_SECONDS)
    school['subscription_started_at'] = now.isoformat()
    school['subscription_expires_at'] = expires.isoformat()
    school['subscription_blocked']    = False
    return school


def _compute_subscription_status(school):
    """Calcule l'état d'abonnement d'une école à partir de son entrée
    dans le registre central. Ne renvoie jamais None : une école sans
    aucune information d'abonnement (compte créé avant l'introduction
    de cette fonctionnalité) est considérée VALIDE par défaut, pour ne
    jamais bloquer rétroactivement un compte existant."""
    if not school:
        return {
            "valid":             False,
            "blocked":           True,
            "expires_at":        None,
            "seconds_remaining": 0,
        }

    if school.get('subscription_blocked'):
        return {
            "valid":             False,
            "blocked":           True,
            "expires_at":        school.get('subscription_expires_at'),
            "seconds_remaining": 0,
        }

    expires_at_str = school.get('subscription_expires_at')
    if not expires_at_str:
        return {
            "valid":             True,
            "blocked":           False,
            "expires_at":        None,
            "seconds_remaining": None,
        }

    try:
        expires_at = datetime.datetime.fromisoformat(expires_at_str)
    except Exception:
        return {
            "valid":             True,
            "blocked":           False,
            "expires_at":        expires_at_str,
            "seconds_remaining": None,
        }

    now       = datetime.datetime.now()
    remaining = (expires_at - now).total_seconds()
    is_valid  = remaining > 0
    return {
        "valid":             is_valid,
        "blocked":           False,
        "expires_at":        expires_at_str,
        "seconds_remaining": max(0, int(remaining)),
    }


# ====================================================================
# DISTRIBUTION MULTI-MOIS (logique identique à handlePayment Flutter)
# ====================================================================
def _get_required_for_month(config, section, mois):
    exceptions = config.get('monthlyExceptionsBySection', {}).get(section, {})
    if mois in exceptions:
        return float(exceptions[mois])
    fee = config.get('feesBySection', {}).get(section)
    if fee is not None:
        return float(fee)
    return 35000.0


def _distribute_payment(config, eleve, start_mois, total_amount):
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
# ⚡ LOG DE CHAQUE REQUÊTE ENTRANTE
# ====================================================================
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
            # ⚡⚡⚡ NOUVEAU — champs d'abonnement, remplis réellement à
            # l'activation (voir /school/activate). Laissés vides ici
            # pour qu'une école non encore activée ne soit jamais
            # comptée comme "expirée".
            "subscription_started_at": None,
            "subscription_expires_at": None,
            "subscription_blocked":    False,
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
        # ⚡⚡⚡ NOUVEAU — démarre la période d'abonnement de l'école dès
        # son activation (voir SUBSCRIPTION_DURATION_SECONDS en haut du
        # fichier : 1 minute en mode test, 30 jours en production).
        _start_new_subscription_period(schools[target_code])
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
                "autresFrais": [],
                "autresFraisPaiementsByYear": {},
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
            # ⚡⚡⚡ NOUVEAU — permet au client Flutter d'initialiser tout
            # de suite son cache local d'abonnement (SubscriptionService).
            "subscription_expires_at": schools[target_code].get('subscription_expires_at'),
            "subscription_seconds":    SUBSCRIPTION_DURATION_SECONDS,
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
            # ⚡⚡⚡ NOUVEAU — état d'abonnement complet, utilisé par
            # l'interface admin (admin_panel.py) pour afficher qui est
            # en règle et qui a besoin d'une clé de reconnexion.
            "subscription":  _compute_subscription_status(s),
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

        file_size = os.path.getsize(filepath) if os.path.exists(filepath) else 0
        logger.info(
            "✅ BACKUP écrit avec succès : école='%s' path='%s' taille=%d octets "
            "| %d correction(s) d'ID",
            school_code, filepath, file_size, len(corrections),
        )

        # ⚡⚡⚡ NOUVEAU — on joint l'état de l'abonnement à la réponse du
        # backup : c'est un des moments où l'appli a forcément internet,
        # donc l'occasion idéale de rafraîchir le cache local côté
        # client (SubscriptionService.applyServerSubscription).
        _, school_entry = _find_school_entry(school_code)
        return jsonify({
            "message":      "Sauvegarde réussie",
            "school_code":  school_code,
            "corrections":  corrections,
            "subscription": _compute_subscription_status(school_entry),
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
        # ⚡⚡⚡ NOUVEAU — état d'abonnement inclus dans la restauration,
        # pour que le client rafraîchisse son cache local dès qu'il a
        # internet (utile notamment lors d'une restauration classique).
        _, school_entry = _find_school_entry(school_code)
        data['subscription'] = _compute_subscription_status(school_entry)
        return jsonify(data), 200
    logger.warning(
        "❌ RESTORE : aucune sauvegarde trouvée pour école='%s' (fichier attendu : '%s')",
        school_code, filepath,
    )
    return jsonify({"error": "Aucune sauvegarde trouvée"}), 404


# ====================================================================
# PAIEMENTS EN ATTENTE (sous-utilisateur — clé de type PAY)
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

        fichiers_ecoles = [
            f for f in os.listdir(DATA_DIR)
            if f.endswith('.json') and f not in SYSTEM_FILES
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
        remainder     = amount - total_covered

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
    try:
        data = request.get_json()
        return _store_pending_mobile_payment(data)
    except Exception as e:
        logger.exception("Erreur parent_submit_mobile_payment")
        return jsonify({"error": str(e)}), 500


def _store_pending_mobile_payment(data):
    try:
        student_id    = data.get('student_id', '').strip().upper()
        school_code   = data.get('school_code', '').strip()
        network       = data.get('network', '')
        parent_name   = data.get('parent_name', 'Parent')
        month_entries = data.get('month_entries')
        start_mois    = data.get('mois')
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
    for fname in os.listdir(DATA_DIR):
        if not fname.endswith('.json') or fname in SYSTEM_FILES:
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
                # ⚡⚡⚡ NOUVEAU — on joint l'état de l'abonnement à la
                # réponse de connexion. C'est LE moment clé : quand un
                # utilisateur se connecte depuis un NOUVEL ordinateur
                # avec code école + mot de passe, c'est ici que le
                # serveur détermine s'il faut le rediriger vers l'écran
                # "Abonnement expiré" (le client Flutter lit
                # `subscription.valid`).
                _, school_entry = _find_school_entry(school_code)
                subscription = _compute_subscription_status(school_entry)
                logger.info(
                    "verify_password : école='%s' mot de passe OK | abonnement_valide=%s",
                    school_code, subscription['valid'],
                )
                return jsonify({
                    "valid":        True,
                    "subscription": subscription,
                }), 200
            logger.warning("verify_password : mot de passe incorrect pour école='%s'", school_code)
            return jsonify({
                "valid": False, "error": "Mot de passe incorrect"
            }), 401
        logger.warning("verify_password : aucune sauvegarde pour école='%s'", school_code)
        return jsonify({"error": "Aucune sauvegarde trouvée"}), 404
    except Exception as e:
        logger.exception("Erreur verify_password")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# ⚡⚡⚡ NOUVEAU — ROUTES ABONNEMENT / CLÉ DE RECONNEXION
# ====================================================================
# Trois routes :
#   1) /school/check_subscription       (public, GET)   — l'appli
#      interroge l'état d'abonnement d'une école, sans mot de passe
#      (comme /restore).
#   2) /admin/generate_reconnection_key (admin, POST)    — génère une
#      clé à usage unique pour une école, à transmettre par
#      téléphone/WhatsApp à l'école concernée.
#   3) /school/redeem_reconnection_key  (public, POST)   — l'appli
#      envoie la clé saisie par l'utilisateur ; si elle est valide,
#      une nouvelle période d'abonnement démarre immédiatement.
# ====================================================================

@app.route('/school/check_subscription', methods=['GET'])
def check_subscription():
    """
    Appelée par l'application :
      - au démarrage, si une connexion internet est disponible, pour
        rafraîchir le cache local (SubscriptionService) ;
      - surtout, lors d'une connexion sur un NOUVEL appareil avec code
        école + mot de passe (voir aussi /verify_password qui renvoie
        déjà cette même information).
    Ne nécessite aucun mot de passe : le school_code seul suffit,
    exactement comme /restore.
    """
    try:
        school_code = request.args.get('school_code', '').strip()
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        _, school = _find_school_entry(school_code)
        if not school:
            logger.warning("check_subscription : école introuvable code='%s'", school_code)
            return jsonify({"error": "École introuvable"}), 404
        status = _compute_subscription_status(school)
        logger.info(
            "check_subscription : école='%s' valide=%s restant=%ss",
            school_code, status['valid'], status.get('seconds_remaining'),
        )
        return jsonify(status), 200
    except Exception as e:
        logger.exception("Erreur check_subscription")
        return jsonify({"error": str(e)}), 500


@app.route('/admin/generate_reconnection_key', methods=['POST'])
def generate_reconnection_key():
    """
    Réservée à l'admin (mot de passe admin requis). Génère une clé de
    reconnexion à usage unique pour une école donnée. Cette clé, une
    fois transmise à l'école et saisie dans l'appli (écran "Abonnement
    expiré"), redémarre immédiatement une période d'abonnement complète
    pour cette école (60 secondes en mode test, 30 jours en production).
    """
    try:
        data = request.get_json()
        if data.get('admin_password') != ADMIN_PASSWORD:
            logger.warning("generate_reconnection_key : mot de passe admin incorrect")
            return jsonify({"error": "Mot de passe admin incorrect"}), 401

        school_code = (data.get('school_code') or '').strip()
        if not school_code:
            return jsonify({"error": "Code école manquant"}), 400

        real_code, school = _find_school_entry(school_code)
        if not school:
            return jsonify({"error": "École introuvable"}), 404

        key = _generate_reconnection_key_str()
        keys_store      = _load_json(SUBSCRIPTION_KEYS_FILE, {})
        # Sécurité : s'assurer qu'on ne génère jamais deux fois la même
        # clé (extrêmement improbable vu l'espace de génération, mais
        # gratuit à vérifier).
        while key in keys_store:
            key = _generate_reconnection_key_str()

        keys_store[key] = {
            "school_code": real_code,
            "school_name": school.get('school_name'),
            "created_at":  datetime.datetime.now().isoformat(),
            "used":        False,
            "used_at":     None,
        }
        _save_json(SUBSCRIPTION_KEYS_FILE, keys_store)

        logger.info(
            "🔑 generate_reconnection_key : école='%s' → clé générée='%s'",
            real_code, key,
        )

        return jsonify({
            "key":         key,
            "school_code": real_code,
            "school_name": school.get('school_name'),
        }), 200
    except Exception as e:
        logger.exception("Erreur generate_reconnection_key")
        return jsonify({"error": str(e)}), 500


@app.route('/school/redeem_reconnection_key', methods=['POST'])
def redeem_reconnection_key():
    """
    Appelée par l'application quand l'utilisateur saisit, dans l'écran
    "Abonnement expiré", la clé fournie par l'administrateur EduPay.
    Si la clé est valide, non utilisée, et correspond bien à l'école
    concernée, une nouvelle période d'abonnement démarre immédiatement
    et la clé est marquée comme consommée (usage unique).
    """
    try:
        data        = request.get_json()
        school_code = (data.get('school_code') or '').strip()
        key         = (data.get('key') or '').strip().upper()

        if not school_code or not key:
            return jsonify({"error": "Données manquantes"}), 400

        real_code, school = _find_school_entry(school_code)
        if not school:
            return jsonify({"error": "École introuvable"}), 404

        keys_store = _load_json(SUBSCRIPTION_KEYS_FILE, {})
        key_info   = keys_store.get(key)

        if not key_info:
            logger.warning(
                "redeem_reconnection_key : clé introuvable pour école='%s'",
                school_code,
            )
            return jsonify({"error": "Clé de reconnexion invalide"}), 404

        if key_info.get('used'):
            logger.warning(
                "redeem_reconnection_key : clé déjà utilisée (école='%s')",
                school_code,
            )
            return jsonify({"error": "Cette clé a déjà été utilisée"}), 400

        if key_info.get('school_code', '').upper() != real_code.upper():
            logger.warning(
                "redeem_reconnection_key : clé ne correspond pas à l'école='%s'",
                school_code,
            )
            return jsonify({
                "error": "Cette clé ne correspond pas à cette école"
            }), 400

        # Tout est valide : on redémarre une période complète et on
        # marque la clé comme consommée.
        schools = _load_json(SCHOOLS_FILE, {})
        _start_new_subscription_period(schools[real_code])
        _save_json(SCHOOLS_FILE, schools)

        key_info['used']    = True
        key_info['used_at'] = datetime.datetime.now().isoformat()
        keys_store[key]     = key_info
        _save_json(SUBSCRIPTION_KEYS_FILE, keys_store)

        logger.info(
            "✅ redeem_reconnection_key : école='%s' réactivée jusqu'à '%s'",
            real_code, schools[real_code].get('subscription_expires_at'),
        )

        return jsonify({
            "message":    "Abonnement réactivé avec succès",
            "expires_at": schools[real_code].get('subscription_expires_at'),
        }), 200
    except Exception as e:
        logger.exception("Erreur redeem_reconnection_key")
        return jsonify({"error": str(e)}), 500


@app.route('/admin/list_reconnection_keys', methods=['POST'])
def list_reconnection_keys():
    """
    Réservée à l'admin. Renvoie l'historique des clés de reconnexion
    générées (utilisées ou non), avec un filtre optionnel par école —
    pratique pour l'onglet "Historique" de l'interface admin.
    """
    try:
        data = request.get_json()
        if data.get('admin_password') != ADMIN_PASSWORD:
            return jsonify({"error": "Accès refusé"}), 401
        school_code = (data.get('school_code') or '').strip()
        keys_store  = _load_json(SUBSCRIPTION_KEYS_FILE, {})
        result = [
            {"key": k, **v}
            for k, v in keys_store.items()
            if not school_code or v.get('school_code', '').upper() == school_code.upper()
        ]
        result.sort(key=lambda x: x.get('created_at', ''), reverse=True)
        return jsonify({"keys": result, "total": len(result)}), 200
    except Exception as e:
        logger.exception("Erreur list_reconnection_keys")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# ⚡⚡ NOUVEAU — CLÉS D'ACCÈS MULTI-USAGES
# ====================================================================
# Une clé encode désormais 4 informations :
#   - school_code : l'école concernée
#   - type        : PAY | DISC | INSC | AFR (ce que le sous-utilisateur
#                   peut faire une fois connecté avec cette clé)
#   - section     : la section sur laquelle il travaille
#   - classe      : soit une classe précise, soit None/"" pour signifier
#                   "toutes les classes de la section"
# Le format texte de la clé reste lisible par un humain, à des fins de
# debug/support : SCHOOLCODE*TYPE*SEC*CLASSE*alea
# (CLASSE vaut littéralement "ALL" quand aucune classe n'est précisée)
# ====================================================================

def _slug(value, max_len=12):
    """Réduit une chaîne à des caractères alphanumériques, en majuscules,
    pour l'insérer proprement dans la clé texte (la classe peut contenir
    des espaces, accents, etc. ex: '6ème A')."""
    cleaned = re.sub(r'[^A-Za-z0-9]', '', value or '')
    return cleaned.upper()[:max_len] if cleaned else "ALL"


@app.route('/generate_key', methods=['POST'])
def generate_key():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        section     = data.get('section')
        # ⚡⚡ NOUVEAU — type d'accès. 'PAY' par défaut pour rester
        # compatible avec d'anciens clients qui n'enverraient pas ce champ.
        key_type    = (data.get('type') or 'PAY').strip().upper()
        # ⚡⚡ NOUVEAU — classe ciblée, ou vide/None = toutes les classes
        # de la section.
        classe      = (data.get('classe') or '').strip()

        if not school_code or not section:
            return jsonify({"error": "Données manquantes"}), 400

        if key_type not in KEY_TYPES:
            return jsonify({
                "error": f"Type de clé invalide. Valeurs possibles : "
                         f"{', '.join(sorted(KEY_TYPES))}"
            }), 400

        key = (
            f"{school_code.upper()}*{key_type}*{section.upper()[:3]}"
            f"*{_slug(classe)}*{os.urandom(4).hex()}"
        )
        keys      = _load_json(KEYS_FILE, {})
        keys[key] = {
            "school_code": school_code,
            "section":     section,
            "type":        key_type,
            # None = toutes les classes de la section
            "classe":      classe if classe else None,
        }
        _save_json(KEYS_FILE, keys)
        logger.info(
            "🔑 generate_key : école='%s' type='%s' section='%s' classe='%s' → clé générée",
            school_code, key_type, section, classe or "TOUTES",
        )
        return jsonify({
            "key":     key,
            "section": section,
            "type":    key_type,
            "classe":  classe or None,
        }), 200
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
        logger.info(
            "verify_key : clé valide pour école='%s' type='%s' section='%s' classe='%s'",
            school_code, info.get('type', 'PAY'), info["section"], info.get('classe'),
        )
        return jsonify({
            "valid":        True,
            "school_code":  school_code,
            "section":      info["section"],
            # ⚡⚡ NOUVEAU — anciennes clés déjà en circulation sans 'type' :
            # on retombe sur 'PAY' pour ne rien casser.
            "type":         info.get("type", "PAY"),
            "classe":       info.get("classe"),  # None = toutes les classes
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


@app.route('/list_keys', methods=['GET'])
def list_keys():
    """⚡⚡ NOUVEAU — Liste toutes les clés actives d'une école, pour que
    l'admin puisse voir/gérer (et révoquer) les clés déjà distribuées,
    avec leur type, section et classe."""
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        keys   = _load_json(KEYS_FILE, {})
        result = [
            {
                "key":     k,
                "type":    v.get("type", "PAY"),
                "section": v.get("section"),
                "classe":  v.get("classe"),
            }
            for k, v in keys.items()
            if v.get("school_code") == school_code
        ]
        return jsonify({"keys": result, "total": len(result)}), 200
    except Exception as e:
        logger.exception("Erreur list_keys")
        return jsonify({"error": str(e)}), 500


def _generate_student_id_for_school(school_code, nom, year, school_name, proposed_id=None):
    """Factorisation de la logique déjà utilisée par /generate_student_id,
    réutilisée aussi par la validation des inscriptions en attente."""
    ids_store = _load_json(IDS_FILE, {})
    used_ids  = set(ids_store.get(school_code.lower(), []))

    if proposed_id and proposed_id not in used_ids:
        candidate = proposed_id
    else:
        year_short    = year[-2:] if year and len(year) >= 2 else "26"
        alnum_school  = re.sub(r'[^A-Za-z0-9]', '', school_name or '')
        school_letter = alnum_school[0].upper() if alnum_school else "B"
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
    return candidate


@app.route('/generate_student_id', methods=['POST'])
def generate_student_id():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        nom         = data.get('nom', '')
        year        = data.get('year', '2025-2026')
        proposed_id = data.get('proposed_id')
        school_name = data.get('school_name', '')

        if not school_code or not nom:
            return jsonify({"error": "Données manquantes"}), 400

        candidate = _generate_student_id_for_school(
            school_code, nom, year, school_name, proposed_id)
        logger.info("generate_student_id : école='%s' → id='%s'", school_code, candidate)
        return jsonify({"id": candidate}), 200
    except Exception as e:
        logger.exception("Erreur generate_student_id")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# ⚡⚡ NOUVEAU — INSCRIPTIONS EN ATTENTE (clé de type INSC)
# Même philosophie que les paiements : le sous-utilisateur (agent chargé
# des inscriptions) soumet une fiche élève, qui reste "en attente" tant
# que l'admin ne l'a pas validée depuis admin_dashboard_screen.dart. Cela
# évite les doublons/erreurs de saisie directement dans les données
# officielles de l'école.
# ====================================================================

@app.route('/school/submit_registration', methods=['POST'])
def submit_registration():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        annee       = data.get('annee')
        section     = (data.get('section') or '').strip()
        classe      = (data.get('classe') or '').strip()
        nom         = (data.get('nom') or '').strip()
        post_nom    = (data.get('postNom') or '').strip()
        prenom      = (data.get('prenom') or '').strip()
        pere_nom    = (data.get('pereNom') or '').strip()
        mere_nom    = (data.get('mereNom') or '').strip()
        adresse     = (data.get('adresse') or '').strip()
        naissance   = (data.get('dateNaissance') or '').strip()
        submitted_by = (data.get('submitted_by') or 'Agent inscriptions').strip()

        if not all([school_code, annee, section, classe, nom]):
            return jsonify({
                "error": "École, année, section, classe et nom sont obligatoires"
            }), 400

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        registration_id = (
            f"reg_{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"
            f"_{os.urandom(3).hex()}"
        )

        pending_store = _load_json(PENDING_REGISTRATIONS_FILE, {})
        school_key    = school_code.lower()
        pending_list  = pending_store.get(school_key, [])
        pending_list.append({
            "id":            registration_id,
            "annee":         annee,
            "section":       section,
            "classe":        classe,
            "nom":           nom,
            "postNom":       post_nom,
            "prenom":        prenom,
            "pereNom":       pere_nom,
            "mereNom":       mere_nom,
            "adresse":       adresse,
            "dateNaissance": naissance,
            "submitted_by":  submitted_by,
            "date":          datetime.date.today().isoformat(),
        })
        pending_store[school_key] = pending_list
        _save_json(PENDING_REGISTRATIONS_FILE, pending_store)

        logger.info(
            "🧑‍🎓 submit_registration : école='%s' élève='%s %s' classe='%s' → id_attente='%s'",
            school_code, nom, prenom, classe, registration_id,
        )

        return jsonify({
            "message":         "Inscription reçue, en attente de validation",
            "registration_id": registration_id,
        }), 200
    except Exception as e:
        logger.exception("Erreur submit_registration")
        return jsonify({"error": str(e)}), 500


@app.route('/school/get_pending_registrations', methods=['GET'])
def get_pending_registrations():
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        pending_store = _load_json(PENDING_REGISTRATIONS_FILE, {})
        pending_list  = pending_store.get(school_code.lower(), [])
        logger.info(
            "get_pending_registrations : école='%s' → %d en attente",
            school_code, len(pending_list),
        )
        return jsonify({"pending_registrations": pending_list}), 200
    except Exception as e:
        logger.exception("Erreur get_pending_registrations")
        return jsonify({"error": str(e)}), 500


@app.route('/school/validate_registrations', methods=['POST'])
def validate_registrations():
    try:
        data            = request.get_json()
        school_code     = data.get('school_code')
        registration_ids = data.get('registration_ids')

        if not school_code:
            return jsonify({"error": "Code manquant"}), 400

        school_key = school_code.lower()
        filepath   = os.path.join(DATA_DIR, f"{school_key}.json")
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)

        school_name = saved.get('config', {}).get('schoolName', school_code)

        pending_store = _load_json(PENDING_REGISTRATIONS_FILE, {})
        pending_list  = pending_store.get(school_key, [])

        if registration_ids:
            to_validate = [p for p in pending_list if p.get('id') in registration_ids]
            remaining   = [p for p in pending_list if p.get('id') not in registration_ids]
        else:
            to_validate = pending_list
            remaining   = []

        created_students = []
        for entry in to_validate:
            annee = entry.get('annee')
            saved.setdefault('history', {}).setdefault(annee, {}).setdefault('eleves', [])
            year_data = saved['history'][annee]

            new_id = _generate_student_id_for_school(
                school_code, entry.get('nom', ''), annee, school_name)

            year_data['eleves'].append({
                "id":            new_id,
                "nom":           entry.get('nom', ''),
                "postNom":       entry.get('postNom', ''),
                "prenom":        entry.get('prenom', ''),
                "classe":        entry.get('classe', ''),
                "section":       entry.get('section', ''),
                "paid":          {},
                "transactions":  [],
                "pereNom":       entry.get('pereNom', ''),
                "mereNom":       entry.get('mereNom', ''),
                "adresse":       entry.get('adresse', ''),
                "dateNaissance": entry.get('dateNaissance', ''),
                "customFields":  {},
            })
            created_students.append({"registration_id": entry.get('id'), "new_id": new_id})

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(saved, f, ensure_ascii=False, indent=2)

        pending_store[school_key] = remaining
        _save_json(PENDING_REGISTRATIONS_FILE, pending_store)

        logger.info(
            "✅ validate_registrations : école='%s' | %d validée(s) | %d restante(s)",
            school_code, len(created_students), len(remaining),
        )

        return jsonify({
            "message":          "Inscriptions validées",
            "created_students": created_students,
            "remaining":        len(remaining),
        }), 200
    except Exception as e:
        logger.exception("Erreur validate_registrations")
        return jsonify({"error": str(e)}), 500


@app.route('/school/reject_registration', methods=['POST'])
def reject_registration():
    try:
        data            = request.get_json()
        school_code     = data.get('school_code')
        registration_id = data.get('registration_id')
        if not school_code or not registration_id:
            return jsonify({"error": "Données manquantes"}), 400

        school_key    = school_code.lower()
        pending_store = _load_json(PENDING_REGISTRATIONS_FILE, {})
        pending_list  = pending_store.get(school_key, [])
        pending_list  = [p for p in pending_list if p.get('id') != registration_id]
        pending_store[school_key] = pending_list
        _save_json(PENDING_REGISTRATIONS_FILE, pending_store)
        logger.info("reject_registration : école='%s' id='%s' rejetée", school_code, registration_id)
        return jsonify({"message": "Inscription rejetée"}), 200
    except Exception as e:
        logger.exception("Erreur reject_registration")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# ⚡⚡ NOUVEAU — AUTRES FRAIS (clé de type AFR)
# Consultation des "autres frais" existants (créés par l'admin depuis
# Paramètres) et soumission de paiements, également en file d'attente
# de validation — même logique que /record_payment pour les frais
# mensuels.
# ====================================================================

@app.route('/school/get_autres_frais', methods=['GET'])
def get_autres_frais():
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404
        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)
        return jsonify({
            "autres_frais": saved.get('autresFrais', []),
        }), 200
    except Exception as e:
        logger.exception("Erreur get_autres_frais")
        return jsonify({"error": str(e)}), 500


@app.route('/school/submit_autre_frais_payment', methods=['POST'])
def submit_autre_frais_payment():
    try:
        data            = request.get_json()
        school_code     = data.get('school_code')
        annee           = data.get('annee')
        eleve_id        = data.get('eleve_id')
        autre_frais_id  = data.get('autre_frais_id')
        montant         = data.get('montant')
        enregistre_par  = (data.get('enregistre_par') or 'Agent').strip()

        if not all([school_code, annee, eleve_id, autre_frais_id]) or montant is None:
            return jsonify({"error": "Données manquantes"}), 400

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404
        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)

        frais = next(
            (f for f in saved.get('autresFrais', [])
             if f.get('id') == autre_frais_id), None)
        if frais is None:
            return jsonify({"error": "Frais introuvable"}), 404

        year_data = saved.get('history', {}).get(annee, {})
        eleve = next(
            (e for e in year_data.get('eleves', [])
             if e.get('id') == eleve_id), None)
        if eleve is None:
            return jsonify({"error": "Élève introuvable"}), 404

        payment_id = (
            f"afr_{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"
            f"_{os.urandom(3).hex()}"
        )

        pending_store = _load_json(PENDING_AUTRES_FRAIS_FILE, {})
        school_key    = school_code.lower()
        pending_list  = pending_store.get(school_key, [])
        pending_list.append({
            "id":             payment_id,
            "annee":          annee,
            "eleve_id":       eleve_id,
            "nom":            eleve.get('nom', ''),
            "postNom":        eleve.get('postNom', ''),
            "prenom":         eleve.get('prenom', ''),
            "autreFraisId":   autre_frais_id,
            "autreFraisNom":  frais.get('nom', ''),
            "montant":        montant,
            "enregistrePar":  enregistre_par,
            "date":           datetime.datetime.now().isoformat(),
        })
        pending_store[school_key] = pending_list
        _save_json(PENDING_AUTRES_FRAIS_FILE, pending_store)

        logger.info(
            "💰 submit_autre_frais_payment : école='%s' élève='%s' frais='%s' montant=%s → id_attente='%s'",
            school_code, eleve_id, frais.get('nom', ''), montant, payment_id,
        )

        return jsonify({
            "message":    "Paiement reçu, en attente de validation",
            "pending_id": payment_id,
        }), 200
    except Exception as e:
        logger.exception("Erreur submit_autre_frais_payment")
        return jsonify({"error": str(e)}), 500


@app.route('/school/get_pending_autres_frais', methods=['GET'])
def get_pending_autres_frais():
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        pending_store = _load_json(PENDING_AUTRES_FRAIS_FILE, {})
        pending_list  = pending_store.get(school_code.lower(), [])
        return jsonify({"pending_autres_frais": pending_list}), 200
    except Exception as e:
        logger.exception("Erreur get_pending_autres_frais")
        return jsonify({"error": str(e)}), 500


@app.route('/school/validate_autres_frais_payments', methods=['POST'])
def validate_autres_frais_payments():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        payment_ids = data.get('payment_ids')

        if not school_code:
            return jsonify({"error": "Code manquant"}), 400

        school_key = school_code.lower()
        filepath   = os.path.join(DATA_DIR, f"{school_key}.json")
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)
        saved.setdefault('autresFraisPaiementsByYear', {})

        pending_store = _load_json(PENDING_AUTRES_FRAIS_FILE, {})
        pending_list  = pending_store.get(school_key, [])

        if payment_ids:
            to_validate = [p for p in pending_list if p.get('id') in payment_ids]
            remaining   = [p for p in pending_list if p.get('id') not in payment_ids]
        else:
            to_validate = pending_list
            remaining   = []

        validated_count = 0
        for entry in to_validate:
            annee = entry.get('annee')
            saved['autresFraisPaiementsByYear'].setdefault(annee, [])
            saved['autresFraisPaiementsByYear'][annee].append({
                "id":            entry.get('id'),
                "autreFraisId":  entry.get('autreFraisId'),
                "autreFraisNom": entry.get('autreFraisNom'),
                "eleveId":       entry.get('eleve_id'),
                "montant":       entry.get('montant'),
                "date":          entry.get('date'),
                "enregistrePar": entry.get('enregistrePar', 'Agent'),
            })
            validated_count += 1

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(saved, f, ensure_ascii=False, indent=2)

        pending_store[school_key] = remaining
        _save_json(PENDING_AUTRES_FRAIS_FILE, pending_store)

        logger.info(
            "✅ validate_autres_frais_payments : école='%s' | %d validé(s) | %d restant(s)",
            school_code, validated_count, len(remaining),
        )

        return jsonify({
            "message":           "Paiements validés",
            "validated_count":   validated_count,
            "remaining_pending": len(remaining),
        }), 200
    except Exception as e:
        logger.exception("Erreur validate_autres_frais_payments")
        return jsonify({"error": str(e)}), 500


@app.route('/school/reject_autre_frais_payment', methods=['POST'])
def reject_autre_frais_payment():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        payment_id  = data.get('payment_id')
        if not school_code or not payment_id:
            return jsonify({"error": "Données manquantes"}), 400

        school_key    = school_code.lower()
        pending_store = _load_json(PENDING_AUTRES_FRAIS_FILE, {})
        pending_list  = pending_store.get(school_key, [])
        pending_list  = [p for p in pending_list if p.get('id') != payment_id]
        pending_store[school_key] = pending_list
        _save_json(PENDING_AUTRES_FRAIS_FILE, pending_store)
        return jsonify({"message": "Paiement rejeté"}), 200
    except Exception as e:
        logger.exception("Erreur reject_autre_frais_payment")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# ⚡ NOUVEAU — MODULE DISCIPLINE (clé de type DISC)
# Trois briques :
#   1) Absences : le directeur de discipline coche les élèves absents
#      pour une classe/date, on enregistre le registre ET on notifie
#      automatiquement chaque parent concerné.
#   2) Convocations : message individuel envoyé à un parent (mauvais
#      comportement, etc.), rédigé librement par l'école.
#   3) Communiqués : message envoyé à un groupe de parents (élèves
#      sélectionnés, une classe, une section, ou toute l'école).
# Tous ces messages sont stockés dans MESSAGES_FILE, une entrée par
# élève ciblé, ce qui permet à l'appli parent de tout récupérer via
# une seule route (/parent/get_messages) filtrée par élève.
# ⚡⚡ Ces routes sont désormais aussi appelées par le sous-utilisateur
# détenteur d'une clé de type DISC (verrouillée sur une section/classe),
# exactement comme l'admin les appelle depuis discipline_registre_screen.dart
# et communique_screen.dart — aucune modification nécessaire ici.
# La synchronisation côté parent se fait par sondage périodique
# (polling) — pas de websocket sur cet hébergement — ce qui donne un
# effet quasi temps-réel amplement suffisant pour ce cas d'usage.
# ====================================================================

def _new_message_id():
    return f"msg_{datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')}_{os.urandom(3).hex()}"


def _add_message_for_student(school_code, student_id, msg_type, title, message, extra=None):
    messages_store = _load_json(MESSAGES_FILE, {})
    school_key     = school_code.lower()
    msg_list       = messages_store.get(school_key, [])
    entry = {
        "id":         _new_message_id(),
        "type":       msg_type,   # 'absence' | 'convocation' | 'announcement'
        "student_id": student_id,
        "title":      title,
        "message":    message,
        "date":       datetime.date.today().isoformat(),
        "created_at": datetime.datetime.now().isoformat(),
        "read":       False,
    }
    if extra:
        entry.update(extra)
    msg_list.append(entry)
    messages_store[school_key] = msg_list
    _save_json(MESSAGES_FILE, messages_store)
    return entry


@app.route('/school/record_absences', methods=['POST'])
def record_absences():
    """
    Enregistre les absences d'une classe pour une date donnée (registre
    de discipline) et notifie automatiquement le parent de chaque élève
    coché comme absent.
    """
    try:
        data           = request.get_json()
        school_code    = data.get('school_code')
        annee          = data.get('annee')
        classe         = data.get('classe', '')
        section        = data.get('section', '')
        date_str       = data.get('date') or datetime.date.today().isoformat()
        absent_ids     = data.get('absent_ids', [])
        recorded_by    = data.get('recorded_by', 'Direction')
        custom_message = (data.get('message') or '').strip()

        if not school_code or not annee:
            return jsonify({"error": "Données manquantes"}), 400

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404
        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)
        year_data     = saved.get('history', {}).get(annee, {})
        eleves_by_id  = {e.get('id'): e for e in year_data.get('eleves', [])}

        attendance_store  = _load_json(ATTENDANCE_FILE, {})
        school_key        = school_code.lower()
        school_attendance = attendance_store.get(school_key, {})
        date_attendance    = school_attendance.get(date_str, {})
        class_key          = classe or "toutes"
        date_attendance[class_key] = {
            "absents":     absent_ids,
            "section":     section,
            "recorded_at": datetime.datetime.now().isoformat(),
            "recorded_by": recorded_by,
        }
        school_attendance[date_str] = date_attendance
        attendance_store[school_key] = school_attendance
        _save_json(ATTENDANCE_FILE, attendance_store)

        default_text = (custom_message or
            "Votre enfant était absent(e) à l'école aujourd'hui "
            "sans justification. Merci de contacter l'administration "
            "pour toute clarification.")

        sent = []
        for sid in absent_ids:
            eleve       = eleves_by_id.get(sid)
            nom_complet = (f"{eleve.get('nom','')} {eleve.get('postNom','')}".strip()
                           if eleve else sid)
            _add_message_for_student(
                school_code, sid, "absence",
                "Absence non justifiée",
                default_text,
                extra={"nom_eleve": nom_complet, "classe": classe},
            )
            sent.append(sid)

        logger.info(
            "📋 record_absences : école='%s' classe='%s' date='%s' | %d absent(s) notifié(s)",
            school_code, classe, date_str, len(sent),
        )

        return jsonify({
            "message":        "Absences enregistrées et parents notifiés",
            "notified_count": len(sent),
        }), 200
    except Exception as e:
        logger.exception("Erreur record_absences")
        return jsonify({"error": str(e)}), 500


@app.route('/school/get_attendance', methods=['GET'])
def get_attendance():
    """
    Renvoie le registre déjà enregistré pour une classe/date donnée
    (utile pour rouvrir le registre du jour sans perdre les cases déjà
    cochées).
    """
    try:
        school_code = request.args.get('school_code')
        date_str    = request.args.get('date') or datetime.date.today().isoformat()
        classe      = request.args.get('classe', 'toutes')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        attendance_store  = _load_json(ATTENDANCE_FILE, {})
        school_attendance = attendance_store.get(school_code.lower(), {})
        date_attendance   = school_attendance.get(date_str, {})
        record = date_attendance.get(classe, {"absents": []})
        return jsonify(record), 200
    except Exception as e:
        logger.exception("Erreur get_attendance")
        return jsonify({"error": str(e)}), 500


@app.route('/school/send_convocation', methods=['POST'])
def send_convocation():
    """
    Envoie un message de convocation à un parent (comportement,
    discipline...). Le texte est rédigé librement par l'école.
    """
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        student_id  = data.get('student_id')
        title       = (data.get('title') or 'Convocation des parents').strip()
        message     = (data.get('message') or '').strip()

        if not school_code or not student_id or not message:
            return jsonify({"error": "Données manquantes"}), 400

        entry = _add_message_for_student(
            school_code, student_id, "convocation", title, message)

        logger.info(
            "📨 send_convocation : école='%s' élève='%s'",
            school_code, student_id,
        )
        return jsonify({"message": "Convocation envoyée", "id": entry["id"]}), 200
    except Exception as e:
        logger.exception("Erreur send_convocation")
        return jsonify({"error": str(e)}), 500


@app.route('/school/send_announcement', methods=['POST'])
def send_announcement():
    """
    Envoie un communiqué aux parents. Ciblage :
      - target = "students" + student_ids = [...]
      - target = "classe"   + classe = "..."
      - target = "section"  + section = "..."
      - target = "all"      (toute l'école)
    """
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        annee       = data.get('annee')
        title       = (data.get('title') or "Communiqué de l'école").strip()
        message     = (data.get('message') or '').strip()
        target      = data.get('target', 'all')
        student_ids = data.get('student_ids', [])
        classe      = data.get('classe', '')
        section     = data.get('section', '')

        if not school_code or not annee or not message:
            return jsonify({"error": "Données manquantes"}), 400

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404
        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)
        year_data = saved.get('history', {}).get(annee, {})
        eleves    = year_data.get('eleves', [])

        if target == 'students':
            targeted = [e for e in eleves if e.get('id') in student_ids]
        elif target == 'classe':
            targeted = [e for e in eleves if e.get('classe') == classe]
        elif target == 'section':
            targeted = [e for e in eleves if e.get('section') == section]
        else:
            targeted = eleves

        sent = []
        for e in targeted:
            sid = e.get('id')
            if not sid:
                continue
            _add_message_for_student(
                school_code, sid, "announcement", title, message,
                extra={"nom_eleve": f"{e.get('nom','')} {e.get('postNom','')}".strip()},
            )
            sent.append(sid)

        logger.info(
            "📢 send_announcement : école='%s' cible='%s' | %d parent(s) notifié(s)",
            school_code, target, len(sent),
        )
        return jsonify({
            "message":        "Communiqué envoyé",
            "notified_count": len(sent),
        }), 200
    except Exception as e:
        logger.exception("Erreur send_announcement")
        return jsonify({"error": str(e)}), 500


@app.route('/parent/get_messages', methods=['GET'])
def parent_get_messages():
    """
    Récupère tous les messages (absences, convocations, communiqués)
    liés à un élève donné, du plus récent au plus ancien, avec le
    nombre de messages non lus. Appelée par l'appli parent en boucle
    (sondage périodique) pour simuler le temps réel.
    """
    try:
        student_id  = request.args.get('student_id', '').strip().upper()
        school_code = request.args.get('school_code', '').strip()
        if not student_id or not school_code:
            return jsonify({"error": "Paramètres manquants"}), 400

        messages_store   = _load_json(MESSAGES_FILE, {})
        msg_list         = messages_store.get(school_code.lower(), [])
        student_messages = [
            m for m in msg_list
            if m.get('student_id', '').upper() == student_id
        ]
        student_messages.sort(key=lambda m: m.get('created_at', ''), reverse=True)
        unread_count = sum(1 for m in student_messages if not m.get('read'))

        return jsonify({
            "messages":     student_messages,
            "unread_count": unread_count,
        }), 200
    except Exception as e:
        logger.exception("Erreur parent_get_messages")
        return jsonify({"error": str(e)}), 500


@app.route('/parent/mark_message_read', methods=['POST'])
def parent_mark_message_read():
    try:
        data        = request.get_json()
        school_code = (data.get('school_code') or '').strip()
        message_id  = (data.get('message_id') or '').strip()
        if not school_code or not message_id:
            return jsonify({"error": "Données manquantes"}), 400

        messages_store = _load_json(MESSAGES_FILE, {})
        school_key     = school_code.lower()
        msg_list       = messages_store.get(school_key, [])
        found = False
        for m in msg_list:
            if m.get('id') == message_id:
                m['read'] = True
                found = True
                break
        messages_store[school_key] = msg_list
        _save_json(MESSAGES_FILE, messages_store)

        if not found:
            return jsonify({"error": "Message introuvable"}), 404
        return jsonify({"message": "Marqué comme lu"}), 200
    except Exception as e:
        logger.exception("Erreur parent_mark_message_read")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# ⚡ ROUTE DE DIAGNOSTIC
# ====================================================================
@app.route('/admin/health', methods=['GET'])
def admin_health():
    try:
        fichiers_ecoles = [
            f for f in os.listdir(DATA_DIR)
            if f.endswith('.json') and f not in SYSTEM_FILES
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
            # ⚡⚡⚡ NOUVEAU — visible d'un coup d'œil dans /admin/health
            "subscription_mode": "TEST (1 minute)" if SUBSCRIPTION_TEST_MODE else "PRODUCTION (30 jours)",
        }), 200
    except Exception as e:
        logger.exception("Erreur admin_health")
        return jsonify({"error": str(e)}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=10000)