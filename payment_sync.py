"""
Synchronisation silencieuse des paiements école → serveur → parents.

- /school/sync_student_payments : l'application école envoie l'ÉTAT complet
  (paid + transactions) des élèves modifiés. Le serveur remplace l'état de
  l'élève (idempotent : renvoyer 10 fois = même résultat), compare avec
  l'ancien état, et prévient les parents (paiement reçu / annulé / modifié).
- Un numéro de version des paiements par élève est tenu à jour : l'app parent
  le lit à chaque synchronisation et recharge ses montants quand il change.
"""
import os
import json
import time
import hashlib
import datetime
import threading
import contextlib
import logging

try:
    import fcntl
except ImportError:          # Windows (dev local)
    fcntl = None

from flask import request, jsonify

logger = logging.getLogger("edupay.payment_sync")

DATA_DIR = os.environ.get("DATA_DIR", "/var/data/school_data")
os.makedirs(DATA_DIR, exist_ok=True)

PAYMENT_VERSIONS_FILE = os.path.join(DATA_DIR, "payments_versions.json")
_VERSIONS_LOCK_FILE = os.path.join(DATA_DIR, "payments_versions.lock")
_SCHOOL_LOCK_FILE = os.path.join(DATA_DIR, "school_sync.lock")

MONTHS = [
    'Septembre', 'Octobre', 'Novembre', 'Decembre',
    'Janvier', 'Fevrier', 'Mars', 'Avril', 'Mai', 'Juin'
]

# Un ancien paiement (date plus vieille que ça) n'est jamais annoncé comme
# « nouveau » aux parents (évite le spam lors d'une première synchronisation).
RECENT_DAYS = 7

_THREAD_LOCK = threading.RLock()


@contextlib.contextmanager
def _locked(lock_path):
    """Verrou inter-threads ET inter-processus."""
    with _THREAD_LOCK:
        fd = None
        try:
            if fcntl is not None:
                fd = open(lock_path, 'a')
                fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            if fd is not None:
                try:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                finally:
                    fd.close()


def _load(path, default):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return default


def _save_atomic(path, data):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


# --------------------------------------------------------------------
# VERSION DES PAIEMENTS (par école + élève)
# --------------------------------------------------------------------

def bump_payment_versions(school_code, student_ids):
    """Marque les paiements de ces élèves comme « modifiés » : les apps
    parents rechargeront leurs montants à la prochaine synchronisation."""
    ids = {str(s).strip().upper() for s in (student_ids or []) if s}
    if not ids or not school_code:
        return
    key = school_code.strip().lower()
    with _locked(_VERSIONS_LOCK_FILE):
        store = _load(PAYMENT_VERSIONS_FILE, {})
        sch = store.setdefault(key, {})
        now = int(time.time() * 1000)
        for sid in ids:
            try:
                prev = int(sch.get(sid, 0))
            except (TypeError, ValueError):
                prev = 0
            sch[sid] = max(prev + 1, now)
        _save_atomic(PAYMENT_VERSIONS_FILE, store)


def get_payment_version(school_code, student_id):
    try:
        store = _load(PAYMENT_VERSIONS_FILE, {})
        return int(store.get(school_code.strip().lower(), {})
                   .get(str(student_id).strip().upper(), 0))
    except Exception:
        return 0


# --------------------------------------------------------------------
# OUTILS TRANSACTIONS
# --------------------------------------------------------------------

def _num(v):
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def _amount(t):
    return _num(t.get('amount'))


def _sig(t):
    return f"{t.get('date', '')}|{t.get('mois', '')}|{_amount(t):.2f}"


def _fc(x):
    return f"{x:,.0f}".replace(',', ' ') + " FC"


def _index(txs):
    """{clé: transaction}. Les transactions sans id (ou avec un id LEG_
    généré par le serveur) sont reconnues par leur signature."""
    out, seen = {}, {}
    for t in txs or []:
        if not isinstance(t, dict):
            continue
        tid = str(t.get('id') or '').strip()
        base = tid if (tid and not tid.startswith('LEG_')) else 'SIG|' + _sig(t)
        n = seen.get(base, 0)
        seen[base] = n + 1
        out[f"{base}#{n}" if n else base] = t
    return out


def _is_recent(t):
    try:
        d = datetime.date.fromisoformat(str(t.get('date', ''))[:10])
    except ValueError:
        return False
    return (datetime.date.today() - d).days <= RECENT_DAYS


def _months_text(txs):
    seen = []
    for t in txs:
        m = str(t.get('mois', '') or '')
        if m and m not in seen:
            seen.append(m)
    seen.sort(key=lambda m: MONTHS.index(m) if m in MONTHS else 99)
    return ", ".join(seen) if seen else "l'année"


def _digest(kind, items, total_paid):
    raw = json.dumps([kind, sorted(items), round(total_paid, 2)],
                     ensure_ascii=False)
    return hashlib.sha1(raw.encode('utf-8')).hexdigest()[:16]


def _build_events(old_txs, new_txs, total_paid):
    """Retourne [(kind, titre, message, client_id)]."""
    old_i, new_i = _index(old_txs), _index(new_txs)

    added = [t for k, t in new_i.items()
             if k not in old_i and not t.get('saisieGroupee')
             and _is_recent(t)]
    removed = [t for k, t in old_i.items()
               if k not in new_i and not t.get('saisieGroupee')]
    modified = [(old_i[k], t) for k, t in new_i.items()
                if k in old_i and not t.get('saisieGroupee')
                and (abs(_amount(old_i[k]) - _amount(t)) > 0.009
                     or str(old_i[k].get('mois', '')) != str(t.get('mois', '')))]

    suffix = f" Total payé cette année : {_fc(total_paid)}."
    events = []

    if added:
        total = sum(_amount(t) for t in added)
        msg = (f"Un paiement de {_fc(total)} a été enregistré pour "
               f"{_months_text(added)}.") + suffix
        events.append((
            "added", "Paiement reçu", msg,
            "pay_" + _digest("added",
                             [f"{_sig(t)}" for t in added], total_paid)))

    if removed:
        total = sum(_amount(t) for t in removed)
        msg = (f"Le paiement de {_fc(total)} pour {_months_text(removed)} "
               f"a été annulé par l'école.") + suffix
        events.append((
            "cancelled", "Paiement annulé", msg,
            "pay_" + _digest("cancelled",
                             [f"{_sig(t)}" for t in removed], total_paid)))

    if modified:
        if len(modified) == 1:
            o, n = modified[0]
            msg = (f"Le paiement de {n.get('mois', '')} a été modifié : "
                   f"{_fc(_amount(o))} → {_fc(_amount(n))}.") + suffix
        else:
            msg = (f"{len(modified)} paiements ont été modifiés par "
                   f"l'école.") + suffix
        events.append((
            "modified", "Paiement modifié", msg,
            "pay_" + _digest("modified",
                             [f"{_sig(o)}>{_sig(n)}" for o, n in modified],
                             total_paid)))
    return events


def _same_state(old_paid, old_txs, new_paid, new_txs):
    op = {str(k): round(_num(v), 2) for k, v in (old_paid or {}).items()}
    np_ = {str(k): round(_num(v), 2) for k, v in new_paid.items()}
    if op != np_:
        return False
    return (json.dumps(old_txs or [], sort_keys=True, ensure_ascii=False)
            == json.dumps(new_txs, sort_keys=True, ensure_ascii=False))


# --------------------------------------------------------------------
# ROUTE
# --------------------------------------------------------------------

def register_payment_sync(app, deps):
    """deps : add_messages_bulk, run_async, notify_parents,
    get_all_ids_except (fonctions de app.py)."""

    @app.route('/school/sync_student_payments', methods=['POST'])
    def sync_student_payments():
        try:
            data = request.get_json(silent=True) or {}
            school_code = (data.get('school_code') or '').strip()
            students = data.get('students')
            if not school_code or not isinstance(students, list):
                return jsonify({"error": "Données manquantes"}), 400

            filepath = os.path.join(DATA_DIR, f"{school_code.lower()}.json")
            if not os.path.exists(filepath):
                return jsonify({
                    "error": "Aucune sauvegarde de l'école sur le serveur",
                    "needs_backup": True,
                }), 404

            done, pending_events, changed_ids = [], [], []

            with _locked(_SCHOOL_LOCK_FILE):
                saved = _load(filepath, None)
                if not isinstance(saved, dict):
                    return jsonify({"error": "Fichier école illisible"}), 500

                password = data.get('password')
                if (password and saved.get('backup_password')
                        and password != saved.get('backup_password')):
                    return jsonify({"error": "Mot de passe incorrect"}), 401

                year = str(data.get('annee') or saved.get('currentYear') or '')
                if not year:
                    return jsonify({"error": "Année introuvable"}), 400

                history = saved.setdefault('history', {})
                year_data = history.setdefault(year, {})
                eleves = year_data.setdefault('eleves', [])
                by_id = {str(e.get('id', '')).upper(): e
                         for e in eleves if isinstance(e, dict)}

                other_ids = None
                file_changed = False

                for snap in students:
                    if not isinstance(snap, dict):
                        continue
                    sid = str(snap.get('id') or '').strip()
                    if not sid:
                        continue
                    paid_in = snap.get('paid')
                    txs_in = snap.get('transactions')
                    if not isinstance(paid_in, dict) or not isinstance(txs_in, list):
                        done.append(sid)
                        continue

                    new_paid = {str(k): _num(v) for k, v in paid_in.items()}
                    new_txs = [t for t in txs_in if isinstance(t, dict)]

                    e = by_id.get(sid.upper())
                    if e is None:
                        # Élève jamais sauvegardé : on le crée (sauf conflit
                        # d'ID avec une autre école).
                        if other_ids is None:
                            other_ids = {
                                str(x).upper() for x in
                                deps['get_all_ids_except'](school_code)}
                        if sid.upper() in other_ids:
                            done.append(sid)
                            continue
                        e = {
                            "id": sid,
                            "nom": snap.get('nom', ''),
                            "postNom": snap.get('postNom', ''),
                            "prenom": snap.get('prenom', ''),
                            "classe": snap.get('classe', ''),
                            "section": snap.get('section', ''),
                            "paid": {},
                            "transactions": [],
                            "customFields": {},
                        }
                        eleves.append(e)
                        by_id[sid.upper()] = e

                    old_paid = e.get('paid') or {}
                    old_txs = e.get('transactions') or []

                    if _same_state(old_paid, old_txs, new_paid, new_txs):
                        done.append(sid)
                        continue

                    events = _build_events(old_txs, new_txs,
                                           sum(new_paid.values()))
                    e['paid'] = new_paid
                    e['transactions'] = new_txs
                    file_changed = True
                    changed_ids.append(sid)
                    done.append(sid)
                    if events:
                        pending_events.append((sid, events))

                if file_changed:
                    _save_atomic(filepath, saved)
                    # AVANT les notifications : quand le parent se synchronise
                    # suite à la notification, la version est déjà à jour.
                    bump_payment_versions(school_code, changed_ids)

            # Notifications (hors verrou)
            for sid, events in pending_events:
                items = [{
                    "student_id": sid,
                    "type": "payment",
                    "title": title,
                    "message": message,
                    "sender": "school",
                    "client_id": client_id,
                    "extra": {"payment_event": kind},
                } for kind, title, message, client_id in events]
                try:
                    created = deps['add_messages_bulk'](school_code, items)
                    entries = [en for en, is_new in created if is_new]
                    if entries:
                        deps['run_async'](deps['notify_parents'],
                                          school_code, entries)
                except Exception:
                    logger.exception("sync_student_payments : notification "
                                     "échouée (non bloquant)")

            logger.info("💸 sync_student_payments : école='%s' reçus=%d "
                        "modifiés=%d", school_code, len(done), len(changed_ids))
            return jsonify({"done": done, "changed": len(changed_ids)}), 200
        except Exception as e:
            logger.exception("Erreur sync_student_payments")
            return jsonify({"error": str(e)}), 500