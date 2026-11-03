import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../frais_scolaires.dart';

// ==============================================================================
// ⚡ NOUVEAU — IMPORTATION D'ÉLÈVES DEPUIS UN FICHIER EXTERNE (JSON OU TEXTE)
// ==============================================================================
//
// Ce fichier regroupe TOUTE la logique d'import, séparément de
// FraisScolaires, pour ne rien risquer sur le fichier principal :
//   1. StudentImportParser  : lit le contenu brut du fichier (JSON ou texte
//      en blocs "Label: valeur") et le transforme en une liste
//      d'ImportedStudentRecord.
//   2. ImportedStudentRecord: une fiche élève brute, avec la classe déjà
//      décortiquée (numéro / code / libellé / section candidate) ET,
//      désormais, la section explicite si le fichier en fournit une.
//   3. StudentImportService : compare les données du fichier à la base
//      actuelle (sections inconnues, doublons nom/post-nom/prénom) et
//      applique l'import une fois que l'utilisateur a tranché ces points.
//   4. AutoImportGuard      : mémorise (via SharedPreferences, donc sans
//      toucher au fichier de données principal) le contenu déjà importé
//      automatiquement, pour ne jamais réimporter deux fois le même
//      fichier au démarrage.
//
// ⚡ MODIFICATION — LECTURE DIRECTE DU CHAMP "section" DU FICHIER
// ------------------------------------------------------------------------
// Avant cette modification, la seule façon de déclencher la création ou la
// résolution d'une section pendant l'import était d'écrire un code de
// filière DANS le champ "classe" avec un tiret, ex :
//     "classe": "4eme CG - COMMERCIALE ET GESTION"
// Le champ "section" du fichier JSON, lui, n'était jamais lu.
//
// Désormais, un champ "section" explicite dans le fichier (ex:
// {"section": "CG", "classe": "4ème"}) est reconnu et devient LA source
// prioritaire pour déterminer la section de l'élève. Le numéro de classe
// (ex: "4ème") est alors pris tel quel dans le champ "classe", sans avoir
// besoin d'un tiret ni d'un code de filière dedans.
//
// Comportement exact :
//   - Si le fichier fournit un champ "section" non vide  -> cette valeur
//     est utilisée comme candidate de section (résolution / alias / boîte
//     de dialogue de conflit, exactement comme avant).
//   - Sinon, on retombe sur l'ancien comportement : la section candidate
//     est déduite du code trouvé dans le champ "classe" (ex: "CG" dans
//     "4eme CG - ...").
//   - Dans tous les cas, le numéro de classe (ex: "4ème") est toujours lu
//     depuis le premier token du champ "classe".
//
// Aucune de ces classes ne modifie le comportement existant de
// FraisScolaires : elles n'utilisent que des méthodes déjà publiques
// (findDuplicateFullName, generateLocalStudentId, addClasseNumero,
// addSubClasse, buildFullClasseName, getClassesForSection, saveData) plus
// trois petites méthodes ajoutées à FraisScolaires
// (resolveSectionAlias / registerSectionAlias / registerCustomFieldQuestion
// / normalizeSectionKey), elles-mêmes purement additives.
// ==============================================================================

class ImportedStudentRecord {
  final String nom;
  final String postNom;
  final String prenom;
  final String sexe;
  final String dateNaissanceIso;
  final String lieuNaissance;
  final String telephone;
  final String tuteur;
  final String matricule;
  final String classeBrute;

  // ⚡ NOUVEAU — valeur brute du champ "section" du fichier, si présente.
  // Vide si le fichier ne fournit pas ce champ (ex: anciens fichiers texte
  // ou JSON n'ayant que "classe").
  final String sectionExplicite;

  // Renseignés automatiquement par _splitClasse() à la construction.
  String numero = '';
  String code = '';
  String libelle = '';
  String rawSectionCandidateFromClasse = '';

  ImportedStudentRecord({
    required this.nom,
    required this.postNom,
    required this.prenom,
    required this.sexe,
    required this.dateNaissanceIso,
    required this.lieuNaissance,
    required this.telephone,
    required this.tuteur,
    required this.matricule,
    required this.classeBrute,
    this.sectionExplicite = '',
  }) {
    _splitClasse();
  }

  // ============================================================================
  // ⚡ NOUVEAU — Candidate de section "effective" utilisée partout ailleurs
  // dans ce fichier (analyze, importNewRecords, etc.) : priorité absolue au
  // champ "section" explicite du fichier ; à défaut, on retombe sur
  // l'ancienne déduction via le code trouvé dans le champ "classe".
  // ============================================================================
  String get rawSectionCandidate {
    final explicite = sectionExplicite.trim();
    if (explicite.isNotEmpty) return explicite;
    return rawSectionCandidateFromClasse;
  }

  // ============================================================================
  // Décortique une valeur de "classe" du fichier source, ex:
  //   "3eme CG - COMMERCIALE ET GESTION"  -> numero="3ème", code="CG",
  //                                          libelle="COMMERCIALE ET GESTION",
  //                                          rawSectionCandidateFromClasse=
  //                                            "CG - COMMERCIALE ET GESTION"
  //   "7eme A - Option : 003"             -> numero="7ème", code="A",
  //                                          libelle="Option : 003",
  //                                          rawSectionCandidateFromClasse="A"
  //      (le libellé "Option : xxx" ne porte aucune information utile de
  //       filière, donc seul le code court sert de candidat de section —
  //       cas typique du tronc commun / "Éducation de Base")
  //   "4ème"                              -> numero="4ème", code="",
  //                                          libelle="",
  //                                          rawSectionCandidateFromClasse=""
  //      (cas simple : pas de tiret, donc pas de section déduite d'ici —
  //       c'est alors sectionExplicite, si fournie, qui prendra le relais
  //       via le getter rawSectionCandidate ci-dessus)
  // ============================================================================
  void _splitClasse() {
    final full = classeBrute.trim();
    if (full.isEmpty) return;

    final dashIdx = full.indexOf(' - ');
    final leftPart = dashIdx != -1 ? full.substring(0, dashIdx).trim() : full;
    final rightPart = dashIdx != -1 ? full.substring(dashIdx + 3).trim() : '';

    final leftTokens = leftPart.split(RegExp(r'\s+'));
    final numeroRaw = leftTokens.isNotEmpty ? leftTokens.first : '';
    final codeTokens = leftTokens.length > 1 ? leftTokens.sublist(1) : <String>[];

    numero = _normalizeNumero(numeroRaw);
    code = codeTokens.join(' ').trim();
    libelle = rightPart;

    final isOptionPlaceholder =
    RegExp(r'^option\s*:?\s*\d+$', caseSensitive: false).hasMatch(libelle);

    if (code.isEmpty && libelle.isEmpty) {
      rawSectionCandidateFromClasse = '';
    } else if (isOptionPlaceholder || libelle.isEmpty) {
      rawSectionCandidateFromClasse = code;
    } else {
      rawSectionCandidateFromClasse = code.isNotEmpty ? '$code - $libelle' : libelle;
    }
  }

  static String _normalizeNumero(String raw) {
    final match = RegExp(r'(\d+)').firstMatch(raw);
    if (match == null) return raw.trim();
    final n = int.tryParse(match.group(1)!) ?? 0;
    if (n <= 0) return raw.trim();
    if (n == 1) return "1ère";
    return "${n}ème";
  }
}

class StudentImportParseResult {
  final List<ImportedStudentRecord> records;
  final List<String> errors;
  StudentImportParseResult(this.records, this.errors);
}

class StudentImportParser {
  // Champs reconnus, avec leurs synonymes possibles (le fichier peut être
  // du JSON avec des clés en snake_case comme dans ton export, ou un
  // fichier texte en blocs "Label : valeur" écrit à la main).
  static const _keyNom = ['nom'];
  static const _keyPostNom = ['postnom', 'post_nom', 'postNom', 'post-nom'];
  static const _keyPrenom = ['prenom', 'prénom'];
  static const _keySexe = ['sexe', 'genre'];
  static const _keyDateNaissance = [
    'date_de_naissance',
    'datedenaissance',
    'date_naissance',
    'dateNaissance',
    'naissance',
  ];
  static const _keyLieuNaissance = [
    'lieu_de_naissance',
    'lieudenaissance',
    'lieu_naissance',
    'lieuNaissance',
  ];
  static const _keyTelephone = ['telephone', 'téléphone', 'tel', 'phone', 'gsm'];
  static const _keyTuteur = ['tuteur', 'repondant', 'répondant', 'parent'];
  static const _keyMatricule = ['matricule', 'id', 'numero_matricule'];
  static const _keyClasse = ['classe', 'class', 'classe_complete'];

  // ⚡ NOUVEAU — synonymes reconnus pour le champ "section" explicite.
  static const _keySection = ['section', 'filiere', 'filière', 'option'];

  static StudentImportParseResult parse(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return StudentImportParseResult([], ["Le fichier est vide."]);
    }
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      return _parseJson(trimmed);
    }
    return _parseTextBlocks(trimmed);
  }

  static StudentImportParseResult _parseJson(String content) {
    final errors = <String>[];
    final records = <ImportedStudentRecord>[];
    try {
      final decoded = jsonDecode(content);
      final List list = decoded is List ? decoded : [decoded];
      for (final item in list) {
        if (item is! Map) continue;
        records.add(_recordFromMap(Map<String, dynamic>.from(item)));
      }
    } catch (e) {
      errors.add("Erreur de lecture du fichier JSON : $e");
    }
    return StudentImportParseResult(records, errors);
  }

  static StudentImportParseResult _parseTextBlocks(String content) {
    final records = <ImportedStudentRecord>[];
    final blocks = content.split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block.split('\n').where((l) => l.trim().isNotEmpty);
      if (lines.isEmpty) continue;
      final map = <String, dynamic>{};
      for (final line in lines) {
        final idx = line.indexOf(':');
        if (idx == -1) continue;
        final key = line.substring(0, idx).trim();
        final value = line.substring(idx + 1).trim();
        if (key.isEmpty) continue;
        map[key] = value;
      }
      if (map.isEmpty) continue;
      records.add(_recordFromMap(map));
    }
    return StudentImportParseResult(records, const []);
  }

  static ImportedStudentRecord _recordFromMap(Map<String, dynamic> map) {
    String get(List<String> candidates) {
      for (final candidate in candidates) {
        for (final entry in map.entries) {
          if (_normalizeKey(entry.key) == _normalizeKey(candidate)) {
            return entry.value?.toString().trim() ?? '';
          }
        }
      }
      return '';
    }

    return ImportedStudentRecord(
      nom: get(_keyNom),
      postNom: get(_keyPostNom),
      prenom: get(_keyPrenom),
      sexe: get(_keySexe),
      dateNaissanceIso: get(_keyDateNaissance),
      lieuNaissance: get(_keyLieuNaissance),
      telephone: get(_keyTelephone),
      tuteur: get(_keyTuteur),
      matricule: get(_keyMatricule),
      classeBrute: get(_keyClasse),
      // ⚡ NOUVEAU — lecture directe du champ "section" (ou synonymes).
      sectionExplicite: get(_keySection),
    );
  }

  static String _normalizeKey(String k) =>
      k.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

// ==============================================================================
// CONFLITS DE SECTION ET DOUBLONS — objets d'état pour les boîtes de dialogue
// ==============================================================================

class SectionConflict {
  final String rawCandidate;
  bool createNew;
  String newSectionName;
  String? mergeTarget;

  SectionConflict(this.rawCandidate)
      : createNew = true,
        newSectionName = rawCandidate;
}

class DuplicateMatch {
  final ImportedStudentRecord incoming;
  final Eleve existing;
  bool completeMissingInfo;

  DuplicateMatch(this.incoming, this.existing) : completeMissingInfo = true;
}

class ImportAnalysis {
  final List<ImportedStudentRecord> records;
  final List<SectionConflict> sectionConflicts;
  ImportAnalysis(this.records, this.sectionConflicts);
}

// ==============================================================================
// SERVICE PRINCIPAL
// ==============================================================================

class StudentImportService {
  // Intitulés standardisés des questions personnalisées créées
  // automatiquement — TOUJOURS les mêmes, quel que soit l'élève, pour
  // qu'une même information ne soit jamais dupliquée sous un intitulé
  // légèrement différent.
  static const String qTelephone = 'Téléphone';
  static const String qTuteur = 'Tuteur / Répondant';
  static const String qLieuNaissance = 'Lieu de naissance';
  static const String qMatricule = 'Matricule (import)';
  static const String qSexe = 'Sexe';
  static const String qSectionOrigine = "Section d'origine (import)";

  /// Cherche `fileName` sur le Bureau de l'utilisateur, sur Mac, Windows et
  /// Linux, via les variables d'environnement standard (aucune dépendance
  /// supplémentaire nécessaire).
  static Future<String?> findDesktopFile(String fileName) async {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return null;
    final path =
        '$home${Platform.pathSeparator}Desktop${Platform.pathSeparator}$fileName';
    final file = File(path);
    return await file.exists() ? path : null;
  }

  /// Analyse les enregistrements importés et retourne la liste des valeurs
  /// de section totalement inconnues (ni alias déjà enregistré, ni section
  /// du même nom déjà existante), une seule fois par valeur distincte.
  static ImportAnalysis analyze(
      FraisScolaires fs, List<ImportedStudentRecord> records) {
    final seenKeys = <String>{};
    final conflicts = <SectionConflict>[];
    for (final r in records) {
      if (r.rawSectionCandidate.isEmpty) continue;
      final resolved = fs.resolveSectionAlias(r.rawSectionCandidate);
      if (resolved == null) {
        final key = fs.normalizeSectionKey(r.rawSectionCandidate);
        if (seenKeys.add(key)) {
          conflicts.add(SectionConflict(r.rawSectionCandidate));
        }
      }
    }
    return ImportAnalysis(records, conflicts);
  }

  /// Enregistre définitivement les choix faits par l'utilisateur pour
  /// chaque section inconnue (fusion vers une section existante, ou
  /// création telle quelle).
  static Future<void> applySectionResolutions(
      FraisScolaires fs, List<SectionConflict> conflicts) async {
    for (final c in conflicts) {
      final target = c.createNew
          ? (c.newSectionName.trim().isEmpty
          ? c.rawCandidate
          : c.newSectionName.trim())
          : (c.mergeTarget ?? c.rawCandidate);
      await fs.registerSectionAlias(c.rawCandidate, target);
    }
  }

  /// Détecte, pour chaque enregistrement importé, un élève déjà existant
  /// avec exactement le même Nom + Post-nom + Prénom (règle déjà utilisée
  /// partout ailleurs dans l'application via findDuplicateFullName).
  static List<DuplicateMatch> findDuplicates(
      FraisScolaires fs, List<ImportedStudentRecord> records) {
    final matches = <DuplicateMatch>[];
    for (final r in records) {
      final existing = fs.findDuplicateFullName(
        nom: r.nom,
        postNom: r.postNom,
        prenom: r.prenom,
      );
      if (existing != null) {
        matches.add(DuplicateMatch(r, existing));
      }
    }
    return matches;
  }

  static String? _formatDateFromIso(String iso) {
    if (iso.trim().isEmpty) return null;
    final parts = iso.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    if (y <= 1901 || m <= 0 || d <= 0) return null; // ex: "0000-00-00"
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d)}/${two(m)}/$y';
  }

  /// Crée un nouvel Eleve pour chaque enregistrement qui n'est PAS un
  /// doublon, en répartissant intelligemment les informations du fichier :
  ///   - date de naissance -> champ natif Eleve.dateNaissance
  ///   - section/classe/sous-classe -> résolues via les alias de section
  ///     (priorité au champ "section" explicite du fichier, sinon déduction
  ///     depuis le champ "classe" comme avant)
  ///   - téléphone, tuteur, lieu de naissance, matricule, sexe -> questions
  ///     personnalisées standardisées, créées une seule fois puis réutilisées.
  static Future<int> importNewRecords(
      FraisScolaires fs, List<ImportedStudentRecord> records) async {
    int count = 0;
    for (final r in records) {
      if (r.nom.trim().isEmpty && r.postNom.trim().isEmpty) continue;

      // Sécurité anti-doublon (au cas où deux lignes du fichier lui-même
      // seraient identiques, ou qu'un doublon aurait été créé entre-temps).
      if (fs.findDuplicateFullName(
          nom: r.nom, postNom: r.postNom, prenom: r.prenom) !=
          null) {
        continue;
      }

      String section = 'Secondaire';
      String? subClasse;
      if (r.rawSectionCandidate.isNotEmpty) {
        final resolved =
            fs.resolveSectionAlias(r.rawSectionCandidate) ?? r.rawSectionCandidate;
        section = resolved;
        final resolvedKey = fs.normalizeSectionKey(resolved);
        final candidateKey = fs.normalizeSectionKey(r.rawSectionCandidate);
        // Si la section finale est différente de la valeur brute d'origine
        // (donc une vraie fusion, ex: "CG - COMMERCIALE ET GESTION" fusionné
        // dans "H.Technique"), on garde le code court comme sous-classe pour
        // ne perdre aucune granularité. Ce cas ne s'applique que lorsque la
        // section provient du découpage du champ "classe" (avec un code
        // court) ; quand la section vient du champ "section" explicite, il
        // n'y a normalement pas de code court séparé à conserver.
        if (resolvedKey != candidateKey && r.code.trim().isNotEmpty) {
          subClasse = r.code.trim();
        }
      }
      if (!fs.config.sections.contains(section)) {
        fs.config.sections.add(section);
      }

      final numero = r.numero.trim().isEmpty ? '1ère' : r.numero.trim();
      if (!fs.getClassesForSection(section).contains(numero)) {
        await fs.addClasseNumero(section, numero);
      }
      if (subClasse != null && subClasse.isNotEmpty) {
        await fs.addSubClasse(section, numero, subClasse);
      }
      final classeFinale = fs.buildFullClasseName(numero, subClasse);

      final customFields = <String, String>{};

      if (r.telephone.trim().isNotEmpty) {
        customFields[qTelephone] = r.telephone.trim();
        await fs.registerCustomFieldQuestion(qTelephone);
      }
      if (r.tuteur.trim().isNotEmpty) {
        customFields[qTuteur] = r.tuteur.trim();
        await fs.registerCustomFieldQuestion(qTuteur);
      }
      if (r.lieuNaissance.trim().isNotEmpty) {
        customFields[qLieuNaissance] = r.lieuNaissance.trim();
        await fs.registerCustomFieldQuestion(qLieuNaissance);
      }
      if (r.matricule.trim().isNotEmpty) {
        customFields[qMatricule] = r.matricule.trim();
        await fs.registerCustomFieldQuestion(qMatricule);
      }
      final sexe = r.sexe.trim();
      final sexeValide = sexe.isNotEmpty && sexe != '-';
      if (sexeValide) {
        customFields[qSexe] = sexe;
        await fs.registerCustomFieldQuestion(qSexe);
      }
      if (r.rawSectionCandidate.isNotEmpty &&
          fs.normalizeSectionKey(r.rawSectionCandidate) !=
              fs.normalizeSectionKey(section)) {
        customFields[qSectionOrigine] = r.rawSectionCandidate;
        await fs.registerCustomFieldQuestion(qSectionOrigine);
      }

      final id = fs.generateLocalStudentId(
          r.nom.trim().isNotEmpty ? r.nom.trim() : r.postNom.trim());

      final eleve = Eleve(
        id: id,
        nom: r.nom.trim(),
        postNom: r.postNom.trim(),
        prenom: r.prenom.trim(),
        classe: classeFinale,
        section: section,
        dateNaissance: _formatDateFromIso(r.dateNaissanceIso) ?? '',
        customFields: customFields,
      );

      fs.currentData.eleves.add(eleve);
      count++;
    }
    await fs.saveData();
    return count;
  }

  /// Pour chaque doublon marqué "à compléter", ajoute UNIQUEMENT les
  /// informations manquantes sur la fiche déjà existante (ne remplace ni
  /// n'efface jamais une valeur déjà renseignée).
  static Future<int> completeDuplicates(
      FraisScolaires fs, List<DuplicateMatch> matches) async {
    int count = 0;
    for (final m in matches) {
      if (!m.completeMissingInfo) continue;
      final e = m.existing;
      final r = m.incoming;
      bool changed = false;

      void setIfEmpty(String key, String value) {
        if (value.trim().isEmpty) return;
        final current = e.customFields[key]?.trim() ?? '';
        if (current.isEmpty) {
          e.customFields[key] = value.trim();
          changed = true;
        }
      }

      setIfEmpty(qTelephone, r.telephone);
      setIfEmpty(qTuteur, r.tuteur);
      setIfEmpty(qLieuNaissance, r.lieuNaissance);
      setIfEmpty(qMatricule, r.matricule);
      final sexe = r.sexe.trim();
      if (sexe.isNotEmpty && sexe != '-') setIfEmpty(qSexe, sexe);

      if (e.dateNaissance.trim().isEmpty) {
        final formatted = _formatDateFromIso(r.dateNaissanceIso);
        if (formatted != null) {
          e.dateNaissance = formatted;
          changed = true;
        }
      }

      if (changed) {
        await fs.registerCustomFieldQuestion(qTelephone);
        await fs.registerCustomFieldQuestion(qTuteur);
        await fs.registerCustomFieldQuestion(qLieuNaissance);
        await fs.registerCustomFieldQuestion(qMatricule);
        await fs.registerCustomFieldQuestion(qSexe);
        count++;
      }
    }
    if (count > 0) await fs.saveData();
    return count;
  }
}

// ==============================================================================
// ⚡ NOUVEAU — GARDE-FOU POUR L'IMPORT AUTOMATIQUE AU DÉMARRAGE
// ==============================================================================
// Mémorise (via SharedPreferences, donc SANS toucher au fichier de données
// principal de FraisScolaires) le contenu déjà proposé/importé
// automatiquement depuis le Bureau, pour ne jamais reproposer deux fois le
// même fichier tel quel à chaque redémarrage de l'application. Si le
// fichier liste.txt est ensuite modifié (nouveaux élèves ajoutés dedans),
// son contenu change, donc son "empreinte" change aussi : il sera
// automatiquement proposé à nouveau.
class AutoImportGuard {
  static const _prefKey = 'auto_import_last_hash';

  static Future<bool> alreadyHandled(String content) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_prefKey);
    return last == content.hashCode.toString();
  }

  static Future<void> markHandled(String content) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, content.hashCode.toString());
  }
}