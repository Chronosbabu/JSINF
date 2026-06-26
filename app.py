from flask import Flask, request, jsonify
import json
import os
import datetime

app = Flask(__name__)
DATA_DIR = "school_data"
os.makedirs(DATA_DIR, exist_ok=True)

PENDING_FILE = os.path.join(DATA_DIR, "pending_payments.json")

def _load_pending():
    if os.path.exists(PENDING_FILE):
        with open(PENDING_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    return {}

def _save_pending(data):
    with open(PENDING_FILE, 'w', encoding='utf-8') as f:
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
        return jsonify({"error": "Aucune sauvegarde trouvée"}), 404

# ==================== ENREGISTREMENT PAIEMENT EN ATTENTE ====================
@app.route('/record_payment', methods=['POST'])
def record_payment():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        eleve_id = data.get('eleve_id')
        mois = data.get('mois')
        amount = data.get('amount')

        if not all([school_code, eleve_id, mois, amount]):
            return jsonify({"error": "Données manquantes"}), 400

        pending = _load_pending()
        key = school_code.lower()
        if key not in pending:
            pending[key] = []

        pending[key].append({
            "eleve_id": eleve_id,
            "mois": mois,
            "amount": amount,
            "date": datetime.datetime.now().isoformat(),
            "status": "pending"
        })

        _save_pending(pending)
        return jsonify({"message": "Paiement envoyé en attente de validation"}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ==================== RÉCUPÉRATION PAIEMENTS EN ATTENTE POUR ADMIN ====================
@app.route('/pending_payments', methods=['GET'])
def pending_payments():
    school_code = request.args.get('school_code')
    if not school_code:
        return jsonify({"error": "Code manquant"}), 400

    pending = _load_pending()
    key = school_code.lower()
    return jsonify(pending.get(key, [])), 200

# ==================== VALIDATION DES PAIEMENTS PAR ADMIN ====================
@app.route('/validate_payments', methods=['POST'])
def validate_payments():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400

        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            school_data = json.load(f)

        pending = _load_pending()
        key = school_code.lower()
        payments = pending.get(key, [])

        # Appliquer les paiements
        for p in payments:
            for year_data in school_data.get('history', {}).values():
                for eleve in year_data.get('eleves', []):
                    if eleve.get('id') == p['eleve_id']:
                        eleve.setdefault('paid', {})
                        eleve['paid'][p['mois']] = eleve['paid'].get(p['mois'], 0) + p['amount']
                        eleve.setdefault('transactions', [])
                        eleve['transactions'].append({
                            'date': p['date'],
                            'mois': p['mois'],
                            'amount': p['amount'],
                            'validated_by_admin': True
                        })

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(school_data, f, ensure_ascii=False, indent=2)

        # Vider les paiements validés
        if key in pending:
            del pending[key]
            _save_pending(pending)

        return jsonify({"message": "Tous les paiements validés et enregistrés"}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=10000)