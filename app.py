from flask import Flask, request, jsonify
import json
import os
import re
import datetime

app = Flask(__name__)
DATA_DIR = "school_data"
os.makedirs(DATA_DIR, exist_ok=True)

KEYS_FILE = os.path.join(DATA_DIR, "keys_store.json")
IDS_FILE = os.path.join(DATA_DIR, "ids_store.json")
PENDING_FILE = os.path.join(DATA_DIR, "pending_payments.json")
MOBILE_PAYMENTS_FILE = os.path.join(DATA_DIR, "mobile_payments.json")


def _load_json(path, default):
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return default


def _save_json(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _get_all_ids_except(school_code):
    """
    Collecte tous les IDs de toutes les écoles SAUF celle en cours.
    Utilisé pour détecter les conflits lors d'un backup.
    """
    all_ids = set()
    skip_files = {'keys_store.json', 'ids_store.json',
                  'pending_payments.json', 'mobile_payments.json'}
    for fname in os.listdir(DATA_DIR):
        if not fname.endswith('.json'):
            continue
        if fname in skip_files:
            continue
        if fname == f"{school_code.lower()}.json":
            continue
        fpath = os.path.join(DATA_DIR, fname)
        try:
            with open(fpath, 'r', encoding='utf-8') as f:
                data = json.load(f)
            for year_data in data.get('history', {}).values():
                for eleve in year_data.get('eleves', []):
                    eid = eleve.get('id', '')
                    if eid:
                        all_ids.add(eid)
        except Exception:
            pass
    return all_ids


def _resolve_id_conflicts(school_code, backup_data):
    """
    Compare les IDs du backup entrant avec tous les autres écoles.
    Renvoie (backup_data_corrigé, dict_corrections).
    dict_corrections = {ancien_id: nouvel_id, ...}
    """
    other_ids = _get_all_ids_except(school_code)
    if not other_ids:
        return backup_data, {}

    # Collecter aussi les IDs internes à cette école (pour éviter doublons internes)
    own_ids = set()
    for year_data in backup_data.get('history', {}).values():
        for eleve in year_data.get('eleves', []):
            eid = eleve.get('id', '')
            if eid:
                own_ids.add(eid)

    all_used = other_ids | own_ids
    corrections = {}

    for year_data in backup_data.get('history', {}).values():
        for eleve in year_data.get('eleves', []):
            old_id = eleve.get('id', '')
            if not old_id or old_id not in other_ids:
                continue

            # Extraire le préfixe (lettres) du numéro final
            match = re.match(r'^(.*?)(\d+)$', old_id)
            if match:
                base = match.group(1)
            else:
                base = old_id + '_'

            # Trouver un nouvel ID unique
            counter = 1
            new_id = f"{base}{counter}"
            while new_id in all_used:
                counter += 1
                new_id = f"{base}{counter}"

            corrections[old_id] = new_id
            eleve['id'] = new_id
            all_used.add(new_id)
            all_used.discard(old_id)

    return backup_data, corrections


# ==================== BACKUP / RESTORE ====================
@app.route('/backup', methods=['POST'])
def backup():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        backup_data = data.get('data')
        if not school_code or not backup_data:
            return jsonify({"error": "Données invalides"}), 400

        # Résolution des conflits d'IDs entre écoles
        corrected_data, corrections = _resolve_id_conflicts(school_code, backup_data)

        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(corrected_data, f, ensure_ascii=False, indent=2)

        return jsonify({
            "message": "Sauvegarde réussie",
            "school_code": school_code,
            "corrections": corrections,
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
        data.pop('backup_password', None)
        return jsonify(data), 200
    else:
        return jsonify({"error": "Aucune sauvegarde trouvée pour ce code"}), 404


# ==================== PAIEMENT EN ATTENTE (sous-utilisateur) ====================
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


@app.route('/validate_payments', methods=['POST'])
def validate_payments():
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        payment_ids = data.get('payment_ids')

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


# ==================== PAIEMENTS MOBILE MONEY (PARENT) ====================

@app.route('/parent/find_student', methods=['GET'])
def parent_find_student():
    """
    Cherche un élève par son ID dans TOUTES les écoles.
    Utilisé par l'application parent pour vérifier un ID.
    """
    try:
        student_id = request.args.get('student_id', '').strip().upper()
        if not student_id:
            return jsonify({"found": False, "error": "ID manquant"}), 400

        skip_files = {'keys_store.json', 'ids_store.json',
                      'pending_payments.json', 'mobile_payments.json'}

        for fname in os.listdir(DATA_DIR):
            if not fname.endswith('.json') or fname in skip_files:
                continue
            fpath = os.path.join(DATA_DIR, fname)
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    data = json.load(f)
            except Exception:
                continue

            school_code = fname.replace('.json', '').upper()
            school_name = data.get('config', {}).get('schoolName', school_code)
            current_year = data.get('currentYear', '')
            config = data.get('config', {})

            for year_data in data.get('history', {}).values():
                for eleve in year_data.get('eleves', []):
                    if eleve.get('id', '').upper() == student_id:
                        return jsonify({
                            "found": True,
                            "student": {
                                "id": eleve.get('id'),
                                "nom": eleve.get('nom', ''),
                                "postNom": eleve.get('postNom', ''),
                                "prenom": eleve.get('prenom', ''),
                                "classe": eleve.get('classe', ''),
                                "section": eleve.get('section', ''),
                            },
                            "school_code": school_code,
                            "school_name": school_name,
                            "current_year": current_year,
                            "config": {
                                "feesBySection": config.get('feesBySection', {}),
                                "monthlyExceptionsBySection": config.get('monthlyExceptionsBySection', {}),
                            }
                        }), 200

        return jsonify({"found": False, "error": "Aucun élève trouvé avec cet ID"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/parent/get_payment_history', methods=['GET'])
def parent_get_payment_history():
    """
    Retourne l'historique de paiement d'un élève pour l'application parent.
    """
    try:
        student_id = request.args.get('student_id', '').strip().upper()
        school_code = request.args.get('school_code', '').strip()
        if not student_id or not school_code:
            return jsonify({"error": "Paramètres manquants"}), 400

        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)

        config = data.get('config', {})
        current_year = data.get('currentYear', '')
        history = data.get('history', {})
        year_data = history.get(current_year, {})

        for eleve in year_data.get('eleves', []):
            if eleve.get('id', '').upper() == student_id:
                return jsonify({
                    "paid": eleve.get('paid', {}),
                    "transactions": eleve.get('transactions', []),
                    "fees_by_section": config.get('feesBySection', {}),
                    "monthly_exceptions": config.get('monthlyExceptionsBySection', {}),
                    "fees_by_classe": config.get('feesByClasse', {}),
                    "current_year": current_year,
                }), 200

        return jsonify({"error": "Élève introuvable"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/parent/submit_mobile_payment', methods=['POST'])
def parent_submit_mobile_payment():
    """
    Le parent soumet une demande de paiement via Mobile Money.
    Stockée en attente jusqu'à confirmation par l'admin.
    Fonctionne sans API Mobile Money réelle (pour la démo).
    """
    try:
        data = request.get_json()
        student_id = data.get('student_id', '').strip().upper()
        school_code = data.get('school_code', '').strip()
        mois = data.get('mois')
        amount = data.get('amount')
        network = data.get('network', '')
        parent_name = data.get('parent_name', 'Parent')

        if not all([student_id, school_code, mois]) or amount is None:
            return jsonify({"error": "Données manquantes"}), 400

        filename = f"{school_code.lower()}.json"
        filepath = os.path.join(DATA_DIR, filename)
        if not os.path.exists(filepath):
            return jsonify({"error": "École introuvable"}), 404

        with open(filepath, 'r', encoding='utf-8') as f:
            saved = json.load(f)

        current_year = saved.get('currentYear', '')
        history = saved.get('history', {})
        year_data = history.get(current_year, {})

        eleve = None
        for e in year_data.get('eleves', []):
            if e.get('id', '').upper() == student_id:
                eleve = e
                break

        if eleve is None:
            return jsonify({"error": "Élève introuvable"}), 404

        # Stocker dans les paiements mobile en attente
        mobile_store = _load_json(MOBILE_PAYMENTS_FILE, {})
        school_key = school_code.lower()
        mobile_list = mobile_store.get(school_key, [])

        payment_id = f"mob_{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}_{os.urandom(3).hex()}"
        mobile_entry = {
            "id": payment_id,
            "type": "mobile_money",
            "eleve_id": student_id,
            "annee": current_year,
            "nom": eleve.get('nom', ''),
            "postNom": eleve.get('postNom', ''),
            "prenom": eleve.get('prenom', ''),
            "section": eleve.get('section', ''),
            "classe": eleve.get('classe', ''),
            "mois": mois,
            "amount": amount,
            "network": network,
            "parent_name": parent_name,
            "date": datetime.date.today().isoformat(),
            "status": "pending",
        }
        mobile_list.append(mobile_entry)
        mobile_store[school_key] = mobile_list
        _save_json(MOBILE_PAYMENTS_FILE, mobile_store)

        return jsonify({
            "message": "Demande de paiement mobile reçue. En attente de confirmation par l'école.",
            "payment_id": payment_id
        }), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/get_mobile_payments', methods=['GET'])
def get_mobile_payments():
    """
    Retourne les paiements mobile en attente pour une école.
    Utilisé par l'admin pour afficher le badge.
    """
    try:
        school_code = request.args.get('school_code')
        if not school_code:
            return jsonify({"error": "Code manquant"}), 400
        mobile_store = _load_json(MOBILE_PAYMENTS_FILE, {})
        mobile_list = mobile_store.get(school_code.lower(), [])
        return jsonify({
            "mobile_payments": mobile_list,
            "count": len(mobile_list)
        }), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/confirm_mobile_payments', methods=['POST'])
def confirm_mobile_payments():
    """
    L'admin confirme les paiements mobile.
    Les paiements sont appliqués aux données de l'école.
    """
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        payment_ids = data.get('payment_ids')  # None = tout confirmer

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

        mobile_store = _load_json(MOBILE_PAYMENTS_FILE, {})
        mobile_list = mobile_store.get(school_key, [])

        if payment_ids:
            to_confirm = [p for p in mobile_list if p.get('id') in payment_ids]
            remaining = [p for p in mobile_list if p.get('id') not in payment_ids]
        else:
            to_confirm = mobile_list
            remaining = []

        confirmed_count = 0
        for entry in to_confirm:
            annee = entry.get('annee')
            eleve_id = entry.get('eleve_id')
            mois = entry.get('mois')
            amount = entry.get('amount')

            year_data = history.get(annee)
            if not year_data:
                continue

            eleve = None
            for e in year_data.get('eleves', []):
                if e.get('id', '').upper() == str(eleve_id).upper():
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
                'network': entry.get('network', ''),
                'from_parent': True,
                'validated': True
            })
            confirmed_count += 1

        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(saved, f, ensure_ascii=False, indent=2)

        mobile_store[school_key] = remaining
        _save_json(MOBILE_PAYMENTS_FILE, mobile_store)

        return jsonify({
            "message": "Paiements mobile confirmés",
            "confirmed_count": confirmed_count,
            "remaining": len(remaining)
        }), 200
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
    """
    Conservé pour compatibilité mais la génération est maintenant locale.
    Le serveur valide juste que l'ID est unique et le mémorise.
    """
    try:
        data = request.get_json()
        school_code = data.get('school_code')
        school_name = data.get('school_name', '')
        nom = data.get('nom', '')
        year = data.get('year', '2025-2026')
        proposed_id = data.get('proposed_id')  # ID généré localement

        if not school_code or not nom:
            return jsonify({"error": "Données manquantes"}), 400

        ids_store = _load_json(IDS_FILE, {})
        used_ids = set(ids_store.get(school_code.lower(), []))

        if proposed_id and proposed_id not in used_ids:
            # Utiliser l'ID proposé par le client
            candidate = proposed_id
        else:
            # Générer un ID côté serveur si nécessaire
            year_short = year[-2:] if len(year) >= 2 else "26"
            school_letter = school_name[0].upper() if school_name else "B"
            name_prefix = nom.strip()[:2].upper() if nom.strip() else "XX"
            base_id = f"{name_prefix}{year_short}{school_letter}"
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