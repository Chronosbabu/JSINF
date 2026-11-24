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
# ⚡ FUSION SANS SUPPRESSION (correction de la synchronisation)
# --------------------------------------------------------------------

def _fusionner_ajouts(old_txs, new_txs):
    """Retourne (transactions fusionnées, transactions ajoutées).
    Seules les transactions INCONNUES du serveur sont ajoutées (même clé que
    _index : identifiant, ou signature date|mois|montant pour les
    transactions sans identifiant ou avec un identifiant LEG_). Rien n'est
    jamais supprimé ni modifié : les annulations / modifications passent
    uniquement par la sauvegarde complète (/backup)."""
    old_valides = [t for t in (old_txs or []) if isinstance(t, dict)]
    old_i = _index(old_valides)
    ajoutees = [t for k, t in _index(new_txs).items() if k not in old_i]
    if not ajoutees:
        return list(old_txs or []), []
    fusion = list(old_txs or []) + [dict(t) for t in ajoutees]
    fusion.sort(key=lambda t: str(t.get('date', '')) if isinstance(t, dict) else '')
    return fusion, ajoutees


def _paid_apres_fusion(old_paid, txs):
    """Même règle que l'application (_syncFusionnerEleve) : un mois qui a
    des transactions = somme de ses transactions ; un mois sans transaction
    garde le montant déjà connu du serveur."""
    paid = {}
    for t in txs:
        if not isinstance(t, dict):
            continue
        mois = str(t.get('mois', '') or '')
        if mois:
            paid[mois] = paid.get(mois, 0.0) + _amount(t)
    for mois, v in (old_paid or {}).items():
        if str(mois) not in paid and _num(v) > 0:
            paid[str(mois)] = _num(v)
    return paid


# --------------------------------------------------------------------
# ROUTE
# --------------------------------------------------------------------

def register_payment_sync(app, deps):
    """deps : add_messages_bulk, run_async, notify_parents,
    get_all_ids_except, data_lock, school_path, valid_school_code,
    read_school, commit_school, pw_equal (fonctions de app.py)."""

    @app.route('/school/sync_student_payments', methods=['POST'])
    def sync_student_payments():
        """⚡ CORRIGÉ — FUSION SANS SUPPRESSION.
        Avant : les paiements de l'élève étaient REMPLACÉS par ceux de
        l'ordinateur qui envoie, sans changer la révision : un ordinateur en
        retard effaçait les paiements saisis ailleurs.
        Maintenant :
          • seules les transactions inconnues du serveur sont AJOUTÉES ;
          • aucun élève n'est créé ;
          • même verrou que /backup, révision +1, instantané avant écriture ;
          • mot de passe obligatoire.
        Compatibilité avec les anciennes versions de l'application : quand
        rien n'est écrit (mot de passe absent ou faux, école inconnue, élève
        inconnu), on répond quand même 200 avec "done" = élèves reçus, pour
        que leur file d'attente se vide (pas de bandeau ni de renvoi en
        boucle). "auth_refused" / "ignored" sont des champs en plus, que les
        anciennes versions ignorent."""
        try:
            data = request.get_json(silent=True) or {}
            school_code = (data.get('school_code') or '').strip()
            students = data.get('students')
            if not school_code or not isinstance(students, list):
                return jsonify({"error": "Données manquantes"}), 400

            recus = []
            for s in students:
                if isinstance(s, dict):
                    sid = str(s.get('id') or '').strip()
                    if sid:
                        recus.append(sid)

            def _rien_ecrit(motif, auth_refused=False):
                logger.warning(
                    "sync_student_payments : rien écrit (%s) école='%s' "
                    "élèves=%d", motif, school_code, len(recus))
                return jsonify({
                    "done": recus,
                    "changed": 0,
                    "ignored": recus,
                    "auth_refused": auth_refused,
                }), 200

            if not deps['valid_school_code'](school_code):
                return _rien_ecrit("code école invalide")
            filepath = deps['school_path'](school_code)
            if not os.path.exists(filepath):
                return _rien_ecrit("école inconnue")

            done, pending_events, changed_ids, ignored = [], [], [], []

            with deps['data_lock']:
                saved = deps['read_school'](filepath)
                if not isinstance(saved, dict):
                    return jsonify({"error": "Fichier école illisible"}), 500

                stored_pw = saved.get('backup_password')
                password = data.get('password')
                if not stored_pw or not password or \
                        not deps['pw_equal'](stored_pw, password):
                    return _rien_ecrit("mot de passe absent ou incorrect",
                                       auth_refused=True)

                year = str(data.get('annee') or saved.get('currentYear') or '')
                year_data = (saved.get('history') or {}).get(year)
                eleves = (year_data or {}).get('eleves') \
                    if isinstance(year_data, dict) else None
                if not isinstance(eleves, list):
                    return _rien_ecrit(f"année '{year}' absente du serveur")
                by_id = {str(e.get('id', '')).upper(): e
                         for e in eleves if isinstance(e, dict)}

                for snap in students:
                    if not isinstance(snap, dict):
                        continue
                    sid = str(snap.get('id') or '').strip()
                    if not sid:
                        continue
                    txs_in = snap.get('transactions')
                    if not isinstance(txs_in, list):
                        done.append(sid)
                        continue
                    new_txs = [t for t in txs_in if isinstance(t, dict)]

                    e = by_id.get(sid.upper())
                    if e is None:
                        # Élève jamais sauvegardé : il arrivera sur le
                        # serveur par « Sauvegarder » (on ne crée plus de
                        # fiche incomplète, source de doublons).
                        ignored.append(sid)
                        done.append(sid)
                        continue

                    old_txs = e.get('transactions') or []
                    fusion, ajoutees = _fusionner_ajouts(old_txs, new_txs)
                    if not ajoutees:
                        done.append(sid)
                        continue

                    new_paid = _paid_apres_fusion(e.get('paid') or {}, fusion)
                    events = _build_events(old_txs, fusion,
                                           sum(new_paid.values()))
                    e['transactions'] = fusion
                    e['paid'] = new_paid
                    changed_ids.append(sid)
                    done.append(sid)
                    if events:
                        pending_events.append((sid, events))

                if changed_ids:
                    # Révision +1 : les ordinateurs récupéreront ces ajouts
                    # avant leur prochaine sauvegarde (STALE_REVISION).
                    deps['commit_school'](filepath, saved)
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
                        "modifiés=%d ignorés=%d", school_code, len(done),
                        len(changed_ids), len(ignored))
            return jsonify({
                "done": done,
                "changed": len(changed_ids),
                "ignored": ignored,
                "auth_refused": False,
            }), 200
        except Exception as e:
            logger.exception("Erreur sync_student_payments")
            return jsonify({"error": str(e)}), 500