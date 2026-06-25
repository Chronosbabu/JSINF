from flask import Flask, request, jsonify
import json
import os
import datetime

app = Flask(__name__)
DATA_DIR = "school_data"
os.makedirs(DATA_DIR, exist_ok=True)

KEYS_FILE = os.path.join(DATA_DIR, "keys_store.json")
IDS_FILE = os.path.join(DATA_DIR, "ids_store.json")


def _load_json(path, default):
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return default


def _save_json(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


# ==================== BACKUP / RESTORE ====================
@app.route('/backup', methods=['POST'])
def backup():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        backup_data = data.get('data')
        if not school_code or not backup_data:
            return jsonify({"error": "Données invalides"}), 400
        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(backup_data, f, ensure_ascii=False, indent=2)
        return jsonify({"message": "Sauvegarde réussie", "school_code": school_code}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/restore', methods=['GET'])
def restore():
    school_code = request.args.get('school_code')
    if not school_code:
        return jsonify({"error": "Code manquant"}), 400
    filename = f"{school_code.lower()}.json"
    filepath = os.path.join(DATA_DIR, filename)
    if os.path.exists(filepath):
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        data.pop('backup_password', None)
        return jsonify(data), 200
    else:
        return jsonify({"error": "Aucune sauvegarde trouvée pour ce code"}), 404


@app.route('/verify_password', methods=['POST'])
def verify_password():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        password = data.get('password')
        if not school_code or not password:
            return jsonify({"error": "Données manquantes"}), 400
        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)
        if os.path.exists(filepath):
            with open(filepath, 'r', encoding='utf-8') as f:
                saved_data = json.load(f)
            saved_password = saved_data.get('backup_password')
            if saved_password == password:
                return jsonify({"valid": True}), 200
            else:
                return jsonify({"valid": False, "error": "Mot de passe incorrect"}), 401
        else:
            return jsonify({"error": "Aucune sauvegarde trouvée"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ==================== CLÉS D'ACCÈS PAR SECTION (sub-users) ====================
# Avant : la clé était juste renvoyée sans jamais être enregistrée -> impossible
# de la vérifier ensuite. Maintenant le serveur la stocke et c'est LUI seul
# qui sait si une clé est valide.
@app.route('/generate_key', methods=['POST'])
def generate_key():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        section = data.get('section')  # ex: "Primaire", "Secondaire", "Maternelle"
        if not school_code or not section:
            return jsonify({"error": "Données manquantes"}), 400

        key = f"{school_code.upper()}*{section.upper()[:3]}*{os.urandom(4).hex()}"

        keys = _load_json(KEYS_FILE, {})
        keys[key] = {"school_code": school_code, "section": section}
        _save_json(KEYS_FILE, keys)

        return jsonify({"key": key, "section": section}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/verify_key', methods=['POST'])
def verify_key():
    """Le sub-user appelle cette route à la connexion. Si la clé n'existe pas
    dans keys_store.json (donc n'a pas été générée par ce serveur), c'est
    refusé. On renvoie aussi le nom de l'école et l'année en cours de l'admin,
    pour que le sub-user charge directement les bonnes données."""
    try:
        data = request.get_json()
        key = data.get('key')
        if not key:
            return jsonify({"valid": False, "error": "Clé manquante"}), 400

        keys = _load_json(KEYS_FILE, {})
        info = keys.get(key)
        if not info:
            return jsonify({"valid": False, "error": "Clé invalide"}), 404

        school_code = info["school_code"]
        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)
        school_name = school_code
        current_year = None
        if os.path.exists(filepath):
            with open(filepath, 'r', encoding='utf-8') as f:
                saved = json.load(f)
            school_name = saved.get('config', {}).get('schoolName', school_code)
            current_year = saved.get('currentYear')

        return jsonify({
            "valid": True,
            "school_code": school_code,
            "section": info["section"],
            "school_name": school_name,
            "current_year": current_year,
        }), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/revoke_key', methods=['POST'])
def revoke_key():
    try:
        data = request.get_json()
        key = data.get('key')
        if not key:
            return jsonify({"error": "Clé manquante"}), 400
        keys = _load_json(KEYS_FILE, {})
        if key in keys:
            del keys[key]
            _save_json(KEYS_FILE, keys)
        return jsonify({"message": "Clé révoquée"}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ==================== GÉNÉRATION D'ID ÉLÈVE (toujours côté serveur) ====================
# Avant : l'ID était calculé en local dans l'app Flutter, donc créé même
# sans internet. Maintenant c'est le serveur qui décide et qui garde la trace
# des IDs déjà utilisés pour chaque école, pour garantir l'unicité réelle.
@app.route('/generate_student_id', methods=['POST'])
def generate_student_id():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        school_name = data.get('school_name', '')
        nom = data.get('nom', '')
        year = data.get('year', '2025-2026')

        if not school_code or not nom:
            return jsonify({"error": "Données manquantes"}), 400

        year_short = year[-2:] if len(year) >= 2 else "26"
        school_letter = school_name[0].upper() if school_name else "B"
        name_prefix = nom.strip()[:2].upper() if nom.strip() else "XX"
        base_id = f"{name_prefix}{year_short}{school_letter}"

        ids_store = _load_json(IDS_FILE, {})
        used_ids = set(ids_store.get(school_code.lower(), []))

        counter = 1
        candidate = f"{base_id}{counter}"
        while candidate in used_ids:
            counter += 1
            candidate = f"{base_id}{counter}"

        used_ids.add(candidate)
        ids_store[school_code.lower()] = list(used_ids)
        _save_json(IDS_FILE, ids_store)

        return jsonify({"id": candidate}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ==================== PAIEMENT ENVOYÉ PAR UN SOUS-UTILISATEUR ====================
# Le sub-user n'a pas de fichier de sauvegarde local partagé avec l'admin :
# chaque paiement qu'il enregistre est donc poussé directement dans le fichier
# de sauvegarde de l'école sur le serveur.
@app.route('/record_payment', methods=['POST'])
def record_payment():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        annee = data.get('annee')
        eleve_id = data.get('eleve_id')
        mois = data.get('mois')
        amount = data.get('amount')

        if not all([school_code, annee, eleve_id, mois]) or amount is None:
            return jsonify({"error": "Données manquantes"}), 400

        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)

        history = saved.get('history', {})
        year_data = history.get(annee)
        if not year_data:
            return jsonify({"error": "Année introuvable"}), 404

        eleve = None
        for e in year_data.get('eleves', []):
            if e.get('id') == eleve_id:
                eleve = e
                break

        if eleve is None:
            return jsonify({"error": "Élève introuvable"}), 404

        eleve.setdefault('paid', {})
        eleve['paid'][mois] = eleve['paid'].get(mois, 0) + amount
        eleve.setdefault('transactions', [])
        eleve['transactions'].append({
            'date': datetime.date.today().isoformat(),
            'mois': mois,
            'amount': amount,
        })

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(saved, f, ensure_ascii=False, indent=2)

        return jsonify({"message": "Paiement enregistré", "paid_total": eleve['paid'][mois]}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=10000)
