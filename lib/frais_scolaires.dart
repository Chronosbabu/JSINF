import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:open_file/open_file.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'services/epson_printer_service.dart';
import 'dart:math';

const String serverUrl = "https://jsinf.onrender.com";

const String kDepenseGlobale = 'globale';
const String kDepenseIndependante = 'independante';
const String kDepenseMixte = 'mixte';
const String kRubriqueAutre = 'Autre';
const String kRubriqueNonAffectee = 'Non affectée';

String formatMontant(double v) {
  final neg = v < -0.5;
  final s = v.abs().round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '${neg ? '-' : ''}$buf';
}

class Depense {
  String id;
  String motif;
  double montant;
  DateTime date;
  String enregistrePar;
  String portee;
  List<String> sections;
  List<String> classes;
  String rubrique;

  Depense({
    required this.id,
    required this.motif,
    required this.montant,
    required this.date,
    this.enregistrePar = 'Direction',
    this.portee = kDepenseGlobale,
    List<String>? sections,
    List<String>? classes,
    this.rubrique = '',
  })  : sections = sections ?? [],
        classes = classes ?? [];

  factory Depense.fromJson(Map<String, dynamic> json) {
    final String porteeRaw = json['portee'] as String? ?? kDepenseGlobale;
    final String portee = (porteeRaw == kDepenseIndependante ||
        porteeRaw == kDepenseMixte)
        ? porteeRaw
        : kDepenseGlobale;
    return Depense(
      id: json['id'] as String? ?? '',
      motif: json['motif'] as String? ?? '',
      montant: (json['montant'] as num?)?.toDouble() ?? 0.0,
      date: DateTime.tryParse(json['date'] as String? ?? '') ??
          DateTime.now(),
      enregistrePar: json['enregistrePar'] as String? ?? 'Direction',
      portee: portee,
      sections: (json['sections'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ??
          [],
      classes: (json['classes'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ??
          [],
      rubrique: json['rubrique'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'motif': motif,
    'montant': montant,
    'date': date.toIso8601String(),
    'enregistrePar': enregistrePar,
    'portee': portee,
    'sections': sections,
    'classes': classes,
    'rubrique': rubrique,
  };

  String get dateFormatee {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} à '
        '${two(date.hour)}:${two(date.minute)}';
  }

  String get porteeLabel {
    switch (portee) {
      case kDepenseIndependante:
        return 'Indépendante';
      case kDepenseMixte:
        return 'Mixte';
      case kDepenseGlobale:
      default:
        return 'Globale';
    }
  }

  String get rubriqueAffichee =>
      rubrique.trim().isEmpty ? kRubriqueNonAffectee : rubrique.trim();

  String get sectionsLabel {
    if (portee == kDepenseGlobale || sections.isEmpty) {
      return "Toute l'école";
    }
    return sections.join(', ');
  }

  String get classesLabel {
    if (portee == kDepenseGlobale) return 'Toutes';
    if (classes.isEmpty) return 'Toutes les classes';
    return classes.join(', ');
  }
}

class RubriqueStat {
  final String rubrique;
  final double pourcentage;
  double collecte;
  double globales = 0;
  double independantes = 0;
  double mixtes = 0;

  RubriqueStat({
    required this.rubrique,
    required this.pourcentage,
    required this.collecte,
  });

  double get total => globales + independantes + mixtes;
  double get reste => collecte - total;
}

class SectionStat {
  final String section;
  double collecte;
  double independantes = 0;
  double mixtes = 0;

  SectionStat({required this.section, required this.collecte});

  double get total => independantes + mixtes;
  double get reste => collecte - total;
  bool get aDeLActivite => collecte != 0 || total != 0;
}

class DepensePeriodeStats {
  final String period;
  final List<Depense> depenses;
  final List<RubriqueStat> rubriques;
  final List<SectionStat> sections;
  final double totalCollecte;
  final double globales;
  final double independantes;
  final double mixtes;
  final bool globalesExclues;

  DepensePeriodeStats({
    required this.period,
    required this.depenses,
    required this.rubriques,
    required this.sections,
    required this.totalCollecte,
    required this.globales,
    required this.independantes,
    required this.mixtes,
    required this.globalesExclues,
  });

  double get totalDepenses => globales + independantes + mixtes;
  double get reste => totalCollecte - totalDepenses;

  RubriqueStat? rubriqueParNom(String nom) {
    for (final r in rubriques) {
      if (r.rubrique == nom) return r;
    }
    return null;
  }
}

class GroupeOption {
  final String nom;
  final List<String> sections;
  final bool estOption;

  GroupeOption({
    required this.nom,
    required this.sections,
    required this.estOption,
  });
}

// ============================================================================
// ⚡ NOUVEAU — GROUPE DE "AUTRES FRAIS" PORTANT LE MÊME NOM
// ============================================================================
// Quand plusieurs frais additionnels ont le même nom (ex : "Frais de l'État"
// ajouté une fois par classe/section avec des montants différents), ils sont
// considérés comme UN SEUL type de frais UNIQUEMENT pour la génération des
// rapports. Rien n'est modifié dans les données : chaque frais garde son id,
// son montant et ses paiements. Ce groupe sert seulement à les rassembler
// dans le rapport PDF.
// ============================================================================
class AutreFraisGroupe {
  final String cle;
  final String nom;
  final List<String> ids;
  final double montantMin;
  final double montantMax;

  AutreFraisGroupe({
    required this.cle,
    required this.nom,
    required this.ids,
    required this.montantMin,
    required this.montantMax,
  });

  int get nombreDeFraisFusionnes => ids.length;
}

// ============================================================================
// ⚡ NOUVEAU — TRANCHE D'UN "AUTRE FRAIS" (ex : Première tranche du Frais de
// l'État). Une tranche a un nom et un montant. Les tranches d'un frais sont
// stockées dans AutreFrais.tranchesParCle, par cible (toute l'école, une
// section ou une classe).
// ============================================================================
class AutreFraisTranche {
  String id;
  String nom;
  double montant;

  AutreFraisTranche({
    required this.id,
    required this.nom,
    required this.montant,
  });

  factory AutreFraisTranche.fromJson(Map<String, dynamic> json) =>
      AutreFraisTranche(
        id: json['id'] as String? ?? '',
        nom: json['nom'] as String? ?? '',
        montant: (json['montant'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nom': nom,
    'montant': montant,
  };
}

class AutreFrais {
  String id;
  String nom;
  double montant;
  String scope;
  String? section;
  String? classe;
  DateTime dateCreation;
  Map<String, double> montantsParSection;
  Map<String, double> montantsParClasse;
  // ⚡ NOUVEAU — tranches par cible :
  //   'ALL'                  -> toute l'école
  //   'S:<section>'          -> une section
  //   'C:<section>|<classe>' -> une classe (numéro de classe, sans sous-classe)
  // Si aucune tranche n'est définie pour un élève, le frais se paie en une
  // seule fois comme avant.
  Map<String, List<AutreFraisTranche>> tranchesParCle;

  AutreFrais({
    required this.id,
    required this.nom,
    required this.montant,
    this.scope = 'all',
    this.section,
    this.classe,
    DateTime? dateCreation,
    Map<String, double>? montantsParSection,
    Map<String, double>? montantsParClasse,
    Map<String, List<AutreFraisTranche>>? tranchesParCle,
  })  : dateCreation = dateCreation ?? DateTime.now(),
        montantsParSection = montantsParSection ?? {},
        montantsParClasse = montantsParClasse ?? {},
        tranchesParCle = tranchesParCle ?? {};

  factory AutreFrais.fromJson(Map<String, dynamic> json) => AutreFrais(
    id: json['id'] as String? ?? '',
    nom: json['nom'] as String? ?? '',
    montant: (json['montant'] as num?)?.toDouble() ?? 0.0,
    scope: json['scope'] as String? ?? 'all',
    section: json['section'] as String?,
    classe: json['classe'] as String?,
    dateCreation:
    DateTime.tryParse(json['dateCreation'] as String? ?? '') ??
        DateTime.now(),
    montantsParSection:
    (json['montantsParSection'] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(key, (value as num).toDouble()),
    ) ??
        {},
    montantsParClasse:
    (json['montantsParClasse'] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(key, (value as num).toDouble()),
    ) ??
        {},
    tranchesParCle:
    (json['tranchesParCle'] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(
        key,
        (value as List<dynamic>)
            .map((e) =>
            AutreFraisTranche.fromJson(e as Map<String, dynamic>))
            .toList(),
      ),
    ) ??
        {},
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nom': nom,
    'montant': montant,
    'scope': scope,
    'section': section,
    'classe': classe,
    'dateCreation': dateCreation.toIso8601String(),
    'montantsParSection': montantsParSection,
    'montantsParClasse': montantsParClasse,
    'tranchesParCle': tranchesParCle.map(
          (key, value) => MapEntry(key, value.map((t) => t.toJson()).toList()),
    ),
  };
}

class AutreFraisPaiement {
  String id;
  String autreFraisId;
  String autreFraisNom;
  String eleveId;
  double montant;
  DateTime date;
  String enregistrePar;
  // ⚡ NOUVEAU — informations de tranche (vides si le frais a été payé en une
  // seule fois, sans tranche).
  String trancheId;
  String trancheNom;
  int trancheNumero;
  int trancheTotal;

  AutreFraisPaiement({
    required this.id,
    required this.autreFraisId,
    required this.autreFraisNom,
    required this.eleveId,
    required this.montant,
    required this.date,
    this.enregistrePar = 'Direction',
    this.trancheId = '',
    this.trancheNom = '',
    this.trancheNumero = 0,
    this.trancheTotal = 0,
  });

  factory AutreFraisPaiement.fromJson(Map<String, dynamic> json) =>
      AutreFraisPaiement(
        id: json['id'] as String? ?? '',
        autreFraisId: json['autreFraisId'] as String? ?? '',
        autreFraisNom: json['autreFraisNom'] as String? ?? '',
        eleveId: json['eleveId'] as String? ?? '',
        montant: (json['montant'] as num?)?.toDouble() ?? 0.0,
        date: DateTime.tryParse(json['date'] as String? ?? '') ??
            DateTime.now(),
        enregistrePar: json['enregistrePar'] as String? ?? 'Direction',
        trancheId: json['trancheId'] as String? ?? '',
        trancheNom: json['trancheNom'] as String? ?? '',
        trancheNumero: (json['trancheNumero'] as num?)?.toInt() ?? 0,
        trancheTotal: (json['trancheTotal'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'autreFraisId': autreFraisId,
    'autreFraisNom': autreFraisNom,
    'eleveId': eleveId,
    'montant': montant,
    'date': date.toIso8601String(),
    'enregistrePar': enregistrePar,
    'trancheId': trancheId,
    'trancheNom': trancheNom,
    'trancheNumero': trancheNumero,
    'trancheTotal': trancheTotal,
  };

  String get dateFormatee {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} à '
        '${two(date.hour)}:${two(date.minute)}';
  }

  // ⚡ NOUVEAU — libellé court de la tranche, ex : "Deuxième tranche (2/3)".
  // Vide si le paiement n'est pas lié à une tranche.
  String get trancheLibelle {
    if (trancheNom.trim().isEmpty) return '';
    if (trancheNumero > 0 && trancheTotal > 0) {
      return '${trancheNom.trim()} ($trancheNumero/$trancheTotal)';
    }
    return trancheNom.trim();
  }
}

class AutreFraisAdministration {
  String id;
  String nom;
  double pourcentage;

  AutreFraisAdministration({
    required this.id,
    required this.nom,
    required this.pourcentage,
  });

  factory AutreFraisAdministration.fromJson(Map<String, dynamic> json) =>
      AutreFraisAdministration(
        id: json['id'] as String? ?? '',
        nom: json['nom'] as String? ?? '',
        pourcentage: (json['pourcentage'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nom': nom,
    'pourcentage': pourcentage,
  };
}

class RepartitionDetail {
  final String label;
  final double total;
  final Map<String, double> parAdministration;

  RepartitionDetail({
    required this.label,
    required this.total,
    required this.parAdministration,
  });
}

class AdminAuditLog {
  String id;
  String action;
  String eleveId;
  String eleveNomComplet;
  String classe;
  String mois;
  double montantAvant;
  double montantApres;
  DateTime date;

  AdminAuditLog({
    required this.id,
    required this.action,
    required this.eleveId,
    required this.eleveNomComplet,
    required this.classe,
    required this.mois,
    required this.montantAvant,
    required this.montantApres,
    DateTime? date,
  }) : date = date ?? DateTime.now();

  factory AdminAuditLog.fromJson(Map<String, dynamic> json) => AdminAuditLog(
    id: json['id'] as String? ?? '',
    action: json['action'] as String? ?? '',
    eleveId: json['eleveId'] as String? ?? '',
    eleveNomComplet: json['eleveNomComplet'] as String? ?? '',
    classe: json['classe'] as String? ?? '',
    mois: json['mois'] as String? ?? '',
    montantAvant: (json['montantAvant'] as num?)?.toDouble() ?? 0.0,
    montantApres: (json['montantApres'] as num?)?.toDouble() ?? 0.0,
    date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'action': action,
    'eleveId': eleveId,
    'eleveNomComplet': eleveNomComplet,
    'classe': classe,
    'mois': mois,
    'montantAvant': montantAvant,
    'montantApres': montantApres,
    'date': date.toIso8601String(),
  };

  String get dateFormatee {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} à '
        '${two(date.hour)}:${two(date.minute)}';
  }
}

class Signataire {
  String id;
  String nom;
  String fonction;

  Signataire({
    required this.id,
    required this.nom,
    required this.fonction,
  });

  factory Signataire.fromJson(Map<String, dynamic> json) => Signataire(
    id: json['id'] as String? ?? '',
    nom: json['nom'] as String? ?? '',
    fonction: json['fonction'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nom': nom,
    'fonction': fonction,
  };
}

class FraisScolaires {
  SchoolConfig config;
  SchoolYearData currentData = SchoolYearData(eleves: []);
  String currentYear = '2025-2026';
  Map<String, SchoolYearData> history = {};
  String? _dataFilePath;
  String? lastSelectedClassFilter;
  String? lastSelectedSectionFilter;
  String? schoolCode;
  Map<String, List<Depense>> depensesByYear = {};
  List<AutreFrais> autresFrais = [];
  Map<String, List<AutreFraisPaiement>> autresFraisPaiementsByYear = {};
  List<AutreFraisAdministration> autresFraisAdministrations = [];
  List<AdminAuditLog> adminAuditLog = [];
  List<Signataire> signataires = [];
  String? lastReportCity;
  List<String> printedReceiptKeys = [];
  List<Map<String, dynamic>> receiptQueue = [];
  List<Map<String, dynamic>> localAccessKeys = [];
  List<Map<String, dynamic>> localPendingPayments = [];
  List<Map<String, dynamic>> localPendingRegistrations = [];
  List<Map<String, dynamic>> localPendingAutresFraisPayments = [];
  Map<String, List<String>> localAttendance = {};
  List<Map<String, dynamic>> localCommunicationsLog = [];

  // ==========================================================================
  // ⚡ NOUVEAU — HISTORIQUE DES ÉLÈVES SUPPRIMÉS / EXCLUS
  // ==========================================================================
  // Quand un élève est supprimé ou exclu définitivement du registre actif :
  //   - il n'apparaît plus dans currentData.eleves (donc plus dans les listes
  //     et filtres du registre normal) ;
  //   - MAIS tout l'argent qu'il avait déjà payé reste comptabilisé dans les
  //     totaux de l'école (caisse, totaux par section, par classe, par mois,
  //     par année), car les fonctions de calcul monétaire ci-dessous
  //     additionnent aussi elevesSupprimesData.eleves ;
  //   - son historique complet (transactions, informations) est conservé
  //     dans elevesSupprimesData et reste consultable dans la page
  //     "Élèves Supprimés", tant qu'on ne le supprime pas volontairement et
  //     définitivement depuis cette page (protégé par mot de passe admin).
  SchoolYearData elevesSupprimesData = SchoolYearData(eleves: []);
  Map<String, String> dateSuppressionEleves = {};
  Map<String, String> motifSuppressionEleves = {};

  Map<String, List<String>> optionsSections = {};

  int _localIdCounter = 0;

  bool _isFlushingReceiptQueue = false;

  final List<String> months = [
    'Septembre', 'Octobre', 'Novembre', 'Decembre',
    'Janvier', 'Fevrier', 'Mars', 'Avril', 'Mai', 'Juin'
  ];

  static const List<String> _joursSemaine = [
    'Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'
  ];

  static const List<String> _moisCalendrier = [
    'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
    'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'
  ];

  FraisScolaires() : config = SchoolConfig(schoolName: "EduPay School RDC");

  int _schoolMonthIndexForToday() {
    final calendarMonth = DateTime.now().month;
    if (calendarMonth >= 9 && calendarMonth <= 12) {
      return calendarMonth - 9;
    } else if (calendarMonth >= 1 && calendarMonth <= 6) {
      return calendarMonth + 3;
    }
    return -1;
  }

  String? get currentSchoolMonthName {
    final idx = _schoolMonthIndexForToday();
    if (idx < 0 || idx >= months.length) return null;
    return months[idx];
  }

  String get _dateGenerationFormatee {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final jour = _joursSemaine[now.weekday - 1];
    return '$jour ${two(now.day)}/${two(now.month)}/${now.year} à '
        '${two(now.hour)}:${two(now.minute)}';
  }

  String getMoisPayesPourDate(Eleve eleve, [String? date]) {
    final targetDate = date ?? DateTime.now().toString().split(' ')[0];
    final moisDuJour = <String>[];
    for (final t in eleve.transactions) {
      if (t['date'] == targetDate) {
        final mois = t['mois']?.toString() ?? '';
        if (mois.isNotEmpty && !moisDuJour.contains(mois)) {
          moisDuJour.add(mois);
        }
      }
    }
    moisDuJour.sort(
            (a, b) => months.indexOf(a).compareTo(months.indexOf(b)));
    return moisDuJour.join(', ');
  }

  List<pw.Widget> _buildSignatureSection([String? city]) {
    if (signataires.isEmpty) return [];

    final villeAffichee =
    (city != null && city.trim().isNotEmpty) ? city.trim() : 'Lubumbashi';

    final rows = <List<Signataire>>[];
    for (var i = 0; i < signataires.length; i += 3) {
      final end = (i + 3 > signataires.length) ? signataires.length : i + 3;
      rows.add(signataires.sublist(i, end));
    }

    pw.Widget buildColonne(Signataire s) {
      return pw.Expanded(
        child: pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 14),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.SizedBox(height: 34),
              pw.Container(
                decoration: const pw.BoxDecoration(
                  border: pw.Border(
                    top: pw.BorderSide(width: 0.8, color: PdfColors.black),
                  ),
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                s.nom.isNotEmpty ? s.nom : ' ',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                s.fonction.isNotEmpty ? s.fonction : ' ',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 9,
                  fontStyle: pw.FontStyle.italic,
                  color: PdfColors.grey700,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return [
      pw.SizedBox(height: 36),
      pw.Divider(thickness: 0.6, color: PdfColors.grey400),
      pw.SizedBox(height: 4),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          'Fait à $villeAffichee, le : $_dateGenerationFormatee',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        ),
      ),
      pw.SizedBox(height: 26),
      ...rows.map((rowSignataires) {
        final widgets = rowSignataires.map(buildColonne).toList();
        while (widgets.length < 3) {
          widgets.add(pw.Expanded(child: pw.SizedBox()));
        }
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 24),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: widgets,
          ),
        );
      }),
    ];
  }

  Map<int, pw.TableColumnWidth> _buildColumnWidths(List<double> flexRatios) {
    return {
      for (var i = 0; i < flexRatios.length; i++)
        i: pw.FlexColumnWidth(flexRatios[i]),
    };
  }

  double _tableCellFontSize(int columnCount) {
    if (columnCount <= 6) return 9;
    if (columnCount <= 8) return 8.5;
    if (columnCount <= 10) return 8;
    if (columnCount <= 13) return 7.5;
    return 6.5;
  }

  double _tableHeaderFontSize(int columnCount) {
    if (columnCount <= 6) return 9;
    if (columnCount <= 8) return 8.5;
    if (columnCount <= 10) return 8;
    if (columnCount <= 13) return 7.5;
    return 7;
  }

  Future<Map<String, dynamic>> createPromoterRequest({
    required String type,
    required Eleve eleve,
    Map<String, dynamic>? transaction,
    String? mois,
    double? nouveauMontant,
  }) async {
    if (schoolCode == null || schoolCode!.isEmpty) {
      return {
        'success': false,
        'error': "Code école manquant. Sauvegardez d'abord sur le serveur."
      };
    }
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/school/create_promoter_request'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'school_code': schoolCode,
          'type': type,
          'eleve_id': eleve.id,
          'eleve_nom': '${eleve.nom} ${eleve.postNom} ${eleve.prenom}',
          'classe': eleve.classe,
          'section': eleve.section,
          'mois': mois ?? transaction?['mois'] ?? '',
          'transaction_id': transaction?['id'] ?? '',
          'montant_actuel': (transaction?['amount'] as num?)?.toDouble(),
          'nouveau_montant': nouveauMontant,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {'success': true, 'request_id': data['request_id']};
      }
      return {
        'success': false,
        'error': 'Statut ${response.statusCode} : ${response.body}',
      };
    } on SocketException catch (e) {
      return {'success': false, 'error': 'Aucune connexion réseau : $e'};
    } catch (e) {
      return {'success': false, 'error': 'Erreur inattendue : $e'};
    }
  }

  Future<Map<String, dynamic>> checkPromoterRequestStatus(
      String requestId) async {
    if (schoolCode == null || schoolCode!.isEmpty) {
      return {'status': 'pending'};
    }
    try {
      final response = await http
          .get(Uri.parse(
          '$serverUrl/school/get_request_status?school_code=$schoolCode&request_id=$requestId'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        return Map<String, dynamic>.from(json.decode(response.body));
      }
      return {'status': 'pending'};
    } catch (_) {
      return {'status': 'pending'};
    }
  }

  Future<void> applyApprovedRequest(
      String type,
      Eleve eleve,
      Map<String, dynamic> transaction,
      Map<String, dynamic> requestData,
      ) async {
    if (type == 'cancel') {
      await cancelTransaction(eleve: eleve, transaction: transaction);
    } else if (type == 'modify') {
      final nouveau = (requestData['nouveau_montant'] as num?)?.toDouble();
      if (nouveau != null) {
        await modifyTransactionAmount(
            eleve: eleve, transaction: transaction, newAmount: nouveau);
      }
    } else if (type == 'reprint') {
      await forceReprintTransactionReceipt(
          eleve: eleve, transaction: transaction);
    }
  }

  Future<bool> forceReprintTransactionReceipt({
    required Eleve eleve,
    required Map<String, dynamic> transaction,
  }) async {
    final printerName = await _currentPrinterName();
    if (printerName.isEmpty) return false;
    final logoBytes = await _loadLogoBytesForPrinting();
    final bool ok = await EscPosPrinterService.printTransactionsReceipt(
      printerName: printerName,
      schoolName: config.schoolName,
      currentYear: currentYear,
      studentName: '${eleve.nom} ${eleve.postNom} ${eleve.prenom}',
      studentId: eleve.id,
      classe: eleve.classe,
      section: eleve.section,
      transactions: [transaction],
      logoBytes: logoBytes,
      duplicata: true,
    );
    if (ok) {
      transaction['receiptConfirmed'] = true;
      final key = _principalReceiptKey(eleve, transaction);
      if (!isReceiptPrinted(key)) {
        await _markReceiptPrinted(key);
      } else {
        await saveData();
      }
    }
    return ok;
  }

  Map<String, dynamic> computePromoterSummary() {
    final today = DateTime.now().toString().split(' ')[0];

    final Map<String, double> moneyTodayBySection =
    getMoneyCollectedTodayBySection();
    final double moneyTodayPrincipal =
    moneyTodayBySection.values.fold(0.0, (sum, v) => sum + v);

    double moneyTodayAutresFrais = 0;
    for (final p in (autresFraisPaiementsByYear[currentYear] ?? [])) {
      if (p.date.toString().split(' ')[0] == today) {
        moneyTodayAutresFrais += p.montant;
      }
    }

    final Map<String, double> moneyThisMonthBySection =
    getMoneyCollectedThisMonthBySection();
    final double moneyThisMonthPrincipal =
    moneyThisMonthBySection.values.fold(0.0, (sum, v) => sum + v);

    double moneyThisMonthAutresFrais = 0;
    final DateTime now = DateTime.now();
    for (final p in (autresFraisPaiementsByYear[currentYear] ?? [])) {
      if (p.date.year == now.year && p.date.month == now.month) {
        moneyThisMonthAutresFrais += p.montant;
      }
    }

    final double totalPrincipalYear = getYearTotalCollected();
    final double totalAutresFraisYear =
    (autresFraisPaiementsByYear[currentYear] ?? [])
        .fold(0.0, (sum, p) => sum + p.montant);
    final Map<String, double> moneyThisYearBySection = getTotalBySection();

    final adminDistToday = calculateAdminDistribution(moneyTodayPrincipal);
    final adminDistThisMonth =
    calculateAdminDistribution(moneyThisMonthPrincipal);
    final adminDistThisYear = calculateAdminDistribution(totalPrincipalYear);

    final autresFraisAdminDistToday =
    calculateAutresFraisAdminDistribution(moneyTodayAutresFrais);
    final autresFraisAdminDistThisMonth =
    calculateAutresFraisAdminDistribution(moneyThisMonthAutresFrais);
    final autresFraisAdminDistThisYear =
    calculateAutresFraisAdminDistribution(totalAutresFraisYear);

    Map<String, Map<String, double>> distBySection(
        Map<String, double> amountsBySection) {
      final result = <String, Map<String, double>>{};
      amountsBySection.forEach((section, amount) {
        result[section] = calculateAdminDistribution(amount);
      });
      return result;
    }

    final adminDistributionTodayBySection = distBySection(moneyTodayBySection);
    final adminDistributionThisMonthBySection =
    distBySection(moneyThisMonthBySection);
    final adminDistributionThisYearBySection =
    distBySection(moneyThisYearBySection);

    final Map<String, int> studentsBySection = {};
    final Map<String, int> studentsByClass = {};
    for (final e in currentData.eleves) {
      studentsBySection[e.section] = (studentsBySection[e.section] ?? 0) + 1;
      final key = "${e.section} - ${e.classe}";
      studentsByClass[key] = (studentsByClass[key] ?? 0) + 1;
    }

    return {
      'schoolName': config.schoolName,
      'currentYear': currentYear,
      'currentMonthName': currentSchoolMonthName ?? '',

      'moneyToday': moneyTodayPrincipal + moneyTodayAutresFrais,
      'moneyTodayPrincipal': moneyTodayPrincipal,
      'moneyTodayAutresFrais': moneyTodayAutresFrais,
      'adminDistributionToday': adminDistToday,
      'autresFraisAdminDistributionToday': autresFraisAdminDistToday,
      'moneyTodayBySection': moneyTodayBySection,
      'adminDistributionTodayBySection': adminDistributionTodayBySection,

      'moneyThisMonth': moneyThisMonthPrincipal + moneyThisMonthAutresFrais,
      'moneyThisMonthPrincipal': moneyThisMonthPrincipal,
      'moneyThisMonthAutresFrais': moneyThisMonthAutresFrais,
      'adminDistributionThisMonth': adminDistThisMonth,
      'autresFraisAdminDistributionThisMonth': autresFraisAdminDistThisMonth,
      'moneyThisMonthBySection': moneyThisMonthBySection,
      'adminDistributionThisMonthBySection':
      adminDistributionThisMonthBySection,

      'adminDistributionThisYear': adminDistThisYear,
      'autresFraisAdminDistributionThisYear': autresFraisAdminDistThisYear,
      'moneyThisYearBySection': moneyThisYearBySection,
      'adminDistributionThisYearBySection':
      adminDistributionThisYearBySection,

      'totalStudents': currentData.eleves.length,
      'studentsBySection': studentsBySection,
      'studentsByClass': studentsByClass,
      'totalAmountGlobal': totalPrincipalYear + totalAutresFraisYear,
      'totalAmountBySection': getTotalBySection(),
      'totalAmountByClass': getTotalByClass(),
      'totalDepenses': getTotalDepenses(),
      'totalDepensesToday': getTotalDepensesToday(),
      'totalDepensesThisMonth': getTotalDepensesThisMonth(),
      'depensesParPortee': {
        kDepenseGlobale: getTotalDepensesParPortee(kDepenseGlobale),
        kDepenseIndependante: getTotalDepensesParPortee(kDepenseIndependante),
        kDepenseMixte: getTotalDepensesParPortee(kDepenseMixte),
      },
      'soldeNet': getSoldeNetActuel(),
    };
  }

  Future<void> pushPromoterSummary() async {
    if (schoolCode == null || schoolCode!.isEmpty) return;
    try {
      final summary = computePromoterSummary();
      await http.post(
        Uri.parse('$serverUrl/school/push_promoter_summary'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'school_code': schoolCode, 'summary': summary}),
      ).timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  Future<void> cancelTransaction({
    required Eleve eleve,
    required Map<String, dynamic> transaction,
  }) async {
    final mois = transaction['mois']?.toString() ?? '';
    final montant = (transaction['amount'] as num?)?.toDouble() ?? 0.0;

    final currentPaid = eleve.paid[mois] ?? 0;
    double newPaid = currentPaid - montant;
    if (newPaid < 0) newPaid = 0;
    eleve.paid[mois] = newPaid;

    eleve.transactions.remove(transaction);

    recalculerRepartitionMoisPourEleve(eleve);

    adminAuditLog.add(AdminAuditLog(
      id: 'AUD${DateTime.now().millisecondsSinceEpoch}',
      action: 'annulation',
      eleveId: eleve.id,
      eleveNomComplet: '${eleve.nom} ${eleve.postNom} ${eleve.prenom}',
      classe: eleve.classe,
      mois: mois,
      montantAvant: montant,
      montantApres: 0,
    ));

    await saveData();
  }

  Future<void> modifyTransactionAmount({
    required Eleve eleve,
    required Map<String, dynamic> transaction,
    required double newAmount,
  }) async {
    final mois = transaction['mois']?.toString() ?? '';
    final oldAmount = (transaction['amount'] as num?)?.toDouble() ?? 0.0;

    final currentPaid = eleve.paid[mois] ?? 0;
    double newPaid = currentPaid - oldAmount + newAmount;
    if (newPaid < 0) newPaid = 0;
    eleve.paid[mois] = newPaid;

    transaction['amount'] = newAmount;
    transaction['modifiePar'] = 'Promoteur';
    transaction['modifieLe'] = DateTime.now().toString().split(' ')[0];

    recalculerRepartitionMoisPourEleve(eleve);

    adminAuditLog.add(AdminAuditLog(
      id: 'AUD${DateTime.now().millisecondsSinceEpoch}',
      action: 'modification',
      eleveId: eleve.id,
      eleveNomComplet: '${eleve.nom} ${eleve.postNom} ${eleve.prenom}',
      classe: eleve.classe,
      mois: mois,
      montantAvant: oldAmount,
      montantApres: newAmount,
    ));

    await saveData();
  }

  List<AdminAuditLog> getAdminAuditLog() {
    final list = List<AdminAuditLog>.from(adminAuditLog);
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  List<Signataire> getSignataires() => List<Signataire>.from(signataires);

  Future<Signataire> addSignataire({
    required String nom,
    required String fonction,
  }) async {
    final signataire = Signataire(
      id: 'SIG${DateTime.now().millisecondsSinceEpoch}',
      nom: nom.trim(),
      fonction: fonction.trim(),
    );
    signataires.add(signataire);
    await saveData();
    return signataire;
  }

  Future<void> updateSignataire(
      String id, {
        required String nom,
        required String fonction,
      }) async {
    for (var s in signataires) {
      if (s.id == id) {
        s.nom = nom.trim();
        s.fonction = fonction.trim();
        break;
      }
    }
    await saveData();
  }

  Future<void> deleteSignataire(String id) async {
    signataires.removeWhere((s) => s.id == id);
    await saveData();
  }

  Future<void> setLastReportCity(String city) async {
    final trimmed = city.trim();
    lastReportCity = trimmed.isEmpty ? null : trimmed;
    await saveData();
  }

  String normalizeSectionKey(String raw) => raw.trim().toUpperCase();

  String? resolveSectionAlias(String rawSectionCandidate) {
    final key = normalizeSectionKey(rawSectionCandidate);
    if (config.sectionAliases.containsKey(key)) {
      return config.sectionAliases[key];
    }
    for (final s in config.sections) {
      if (normalizeSectionKey(s) == key) return s;
    }
    return null;
  }

  Future<void> registerSectionAlias(
      String rawSectionCandidate, String targetSection) async {
    final key = normalizeSectionKey(rawSectionCandidate);
    config.sectionAliases[key] = targetSection;
    if (!config.sections.contains(targetSection)) {
      config.sections.add(targetSection);
    }
    await saveData();
  }

  Future<void> registerCustomFieldQuestion(String question) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty) return;
    final exists = config.customFieldQuestions
        .any((q) => q.trim().toLowerCase() == trimmed.toLowerCase());
    if (!exists) {
      config.customFieldQuestions.add(trimmed);
      await saveData();
    }
  }

  bool isReceiptPrinted(String key) => printedReceiptKeys.contains(key);

  Future<Uint8List?> _loadLogoBytesForPrinting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasLogo = prefs.getBool('has_logo') ?? false;
      if (!hasLogo) return null;
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/school_logo.png');
      if (await file.exists()) {
        return await file.readAsBytes();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _currentPrinterName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('printer_name') ?? '';
  }

  String _principalReceiptKey(Eleve eleve, Map<String, dynamic> transaction) {
    final String transactionId = transaction['id']?.toString() ?? '';
    if (transactionId.isNotEmpty) {
      return 'principal|${eleve.id}|$transactionId';
    }
    final String mois = transaction['mois']?.toString() ?? '';
    return 'principal|${eleve.id}|$mois|${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<void> _markReceiptPrinted(String key) async {
    if (!printedReceiptKeys.contains(key)) {
      printedReceiptKeys.add(key);
    }
    receiptQueue.removeWhere((r) => r['key'] == key);
    await saveData();
  }

  Future<void> _enqueueReceipt({
    required String key,
    required String type,
    required String eleveId,
    required Map<String, dynamic> data,
  }) async {
    final existingIndex = receiptQueue.indexWhere((r) => r['key'] == key);
    final entry = <String, dynamic>{
      'key': key,
      'type': type,
      'eleveId': eleveId,
      'data': data,
      'dateAjout': DateTime.now().toIso8601String(),
    };
    if (existingIndex != -1) {
      receiptQueue[existingIndex] = entry;
    } else {
      receiptQueue.add(entry);
    }
    await saveData();
  }

  Future<bool> printOrQueuePrincipalReceipt({
    required Eleve eleve,
    required Map<String, dynamic> transaction,
  }) async {
    final String transactionId = transaction['id']?.toString() ?? '';
    final String mois = transaction['mois']?.toString() ?? '';
    final double montantPaye =
        (transaction['amount'] as num?)?.toDouble() ?? 0.0;

    final key = _principalReceiptKey(eleve, transaction);
    if (isReceiptPrinted(key)) return false;

    final double montantRequis = getRequiredForMonthForEleve(eleve, mois);
    final double totalPaye = getStudentTotalPaid(eleve);
    final double totalRequis = getStudentPending(eleve) + totalPaye;
    final double resteAPayerMoisBrut = montantRequis - (eleve.paid[mois] ?? 0);
    final double resteAPayerMois =
    resteAPayerMoisBrut < 0 ? 0.0 : resteAPayerMoisBrut;

    final data = <String, dynamic>{
      'studentName': '${eleve.nom} ${eleve.postNom} ${eleve.prenom}',
      'studentId': eleve.id,
      'classe': eleve.classe,
      'section': eleve.section,
      'moisPaye': mois,
      'montantPaye': montantPaye,
      'montantRequis': montantRequis,
      'resteAPayerMois': resteAPayerMois,
      'totalDejaPayeAnnee': totalPaye,
      'totalRequis': totalRequis,
      'transactionId': transactionId,
      'historiqueTransactions':
      eleve.transactions.map((t) => Map<String, dynamic>.from(t)).toList(),
    };

    final printerName = await _currentPrinterName();
    if (printerName.isNotEmpty) {
      final logoBytes = await _loadLogoBytesForPrinting();
      final bool ok = await EscPosPrinterService.printReceipt(
        printerName: printerName,
        schoolName: config.schoolName,
        currentYear: currentYear,
        studentName: data['studentName'] as String,
        studentId: data['studentId'] as String,
        classe: data['classe'] as String,
        section: data['section'] as String,
        moisPaye: mois,
        montantPaye: montantPaye,
        montantRequis: montantRequis,
        resteAPayerMois: resteAPayerMois,
        totalDejaPayeAnnee: totalPaye,
        totalRequis: totalRequis,
        historiqueTransactions: List<Map<String, dynamic>>.from(
            data['historiqueTransactions'] as List),
        logoBytes: logoBytes,
      );
      if (ok) {
        await _markReceiptPrinted(key);
        return true;
      }
    }

    await _enqueueReceipt(
      key: key,
      type: 'principal',
      eleveId: eleve.id,
      data: data,
    );
    return false;
  }

  Future<bool> retryPrintPrincipalReceipt({
    required Eleve eleve,
    required Map<String, dynamic> transaction,
    required String printerName,
    Uint8List? logoBytes,
  }) async {
    final key = _principalReceiptKey(eleve, transaction);

    if (isReceiptPrinted(key)) {
      transaction['receiptConfirmed'] = true;
      await saveData();
      return true;
    }

    final bool ok = await EscPosPrinterService.printTransactionsReceipt(
      printerName: printerName,
      schoolName: config.schoolName,
      currentYear: currentYear,
      studentName: '${eleve.nom} ${eleve.postNom} ${eleve.prenom}',
      studentId: eleve.id,
      classe: eleve.classe,
      section: eleve.section,
      transactions: [transaction],
      logoBytes: logoBytes,
      duplicata: false,
    );

    if (ok) {
      transaction['receiptConfirmed'] = true;
      await _markReceiptPrinted(key);
    }

    return ok;
  }

  // ==========================================================================
  // ⚡ MODIFIÉ — REÇU D'UN "AUTRE FRAIS" AVEC PRISE EN COMPTE DES TRANCHES
  // ==========================================================================
  // Si le paiement concerne une tranche, le titre imprimé sur le reçu devient
  // par exemple "Frais de l'État - Deuxième tranche (2/3)" et le montant
  // imprimé est celui de la tranche payée. La clé anti-doublon contient
  // aussi l'id de la tranche : chaque tranche a son propre reçu, et un reçu
  // déjà imprimé n'est jamais réimprimé automatiquement.
  // Sans paiement de tranche (frais sans tranche), le comportement est
  // strictement identique à avant.
  // ==========================================================================
  Future<bool> printOrQueueAutreFraisReceipt({
    required Eleve eleve,
    required AutreFrais frais,
    AutreFraisPaiement? paiement,
  }) async {
    final bool avecTranche =
        paiement != null && paiement.trancheId.trim().isNotEmpty;
    final key = avecTranche
        ? 'autre_frais|${eleve.id}|${frais.id}|${paiement.trancheId}'
        : 'autre_frais|${eleve.id}|${frais.id}';
    if (isReceiptPrinted(key)) return false;

    final double montant =
        paiement?.montant ?? getMontantAutreFraisPourEleve(frais, eleve);

    final String titre = avecTranche
        ? '${frais.nom} - ${paiement.trancheLibelle}'
        : frais.nom;

    final data = <String, dynamic>{
      'titreFrais': titre,
      'studentName': '${eleve.nom} ${eleve.postNom} ${eleve.prenom}',
      'classe': eleve.classe,
      'section': eleve.section,
      'montant': montant,
    };

    final printerName = await _currentPrinterName();
    if (printerName.isNotEmpty) {
      final bool ok = await EscPosPrinterService.printAutreFraisReceipt(
        printerName: printerName,
        schoolName: config.schoolName,
        titreFrais: data['titreFrais'] as String,
        studentName: data['studentName'] as String,
        classe: data['classe'] as String,
        section: data['section'] as String,
        montant: data['montant'] as double,
      );
      if (ok) {
        await _markReceiptPrinted(key);
        return true;
      }
    }

    await _enqueueReceipt(
      key: key,
      type: 'autre_frais',
      eleveId: eleve.id,
      data: data,
    );
    return false;
  }

  Future<int> flushReceiptQueue() async {
    if (_isFlushingReceiptQueue) return 0;
    if (receiptQueue.isEmpty) return 0;
    final printerName = await _currentPrinterName();
    if (printerName.isEmpty) return 0;

    _isFlushingReceiptQueue = true;
    try {
      final logoBytes = await _loadLogoBytesForPrinting();
      int printedCount = 0;
      final items = List<Map<String, dynamic>>.from(receiptQueue);

      for (final item in items) {
        final key = item['key']?.toString() ?? '';
        if (key.isEmpty) continue;
        if (isReceiptPrinted(key)) {
          receiptQueue.removeWhere((r) => r['key'] == key);
          continue;
        }
        final type = item['type']?.toString() ?? '';
        final data = Map<String, dynamic>.from(item['data'] as Map? ?? {});
        bool ok = false;

        if (type == 'principal') {
          ok = await EscPosPrinterService.printReceipt(
            printerName: printerName,
            schoolName: config.schoolName,
            currentYear: currentYear,
            studentName: data['studentName'] as String? ?? '',
            studentId: data['studentId'] as String? ?? '',
            classe: data['classe'] as String? ?? '',
            section: data['section'] as String? ?? '',
            moisPaye: data['moisPaye'] as String? ?? '',
            montantPaye: (data['montantPaye'] as num?)?.toDouble() ?? 0.0,
            montantRequis: (data['montantRequis'] as num?)?.toDouble() ?? 0.0,
            resteAPayerMois:
            (data['resteAPayerMois'] as num?)?.toDouble() ?? 0.0,
            totalDejaPayeAnnee:
            (data['totalDejaPayeAnnee'] as num?)?.toDouble() ?? 0.0,
            totalRequis: (data['totalRequis'] as num?)?.toDouble() ?? 0.0,
            historiqueTransactions:
            ((data['historiqueTransactions'] as List?) ?? [])
                .map((t) => Map<String, dynamic>.from(t as Map))
                .toList(),
            logoBytes: logoBytes,
          );
        } else if (type == 'autre_frais') {
          ok = await EscPosPrinterService.printAutreFraisReceipt(
            printerName: printerName,
            schoolName: config.schoolName,
            titreFrais: data['titreFrais'] as String? ?? '',
            studentName: data['studentName'] as String? ?? '',
            classe: data['classe'] as String? ?? '',
            section: data['section'] as String? ?? '',
            montant: (data['montant'] as num?)?.toDouble() ?? 0.0,
          );
        }

        if (ok) {
          await _markReceiptPrinted(key);
          printedCount++;
        }
      }

      return printedCount;
    } finally {
      _isFlushingReceiptQueue = false;
    }
  }

  String generateLocalStudentId(String nom) {
    final yearShort = currentYear.length >= 2
        ? currentYear.substring(currentYear.length - 2)
        : '26';
    final schoolLetter = config.schoolName.isNotEmpty
        ? config.schoolName[0].toUpperCase()
        : 'B';
    final nameRaw    = nom.trim().toUpperCase();
    final namePrefix = nameRaw.length >= 2
        ? nameRaw.substring(0, 2)
        : nameRaw.padRight(2, 'X');

    final allIds = history.values
        .expand((yd) => yd.eleves)
        .map((e) => e.id)
        .where((id) => id.isNotEmpty)
        .toSet();

    _localIdCounter++;
    String candidate = '$namePrefix$yearShort$schoolLetter$_localIdCounter';

    while (allIds.contains(candidate)) {
      _localIdCounter++;
      candidate = '$namePrefix$yearShort$schoolLetter$_localIdCounter';
    }
    return candidate;
  }

  Future<String> generateUniqueStudentId(
      String nom, String schoolCodeForServer) async {
    if (nom.trim().isEmpty) {
      throw Exception("Le nom est requis pour générer un identifiant.");
    }
    return generateLocalStudentId(nom);
  }

  void _applyIdCorrections(Map<String, dynamic> corrections) {
    if (corrections.isEmpty) return;
    for (var yearData in history.values) {
      for (var eleve in yearData.eleves) {
        if (corrections.containsKey(eleve.id)) {
          eleve.id = corrections[eleve.id] as String;
        }
      }
    }
  }

  Eleve? findStudentByFullName(
      String nom, String postNom, String prenom, [String? year]) {
    final targetKey =
        '${nom.trim().toLowerCase()}_${postNom.trim().toLowerCase()}_${prenom.trim().toLowerCase()}';
    final list = year != null
        ? (history[year]?.eleves ?? currentData.eleves)
        : currentData.eleves;
    for (final e in list) {
      final key =
          '${e.nom.trim().toLowerCase()}_${e.postNom.trim().toLowerCase()}_${e.prenom.trim().toLowerCase()}';
      if (key == targetKey) return e;
    }
    return null;
  }

  Eleve? findDuplicateFullName({
    required String nom,
    required String postNom,
    required String prenom,
    String? excludeId,
  }) {
    final nomN = nom.trim().toLowerCase();
    final postNomN = postNom.trim().toLowerCase();
    final prenomN = prenom.trim().toLowerCase();
    for (final e in currentData.eleves) {
      if (excludeId != null && e.id == excludeId) continue;
      if (e.nom.trim().toLowerCase() == nomN &&
          e.postNom.trim().toLowerCase() == postNomN &&
          e.prenom.trim().toLowerCase() == prenomN) {
        return e;
      }
    }
    return null;
  }

  Map<String, dynamic> exportSnapshotForClients() {
    return {
      'config': config.toJson(),
      'currentYear': currentYear,
      'localIdCounter': _localIdCounter,
      'lastSelectedClassFilter': lastSelectedClassFilter,
      'lastSelectedSectionFilter': lastSelectedSectionFilter,
      'history': history.map((key, value) => MapEntry(key, value.toJson())),
      'depensesByYear': depensesByYear.map(
            (key, value) =>
            MapEntry(key, value.map((d) => d.toJson()).toList()),
      ),
      'autresFrais': autresFrais.map((f) => f.toJson()).toList(),
      'autresFraisPaiementsByYear': autresFraisPaiementsByYear.map(
            (key, value) =>
            MapEntry(key, value.map((p) => p.toJson()).toList()),
      ),
      'autresFraisAdministrations':
      autresFraisAdministrations.map((a) => a.toJson()).toList(),
      'adminAuditLog': adminAuditLog.map((a) => a.toJson()).toList(),
      'signataires': signataires.map((s) => s.toJson()).toList(),
      'optionsSections': optionsSections,
      'printedReceiptKeys': printedReceiptKeys,
      'receiptQueue': receiptQueue,
      'elevesSupprimesData': elevesSupprimesData.toJson(),
      'dateSuppressionEleves': dateSuppressionEleves,
      'motifSuppressionEleves': motifSuppressionEleves,
      'backup_password': null,
    };
  }

  Future<Map<String, dynamic>> generateLocalKey({
    required List<String> sections,
    required String type,
    String? classe,
    int durationValue = 30,
    String durationUnit = 'days',
  }) async {
    final rand = Random.secure();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final suffix =
    List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
    final prefix =
    (schoolCode != null && schoolCode!.isNotEmpty) ? schoolCode! : 'ECOLE';
    final key = 'LOC-$prefix-$type-$suffix';
    final int safeDurationValue = durationValue < 1 ? 1 : durationValue;
    final String safeDurationUnit =
    durationUnit == 'minutes' ? 'minutes' : 'days';

    final entry = <String, dynamic>{
      'key': key,
      'type': type,
      'sections': sections,
      'classe': classe,
      'createdAt': DateTime.now().toIso8601String(),
      'durationValue': safeDurationValue,
      'durationUnit': safeDurationUnit,
    };
    localAccessKeys.add(entry);
    await saveData();
    return entry;
  }

  Future<Map<String, dynamic>?> verifyLocalKey(String key) async {
    for (final entry in localAccessKeys) {
      if (entry['key'] == key) {
        return entry;
      }
    }
    return null;
  }

  Future<void> revokeLocalKey(String key) async {
    localAccessKeys.removeWhere((e) => e['key'] == key);
    await saveData();
  }

  Future<Map<String, dynamic>> addLocalPendingPayment({
    required String eleveId,
    required String mois,
    required double amount,
  }) async {
    Eleve? eleve;
    for (final e in currentData.eleves) {
      if (e.id == eleveId) {
        eleve = e;
        break;
      }
    }
    final entry = <String, dynamic>{
      'id': 'LPP${DateTime.now().millisecondsSinceEpoch}',
      'eleve_id': eleveId,
      'nom': eleve?.nom ?? '',
      'postNom': eleve?.postNom ?? '',
      'prenom': eleve?.prenom ?? '',
      'section': eleve?.section ?? '',
      'classe': eleve?.classe ?? '',
      'mois': mois,
      'amount': amount,
      'date': DateTime.now().toString().split(' ')[0],
    };
    localPendingPayments.add(entry);
    await saveData();
    return entry;
  }

  Future<int> validateLocalPendingPayments(List<String> ids) async {
    int count = 0;
    final toValidate =
    localPendingPayments.where((p) => ids.contains(p['id'])).toList();
    for (final p in toValidate) {
      Eleve? eleve;
      for (final e in currentData.eleves) {
        if (e.id == p['eleve_id']) {
          eleve = e;
          break;
        }
      }
      eleve ??= findStudentByFullName(
        (p['nom'] ?? '').toString(),
        (p['postNom'] ?? '').toString(),
        (p['prenom'] ?? '').toString(),
      );
      if (eleve != null) {
        handlePayment(
            eleve, p['mois'].toString(), (p['amount'] as num).toDouble());
        count++;
      }
    }
    localPendingPayments.removeWhere((p) => ids.contains(p['id']));
    await saveData();
    return count;
  }

  Future<Map<String, dynamic>> addLocalPendingRegistration(
      Map<String, dynamic> data) async {
    final entry = <String, dynamic>{
      'id': 'LPR${DateTime.now().millisecondsSinceEpoch}',
      ...data,
    };
    localPendingRegistrations.add(entry);
    await saveData();
    return entry;
  }

  Future<int> validateLocalPendingRegistrations(List<String> ids) async {
    int count = 0;
    final toValidate = localPendingRegistrations
        .where((r) => ids.contains(r['id']))
        .toList();
    final processedIds = <String>[];
    for (final r in toValidate) {
      final nom = (r['nom'] ?? '').toString().trim();
      final section = (r['section'] ?? '').toString().trim();
      final classe = (r['classe'] ?? '').toString().trim();
      final postNom = (r['postNom'] ?? '').toString().trim();
      final prenom = (r['prenom'] ?? '').toString().trim();
      if (nom.isEmpty || section.isEmpty || classe.isEmpty) {
        processedIds.add(r['id'] as String);
        continue;
      }
      if (findDuplicateFullName(nom: nom, postNom: postNom, prenom: prenom) !=
          null) {
        continue;
      }

      final id = generateLocalStudentId(nom);
      currentData.eleves.add(Eleve(
        id: id,
        nom: nom,
        postNom: postNom,
        prenom: prenom,
        classe: classe,
        section: section,
      ));
      count++;
      processedIds.add(r['id'] as String);
    }
    localPendingRegistrations
        .removeWhere((r) => processedIds.contains(r['id']));
    await saveData();
    return count;
  }

  Future<Map<String, dynamic>> addLocalPendingAutreFraisPayment({
    required String eleveId,
    required String autreFraisId,
    required double montant,
    String enregistrePar = 'Agent',
  }) async {
    Eleve? eleve;
    for (final e in currentData.eleves) {
      if (e.id == eleveId) {
        eleve = e;
        break;
      }
    }
    AutreFrais? frais;
    for (final f in autresFrais) {
      if (f.id == autreFraisId) {
        frais = f;
        break;
      }
    }
    final entry = <String, dynamic>{
      'id': 'LPAF${DateTime.now().millisecondsSinceEpoch}',
      'eleveId': eleveId,
      'nom': eleve?.nom ?? '',
      'postNom': eleve?.postNom ?? '',
      'prenom': eleve?.prenom ?? '',
      'autreFraisId': autreFraisId,
      'autreFraisNom': frais?.nom ?? '',
      'montant': montant,
      'enregistrePar': enregistrePar,
    };
    localPendingAutresFraisPayments.add(entry);
    await saveData();
    return entry;
  }

  Future<int> validateLocalPendingAutresFraisPayments(
      List<String> ids) async {
    int count = 0;
    final toValidate = localPendingAutresFraisPayments
        .where((p) => ids.contains(p['id']))
        .toList();
    for (final p in toValidate) {
      Eleve? eleve;
      for (final e in currentData.eleves) {
        if (e.id == p['eleveId']) {
          eleve = e;
          break;
        }
      }
      eleve ??= findStudentByFullName(
        (p['nom'] ?? '').toString(),
        (p['postNom'] ?? '').toString(),
        (p['prenom'] ?? '').toString(),
      );
      AutreFrais? frais;
      for (final f in autresFrais) {
        if (f.id == p['autreFraisId']) {
          frais = f;
          break;
        }
      }
      if (eleve != null && frais != null) {
        // ⚡ NOUVEAU — si le frais fonctionne par tranches, le paiement en
        // attente règle la prochaine tranche non payée ; si toutes les
        // tranches sont déjà payées, ce paiement en attente est ignoré
        // (aucune erreur, aucun doublon).
        try {
          await payAutreFrais(
            frais: frais,
            eleve: eleve,
            enregistrePar: (p['enregistrePar'] ?? 'Agent').toString(),
          );
          count++;
        } catch (_) {}
      }
    }
    localPendingAutresFraisPayments.removeWhere((p) => ids.contains(p['id']));
    await saveData();
    return count;
  }

  Future<void> recordLocalAbsences({
    required String classe,
    required String section,
    required String date,
    required List<String> absentIds,
    String recordedBy = 'Direction',
  }) async {
    localAttendance['$classe|$date'] = absentIds;
    localCommunicationsLog.add({
      'type': 'absences',
      'classe': classe,
      'section': section,
      'date': date,
      'absent_ids': absentIds,
      'recordedBy': recordedBy,
      'loggedAt': DateTime.now().toIso8601String(),
      'delivered': false,
    });
    await saveData();
  }

  List<String> getLocalAttendance(String classe, String date) {
    return localAttendance['$classe|$date'] ?? [];
  }

  Future<void> logLocalCommunication(Map<String, dynamic> entry) async {
    localCommunicationsLog.add({
      ...entry,
      'loggedAt': DateTime.now().toIso8601String(),
      'delivered': false,
    });
    await saveData();
  }

  String _classeKey(String section, String classeNumero) =>
      "$section|$classeNumero";

  List<String> getClassesForSection(String section) {
    if (config.classesBySection.containsKey(section) &&
        config.classesBySection[section]!.isNotEmpty) {
      return config.classesBySection[section]!;
    }
    final autoClasses = SchoolConfig.defaultClassesForSectionName(section);
    if (autoClasses.isNotEmpty) {
      config.classesBySection[section] = List<String>.from(autoClasses);
    }
    return config.classesBySection[section] ?? [];
  }

  Future<void> addClasseNumero(String section, String classeNumero) async {
    final trimmed = classeNumero.trim();
    if (trimmed.isEmpty) return;
    final list = config.classesBySection.putIfAbsent(section, () => []);
    if (!list.contains(trimmed)) {
      list.add(trimmed);
      await saveData();
    }
  }

  Future<void> renameClasseNumero(
      String section, String oldNumero, String newNumero) async {
    final trimmedNew = newNumero.trim();
    if (trimmedNew.isEmpty || trimmedNew == oldNumero) return;

    final list = config.classesBySection[section];
    if (list != null) {
      final idx = list.indexOf(oldNumero);
      if (idx != -1) {
        if (list.contains(trimmedNew)) {
          list.removeAt(idx);
        } else {
          list[idx] = trimmedNew;
        }
      }
    }

    final oldKey = _classeKey(section, oldNumero);
    final newKey = _classeKey(section, trimmedNew);
    if (config.subClassesByClasse.containsKey(oldKey)) {
      final subs = config.subClassesByClasse.remove(oldKey)!;
      if (config.subClassesByClasse.containsKey(newKey)) {
        for (var s in subs) {
          if (!config.subClassesByClasse[newKey]!.contains(s)) {
            config.subClassesByClasse[newKey]!.add(s);
          }
        }
      } else {
        config.subClassesByClasse[newKey] = subs;
      }
    }
    if (config.feesByClasse.containsKey(oldKey)) {
      final fee = config.feesByClasse.remove(oldKey)!;
      config.feesByClasse[newKey] = fee;
    }
    if (config.monthlyExceptionsByClasse.containsKey(oldKey)) {
      final exc = config.monthlyExceptionsByClasse.remove(oldKey)!;
      config.monthlyExceptionsByClasse[newKey] = exc;
    }
    for (var yearData in history.values) {
      for (var eleve in yearData.eleves) {
        if (eleve.section != section) continue;
        final numero = classeNumeroFromFullClasse(eleve.classe);
        if (numero == oldNumero) {
          final sub = subClasseFromFullClasse(eleve.classe);
          eleve.classe = buildFullClasseName(trimmedNew, sub);
        }
      }
    }

    for (var frais in autresFrais) {
      if (frais.scope == 'classe' &&
          frais.section == section &&
          frais.classe == oldNumero) {
        frais.classe = trimmedNew;
      }
      if (frais.montantsParClasse.containsKey(oldKey)) {
        final montant = frais.montantsParClasse.remove(oldKey)!;
        frais.montantsParClasse[newKey] = montant;
      }
      // ⚡ NOUVEAU — les tranches définies pour cette classe suivent la
      // classe quand elle est renommée.
      final String oldTrancheKey = 'C:$oldKey';
      final String newTrancheKey = 'C:$newKey';
      if (frais.tranchesParCle.containsKey(oldTrancheKey)) {
        final tranches = frais.tranchesParCle.remove(oldTrancheKey)!;
        if (!frais.tranchesParCle.containsKey(newTrancheKey)) {
          frais.tranchesParCle[newTrancheKey] = tranches;
        }
      }
    }

    if (lastSelectedClassFilter == oldNumero) {
      lastSelectedClassFilter = trimmedNew;
    }

    await saveData();
  }

  Future<Map<String, dynamic>> deleteClasseNumero(
      String section,
      String numero, {
        bool force = false,
      }) async {
    int studentCount = 0;
    for (var yearData in history.values) {
      for (var eleve in yearData.eleves) {
        if (eleve.section == section &&
            classeNumeroFromFullClasse(eleve.classe) == numero) {
          studentCount++;
        }
      }
    }

    final key = _classeKey(section, numero);

    int autresFraisCount = 0;
    for (var frais in autresFrais) {
      if (frais.scope == 'classe' &&
          frais.section == section &&
          frais.classe == numero) {
        autresFraisCount++;
      } else if (frais.montantsParClasse.containsKey(key)) {
        autresFraisCount++;
      }
    }

    if ((studentCount > 0 || autresFraisCount > 0) && !force) {
      return {
        'success': false,
        'studentCount': studentCount,
        'autresFraisCount': autresFraisCount,
      };
    }

    config.classesBySection[section]?.remove(numero);
    config.subClassesByClasse.remove(key);
    config.feesByClasse.remove(key);
    config.monthlyExceptionsByClasse.remove(key);

    for (var frais in autresFrais) {
      if (frais.scope == 'classe' &&
          frais.section == section &&
          frais.classe == numero) {
        frais.scope = 'section';
        frais.classe = null;
      }
      frais.montantsParClasse.remove(key);
      // ⚡ NOUVEAU — les tranches propres à cette classe disparaissent avec
      // elle (les paiements déjà enregistrés restent intacts).
      frais.tranchesParCle.remove('C:$key');
    }

    if (lastSelectedClassFilter == numero) {
      lastSelectedClassFilter = null;
    }
    await saveData();
    return {
      'success': true,
      'studentCount': studentCount,
      'autresFraisCount': autresFraisCount,
    };
  }

  List<String> getSubClassesFor(String section, String classeNumero) {
    return config.subClassesByClasse[_classeKey(section, classeNumero)] ?? [];
  }

  Future<void> addSubClasse(
      String section, String classeNumero, String subClasse) async {
    final trimmed = subClasse.trim();
    if (trimmed.isEmpty) return;
    final key  = _classeKey(section, classeNumero);
    final list = config.subClassesByClasse.putIfAbsent(key, () => []);
    if (!list.contains(trimmed)) {
      list.add(trimmed);
      await saveData();
    }
  }

  Future<Map<String, dynamic>> removeSubClasse(
      String section,
      String classeNumero,
      String subClasse, {
        bool force = false,
      }) async {
    int studentCount = 0;
    for (var yearData in history.values) {
      for (var eleve in yearData.eleves) {
        if (eleve.section == section &&
            classeNumeroFromFullClasse(eleve.classe) == classeNumero &&
            subClasseFromFullClasse(eleve.classe) == subClasse) {
          studentCount++;
        }
      }
    }

    if (studentCount > 0 && !force) {
      return {
        'success': false,
        'studentCount': studentCount,
      };
    }

    final key = _classeKey(section, classeNumero);
    config.subClassesByClasse[key]?.remove(subClasse);
    await saveData();
    return {
      'success': true,
      'studentCount': studentCount,
    };
  }

  String buildFullClasseName(String classeNumero, String? subClasse) {
    if (subClasse == null || subClasse.trim().isEmpty) return classeNumero;
    return "$classeNumero ${subClasse.trim()}";
  }

  String classeNumeroFromFullClasse(String classeComplete) {
    final trimmed = classeComplete.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed.split(' ').first;
  }

  String? subClasseFromFullClasse(String classeComplete) {
    final parts = classeComplete.trim().split(' ');
    if (parts.length > 1) {
      final rest = parts.sublist(1).join(' ').trim();
      return rest.isEmpty ? null : rest;
    }
    return null;
  }

  List<String> getAllDisplayClassesForSection(String section) {
    final result = <String>[];
    for (var numero in getClassesForSection(section)) {
      final subs = getSubClassesFor(section, numero);
      if (subs.isEmpty) {
        result.add(numero);
      } else {
        for (var sub in subs) {
          result.add(buildFullClasseName(numero, sub));
        }
      }
    }
    return result;
  }

  List<String> getAllDisplayClasses() {
    final result = <String>{};
    for (var section in config.sections) {
      result.addAll(getAllDisplayClassesForSection(section));
    }
    return result.toList();
  }

  List<Map<String, String>> getAllDisplayClassesWithSection() {
    final List<MapEntry<String, String>> paires = [];
    for (var section in config.sections) {
      for (var classe in getAllDisplayClassesForSection(section)) {
        paires.add(MapEntry(classe, section));
      }
    }

    final Map<String, int> occurrences = {};
    for (var p in paires) {
      occurrences[p.key] = (occurrences[p.key] ?? 0) + 1;
    }

    final Set<String> dejaVus = {};
    final result = <Map<String, String>>[];
    for (var p in paires) {
      final cleUnique = '${p.value}|${p.key}';
      if (dejaVus.contains(cleUnique)) continue;
      dejaVus.add(cleUnique);
      final bool ambigu = (occurrences[p.key] ?? 0) > 1;
      result.add({
        'classe': p.key,
        'section': p.value,
        'label': ambigu ? '${p.key} (${p.value})' : p.key,
      });
    }
    return result;
  }

  String? getNextClasseNumero(String section, String classeNumero) {
    final list = getClassesForSection(section);
    final idx  = list.indexOf(classeNumero);
    if (idx == -1 || idx == list.length - 1) return null;
    return list[idx + 1];
  }

  String computePromotedClasse(Eleve eleve) {
    final numero     = classeNumeroFromFullClasse(eleve.classe);
    final subClasse  = subClasseFromFullClasse(eleve.classe);
    final nextNumero = getNextClasseNumero(eleve.section, numero);
    if (nextNumero == null) return eleve.classe;
    return buildFullClasseName(nextNumero, subClasse);
  }

  Future<Map<String, int>> promoteStudents({
    required List<Eleve> studentsToProcess,
    required Map<String, bool> passToNextYear,
    required Map<String, bool> monterClasse,
    required String targetYear,
  }) async {
    int promoted    = 0;
    int abandoned   = 0;
    int redoublants = 0;

    if (!history.containsKey(targetYear)) {
      history[targetYear] = SchoolYearData(eleves: []);
    }
    final targetData  = history[targetYear]!;
    final existingIds = targetData.eleves.map((e) => e.id).toSet();

    for (var eleve in studentsToProcess) {
      final shouldPass = passToNextYear[eleve.id] ?? true;
      if (!shouldPass) {
        abandoned++;
        continue;
      }
      final shouldMonter = monterClasse[eleve.id] ?? true;
      String newClasse;
      if (shouldMonter) {
        final promotedClasse = computePromotedClasse(eleve);
        if (promotedClasse == eleve.classe) redoublants++;
        newClasse = promotedClasse;
      } else {
        newClasse = eleve.classe;
        redoublants++;
      }

      if (existingIds.contains(eleve.id)) {
        final existing =
        targetData.eleves.firstWhere((e) => e.id == eleve.id);
        existing.classe  = newClasse;
        existing.section = eleve.section;
        existing.montantMensuelPersonnalise = eleve.montantMensuelPersonnalise;
      } else {
        targetData.eleves.add(Eleve(
          id:      eleve.id,
          nom:     eleve.nom,
          postNom: eleve.postNom,
          prenom:  eleve.prenom,
          classe:  newClasse,
          section: eleve.section,
          montantMensuelPersonnalise: eleve.montantMensuelPersonnalise,
        ));
        existingIds.add(eleve.id);
      }
      promoted++;
    }

    await saveData();
    return {
      'promoted':    promoted,
      'abandoned':   abandoned,
      'redoublants': redoublants,
    };
  }

  List<Eleve> getStudentsBySection(String section) =>
      currentData.eleves.where((e) => e.section == section).toList();

  List<Eleve> getStudentsByClass(String classe) =>
      currentData.eleves.where((e) => e.classe == classe).toList();

  List<Eleve> getStudentsBySectionAndClass(
      String? section, String? classe) {
    return currentData.eleves.where((e) {
      final matchSection = section == null || e.section == section;
      final matchClass   = classe  == null || e.classe  == classe;
      return matchSection && matchClass;
    }).toList();
  }

  static const double _montantSecoursSiNonConfigure = 35000;

  bool sectionAFraisConfigure(String section) =>
      config.feesBySection.containsKey(section);

  List<String> getSectionsSansFraisConfigure() {
    return config.sections
        .where((s) => !sectionAFraisConfigure(s))
        .toList();
  }

  double getRequiredForMonth(String mois, String section,
      [String? classe]) {
    if (classe != null && classe.trim().isNotEmpty) {
      final classeNumero = classeNumeroFromFullClasse(classe);
      final key          = _classeKey(section, classeNumero);
      final classExc     = config.monthlyExceptionsByClasse[key];
      if (classExc != null && classExc.containsKey(mois)) {
        return classExc[mois]!;
      }
      if (config.feesByClasse.containsKey(key)) {
        return config.feesByClasse[key]!;
      }
    }
    final exc = config.monthlyExceptionsBySection[section];
    if (exc != null && exc.containsKey(mois)) return exc[mois]!;
    return config.feesBySection[section] ?? _montantSecoursSiNonConfigure;
  }

  double getRequiredForMonthForEleve(Eleve eleve, String mois) {
    if (eleve.exceptionsMoisPersonnalisees.containsKey(mois)) {
      final v = eleve.exceptionsMoisPersonnalisees[mois]!;
      return v < 0 ? 0 : v;
    }
    if (eleve.montantMensuelPersonnalise != null) {
      return eleve.montantMensuelPersonnalise!;
    }
    return getRequiredForMonth(mois, eleve.section, eleve.classe);
  }

  Future<void> setMontantMensuelPersonnalise(
      Eleve eleve, double? montant) async {
    eleve.montantMensuelPersonnalise =
    (montant != null && montant > 0) ? montant : null;
    recalculerRepartitionMoisPourEleve(eleve);
    await saveData();
  }

  Future<void> setExceptionsMoisPourEleve(
      Eleve eleve, Map<String, double> exceptionsParMois) async {
    exceptionsParMois.forEach((mois, montant) {
      eleve.exceptionsMoisPersonnalisees[mois] = montant < 0 ? 0 : montant;
    });
    recalculerRepartitionMoisPourEleve(eleve);
    await saveData();
  }

  Future<int> setExceptionsMoisPourPlusieursEleves(
      List<Map<String, dynamic>> lot) async {
    int count = 0;
    for (final entry in lot) {
      final Eleve eleve = entry['eleve'] as Eleve;
      final Map<String, double> exceptions =
      Map<String, double>.from(entry['exceptions'] as Map);
      exceptions.forEach((mois, montant) {
        eleve.exceptionsMoisPersonnalisees[mois] = montant < 0 ? 0 : montant;
      });
      recalculerRepartitionMoisPourEleve(eleve);
      count++;
    }
    await saveData();
    return count;
  }

  Future<void> removeExceptionMoisPourEleve(Eleve eleve, String mois) async {
    eleve.exceptionsMoisPersonnalisees.remove(mois);
    recalculerRepartitionMoisPourEleve(eleve);
    await saveData();
  }

  Future<void> removeToutesExceptionsMoisPourEleve(Eleve eleve) async {
    eleve.exceptionsMoisPersonnalisees.clear();
    recalculerRepartitionMoisPourEleve(eleve);
    await saveData();
  }

  List<Eleve> getElevesAvecExceptionPersonnalisee() {
    final list = currentData.eleves
        .where((e) =>
    e.montantMensuelPersonnalise != null ||
        e.exceptionsMoisPersonnalisees.isNotEmpty)
        .toList();
    list.sort((a, b) => a.nom.toLowerCase().compareTo(b.nom.toLowerCase()));
    return list;
  }

  bool moisEstDebloquePourEleve(Eleve eleve, String mois) =>
      eleve.moisDebloque == mois;

  Future<void> setMoisDebloquePourEleve(Eleve eleve, String? mois) async {
    eleve.moisDebloque = mois;
    await saveData();
  }

  Map<String, double> getTotalBySection() {
    final totals = <String, double>{};
    for (var e in currentData.eleves) {
      totals[e.section] = (totals[e.section] ?? 0) + getStudentTotalPaid(e);
    }
    // ⚡ NOUVEAU — l'argent déjà payé par les élèves supprimés/exclus reste
    // comptabilisé dans les totaux par section (il reste dans la caisse de
    // l'école même si l'élève n'apparaît plus dans le registre actif).
    for (var e in elevesSupprimesData.eleves) {
      totals[e.section] = (totals[e.section] ?? 0) + getStudentTotalPaid(e);
    }
    return totals;
  }

  Map<String, double> getTotalByClass() {
    final totals = <String, double>{};
    for (var e in currentData.eleves) {
      final key = "${e.section} - ${e.classe}";
      totals[key] = (totals[key] ?? 0) + getStudentTotalPaid(e);
    }
    // ⚡ NOUVEAU — idem pour le total par classe : l'argent des élèves
    // supprimés/exclus reste compté dans le total de leur ancienne classe.
    for (var e in elevesSupprimesData.eleves) {
      final key = "${e.section} - ${e.classe}";
      totals[key] = (totals[key] ?? 0) + getStudentTotalPaid(e);
    }
    return totals;
  }

  double getYearTotalCollected() =>
      months.fold(
          0.0,
              (sum, m) =>
          sum +
              currentData.eleves.fold(
                  0.0, (s, e) => s + (e.paid[m] ?? 0)) +
              // ⚡ NOUVEAU — l'argent déjà payé par les élèves
              // supprimés/exclus reste comptabilisé dans le total annuel.
              elevesSupprimesData.eleves.fold(
                  0.0, (s, e) => s + (e.paid[m] ?? 0)));

  double getCurrentMonthTotalCollected() {
    final idx = _schoolMonthIndexForToday();
    if (idx < 0 || idx >= months.length) return 0.0;
    final moisCourant = months[idx];
    return currentData.eleves
        .fold(0.0, (sum, e) => sum + (e.paid[moisCourant] ?? 0)) +
        // ⚡ NOUVEAU — idem pour le total du mois en cours.
        elevesSupprimesData.eleves
            .fold(0.0, (sum, e) => sum + (e.paid[moisCourant] ?? 0));
  }

  Map<String, double> getMoneyCollectedTodayBySection() {
    final today = DateTime.now().toString().split(' ')[0];
    final Map<String, double> result = {};
    // ⚡ NOUVEAU — on inclut aussi les élèves supprimés/exclus : si un
    // paiement a eu lieu aujourd'hui avant la suppression de l'élève,
    // ce montant reste compté dans la caisse du jour.
    for (final e in [...currentData.eleves, ...elevesSupprimesData.eleves]) {
      double sumToday = 0;
      for (final t in e.transactions) {
        if (t['date'] == today) {
          sumToday += (t['amount'] as num?)?.toDouble() ?? 0.0;
        }
      }
      if (sumToday != 0) {
        result[e.section] = (result[e.section] ?? 0) + sumToday;
      }
    }
    return result;
  }

  Map<String, double> getMoneyCollectedThisMonthBySection() {
    final idx = _schoolMonthIndexForToday();
    if (idx < 0 || idx >= months.length) return {};
    final moisCourant = months[idx];
    final Map<String, double> result = {};
    // ⚡ NOUVEAU — idem pour le mois en cours : l'argent déjà payé par les
    // élèves supprimés/exclus reste comptabilisé dans la caisse du mois.
    for (final e in [...currentData.eleves, ...elevesSupprimesData.eleves]) {
      final montant = e.paid[moisCourant] ?? 0;
      if (montant != 0) {
        result[e.section] = (result[e.section] ?? 0) + montant;
      }
    }
    return result;
  }

  double getMoneyCollectedForPeriod(String period) {
    switch (period) {
      case 'today':
        return getMoneyCollectedTodayBySection()
            .values
            .fold(0.0, (a, b) => a + b);
      case 'month':
        return getCurrentMonthTotalCollected();
      case 'year':
      default:
        return getYearTotalCollected();
    }
  }

  List<Eleve> getPaidStudentsToday() {
    final today = DateTime.now().toString().split(' ')[0];
    return currentData.eleves
        .where((e) => e.transactions.any((t) => t['date'] == today))
        .toList();
  }

  List<Eleve> getPaidStudentsThisMonth() {
    final idx = _schoolMonthIndexForToday();
    if (idx < 0 || idx >= months.length) return [];
    final moisCourant = months[idx];
    return currentData.eleves
        .where((e) =>
    e.paid.containsKey(moisCourant) &&
        e.paid[moisCourant]! > 0)
        .toList();
  }

  List<Map<String, dynamic>> getPaiementsPourDate({
    required String date,
    String? mois,
    String? sectionFilter,
    String? classFilter,
  }) {
    final List<Map<String, dynamic>> result = [];
    for (final e in currentData.eleves) {
      if (sectionFilter != null && e.section != sectionFilter) continue;
      if (classFilter != null && e.classe != classFilter) continue;
      for (final t in e.transactions) {
        if (t['date']?.toString() != date) continue;
        final String moisTransaction = t['mois']?.toString() ?? '';
        if (mois != null && moisTransaction != mois) continue;
        result.add({
          'eleve': e,
          'transaction': t,
        });
      }
    }
    result.sort((a, b) {
      final Eleve ea = a['eleve'] as Eleve;
      final Eleve eb = b['eleve'] as Eleve;
      final c = ea.nom.toLowerCase().compareTo(eb.nom.toLowerCase());
      if (c != 0) return c;
      return ea.prenom.toLowerCase().compareTo(eb.prenom.toLowerCase());
    });
    return result;
  }

  double getTotalPaiementsPourDate({
    required String date,
    String? mois,
    String? sectionFilter,
    String? classFilter,
  }) {
    return getPaiementsPourDate(
      date: date,
      mois: mois,
      sectionFilter: sectionFilter,
      classFilter: classFilter,
    ).fold(0.0, (sum, item) {
      final t = item['transaction'] as Map<String, dynamic>;
      return sum + ((t['amount'] as num?)?.toDouble() ?? 0.0);
    });
  }

  Map<String, double> calculateAdminDistribution(double totalAmount) {
    final distribution = <String, double>{};
    for (var admin in config.administrations) {
      distribution[admin.nom] = totalAmount * (admin.pourcentage / 100);
    }
    return distribution;
  }

  double getTotalPourcentageAdministrations() =>
      config.administrations.fold(0.0, (sum, a) => sum + a.pourcentage);

  bool get aDesOptionsActives =>
      optionsSections.values.any((liste) => liste.isNotEmpty);

  List<String> getOptionsNoms() => List<String>.from(optionsSections.keys);

  List<String> getOptionsUtilisables() => optionsSections.entries
      .where((e) => e.value.isNotEmpty)
      .map((e) => e.key)
      .toList();

  List<String> getSectionsPourOption(String option) =>
      List<String>.from(optionsSections[option] ?? const <String>[]);

  String? getOptionDeSection(String section) {
    for (final e in optionsSections.entries) {
      if (e.value.contains(section)) return e.key;
    }
    return null;
  }

  bool _nomDejaPrisParSectionOuOption(String nom, {String? sauf}) {
    final bas = nom.trim().toLowerCase();
    for (final k in optionsSections.keys) {
      if (sauf != null && k == sauf) continue;
      if (k.trim().toLowerCase() == bas) return true;
    }
    for (final s in config.sections) {
      if (s.trim().toLowerCase() == bas) return true;
    }
    return false;
  }

  Future<String?> addOption(String nom) async {
    final n = nom.trim();
    if (n.isEmpty) return "Le nom de l'option ne peut pas être vide";
    if (_nomDejaPrisParSectionOuOption(n)) {
      return "Ce nom est déjà utilisé par une option ou une section";
    }
    optionsSections[n] = <String>[];
    await saveData();
    return null;
  }

  Future<String?> renameOption(String ancien, String nouveau) async {
    final n = nouveau.trim();
    if (n.isEmpty) return "Le nom de l'option ne peut pas être vide";
    if (!optionsSections.containsKey(ancien)) return "Option introuvable";
    if (n == ancien) return null;
    if (_nomDejaPrisParSectionOuOption(n, sauf: ancien)) {
      return "Ce nom est déjà utilisé par une option ou une section";
    }
    final reconstruit = <String, List<String>>{};
    optionsSections.forEach((k, v) {
      reconstruit[k == ancien ? n : k] = v;
    });
    optionsSections = reconstruit;
    await saveData();
    return null;
  }

  Future<void> deleteOption(String option) async {
    if (optionsSections.remove(option) != null) {
      await saveData();
    }
  }

  Future<void> setSectionsPourOption(
      String option, List<String> sections) async {
    if (!optionsSections.containsKey(option)) return;
    final valides = <String>[];
    for (final s in sections) {
      if (config.sections.contains(s) && !valides.contains(s)) {
        valides.add(s);
      }
    }
    valides.sort((a, b) =>
        config.sections.indexOf(a).compareTo(config.sections.indexOf(b)));

    for (final e in optionsSections.entries) {
      if (e.key == option) continue;
      e.value.removeWhere((s) => valides.contains(s));
    }
    optionsSections[option] = valides;
    await saveData();
  }

  void retirerSectionDesOptions(String section) {
    for (final liste in optionsSections.values) {
      liste.removeWhere((s) => s == section);
    }
  }

  Map<String, List<String>> _parseOptionsSections(dynamic raw) {
    final result = <String, List<String>>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final nom = k.toString().trim();
        if (nom.isEmpty) return;
        final liste = <String>[];
        if (v is List) {
          for (final s in v) {
            final t = s.toString();
            if (t.isNotEmpty && !liste.contains(t)) liste.add(t);
          }
        }
        result[nom] = liste;
      });
    }
    return result;
  }

  void _nettoyerOptions() {
    final propres = <String, List<String>>{};
    final dejaAffectees = <String>{};
    optionsSections.forEach((nom, secs) {
      final n = nom.trim();
      if (n.isEmpty || propres.containsKey(n)) return;
      final liste = <String>[];
      for (final s in secs) {
        if (config.sections.isNotEmpty && !config.sections.contains(s)) {
          continue;
        }
        if (dejaAffectees.contains(s) || liste.contains(s)) continue;
        liste.add(s);
        dejaAffectees.add(s);
      }
      propres[n] = liste;
    });
    optionsSections = propres;
  }

  List<GroupeOption> _groupesOptions(Iterable<String> sectionsPresentes) {
    final presentes = <String>{...sectionsPresentes};
    final groupes = <GroupeOption>[];
    final dejaPris = <String>{};

    optionsSections.forEach((nom, secs) {
      final incluses = secs
          .where((s) => presentes.contains(s) && !dejaPris.contains(s))
          .toList();
      if (incluses.isEmpty) return;
      dejaPris.addAll(incluses);
      groupes.add(
          GroupeOption(nom: nom, sections: incluses, estOption: true));
    });

    final restantes = <String>[
      ...config.sections
          .where((s) => presentes.contains(s) && !dejaPris.contains(s)),
      ...(presentes
          .where((s) => !config.sections.contains(s) && !dejaPris.contains(s))
          .toList()
        ..sort()),
    ];
    for (final s in restantes) {
      groupes.add(GroupeOption(nom: s, sections: [s], estOption: false));
    }

    int cle(GroupeOption g) {
      var m = 1 << 30;
      for (final s in g.sections) {
        var i = config.sections.indexOf(s);
        if (i < 0) i = 1 << 20;
        if (i < m) m = i;
      }
      return m;
    }

    groupes.sort((a, b) {
      final c = cle(a).compareTo(cle(b));
      if (c != 0) return c;
      return a.nom.compareTo(b.nom);
    });
    return groupes;
  }

  String _tauxMensuelLabel(List<Eleve> eleves) {
    if (eleves.isEmpty) return '-';
    final mois = currentSchoolMonthName ?? months.first;
    double? min;
    double? max;
    for (final e in eleves) {
      final v = getRequiredForMonth(mois, e.section, e.classe);
      if (min == null || v < min) min = v;
      if (max == null || v > max) max = v;
    }
    if (min == null || max == null) return '-';
    if ((max - min).abs() < 0.5) return formatMontant(min);
    return '${formatMontant(min)} - ${formatMontant(max)}';
  }

  String _pctLabel(double p) =>
      p == p.roundToDouble() ? p.toStringAsFixed(0) : p.toStringAsFixed(1);

  List<Depense> getDepensesForYear([String? year]) {
    final y = year ?? currentYear;
    final list = List<Depense>.from(depensesByYear[y] ?? []);
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  double getTotalDepenses([String? year]) {
    final y = year ?? currentYear;
    return (depensesByYear[y] ?? [])
        .fold(0.0, (sum, d) => sum + d.montant);
  }

  double getTotalDepensesToday([String? year]) {
    final y = year ?? currentYear;
    final today = DateTime.now().toString().split(' ')[0];
    return (depensesByYear[y] ?? [])
        .where((d) => d.date.toString().split(' ')[0] == today)
        .fold(0.0, (sum, d) => sum + d.montant);
  }

  double getTotalDepensesThisMonth([String? year]) {
    final y = year ?? currentYear;
    final now = DateTime.now();
    return (depensesByYear[y] ?? [])
        .where((d) => d.date.year == now.year && d.date.month == now.month)
        .fold(0.0, (sum, d) => sum + d.montant);
  }

  double getTotalDepensesParPortee(String portee, [String? year]) {
    final y = year ?? currentYear;
    return (depensesByYear[y] ?? [])
        .where((d) => d.portee == portee)
        .fold(0.0, (sum, d) => sum + d.montant);
  }

  double getSoldeNetActuel([String? year]) {
    final y = year ?? currentYear;
    final totalCollecte = (y == currentYear)
        ? getYearTotalCollected()
        : months.fold<double>(
      0.0,
          (sum, m) =>
      sum +
          (history[y]?.eleves.fold<double>(
              0.0, (s, e) => s + (e.paid[m] ?? 0)) ??
              0.0),
    );
    return totalCollecte - getTotalDepenses(y);
  }

  double getSoldeNetForPeriod(String period, [String? year]) {
    switch (period) {
      case 'today':
        return getMoneyCollectedForPeriod('today') -
            getTotalDepensesToday(year);
      case 'month':
        return getMoneyCollectedForPeriod('month') -
            getTotalDepensesThisMonth(year);
      case 'year':
      default:
        return getSoldeNetActuel(year);
    }
  }

  List<String> getRubriquesDisponibles() {
    final result = <String>[];
    for (final a in config.administrations) {
      final nom = a.nom.trim();
      if (nom.isNotEmpty && !result.contains(nom)) result.add(nom);
    }
    result.add(kRubriqueAutre);
    return result;
  }

  Map<String, double> repartitionDepenseParSection(Depense d) {
    if (d.portee == kDepenseGlobale || d.sections.isEmpty) return {};
    final part = d.montant / d.sections.length;
    return {for (final s in d.sections) s: part};
  }

  bool _depenseConcerneFiltre(
      Depense d, String? sectionFilter, String? classFilter) {
    if (d.portee == kDepenseGlobale) return true;
    if (sectionFilter != null && !d.sections.contains(sectionFilter)) {
      return false;
    }
    if (classFilter != null &&
        d.classes.isNotEmpty &&
        !d.classes.contains(classFilter)) {
      return false;
    }
    return true;
  }

  List<Depense> getDepensesForPeriod(
      String period, {
        String? year,
        String? sectionFilter,
        String? classFilter,
      }) {
    final y = year ?? currentYear;
    final now = DateTime.now();
    final todayStr = now.toString().split(' ')[0];
    final list = (depensesByYear[y] ?? []).where((d) {
      bool okPeriode;
      switch (period) {
        case 'today':
          okPeriode = d.date.toString().split(' ')[0] == todayStr;
          break;
        case 'month':
          okPeriode = d.date.year == now.year && d.date.month == now.month;
          break;
        case 'year':
        default:
          okPeriode = true;
      }
      return okPeriode && _depenseConcerneFiltre(d, sectionFilter, classFilter);
    }).toList();
    list.sort((a, b) => a.date.compareTo(b.date));
    return list;
  }

  Map<String, double> _collecteParSectionPourPeriode(String period) {
    switch (period) {
      case 'today':
        return getMoneyCollectedTodayBySection();
      case 'month':
        return getMoneyCollectedThisMonthBySection();
      case 'year':
      default:
        return getTotalBySection();
    }
  }

  DepensePeriodeStats computeDepensesStats(
      String period, {
        String? year,
        String? sectionFilter,
        String? classFilter,
      }) {
    final collecteAll = _collecteParSectionPourPeriode(period);
    final collecteBySection = <String, double>{};
    collecteAll.forEach((s, v) {
      if (sectionFilter == null || s == sectionFilter) {
        collecteBySection[s] = v;
      }
    });
    final double totalCollecte =
    collecteBySection.values.fold(0.0, (a, b) => a + b);

    final depenses = getDepensesForPeriod(
      period,
      year: year,
      sectionFilter: sectionFilter,
      classFilter: classFilter,
    );

    final Map<String, RubriqueStat> rub = {};
    for (final admin in config.administrations) {
      final nom = admin.nom.trim();
      if (nom.isEmpty) continue;
      rub[nom] = RubriqueStat(
        rubrique: nom,
        pourcentage: admin.pourcentage,
        collecte: totalCollecte * (admin.pourcentage / 100),
      );
    }

    final Map<String, SectionStat> secStats = {};
    final sectionsBase = sectionFilter != null
        ? <String>[sectionFilter]
        : List<String>.from(config.sections);
    for (final s in sectionsBase) {
      secStats[s] = SectionStat(section: s, collecte: collecteBySection[s] ?? 0);
    }
    collecteBySection.forEach((s, v) {
      secStats.putIfAbsent(s, () => SectionStat(section: s, collecte: v));
    });

    double globales = 0;
    double independantes = 0;
    double mixtes = 0;

    for (final d in depenses) {
      final cle = d.rubriqueAffichee;
      final r = rub.putIfAbsent(
        cle,
            () => RubriqueStat(rubrique: cle, pourcentage: 0, collecte: 0),
      );
      if (d.portee == kDepenseGlobale) {
        if (sectionFilter == null) {
          r.globales += d.montant;
          globales += d.montant;
        }
      } else {
        final parts = repartitionDepenseParSection(d);
        parts.forEach((s, amt) {
          if (sectionFilter != null && s != sectionFilter) return;
          final st = secStats.putIfAbsent(
              s, () => SectionStat(section: s, collecte: 0));
          if (d.portee == kDepenseIndependante) {
            r.independantes += amt;
            st.independantes += amt;
            independantes += amt;
          } else {
            r.mixtes += amt;
            st.mixtes += amt;
            mixtes += amt;
          }
        });
      }
    }

    return DepensePeriodeStats(
      period: period,
      depenses: depenses,
      rubriques: rub.values.toList(),
      sections: secStats.values.toList(),
      totalCollecte: totalCollecte,
      globales: globales,
      independantes: independantes,
      mixtes: mixtes,
      globalesExclues: sectionFilter != null,
    );
  }

  double? getSoldeDisponibleRubrique({
    required String rubrique,
    required String portee,
    List<String> sections = const [],
  }) {
    if (rubrique == kRubriqueAutre || rubrique.trim().isEmpty) return null;
    double pct = 0;
    for (final a in config.administrations) {
      if (a.nom.trim() == rubrique.trim()) {
        pct = a.pourcentage;
        break;
      }
    }
    final collecteSec = getTotalBySection();
    double collecte = 0;
    if (portee == kDepenseGlobale) {
      collecte = collecteSec.values.fold(0.0, (a, b) => a + b) * pct / 100;
    } else {
      for (final s in sections) {
        collecte += (collecteSec[s] ?? 0) * pct / 100;
      }
    }

    double depense = 0;
    for (final d in (depensesByYear[currentYear] ?? [])) {
      if (d.rubrique.trim() != rubrique.trim()) continue;
      if (portee == kDepenseGlobale) {
        depense += d.montant;
      } else {
        final parts = repartitionDepenseParSection(d);
        for (final s in sections) {
          depense += parts[s] ?? 0;
        }
      }
    }
    return collecte - depense;
  }

  Future<Depense> addDepense({
    required String motif,
    required double montant,
    String enregistrePar = 'Direction',
    String portee = kDepenseGlobale,
    List<String>? sections,
    List<String>? classes,
    String rubrique = '',
    DateTime? date,
  }) async {
    final depense = Depense(
      id: 'DEP${DateTime.now().millisecondsSinceEpoch}',
      motif: motif.trim(),
      montant: montant,
      date: date ?? DateTime.now(),
      enregistrePar: enregistrePar,
      portee: portee,
      sections: portee == kDepenseGlobale ? [] : (sections ?? []),
      classes: portee == kDepenseGlobale ? [] : (classes ?? []),
      rubrique: rubrique.trim(),
    );
    depensesByYear.putIfAbsent(currentYear, () => []).add(depense);
    await saveData();
    return depense;
  }

  Future<Depense> addDepenseParOption({
    required String motif,
    required double montant,
    required String option,
    String enregistrePar = 'Direction',
    List<String>? classes,
    String rubrique = '',
    DateTime? date,
  }) async {
    final sections = getSectionsPourOption(option);
    if (sections.isEmpty) {
      throw Exception("L'option \"$option\" ne contient aucune section.");
    }
    return addDepense(
      motif: motif,
      montant: montant,
      enregistrePar: enregistrePar,
      portee: sections.length == 1 ? kDepenseIndependante : kDepenseMixte,
      sections: sections,
      classes: classes,
      rubrique: rubrique,
      date: date,
    );
  }

  Future<void> deleteDepense(String id, [String? year]) async {
    final y = year ?? currentYear;
    depensesByYear[y]?.removeWhere((d) => d.id == id);
    await saveData();
  }

  Future<void> updateDepenseDate(
      String id,
      DateTime newDate, [
        String? year,
      ]) async {
    final y = year ?? currentYear;
    final list = depensesByYear[y];
    if (list == null) return;
    for (final d in list) {
      if (d.id == id) {
        d.date = newDate;
        break;
      }
    }
    await saveData();
  }

  Future<void> clearDepensesForYear([String? year]) async {
    final y = year ?? currentYear;
    depensesByYear[y] = [];
    await saveData();
  }

  List<AutreFrais> getAutresFrais() {
    final list = List<AutreFrais>.from(autresFrais);
    list.sort((a, b) => a.nom.toLowerCase().compareTo(b.nom.toLowerCase()));
    return list;
  }

  // ==========================================================================
  // ⚡ NOUVEAU — FUSION (POUR LES RAPPORTS UNIQUEMENT) DES "AUTRES FRAIS"
  // PORTANT LE MÊME NOM
  // ==========================================================================
  // Deux frais sont considérés comme "le même type de frais" quand leur nom
  // est identique après normalisation (espaces superflus retirés, majuscules/
  // minuscules ignorées). Exemple : "Frais de l'État", "frais de l'état " et
  // "FRAIS DE L'ÉTAT" forment un seul groupe.
  //
  // ⚠️ AUCUNE donnée n'est modifiée : ni les frais, ni les montants, ni les
  // paiements, ni les reçus, ni les calculs de caisse. Ces méthodes ne font
  // que LIRE la liste `autresFrais` pour proposer un regroupement dans
  // l'écran de génération de rapport.
  // ==========================================================================
  String normaliserNomFrais(String nom) =>
      nom.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  List<AutreFraisGroupe> getAutresFraisGroupes() {
    final Map<String, List<AutreFrais>> parCle = {};
    for (final f in autresFrais) {
      final cle = normaliserNomFrais(f.nom);
      if (cle.isEmpty) continue;
      parCle.putIfAbsent(cle, () => []).add(f);
    }

    final result = <AutreFraisGroupe>[];
    parCle.forEach((cle, liste) {
      double min = double.infinity;
      double max = double.negativeInfinity;
      void considerer(double v) {
        if (v < min) min = v;
        if (v > max) max = v;
      }

      for (final f in liste) {
        considerer(f.montant);
        for (final v in f.montantsParSection.values) {
          considerer(v);
        }
        for (final v in f.montantsParClasse.values) {
          considerer(v);
        }
      }
      if (min == double.infinity) {
        min = 0;
        max = 0;
      }

      result.add(AutreFraisGroupe(
        cle: cle,
        nom: liste.first.nom.trim(),
        ids: liste.map((f) => f.id).toList(),
        montantMin: min,
        montantMax: max,
      ));
    });

    result.sort((a, b) => a.nom.toLowerCase().compareTo(b.nom.toLowerCase()));
    return result;
  }

  Future<AutreFrais> addAutreFrais({
    required String nom,
    required double montant,
    String scope = 'all',
    String? section,
    String? classe,
  }) async {
    final frais = AutreFrais(
      id: 'AF${DateTime.now().millisecondsSinceEpoch}',
      nom: nom.trim(),
      montant: montant,
      scope: scope,
      section: scope == 'all' ? null : section,
      classe: scope == 'classe' ? classe : null,
    );
    autresFrais.add(frais);
    await saveData();
    return frais;
  }

  Future<void> deleteAutreFrais(String id) async {
    autresFrais.removeWhere((f) => f.id == id);
    await saveData();
  }

  Future<void> updateAutreFrais(
      String id, {
        required String nom,
        required double montant,
        required String scope,
        String? section,
        String? classe,
      }) async {
    for (var f in autresFrais) {
      if (f.id == id) {
        f.nom = nom.trim();
        f.montant = montant;
        f.scope = scope;
        f.section = scope == 'all' ? null : section;
        f.classe = scope == 'classe' ? classe : null;
        break;
      }
    }
    await saveData();
  }

  Future<void> setMontantSectionPourAutreFrais(
      String autreFraisId, String section, double montant) async {
    for (var f in autresFrais) {
      if (f.id == autreFraisId) {
        f.montantsParSection[section] = montant;
        break;
      }
    }
    await saveData();
  }

  Future<void> removeMontantSectionPourAutreFrais(
      String autreFraisId, String section) async {
    for (var f in autresFrais) {
      if (f.id == autreFraisId) {
        f.montantsParSection.remove(section);
        break;
      }
    }
    await saveData();
  }

  Future<void> setMontantClassePourAutreFrais(
      String autreFraisId,
      String section,
      String classeNumero,
      double montant,
      ) async {
    final key = _classeKey(section, classeNumero);
    for (var f in autresFrais) {
      if (f.id == autreFraisId) {
        f.montantsParClasse[key] = montant;
        break;
      }
    }
    await saveData();
  }

  Future<void> removeMontantClassePourAutreFrais(
      String autreFraisId, String section, String classeNumero) async {
    final key = _classeKey(section, classeNumero);
    for (var f in autresFrais) {
      if (f.id == autreFraisId) {
        f.montantsParClasse.remove(key);
        break;
      }
    }
    await saveData();
  }

  bool autreFraisAppliesToStudent(AutreFrais frais, Eleve eleve) {
    switch (frais.scope) {
      case 'section':
        return frais.section != null && eleve.section == frais.section;
      case 'classe':
        return frais.section != null &&
            frais.classe != null &&
            eleve.section == frais.section &&
            classeNumeroFromFullClasse(eleve.classe) == frais.classe;
      case 'all':
      default:
        return true;
    }
  }

  List<Eleve> getEligibleStudentsForAutreFrais(AutreFrais frais) {
    final students = currentData.eleves
        .where((e) => autreFraisAppliesToStudent(frais, e))
        .toList();
    students.sort((a, b) {
      final c = a.classe.compareTo(b.classe);
      if (c != 0) return c;
      return a.nom.compareTo(b.nom);
    });
    return students;
  }

  double getMontantAutreFraisPourEleve(AutreFrais frais, Eleve eleve) {
    final classeNumero = classeNumeroFromFullClasse(eleve.classe);
    final classeKey = _classeKey(eleve.section, classeNumero);
    if (frais.montantsParClasse.containsKey(classeKey)) {
      return frais.montantsParClasse[classeKey]!;
    }
    if (frais.montantsParSection.containsKey(eleve.section)) {
      return frais.montantsParSection[eleve.section]!;
    }
    return frais.montant;
  }

  // ==========================================================================
  // ⚡ NOUVEAU — TRANCHES DES "AUTRES FRAIS"
  // ==========================================================================
  // Les tranches se configurent directement depuis l'écran de paiement des
  // Autres Frais (plus besoin des Paramètres). Une tranche est rattachée à
  // une CIBLE :
  //   - toute l'école        -> clé 'ALL'
  //   - une section          -> clé 'S:<section>'
  //   - une classe           -> clé 'C:<section>|<classe>'
  //
  // Pour un élève donné, on retient les tranches de la cible la plus précise
  // qui en possède : classe, puis section, puis toute l'école. Si aucune
  // cible n'a de tranche, le frais se paie en une seule fois (comme avant).
  //
  // Un élève paie les tranches dans l'ordre (la prochaine non payée). Chaque
  // paiement garde l'id, le nom, le numéro de la tranche : ils sont repris
  // sur le reçu et dans le rapport PDF.
  // ==========================================================================
  static const String kTrancheCleTous = 'ALL';

  String cleTrancheSection(String section) => 'S:$section';

  String cleTrancheClasse(String section, String classeNumero) =>
      'C:${_classeKey(section, classeNumero)}';

  String cleTranchePourCible({String? section, String? classeNumero}) {
    if (section != null && classeNumero != null) {
      return cleTrancheClasse(section, classeNumero);
    }
    if (section != null) return cleTrancheSection(section);
    return kTrancheCleTous;
  }

  String nomTrancheSuggere(int numero) {
    switch (numero) {
      case 1:
        return 'Première tranche';
      case 2:
        return 'Deuxième tranche';
      case 3:
        return 'Troisième tranche';
      default:
        return '${numero}ème tranche';
    }
  }

  AutreFrais? _trouverAutreFrais(String autreFraisId) {
    for (final f in autresFrais) {
      if (f.id == autreFraisId) return f;
    }
    return null;
  }

  List<AutreFraisTranche> getTranchesPourCle(AutreFrais frais, String cle) =>
      List<AutreFraisTranche>.from(
          frais.tranchesParCle[cle] ?? const <AutreFraisTranche>[]);

  List<AutreFraisTranche> getTranchesPourEleve(AutreFrais frais, Eleve eleve) {
    final numero = classeNumeroFromFullClasse(eleve.classe);
    final cles = <String>[
      cleTrancheClasse(eleve.section, numero),
      cleTrancheSection(eleve.section),
      kTrancheCleTous,
    ];
    for (final cle in cles) {
      final liste = frais.tranchesParCle[cle];
      if (liste != null && liste.isNotEmpty) {
        return List<AutreFraisTranche>.from(liste);
      }
    }
    return <AutreFraisTranche>[];
  }

  bool autreFraisAUneTranchePourEleve(AutreFrais frais, Eleve eleve) =>
      getTranchesPourEleve(frais, eleve).isNotEmpty;

  double getMontantAutreFraisPourCible(
      AutreFrais frais, {
        String? section,
        String? classeNumero,
      }) {
    if (section != null && classeNumero != null) {
      final key = _classeKey(section, classeNumero);
      if (frais.montantsParClasse.containsKey(key)) {
        return frais.montantsParClasse[key]!;
      }
    }
    if (section != null && frais.montantsParSection.containsKey(section)) {
      return frais.montantsParSection[section]!;
    }
    return frais.montant;
  }

  Future<AutreFraisTranche?> addTranchePourAutreFrais({
    required String autreFraisId,
    required String cle,
    required String nom,
    required double montant,
  }) async {
    final frais = _trouverAutreFrais(autreFraisId);
    if (frais == null) return null;
    final tranche = AutreFraisTranche(
      id: 'TR${DateTime.now().microsecondsSinceEpoch}',
      nom: nom.trim(),
      montant: montant,
    );
    frais.tranchesParCle.putIfAbsent(cle, () => []).add(tranche);
    await saveData();
    return tranche;
  }

  Future<bool> updateTranchePourAutreFrais({
    required String autreFraisId,
    required String cle,
    required String trancheId,
    required String nom,
    required double montant,
  }) async {
    final frais = _trouverAutreFrais(autreFraisId);
    if (frais == null) return false;
    final liste = frais.tranchesParCle[cle];
    if (liste == null) return false;
    for (final t in liste) {
      if (t.id == trancheId) {
        t.nom = nom.trim();
        t.montant = montant;
        await saveData();
        return true;
      }
    }
    return false;
  }

  int compterPaiementsPourTranche(String trancheId) {
    int count = 0;
    for (final liste in autresFraisPaiementsByYear.values) {
      for (final p in liste) {
        if (p.trancheId == trancheId) count++;
      }
    }
    return count;
  }

  // Une tranche qui a déjà reçu au moins un paiement ne peut pas être
  // supprimée (retourne false) : sinon les rapports et les reçus déjà émis
  // ne correspondraient plus à la configuration.
  Future<bool> deleteTranchePourAutreFrais({
    required String autreFraisId,
    required String cle,
    required String trancheId,
  }) async {
    if (compterPaiementsPourTranche(trancheId) > 0) return false;
    final frais = _trouverAutreFrais(autreFraisId);
    if (frais == null) return false;
    final liste = frais.tranchesParCle[cle];
    if (liste == null) return false;
    liste.removeWhere((t) => t.id == trancheId);
    if (liste.isEmpty) frais.tranchesParCle.remove(cle);
    await saveData();
    return true;
  }

  List<AutreFraisPaiement> getPaiementsEleveAutreFrais(
      Eleve eleve, AutreFrais frais, [String? year]) {
    final y = year ?? currentYear;
    return (autresFraisPaiementsByYear[y] ?? [])
        .where((p) => p.autreFraisId == frais.id && p.eleveId == eleve.id)
        .toList();
  }

  bool hasPaidTrancheAutreFrais(
      Eleve eleve, AutreFrais frais, AutreFraisTranche tranche,
      [String? year]) {
    return getPaiementsEleveAutreFrais(eleve, frais, year)
        .any((p) => p.trancheId == tranche.id);
  }

  // Retourne la prochaine tranche non payée de l'élève (ou null s'il n'y a
  // pas de tranche pour lui, ou si toutes sont déjà payées).
  AutreFraisTranche? getProchaineTrancheAutreFrais(
      AutreFrais frais, Eleve eleve,
      [String? year]) {
    final tranches = getTranchesPourEleve(frais, eleve);
    if (tranches.isEmpty) return null;
    final paiements = getPaiementsEleveAutreFrais(eleve, frais, year);
    for (final t in tranches) {
      if (!paiements.any((p) => p.trancheId == t.id)) return t;
    }
    return null;
  }

  int getNombreTranchesPayeesAutreFrais(Eleve eleve, AutreFrais frais,
      [String? year]) {
    final tranches = getTranchesPourEleve(frais, eleve);
    if (tranches.isEmpty) return 0;
    final paiements = getPaiementsEleveAutreFrais(eleve, frais, year);
    int count = 0;
    for (final t in tranches) {
      if (paiements.any((p) => p.trancheId == t.id)) count++;
    }
    return count;
  }

  // Montant réellement à payer maintenant par l'élève (prochaine tranche,
  // ou montant complet si le frais n'a pas de tranche).
  double getMontantProchainPaiementAutreFrais(AutreFrais frais, Eleve eleve) {
    final prochaine = getProchaineTrancheAutreFrais(frais, eleve);
    if (prochaine != null) return prochaine.montant;
    return getMontantAutreFraisPourEleve(frais, eleve);
  }

  // Reste à payer sur ce frais (somme des tranches non payées, ou montant
  // complet si aucun paiement et pas de tranche, 0 si tout est payé).
  double getResteAPayerAutreFrais(AutreFrais frais, Eleve eleve) {
    if (hasPaidAutreFrais(eleve, frais)) return 0;
    final tranches = getTranchesPourEleve(frais, eleve);
    if (tranches.isEmpty) return getMontantAutreFraisPourEleve(frais, eleve);
    final paiements = getPaiementsEleveAutreFrais(eleve, frais);
    double reste = 0;
    for (final t in tranches) {
      if (!paiements.any((p) => p.trancheId == t.id)) reste += t.montant;
    }
    return reste;
  }

  // ⚡ CORRIGÉ — "payé" signifie "entièrement payé" :
  //   - SANS tranche pour l'élève : au moins un paiement existe (comportement
  //     d'avant, inchangé) ;
  //   - AVEC tranches pour l'élève : TOUTES les tranches de l'élève doivent
  //     être payées. Un ancien paiement unique (fait AVANT la configuration
  //     des tranches, donc sans trancheId) ne compte plus comme "tout payé" :
  //     il ne bloque plus l'élève, qui doit payer chaque tranche (première,
  //     deuxième, troisième…). Cet ancien paiement reste enregistré et
  //     continue d'être compté dans les totaux de caisse et les rapports.
  bool hasPaidAutreFrais(Eleve eleve, AutreFrais frais, [String? year]) {
    final paiements = getPaiementsEleveAutreFrais(eleve, frais, year);
    if (paiements.isEmpty) return false;
    final tranches = getTranchesPourEleve(frais, eleve);
    if (tranches.isEmpty) return true;
    return tranches.every((t) => paiements.any((p) => p.trancheId == t.id));
  }

  // Au moins un paiement (tranche ou ancien paiement unique), mais pas encore
  // tout payé (cas des tranches).
  bool hasPaidPartiellementAutreFrais(Eleve eleve, AutreFrais frais,
      [String? year]) {
    final paiements = getPaiementsEleveAutreFrais(eleve, frais, year);
    if (paiements.isEmpty) return false;
    return !hasPaidAutreFrais(eleve, frais, year);
  }

  // ⚡ MODIFIÉ — paiement d'un autre frais. Si le frais a des tranches pour
  // cet élève, on paie la tranche demandée (`tranche`) ou, par défaut, la
  // prochaine tranche non payée. Une exception est levée si toutes les
  // tranches sont déjà payées ou si la tranche demandée l'est déjà.
  Future<AutreFraisPaiement> payAutreFrais({
    required AutreFrais frais,
    required Eleve eleve,
    String enregistrePar = 'Direction',
    AutreFraisTranche? tranche,
  }) async {
    final tranches = getTranchesPourEleve(frais, eleve);
    AutreFraisTranche? aPayer = tranche;
    if (aPayer == null && tranches.isNotEmpty) {
      aPayer = getProchaineTrancheAutreFrais(frais, eleve);
      if (aPayer == null) {
        throw Exception('Toutes les tranches de "${frais.nom}" sont déjà '
            'payées pour cet élève.');
      }
    }
    if (aPayer != null && hasPaidTrancheAutreFrais(eleve, frais, aPayer)) {
      throw Exception('La tranche "${aPayer.nom}" est déjà payée pour cet '
          'élève.');
    }

    final double montant = aPayer != null
        ? aPayer.montant
        : getMontantAutreFraisPourEleve(frais, eleve);

    int numeroTranche = 0;
    if (aPayer != null) {
      final idx = tranches.indexWhere((t) => t.id == aPayer!.id);
      numeroTranche = idx >= 0 ? idx + 1 : 0;
    }

    final paiement = AutreFraisPaiement(
      id: 'AFP${DateTime.now().microsecondsSinceEpoch}',
      autreFraisId: frais.id,
      autreFraisNom: frais.nom,
      eleveId: eleve.id,
      montant: montant,
      date: DateTime.now(),
      enregistrePar: enregistrePar,
      trancheId: aPayer?.id ?? '',
      trancheNom: aPayer?.nom ?? '',
      trancheNumero: numeroTranche,
      trancheTotal: aPayer != null ? tranches.length : 0,
    );
    autresFraisPaiementsByYear
        .putIfAbsent(currentYear, () => [])
        .add(paiement);
    await saveData();
    return paiement;
  }

  Future<void> deleteAutreFraisPaiement(String id, [String? year]) async {
    final y = year ?? currentYear;
    autresFraisPaiementsByYear[y]?.removeWhere((p) => p.id == id);
    await saveData();
  }

  List<AutreFraisPaiement> getAutresFraisPaiementsForYear([String? year]) {
    final y = year ?? currentYear;
    final list = List<AutreFraisPaiement>.from(
        autresFraisPaiementsByYear[y] ?? []);
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  double getTotalPaidForAutreFrais(
      AutreFrais frais, {
        String? year,
        String? sectionFilter,
        String? classFilter,
      }) {
    final y = year ?? currentYear;
    Iterable<AutreFraisPaiement> paiements =
    (autresFraisPaiementsByYear[y] ?? [])
        .where((p) => p.autreFraisId == frais.id);

    if (sectionFilter != null || classFilter != null) {
      paiements = paiements.where((p) {
        Eleve? eleve;
        for (final e in currentData.eleves) {
          if (e.id == p.eleveId) {
            eleve = e;
            break;
          }
        }
        if (eleve == null) return false;
        if (sectionFilter != null && eleve.section != sectionFilter) {
          return false;
        }
        if (classFilter != null && eleve.classe != classFilter) {
          return false;
        }
        return true;
      });
    }

    return paiements.fold(0.0, (sum, p) => sum + p.montant);
  }

  Map<String, double> calculateAutresFraisAdminDistribution(
      double totalAmount) {
    final distribution = <String, double>{};
    for (var admin in autresFraisAdministrations) {
      distribution[admin.nom] = totalAmount * (admin.pourcentage / 100);
    }
    return distribution;
  }

  double getTotalPourcentageAutresFraisAdministrations() =>
      autresFraisAdministrations.fold(0.0, (sum, a) => sum + a.pourcentage);

  Map<String, double> getAdminDistributionForAutreFrais(
      AutreFrais frais, {
        String? year,
        String? sectionFilter,
        String? classFilter,
      }) {
    final double total = getTotalPaidForAutreFrais(
      frais,
      year: year,
      sectionFilter: sectionFilter,
      classFilter: classFilter,
    );
    return calculateAutresFraisAdminDistribution(total);
  }

  List<AutreFraisAdministration> getAutresFraisAdministrations() =>
      List<AutreFraisAdministration>.from(autresFraisAdministrations);

  Future<AutreFraisAdministration> addAutreFraisAdministration({
    required String nom,
    required double pourcentage,
  }) async {
    final admin = AutreFraisAdministration(
      id: 'AFA${DateTime.now().millisecondsSinceEpoch}',
      nom: nom.trim(),
      pourcentage: pourcentage,
    );
    autresFraisAdministrations.add(admin);
    await saveData();
    return admin;
  }

  Future<void> updateAutreFraisAdministration(
      String id, {
        required String nom,
        required double pourcentage,
      }) async {
    for (var a in autresFraisAdministrations) {
      if (a.id == id) {
        a.nom = nom.trim();
        a.pourcentage = pourcentage;
        break;
      }
    }
    await saveData();
  }

  Future<void> deleteAutreFraisAdministration(String id) async {
    autresFraisAdministrations.removeWhere((a) => a.id == id);
    await saveData();
  }

  List<String> getOptions() => List<String>.from(config.sections);

  RepartitionDetail getRepartitionForOption(String option) =>
      getRepartitionForOptionPeriod(option, 'year');

  RepartitionDetail getRepartitionForOptionPeriod(
      String option, String period) {
    double total;
    switch (period) {
      case 'today':
        total = getMoneyCollectedTodayBySection()[option] ?? 0.0;
        break;
      case 'month':
        total = getMoneyCollectedThisMonthBySection()[option] ?? 0.0;
        break;
      case 'year':
      default:
        total = getStudentsBySection(option)
            .fold(0.0, (sum, e) => sum + getStudentTotalPaid(e));
    }
    return RepartitionDetail(
      label: option,
      total: total,
      parAdministration: calculateAdminDistribution(total),
    );
  }

  String _sousSectionLabelFor(Eleve eleve) {
    final sousClasse = subClasseFromFullClasse(eleve.classe);
    if (sousClasse != null && sousClasse.trim().isNotEmpty) {
      return sousClasse.trim();
    }
    final numero = classeNumeroFromFullClasse(eleve.classe);
    return "Éducation de Base ($numero)";
  }

  double _getStudentAmountForPeriod(Eleve eleve, String period) {
    switch (period) {
      case 'today':
        final today = DateTime.now().toString().split(' ')[0];
        double sum = 0;
        for (final t in eleve.transactions) {
          if (t['date'] == today) {
            sum += (t['amount'] as num?)?.toDouble() ?? 0.0;
          }
        }
        return sum;
      case 'month':
        final idx = _schoolMonthIndexForToday();
        if (idx < 0 || idx >= months.length) return 0.0;
        return eleve.paid[months[idx]] ?? 0.0;
      case 'year':
      default:
        return getStudentTotalPaid(eleve);
    }
  }

  List<RepartitionDetail> getSousSectionsForOption(String option) =>
      getSousSectionsForOptionPeriod(option, 'year');

  List<RepartitionDetail> getSousSectionsForOptionPeriod(
      String option, String period) {
    final students = getStudentsBySection(option);
    final Map<String, double> totalsByLabel = {};
    for (var e in students) {
      final label = _sousSectionLabelFor(e);
      final montant = _getStudentAmountForPeriod(e, period);
      totalsByLabel[label] = (totalsByLabel[label] ?? 0) + montant;
    }
    final details = totalsByLabel.entries
        .map((entry) => RepartitionDetail(
      label: entry.key,
      total: entry.value,
      parAdministration: calculateAdminDistribution(entry.value),
    ))
        .toList();
    details.sort((a, b) {
      final aBase = a.label.startsWith("Éducation de Base");
      final bBase = b.label.startsWith("Éducation de Base");
      if (aBase && !bBase) return -1;
      if (!aBase && bBase) return 1;
      return a.label.compareTo(b.label);
    });
    return details;
  }

  bool optionHasSousSections(String option) {
    return getStudentsBySection(option).any((e) {
      final sc = subClasseFromFullClasse(e.classe);
      return sc != null && sc.trim().isNotEmpty;
    });
  }

  List<double> getMonthlyEvolution({
    String? option,
    String? sousSectionLabel,
    String? classe,
  }) {
    List<Eleve> students = currentData.eleves;
    if (option != null) {
      students = students.where((e) => e.section == option).toList();
    }
    if (sousSectionLabel != null) {
      students = students
          .where((e) => _sousSectionLabelFor(e) == sousSectionLabel)
          .toList();
    }
    if (classe != null) {
      students = students.where((e) => e.classe == classe).toList();
    }
    return months
        .map((m) =>
        students.fold<double>(0.0, (sum, e) => sum + (e.paid[m] ?? 0)))
        .toList();
  }

  List<String> getClassesForOptionAndSousSection(
      String option, [
        String? sousSectionLabel,
      ]) {
    final classes = getAllDisplayClassesForSection(option);
    if (sousSectionLabel == null) return classes;
    return classes.where((c) {
      final sousClasse = subClasseFromFullClasse(c);
      final label = (sousClasse != null && sousClasse.trim().isNotEmpty)
          ? sousClasse.trim()
          : "Éducation de Base (${classeNumeroFromFullClasse(c)})";
      return label == sousSectionLabel;
    }).toList();
  }

  bool isStudentEnOrdrePourMois(Eleve eleve, String mois) {
    final required     = getRequiredForMonthForEleve(eleve, mois);
    final paidForMonth = eleve.paid[mois] ?? 0;
    return paidForMonth >= required;
  }

  List<Eleve> getStudentsByOrderStatus({
    required String mois,
    required bool enOrdre,
    String? sectionFilter,
    String? classFilter,
  }) {
    List<Eleve> students = currentData.eleves;
    if (sectionFilter != null) {
      students = students.where((e) => e.section == sectionFilter).toList();
    }
    if (classFilter != null) {
      students = students.where((e) => e.classe == classFilter).toList();
    }
    students = students
        .where((e) => isStudentEnOrdrePourMois(e, mois) == enOrdre)
        .toList();

    students.sort((a, b) {
      final c = a.classe.compareTo(b.classe);
      if (c != 0) return c;
      return a.nom.compareTo(b.nom);
    });
    return students;
  }

  void recalculerRepartitionMoisPourEleve(Eleve eleve) {
    if (eleve.transactions.isEmpty) {
      final double totalPayeSansTransactions = getStudentTotalPaid(eleve);
      if (totalPayeSansTransactions > 0) {
        double restant = totalPayeSansTransactions;
        final Map<String, double> paidSansTransactions = {};
        for (final mois in months) {
          if (restant <= 0) break;
          final double requis = getRequiredForMonthForEleve(eleve, mois);
          if (requis <= 0) continue;
          final double aAffecter = restant >= requis ? requis : restant;
          paidSansTransactions[mois] = aAffecter;
          restant -= aAffecter;
        }
        if (restant > 0 && months.isNotEmpty) {
          final dernierMois = months.last;
          paidSansTransactions[dernierMois] =
              (paidSansTransactions[dernierMois] ?? 0) + restant;
        }
        eleve.paid
          ..clear()
          ..addAll(paidSansTransactions);
        _rafraichirRecusEnAttentePourEleve(eleve);
        return;
      }
      eleve.paid.clear();
      _rafraichirRecusEnAttentePourEleve(eleve);
      return;
    }

    final indexees = <MapEntry<int, Map<String, dynamic>>>[
      for (var i = 0; i < eleve.transactions.length; i++)
        MapEntry(i, eleve.transactions[i]),
    ];
    indexees.sort((a, b) {
      final parDate = (a.value['date'] ?? '')
          .toString()
          .compareTo((b.value['date'] ?? '').toString());
      if (parDate != 0) return parDate;
      return a.key.compareTo(b.key);
    });

    final Map<String, double> nouveauPaid = {};
    int monthIndex = 0;

    for (final transaction in indexees.map((e) => e.value)) {
      final double montant =
          (transaction['amount'] as num?)?.toDouble() ?? 0.0;
      if (montant <= 0) continue;

      final String? moisFixe = transaction['moisDebloque'] == true
          ? transaction['mois']?.toString()
          : null;

      if (moisFixe != null && moisFixe.isNotEmpty) {
        nouveauPaid[moisFixe] = (nouveauPaid[moisFixe] ?? 0) + montant;
        continue;
      }

      while (monthIndex < months.length) {
        final mois = months[monthIndex];
        final requis = getRequiredForMonthForEleve(eleve, mois);
        final dejaAffecte = nouveauPaid[mois] ?? 0;
        if (requis > 0 && dejaAffecte < requis) break;
        monthIndex++;
      }

      if (monthIndex < months.length) {
        final mois = months[monthIndex];
        transaction['mois'] = mois;
        nouveauPaid[mois] = (nouveauPaid[mois] ?? 0) + montant;
      } else if (months.isNotEmpty) {
        final dernierMois = months.last;
        transaction['mois'] = dernierMois;
        transaction['excedent'] = true;
        nouveauPaid[dernierMois] = (nouveauPaid[dernierMois] ?? 0) + montant;
      }
    }

    eleve.paid
      ..clear()
      ..addAll(nouveauPaid);

    _rafraichirRecusEnAttentePourEleve(eleve);
  }

  void _rafraichirRecusEnAttentePourEleve(Eleve eleve) {
    for (var i = 0; i < receiptQueue.length; i++) {
      final r = receiptQueue[i];
      if (r['type'] != 'principal' || r['eleveId'] != eleve.id) continue;

      final data = Map<String, dynamic>.from(r['data'] as Map? ?? {});
      final mois = data['moisPaye']?.toString() ?? '';
      if (mois.isEmpty) continue;

      final double montantRequis = getRequiredForMonthForEleve(eleve, mois);
      final double totalPaye = getStudentTotalPaid(eleve);
      final double totalRequis = getStudentPending(eleve) + totalPaye;
      final double resteBrut = montantRequis - (eleve.paid[mois] ?? 0);
      final double reste = resteBrut < 0 ? 0.0 : resteBrut;

      data['montantRequis']      = montantRequis;
      data['resteAPayerMois']    = reste;
      data['totalDejaPayeAnnee'] = totalPaye;
      data['totalRequis']        = totalRequis;
      data['historiqueTransactions'] = eleve.transactions
          .map((t) => Map<String, dynamic>.from(t))
          .toList();

      receiptQueue[i] = {...r, 'data': data};
    }
  }

  Future<int> recalculerPaiementsPour({
    String? section,
    String? classeNumero,
  }) async {
    int count = 0;
    for (final eleve in currentData.eleves) {
      if (section != null && eleve.section != section) continue;
      if (classeNumero != null &&
          classeNumeroFromFullClasse(eleve.classe) != classeNumero) {
        continue;
      }
      recalculerRepartitionMoisPourEleve(eleve);
      count++;
    }
    await saveData();
    return count;
  }

  Future<int> recalculerPaiementsPourModeConstant({
    String? section,
    String? classeNumero,
    required Map<String, double> anciensRequisParMois,
  }) async {
    int count = 0;
    for (final eleve in currentData.eleves) {
      if (section != null && eleve.section != section) continue;
      if (classeNumero != null &&
          classeNumeroFromFullClasse(eleve.classe) != classeNumero) {
        continue;
      }
      if (eleve.montantMensuelPersonnalise != null) continue;

      bool modifie = false;
      for (final mois in anciensRequisParMois.keys) {
        final double? ancienRequis = anciensRequisParMois[mois];
        if (ancienRequis == null) continue;

        final double nouveauRequis = getRequiredForMonthForEleve(eleve, mois);

        if (nouveauRequis >= ancienRequis) continue;

        final double paidActuel = eleve.paid[mois] ?? 0;
        if (paidActuel > nouveauRequis) {
          eleve.paid[mois] = nouveauRequis;
          modifie = true;
        }
      }

      if (modifie) {
        count++;
        _rafraichirRecusEnAttentePourEleve(eleve);
      }
    }
    await saveData();
    return count;
  }

  Map<String, double> snapshotRequisTousMoisPour(
      String section, String? classeNumero) {
    return {
      for (final m in months) m: getRequiredForMonth(m, section, classeNumero),
    };
  }

  Map<String, dynamic> _computeStudentCounts(List<Eleve> students) {
    final Map<String, int> parSection = {};
    final Map<String, int> parClasse = {};

    for (final e in students) {
      parSection[e.section] = (parSection[e.section] ?? 0) + 1;
      final classeKey = "${e.section} - ${e.classe}";
      parClasse[classeKey] = (parClasse[classeKey] ?? 0) + 1;
    }

    final sectionsTriees = parSection.keys.toList()..sort();
    final classesTriees = parClasse.keys.toList()..sort();

    return {
      'total': students.length,
      'parSection': {
        for (final s in sectionsTriees) s: parSection[s]!,
      },
      'parClasse': {
        for (final c in classesTriees) c: parClasse[c]!,
      },
    };
  }

  List<pw.Widget> _buildStudentCountSection(
      List<Eleve> students, {
        String label = "Élèves concernés par ce rapport",
      }) {
    final counts = _computeStudentCounts(students);
    final int total = counts['total'] as int;
    final Map<String, int> parSection =
    Map<String, int>.from(counts['parSection'] as Map);
    final Map<String, int> parClasse =
    Map<String, int>.from(counts['parClasse'] as Map);

    return [
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
          color: PdfColors.indigo50,
          border: pw.Border.all(color: PdfColors.indigo200, width: 0.8),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              "NOMBRE D'ÉLÈVES — $label",
              style: pw.TextStyle(
                fontSize: 13,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.indigo900,
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              "Total général : $total élève(s)",
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            if (parSection.isNotEmpty) ...[
              pw.SizedBox(height: 8),
              pw.Text(
                "Par section :",
                style: pw.TextStyle(
                    fontSize: 10.5, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 3),
              ...parSection.entries.map(
                    (entry) => pw.Padding(
                  padding: const pw.EdgeInsets.only(left: 8, bottom: 1),
                  child: pw.Text(
                    "• ${entry.key} : ${entry.value} élève(s)",
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ],
            if (parClasse.isNotEmpty) ...[
              pw.SizedBox(height: 8),
              pw.Text(
                "Par classe :",
                style: pw.TextStyle(
                    fontSize: 10.5, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 3),
              ...parClasse.entries.map(
                    (entry) => pw.Padding(
                  padding: const pw.EdgeInsets.only(left: 8, bottom: 1),
                  child: pw.Text(
                    "• ${entry.key} : ${entry.value} élève(s)",
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  List<pw.Widget> _buildRepartitionParOption(
      List<Eleve> students, Map<String, double> totalBySection) {
    if (!aDesOptionsActives) return [];
    if (config.administrations.isEmpty || totalBySection.isEmpty) return [];

    final groupes = _groupesOptions(totalBySection.keys);
    if (!groupes.any((g) => g.estOption)) return [];

    final admins = config.administrations;

    final List<double> totaux = [];
    final List<int> effectifs = [];
    final List<String> taux = [];
    final List<Eleve> tousLesEleves = [];

    for (final g in groupes) {
      final double total = g.sections
          .fold<double>(0.0, (sum, s) => sum + (totalBySection[s] ?? 0));
      final List<Eleve> elevesGroupe = students
          .where((e) =>
      g.sections.contains(e.section) &&
          (totalBySection[e.section] ?? 0) > 0)
          .toList();
      totaux.add(total);
      effectifs.add(elevesGroupe.length);
      taux.add(_tauxMensuelLabel(elevesGroupe));
      tousLesEleves.addAll(elevesGroupe);
    }

    final double totalGeneral = totaux.fold(0.0, (sum, v) => sum + v);
    final int effectifGeneral = effectifs.fold(0, (sum, v) => sum + v);
    final String tauxGeneral = _tauxMensuelLabel(tousLesEleves);

    final headers = <String>[
      'Rubrique',
      ...groupes.map((g) => g.estOption
          ? '${g.nom}\n(${g.sections.length} section${g.sections.length > 1 ? 's' : ''})'
          : g.nom),
      'TOTAL',
    ];

    final rows = <List<String>>[
      ['Effectif', ...effectifs.map((e) => '$e'), '$effectifGeneral'],
      ['Taux mensuel (FC)', ...taux, tauxGeneral],
      [
        'Montant collecté (FC)',
        ...totaux.map((t) => formatMontant(t)),
        formatMontant(totalGeneral),
      ],
      for (final a in admins)
        [
          '${a.nom} (${_pctLabel(a.pourcentage)}%)',
          ...totaux.map((t) => formatMontant(t * a.pourcentage / 100)),
          formatMontant(totalGeneral * a.pourcentage / 100),
        ],
    ];

    final double cellFontSize = _tableCellFontSize(headers.length);
    final double headerFontSize = _tableHeaderFontSize(headers.length);

    final optionsAffichees = groupes.where((g) => g.estOption).toList();

    return [
      pw.Text(
        "RÉPARTITION PAR OPTION ET PAR ADMINISTRATION",
        style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 4),
      pw.Text(
        "Regroupement des sections en options : chaque colonne réunit "
            "toutes les sections de l'option. Les sections qui ne sont dans "
            "aucune option figurent chacune dans leur propre colonne.",
        style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
      ),
      pw.SizedBox(height: 10),
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: rows,
        columnWidths: _buildColumnWidths([
          2.0,
          ...List<double>.filled(groupes.length, 1.4),
          1.5,
        ]),
        headerStyle: pw.TextStyle(
          fontSize: headerFontSize,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.indigo800),
        headerAlignment: pw.Alignment.center,
        cellStyle: pw.TextStyle(fontSize: cellFontSize),
        cellAlignment: pw.Alignment.center,
        cellAlignments: {
          0: pw.Alignment.centerLeft,
        },
        cellPadding:
        const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        oddRowDecoration: const pw.BoxDecoration(color: PdfColors.indigo50),
      ),
      pw.SizedBox(height: 6),
      ...optionsAffichees.map(
            (g) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 1),
          child: pw.Text(
            "• ${g.nom} = ${g.sections.join(', ')}",
            style: pw.TextStyle(
              fontSize: 9,
              fontStyle: pw.FontStyle.italic,
              color: PdfColors.grey800,
            ),
          ),
        ),
      ),
      pw.SizedBox(height: 16),
    ];
  }

  List<pw.Widget> _buildRepartitionParSectionEtAdministration(
      List<Eleve> students, String period) {
    if (config.administrations.isEmpty || students.isEmpty) return [];

    final Map<String, double> totalBySection = {};
    for (final e in students) {
      totalBySection[e.section] =
          (totalBySection[e.section] ?? 0) + _getStudentAmountForPeriod(e, period);
    }
    totalBySection.removeWhere((_, v) => v <= 0);
    if (totalBySection.isEmpty) return [];

    final List<String> sectionsOrdonnees = [
      ...config.sections.where((s) => totalBySection.containsKey(s)),
      ...(totalBySection.keys
          .where((s) => !config.sections.contains(s))
          .toList()
        ..sort()),
    ];

    final headers = [
      'Section',
      'Effectif',
      'Montant Total (FC)',
      ...config.administrations
          .map((a) => '${a.nom}\n(${a.pourcentage.toStringAsFixed(0)}%)'),
    ];

    final Map<String, int> effectifParSection = {};
    for (final e in students) {
      if ((totalBySection[e.section] ?? 0) <= 0) continue;
      effectifParSection[e.section] =
          (effectifParSection[e.section] ?? 0) + 1;
    }

    final rows = <List<String>>[];
    for (final section in sectionsOrdonnees) {
      final double total = totalBySection[section] ?? 0;
      final dist = calculateAdminDistribution(total);
      rows.add([
        section,
        '${effectifParSection[section] ?? 0}',
        total.toStringAsFixed(0),
        ...config.administrations
            .map((a) => (dist[a.nom] ?? 0).toStringAsFixed(0)),
      ]);
    }

    final double totalGeneral =
    totalBySection.values.fold(0.0, (sum, v) => sum + v);
    final int effectifGeneral =
    effectifParSection.values.fold(0, (sum, v) => sum + v);
    final distGenerale = calculateAdminDistribution(totalGeneral);

    final columnWidths = _buildColumnWidths([
      1.7,
      0.9,
      1.5,
      ...List<double>.filled(config.administrations.length, 1.3),
    ]);
    final double cellFontSize = _tableCellFontSize(headers.length);
    final double headerFontSize = _tableHeaderFontSize(headers.length);

    return [
      pw.Text(
        "RÉPARTITION PAR SECTION ET PAR ADMINISTRATION",
        style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 4),
      pw.Text(
        "Détail du montant collecté et de sa répartition entre "
            "administrations, section par section. Le total général "
            "toutes sections et classes confondues figure dans le "
            "tableau récapitulatif juste en dessous.",
        style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
      ),
      pw.SizedBox(height: 10),
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: rows,
        columnWidths: columnWidths,
        headerStyle: pw.TextStyle(
          fontSize: headerFontSize,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.indigo),
        headerAlignment: pw.Alignment.center,
        cellStyle: pw.TextStyle(fontSize: cellFontSize),
        cellAlignment: pw.Alignment.centerRight,
        cellAlignments: {
          0: pw.Alignment.centerLeft,
          1: pw.Alignment.center,
        },
        cellPadding:
        const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        oddRowDecoration: const pw.BoxDecoration(color: PdfColors.indigo50),
      ),
      pw.SizedBox(height: 16),

      ..._buildRepartitionParOption(students, totalBySection),

      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: PdfColors.indigo50,
          border: pw.Border.all(color: PdfColors.indigo400, width: 1),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              "TOTAL GÉNÉRAL — TOUTES SECTIONS ET CLASSES CONFONDUES "
                  "($effectifGeneral élève(s))",
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.indigo900,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.TableHelper.fromTextArray(
              headers: [
                'Montant Total (FC)',
                ...config.administrations.map((a) =>
                '${a.nom}\n(${a.pourcentage.toStringAsFixed(0)}%)'),
              ],
              data: [
                [
                  totalGeneral.toStringAsFixed(0),
                  ...config.administrations.map(
                          (a) => (distGenerale[a.nom] ?? 0).toStringAsFixed(0)),
                ],
              ],
              columnWidths: _buildColumnWidths([
                1.5,
                ...List<double>.filled(config.administrations.length, 1.3),
              ]),
              headerStyle: pw.TextStyle(
                fontSize: headerFontSize,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration:
              const pw.BoxDecoration(color: PdfColors.indigo900),
              headerAlignment: pw.Alignment.center,
              cellStyle: pw.TextStyle(
                fontSize: cellFontSize + 0.5,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.indigo900,
              ),
              cellAlignment: pw.Alignment.center,
              cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 24),
    ];
  }

  String _periodeTitrePdf(String period) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    switch (period) {
      case 'today':
        return "DÉPENSES JOURNALIÈRES — ${two(now.day)}/${two(now.month)}/${now.year}";
      case 'month':
        return "DÉPENSES MENSUELLES — ${_moisCalendrier[now.month - 1]} ${now.year}";
      case 'year':
      default:
        return "DÉPENSES ANNUELLES — Année scolaire $currentYear";
    }
  }

  String _periodeCourtePdf(String period) {
    switch (period) {
      case 'today':
        return "du jour";
      case 'month':
        return "du mois";
      case 'year':
      default:
        return "de l'année";
    }
  }

  pw.Widget _pdfLigneMontant(String label, double value, PdfColor color,
      {bool gras = false, double fontSize = 10.5}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(
              fontSize: fontSize,
              color: color,
              fontWeight: gras ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
          pw.Text(
            '${formatMontant(value)} FC',
            style: pw.TextStyle(
              fontSize: fontSize,
              color: color,
              fontWeight: gras ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  pw.TextStyle _pdfHeaderDepenseStyle() => pw.TextStyle(
    fontSize: 8.5,
    fontWeight: pw.FontWeight.bold,
    color: PdfColors.white,
  );

  List<pw.Widget> _buildDepensesParOptionTable(DepensePeriodeStats s) {
    if (!aDesOptionsActives) return [];
    final actives = s.sections.where((x) => x.aDeLActivite).toList();
    if (actives.isEmpty) return [];

    final groupes = _groupesOptions(actives.map((x) => x.section));
    if (!groupes.any((g) => g.estOption)) return [];

    final parNom = <String, SectionStat>{
      for (final x in actives) x.section: x,
    };

    final rows = <List<String>>[];
    double totColl = 0;
    double totInd = 0;
    double totMix = 0;

    for (final g in groupes) {
      double coll = 0;
      double ind = 0;
      double mix = 0;
      for (final sec in g.sections) {
        final st = parNom[sec];
        if (st == null) continue;
        coll += st.collecte;
        ind += st.independantes;
        mix += st.mixtes;
      }
      totColl += coll;
      totInd += ind;
      totMix += mix;
      rows.add([
        g.estOption ? '${g.nom} (option)' : g.nom,
        g.estOption ? g.sections.join(', ') : '-',
        formatMontant(coll),
        formatMontant(ind),
        formatMontant(mix),
        formatMontant(ind + mix),
        formatMontant(coll - (ind + mix)),
      ]);
    }

    rows.add([
      'TOTAL',
      '',
      formatMontant(totColl),
      formatMontant(totInd),
      formatMontant(totMix),
      formatMontant(totInd + totMix),
      formatMontant(totColl - (totInd + totMix)),
    ]);

    return [
      pw.SizedBox(height: 10),
      pw.Text(
        "2 bis. Par option (regroupement de sections) — "
            "${_periodeCourtePdf(s.period).toUpperCase()}",
        style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 4),
      pw.TableHelper.fromTextArray(
        headers: const [
          'Option / Section',
          'Sections incluses',
          'Collecté (FC)',
          'Dép. indépendantes',
          'Dép. mixtes (part)',
          'Total dépensé',
          'Reste (FC)',
        ],
        data: rows,
        columnWidths: _buildColumnWidths([1.8, 2.4, 1.3, 1.4, 1.4, 1.3, 1.3]),
        headerStyle: _pdfHeaderDepenseStyle(),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.red700),
        headerAlignment: pw.Alignment.center,
        cellStyle: const pw.TextStyle(fontSize: 8.5),
        cellAlignment: pw.Alignment.centerRight,
        cellAlignments: {
          0: pw.Alignment.centerLeft,
          1: pw.Alignment.centerLeft,
        },
        cellPadding:
        const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        oddRowDecoration: const pw.BoxDecoration(color: PdfColors.red50),
      ),
      pw.SizedBox(height: 3),
      pw.Text(
        "Les dépenses globales de l'école ne sont rattachées à aucune option.",
        style: pw.TextStyle(
            fontSize: 8.5,
            fontStyle: pw.FontStyle.italic,
            color: PdfColors.grey700),
      ),
    ];
  }

  List<pw.Widget> _buildDepensesPeriodeSection(
      DepensePeriodeStats s, {
        String? sectionFilter,
      }) {
    final widgets = <pw.Widget>[];
    final String periodeCourte = _periodeCourtePdf(s.period);

    widgets.add(
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: const pw.BoxDecoration(
          color: PdfColors.red700,
          borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
        ),
        child: pw.Text(
          _periodeTitrePdf(s.period) +
              (sectionFilter != null ? "  |  Section : $sectionFilter" : ""),
          style: pw.TextStyle(
            fontSize: 12.5,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.white,
          ),
        ),
      ),
    );
    widgets.add(pw.SizedBox(height: 8));

    widgets.add(
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: PdfColors.red50,
          border: pw.Border.all(color: PdfColors.red200, width: 0.8),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
        ),
        child: pw.Column(
          children: [
            _pdfLigneMontant("Total collecté $periodeCourte",
                s.totalCollecte, PdfColors.green800, gras: true),
            pw.Divider(thickness: 0.4, color: PdfColors.red200),
            if (!s.globalesExclues)
              _pdfLigneMontant("Dépenses globales (toute l'école)",
                  s.globales, PdfColors.grey900),
            _pdfLigneMontant("Dépenses indépendantes (une section)",
                s.independantes, PdfColors.grey900),
            _pdfLigneMontant("Dépenses mixtes (plusieurs sections)",
                s.mixtes, PdfColors.grey900),
            pw.Divider(thickness: 0.4, color: PdfColors.red200),
            _pdfLigneMontant("TOTAL DES DÉPENSES $periodeCourte".toUpperCase(),
                s.totalDepenses, PdfColors.red800, gras: true),
            _pdfLigneMontant(
              "RESTE APRÈS DÉPENSES",
              s.reste,
              s.reste >= 0 ? PdfColors.indigo900 : PdfColors.red800,
              gras: true,
              fontSize: 12,
            ),
          ],
        ),
      ),
    );
    widgets.add(pw.SizedBox(height: 12));

    widgets.add(pw.Text(
      "1. Par rubrique (administration) — ${periodeCourte.toUpperCase()}",
      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
    ));
    widgets.add(pw.SizedBox(height: 4));
    if (s.rubriques.isEmpty) {
      widgets.add(pw.Text(
        "Aucune rubrique (administration) configurée.",
        style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
      ));
    } else {
      final rowsRub = s.rubriques
          .map((r) => [
        r.rubrique,
        r.pourcentage > 0
            ? '${r.pourcentage.toStringAsFixed(0)}%'
            : '-',
        formatMontant(r.collecte),
        formatMontant(r.globales),
        formatMontant(r.independantes),
        formatMontant(r.mixtes),
        formatMontant(r.total),
        formatMontant(r.reste),
      ])
          .toList();
      widgets.add(
        pw.TableHelper.fromTextArray(
          headers: const [
            'Rubrique',
            'Taux',
            'Collecté (FC)',
            'Dép. globales',
            'Dép. indépendantes',
            'Dép. mixtes',
            'Total dépensé',
            'Reste (FC)',
          ],
          data: rowsRub,
          columnWidths: _buildColumnWidths([2.0, 0.7, 1.3, 1.2, 1.4, 1.2, 1.3, 1.3]),
          headerStyle: _pdfHeaderDepenseStyle(),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.red700),
          headerAlignment: pw.Alignment.center,
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          cellAlignment: pw.Alignment.centerRight,
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.center,
          },
          cellPadding:
          const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          oddRowDecoration: const pw.BoxDecoration(color: PdfColors.red50),
        ),
      );
      final double totColl =
      s.rubriques.fold(0.0, (a, r) => a + r.collecte);
      final double totDep = s.rubriques.fold(0.0, (a, r) => a + r.total);
      widgets.add(pw.SizedBox(height: 3));
      widgets.add(pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          "TOTAL : collecté ${formatMontant(totColl)} FC  |  "
              "dépensé ${formatMontant(totDep)} FC  |  "
              "reste ${formatMontant(totColl - totDep)} FC",
          style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
        ),
      ));
    }
    widgets.add(pw.SizedBox(height: 12));

    widgets.add(pw.Text(
      "2. Par section — ${periodeCourte.toUpperCase()}",
      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
    ));
    widgets.add(pw.SizedBox(height: 4));
    final sectionsActives = s.sections.where((x) => x.aDeLActivite).toList();
    if (sectionsActives.isEmpty) {
      widgets.add(pw.Text(
        "Aucune activité (collecte ou dépense) par section sur cette période.",
        style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
      ));
    } else {
      final rowsSec = sectionsActives
          .map((x) => [
        x.section,
        formatMontant(x.collecte),
        formatMontant(x.independantes),
        formatMontant(x.mixtes),
        formatMontant(x.total),
        formatMontant(x.reste),
      ])
          .toList();
      widgets.add(
        pw.TableHelper.fromTextArray(
          headers: const [
            'Section',
            'Collecté (FC)',
            'Dép. indépendantes',
            'Dép. mixtes (part)',
            'Total dépensé',
            'Reste (FC)',
          ],
          data: rowsSec,
          columnWidths: _buildColumnWidths([2.2, 1.4, 1.5, 1.4, 1.4, 1.4]),
          headerStyle: _pdfHeaderDepenseStyle(),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.red700),
          headerAlignment: pw.Alignment.center,
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          cellAlignment: pw.Alignment.centerRight,
          cellAlignments: {0: pw.Alignment.centerLeft},
          cellPadding:
          const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          oddRowDecoration: const pw.BoxDecoration(color: PdfColors.red50),
        ),
      );
    }
    if (!s.globalesExclues) {
      widgets.add(pw.SizedBox(height: 3));
      widgets.add(pw.Text(
        "Dépenses globales de l'école (non rattachées à une section) : "
            "${formatMontant(s.globales)} FC.",
        style: pw.TextStyle(
            fontSize: 9,
            fontStyle: pw.FontStyle.italic,
            color: PdfColors.grey800),
      ));
    }

    widgets.addAll(_buildDepensesParOptionTable(s));
    widgets.add(pw.SizedBox(height: 12));

    widgets.add(pw.Text(
      "3. Détail des dépenses (journal de caisse) — ${periodeCourte.toUpperCase()}",
      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
    ));
    widgets.add(pw.SizedBox(height: 4));
    if (s.depenses.isEmpty) {
      widgets.add(pw.Text(
        "Aucune dépense enregistrée sur cette période.",
        style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
      ));
    } else {
      final rowsDet = <List<String>>[];
      double totalListe = 0;
      for (var i = 0; i < s.depenses.length; i++) {
        final d = s.depenses[i];
        totalListe += d.montant;
        rowsDet.add([
          '${i + 1}',
          d.dateFormatee,
          d.porteeLabel,
          d.sectionsLabel,
          d.classesLabel,
          d.rubriqueAffichee,
          d.motif,
          formatMontant(d.montant),
          d.enregistrePar,
        ]);
      }
      widgets.add(
        pw.TableHelper.fromTextArray(
          headers: const [
            'N°',
            'Date et heure',
            'Type',
            'Section(s)',
            'Classe(s)',
            'Rubrique',
            'Motif / Explication',
            'Montant (FC)',
            'Enregistré par',
          ],
          data: rowsDet,
          columnWidths: _buildColumnWidths(
              [0.4, 1.5, 1.0, 1.4, 1.3, 1.3, 2.6, 1.1, 1.0]),
          headerStyle: _pdfHeaderDepenseStyle(),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.red700),
          headerAlignment: pw.Alignment.center,
          cellStyle: const pw.TextStyle(fontSize: 8),
          cellAlignment: pw.Alignment.centerLeft,
          cellAlignments: {
            0: pw.Alignment.center,
            7: pw.Alignment.centerRight,
          },
          cellPadding:
          const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 4),
          oddRowDecoration: const pw.BoxDecoration(color: PdfColors.red50),
        ),
      );
      widgets.add(pw.SizedBox(height: 3));
      widgets.add(pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          "TOTAL DES DÉPENSES LISTÉES : ${formatMontant(totalListe)} FC",
          style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold),
        ),
      ));
      if (s.globalesExclues) {
        widgets.add(pw.SizedBox(height: 2));
        widgets.add(pw.Text(
          "Note : les dépenses globales apparaissent dans cette liste mais "
              "ne sont pas déduites des montants de la section ci-dessus.",
          style: pw.TextStyle(
              fontSize: 8.5,
              fontStyle: pw.FontStyle.italic,
              color: PdfColors.grey700),
        ));
      }
    }

    widgets.add(pw.SizedBox(height: 10));
    widgets.add(
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: pw.BoxDecoration(
          color: s.reste >= 0 ? PdfColors.green50 : PdfColors.red100,
          border: pw.Border.all(
            color: s.reste >= 0 ? PdfColors.green700 : PdfColors.red700,
            width: 1,
          ),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              "RESTE EN CAISSE APRÈS DÉPENSES $periodeCourte".toUpperCase(),
              style: pw.TextStyle(
                  fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              '${formatMontant(s.reste)} FC',
              style: pw.TextStyle(
                fontSize: 13,
                fontWeight: pw.FontWeight.bold,
                color: s.reste >= 0 ? PdfColors.green800 : PdfColors.red800,
              ),
            ),
          ],
        ),
      ),
    );
    widgets.add(pw.SizedBox(height: 22));
    return widgets;
  }

  List<pw.Widget> _buildDepensesReportSections({
    String? sectionFilter,
    String? classFilter,
  }) {
    final widgets = <pw.Widget>[
      pw.NewPage(),
      pw.Center(
        child: pw.Text(
          "RAPPORT DES DÉPENSES",
          style: pw.TextStyle(
            fontSize: 17,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.red800,
          ),
        ),
      ),
      pw.SizedBox(height: 4),
      pw.Center(
        child: pw.Text(
          "${config.schoolName.toUpperCase()} — Année scolaire $currentYear",
          style: const pw.TextStyle(fontSize: 10.5, color: PdfColors.grey700),
        ),
      ),
      pw.SizedBox(height: 8),
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(9),
        decoration: pw.BoxDecoration(
          color: PdfColors.grey100,
          border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              "Comment lire ce rapport",
              style: pw.TextStyle(
                  fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              "• Dépense GLOBALE : elle concerne toute l'école (ex. : électricité, "
                  "frais administratifs généraux).",
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.Text(
              "• Dépense INDÉPENDANTE : elle concerne UNE seule section "
                  "(ex. : achat de craies pour la Maternelle).",
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.Text(
              "• Dépense MIXTE : elle concerne DEUX sections ou plus ; le montant "
                  "est réparti à parts égales entre les sections concernées.",
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.Text(
              "• Chaque dépense est imputée à une RUBRIQUE (salaire des "
                  "enseignants, construction, etc.) : le « Reste » est ce qui "
                  "demeure dans la rubrique après la sortie d'argent.",
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.Text(
              "• Chaque dépense apparaît dans le rapport correspondant à SA "
                  "PROPRE DATE (celle indiquée à l'enregistrement, ou "
                  "corrigée ensuite dans l'historique), et non à la date à "
                  "laquelle elle a été saisie dans l'application.",
              style: const pw.TextStyle(fontSize: 9),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 14),
    ];

    for (final period in const ['today', 'month', 'year']) {
      final stats = computeDepensesStats(
        period,
        sectionFilter: sectionFilter,
        classFilter: classFilter,
      );
      widgets.addAll(_buildDepensesPeriodeSection(
        stats,
        sectionFilter: sectionFilter,
      ));
    }
    return widgets;
  }

  List<pw.Widget> _buildCenteredReportHeader({
    required String title,
    String? subtitle,
  }) {
    return [
      pw.Center(
        child: pw.Text(
          config.schoolName.toUpperCase(),
          style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
        ),
      ),
      pw.SizedBox(height: 4),
      pw.Center(
        child: pw.Text(
          title,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
        ),
      ),
      if (subtitle != null && subtitle.trim().isNotEmpty) ...[
        pw.SizedBox(height: 4),
        pw.Center(
          child: pw.Text(
            subtitle,
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 11),
          ),
        ),
      ],
      pw.SizedBox(height: 2),
      pw.Center(
        child: pw.Text(
          'Généré le : $_dateGenerationFormatee',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
        ),
      ),
      pw.SizedBox(height: 16),
      pw.Divider(thickness: 1),
      pw.SizedBox(height: 10),
    ];
  }

  pw.Widget _pdfDetailRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 120,
            child: pw.Text(
              "$label :",
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 11,
                color: PdfColors.grey700,
              ),
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              value,
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _pdfTotalRow(String label, double amount, PdfColor color) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: color,
            ),
          ),
          pw.Text(
            '${amount.toStringAsFixed(0)} FC',
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _pdfMonthRow(String mois, double paye, double requis) {
    final double reste = requis - paye;
    final bool nonCommence = paye == 0 && reste == requis;
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        children: [
          pw.Expanded(
            flex: 3,
            child: pw.Text(
              mois,
              style: pw.TextStyle(
                fontSize: 10.5,
                color: nonCommence ? PdfColors.grey600 : PdfColors.black,
                fontWeight:
                nonCommence ? pw.FontWeight.normal : pw.FontWeight.bold,
              ),
            ),
          ),
          pw.Expanded(
            flex: 3,
            child: pw.Text(
              '${paye.toStringAsFixed(0)} / ${requis.toStringAsFixed(0)} FC',
              style: pw.TextStyle(
                fontSize: 10.5,
                color: nonCommence ? PdfColors.grey600 : PdfColors.black,
              ),
            ),
          ),
          pw.Expanded(
            flex: 2,
            child: pw.Align(
              alignment: pw.Alignment.centerRight,
              child: reste <= 0
                  ? pw.Text(
                'OK',
                style: pw.TextStyle(
                  fontSize: 10,
                  color: PdfColors.green700,
                  fontWeight: pw.FontWeight.bold,
                ),
              )
                  : (nonCommence
                  ? pw.Text(
                '-',
                style: const pw.TextStyle(
                    fontSize: 10, color: PdfColors.grey600),
              )
                  : pw.Text(
                '-${reste.toStringAsFixed(0)} FC',
                style: pw.TextStyle(
                  fontSize: 10,
                  color: PdfColors.orange800,
                  fontWeight: pw.FontWeight.bold,
                ),
              )),
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _pdfTransactionRow(Map<String, dynamic> t) {
    final date = t['date']?.toString() ?? '—';
    final mois = t['mois']?.toString() ?? '—';
    final amount = (t['amount'] as num?)?.toDouble() ?? 0.0;
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        children: [
          pw.Expanded(
            child: pw.Text(
              '$date  —  $mois',
              style: const pw.TextStyle(fontSize: 10.5),
            ),
          ),
          pw.Text(
            '${amount.toStringAsFixed(0)} FC',
            style: pw.TextStyle(
              fontSize: 10.5,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> generateStudentPaymentHistoryPdf({
    required Eleve eleve,
    String? filename,
  }) async {
    final pdf = pw.Document();

    final double totalPaye = getStudentTotalPaid(eleve);
    final double totalRequis = getStudentPending(eleve) + totalPaye;
    final double resteTotal = totalRequis - totalPaye;

    final sortedTransactions =
    List<Map<String, dynamic>>.from(eleve.transactions)
      ..sort((a, b) => (a['date'] ?? '')
          .toString()
          .compareTo((b['date'] ?? '').toString()));

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) => [
          pw.Center(
            child: pw.Text(
              config.schoolName.toUpperCase(),
              textAlign: pw.TextAlign.center,
              style:
              pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18),
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Center(
            child: pw.Text(
              "REÇU DE PAIEMENT",
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 13,
                decoration: pw.TextDecoration.underline,
              ),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              "Année scolaire : $currentYear",
              style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
            ),
          ),
          pw.SizedBox(height: 14),
          pw.Divider(thickness: 1),
          pw.SizedBox(height: 10),

          _pdfDetailRow(
              "Nom complet", "${eleve.nom} ${eleve.postNom} ${eleve.prenom}"),
          _pdfDetailRow("ID", eleve.id.isNotEmpty ? eleve.id : "N/A"),
          _pdfDetailRow("Promotion", eleve.classe),
          _pdfDetailRow("Section", eleve.section),

          pw.SizedBox(height: 10),
          pw.Divider(thickness: 1),
          pw.SizedBox(height: 10),

          pw.Text(
            "BILAN FINANCIER",
            style: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 13,
              color: PdfColors.indigo900,
            ),
          ),
          pw.SizedBox(height: 8),
          ...months.map((mois) {
            final requis = getRequiredForMonthForEleve(eleve, mois);
            final paye = (eleve.paid[mois] ?? 0).toDouble();
            return _pdfMonthRow(mois, paye, requis);
          }),

          pw.SizedBox(height: 10),
          pw.Divider(thickness: 1),
          pw.SizedBox(height: 10),

          _pdfTotalRow("Total payé", totalPaye, PdfColors.green700),
          _pdfTotalRow(
              "Total requis (annuel)", totalRequis, PdfColors.indigo900),
          _pdfTotalRow(
            "Reste à payer",
            resteTotal > 0 ? resteTotal : 0,
            resteTotal > 0 ? PdfColors.red700 : PdfColors.green700,
          ),

          pw.SizedBox(height: 10),
          pw.Divider(thickness: 1),
          pw.SizedBox(height: 10),

          pw.Text(
            "HISTORIQUE DES PAIEMENTS",
            style: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 13,
              color: PdfColors.indigo900,
            ),
          ),
          pw.SizedBox(height: 8),
          if (sortedTransactions.isEmpty)
            pw.Text(
              "Aucune transaction enregistrée.",
              style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
            )
          else
            ...sortedTransactions.map(_pdfTransactionRow),
        ],
      ),
    );

    final String safeFilename = (filename != null && filename.trim().isNotEmpty)
        ? filename.trim()
        : "${eleve.nom}_${eleve.postNom}_${eleve.id}"
        .replaceAll(RegExp(r'\s+'), '_');

    return await _savePdf(pdf, safeFilename, "historique_paiements");
  }

  Future<Map<String, dynamic>> printStudentPaymentHistoryReceipt({
    required Eleve eleve,
    bool duplicata = false,
  }) async {
    final String printerName = await _currentPrinterName();
    if (printerName.isEmpty) {
      return {
        'success': false,
        'error': "Aucune imprimante configurée. Configurez-la dans Paramètres.",
      };
    }

    final Uint8List? logoBytes = await _loadLogoBytesForPrinting();

    final Map<String, double> paidByMonth = {};
    final Map<String, double> requiredByMonth = {};
    for (final mois in months) {
      paidByMonth[mois] = (eleve.paid[mois] ?? 0).toDouble();
      requiredByMonth[mois] = getRequiredForMonthForEleve(eleve, mois);
    }

    final double totalPaye = getStudentTotalPaid(eleve);
    final double totalRequis = getStudentPending(eleve) + totalPaye;

    final List<Map<String, dynamic>> transactions = eleve.transactions
        .map((t) => Map<String, dynamic>.from(t))
        .toList();

    final bool ok = await EscPosPrinterService.printStudentPaymentHistoryReceipt(
      printerName: printerName,
      schoolName: config.schoolName,
      currentYear: currentYear,
      studentName: '${eleve.nom} ${eleve.postNom} ${eleve.prenom}',
      studentId: eleve.id.isNotEmpty ? eleve.id : "N/A",
      classe: eleve.classe,
      section: eleve.section,
      months: months,
      paidByMonth: paidByMonth,
      requiredByMonth: requiredByMonth,
      totalPaye: totalPaye,
      totalRequis: totalRequis,
      transactions: transactions,
      logoBytes: logoBytes,
      duplicata: duplicata,
    );

    if (!ok) {
      return {
        'success': false,
        'error': "Échec de l'impression. Vérifiez l'imprimante.",
      };
    }
    return {'success': true};
  }

  Future<Map<String, dynamic>> generatePdf({
    required String filename,
    required String reportType,
    String? sectionFilter,
    String? classFilter,
    String? city,
    bool includeDepenses = true,
  }) async {
    if (reportType == "student_list") {
      return await _generateStudentListPdf(
        filename:      filename,
        sectionFilter: sectionFilter,
        classFilter:   classFilter,
        city:          city,
      );
    }

    // ==========================================================================
    // ⚡ CORRECTION — Le montant affiché pour chaque élève et le total du
    // rapport doivent correspondre EXACTEMENT à la période du rapport :
    //   - "daily"   -> uniquement ce que l'élève a payé AUJOURD'HUI
    //   - "monthly" -> uniquement ce que l'élève a payé CE MOIS-CI
    //   - "annual"  -> le total payé depuis le début de l'année (inchangé)
    // Avant, on utilisait toujours getStudentTotalPaid() (le cumul depuis
    // le début de l'année), ce qui faisait apparaître, dans un rapport
    // journalier ou mensuel, un montant qui incluait aussi les paiements
    // des jours/mois précédents. On utilise maintenant
    // _getStudentAmountForPeriod(), qui calcule le montant réellement
    // rattaché à la période demandée.
    // ==========================================================================
    final String periodePourMontant = reportType == "daily"
        ? "today"
        : (reportType == "monthly" ? "month" : "year");

    final pdf     = pw.Document();
    List<Eleve> students;
    String title;
    String countLabel;

    if (reportType == "daily") {
      students = getPaidStudentsToday();
      title    = "RAPPORT JOURNALIER";
      countLabel = "ont payé aujourd'hui";
    } else if (reportType == "monthly") {
      students = getPaidStudentsThisMonth();
      title    = "RAPPORT MENSUEL";
      countLabel = "ont payé ce mois-ci";
    } else {
      students = currentData.eleves;
      title    = "RAPPORT ANNUEL";
      countLabel = "figurent dans ce rapport";
    }

    final List<Eleve> studentsAvantFiltres = List<Eleve>.from(students);
    final bool afficherRepartitionParSection =
        sectionFilter == null && classFilter == null;

    if (sectionFilter != null) {
      students = students
          .where((e) => e.section == sectionFilter)
          .toList();
      title += " - $sectionFilter";
    }
    if (classFilter != null) {
      students = students
          .where((e) => e.classe == classFilter)
          .toList();
      title += " - $classFilter";
    }

    final double total              = students.fold(
        0.0, (sum, e) => sum + _getStudentAmountForPeriod(e, periodePourMontant));
    final adminDistribution         = calculateAdminDistribution(total);
    final double totalMoisEcole     = getCurrentMonthTotalCollected();
    final double totalAnneeEcole    = getYearTotalCollected();
    final double totalDepensesAnnee = getTotalDepenses();
    final double soldeNetAnnee      = totalAnneeEcole - totalDepensesAnnee;
    final String currentMonthName =
        currentSchoolMonthName ?? "Hors année scolaire (vacances)";
    final bool showMoisConcerne = reportType == "daily";

    final headers = [
      'ID', 'Nom Complet', 'Section', 'Classe', 'Montant Payé (FC)',
      if (showMoisConcerne) 'Mois Concerné(s)',
      ...config.administrations.map(
              (a) => '${a.nom} (${a.pourcentage.toStringAsFixed(0)}%)'),
    ];

    // ==========================================================================
    // ⚡ NOUVEAU — ORDRE D'AFFICHAGE DE LA LISTE DES ÉLÈVES (rapport
    // journalier, mensuel et annuel) : les élèves sont rangés par SECTION
    // (dans l'ordre des sections de l'école), puis par CLASSE (dans l'ordre
    // des classes de la section), puis par nom alphabétique.
    //
    // IMPORTANT : on trie une COPIE de la liste (studentsTriesPourListe)
    // qui sert UNIQUEMENT à construire les lignes du tableau ci-dessous.
    // La liste "students" n'est jamais modifiée (en rapport annuel elle
    // pointe vers currentData.eleves : on ne la trie donc surtout pas),
    // et aucun total, aucune répartition, aucun comptage n'est touché :
    // seul l'ORDRE des lignes dans la liste imprimée change.
    // ==========================================================================
    final List<Eleve> studentsTriesPourListe = List<Eleve>.from(students);
    int indexSectionPourTri(String section) {
      final i = config.sections.indexOf(section);
      return i < 0 ? (1 << 20) : i;
    }

    int indexClassePourTri(Eleve e) {
      final liste = config.classesBySection[e.section];
      if (liste == null) return 1 << 20;
      final i = liste.indexOf(classeNumeroFromFullClasse(e.classe));
      return i < 0 ? (1 << 20) : i;
    }

    studentsTriesPourListe.sort((a, b) {
      int c = indexSectionPourTri(a.section)
          .compareTo(indexSectionPourTri(b.section));
      if (c != 0) return c;
      c = a.section.toLowerCase().compareTo(b.section.toLowerCase());
      if (c != 0) return c;
      c = indexClassePourTri(a).compareTo(indexClassePourTri(b));
      if (c != 0) return c;
      c = a.classe.toLowerCase().compareTo(b.classe.toLowerCase());
      if (c != 0) return c;
      c = a.nom.toLowerCase().compareTo(b.nom.toLowerCase());
      if (c != 0) return c;
      c = a.postNom.toLowerCase().compareTo(b.postNom.toLowerCase());
      if (c != 0) return c;
      return a.prenom.toLowerCase().compareTo(b.prenom.toLowerCase());
    });

    final rows = studentsTriesPourListe.map((e) {
      final montant = _getStudentAmountForPeriod(e, periodePourMontant);
      final row = [
        e.id.isNotEmpty ? e.id : "N/A",
        "${e.nom} ${e.postNom} ${e.prenom}",
        e.section,
        e.classe,
        montant.toStringAsFixed(0),
      ];
      if (showMoisConcerne) {
        final moisConcernes = getMoisPayesPourDate(e);
        row.add(moisConcernes.isNotEmpty
            ? moisConcernes
            : (currentSchoolMonthName ?? '-'));
      }
      for (var admin in config.administrations) {
        row.add(
            (montant * (admin.pourcentage / 100)).toStringAsFixed(0));
      }
      return row;
    }).toList();
    final List<double> recapMensuel =
    reportType == "annual" ? getMonthlyEvolution() : const [];

    final List<double> mainTableFlex = [
      0.7,
      2.5,
      1.1,
      1.3,
      1.3,
      if (showMoisConcerne) 1.7,
      ...List<double>.filled(config.administrations.length, 1.3),
    ];
    final mainTableColumnWidths = _buildColumnWidths(mainTableFlex);
    final double mainCellFontSize = _tableCellFontSize(headers.length);
    final double mainHeaderFontSize = _tableHeaderFontSize(headers.length);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        build: (pw.Context context) => [
          ..._buildCenteredReportHeader(
            title: title,
            subtitle: 'Année scolaire $currentYear',
          ),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: PdfColors.indigo50,
              border: pw.Border.all(color: PdfColors.indigo200, width: 0.8),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  "Total Collecté (ce rapport) : ${total.toStringAsFixed(0)} FC",
                  style: pw.TextStyle(
                    fontSize: 15,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.indigo900,
                  ),
                ),
                pw.SizedBox(height: 5),
                pw.Text(
                  "Total ce Mois ($currentMonthName) : "
                      "${totalMoisEcole.toStringAsFixed(0)} FC",
                  style: const pw.TextStyle(fontSize: 11),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  "Total cette Année ($currentYear) : "
                      "${totalAnneeEcole.toStringAsFixed(0)} FC",
                  style: const pw.TextStyle(fontSize: 11),
                ),
                if (includeDepenses) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    "Total des dépenses de l'année (toute l'école) : "
                        "${formatMontant(totalDepensesAnnee)} FC",
                    style: const pw.TextStyle(
                        fontSize: 11, color: PdfColors.red800),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    "Solde net de l'année après dépenses : "
                        "${formatMontant(soldeNetAnnee)} FC "
                        "(détail des dépenses en fin de rapport)",
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.indigo900,
                    ),
                  ),
                ],
              ],
            ),
          ),
          pw.SizedBox(height: 16),
          ..._buildStudentCountSection(students, label: countLabel),
          pw.SizedBox(height: 16),
          pw.Text("LISTE DES ÉLÈVES",
              style: pw.TextStyle(
                  fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers:   headers,
            data:      rows,
            columnWidths: mainTableColumnWidths,
            headerStyle: pw.TextStyle(
                fontSize: mainHeaderFontSize,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white),
            headerDecoration:
            const pw.BoxDecoration(color: PdfColors.indigo),
            cellStyle: pw.TextStyle(fontSize: mainCellFontSize),
            cellAlignment: pw.Alignment.centerLeft,
            cellPadding:
            const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            oddRowDecoration:
            const pw.BoxDecoration(color: PdfColors.indigo50),
          ),
          if (reportType == "annual") ...[
            pw.SizedBox(height: 26),
            pw.Text("RÉCAPITULATIF MENSUEL",
                style: pw.TextStyle(
                    fontSize: 15, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            pw.TableHelper.fromTextArray(
              headers: const ['Mois', 'Total Collecté (FC)'],
              data: List<List<String>>.generate(
                months.length,
                    (i) => [
                  months[i],
                  (i < recapMensuel.length ? recapMensuel[i] : 0.0)
                      .toStringAsFixed(0),
                ],
              ),
              columnWidths: _buildColumnWidths([1.4, 1]),
              headerStyle: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration:
              const pw.BoxDecoration(color: PdfColors.indigo),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              cellAlignments: {
                0: pw.Alignment.centerLeft,
                1: pw.Alignment.centerRight,
              },
              oddRowDecoration:
              const pw.BoxDecoration(color: PdfColors.indigo50),
            ),
          ],
          pw.SizedBox(height: 30),
          if (afficherRepartitionParSection)
            ..._buildRepartitionParSectionEtAdministration(
                studentsAvantFiltres, periodePourMontant),
          pw.Text(
            "RÉPARTITION GLOBALE PAR ADMINISTRATION",
            style: pw.TextStyle(
                fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 10),
          ...adminDistribution.entries.map(
                (entry) => pw.Text(
              "${entry.key} : ${entry.value.toStringAsFixed(0)} FC "
                  "(${config.administrations.firstWhere((a) => a.nom == entry.key).pourcentage.toStringAsFixed(0)}%)",
            ),
          ),

          // ==========================================================================
          // ⚡ NOUVEAU — La partie "Dépenses" (journalières, mensuelles et
          // annuelles) n'apparaît dans le PDF que si includeDepenses == true.
          // Si false, on passe directement au bloc des signataires : rien
          // concernant les dépenses n'apparaît nulle part dans le document.
          // ==========================================================================
          if (includeDepenses)
            ..._buildDepensesReportSections(
              sectionFilter: sectionFilter,
              classFilter: classFilter,
            ),

          ..._buildSignatureSection(city),
        ],
      ),
    );

    return await _savePdf(pdf, filename, reportType);
  }

  Future<Map<String, dynamic>> _generateStudentListPdf({
    required String filename,
    String? sectionFilter,
    String? classFilter,
    String? city,
  }) async {
    List<Eleve> students = currentData.eleves;
    if (sectionFilter != null) {
      students =
          students.where((e) => e.section == sectionFilter).toList();
    }
    if (classFilter != null) {
      students =
          students.where((e) => e.classe == classFilter).toList();
    }
    students.sort((a, b) {
      final c = a.classe.compareTo(b.classe);
      if (c != 0) return c;
      return a.nom.compareTo(b.nom);
    });

    final sectionLabel = sectionFilter ?? "Toutes les sections";
    final classeLabel  = classFilter   ?? "Toutes les classes";
    final dateStr      = _dateGenerationFormatee;

    final rows = <List<String>>[];
    for (int i = 0; i < students.length; i++) {
      final e = students[i];
      rows.add(['${i + 1}', e.nom, e.postNom, e.prenom, e.classe]);
    }

    final columnWidths = _buildColumnWidths([0.5, 1.6, 1.6, 1.6, 1.5]);

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        build: (pw.Context context) => [
          pw.Center(
            child: pw.Text(
              config.schoolName.toUpperCase(),
              style: pw.TextStyle(
                  fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              "REGISTRE DES ÉLÈVES — Année $currentYear",
              style: pw.TextStyle(
                  fontSize: 13, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              "Section : $sectionLabel | Classe : $classeLabel",
              style: const pw.TextStyle(fontSize: 11),
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Center(
            child: pw.Text(
              "Imprimé le : $dateStr | Total : ${students.length} élève(s)",
              style: const pw.TextStyle(
                  fontSize: 10, color: PdfColors.grey700),
            ),
          ),
          pw.SizedBox(height: 16),
          pw.Divider(thickness: 1),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: ['N°', 'Nom', 'Post-nom', 'Prénom', 'Classe'],
            data:    rows,
            columnWidths: columnWidths,
            headerStyle: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration:
            const pw.BoxDecoration(color: PdfColors.indigo),
            cellStyle:   const pw.TextStyle(fontSize: 10),
            cellHeight:  22,
            cellPadding:
            const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            cellAlignments: {
              0: pw.Alignment.center,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerLeft,
              3: pw.Alignment.centerLeft,
              4: pw.Alignment.centerLeft,
            },
            oddRowDecoration:
            const pw.BoxDecoration(color: PdfColors.indigo50),
          ),
          ..._buildSignatureSection(city),
        ],
      ),
    );

    return await _savePdf(pdf, filename, "student_list");
  }

  Future<Map<String, dynamic>> generateOrderStatusPdf({
    required String filename,
    required String mois,
    required bool enOrdre,
    String? sectionFilter,
    String? classFilter,
  }) async {
    final students = getStudentsByOrderStatus(
      mois:          mois,
      enOrdre:       enOrdre,
      sectionFilter: sectionFilter,
      classFilter:   classFilter,
    );

    final sectionLabel = sectionFilter ?? "Toutes les sections";
    final classeLabel  = classFilter   ?? "Toutes les classes";
    final dateStr      = _dateGenerationFormatee;
    final statutLabel  =
    enOrdre ? "QUI ONT DÉJÀ PAYÉ" : "QUI N'ONT PAS ENCORE PAYÉ";

    final title = "LISTE DES ÉLÈVES DE $classeLabel - $sectionLabel "
        "DU $dateStr $statutLabel $mois";

    final rows = <List<String>>[];
    for (int i = 0; i < students.length; i++) {
      final e              = students[i];
      final montantPaye    = e.paid[mois] ?? 0;
      final montantRequis  = getRequiredForMonthForEleve(e, mois);
      rows.add([
        '${i + 1}',
        e.nom,
        e.postNom,
        e.prenom,
        e.section,
        e.classe,
        '${montantPaye.toStringAsFixed(0)} / ${montantRequis.toStringAsFixed(0)} FC',
      ]);
    }

    final columnWidths =
    _buildColumnWidths([0.5, 1.4, 1.4, 1.4, 1.1, 1.3, 1.8]);

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        build: (pw.Context context) => [
          pw.Center(
            child: pw.Text(
              config.schoolName.toUpperCase(),
              style: pw.TextStyle(
                  fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              title,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                  fontSize: 13, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              "Section : $sectionLabel | Classe : $classeLabel | Mois : $mois",
              style: const pw.TextStyle(fontSize: 11),
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Center(
            child: pw.Text(
              "Année $currentYear | Imprimé le : $dateStr | "
                  "Total : ${students.length} élève(s)",
              style: const pw.TextStyle(
                  fontSize: 10, color: PdfColors.grey700),
            ),
          ),
          pw.SizedBox(height: 16),
          pw.Divider(thickness: 1),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: [
              'N°', 'Nom', 'Post-nom', 'Prénom', 'Section', 'Classe',
              'Payé / Requis ($mois)',
            ],
            data: rows,
            columnWidths: columnWidths,
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(
              color: enOrdre ? PdfColors.green700 : PdfColors.red700,
            ),
            cellStyle:  const pw.TextStyle(fontSize: 9),
            cellHeight: 22,
            cellPadding:
            const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            cellAlignments: {
              0: pw.Alignment.center,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerLeft,
              3: pw.Alignment.centerLeft,
              4: pw.Alignment.centerLeft,
              5: pw.Alignment.centerLeft,
              6: pw.Alignment.center,
            },
            oddRowDecoration: pw.BoxDecoration(
              color: enOrdre ? PdfColors.green50 : PdfColors.red50,
            ),
          ),
        ],
      ),
    );

    return await _savePdf(
      pdf,
      filename,
      enOrdre ? 'en_ordre_$mois' : 'pas_en_ordre_$mois',
    );
  }

  // ==========================================================================
  // ⚡ MODIFIÉ — RAPPORT "AUTRES FRAIS DE PAIEMENT" AVEC FUSION PAR NOM
  // ET PRISE EN COMPTE DES TRANCHES
  // ==========================================================================
  // Quand un type de frais est choisi (autreFraisGroupeCle, ou à défaut
  // autreFraisId), TOUS les frais portant le même nom (même s'ils ont été
  // ajoutés un par un avec des montants différents selon la section/classe)
  // sont fusionnés EN UN SEUL RAPPORT. Cette fusion se fait uniquement au
  // moment de générer le PDF : aucune donnée enregistrée n'est modifiée, et
  // aucun calcul de caisse, de reçu ou de répartition n'est touché.
  //
  // Organisation du rapport fusionné (pour que le lecteur ne se perde pas) :
  //   1. En-tête + cadre de synthèse (total, nombre de paiements, élèves
  //      concernés / ayant tout payé / paiement partiel / restant à payer)
  //   2. Récapitulatif PAR SECTION
  //   3. Récapitulatif PAR CLASSE (montant unitaire, concernés, soldés,
  //      partiels, restants, total)
  //   4. ⚡ NOUVEAU — Récapitulatif PAR TRANCHE (si des tranches existent) :
  //      pour chaque section/classe, combien d'élèves ont payé chaque
  //      tranche et combien a été collecté
  //   5. Détail des paiements (avec la colonne « Tranche »), rangé par
  //      section puis par classe puis par nom
  //   6. Répartition par administration (inchangée)
  //   7. Signataires (inchangés)
  //
  // Les filtres Section / Classe restent utilisables : ils limitent tous les
  // tableaux ci-dessus à la section/classe choisie. Les sections/classes où
  // ce frais n'a pas été défini n'apparaissent simplement pas.
  //
  // Sans type choisi ("Tous types confondus"), le comportement d'origine est
  // conservé (avec la colonne « Tranche » en plus dans le détail).
  // ==========================================================================
  Future<Map<String, dynamic>> generateAutresFraisPdf({
    required String filename,
    String? autreFraisId,
    String? autreFraisGroupeCle,
    String? sectionFilter,
    String? classFilter,
    String? city,
  }) async {
    // ---- 1. Résolution du groupe (fusion par nom) -------------------------
    String? cleGroupe = autreFraisGroupeCle;
    if (cleGroupe == null && autreFraisId != null) {
      for (final f in autresFrais) {
        if (f.id == autreFraisId) {
          cleGroupe = normaliserNomFrais(f.nom);
          break;
        }
      }
    }

    AutreFraisGroupe? groupe;
    if (cleGroupe != null) {
      for (final g in getAutresFraisGroupes()) {
        if (g.cle == cleGroupe) {
          groupe = g;
          break;
        }
      }
    }

    final Set<String> idsGroupe = {
      if (groupe != null) ...groupe.ids,
      if (autreFraisId != null) autreFraisId,
    };
    final bool modeFusion = cleGroupe != null || autreFraisId != null;

    // ---- 2. Paiements concernés ------------------------------------------
    var paiements = getAutresFraisPaiementsForYear();
    if (modeFusion) {
      final String? cleFinale = cleGroupe;
      paiements = paiements.where((p) {
        if (idsGroupe.contains(p.autreFraisId)) return true;
        if (cleFinale != null &&
            normaliserNomFrais(p.autreFraisNom) == cleFinale) {
          return true;
        }
        return false;
      }).toList();
    }

    final Map<String, Eleve> elevesParId = {};
    for (final e in currentData.eleves) {
      elevesParId.putIfAbsent(e.id, () => e);
    }

    int indexSectionPourTri(String section) {
      final i = config.sections.indexOf(section);
      return i < 0 ? (1 << 20) : i;
    }

    int indexClassePourTri(String section, String classe) {
      final liste = config.classesBySection[section];
      if (liste == null) return 1 << 20;
      final i = liste.indexOf(classeNumeroFromFullClasse(classe));
      return i < 0 ? (1 << 20) : i;
    }

    final List<Map<String, dynamic>> entrees = [];
    double total = 0;
    final Map<String, Eleve> elevesDistincts = {};

    for (final p in paiements) {
      final Eleve? eleve = elevesParId[p.eleveId];
      final section = eleve?.section ?? '';
      final classe  = eleve?.classe  ?? '';
      if (sectionFilter != null && section != sectionFilter) continue;
      if (classFilter != null && classe != classFilter) continue;

      entrees.add({
        'p': p,
        'eleve': eleve,
        'section': section,
        'classe': classe,
      });
      total += p.montant;
      if (eleve != null) {
        elevesDistincts[eleve.id] = eleve;
      }
    }

    final bool aDesTranches =
    entrees.any((en) => (en['p'] as AutreFraisPaiement).trancheId.isNotEmpty);

    // En mode fusion, la liste détaillée est rangée par section, puis par
    // classe, puis par nom. (Seul l'ORDRE des lignes change : aucun total.)
    if (modeFusion) {
      entrees.sort((a, b) {
        final String sa = a['section'] as String;
        final String sb = b['section'] as String;
        final String ca = a['classe'] as String;
        final String cb = b['classe'] as String;
        int c = indexSectionPourTri(sa).compareTo(indexSectionPourTri(sb));
        if (c != 0) return c;
        c = sa.toLowerCase().compareTo(sb.toLowerCase());
        if (c != 0) return c;
        c = indexClassePourTri(sa, ca).compareTo(indexClassePourTri(sb, cb));
        if (c != 0) return c;
        c = ca.toLowerCase().compareTo(cb.toLowerCase());
        if (c != 0) return c;
        final Eleve? ea = a['eleve'] as Eleve?;
        final Eleve? eb = b['eleve'] as Eleve?;
        final String na = ea != null
            ? '${ea.nom} ${ea.postNom} ${ea.prenom}'.toLowerCase()
            : '~';
        final String nb = eb != null
            ? '${eb.nom} ${eb.postNom} ${eb.prenom}'.toLowerCase()
            : '~';
        c = na.compareTo(nb);
        if (c != 0) return c;
        final AutreFraisPaiement pa = a['p'] as AutreFraisPaiement;
        final AutreFraisPaiement pb = b['p'] as AutreFraisPaiement;
        c = pa.trancheNumero.compareTo(pb.trancheNumero);
        if (c != 0) return c;
        return pa.date.compareTo(pb.date);
      });
    }

    final rows = <List<String>>[];
    for (final en in entrees) {
      final AutreFraisPaiement p = en['p'] as AutreFraisPaiement;
      final Eleve? eleve = en['eleve'] as Eleve?;
      final String section = en['section'] as String;
      final String classe = en['classe'] as String;
      rows.add([
        (eleve != null && eleve.id.isNotEmpty) ? eleve.id : 'N/A',
        eleve != null
            ? "${eleve.nom} ${eleve.postNom} ${eleve.prenom}"
            : "Élève introuvable",
        section.isEmpty ? '-' : section,
        classe.isEmpty ? '-' : classe,
        p.autreFraisNom,
        p.trancheLibelle.isEmpty ? '-' : p.trancheLibelle,
        p.montant.toStringAsFixed(0),
        p.dateFormatee,
      ]);
    }

    final adminDistribution = calculateAutresFraisAdminDistribution(total);

    // ---- 3. Récapitulatifs par section / par classe / par tranche ---------
    final List<pw.Widget> recapWidgets = [];
    int totalConcernes = 0;
    int totalSoldes = 0;
    int totalPartiels = 0;

    if (modeFusion) {
      String cleSC(String s, String c) => '$s\u0001$c';

      final Map<String, String> sectionDeCle = {};
      final Map<String, String> classeDeCle = {};
      final Map<String, Set<String>> payeursParCle = {};
      final Map<String, Set<String>> concernesParCle = {};
      final Map<String, Set<String>> soldesParCle = {};
      final Map<String, Set<String>> partielsParCle = {};
      final Map<String, double> totalParCle = {};
      final Map<String, Set<double>> montantsParCle = {};

      void assurerCle(String k, String s, String c) {
        sectionDeCle.putIfAbsent(k, () => s);
        classeDeCle.putIfAbsent(k, () => c);
        payeursParCle.putIfAbsent(k, () => <String>{});
        concernesParCle.putIfAbsent(k, () => <String>{});
        soldesParCle.putIfAbsent(k, () => <String>{});
        partielsParCle.putIfAbsent(k, () => <String>{});
        totalParCle.putIfAbsent(k, () => 0.0);
        montantsParCle.putIfAbsent(k, () => <double>{});
      }

      // Paiements effectifs
      for (final en in entrees) {
        final AutreFraisPaiement p = en['p'] as AutreFraisPaiement;
        final String s0 = en['section'] as String;
        final String c0 = en['classe'] as String;
        final String s = s0.isEmpty ? '-' : s0;
        final String c = c0.isEmpty ? '-' : c0;
        final String k = cleSC(s, c);
        assurerCle(k, s, c);
        payeursParCle[k]!.add(p.eleveId);
        concernesParCle[k]!.add(p.eleveId);
        totalParCle[k] = (totalParCle[k] ?? 0) + p.montant;
        montantsParCle[k]!.add(p.montant);
      }

      // Élèves concernés (même s'ils n'ont pas encore payé) + statut de
      // paiement : soldé (tout payé), partiel (certaines tranches payées),
      // ou pas encore payé.
      final fraisDuGroupe =
      autresFrais.where((f) => idsGroupe.contains(f.id)).toList();
      final Set<String> elevesExamines = {};
      for (final e in currentData.eleves) {
        if (sectionFilter != null && e.section != sectionFilter) continue;
        if (classFilter != null && e.classe != classFilter) continue;
        AutreFrais? fraisApplicable;
        for (final f in fraisDuGroupe) {
          if (autreFraisAppliesToStudent(f, e)) {
            fraisApplicable = f;
            break;
          }
        }
        if (fraisApplicable == null) continue;
        final String k = cleSC(e.section, e.classe);
        assurerCle(k, e.section, e.classe);
        concernesParCle[k]!.add(e.id);
        montantsParCle[k]!
            .add(getMontantAutreFraisPourEleve(fraisApplicable, e));

        elevesExamines.add(e.id);
        final paiementsEleve =
        paiements.where((p) => p.eleveId == e.id).toList();
        if (paiementsEleve.isNotEmpty) {
          final tranches = getTranchesPourEleve(fraisApplicable, e);
          final Set<String> idsPayes =
          paiementsEleve.map((p) => p.trancheId).toSet();
          // ⚡ CORRIGÉ — même règle que hasPaidAutreFrais :
          //   - sans tranche pour l'élève : un paiement suffit (soldé) ;
          //   - avec tranches : TOUTES les tranches doivent être payées.
          // Un ancien paiement unique (sans tranche) ne compte plus comme
          // "tout payé" quand des tranches existent pour cet élève : il est
          // classé en "paiement partiel" tant que les tranches ne sont pas
          // toutes payées.
          final bool solde = tranches.isEmpty ||
              tranches.every((t) => idsPayes.contains(t.id));
          if (solde) {
            soldesParCle[k]!.add(e.id);
          } else {
            partielsParCle[k]!.add(e.id);
          }
        }
      }

      // Payeurs dont l'élève n'a pas pu être évalué ci-dessus (élève
      // introuvable ou frais plus applicable) : comptés comme soldés pour
      // ne pas les perdre du récapitulatif.
      for (final en in entrees) {
        final AutreFraisPaiement p = en['p'] as AutreFraisPaiement;
        if (elevesExamines.contains(p.eleveId)) continue;
        final String s0 = en['section'] as String;
        final String c0 = en['classe'] as String;
        final String k = cleSC(s0.isEmpty ? '-' : s0, c0.isEmpty ? '-' : c0);
        soldesParCle[k]?.add(p.eleveId);
      }

      String montantLabel(Set<double> s) {
        if (s.isEmpty) return '-';
        final l = s.toList()..sort();
        if ((l.last - l.first).abs() < 0.5) return formatMontant(l.first);
        return '${formatMontant(l.first)} - ${formatMontant(l.last)}';
      }

      final List<String> cles = sectionDeCle.keys.toList();
      cles.sort((a, b) {
        final String sa = sectionDeCle[a]!;
        final String sb = sectionDeCle[b]!;
        final String ca = classeDeCle[a]!;
        final String cb = classeDeCle[b]!;
        int c = indexSectionPourTri(sa).compareTo(indexSectionPourTri(sb));
        if (c != 0) return c;
        c = sa.toLowerCase().compareTo(sb.toLowerCase());
        if (c != 0) return c;
        c = indexClassePourTri(sa, ca).compareTo(indexClassePourTri(sb, cb));
        if (c != 0) return c;
        return ca.toLowerCase().compareTo(cb.toLowerCase());
      });

      // --- Tableau par classe ---
      final rowsClasse = <List<String>>[];
      int sumConc = 0;
      int sumSolde = 0;
      int sumPartiel = 0;
      double sumTot = 0;
      for (final k in cles) {
        final int conc = concernesParCle[k]!.length;
        final int sold = soldesParCle[k]!.length;
        final int part = partielsParCle[k]!.length;
        final double tot = totalParCle[k] ?? 0;
        if (conc == 0 && sold == 0 && part == 0) continue;
        final int reste = conc - sold - part < 0 ? 0 : conc - sold - part;
        sumConc += conc;
        sumSolde += sold;
        sumPartiel += part;
        sumTot += tot;
        rowsClasse.add([
          sectionDeCle[k]!,
          classeDeCle[k]!,
          montantLabel(montantsParCle[k]!),
          '$conc',
          '$sold',
          '$part',
          '$reste',
          formatMontant(tot),
        ]);
      }
      totalConcernes = sumConc;
      totalSoldes = sumSolde;
      totalPartiels = sumPartiel;
      final int sumReste =
      sumConc - sumSolde - sumPartiel < 0 ? 0 : sumConc - sumSolde - sumPartiel;
      rowsClasse.add([
        'TOTAL',
        '',
        '',
        '$sumConc',
        '$sumSolde',
        '$sumPartiel',
        '$sumReste',
        formatMontant(sumTot),
      ]);

      // --- Tableau par section ---
      final List<String> sectionsVues = [];
      for (final k in cles) {
        final s = sectionDeCle[k]!;
        if (!sectionsVues.contains(s)) sectionsVues.add(s);
      }
      final rowsSection = <List<String>>[];
      for (final s in sectionsVues) {
        int conc = 0;
        int sold = 0;
        int part = 0;
        double tot = 0;
        final Set<double> montantsSection = {};
        for (final k in cles) {
          if (sectionDeCle[k] != s) continue;
          conc += concernesParCle[k]!.length;
          sold += soldesParCle[k]!.length;
          part += partielsParCle[k]!.length;
          tot += totalParCle[k] ?? 0;
          montantsSection.addAll(montantsParCle[k]!);
        }
        if (conc == 0 && sold == 0 && part == 0) continue;
        final int reste = conc - sold - part < 0 ? 0 : conc - sold - part;
        rowsSection.add([
          s,
          montantLabel(montantsSection),
          '$conc',
          '$sold',
          '$part',
          '$reste',
          formatMontant(tot),
        ]);
      }
      rowsSection.add([
        'TOTAL',
        '',
        '$sumConc',
        '$sumSolde',
        '$sumPartiel',
        '$sumReste',
        formatMontant(sumTot),
      ]);

      recapWidgets.addAll([
        pw.Text(
          "1. RÉCAPITULATIF PAR SECTION",
          style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          "Les montants peuvent différer d'une section à l'autre : ils sont "
              "rassemblés ici sous un seul et même type de frais. "
              "« Ont tout payé » = toutes les tranches payées (ou paiement "
              "unique) ; « Paiement partiel » = au moins un paiement mais "
              "pas toutes les tranches.",
          style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 8),
        pw.TableHelper.fromTextArray(
          headers: const [
            'Section',
            'Montant unitaire (FC)',
            'Élèves concernés',
            'Ont tout payé',
            'Paiement partiel',
            'Pas encore payé',
            'Total collecté (FC)',
          ],
          data: rowsSection,
          columnWidths:
          _buildColumnWidths([2.2, 1.6, 1.2, 1.0, 1.1, 1.3, 1.6]),
          headerStyle: pw.TextStyle(
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.white,
          ),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.indigo800),
          headerAlignment: pw.Alignment.center,
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignment: pw.Alignment.center,
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            6: pw.Alignment.centerRight,
          },
          cellPadding:
          const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          oddRowDecoration: const pw.BoxDecoration(color: PdfColors.indigo50),
        ),
        pw.SizedBox(height: 18),
        pw.Text(
          "2. RÉCAPITULATIF PAR CLASSE",
          style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          "Pour chaque classe : le montant à payer, le nombre d'élèves "
              "concernés, ceux qui ont tout payé, ceux qui n'ont payé qu'une "
              "partie (tranches), ceux qui n'ont pas encore payé, et le "
              "total collecté.",
          style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 8),
        pw.TableHelper.fromTextArray(
          headers: const [
            'Section',
            'Classe',
            'Montant unitaire (FC)',
            'Élèves concernés',
            'Ont tout payé',
            'Paiement partiel',
            'Pas encore payé',
            'Total collecté (FC)',
          ],
          data: rowsClasse,
          columnWidths:
          _buildColumnWidths([1.8, 1.4, 1.6, 1.2, 1.0, 1.1, 1.3, 1.6]),
          headerStyle: pw.TextStyle(
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.white,
          ),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.indigo),
          headerAlignment: pw.Alignment.center,
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignment: pw.Alignment.center,
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerLeft,
            7: pw.Alignment.centerRight,
          },
          cellPadding:
          const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          oddRowDecoration: const pw.BoxDecoration(color: PdfColors.indigo50),
        ),
        pw.SizedBox(height: 24),
      ]);

      // --- Tableau par tranche (uniquement si des paiements de tranches) --
      if (aDesTranches) {
        final Map<String, Map<String, dynamic>> parTranche = {};
        for (final en in entrees) {
          final AutreFraisPaiement p = en['p'] as AutreFraisPaiement;
          if (p.trancheId.isEmpty) continue;
          final String s0 = en['section'] as String;
          final String c0 = en['classe'] as String;
          final String s = s0.isEmpty ? '-' : s0;
          final String c = c0.isEmpty ? '-' : c0;
          final String k = '${cleSC(s, c)}\u0002${p.trancheNumero}\u0002'
              '${p.trancheNom}';
          final d = parTranche.putIfAbsent(k, () => {
            'section': s,
            'classe': c,
            'numero': p.trancheNumero,
            'nom': p.trancheLibelle,
            'montants': <double>{},
            'eleves': <String>{},
            'total': 0.0,
          });
          (d['montants'] as Set<double>).add(p.montant);
          (d['eleves'] as Set<String>).add(p.eleveId);
          d['total'] = (d['total'] as double) + p.montant;
        }

        final listeTr = parTranche.values.toList();
        listeTr.sort((a, b) {
          final String sa = a['section'] as String;
          final String sb = b['section'] as String;
          final String ca = a['classe'] as String;
          final String cb = b['classe'] as String;
          int c = indexSectionPourTri(sa).compareTo(indexSectionPourTri(sb));
          if (c != 0) return c;
          c = sa.toLowerCase().compareTo(sb.toLowerCase());
          if (c != 0) return c;
          c = indexClassePourTri(sa, ca).compareTo(indexClassePourTri(sb, cb));
          if (c != 0) return c;
          c = ca.toLowerCase().compareTo(cb.toLowerCase());
          if (c != 0) return c;
          return (a['numero'] as int).compareTo(b['numero'] as int);
        });

        final rowsTr = <List<String>>[];
        double sumTrTotal = 0;
        int sumTrPaiements = 0;
        for (final d in listeTr) {
          final int nb = (d['eleves'] as Set<String>).length;
          sumTrPaiements += nb;
          sumTrTotal += d['total'] as double;
          rowsTr.add([
            d['section'] as String,
            d['classe'] as String,
            d['nom'] as String,
            montantLabel(d['montants'] as Set<double>),
            '$nb',
            formatMontant(d['total'] as double),
          ]);
        }
        rowsTr.add([
          'TOTAL',
          '',
          '',
          '',
          '$sumTrPaiements',
          formatMontant(sumTrTotal),
        ]);

        recapWidgets.addAll([
          pw.Text(
            "3. RÉCAPITULATIF PAR TRANCHE",
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            "Pour chaque section et classe : combien d'élèves ont payé "
                "chaque tranche, le montant de la tranche et le total "
                "collecté.",
            style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            headers: const [
              'Section',
              'Classe',
              'Tranche',
              'Montant de la tranche (FC)',
              'Élèves ayant payé',
              'Total collecté (FC)',
            ],
            data: rowsTr,
            columnWidths: _buildColumnWidths([1.8, 1.4, 2.2, 1.6, 1.2, 1.6]),
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration:
            const pw.BoxDecoration(color: PdfColors.indigo700),
            headerAlignment: pw.Alignment.center,
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignment: pw.Alignment.center,
            cellAlignments: {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerLeft,
              5: pw.Alignment.centerRight,
            },
            cellPadding:
            const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            oddRowDecoration:
            const pw.BoxDecoration(color: PdfColors.indigo50),
          ),
          pw.SizedBox(height: 24),
        ]);
      }
    }

    // ---- 4. Titre ---------------------------------------------------------
    String title = "RAPPORT — AUTRES FRAIS DE PAIEMENT";
    if (modeFusion) {
      final String nomType = groupe != null
          ? groupe.nom
          : (paiements.isNotEmpty ? paiements.first.autreFraisNom : '');
      if (nomType.isNotEmpty) title += " : $nomType";
    } else {
      title += " (TOUS TYPES CONFONDUS)";
    }
    if (sectionFilter != null) title += " - $sectionFilter";
    if (classFilter != null) title += " - $classFilter";

    final headers = [
      'ID', 'Nom Complet', 'Section', 'Classe', 'Type de Frais', 'Tranche',
      'Montant (FC)', 'Date de Paiement',
    ];

    final columnWidths =
    _buildColumnWidths([0.6, 2.0, 1.0, 1.1, 1.4, 1.5, 1.0, 1.3]);
    final double cellFontSize = _tableCellFontSize(headers.length);
    final double headerFontSize = _tableHeaderFontSize(headers.length);

    final AutreFraisGroupe? grp = groupe;
    final String numeroDetail = aDesTranches ? "4" : "3";

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        build: (pw.Context context) => [
          ..._buildCenteredReportHeader(
            title: title,
            subtitle: 'Année scolaire $currentYear',
          ),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: PdfColors.indigo50,
              border: pw.Border.all(color: PdfColors.indigo200, width: 0.8),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  "Total Collecté (ce rapport) : ${total.toStringAsFixed(0)} FC",
                  style: pw.TextStyle(
                    fontSize: 15,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.indigo900,
                  ),
                ),
                pw.SizedBox(height: 5),
                pw.Text(
                  "Nombre de paiements : ${rows.length}",
                  style: const pw.TextStyle(fontSize: 11),
                ),
                if (modeFusion) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    "Élèves concernés : $totalConcernes  |  "
                        "Ont tout payé : $totalSoldes  |  "
                        "Paiement partiel : $totalPartiels  |  "
                        "Pas encore payé : "
                        "${totalConcernes - totalSoldes - totalPartiels < 0 ? 0 : totalConcernes - totalSoldes - totalPartiels}",
                    style: const pw.TextStyle(fontSize: 11),
                  ),
                ],
                if (grp != null) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    grp.montantMin == grp.montantMax
                        ? "Montant du frais : ${formatMontant(grp.montantMin)} FC"
                        : "Montants du frais selon la section/classe : de "
                        "${formatMontant(grp.montantMin)} FC à "
                        "${formatMontant(grp.montantMax)} FC",
                    style: const pw.TextStyle(fontSize: 11),
                  ),
                ],
                if (grp != null && grp.ids.length > 1) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    "Ce rapport fusionne ${grp.ids.length} configurations "
                        "portant le même nom en un seul type de frais.",
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontStyle: pw.FontStyle.italic,
                      color: PdfColors.grey700,
                    ),
                  ),
                ],
                if (aDesTranches) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    "Ce frais est payé par tranches : chaque paiement "
                        "correspond à une tranche (voir le récapitulatif par "
                        "tranche et la colonne « Tranche »).",
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontStyle: pw.FontStyle.italic,
                      color: PdfColors.grey700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          pw.SizedBox(height: 16),
          ..._buildStudentCountSection(
            elevesDistincts.values.toList(),
            label: "ont payé au moins un frais de ce rapport",
          ),
          pw.SizedBox(height: 16),
          ...recapWidgets,
          pw.Text(
            modeFusion
                ? "$numeroDetail. DÉTAIL DES PAIEMENTS (par section, puis par classe)"
                : "DÉTAIL DES PAIEMENTS",
            style:
            pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 10),
          if (rows.isEmpty)
            pw.Text(
              "Aucun paiement enregistré pour ce filtre.",
              style:
              const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
            )
          else
            pw.TableHelper.fromTextArray(
              headers: headers,
              data: rows,
              columnWidths: columnWidths,
              headerStyle: pw.TextStyle(
                  fontSize: headerFontSize,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white),
              headerDecoration:
              const pw.BoxDecoration(color: PdfColors.indigo),
              cellStyle: pw.TextStyle(fontSize: cellFontSize),
              cellAlignment: pw.Alignment.centerLeft,
              cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              oddRowDecoration:
              const pw.BoxDecoration(color: PdfColors.indigo50),
            ),
          pw.SizedBox(height: 30),
          pw.Text(
            "RÉPARTITION GLOBALE PAR ADMINISTRATION (AUTRES FRAIS)",
            style:
            pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 10),
          if (autresFraisAdministrations.isEmpty)
            pw.Text(
              "Aucune administration configurée pour les Autres Frais.",
              style:
              const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
            )
          else if (total == 0)
            pw.Text(
              "Aucun montant à répartir pour ce filtre.",
              style:
              const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
            )
          else
            ...adminDistribution.entries.map(
                  (entry) => pw.Text(
                "${entry.key} : ${entry.value.toStringAsFixed(0)} FC "
                    "(${autresFraisAdministrations.firstWhere((a) => a.nom == entry.key).pourcentage.toStringAsFixed(0)}%)",
              ),
            ),
          ..._buildSignatureSection(city),
        ],
      ),
    );

    return await _savePdf(pdf, filename, "autres_frais");
  }

  Future<Map<String, dynamic>> _savePdf(
      pw.Document pdf, String filename, String reportType) async {
    try {
      final bytes     = await pdf.save();
      final directory = await getDownloadsDirectory();
      if (directory != null) {
        final fileName =
            '${filename}_${reportType}_${DateTime.now().toString().split(' ')[0]}.pdf';
        final file = File('${directory.path}/$fileName');
        await file.writeAsBytes(bytes);
        await OpenFile.open(file.path);
        return {'success': true, 'path': file.path};
      } else {
        final saveLocation = await getSaveLocation(
          suggestedName: '${filename}_$reportType.pdf',
          acceptedTypeGroups: [
            XTypeGroup(label: 'PDF', extensions: ['pdf'])
          ],
        );
        if (saveLocation != null) {
          final file = File(saveLocation.path);
          await file.writeAsBytes(bytes);
          await OpenFile.open(file.path);
          return {'success': true, 'path': file.path};
        }
        return {'success': false, 'error': 'Enregistrement annulé.'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<void> loadData() async {
    final dir       = await getApplicationDocumentsDirectory();
    _dataFilePath   = '${dir.path}/school_fees_data.json';
    final file      = File(_dataFilePath!);

    if (await file.exists()) {
      try {
        final jsonStr = await file.readAsString();
        final data    = json.decode(jsonStr) as Map<String, dynamic>;

        config       = SchoolConfig.fromJson(data['config'] ?? {});
        currentYear  = data['currentYear'] ?? '2025-2026';
        lastSelectedClassFilter   = data['lastSelectedClassFilter'];
        lastSelectedSectionFilter = data['lastSelectedSectionFilter'];
        lastReportCity = data['lastReportCity'] as String?;
        schoolCode = data['schoolCode'] as String?;
        if (data['adminAuditLog'] != null) {
          adminAuditLog = (data['adminAuditLog'] as List<dynamic>)
              .map((e) => AdminAuditLog.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        if (data['signataires'] != null) {
          signataires = (data['signataires'] as List<dynamic>)
              .map((e) => Signataire.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        if (data['optionsSections'] != null) {
          optionsSections = _parseOptionsSections(data['optionsSections']);
          _nettoyerOptions();
        }

        if (data['history'] != null) {
          history = (data['history'] as Map<String, dynamic>).map(
                (key, value) =>
                MapEntry(key, SchoolYearData.fromJson(value)),
          );
        }
        if (data['depensesByYear'] != null) {
          depensesByYear =
              (data['depensesByYear'] as Map<String, dynamic>).map(
                    (key, value) => MapEntry(
                  key,
                  (value as List<dynamic>)
                      .map((e) => Depense.fromJson(e as Map<String, dynamic>))
                      .toList(),
                ),
              );
        }
        if (data['autresFrais'] != null) {
          autresFrais = (data['autresFrais'] as List<dynamic>)
              .map((e) => AutreFrais.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        if (data['autresFraisPaiementsByYear'] != null) {
          autresFraisPaiementsByYear = (data['autresFraisPaiementsByYear']
          as Map<String, dynamic>)
              .map(
                (key, value) => MapEntry(
              key,
              (value as List<dynamic>)
                  .map((e) => AutreFraisPaiement.fromJson(
                  e as Map<String, dynamic>))
                  .toList(),
            ),
          );
        }
        if (data['autresFraisAdministrations'] != null) {
          autresFraisAdministrations =
              (data['autresFraisAdministrations'] as List<dynamic>)
                  .map((e) => AutreFraisAdministration.fromJson(
                  e as Map<String, dynamic>))
                  .toList();
        }

        if (history.containsKey(currentYear)) {
          currentData = history[currentYear]!;
        } else {
          currentData          = SchoolYearData(eleves: []);
          history[currentYear] = currentData;
        }

        if (data['localIdCounter'] != null) {
          _localIdCounter = data['localIdCounter'] as int;
        } else {
          _localIdCounter = _inferCounterFromExistingIds();
        }
        if (data['localAccessKeys'] != null) {
          localAccessKeys = (data['localAccessKeys'] as List<dynamic>)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
        if (data['localPendingPayments'] != null) {
          localPendingPayments =
              (data['localPendingPayments'] as List<dynamic>)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        }
        if (data['localPendingRegistrations'] != null) {
          localPendingRegistrations =
              (data['localPendingRegistrations'] as List<dynamic>)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        }
        if (data['localPendingAutresFraisPayments'] != null) {
          localPendingAutresFraisPayments =
              (data['localPendingAutresFraisPayments'] as List<dynamic>)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        }
        if (data['localAttendance'] != null) {
          localAttendance =
              (data['localAttendance'] as Map<String, dynamic>).map(
                    (key, value) => MapEntry(
                  key,
                  (value as List<dynamic>).map((e) => e.toString()).toList(),
                ),
              );
        }
        if (data['localCommunicationsLog'] != null) {
          localCommunicationsLog =
              (data['localCommunicationsLog'] as List<dynamic>)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        }
        if (data['printedReceiptKeys'] != null) {
          printedReceiptKeys = (data['printedReceiptKeys'] as List<dynamic>)
              .map((e) => e.toString())
              .toList();
        }
        if (data['receiptQueue'] != null) {
          receiptQueue = (data['receiptQueue'] as List<dynamic>)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
        if (data['elevesSupprimesData'] != null) {
          elevesSupprimesData =
              SchoolYearData.fromJson(data['elevesSupprimesData']);
        }
        if (data['dateSuppressionEleves'] != null) {
          dateSuppressionEleves =
              (data['dateSuppressionEleves'] as Map<String, dynamic>)
                  .map((key, value) => MapEntry(key, value.toString()));
        }
        if (data['motifSuppressionEleves'] != null) {
          motifSuppressionEleves =
              (data['motifSuppressionEleves'] as Map<String, dynamic>)
                  .map((key, value) => MapEntry(key, value.toString()));
        }

        await _assignMissingIds();
      } catch (_) {
        _initDefaultData();
      }
    } else {
      _initDefaultData();
    }
  }

  int _inferCounterFromExistingIds() {
    int maxCounter = 0;
    final regex    = RegExp(r'(\d+)$');
    for (var yearData in history.values) {
      for (var eleve in yearData.eleves) {
        final match = regex.firstMatch(eleve.id);
        if (match != null) {
          final n = int.tryParse(match.group(1) ?? '') ?? 0;
          if (n > maxCounter) maxCounter = n;
        }
      }
    }
    return maxCounter;
  }

  Future<void> _assignMissingIds() async {
    bool changed = false;
    for (var yearData in history.values) {
      for (var eleve in yearData.eleves) {
        if (eleve.id.isEmpty || eleve.id == "N/A") {
          eleve.id = generateLocalStudentId(eleve.nom);
          changed  = true;
        }
      }
    }
    if (changed) await saveData();
  }

  void _initDefaultData() {
    currentData          = SchoolYearData(eleves: []);
    history[currentYear] = currentData;
    _localIdCounter      = 0;
  }

  Future<void> saveData() async {
    if (_dataFilePath == null) {
      final dir     = await getApplicationDocumentsDirectory();
      _dataFilePath = '${dir.path}/school_fees_data.json';
    }
    history[currentYear] = currentData;
    final file = File(_dataFilePath!);
    final data = {
      'config':                  config.toJson(),
      'currentYear':             currentYear,
      'localIdCounter':          _localIdCounter,
      'lastSelectedClassFilter': lastSelectedClassFilter,
      'lastSelectedSectionFilter': lastSelectedSectionFilter,
      'lastReportCity': lastReportCity,
      'schoolCode':              schoolCode,
      'history':                 history.map(
              (key, value) => MapEntry(key, value.toJson())),
      'depensesByYear': depensesByYear.map(
            (key, value) =>
            MapEntry(key, value.map((d) => d.toJson()).toList()),
      ),
      'autresFrais': autresFrais.map((f) => f.toJson()).toList(),
      'autresFraisPaiementsByYear': autresFraisPaiementsByYear.map(
            (key, value) =>
            MapEntry(key, value.map((p) => p.toJson()).toList()),
      ),
      'autresFraisAdministrations':
      autresFraisAdministrations.map((a) => a.toJson()).toList(),
      'adminAuditLog': adminAuditLog.map((a) => a.toJson()).toList(),
      'signataires': signataires.map((s) => s.toJson()).toList(),
      'optionsSections': optionsSections,
      'localAccessKeys': localAccessKeys,
      'localPendingPayments': localPendingPayments,
      'localPendingRegistrations': localPendingRegistrations,
      'localPendingAutresFraisPayments': localPendingAutresFraisPayments,
      'localAttendance': localAttendance,
      'localCommunicationsLog': localCommunicationsLog,
      'printedReceiptKeys': printedReceiptKeys,
      'receiptQueue': receiptQueue,
      'elevesSupprimesData': elevesSupprimesData.toJson(),
      'dateSuppressionEleves': dateSuppressionEleves,
      'motifSuppressionEleves': motifSuppressionEleves,
    };
    await file.writeAsString(json.encode(data));
  }

  Future<void> clearLocalData() async {
    if (_dataFilePath == null) {
      final dir     = await getApplicationDocumentsDirectory();
      _dataFilePath = '${dir.path}/school_fees_data.json';
    }
    final file = File(_dataFilePath!);
    if (await file.exists()) {
      await file.delete();
    }
    config      = SchoolConfig(schoolName: "EduPay School RDC");
    currentData = SchoolYearData(eleves: []);
    currentYear = '2025-2026';
    history     = {};
    _localIdCounter = 0;
    lastSelectedClassFilter   = null;
    lastSelectedSectionFilter = null;
    lastReportCity = null;
    schoolCode  = null;
    depensesByYear = {};
    autresFrais = [];
    autresFraisPaiementsByYear = {};
    autresFraisAdministrations = [];
    adminAuditLog = [];
    signataires = [];
    optionsSections = {};
    localAccessKeys = [];
    localPendingPayments = [];
    localPendingRegistrations = [];
    localPendingAutresFraisPayments = [];
    localAttendance = {};
    localCommunicationsLog = [];
    printedReceiptKeys = [];
    receiptQueue = [];
    elevesSupprimesData = SchoolYearData(eleves: []);
    dateSuppressionEleves = {};
    motifSuppressionEleves = {};
  }

  Future<void> changeYear(String newYear) async {
    if (currentYear == newYear) return;
    history[currentYear] = currentData;
    currentYear = newYear;
    if (history.containsKey(newYear)) {
      currentData = history[newYear]!;
    } else {
      currentData          = SchoolYearData(eleves: []);
      history[newYear]     = currentData;
    }
    await saveData();
  }

  List<Map<String, dynamic>> handlePayment(
      Eleve eleve, String mois, double payment) {
    int    index     = months.indexOf(mois);
    if (index == -1) return [];

    final String today     = DateTime.now().toString().split(' ')[0];
    double       remaining = payment;
    String       currentMonth = mois;
    final List<Map<String, dynamic>> nouvellesTransactions = [];

    String genererIdTransaction() =>
        'TX${DateTime.now().microsecondsSinceEpoch}_${nouvellesTransactions.length}';

    while (remaining > 0 && index < months.length) {
      double required    = getRequiredForMonthForEleve(eleve, currentMonth);
      double alreadyPaid = eleve.paid[currentMonth] ?? 0;
      double needed      = required - alreadyPaid;

      if (needed > 0) {
        double toAdd = remaining > needed ? needed : remaining;
        eleve.paid[currentMonth] = alreadyPaid + toAdd;
        final transaction = <String, dynamic>{
          'id': genererIdTransaction(),
          'date':   today,
          'mois':   currentMonth,
          'amount': toAdd,
        };
        eleve.transactions.add(transaction);
        nouvellesTransactions.add(transaction);
        remaining -= toAdd;
      }

      index++;
      if (index < months.length) currentMonth = months[index];
    }

    if (remaining > 0 && months.isNotEmpty) {
      final dernierMois = months.last;
      final double dejaPayeDernierMois = eleve.paid[dernierMois] ?? 0;
      eleve.paid[dernierMois] = dejaPayeDernierMois + remaining;
      final transaction = <String, dynamic>{
        'id': genererIdTransaction(),
        'date': today,
        'mois': dernierMois,
        'amount': remaining,
        'excedent': true,
      };
      eleve.transactions.add(transaction);
      nouvellesTransactions.add(transaction);
      remaining = 0;
    }

    return nouvellesTransactions;
  }

  List<Map<String, dynamic>> _distribuerSurMoisSuivants(
      Eleve eleve, double montant, {String? moisExclu}) {
    final String today = DateTime.now().toString().split(' ')[0];
    final List<Map<String, dynamic>> nouvellesTransactions = [];

    String genererId() =>
        'TX${DateTime.now().microsecondsSinceEpoch}_${nouvellesTransactions.length}_c';

    double remaining = montant;
    int index = 0;
    while (remaining > 0 && index < months.length) {
      final mois = months[index];
      if (mois == moisExclu) {
        index++;
        continue;
      }
      final double required = getRequiredForMonthForEleve(eleve, mois);
      final double dejaPaye = eleve.paid[mois] ?? 0;
      final double needed = required - dejaPaye;
      if (needed > 0) {
        final double toAdd = remaining >= needed ? needed : remaining;
        eleve.paid[mois] = dejaPaye + toAdd;
        final transaction = <String, dynamic>{
          'id': genererId(),
          'date': today,
          'mois': mois,
          'amount': toAdd,
        };
        eleve.transactions.add(transaction);
        nouvellesTransactions.add(transaction);
        remaining -= toAdd;
      }
      index++;
    }

    if (remaining > 0 && months.isNotEmpty) {
      final dernierMois = months.last;
      if (dernierMois != moisExclu) {
        final double dejaPayeDernierMois = eleve.paid[dernierMois] ?? 0;
        eleve.paid[dernierMois] = dejaPayeDernierMois + remaining;
        final transaction = <String, dynamic>{
          'id': genererId(),
          'date': today,
          'mois': dernierMois,
          'amount': remaining,
          'excedent': true,
        };
        eleve.transactions.add(transaction);
        nouvellesTransactions.add(transaction);
      }
    }

    return nouvellesTransactions;
  }

  List<Map<String, dynamic>> handlePaymentMoisDebloque(
      Eleve eleve, String moisDebloque, double montant) {
    final String today = DateTime.now().toString().split(' ')[0];
    final List<Map<String, dynamic>> nouvellesTransactions = [];

    String genererId() =>
        'TX${DateTime.now().microsecondsSinceEpoch}_${nouvellesTransactions.length}_d';

    final double required = getRequiredForMonthForEleve(eleve, moisDebloque);
    final double dejaPaye = eleve.paid[moisDebloque] ?? 0;
    final double needed = required - dejaPaye;
    double remaining = montant;

    if (needed > 0) {
      final double toAdd = remaining >= needed ? needed : remaining;
      eleve.paid[moisDebloque] = dejaPaye + toAdd;
      final transaction = <String, dynamic>{
        'id': genererId(),
        'date': today,
        'mois': moisDebloque,
        'amount': toAdd,
        'moisDebloque': true,
      };
      eleve.transactions.add(transaction);
      nouvellesTransactions.add(transaction);
      remaining -= toAdd;
    }

    if (remaining > 0) {
      nouvellesTransactions.addAll(
        _distribuerSurMoisSuivants(eleve, remaining, moisExclu: moisDebloque),
      );
    }

    return nouvellesTransactions;
  }

  double getStudentTotalPaid(Eleve eleve) =>
      eleve.paid.values.fold(0.0, (sum, p) => sum + p);

  double getStudentPending(Eleve eleve) {
    return months.fold(
        0.0,
            (sum, m) =>
        sum +
            (getRequiredForMonthForEleve(eleve, m) -
                (eleve.paid[m] ?? 0)));
  }

  Future<Map<String, dynamic>> backupToServer(
      String schoolCodeParam, String password) async {
    final normalizedCode = schoolCodeParam.trim().toUpperCase();
    try {
      schoolCode = normalizedCode;
      await saveData();

      final data = {
        'config':          config.toJson(),
        'currentYear':     currentYear,
        'localIdCounter':  _localIdCounter,
        'lastSelectedClassFilter':   lastSelectedClassFilter,
        'lastSelectedSectionFilter': lastSelectedSectionFilter,
        'history':         history.map(
                (key, value) => MapEntry(key, value.toJson())),
        'depensesByYear': depensesByYear.map(
              (key, value) =>
              MapEntry(key, value.map((d) => d.toJson()).toList()),
        ),
        'autresFrais': autresFrais.map((f) => f.toJson()).toList(),
        'autresFraisPaiementsByYear': autresFraisPaiementsByYear.map(
              (key, value) =>
              MapEntry(key, value.map((p) => p.toJson()).toList()),
        ),
        'autresFraisAdministrations':
        autresFraisAdministrations.map((a) => a.toJson()).toList(),
        'adminAuditLog': adminAuditLog.map((a) => a.toJson()).toList(),
        'signataires': signataires.map((s) => s.toJson()).toList(),
        'optionsSections': optionsSections,
        'printedReceiptKeys': printedReceiptKeys,
        'receiptQueue': receiptQueue,
        'elevesSupprimesData': elevesSupprimesData.toJson(),
        'dateSuppressionEleves': dateSuppressionEleves,
        'motifSuppressionEleves': motifSuppressionEleves,
        'backup_password': password,
      };

      final response = await http
          .post(
        Uri.parse('$serverUrl/backup'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'school_code': normalizedCode, 'data': data}),
      )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final corrections  =
            responseData['corrections'] as Map<String, dynamic>? ?? {};
        if (corrections.isNotEmpty) {
          _applyIdCorrections(corrections);
          await saveData();
        }
        await pushPromoterSummary();
        return {'success': true};
      }
      return {
        'success': false,
        'error':
        'Le serveur a répondu avec le statut ${response.statusCode} : '
            '${response.body}',
      };
    } on SocketException catch (e) {
      return {
        'success': false,
        'error': 'Aucune connexion réseau (vérifiez internet / pare-feu) : $e',
      };
    } on HandshakeException catch (e) {
      return {
        'success': false,
        'error': 'Erreur de certificat TLS/SSL sur cet appareil : $e',
      };
    } catch (e) {
      return {'success': false, 'error': 'Erreur inattendue : $e'};
    }
  }

  Future<Map<String, dynamic>> restoreFromServer(
      String schoolCodeParam, String password) async {
    final normalizedCode = schoolCodeParam.trim().toUpperCase();
    try {
      final response = await http
          .get(Uri.parse('$serverUrl/restore?school_code=$normalizedCode'))
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['backup_password'] != null &&
            data['backup_password'] != password) {
          return {'success': false, 'error': 'Mot de passe incorrect'};
        }
        schoolCode = normalizedCode;
        await mergeRestoredData(data);
        await saveData();
        return {'success': true};
      }
      if (response.statusCode == 404) {
        return {
          'success': false,
          'error':
          'Aucune sauvegarde trouvée pour le code "$normalizedCode". '
              'Vérifiez que ce code est exactement celui utilisé lors '
              'du dernier "Sauvegarder sur le Serveur".',
        };
      }
      return {
        'success': false,
        'error':
        'Le serveur a répondu avec le statut ${response.statusCode} : '
            '${response.body}',
      };
    } on SocketException catch (e) {
      return {
        'success': false,
        'error': 'Aucune connexion réseau (vérifiez internet / pare-feu) : $e',
      };
    } catch (e) {
      return {'success': false, 'error': 'Erreur inattendue : $e'};
    }
  }

  Future<Map<String, dynamic>> checkSchoolCodeExists(
      String schoolCodeParam) async {
    final normalizedCode = schoolCodeParam.trim().toUpperCase();
    try {
      final response = await http
          .get(Uri.parse('$serverUrl/restore?school_code=$normalizedCode'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final name = (data['config']?['schoolName'] ?? '') as String;
        return {'exists': true, 'schoolName': name};
      }
      if (response.statusCode == 404) {
        return {'exists': false, 'error': 'Aucune école trouvée avec ce code.'};
      }
      return {
        'exists': false,
        'error': 'Statut HTTP ${response.statusCode} : ${response.body}',
      };
    } catch (e) {
      return {'exists': false, 'error': 'Erreur réseau : $e'};
    }
  }

  // ==========================================================================
  // ⚡ CORRECTION — FUSION DES TRANSACTIONS SANS DOUBLONS (idempotente)
  // ==========================================================================
  // CAUSE DU BUG « le montant se multiplie à chaque clic sur Récupérer » :
  // l'ancienne version donnait aux transactions SANS 'id' une clé contenant
  // un compteur (legacy:date|mois|montant|compteur++). Chaque transaction
  // avait donc une clé unique et n'était JAMAIS reconnue comme doublon :
  // elle était ré-ajoutée à chaque récupération, puis 'paid' était
  // reconstruit à partir de la liste gonflée.
  //
  // NOUVELLE RÈGLE (cliquer 1 fois ou 20 fois = exactement le même résultat) :
  //   1. Les transactions AVEC id sont dédoublonnées par id.
  //   2. Les transactions SANS id sont dédoublonnées par signature
  //      (date|mois|montant) — une seule par signature.
  //   3. Si le serveur a déjà donné un id stable "LEG_..." à une ancienne
  //      transaction, la version locale sans id de la même signature est
  //      considérée comme la même transaction (donc non ajoutée en double).
  //   4. Si aucune transaction n'existe de part et d'autre, on conserve les
  //      montants 'paid' existants au lieu de les effacer.
  // ==========================================================================
  String _signatureTransaction(Map<String, dynamic> t) {
    final double montant = (t['amount'] as num?)?.toDouble() ?? 0.0;
    return '${t['date'] ?? ''}|${t['mois'] ?? ''}|${montant.toStringAsFixed(2)}';
  }

  List<Map<String, dynamic>> _fusionnerTransactionsSansDoublons(
      List<Map<String, dynamic>> locales,
      List<Map<String, dynamic>> serveur,
      ) {
    final Map<String, Map<String, dynamic>> parId = {};
    final Set<String> signaturesAvecIdLegacy = {};
    final List<Map<String, dynamic>> sansId = [];

    void classer(Map<String, dynamic> t) {
      final String tid = t['id']?.toString().trim() ?? '';
      if (tid.isNotEmpty) {
        // Pour une même id, la version du serveur (ajoutée en second) n'écrase
        // pas la version locale : on garde la première rencontrée.
        if (!parId.containsKey(tid)) {
          parId[tid] = t;
          if (tid.startsWith('LEG_')) {
            signaturesAvecIdLegacy.add(_signatureTransaction(t));
          }
        }
      } else {
        sansId.add(t);
      }
    }

    for (final t in serveur) {
      classer(Map<String, dynamic>.from(t));
    }
    for (final t in locales) {
      classer(Map<String, dynamic>.from(t));
    }

    final List<Map<String, dynamic>> resultat = parId.values.toList();
    final Set<String> signaturesSansIdVues = {};
    for (final t in sansId) {
      final String sig = _signatureTransaction(t);
      if (signaturesAvecIdLegacy.contains(sig)) continue;
      if (signaturesSansIdVues.contains(sig)) continue;
      signaturesSansIdVues.add(sig);
      resultat.add(t);
    }

    resultat.sort((a, b) => (a['date'] ?? '')
        .toString()
        .compareTo((b['date'] ?? '').toString()));
    return resultat;
  }

  Future<void> mergeRestoredData(Map<String, dynamic> serverData) async {
    config = SchoolConfig.fromJson(serverData['config'] ?? {});

    if (serverData['localIdCounter'] != null) {
      final serverCounter = serverData['localIdCounter'] as int;
      if (serverCounter > _localIdCounter) {
        _localIdCounter = serverCounter;
      }
    }

    if (serverData['history'] != null) {
      final serverHistory =
      (serverData['history'] as Map<String, dynamic>).map(
            (key, value) =>
            MapEntry(key, SchoolYearData.fromJson(value)),
      );

      for (var entry in serverHistory.entries) {
        final year           = entry.key;
        final serverYearData = entry.value;

        if (history.containsKey(year)) {
          final localEleves  = history[year]!.eleves;
          final existingByKey = <String, Eleve>{};
          for (var e in localEleves) {
            final key =
                "${e.nom.trim().toLowerCase()}_${e.postNom.trim().toLowerCase()}_${e.prenom.trim().toLowerCase()}";
            existingByKey[key] = e;
          }

          for (var serverEleve in serverYearData.eleves) {
            final key =
                "${serverEleve.nom.trim().toLowerCase()}_${serverEleve.postNom.trim().toLowerCase()}_${serverEleve.prenom.trim().toLowerCase()}";

            if (existingByKey.containsKey(key)) {
              final localEleve = existingByKey[key]!;
              localEleve.id    = serverEleve.id.isNotEmpty
                  ? serverEleve.id
                  : localEleve.id;
              localEleve.classe   = serverEleve.classe;
              localEleve.section  = serverEleve.section;
              localEleve.montantMensuelPersonnalise =
                  serverEleve.montantMensuelPersonnalise ??
                      localEleve.montantMensuelPersonnalise;
              if (serverEleve.exceptionsMoisPersonnalisees.isNotEmpty) {
                serverEleve.exceptionsMoisPersonnalisees.forEach((m, v) {
                  localEleve.exceptionsMoisPersonnalisees.putIfAbsent(
                      m, () => v);
                });
              }
              localEleve.moisDebloque ??= serverEleve.moisDebloque;

              // ⚡ CORRECTION — fusion idempotente (voir explication plus haut)
              final List<Map<String, dynamic>> mergedTransactions =
              _fusionnerTransactionsSansDoublons(
                List<Map<String, dynamic>>.from(localEleve.transactions),
                List<Map<String, dynamic>>.from(serverEleve.transactions),
              );

              if (mergedTransactions.isEmpty) {
                // Aucune transaction nulle part : on ne touche pas aux
                // montants payés existants (on garde le plus élevé par mois
                // entre local et serveur au lieu de tout effacer).
                final Map<String, double> paidConserve =
                Map<String, double>.from(localEleve.paid);
                serverEleve.paid.forEach((mois, montant) {
                  final double actuel = paidConserve[mois] ?? 0.0;
                  if (montant > actuel) paidConserve[mois] = montant;
                });
                localEleve.paid
                  ..clear()
                  ..addAll(paidConserve);
              } else {
                localEleve.transactions
                  ..clear()
                  ..addAll(mergedTransactions);

                final Map<String, double> paidReconstruit = {};
                for (var t in mergedTransactions) {
                  final mois = t['mois']?.toString() ?? '';
                  if (mois.isEmpty) continue;
                  final montant = (t['amount'] as num?)?.toDouble() ?? 0.0;
                  paidReconstruit[mois] =
                      (paidReconstruit[mois] ?? 0) + montant;
                }
                localEleve.paid
                  ..clear()
                  ..addAll(paidReconstruit);
              }
            } else {
              localEleves.add(serverEleve);
            }
          }
        } else {
          history[year] = serverYearData;
        }
      }
    }
    if (serverData['depensesByYear'] != null) {
      final serverDepenses =
      (serverData['depensesByYear'] as Map<String, dynamic>).map(
            (key, value) => MapEntry(
          key,
          (value as List<dynamic>)
              .map((e) => Depense.fromJson(e as Map<String, dynamic>))
              .toList(),
        ),
      );

      for (var entry in serverDepenses.entries) {
        final year       = entry.key;
        final serverList = entry.value;

        if (depensesByYear.containsKey(year)) {
          final existingIds =
          depensesByYear[year]!.map((d) => d.id).toSet();
          for (var d in serverList) {
            if (!existingIds.contains(d.id)) {
              depensesByYear[year]!.add(d);
            }
          }
        } else {
          depensesByYear[year] = serverList;
        }
      }
    }
    if (serverData['autresFrais'] != null) {
      final serverAutresFrais = (serverData['autresFrais'] as List<dynamic>)
          .map((e) => AutreFrais.fromJson(e as Map<String, dynamic>))
          .toList();
      final existingFraisIds = autresFrais.map((f) => f.id).toSet();
      for (var f in serverAutresFrais) {
        if (!existingFraisIds.contains(f.id)) {
          autresFrais.add(f);
        } else {
          // ⚡ NOUVEAU — le frais existe déjà localement : on récupère
          // seulement les tranches du serveur pour les cibles qui n'ont
          // encore aucune tranche en local (aucun doublon, aucun écrasement).
          for (final local in autresFrais) {
            if (local.id != f.id) continue;
            f.tranchesParCle.forEach((cle, liste) {
              if (!local.tranchesParCle.containsKey(cle)) {
                local.tranchesParCle[cle] = liste;
              }
            });
            break;
          }
        }
      }
    }
    if (serverData['autresFraisPaiementsByYear'] != null) {
      final serverPaiements = (serverData['autresFraisPaiementsByYear']
      as Map<String, dynamic>)
          .map(
            (key, value) => MapEntry(
          key,
          (value as List<dynamic>)
              .map((e) =>
              AutreFraisPaiement.fromJson(e as Map<String, dynamic>))
              .toList(),
        ),
      );

      for (var entry in serverPaiements.entries) {
        final year       = entry.key;
        final serverList = entry.value;

        if (autresFraisPaiementsByYear.containsKey(year)) {
          final existingIds =
          autresFraisPaiementsByYear[year]!.map((p) => p.id).toSet();
          for (var p in serverList) {
            if (!existingIds.contains(p.id)) {
              autresFraisPaiementsByYear[year]!.add(p);
            }
          }
        } else {
          autresFraisPaiementsByYear[year] = serverList;
        }
      }
    }
    if (serverData['autresFraisAdministrations'] != null) {
      final serverAutresFraisAdmins =
      (serverData['autresFraisAdministrations'] as List<dynamic>)
          .map((e) =>
          AutreFraisAdministration.fromJson(e as Map<String, dynamic>))
          .toList();
      final existingAdminIds =
      autresFraisAdministrations.map((a) => a.id).toSet();
      for (var a in serverAutresFraisAdmins) {
        if (!existingAdminIds.contains(a.id)) {
          autresFraisAdministrations.add(a);
        }
      }
    }
    if (serverData['adminAuditLog'] != null) {
      final serverAudit = (serverData['adminAuditLog'] as List<dynamic>)
          .map((e) => AdminAuditLog.fromJson(e as Map<String, dynamic>))
          .toList();
      final existingAuditIds = adminAuditLog.map((a) => a.id).toSet();
      for (var a in serverAudit) {
        if (!existingAuditIds.contains(a.id)) {
          adminAuditLog.add(a);
        }
      }
    }
    if (serverData['signataires'] != null) {
      final serverSignataires = (serverData['signataires'] as List<dynamic>)
          .map((e) => Signataire.fromJson(e as Map<String, dynamic>))
          .toList();
      final existingSignataireIds = signataires.map((s) => s.id).toSet();
      for (var s in serverSignataires) {
        if (!existingSignataireIds.contains(s.id)) {
          signataires.add(s);
        }
      }
    }
    if (serverData['optionsSections'] != null) {
      final serverOptions = _parseOptionsSections(serverData['optionsSections']);
      serverOptions.forEach((nom, secs) {
        if (optionsSections.containsKey(nom)) return;
        final dejaUtilisees = optionsSections.values.expand((l) => l).toSet();
        optionsSections[nom] =
            secs.where((s) => !dejaUtilisees.contains(s)).toList();
      });
    }
    _nettoyerOptions();

    if (serverData['printedReceiptKeys'] != null) {
      final serverKeys = (serverData['printedReceiptKeys'] as List<dynamic>)
          .map((e) => e.toString());
      for (var k in serverKeys) {
        if (!printedReceiptKeys.contains(k)) {
          printedReceiptKeys.add(k);
        }
      }
    }
    if (serverData['receiptQueue'] != null) {
      final serverQueue = (serverData['receiptQueue'] as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map));
      for (var item in serverQueue) {
        final key = item['key']?.toString() ?? '';
        if (key.isEmpty || printedReceiptKeys.contains(key)) continue;
        final alreadyQueued = receiptQueue.any((r) => r['key'] == key);
        if (!alreadyQueued) {
          receiptQueue.add(item);
        }
      }
    }
    if (serverData['elevesSupprimesData'] != null) {
      final serverElevesSupprimes =
      SchoolYearData.fromJson(serverData['elevesSupprimesData']);
      final existingSupprimesIds =
      elevesSupprimesData.eleves.map((e) => e.id).toSet();
      for (var e in serverElevesSupprimes.eleves) {
        if (!existingSupprimesIds.contains(e.id)) {
          elevesSupprimesData.eleves.add(e);
        }
      }
    }
    if (serverData['dateSuppressionEleves'] != null) {
      (serverData['dateSuppressionEleves'] as Map<String, dynamic>)
          .forEach((key, value) {
        dateSuppressionEleves.putIfAbsent(key, () => value.toString());
      });
    }
    if (serverData['motifSuppressionEleves'] != null) {
      (serverData['motifSuppressionEleves'] as Map<String, dynamic>)
          .forEach((key, value) {
        motifSuppressionEleves.putIfAbsent(key, () => value.toString());
      });
    }

    currentYear = serverData['currentYear'] ?? currentYear;
    if (history.containsKey(currentYear)) {
      currentData = history[currentYear]!;
    } else {
      currentData          = SchoolYearData(eleves: []);
      history[currentYear] = currentData;
    }

    await _assignMissingIds();
  }

  Future<Map<String, dynamic>> recordAbsences({
    required List<String> absentIds,
    required String classe,
    required String section,
    String? date,
    String? message,
    String recordedBy = 'Direction',
  }) async {
    if (schoolCode == null || schoolCode!.isEmpty) {
      return {
        'success': false,
        'error': "Code école manquant. Sauvegardez d'abord sur le serveur "
            "(Paramètres) avant d'utiliser le module Discipline.",
      };
    }
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/school/record_absences'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'school_code': schoolCode,
          'annee':       currentYear,
          'classe':      classe,
          'section':     section,
          'date':        date ?? DateTime.now().toString().split(' ')[0],
          'absent_ids':  absentIds,
          'message':     message ?? '',
          'recorded_by': recordedBy,
        }),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'notified_count': data['notified_count'] ?? 0,
        };
      }
      return {
        'success': false,
        'error': 'Statut ${response.statusCode} : ${response.body}',
      };
    } on SocketException catch (e) {
      return {'success': false, 'error': 'Aucune connexion réseau : $e'};
    } catch (e) {
      return {'success': false, 'error': 'Erreur inattendue : $e'};
    }
  }

  Future<Map<String, dynamic>> getAttendance({
    required String classe,
    String? date,
  }) async {
    if (schoolCode == null || schoolCode!.isEmpty) {
      return {'success': false, 'absents': <String>[]};
    }
    try {
      final dateStr = date ?? DateTime.now().toString().split(' ')[0];
      final response = await http.get(
        Uri.parse('$serverUrl/school/get_attendance'
            '?school_code=$schoolCode&date=$dateStr'
            '&classe=${Uri.encodeComponent(classe)}'),
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'absents': List<String>.from(data['absents'] ?? []),
        };
      }
      return {'success': false, 'absents': <String>[]};
    } catch (_) {
      return {'success': false, 'absents': <String>[]};
    }
  }

  Future<Map<String, dynamic>> sendConvocation({
    required String studentId,
    required String title,
    required String message,
  }) async {
    if (schoolCode == null || schoolCode!.isEmpty) {
      return {'success': false, 'error': 'Code école manquant.'};
    }
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/school/send_convocation'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'school_code': schoolCode,
          'student_id':  studentId,
          'title':       title,
          'message':     message,
        }),
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return {'success': true};
      return {
        'success': false,
        'error': 'Statut ${response.statusCode} : ${response.body}',
      };
    } on SocketException catch (e) {
      return {'success': false, 'error': 'Aucune connexion réseau : $e'};
    } catch (e) {
      return {'success': false, 'error': 'Erreur inattendue : $e'};
    }
  }

  Future<Map<String, dynamic>> sendAnnouncement({
    required String title,
    required String message,
    required String target,
    String? classe,
    String? section,
    List<String>? studentIds,
  }) async {
    if (schoolCode == null || schoolCode!.isEmpty) {
      return {'success': false, 'error': 'Code école manquant.'};
    }
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/school/send_announcement'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'school_code': schoolCode,
          'annee':       currentYear,
          'title':       title,
          'message':     message,
          'target':      target,
          'classe':      classe ?? '',
          'section':     section ?? '',
          'student_ids': studentIds ?? [],
        }),
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'notified_count': data['notified_count'] ?? 0,
        };
      }
      return {
        'success': false,
        'error': 'Statut ${response.statusCode} : ${response.body}',
      };
    } on SocketException catch (e) {
      return {'success': false, 'error': 'Aucune connexion réseau : $e'};
    } catch (e) {
      return {'success': false, 'error': 'Erreur inattendue : $e'};
    }
  }

  // ==========================================================================
  // ⚡ NOUVEAU — MÉTHODES DE GESTION DE L'ARCHIVE DES ÉLÈVES SUPPRIMÉS
  // ==========================================================================
  // getElevesSupprimes() : retourne la liste des élèves archivés, triée du
  //   plus récemment supprimé au plus ancien, pour affichage dans la page
  //   "Élèves Supprimés".
  // getDateSuppressionEleve() / getMotifSuppressionEleve() : métadonnées
  //   associées à un élève archivé (utilisées pour l'affichage).
  // archiverEtSupprimerEleve() : retire l'élève de currentData.eleves (donc
  //   du registre actif) et l'ajoute à l'archive elevesSupprimesData. Comme
  //   l'objet Eleve conserve intact son historique de paiements (paid,
  //   transactions), et comme les fonctions de calcul monétaire ci-dessus
  //   additionnent aussi elevesSupprimesData.eleves, l'argent déjà payé par
  //   cet élève continue d'être comptabilisé dans la caisse de l'école.
  // supprimerDefinitivementEleveArchive() : supprime définitivement et
  //   irréversiblement un élève de l'archive (l'historique nominatif
  //   disparaît, mais l'argent reste acquis puisqu'il a déjà été
  //   comptabilisé au moment du paiement).
  // viderHistoriqueElevesSupprimes() : vide complètement l'archive.
  List<Eleve> getElevesSupprimes() {
    final list = List<Eleve>.from(elevesSupprimesData.eleves);
    list.sort((a, b) {
      final dateA = dateSuppressionEleves[a.id] ?? '';
      final dateB = dateSuppressionEleves[b.id] ?? '';
      return dateB.compareTo(dateA);
    });
    return list;
  }

  String? getDateSuppressionEleve(String eleveId) =>
      dateSuppressionEleves[eleveId];

  String? getMotifSuppressionEleve(String eleveId) =>
      motifSuppressionEleves[eleveId];

  Future<void> archiverEtSupprimerEleve(
      Eleve eleve, {
        String motif = 'Suppression manuelle',
      }) async {
    currentData.eleves.removeWhere((e) => e.id == eleve.id);
    elevesSupprimesData.eleves.removeWhere((e) => e.id == eleve.id);
    elevesSupprimesData.eleves.add(eleve);
    dateSuppressionEleves[eleve.id] = DateTime.now().toIso8601String();
    motifSuppressionEleves[eleve.id] = motif;
    await saveData();
  }

  Future<void> supprimerDefinitivementEleveArchive(String eleveId) async {
    elevesSupprimesData.eleves.removeWhere((e) => e.id == eleveId);
    dateSuppressionEleves.remove(eleveId);
    motifSuppressionEleves.remove(eleveId);
    await saveData();
  }

  Future<void> viderHistoriqueElevesSupprimes() async {
    elevesSupprimesData = SchoolYearData(eleves: []);
    dateSuppressionEleves = {};
    motifSuppressionEleves = {};
    await saveData();
  }
}