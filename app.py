from flask import Flask, request, jsonify
import json
import os
import datetime

app = Flask(__name__)
DATA_DIR = "school_data"
os.makedirs(DATA_DIR, exist_ok=True)

KEYS_FILE = os.path.join(DATA_DIR, "keys_store.json")
IDS_FILE = os.path.join(DATA_DIR, "ids_store.json")
PENDING_FILE = os.path.join(DATA_DIR, "pending_payments.json")  # Paiements en attente de validation


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


# ==================== PAIEMENT (CORRIGÉ : VA EN ATTENTE) ====================
@app.route('/record_payment', methods=['POST'])
def record_payment():
    """
    IMPORTANT : ce paiement N'EST PLUS écrit directement dans les données
    finales de l'école. Il est stocké dans pending_payments.json en attente
    de validation par l'admin (via /validate_payments). C'est ce mécanisme
    qui manquait complètement avant et qui causait le bug "aucune
    information reçue" côté admin.
    """
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

        # On stocke ce paiement comme "en attente" pour cette école
        pending_store = _load_json(PENDING_FILE, {})
        school_key = school_code.lower()
        pending_list = pending_store.get(school_key, [])

        payment_id = f"pay_{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}_{os.urandom(3).hex()}"
        pending_entry = {
            "id": payment_id,
            "eleve_id": eleve_id,
            "annee": annee,
            "nom": eleve.get('nom', ''),
            "postNom": eleve.get('postNom', ''),
            "prenom": eleve.get('prenom', ''),
            "section": eleve.get('section', ''),
            "classe": eleve.get('classe', ''),
            "mois": mois,
            "amount": amount,
            "date": datetime.date.today().isoformat(),
        }
        pending_list.append(pending_entry)
        pending_store[school_key] = pending_list
        _save_json(PENDING_FILE, pending_store)

        return jsonify({
            "message": "Paiement reçu, en attente de validation par l'admin",
            "pending_id": payment_id
        }), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ==================== NOUVEAU : RÉCUPÉRER LES PAIEMENTS EN ATTENTE ====================
@app.route('/get_pending_payments', methods=['GET'])
def get_pending_payments():
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        pending_store = _load_json(PENDING_FILE, {})
        pending_list = pending_store.get(school_code.lower(), [])
        return jsonify({"pending_payments": pending_list}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ==================== NOUVEAU : VALIDER LES PAIEMENTS EN ATTENTE ====================
@app.route('/validate_payments', methods=['POST'])
def validate_payments():
    """
    Applique réellement les paiements en attente (ou une partie d'entre eux,
    via payment_ids) dans les données finales de l'école, puis les retire
    de la liste d'attente. C'est cette route qui rend le bouton
    "Valider Tout" réellement fonctionnel côté admin.
    """
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        payment_ids = data.get('payment_ids')  # liste d'ids, ou None/vide = tout valider

        if not school_code:
            return jsonify({"error": "Code manquant"}), 400

        school_key = school_code.lower()
        filename = f"{school_key}.json"
        filepath = os.path.join(DATA_DIR, filename)
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)
        history = saved.get('history', {})

        pending_store = _load_json(PENDING_FILE, {})
        pending_list = pending_store.get(school_key, [])

        if payment_ids:
            to_validate = [p for p in pending_list if p.get('id') in payment_ids]
            remaining = [p for p in pending_list if p.get('id') not in payment_ids]
        else:
            to_validate = pending_list
            remaining = []

        validated_count = 0
        for entry in to_validate:
            annee = entry.get('annee')
            eleve_id = entry.get('eleve_id')
            mois = entry.get('mois')
            amount = entry.get('amount')

            year_data = history.get(annee)
            if not year_data:
                continue

            eleve = None
            for e in year_data.get('eleves', []):
                if e.get('id') == eleve_id:
                    eleve = e
                    break
            if eleve is None:
                continue

            eleve.setdefault('paid', {})
            eleve['paid'][mois] = eleve['paid'].get(mois, 0) + amount
            eleve.setdefault('transactions', [])
            eleve['transactions'].append({
                'date': entry.get('date'),
                'mois': mois,
                'amount': amount,
                'from_subuser': True,
                'validated': True
            })
            validated_count += 1

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(saved, f, ensure_ascii=False, indent=2)

        pending_store[school_key] = remaining
        _save_json(PENDING_FILE, pending_store)

        return jsonify({
            "message": "Paiements validés avec succès",
            "validated_count": validated_count,
            "remaining_pending": len(remaining)
        }), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ==================== NOUVEAU : REJETER UN PAIEMENT EN ATTENTE (optionnel) ====================
@app.route('/reject_payment', methods=['POST'])
def reject_payment():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        payment_id = data.get('payment_id')
        if not school_code or not payment_id:
            return jsonify({"error": "Données manquantes"}), 400

        school_key = school_code.lower()
        pending_store = _load_json(PENDING_FILE, {})
        pending_list = pending_store.get(school_key, [])
        pending_list = [p for p in pending_list if p.get('id') != payment_id]
        pending_store[school_key] = pending_list
        _save_json(PENDING_FILE, pending_store)

        return jsonify({"message": "Paiement rejeté"}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ==================== AUTRES ROUTES (inchangées) ====================
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


@app.route('/generate_key', methods=['POST'])
def generate_key():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        section = data.get('section')
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


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=10000)