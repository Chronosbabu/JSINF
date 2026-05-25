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

        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(backup_data, f, ensure_ascii=False, indent=2)

        return jsonify({"message": "Sauvegarde réussie"}), 200
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
        return jsonify(data), 200
    else:
        return jsonify({"error": "Aucune sauvegarde trouvée pour ce code"}), 404


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=10000)
