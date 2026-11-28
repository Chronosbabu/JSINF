# -*- coding: utf-8 -*-
"""
✍️ « ÉCRIT… » (comme WhatsApp) entre l'école et le parent d'un élève.

Très léger pour Render : chaque appareil signale « j'écris » au plus une
fois toutes les 3 s pendant la frappe ; l'autre côté demande l'état toutes
les 2 s, seulement quand la conversation est ouverte. L'état s'efface tout
seul au bout de TYPING_TTL_SEC sans nouvelle frappe.
Fichier séparé (chat_typing.json), jamais mélangé aux données des écoles.
"""

import os
import time

TYPING_FILE_NAME = "chat_typing.json"
TYPING_TTL_SEC = 6
SIDES = ("school", "parent")


def register_chat_typing(app, deps):
    from flask import request, jsonify

    data_dir   = deps["data_dir"]
    lock_cls   = deps["lock_cls"]
    load_json  = deps["load_json"]
    save_json  = deps["save_json_atomic"]
    valid_code = deps["valid_school_code"]

    path = os.path.join(data_dir, TYPING_FILE_NAME)
    lock = lock_cls(os.path.join(data_dir, "chat_typing.lock"))

    def _key(school_code, student_id, side):
        return f"{school_code.strip().lower()}|{student_id.strip().upper()}|{side}"

    def _load():
        try:
            d = load_json(path, {})
            return d if isinstance(d, dict) else {}
        except Exception:
            return {}

    def _params(src):
        sc = (src.get('school_code') or '').strip()
        sid = (src.get('student_id') or '').strip().upper()
        side = (src.get('side') or '').strip().lower()
        if not valid_code(sc) or not sid or len(sid) > 60 or side not in SIDES:
            return None
        return sc, sid, side

    @app.route('/chat/typing', methods=['POST'])
    def chat_set_typing():
        """{school_code, student_id, side: school|parent, typing: bool}"""
        p = _params(request.get_json(silent=True) or {})
        if not p:
            return jsonify({"error": "Paramètres manquants"}), 400
        typing = bool((request.get_json(silent=True) or {}).get('typing', True))
        now = time.time()
        k = _key(*p)
        with lock:
            d = _load()
            changed = False
            # ménage des états expirés
            for old in [x for x, exp in d.items() if exp < now]:
                d.pop(old, None)
                changed = True
            if typing:
                d[k] = now + TYPING_TTL_SEC
                changed = True
            elif d.pop(k, None) is not None:
                changed = True
            if changed:
                save_json(path, d)
        return jsonify({"ok": True}), 200

    @app.route('/chat/typing', methods=['GET'])
    def chat_get_typing():
        """?school_code&student_id&side=<MON côté> → l'AUTRE côté écrit-il ?"""
        p = _params(request.args)
        if not p:
            return jsonify({"error": "Paramètres manquants"}), 400
        sc, sid, side = p
        other = "parent" if side == "school" else "school"
        exp = _load().get(_key(sc, sid, other), 0)
        return jsonify({"typing": exp > time.time()}), 200

    return {"file_name": TYPING_FILE_NAME}
