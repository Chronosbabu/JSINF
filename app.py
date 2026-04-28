from flask import Flask, render_template, request, redirect, url_for, send_from_directory, flash
import os
from werkzeug.utils import secure_filename
from datetime import datetime

app = Flask(__name__)
app.secret_key = 'super_secret_key_12345'   # Change ça en production !

# Configuration Upload
UPLOAD_FOLDER = 'uploads'
ALLOWED_EXTENSIONS = {'pdf', 'doc', 'docx', 'epub'}

app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
app.config['MAX_CONTENT_LENGTH'] = 50 * 1024 * 1024  # Limite à 50 Mo

# Création du dossier uploads s'il n'existe pas
if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

# Liste des livres (on utilise une liste en mémoire pour simplicité)
# En production, tu passeras à une base de données (SQLite + SQLAlchemy)
books = []

@app.route("/")
def home():
    search = request.args.get('search', '')
    filtered_books = books
    if search:
        filtered_books = [b for b in books if search.lower() in b['title'].lower() or 
                          search.lower() in b['description'].lower()]
    return render_template("index.html", books=filtered_books, search=search)

@app.route("/upload", methods=['GET', 'POST'])
def upload():
    if request.method == 'POST':
        title = request.form.get('title')
        whatsapp = request.form.get('whatsapp')
        description = request.form.get('description')
        price_type = request.form.get('price_type')  # "gratuit" ou "payant"
        price = request.form.get('price') if price_type == 'payant' else 0

        if 'file' not in request.files:
            flash('Aucun fichier sélectionné', 'error')
            return redirect(request.url)

        file = request.files['file']

        if file.filename == '':
            flash('Aucun fichier sélectionné', 'error')
            return redirect(request.url)

        if file and allowed_file(file.filename):
            filename = secure_filename(file.filename)
            # Ajouter un timestamp pour éviter les doublons de nom
            unique_filename = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{filename}"
            file_path = os.path.join(app.config['UPLOAD_FOLDER'], unique_filename)
            file.save(file_path)

            # Ajout du livre dans la liste
            new_book = {
                'id': len(books) + 1,
                'title': title,
                'whatsapp': whatsapp,
                'description': description,
                'price_type': price_type,
                'price': float(price) if price else 0,
                'filename': unique_filename,
                'date': datetime.now().strftime('%d/%m/%Y %H:%M')
            }
            books.append(new_book)

            flash('Livre publié avec succès !', 'success')
            return redirect(url_for('home'))
        else:
            flash('Type de fichier non autorisé (PDF, DOC, DOCX, EPUB seulement)', 'error')

    return render_template("upload.html")

# Route pour télécharger le livre (seulement si gratuit)
@app.route("/download/<int:book_id>")
def download(book_id):
    book = next((b for b in books if b['id'] == book_id), None)
    if not book:
        flash("Livre introuvable", "error")
        return redirect(url_for('home'))

    if book['price_type'] != 'gratuit':
        flash("Ce livre est payant. Contactez le vendeur via WhatsApp.", "error")
        return redirect(url_for('home'))

    return send_from_directory(app.config['UPLOAD_FOLDER'], book['filename'], as_attachment=True)

# Route pour servir les fichiers (optionnel)
@app.route("/uploads/<filename>")
def uploaded_file(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=10000, debug=True)
