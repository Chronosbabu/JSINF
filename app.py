from flask import Flask, request, jsonify, send_from_directory
import json
import os
import re
import datetime
import secrets
import string
import logging
import sys
import hashlib
import firebase_admin
from firebase_admin import credentials, messaging

app = Flask(__name__)

DATA_DIR = os.environ.get("DATA_DIR", "/var/data/school_data")
os.makedirs(DATA_DIR, exist_ok=True)

KEYS_FILE                  = os.path.join(DATA_DIR, "keys_store.json")
IDS_FILE                   = os.path.join(DATA_DIR, "ids_store.json")
PENDING_FILE                = os.path.join(DATA_DIR, "pending_payments.json")
MOBILE_PAYMENTS_FILE        = os.path.join(DATA_DIR, "mobile_payments.json")
SCHOOLS_FILE                = os.path.join(DATA_DIR, "schools_registry.json")
ATTENDANCE_FILE             = os.path.join(DATA_DIR, "attendance_records.json")
MESSAGES_FILE                = os.path.join(DATA_DIR, "parent_messages.json")
PENDING_REGISTRATIONS_FILE  = os.path.join(DATA_DIR, "pending_registrations.json")
PENDING_AUTRES_FRAIS_FILE   = os.path.join(DATA_DIR, "pending_autres_frais.json")
SUBSCRIPTION_KEYS_FILE      = os.path.join(DATA_DIR, "subscription_keys.json")
PROMOTER_SUMMARY_FILE       = os.path.join(DATA_DIR, "promoter_summary.json")
PROMOTER_PENDING_REQUESTS_FILE  = os.path.join(DATA_DIR, "promoter_pending_requests.json")
PROMOTER_RESOLVED_REQUESTS_FILE = os.path.join(DATA_DIR, "promoter_resolved_requests.json")
FCM_TOKENS_FILE             = os.path.join(DATA_DIR, "fcm_tokens.json")

ADMIN_PASSWORD = "edupay_admin_2026"

AIRTEL_MERCHANT_ID  = os.environ.get('AIRTEL_MERCHANT_ID', '')
AIRTEL_API_KEY      = os.environ.get('AIRTEL_API_KEY', '')
ORANGE_MERCHANT_ID  = os.environ.get('ORANGE_MERCHANT_ID', '')
ORANGE_API_KEY      = os.environ.get('ORANGE_API_KEY', '')
VODACOM_MERCHANT_ID = os.environ.get('VODACOM_MERCHANT_ID', '')
VODACOM_API_KEY     = os.environ.get('VODACOM_API_KEY', '')

SUBSCRIPTION_TEST_MODE = False
SUBSCRIPTION_DURATION_SECONDS = 60 if SUBSCRIPTION_TEST_MODE else 30 * 24 * 60 * 60

MONTHS = [
    'Septembre', 'Octobre', 'Novembre', 'Decembre',
    'Janvier', 'Fevrier', 'Mars', 'Avril', 'Mai', 'Juin'
]

KEY_TYPES = {'PAY', 'DISC', 'INSC', 'AFR'}

SYSTEM_FILES = {
    'keys_store.json', 'ids_store.json',
    'pending_payments.json', 'mobile_payments.json',
    'schools_registry.json',
    'attendance_records.json', 'parent_messages.json',
    'pending_registrations.json', 'pending_autres_frais.json',
    'subscription_keys.json',
    'promoter_summary.json', 'promoter_pending_requests.json',
    'promoter_resolved_requests.json',
    'fcm_tokens.json',
}

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s %(name)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    stream=sys.stdout,
)
logger = logging.getLogger("edupay")


# ====================================================================
# FIREBASE ADMIN SDK — initialisation et notifications FCM
# ====================================================================

_firebase_app = None


def _init_firebase():
    """Initialise Firebase Admin SDK à partir de la variable d'environnement
    FIREBASE_SERVICE_ACCOUNT (JSON du compte de service). Ne jamais logguer
    le contenu de cette variable. N'échoue pas le démarrage du serveur si
    la variable est absente ou invalide : les notifications seront alors
    simplement désactivées (les autres fonctionnalités continuent de marcher)."""
    global _firebase_app
    raw = os.environ.get('FIREBASE_SERVICE_ACCOUNT', '')
    if not raw:
        logger.warning(
            "⚠️ FIREBASE_SERVICE_ACCOUNT absente : les notifications FCM "
            "sont désactivées."
        )
        return None
    try:
        service_account_info = json.loads(raw)
        cred = credentials.Certificate(service_account_info)
        _firebase_app = firebase_admin.initialize_app(cred)
        logger.info("✅ Firebase Admin SDK initialisé avec succès.")
        return _firebase_app
    except Exception as e:
        logger.error(
            "❌ Erreur d'initialisation de Firebase Admin SDK "
            "(vérifiez le format JSON de FIREBASE_SERVICE_ACCOUNT) : %s", e
        )
        return None


def _firebase_ready():
    return _firebase_app is not None


def _load_json(path, default):
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return default


def _save_json(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


# ====================================================================
# ⚡ NOUVEAU — ANTI-DOUBLONS DE TRANSACTIONS
# ====================================================================
# Cause du bug "le montant se multiplie à chaque clic sur Récupérer" :
# l'application fusionne les transactions locales et celles du serveur.
# Les transactions SANS 'id' ne peuvent jamais être reconnues comme
# doublons côté application, donc elles s'ajoutaient à chaque
# récupération. Solution côté serveur : toute transaction sans 'id'
# reçoit un id STABLE (déterministe : toujours le même pour la même
# transaction du même élève), et les doublons exacts sont supprimés.
# ====================================================================

def _tx_signature(t):
    try:
        amount = float(t.get('amount', 0) or 0)
    except (TypeError, ValueError):
        amount = 0.0
    return f"{t.get('date', '')}|{t.get('mois', '')}|{amount:.2f}"


def _stable_legacy_tx_id(eleve_id, signature):
    raw = f"{eleve_id}|{signature}".encode('utf-8')
    return "LEG_" + hashlib.sha1(raw).hexdigest()[:16]


def _normalize_eleve_transactions(eleve):
    """Dédoublonne les transactions d'un élève et donne un id stable à
    celles qui n'en ont pas. Si des doublons ont été supprimés, 'paid'
    est reconstruit à partir des transactions restantes.
    Retourne le nombre de doublons supprimés."""
    txs = eleve.get('transactions')
    if not isinstance(txs, list) or not txs:
        return 0

    eleve_id = str(eleve.get('id', ''))
    seen_ids = set()
    leg_sigs = set()
    result = []
    removed = 0
    modified = False

    for t in txs:
        if not isinstance(t, dict):
            result.append(t)
            continue
        tid = str(t.get('id') or '').strip()
        if tid:
            if tid in seen_ids:
                removed += 1
                continue
            seen_ids.add(tid)
            if tid.startswith('LEG_'):
                leg_sigs.add(_tx_signature(t))
            result.append(t)
        else:
            sig = _tx_signature(t)
            if sig in leg_sigs:
                removed += 1
                continue
            new_id = _stable_legacy_tx_id(eleve_id, sig)
            if new_id in seen_ids:
                removed += 1
                continue
            t['id'] = new_id
            seen_ids.add(new_id)
            leg_sigs.add(sig)
            modified = True
            result.append(t)

    if removed > 0 or modified:
        eleve['transactions'] = result

    if removed > 0:
        paid = {}
        for t in result:
            if not isinstance(t, dict):
                continue
            mois = str(t.get('mois', '') or '')
            if not mois:
                continue
            try:
                amount = float(t.get('amount', 0) or 0)
            except (TypeError, ValueError):
                amount = 0.0
            paid[mois] = paid.get(mois, 0) + amount
        eleve['paid'] = paid

    return removed


def _normalize_school_data(data):
    """Applique la normalisation à tous les élèves (années + archive des
    élèves supprimés). Retourne le total de doublons supprimés."""
    total_removed = 0
    if not isinstance(data, dict):
        return 0

    for yd in (data.get('history') or {}).values():
        if not isinstance(yd, dict):
            continue
        for e in yd.get('eleves', []) or []:
            if isinstance(e, dict):
                total_removed += _normalize_eleve_transactions(e)

    archive = data.get('elevesSupprimesData')
    if isinstance(archive, dict):
        for e in archive.get('eleves', []) or []:
            if isinstance(e, dict):
                total_removed += _normalize_eleve_transactions(e)

    return total_removed


def _fcm_tokens_key(school_code):
    return school_code.strip().lower()


def register_fcm_token(school_code, role, token, platform):
    """Enregistre (ou met à jour) un token FCM pour une école/role donnés.
    Un même token ne sera jamais dupliqué dans la liste."""
    if not school_code or not token:
        return False

    store       = _load_json(FCM_TOKENS_FILE, {})
    school_key  = _fcm_tokens_key(school_code)
    tokens_list = store.get(school_key, [])

    now_iso = datetime.datetime.now().isoformat()

    tokens_list = [t for t in tokens_list if t.get('token') != token]

    tokens_list.append({
        "token":        token,
        "role":         role or "unknown",
        "platform":     platform or "unknown",
        "updated_at":   now_iso,
    })

    store[school_key] = tokens_list
    _save_json(FCM_TOKENS_FILE, store)

    logger.info(
        "📱 register_fcm_token : école='%s' role='%s' plateforme='%s'",
        school_code, role, platform,
    )
    return True


def _get_tokens_for_role(school_code, role=None):
    store       = _load_json(FCM_TOKENS_FILE, {})
    school_key  = _fcm_tokens_key(school_code)
    tokens_list = store.get(school_key, [])
    if role is None:
        return [t.get('token') for t in tokens_list if t.get('token')]
    return [
        t.get('token') for t in tokens_list
        if t.get('token') and t.get('role') == role
    ]


def _remove_invalid_tokens(school_code, invalid_tokens):
    if not invalid_tokens:
        return
    store       = _load_json(FCM_TOKENS_FILE, {})
    school_key  = _fcm_tokens_key(school_code)
    tokens_list = store.get(school_key, [])
    before      = len(tokens_list)
    tokens_list = [
        t for t in tokens_list if t.get('token') not in invalid_tokens
    ]
    store[school_key] = tokens_list
    _save_json(FCM_TOKENS_FILE, store)
    removed = before - len(tokens_list)
    if removed:
        logger.info(
            "🧹 %d token(s) FCM invalide(s)/expiré(s) retiré(s) pour l'école '%s'",
            removed, school_code,
        )


def send_fcm_to_tokens(tokens, title, body, data=None):
    """Envoie une notification FCM à une liste de tokens. Retourne la liste
    des tokens invalides/expirés détectés (à retirer par l'appelant)."""
    if not _firebase_ready() or not tokens:
        return []

    data_payload = {k: str(v) for k, v in (data or {}).items()}
    invalid_tokens = []

    batch_size = 500
    for i in range(0, len(tokens), batch_size):
        batch = tokens[i:i + batch_size]
        message = messaging.MulticastMessage(
            notification=messaging.Notification(title=title, body=body),
            data=data_payload,
            tokens=batch,
        )
        try:
            response = messaging.send_each_for_multicast(message)
        except Exception as e:
            logger.error("❌ Erreur d'envoi FCM (batch) : %s", e)
            continue

        for idx, result in enumerate(response.responses):
            if result.success:
                continue
            error = result.exception
            code = getattr(error, 'code', '') or ''
            msg  = str(error)
            if ('UNREGISTERED' in msg or 'NOT_FOUND' in msg or
                    'INVALID_ARGUMENT' in msg or code in
                    ('NOT_FOUND', 'UNREGISTERED', 'INVALID_ARGUMENT')):
                invalid_tokens.append(batch[idx])
            else:
                logger.warning(
                    "⚠️ Échec d'envoi FCM pour un token (non retiré) : %s", msg
                )

    return invalid_tokens


def notify_school_role(school_code, role, title, body, data=None):
    """Fonction centrale : envoie une notification FCM à tous les
    appareils enregistrés pour une école + un rôle donnés (ex: 'promoteur').
    Nettoie automatiquement les tokens invalides après l'envoi."""
    if not school_code:
        return
    tokens = _get_tokens_for_role(school_code, role)
    if not tokens:
        return
    invalid = send_fcm_to_tokens(tokens, title, body, data)
    if invalid:
        _remove_invalid_tokens(school_code, invalid)


def notify_multiple_schools(school_codes, role, title, body, data=None):
    """Envoie la même notification à plusieurs écoles (même rôle) —
    utile par exemple pour une annonce générale EduPay."""
    for sc in school_codes:
        notify_school_role(sc, role, title, body, data)


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
                "⚠️ Aucun fichier école trouvé au démarrage. Vérifiez que "
                "le disque persistant Render est bien attaché et monté."
            )
    except Exception as e:
        logger.error("Erreur lors du log de démarrage : %s", e)


_init_firebase()
_log_startup_state()


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


def _find_in_schools_dict(schools, school_code):
    if not school_code:
        return None, None
    target = school_code.strip().upper()
    for code, school in schools.items():
        if code.upper() == target:
            return code, school
    return None, None


def _find_school_entry(school_code):
    if not school_code:
        return None, None
    schools = _load_json(SCHOOLS_FILE, {})
    return _find_in_schools_dict(schools, school_code)


def _register_orphan_school_file(school_code, fpath=None):
    if not school_code:
        return False

    schools = _load_json(SCHOOLS_FILE, {})
    _, existing = _find_in_schools_dict(schools, school_code)
    if existing is not None:
        return False

    if fpath is None:
        fpath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
    if not os.path.exists(fpath):
        return False

    try:
        with open(fpath, 'r', encoding='utf-8') as f:
            school_data = json.load(f)
    except Exception as e:
        logger.error(
            "_register_orphan_school_file : fichier illisible '%s' : %s",
            fpath, e,
        )
        return False

    config = school_data.get('config', {})
    reg_id = _generate_registration_id()
    all_reg_ids = {s.get('registration_id') for s in schools.values()}
    while reg_id in all_reg_ids:
        reg_id = _generate_registration_id()

    try:
        mtime = datetime.datetime.fromtimestamp(
            os.path.getmtime(fpath)).isoformat()
    except Exception:
        mtime = datetime.datetime.now().isoformat()

    code_upper = school_code.strip().upper()
    schools[code_upper] = {
        "school_code":     code_upper,
        "school_name":     config.get('schoolName', code_upper),
        "city":            config.get('city', ''),
        "address":         '',
        "director":        config.get('director', ''),
        "phone":           config.get('phone', ''),
        "email":           config.get('email', ''),
        "bank_name":       config.get('bankName', ''),
        "bank_account":    config.get('bankAccount', ''),
        "bank_branch":     config.get('bankBranch', ''),
        "registration_id": reg_id,
        "activated":       True,
        "registered_at":   mtime,
        "activated_at":    mtime,
        "subscription_started_at": None,
        "subscription_expires_at": None,
        "subscription_blocked":    False,
        "recovered":       True,
    }
    _save_json(SCHOOLS_FILE, schools)
    logger.warning(
        "🩹 École orpheline réenregistrée automatiquement : code='%s' "
        "nom='%s' (source='%s')",
        code_upper, schools[code_upper]['school_name'], fpath,
    )
    return True


def _sync_orphan_schools():
    try:
        nb_reparees = 0
        for fname in os.listdir(DATA_DIR):
            if not fname.endswith('.json') or fname in SYSTEM_FILES:
                continue
            school_code = fname[:-5]
            fpath = os.path.join(DATA_DIR, fname)
            if _register_orphan_school_file(school_code, fpath):
                nb_reparees += 1
        if nb_reparees:
            logger.info(
                "🩹 _sync_orphan_schools : %d école(s) réparée(s).",
                nb_reparees,
            )
    except Exception:
        logger.exception("Erreur _sync_orphan_schools")


def _generate_reconnection_key_str():
    chars  = string.ascii_uppercase + string.digits
    groups = [''.join(secrets.choice(chars) for _ in range(4)) for _ in range(3)]
    return f"RECO-{'-'.join(groups)}"


def _start_new_subscription_period(school):
    now     = datetime.datetime.now()
    expires = now + datetime.timedelta(seconds=SUBSCRIPTION_DURATION_SECONDS)
    school['subscription_started_at'] = now.isoformat()
    school['subscription_expires_at'] = expires.isoformat()
    school['subscription_blocked']    = False
    return school


def _compute_subscription_status(school):
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


@app.after_request
def _add_cors_headers(response):
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
    response.headers['Access-Control-Max-Age'] = '86400'
    return response


@app.before_request
def _log_incoming_request():
    logger.info(
        "→ %s %s | IP=%s",
        request.method, request.path, request.remote_addr,
    )


_WEB_DIR = os.path.dirname(os.path.abspath(__file__))


@app.route('/parent.html', methods=['GET'])
def serve_parent_html():
    return send_from_directory(_WEB_DIR, 'parent.html')


@app.route('/parent', methods=['GET'])
def serve_parent_html_alias():
    return send_from_directory(_WEB_DIR, 'parent.html')


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
                    return jsonify({
                        "valid":       False,
                        "already_used": True,
                        "school_code": school_code,
                        "school_name": school.get('school_name'),
                        "error":       "Cet ID a déjà été utilisé.",
                    }), 200
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
                return jsonify({
                    "found":        True,
                    "school_code":  school_code,
                    "school_name":  school.get('school_name'),
                    "activated":    school.get('activated', False),
                }), 200

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
                    return jsonify({"error": "Cet ID a déjà été utilisé."}), 400
                target_code = sc
                break

        if not target_code:
            return jsonify({"error": "ID invalide"}), 404

        schools[target_code]['activated']    = True
        schools[target_code]['activated_at'] = datetime.datetime.now().isoformat()
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
        return jsonify({
            "message":     "Compte activé avec succès. Bienvenue sur EduPay !",
            "school_code": target_code,
            "school_name": final_name,
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

        _sync_orphan_schools()

        schools = _load_json(SCHOOLS_FILE, {})
        summary = [{
            "school_code":   sc,
            "school_name":   s.get('school_name'),
            "city":          s.get('city'),
            "director":      s.get('director'),
            "activated":     s.get('activated', False),
            "registered_at": s.get('registered_at'),
            "activated_at":  s.get('activated_at'),
            "subscription":  _compute_subscription_status(s),
            "recovered":     s.get('recovered', False),
        } for sc, s in schools.items()]
        return jsonify({"schools": summary, "total": len(summary)}), 200
    except Exception as e:
        logger.exception("Erreur list_schools")
        return jsonify({"error": str(e)}), 500


@app.route('/backup', methods=['POST'])
def backup():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        backup_data = data.get('data')
        if not school_code or not backup_data:
            return jsonify({"error": "Données invalides"}), 400

        # ⚡ NOUVEAU — nettoyage des doublons de transactions avant stockage
        removed = _normalize_school_data(backup_data)
        if removed:
            logger.warning(
                "🧹 backup : école='%s' → %d transaction(s) en double "
                "supprimée(s) avant enregistrement.", school_code, removed,
            )

        corrected_data, corrections = _resolve_id_conflicts(
            school_code, backup_data)

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(corrected_data, f, ensure_ascii=False, indent=2)

        if _register_orphan_school_file(school_code, filepath):
            logger.info(
                "🩹 backup : école='%s' réintégrée au registre.",
                school_code,
            )

        _, school_entry = _find_school_entry(school_code)
        return jsonify({
            "message":      "Sauvegarde réussie",
            "school_code":  school_code,
            "corrections":  corrections,
            "subscription": _compute_subscription_status(school_entry),
        }), 200
    except Exception as e:
        logger.exception("❌ Erreur lors du BACKUP")
        return jsonify({"error": str(e)}), 500


@app.route('/restore', methods=['GET'])
def restore():
    school_code = request.args.get('school_code')
    if not school_code:
        return jsonify({"error": "Code manquant"}), 400
    filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
    if os.path.exists(filepath):
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)

        # ⚡ NOUVEAU — on s'assure que toutes les transactions ont un id
        # stable et qu'il n'y a aucun doublon : la récupération devient
        # idempotente (cliquer 10 fois = même résultat que 1 fois).
        removed = _normalize_school_data(data)
        try:
            _save_json(filepath, data)
        except Exception:
            logger.exception("restore : impossible de réécrire le fichier nettoyé")
        if removed:
            logger.warning(
                "🧹 restore : école='%s' → %d doublon(s) supprimé(s).",
                school_code, removed,
            )

        data.pop('backup_password', None)
        _, school_entry = _find_school_entry(school_code)
        data['subscription'] = _compute_subscription_status(school_entry)
        return jsonify(data), 200
    return jsonify({"error": "Aucune sauvegarde trouvée"}), 404


@app.route('/admin/clean_duplicate_transactions', methods=['POST'])
def admin_clean_duplicate_transactions():
    """À appeler UNE FOIS pour réparer toutes les écoles déjà corrompues
    (montants multipliés). Body JSON : {"admin_password": "..."}"""
    try:
        data = request.get_json()
        if data.get('admin_password') != ADMIN_PASSWORD:
            return jsonify({"error": "Accès refusé"}), 401

        report = []
        for fname in sorted(os.listdir(DATA_DIR)):
            if not fname.endswith('.json') or fname in SYSTEM_FILES:
                continue
            fpath = os.path.join(DATA_DIR, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    school_data = json.load(f)
                removed = _normalize_school_data(school_data)
                _save_json(fpath, school_data)
                report.append({"fichier": fname, "doublons_supprimes": removed})
            except Exception as e:
                report.append({"fichier": fname, "erreur": str(e)})

        return jsonify({"rapport": report, "total_fichiers": len(report)}), 200
    except Exception as e:
        logger.exception("Erreur admin_clean_duplicate_transactions")
        return jsonify({"error": str(e)}), 500


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
            # ⚡ NOUVEAU — id stable pour éviter tout doublon côté application
            eleve['transactions'].append({
                'id':           f"SRV_{entry.get('id')}",
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
        return jsonify({"message": "Paiement rejeté"}), 200
    except Exception as e:
        logger.exception("Erreur reject_payment")
        return jsonify({"error": str(e)}), 500


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
            return jsonify({"found": False, "error": "ID manquant"}), 400

        fichiers_ecoles = [
            f for f in os.listdir(DATA_DIR)
            if f.endswith('.json') and f not in SYSTEM_FILES
        ]

        for fname in fichiers_ecoles:
            fpath = os.path.join(DATA_DIR, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    data = json.load(f)
            except Exception:
                continue

            school_code  = fname.replace('.json', '').upper()
            school_name  = data.get('config', {}).get('schoolName', school_code)
            current_year = data.get('currentYear', '')
            config       = data.get('config', {})

            for yd in data.get('history', {}).values():
                for e in yd.get('eleves', []):
                    if e.get('id', '').upper() == student_id:
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

        filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)

        config       = data.get('config', {})
        current_year = data.get('currentYear', '')
        year_data    = data.get('history', {}).get(current_year, {})

        for e in year_data.get('eleves', []):
            if e.get('id', '').upper() == student_id:
                return jsonify({
                    "paid":               e.get('paid', {}),
                    "transactions":       e.get('transactions', []),
                    "fees_by_section":    config.get('feesBySection', {}),
                    "monthly_exceptions": config.get('monthlyExceptionsBySection', {}),
                    "fees_by_classe":     config.get('feesByClasse', {}),
                    "current_year":       current_year,
                }), 200

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

        if not student_id or not school_code:
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

        notify_school_role(
            school_code, "promoteur",
            "Nouveau paiement Mobile Money",
            f"{eleve.get('nom','')} {eleve.get('postNom','')} — "
            f"{total_sent:.0f} FC en attente de confirmation ({network}).",
            data={"type": "mobile_payment", "school_code": school_code},
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
            # ⚡ NOUVEAU — id stable pour éviter tout doublon côté application
            eleve['transactions'].append({
                'id':          f"SRV_{entry.get('id')}",
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

        return jsonify({
            "message":         "Paiements confirmés",
            "confirmed_count": confirmed_count,
            "remaining":       len(remaining),
        }), 200
    except Exception as e:
        logger.exception("Erreur confirm_mobile_payments")
        return jsonify({"error": str(e)}), 500


@app.route('/webhook/airtel', methods=['POST'])
def webhook_airtel():
    data = request.get_json()
    if data.get('status') != 'SUCCESS':
        return jsonify({"ok": True}), 200
    ref   = data.get('transaction', {}).get('id', '')
    parts = ref.replace('EDU_', '').split('_')
    if len(parts) >= 2:
        _auto_confirm_payment(
            parts[0], parts[1],
            float(data.get('transaction', {}).get('amount', 0)),
            'airtel',
            ref,
        )
    return jsonify({"ok": True}), 200


@app.route('/webhook/orange', methods=['POST'])
def webhook_orange():
    return jsonify({"ok": True}), 200


@app.route('/webhook/vodacom', methods=['POST'])
def webhook_vodacom():
    return jsonify({"ok": True}), 200


def _auto_confirm_payment(eleve_id, mois, amount, network, tx_ref=''):
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

            # ⚡ NOUVEAU — id stable + protection contre un webhook rejoué
            tx_id = (f"SRV_AUTO_{tx_ref}" if tx_ref
                     else f"SRV_AUTO_{os.urandom(6).hex()}")
            e.setdefault('transactions', [])
            if any(t.get('id') == tx_id for t in e['transactions']):
                return

            e.setdefault('paid', {})
            e['paid'][mois] = e['paid'].get(mois, 0) + amount
            e['transactions'].append({
                'id':          tx_id,
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
            return


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
                _, school_entry = _find_school_entry(school_code)
                subscription = _compute_subscription_status(school_entry)
                return jsonify({
                    "valid":        True,
                    "subscription": subscription,
                    "school_name": saved_data.get('config', {}).get('schoolName', school_code),
                }), 200
            return jsonify({
                "valid": False, "error": "Mot de passe incorrect"
            }), 401
        return jsonify({"error": "Aucune sauvegarde trouvée"}), 404
    except Exception as e:
        logger.exception("Erreur verify_password")
        return jsonify({"error": str(e)}), 500


@app.route('/school/check_subscription', methods=['GET'])
def check_subscription():
    try:
        school_code = request.args.get('school_code', '').strip()
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        _, school = _find_school_entry(school_code)
        if not school:
            return jsonify({"error": "École introuvable"}), 404
        status = _compute_subscription_status(school)
        return jsonify(status), 200
    except Exception as e:
        logger.exception("Erreur check_subscription")
        return jsonify({"error": str(e)}), 500


@app.route('/admin/generate_reconnection_key', methods=['POST'])
def generate_reconnection_key():
    try:
        data = request.get_json()
        if data.get('admin_password') != ADMIN_PASSWORD:
            return jsonify({"error": "Mot de passe admin incorrect"}), 401

        school_code = (data.get('school_code') or '').strip()
        if not school_code:
            return jsonify({"error": "Code école manquant"}), 400

        real_code, school = _find_school_entry(school_code)
        if not school:
            return jsonify({"error": "École introuvable"}), 404

        key = _generate_reconnection_key_str()
        keys_store      = _load_json(SUBSCRIPTION_KEYS_FILE, {})
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
            return jsonify({"error": "Clé de reconnexion invalide"}), 404

        if key_info.get('used'):
            return jsonify({"error": "Cette clé a déjà été utilisée"}), 400

        if key_info.get('school_code', '').upper() != real_code.upper():
            return jsonify({
                "error": "Cette clé ne correspond pas à cette école"
            }), 400

        schools = _load_json(SCHOOLS_FILE, {})
        _start_new_subscription_period(schools[real_code])
        _save_json(SCHOOLS_FILE, schools)

        key_info['used']    = True
        key_info['used_at'] = datetime.datetime.now().isoformat()
        keys_store[key]     = key_info
        _save_json(SUBSCRIPTION_KEYS_FILE, keys_store)

        return jsonify({
            "message":    "Abonnement réactivé avec succès",
            "expires_at": schools[real_code].get('subscription_expires_at'),
        }), 200
    except Exception as e:
        logger.exception("Erreur redeem_reconnection_key")
        return jsonify({"error": str(e)}), 500


@app.route('/admin/list_reconnection_keys', methods=['POST'])
def list_reconnection_keys():
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


def _key_sections(info):
    if info.get('sections'):
        return list(info['sections'])
    single = info.get('section')
    return [single] if single else []


def _slug(value, max_len=12):
    cleaned = re.sub(r'[^A-Za-z0-9]', '', value or '')
    return cleaned.upper()[:max_len] if cleaned else "ALL"


def _sections_slug(sections):
    if not sections:
        return "ALL"
    parts = [s.upper()[:3] for s in sections if s]
    joined = '+'.join(parts)
    return joined[:24] if joined else "ALL"


@app.route('/generate_key', methods=['POST'])
def generate_key():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')

        sections_raw = data.get('sections')
        if sections_raw is None:
            single_section = data.get('section')
            sections_raw = [single_section] if single_section else []
        sections = [s.strip() for s in sections_raw if s and s.strip()]
        seen = set()
        sections = [s for s in sections if not (s in seen or seen.add(s))]

        key_type = (data.get('type') or 'PAY').strip().upper()

        classe = (data.get('classe') or '').strip()
        if len(sections) != 1:
            classe = ''

        if not school_code or not sections:
            return jsonify({
                "error": "École et au moins une section sont requis"
            }), 400

        if key_type not in KEY_TYPES:
            return jsonify({
                "error": f"Type de clé invalide. Valeurs possibles : "
                         f"{', '.join(sorted(KEY_TYPES))}"
            }), 400

        try:
            duration_value = int(data.get('duration_value', 30))
        except (TypeError, ValueError):
            duration_value = 30
        if duration_value < 1:
            duration_value = 1
        duration_unit = (data.get('duration_unit') or 'days').strip().lower()
        if duration_unit != 'minutes':
            duration_unit = 'days'

        key = (
            f"{school_code.upper()}*{key_type}*{_sections_slug(sections)}"
            f"*{_slug(classe)}*{os.urandom(4).hex()}"
        )
        keys      = _load_json(KEYS_FILE, {})
        keys[key] = {
            "school_code": school_code,
            "sections":    sections,
            "section":     sections[0],
            "type":        key_type,
            "classe":      classe if classe else None,
            "durationValue": duration_value,
            "durationUnit":  duration_unit,
        }
        _save_json(KEYS_FILE, keys)
        return jsonify({
            "key":      key,
            "sections": sections,
            "section":  sections[0],
            "type":     key_type,
            "classe":   classe or None,
            "duration_value": duration_value,
            "duration_unit":  duration_unit,
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
            return jsonify({"valid": False, "error": "Clé invalide"}), 404
        school_code  = info["school_code"]
        sections     = _key_sections(info)
        filepath     = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
        school_name  = school_code
        current_year = None
        if os.path.exists(filepath):
            with open(filepath, 'r', encoding='utf-8') as f:
                saved = json.load(f)
            school_name  = saved.get('config', {}).get('schoolName', school_code)
            current_year = saved.get('currentYear')

        duration_value = info.get('durationValue', 30)
        duration_unit  = info.get('durationUnit', 'days')

        return jsonify({
            "valid":        True,
            "school_code":  school_code,
            "sections":     sections,
            "section":      sections[0] if sections else None,
            "type":         info.get("type", "PAY"),
            "classe":       info.get("classe") if len(sections) == 1 else None,
            "school_name":  school_name,
            "current_year": current_year,
            "duration_value": duration_value,
            "duration_unit":  duration_unit,
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
        return jsonify({"message": "Clé révoquée"}), 200
    except Exception as e:
        logger.exception("Erreur revoke_key")
        return jsonify({"error": str(e)}), 500


@app.route('/list_keys', methods=['GET'])
def list_keys():
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        keys   = _load_json(KEYS_FILE, {})
        result = [
            {
                "key":      k,
                "type":     v.get("type", "PAY"),
                "sections": _key_sections(v),
                "classe":   v.get("classe"),
                "durationValue": v.get("durationValue", 30),
                "durationUnit":  v.get("durationUnit", "days"),
            }
            for k, v in keys.items()
            if v.get("school_code") == school_code
        ]
        return jsonify({"keys": result, "total": len(result)}), 200
    except Exception as e:
        logger.exception("Erreur list_keys")
        return jsonify({"error": str(e)}), 500


def _generate_student_id_for_school(school_code, nom, year, school_name, proposed_id=None):
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
        return jsonify({"id": candidate}), 200
    except Exception as e:
        logger.exception("Erreur generate_student_id")
        return jsonify({"error": str(e)}), 500


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
        return jsonify({"message": "Inscription rejetée"}), 200
    except Exception as e:
        logger.exception("Erreur reject_registration")
        return jsonify({"error": str(e)}), 500


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
            # ⚡ NOUVEAU — on évite d'ajouter deux fois le même paiement (même id)
            if any(p.get('id') == entry.get('id')
                   for p in saved['autresFraisPaiementsByYear'][annee]):
                continue
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


def _new_message_id():
    return f"msg_{datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')}_{os.urandom(3).hex()}"


def _add_message_for_student(school_code, student_id, msg_type, title, message, extra=None):
    messages_store = _load_json(MESSAGES_FILE, {})
    school_key     = school_code.lower()
    msg_list       = messages_store.get(school_key, [])
    entry = {
        "id":         _new_message_id(),
        "type":       msg_type,
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

        if sent:
            notify_school_role(
                school_code, "promoteur",
                "Absences enregistrées",
                f"{len(sent)} élève(s) marqué(s) absent(s) — {classe or 'toutes classes'}.",
                data={"type": "absences", "school_code": school_code},
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

        notify_school_role(
            school_code, "promoteur",
            "Convocation envoyée",
            f"{title} — élève {student_id}.",
            data={"type": "convocation", "school_code": school_code},
        )

        return jsonify({"message": "Convocation envoyée", "id": entry["id"]}), 200
    except Exception as e:
        logger.exception("Erreur send_convocation")
        return jsonify({"error": str(e)}), 500


@app.route('/school/send_announcement', methods=['POST'])
def send_announcement():
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
        sections    = data.get('sections') or ([section] if section else [])

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
        elif target == 'sections':
            targeted = [e for e in eleves if e.get('section') in sections]
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

        if sent:
            notify_school_role(
                school_code, "promoteur",
                "Communiqué envoyé",
                f"\"{title}\" envoyé à {len(sent)} élève(s).",
                data={"type": "announcement", "school_code": school_code},
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
# ROUTES PROMOTEUR — résumé après sauvegarde + demandes d'approbation
# ====================================================================

@app.route('/school/register_fcm_token', methods=['POST'])
def school_register_fcm_token():
    """Appelée par l'application Flutter (promoteur, ou plus tard toute
    autre app) après avoir récupéré/rafraîchi son token FCM."""
    try:
        data        = request.get_json()
        school_code = (data.get('school_code') or '').strip()
        role        = (data.get('role') or 'promoteur').strip()
        token       = (data.get('token') or '').strip()
        platform    = (data.get('platform') or '').strip()

        if not school_code or not token:
            return jsonify({"error": "Données manquantes"}), 400

        ok = register_fcm_token(school_code, role, token, platform)
        if not ok:
            return jsonify({"error": "Échec de l'enregistrement du token"}), 500

        return jsonify({"message": "Token FCM enregistré"}), 200
    except Exception as e:
        logger.exception("Erreur school_register_fcm_token")
        return jsonify({"error": str(e)}), 500


@app.route('/school/push_promoter_summary', methods=['POST'])
def push_promoter_summary():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        summary     = data.get('summary')
        if not school_code or summary is None:
            return jsonify({"error": "Données manquantes"}), 400
        store = _load_json(PROMOTER_SUMMARY_FILE, {})
        summary['updated_at'] = datetime.datetime.now().isoformat()
        store[school_code.lower()] = summary
        _save_json(PROMOTER_SUMMARY_FILE, store)
        logger.info("push_promoter_summary : école='%s' résumé mis à jour", school_code)

        money_today = summary.get('moneyToday')
        body = "Le tableau de bord vient d'être mis à jour."
        if isinstance(money_today, (int, float)):
            body = f"Argent aujourd'hui : {money_today:,.0f} FC — données mises à jour.".replace(',', ' ')
        notify_school_role(
            school_code, "promoteur",
            "Nouvelles données disponibles",
            body,
            data={"type": "summary_update", "school_code": school_code},
        )

        return jsonify({"message": "Résumé mis à jour"}), 200
    except Exception as e:
        logger.exception("Erreur push_promoter_summary")
        return jsonify({"error": str(e)}), 500


@app.route('/school/get_promoter_summary', methods=['GET'])
def get_promoter_summary():
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        store = _load_json(PROMOTER_SUMMARY_FILE, {})
        summary = store.get(school_code.lower())
        return jsonify({"summary": summary}), 200
    except Exception as e:
        logger.exception("Erreur get_promoter_summary")
        return jsonify({"error": str(e)}), 500


def _new_promoter_request_id():
    return f"preq_{datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')}_{os.urandom(3).hex()}"


_PROMOTER_REQUEST_TYPE_LABELS = {
    "reprint": "Demande de réimpression de reçu",
    "modify":  "Demande de modification de paiement",
    "cancel":  "Demande d'annulation de paiement",
}


@app.route('/school/create_promoter_request', methods=['POST'])
def create_promoter_request():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        req_type    = data.get('type')
        if not school_code or req_type not in ('reprint', 'modify', 'cancel'):
            return jsonify({"error": "Données invalides"}), 400

        request_id = _new_promoter_request_id()
        eleve_nom  = data.get('eleve_nom', '')
        mois       = data.get('mois', '')
        entry = {
            "id":              request_id,
            "type":            req_type,
            "eleve_id":        data.get('eleve_id', ''),
            "eleve_nom":       eleve_nom,
            "classe":          data.get('classe', ''),
            "section":         data.get('section', ''),
            "mois":            mois,
            "transaction_id":  data.get('transaction_id', ''),
            "montant_actuel":  data.get('montant_actuel'),
            "nouveau_montant": data.get('nouveau_montant'),
            "status":          "pending",
            "created_at":      datetime.datetime.now().isoformat(),
        }

        school_key   = school_code.lower()
        store        = _load_json(PROMOTER_PENDING_REQUESTS_FILE, {})
        pending_list = store.get(school_key, [])
        pending_list.append(entry)
        store[school_key] = pending_list
        _save_json(PROMOTER_PENDING_REQUESTS_FILE, store)

        logger.info(
            "📨 create_promoter_request : école='%s' type='%s' id='%s'",
            school_code, req_type, request_id,
        )

        title = _PROMOTER_REQUEST_TYPE_LABELS.get(req_type, "Nouvelle demande")
        body_parts = []
        if eleve_nom:
            body_parts.append(eleve_nom)
        if mois:
            body_parts.append(mois)
        if req_type == 'modify' and data.get('nouveau_montant') is not None:
            body_parts.append(f"→ {data.get('nouveau_montant'):.0f} FC")
        body = " — ".join(str(p) for p in body_parts) or "Confirmation requise."

        notify_school_role(
            school_code, "promoteur",
            title,
            body,
            data={
                "type":       "promoter_request",
                "request_id": request_id,
                "request_type": req_type,
                "school_code": school_code,
            },
        )

        return jsonify({"request_id": request_id}), 200
    except Exception as e:
        logger.exception("Erreur create_promoter_request")
        return jsonify({"error": str(e)}), 500


@app.route('/school/get_promoter_requests', methods=['GET'])
def get_promoter_requests():
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        store        = _load_json(PROMOTER_PENDING_REQUESTS_FILE, {})
        pending_list = store.get(school_code.lower(), [])
        pending_list.sort(key=lambda r: r.get('created_at', ''), reverse=True)
        return jsonify({"requests": pending_list, "total": len(pending_list)}), 200
    except Exception as e:
        logger.exception("Erreur get_promoter_requests")
        return jsonify({"error": str(e)}), 500


@app.route('/school/resolve_promoter_request', methods=['POST'])
def resolve_promoter_request():
    try:
        data        = request.get_json()
        school_code = data.get('school_code')
        request_id  = data.get('request_id')
        action      = data.get('action')
        if not school_code or not request_id or action not in ('approve', 'reject'):
            return jsonify({"error": "Données invalides"}), 400

        school_key    = school_code.lower()
        pending_store = _load_json(PROMOTER_PENDING_REQUESTS_FILE, {})
        pending_list  = pending_store.get(school_key, [])

        target = next((r for r in pending_list if r.get('id') == request_id), None)
        if target is None:
            return jsonify({"error": "Demande introuvable"}), 404

        pending_list = [r for r in pending_list if r.get('id') != request_id]
        pending_store[school_key] = pending_list
        _save_json(PROMOTER_PENDING_REQUESTS_FILE, pending_store)

        target['status']      = 'approved' if action == 'approve' else 'rejected'
        target['resolved_at'] = datetime.datetime.now().isoformat()

        resolved_store  = _load_json(PROMOTER_RESOLVED_REQUESTS_FILE, {})
        resolved_school = resolved_store.get(school_key, {})
        resolved_school[request_id] = target
        resolved_store[school_key] = resolved_school
        _save_json(PROMOTER_RESOLVED_REQUESTS_FILE, resolved_store)

        logger.info(
            "✅ resolve_promoter_request : école='%s' id='%s' action='%s'",
            school_code, request_id, action,
        )
        return jsonify({"message": "Demande résolue", "status": target['status']}), 200
    except Exception as e:
        logger.exception("Erreur resolve_promoter_request")
        return jsonify({"error": str(e)}), 500


@app.route('/school/get_request_status', methods=['GET'])
def get_request_status():
    try:
        school_code = request.args.get('school_code')
        request_id  = request.args.get('request_id')
        if not school_code or not request_id:
            return jsonify({"error": "Données manquantes"}), 400

        school_key = school_code.lower()

        resolved_store = _load_json(PROMOTER_RESOLVED_REQUESTS_FILE, {})
        resolved = resolved_store.get(school_key, {}).get(request_id)
        if resolved is not None:
            return jsonify(resolved), 200

        pending_store = _load_json(PROMOTER_PENDING_REQUESTS_FILE, {})
        pending_list  = pending_store.get(school_key, [])
        pending = next((r for r in pending_list if r.get('id') == request_id), None)
        if pending is not None:
            return jsonify(pending), 200

        return jsonify({"error": "Demande introuvable"}), 404
    except Exception as e:
        logger.exception("Erreur get_request_status")
        return jsonify({"error": str(e)}), 500


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

        return jsonify({
            "server_time":     datetime.datetime.now().isoformat(),
            "data_dir":        os.path.abspath(DATA_DIR),
            "nb_ecoles":       len(details),
            "ecoles":          details,
            "subscription_mode": "TEST (1 minute)" if SUBSCRIPTION_TEST_MODE else "PRODUCTION (30 jours)",
            "firebase_ready":  _firebase_ready(),
        }), 200
    except Exception as e:
        logger.exception("Erreur admin_health")
        return jsonify({"error": str(e)}), 500


# ====================================================================
# ROUTES ADMIN — lister et télécharger TOUS les fichiers .json du
# disque persistant (y compris les fichiers système), protégé par
# ADMIN_PASSWORD. Utilisées par le script Mac de sauvegarde locale.
# ====================================================================

@app.route('/admin/list_data_files', methods=['POST'])
def admin_list_data_files():
    try:
        data = request.get_json()
        if data.get('admin_password') != ADMIN_PASSWORD:
            return jsonify({"error": "Accès refusé"}), 401
        files = sorted(f for f in os.listdir(DATA_DIR) if f.endswith('.json'))
        return jsonify({"files": files, "total": len(files)}), 200
    except Exception as e:
        logger.exception("Erreur admin_list_data_files")
        return jsonify({"error": str(e)}), 500


@app.route('/admin/download_data_file', methods=['POST'])
def admin_download_data_file():
    try:
        data = request.get_json()
        if data.get('admin_password') != ADMIN_PASSWORD:
            return jsonify({"error": "Accès refusé"}), 401

        filename = data.get('filename', '')
        safe_name = os.path.basename(filename)
        if not safe_name.endswith('.json') or safe_name != filename:
            return jsonify({"error": "Nom de fichier invalide"}), 400

        filepath = os.path.join(DATA_DIR, safe_name)
        if not os.path.exists(filepath):
            return jsonify({"error": "Fichier introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            content = json.load(f)

        return jsonify({"filename": safe_name, "content": content}), 200
    except Exception as e:
        logger.exception("Erreur admin_download_data_file")
        return jsonify({"error": str(e)}), 500


_sync_orphan_schools()


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=10000)