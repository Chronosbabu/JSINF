from flask import Flask, request, jsonify
import json
import os

app = Flask(__name__)

DATA_DIR = "school_data"
os.makedirs(DATA_DIR, exist_ok=True)

@app.route('/backup', methods=['POST'])
def backup():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        backup_data = data.get('data')

        if not school_code or not backup_data:
            return jsonify({"error": "Données invalides"}), 400

        # Extraction du mot de passe (s'il existe)
        backup_password = backup_data.get('backup_password')

        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(backup_data, f, ensure_ascii=False, indent=2)

        return jsonify({
            "message": "Sauvegarde réussie",
            "school_code": school_code
        }), 200

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
        
        # On retire le mot de passe de la réponse pour plus de sécurité (optionnel)
        # data.pop('backup_password', None)   # Décommente si tu veux cacher le mdp

        return jsonify(data), 200
    else:
        return jsonify({"error": "Aucune sauvegarde trouvée pour ce code"}), 404


# Optionnel : Route pour vérifier uniquement le mot de passe (plus sécurisé à l'avenir)
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


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=10000)
