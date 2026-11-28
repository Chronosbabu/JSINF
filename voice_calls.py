# -*- coding: utf-8 -*-
"""
📞 APPELS AUDIO ÉCOLE → PARENT (WebRTC)
=======================================

Seule l'ÉCOLE peut appeler. Le parent ne peut que décrocher, refuser ou
raccrocher : aucune route ne permet à un parent de lancer un appel.

Pourquoi c'est léger pour Render (plan Starter 7 $) :
  - le SON ne passe JAMAIS par ce serveur. Il va directement d'un appareil
    à l'autre (WebRTC), ou par un relais TURN externe (Cloudflare,
    Metered…) quand un réseau mobile bloque la connexion directe ;
  - ce serveur ne fait que la « signalisation » : quelques petites
    requêtes HTTP (offre, réponse, état) et une notification FCM pour
    faire sonner le téléphone du parent ;
  - les appels sont rangés dans UN fichier séparé (voice_calls.json),
    jamais mélangé aux fichiers des écoles. Les appels terminés depuis
    plus de 2 heures en sortent ; seul un petit journal est gardé.

Variables d'environnement (Render) pour le relais TURN — FORTEMENT
conseillé, sinon environ 1 appel sur 5 échoue sur les réseaux mobiles :
  CF_TURN_KEY_ID + CF_TURN_API_TOKEN : TURN Cloudflare (gratuit jusqu'à
                                       1000 Go/mois)
  ou TURN_URLS (séparées par des virgules) + TURN_USERNAME +
     TURN_CREDENTIAL                  : n'importe quel autre service TURN
"""

import datetime
import json
import logging
import os
import secrets
import threading
import time
import urllib.request

logger = logging.getLogger("edupay.calls")

CALLS_FILE_NAME = "voice_calls.json"

RING_TIMEOUT_SEC     = 45      # le téléphone sonne au maximum 45 s
CONNECT_TIMEOUT_SEC  = 40      # décroché → audio établi
HEARTBEAT_LOST_SEC   = 35      # un côté muet depuis 35 s = appel coupé
HEARTBEAT_WRITE_SEC  = 8       # on n'écrit « vu » sur le disque que toutes les 8 s
MAX_CALL_SEC         = 2 * 3600
KEEP_ENDED_SEC       = 2 * 3600
MAX_LOG_PER_SCHOOL   = 300
MAX_ACTIVE_PER_SCHOOL = 5
MAX_SDP_LEN          = 20000

ACTIVE_STATES = ("ringing", "connecting", "active")

DEFAULT_STUN = [
    {"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]},
    {"urls": ["stun:stun.cloudflare.com:3478"]},
]

PARENT_CALL_CHANNEL_ID = "edupay_parent_calls"

END_LABELS = {
    "hangup_school": "Terminé par l'école",
    "hangup_parent": "Terminé par le parent",
    "declined":      "Refusé par le parent",
    "missed":        "Sans réponse",
    "cancelled":     "Annulé avant la réponse",
    "busy":          "Parent déjà en appel",
    "failed":        "Échec de connexion",
    "connection_lost": "Connexion perdue",
    "too_long":      "Durée maximale atteinte",
}


def _now():
    return time.time()


def _iso(ts):
    if not ts:
        return None
    return datetime.datetime.fromtimestamp(
        ts, datetime.timezone.utc).isoformat()


def register_voice_calls(app, deps):
    from flask import request, jsonify
    from firebase_admin import messaging

    data_dir        = deps["data_dir"]
    lock_cls        = deps["lock_cls"]
    load_json       = deps["load_json"]
    save_json       = deps["save_json_atomic"]
    valid_code      = deps["valid_school_code"]
    students_map    = deps["school_students_map"]
    school_name_of  = deps["school_name"]
    parent_devices  = deps["parent_devices"]      # () -> {token: {...}}
    firebase_ready  = deps["firebase_ready"]
    is_dead_token   = deps["is_dead_token_error"]
    remove_tokens   = deps["remove_invalid_parent_tokens"]
    add_messages    = deps["add_messages_bulk"]
    notify_parents  = deps["notify_parents"]
    run_async       = deps["run_async"]

    calls_file = os.path.join(data_dir, CALLS_FILE_NAME)
    calls_lock = lock_cls(os.path.join(data_dir, "voice_calls.lock"))

    # ------------------------------------------------------------------
    # Stockage
    # ------------------------------------------------------------------
    def _load():
        try:
            store = load_json(calls_file, {})
        except Exception:
            logger.exception("voice_calls.json illisible : on repart à vide")
            store = {}
        store.setdefault("calls", {})
        store.setdefault("log", {})
        return store

    def _save(store):
        save_json(calls_file, store)

    def _student_label(school_code, sid):
        stu = students_map(school_code).get(sid) or {}
        name = " ".join(str(stu.get(k) or '').strip()
                        for k in ('nom', 'postNom', 'prenom')
                        if str(stu.get(k) or '').strip())
        return name or sid, stu.get('classe', '')

    def _devices_for(school_code, sid):
        key = school_code.strip().lower()
        out = []
        for token, dev in (parent_devices() or {}).items():
            for c in dev.get('children', []):
                if (c.get('school_code') or '').lower() == key and \
                        (c.get('student_id') or '').upper() == sid:
                    out.append(token)
                    break
        return out

    def _public(c, side, have_version=None):
        """Ce qu'un côté a le droit de voir (jamais les tokens).
        have_version : version d'offre/réponse que l'appareil a déjà ; si
        elle est à jour, le SDP n'est pas renvoyé (économie de données)."""
        out = {
            "call_id":     c["id"],
            "state":       c["state"],
            "end_reason":  c.get("end_reason"),
            "end_label":   END_LABELS.get(c.get("end_reason") or "", ""),
            "student_id":  c["student_id"],
            "student_name": c.get("student_name", ""),
            "classe":      c.get("classe", ""),
            "school_name": c.get("school_name", ""),
            "caller_name": c.get("caller_name", ""),
            "created_at":  _iso(c.get("created_at")),
            "answered_at": _iso(c.get("answered_at")),
            "ended_at":    _iso(c.get("ended_at")),
            "duration_sec": _duration(c),
            "server_time": _iso(_now()),
            "offer_version":  c.get("offer_version", 1),
            "answer_version": c.get("answer_version", 0),
        }
        if side == "school":
            if c.get("answer_sdp") and \
                    have_version != c.get("answer_version", 0):
                out["answer"] = {"type": "answer", "sdp": c["answer_sdp"]}
            out["devices"] = len(c.get("devices", []))
            out["parent_muted"] = bool(c.get("parent_muted"))
        else:
            if have_version != c.get("offer_version", 1):
                out["offer"] = {"type": "offer", "sdp": c.get("offer_sdp", "")}
            out["school_muted"] = bool(c.get("school_muted"))
        return out

    def _duration(c):
        if not c.get("answered_at"):
            return 0
        end = c.get("ended_at") or _now()
        return max(0, int(end - c["answered_at"]))

    def _end(store, c, reason):
        """Termine un appel (dans le verrou). Retourne True si changé."""
        if c["state"] not in ACTIVE_STATES:
            return False
        c["state"] = "ended"
        c["end_reason"] = reason
        c["ended_at"] = _now()
        sk = c["school_code"]
        log = store["log"].setdefault(sk, [])
        log.append({
            "call_id":      c["id"],
            "student_id":   c["student_id"],
            "student_name": c.get("student_name", ""),
            "classe":       c.get("classe", ""),
            "caller_name":  c.get("caller_name", ""),
            "created_at":   _iso(c.get("created_at")),
            "answered_at":  _iso(c.get("answered_at")),
            "ended_at":     _iso(c.get("ended_at")),
            "duration_sec": _duration(c),
            "end_reason":   reason,
            "end_label":    END_LABELS.get(reason, reason),
        })
        if len(log) > MAX_LOG_PER_SCHOOL:
            del log[:len(log) - MAX_LOG_PER_SCHOOL]
        # effets après coup (hors verrou) : on les note
        c["_post_end"] = True
        return True

    def _expire(store):
        """Règles de temps (sonnerie trop longue, côté silencieux…).
        Retourne la liste des appels terminés à l'instant."""
        now = _now()
        ended = []
        for c in store["calls"].values():
            st = c["state"]
            if st not in ACTIVE_STATES:
                continue
            reason = None
            if st == "ringing" and now - c["created_at"] > RING_TIMEOUT_SEC:
                reason = "missed"
            elif st == "connecting" and \
                    now - (c.get("accepted_at") or now) > CONNECT_TIMEOUT_SEC:
                reason = "failed"
            elif now - c.get("school_seen", c["created_at"]) > HEARTBEAT_LOST_SEC:
                reason = "connection_lost" if st != "ringing" else "cancelled"
            elif st in ("connecting", "active") and \
                    now - c.get("parent_seen", now) > HEARTBEAT_LOST_SEC:
                reason = "connection_lost"
            elif now - c["created_at"] > MAX_CALL_SEC:
                reason = "too_long"
            if reason and _end(store, c, reason):
                ended.append(dict(c))
        # ménage
        for cid in [cid for cid, c in store["calls"].items()
                    if c["state"] == "ended"
                    and now - (c.get("ended_at") or now) > KEEP_ENDED_SEC]:
            store["calls"].pop(cid, None)
        return ended

    def _after_end(calls_ended):
        """Hors verrou : prévenir les téléphones + message « appel manqué »."""
        for c in calls_ended:
            try:
                _push_to_devices(c.get("devices", []), {
                    "type": "call_ended",
                    "call_id": c["id"],
                    "end_reason": c.get("end_reason", ""),
                })
                if c.get("end_reason") in ("missed", "cancelled") and \
                        not c.get("answered_at"):
                    _missed_call_message(c)
            except Exception:
                logger.exception("Fin d'appel : effets secondaires")

    def _missed_call_message(c):
        heure = datetime.datetime.now().strftime('%H:%M')
        who = c.get("caller_name") or c.get("school_name") or "L'école"
        text = (f"📞 Appel manqué de {who} à {heure}. "
                f"L'école vous rappellera ou vous pouvez lui écrire ici.")
        res = add_messages(c["school_code"], [{
            "student_id": c["student_id"], "type": "message",
            "title": "Appel manqué de l'école",
            "message": text, "sender": "school",
            "client_id": f"missed_{c['id']}",
            "extra": {"nom_eleve": c.get("student_name", ""),
                      "classe": c.get("classe", ""),
                      "call_id": c["id"]},
            "urgent": False,
        }])
        entry, created = res[0]
        if created:
            notify_parents(c["school_code"], [entry])

    # ------------------------------------------------------------------
    # FCM : données seules, priorité haute (le téléphone sonne même en
    # veille, l'application dessine elle-même l'écran d'appel).
    # ------------------------------------------------------------------
    def _push_to_devices(tokens, data, ttl_sec=60):
        if not tokens or not firebase_ready():
            return 0
        data = {k: str(v) for k, v in data.items() if v is not None}
        msgs = [messaging.Message(
            token=t, data=data,
            android=messaging.AndroidConfig(
                priority='high',
                ttl=datetime.timedelta(seconds=ttl_sec)),
            apns=messaging.APNSConfig(
                headers={"apns-priority": "10",
                         "apns-push-type": "alert"},
                payload=messaging.APNSPayload(
                    aps=messaging.Aps(content_available=True))),
        ) for t in tokens]
        dead, ok = [], 0
        try:
            resp = messaging.send_each(msgs)
        except Exception as e:
            logger.error("❌ Push appel : %s", e)
            return 0
        for i, r in enumerate(resp.responses):
            if r.success:
                ok += 1
            elif is_dead_token(r.exception):
                dead.append(tokens[i])
            else:
                logger.warning("⚠️ Push appel échoué : %s", r.exception)
        if dead:
            remove_tokens(dead)
        return ok

    # ------------------------------------------------------------------
    # Serveurs ICE (STUN + TURN)
    # ------------------------------------------------------------------
    _ice_cache = {"until": 0, "servers": None}
    _ice_lock = threading.Lock()

    def _cloudflare_ice():
        key_id = os.environ.get("CF_TURN_KEY_ID", "").strip()
        token = os.environ.get("CF_TURN_API_TOKEN", "").strip()
        if not key_id or not token:
            return None
        base = f"https://rtc.live.cloudflare.com/v1/turn/keys/{key_id}/credentials/"
        body = json.dumps({"ttl": 86400}).encode()
        for suffix in ("generate-ice-servers", "generate"):
            try:
                req = urllib.request.Request(
                    base + suffix, data=body, method="POST",
                    headers={"Authorization": f"Bearer {token}",
                             "Content-Type": "application/json",
                             "Accept": "application/json",
                             # Cloudflare refuse (403) l'agent par défaut
                             # « Python-urllib » : on se présente normalement.
                             "User-Agent": "EduPay-Server/1.0"})
                with urllib.request.urlopen(req, timeout=6) as r:
                    payload = json.loads(r.read().decode())
                ice = payload.get("iceServers")
                if isinstance(ice, dict):
                    ice = [ice]
                if ice:
                    return ice
            except Exception as e:
                logger.warning("TURN Cloudflare (%s) : %s", suffix, e)
        return None

    def _static_turn():
        urls = [u.strip() for u in os.environ.get("TURN_URLS", "").split(",")
                if u.strip()]
        if not urls:
            return None
        return [{"urls": urls,
                 "username": os.environ.get("TURN_USERNAME", ""),
                 "credential": os.environ.get("TURN_CREDENTIAL", "")}]

    def ice_servers():
        with _ice_lock:
            if _ice_cache["servers"] and _ice_cache["until"] > _now():
                return _ice_cache["servers"], _ice_cache.get("turn", False)
        turn = _cloudflare_ice() or _static_turn()
        servers = list(DEFAULT_STUN) + (turn or [])
        with _ice_lock:
            _ice_cache["servers"] = servers
            _ice_cache["turn"] = bool(turn)
            # identifiants Cloudflare valables 24 h : on renouvelle toutes
            # les 6 h ; en cas d'échec on réessaie dans 2 min.
            _ice_cache["until"] = _now() + (6 * 3600 if turn else 120)
        return servers, bool(turn)

    # ------------------------------------------------------------------
    # Outils de route
    # ------------------------------------------------------------------
    def _int_or_none(v):
        try:
            return None if v is None else int(v)
        except (TypeError, ValueError):
            return None

    def _body():
        return request.get_json(silent=True) or {}

    def _sdp(v):
        if isinstance(v, dict):
            v = v.get("sdp")
        v = (v or "").strip()
        if not v or len(v) > MAX_SDP_LEN or not v.startswith("v=0"):
            return None
        return v + ("\r\n" if not v.endswith("\n") else "")

    def _get_call_for_school(store, data):
        cid = (data.get("call_id") or "").strip()
        sc = (data.get("school_code") or "").strip().lower()
        c = store["calls"].get(cid)
        if not c or c["school_code"] != sc:
            return None
        return c

    def _get_call_for_parent(store, data):
        cid = (data.get("call_id") or "").strip()
        return store["calls"].get(cid)

    def _with_calls(fn):
        """Exécute fn(store) sous verrou, sauvegarde, puis effets de fin."""
        with calls_lock:
            store = _load()
            ended = _expire(store)
            result, changed = fn(store)
            for c in store["calls"].values():
                if c.pop("_post_end", None) and \
                        not any(e["id"] == c["id"] for e in ended):
                    ended.append(dict(c))
            if changed or ended:
                _save(store)
        if ended:
            run_async(_after_end, ended)
        return result

    # ==================================================================
    # ROUTES COMMUNES
    # ==================================================================
    @app.route('/calls/ice_servers', methods=['GET'])
    def calls_ice_servers():
        servers, has_turn = ice_servers()
        return jsonify({"ice_servers": servers, "turn": has_turn}), 200

    # ==================================================================
    # ROUTES ÉCOLE (la seule qui peut appeler)
    # ==================================================================
    @app.route('/school/call/check', methods=['GET'])
    def school_call_check():
        """Avant d'appeler : le parent a-t-il un téléphone joignable ?"""
        sc = request.args.get('school_code', '').strip()
        sid = request.args.get('student_id', '').strip().upper()
        if not valid_code(sc) or not sid:
            return jsonify({"error": "Paramètres manquants"}), 400
        n = len(_devices_for(sc, sid))
        return jsonify({"devices": n, "can_call": n > 0 and firebase_ready(),
                        "firebase_ready": firebase_ready()}), 200

    @app.route('/school/call/start', methods=['POST'])
    def school_call_start():
        try:
            data = _body()
            sc = (data.get('school_code') or '').strip()
            sid = (data.get('student_id') or '').strip().upper()
            offer = _sdp(data.get('offer'))
            caller = (data.get('caller_name') or '').strip()[:60]
            if not valid_code(sc) or not sid:
                return jsonify({"error": "Paramètres manquants"}), 400
            if not offer:
                return jsonify({"error": "Offre audio invalide"}), 400
            if not firebase_ready():
                return jsonify({"error": "Notifications indisponibles sur le "
                                         "serveur (Firebase)."}), 503
            if sid not in students_map(sc):
                return jsonify({"error": "Élève introuvable"}), 404
            devices = _devices_for(sc, sid)
            if not devices:
                return jsonify({
                    "error": "Aucun téléphone de parent n'est enregistré pour "
                             "cet élève. Le parent doit installer l'application "
                             "et ajouter son enfant.",
                    "code": "NO_DEVICE"}), 404
            name, classe = _student_label(sc, sid)
            school_name = (school_name_of(sc) or
                           (data.get('school_name') or '').strip()[:80])

            def op(store):
                key = sc.lower()
                actifs = [c for c in store["calls"].values()
                          if c["school_code"] == key
                          and c["state"] in ACTIVE_STATES]
                for c in actifs:
                    if c["student_id"] == sid:
                        return (jsonify({
                            "error": "Un appel vers ce parent est déjà en cours.",
                            "code": "ALREADY_IN_CALL",
                            "call_id": c["id"]}), 409), False
                if len(actifs) >= MAX_ACTIVE_PER_SCHOOL:
                    return (jsonify({"error": "Trop d'appels simultanés."}),
                            429), False
                # un téléphone déjà en appel (autre école/enfant) = occupé
                busy = set()
                for c in store["calls"].values():
                    if c["state"] in ACTIVE_STATES:
                        busy.update(c.get("devices", []))
                free = [t for t in devices if t not in busy]
                if not free:
                    return (jsonify({"error": "Le parent est déjà en appel.",
                                     "code": "BUSY"}), 409), False
                now = _now()
                cid = secrets.token_urlsafe(18)
                call = {
                    "id": cid, "school_code": key, "student_id": sid,
                    "student_name": name, "classe": classe,
                    "school_name": school_name, "caller_name": caller,
                    "state": "ringing", "created_at": now,
                    "school_seen": now, "devices": free,
                    "offer_sdp": offer, "offer_version": 1,
                    "answer_sdp": None, "answer_version": 0,
                }
                store["calls"][cid] = call
                return call, True

            res = _with_calls(op)
            if isinstance(res, tuple):
                return res
            call = res
            sent = _push_to_devices(call["devices"], {
                "type": "incoming_call",
                "call_id": call["id"],
                "school_code": call["school_code"],
                "student_id": sid,
                "student_name": name,
                "school_name": school_name,
                "caller_name": caller,
                "expires_at": int(call["created_at"] + RING_TIMEOUT_SEC),
            }, ttl_sec=RING_TIMEOUT_SEC)
            if sent == 0:
                def fail(store):
                    c = store["calls"].get(call["id"])
                    if c:
                        _end(store, c, "failed")
                        c.pop("_post_end", None)
                    return None, True
                _with_calls(fail)
                return jsonify({"error": "Impossible de joindre le téléphone "
                                         "du parent (notification refusée).",
                                "code": "PUSH_FAILED"}), 502
            logger.info("📞 Appel %s : école=%s élève=%s → %d téléphone(s)",
                        call["id"][:6], sc, sid, sent)
            servers, _ = ice_servers()
            return jsonify({"call": _public(call, "school"),
                            "devices_rung": sent,
                            "ice_servers": servers}), 200
        except Exception as e:
            logger.exception("Erreur school_call_start")
            return jsonify({"error": str(e)}), 500

    @app.route('/school/call/status', methods=['POST'])
    def school_call_status():
        """Appelée ~1 fois par seconde par l'école pendant l'appel : sert
        aussi de « je suis toujours là ». Peut transmettre l'état du micro."""
        data = _body()

        def op(store):
            c = _get_call_for_school(store, data)
            if not c:
                return (jsonify({"error": "Appel introuvable"}), 404), False
            changed = False
            now = _now()
            if c["state"] in ACTIVE_STATES and \
                    now - c.get("school_seen", 0) > HEARTBEAT_WRITE_SEC:
                c["school_seen"] = now
                changed = True
            if "muted" in data and bool(data["muted"]) != bool(c.get("school_muted")):
                c["school_muted"] = bool(data["muted"])
                changed = True
            if data.get("connected") and c["state"] == "connecting":
                c["state"] = "active"
                changed = True
            return (jsonify({"call": _public(
                c, "school", _int_or_none(data.get("have_answer_version")))}),
                200), changed

        return _with_calls(op)

    @app.route('/school/call/renegotiate', methods=['POST'])
    def school_call_renegotiate():
        """Reconnexion (le réseau a changé : Wi-Fi ⇄ 4G…) : nouvelle offre
        avec redémarrage ICE. Le parent la récupère par /parent/call/status."""
        data = _body()
        offer = _sdp(data.get('offer'))
        if not offer:
            return jsonify({"error": "Offre invalide"}), 400

        def op(store):
            c = _get_call_for_school(store, data)
            if not c or c["state"] not in ("connecting", "active"):
                return (jsonify({"error": "Appel terminé"}), 410), False
            c["offer_sdp"] = offer
            c["offer_version"] = c.get("offer_version", 1) + 1
            c["school_seen"] = _now()
            return (jsonify({"call": _public(c, "school")}), 200), True

        res = _with_calls(op)
        return res

    @app.route('/school/call/hangup', methods=['POST'])
    def school_call_hangup():
        data = _body()

        def op(store):
            c = _get_call_for_school(store, data)
            if not c:
                return (jsonify({"error": "Appel introuvable"}), 404), False
            reason = "cancelled" if c["state"] == "ringing" else "hangup_school"
            if data.get("reason") == "failed":
                reason = "failed"
            changed = _end(store, c, reason)
            return (jsonify({"call": _public(c, "school")}), 200), changed

        return _with_calls(op)

    @app.route('/school/call/history', methods=['GET'])
    def school_call_history():
        sc = request.args.get('school_code', '').strip().lower()
        sid = request.args.get('student_id', '').strip().upper()
        if not valid_code(sc):
            return jsonify({"error": "Paramètres manquants"}), 400
        with calls_lock:
            store = _load()
        log = list(store["log"].get(sc, []))
        if sid:
            log = [e for e in log if e.get("student_id") == sid]
        log.reverse()
        return jsonify({"calls": log[:200]}), 200

    # ==================================================================
    # ROUTES PARENT (décrocher / refuser / raccrocher seulement)
    # ==================================================================
    @app.route('/parent/call/status', methods=['POST'])
    def parent_call_status():
        data = _body()

        def op(store):
            c = _get_call_for_parent(store, data)
            if not c:
                return (jsonify({"error": "Appel introuvable",
                                 "state": "ended"}), 404), False
            changed = False
            now = _now()
            if c["state"] in ("connecting", "active") and \
                    now - c.get("parent_seen", 0) > HEARTBEAT_WRITE_SEC:
                c["parent_seen"] = now
                changed = True
            if "muted" in data and bool(data["muted"]) != bool(c.get("parent_muted")):
                c["parent_muted"] = bool(data["muted"])
                changed = True
            if data.get("connected") and c["state"] == "connecting":
                c["state"] = "active"
                changed = True
            return (jsonify({"call": _public(
                c, "parent", _int_or_none(data.get("have_offer_version")))}),
                200), changed

        return _with_calls(op)

    @app.route('/parent/call/accept', methods=['POST'])
    def parent_call_accept():
        """Le parent décroche : il reçoit l'offre de l'école. Les autres
        téléphones du même enfant arrêtent de sonner."""
        data = _body()
        token = (data.get('device_token') or '').strip()

        def op(store):
            c = _get_call_for_parent(store, data)
            if not c:
                return (jsonify({"error": "Appel introuvable"}), 404), False
            if c["state"] != "ringing":
                if c["state"] in ("connecting", "active") and token and \
                        c.get("answered_by") == token:
                    # même téléphone qui redemande (réseau coupé) : OK
                    return (jsonify({"call": _public(c, "parent")}), 200), False
                msg = ("Appel déjà pris sur un autre téléphone"
                       if c["state"] != "ended" else "Appel terminé")
                return (jsonify({"error": msg, "state": c["state"],
                                 "end_reason": c.get("end_reason")}), 410), False
            now = _now()
            c["state"] = "connecting"
            c["accepted_at"] = now
            c["answered_at"] = now
            c["parent_seen"] = now
            c["answered_by"] = token or "unknown"
            c["_others"] = [t for t in c.get("devices", []) if t != token]
            return c, True

        res = _with_calls(op)
        if isinstance(res, tuple):
            return res
        c = res
        others = c.pop("_others", [])
        if others:
            run_async(_push_to_devices, others, {
                "type": "call_ended", "call_id": c["id"],
                "end_reason": "answered_elsewhere"})
        servers, _ = ice_servers()
        return jsonify({"call": _public(c, "parent"),
                        "ice_servers": servers}), 200

    @app.route('/parent/call/answer', methods=['POST'])
    def parent_call_answer():
        data = _body()
        answer = _sdp(data.get('answer'))
        if not answer:
            return jsonify({"error": "Réponse audio invalide"}), 400
        try:
            version = int(data.get('offer_version') or 1)
        except (TypeError, ValueError):
            version = 1

        def op(store):
            c = _get_call_for_parent(store, data)
            if not c or c["state"] not in ("connecting", "active"):
                return (jsonify({"error": "Appel terminé"}), 410), False
            if version != c.get("offer_version", 1):
                return (jsonify({"error": "Offre périmée",
                                 "code": "STALE_OFFER",
                                 "call": _public(c, "parent")}), 409), False
            c["answer_sdp"] = answer
            c["answer_version"] = version
            c["parent_seen"] = _now()
            return (jsonify({"call": _public(c, "parent")}), 200), True

        return _with_calls(op)

    @app.route('/parent/call/decline', methods=['POST'])
    def parent_call_decline():
        data = _body()

        def op(store):
            c = _get_call_for_parent(store, data)
            if not c:
                return (jsonify({"error": "Appel introuvable"}), 404), False
            changed = False
            if c["state"] == "ringing":
                changed = _end(store, c, "declined")
            return (jsonify({"call": _public(c, "parent")}), 200), changed

        return _with_calls(op)

    @app.route('/parent/call/hangup', methods=['POST'])
    def parent_call_hangup():
        data = _body()

        def op(store):
            c = _get_call_for_parent(store, data)
            if not c:
                return (jsonify({"error": "Appel introuvable"}), 404), False
            reason = "declined" if c["state"] == "ringing" else "hangup_parent"
            if data.get("reason") == "failed":
                reason = "failed"
            changed = _end(store, c, reason)
            return (jsonify({"call": _public(c, "parent")}), 200), changed

        return _with_calls(op)

    # Petit état pour /admin/health
    def calls_health():
        try:
            with calls_lock:
                store = _load()
            active = sum(1 for c in store["calls"].values()
                         if c["state"] in ACTIVE_STATES)
            return {"active_calls": active,
                    "turn_configured": bool(
                        os.environ.get("CF_TURN_KEY_ID")
                        or os.environ.get("TURN_URLS"))}
        except Exception:
            return {"error": "illisible"}

    return {"health": calls_health, "file_name": CALLS_FILE_NAME}
