class Eleve {
  String id;
  String nom;
  String postNom;
  String prenom;
  String classe;
  String section;
  Map<String, double> paid = {};
  List<Map<String, dynamic>> transactions = [];

  String pereNom;
  String mereNom;
  String adresse;
  String dateNaissance;
  String? photoBase64;
  Map<String, String> customFields = {};

  double? montantMensuelPersonnalise;

  Map<String, double> exceptionsMoisPersonnalisees = {};

  String? moisDebloque;

  Eleve({
    required this.id,
    required this.nom,
    required this.postNom,
    required this.prenom,
    required this.classe,
    required this.section,
    this.pereNom = '',
    this.mereNom = '',
    this.adresse = '',
    this.dateNaissance = '',
    this.photoBase64,
    Map<String, String>? customFields,
    this.montantMensuelPersonnalise,
    Map<String, double>? exceptionsMoisPersonnalisees,
    this.moisDebloque,
  })  : customFields = customFields ?? {},
        exceptionsMoisPersonnalisees = exceptionsMoisPersonnalisees ?? {};

  bool get hasCarteInfo =>
      pereNom.trim().isNotEmpty ||
          mereNom.trim().isNotEmpty ||
          adresse.trim().isNotEmpty ||
          dateNaissance.trim().isNotEmpty ||
          (photoBase64 != null && photoBase64!.isNotEmpty) ||
          customFields.values.any((v) => v.trim().isNotEmpty);

  Map<String, dynamic> toJson() => {
    'id': id,
    'nom': nom,
    'postNom': postNom,
    'prenom': prenom,
    'classe': classe,
    'section': section,
    'paid': paid,
    'transactions': transactions,
    'pereNom': pereNom,
    'mereNom': mereNom,
    'adresse': adresse,
    'dateNaissance': dateNaissance,
    'photoBase64': photoBase64,
    'customFields': customFields,
    'montantMensuelPersonnalise': montantMensuelPersonnalise,
    'exceptionsMoisPersonnalisees': exceptionsMoisPersonnalisees,
    'moisDebloque': moisDebloque,
  };

  factory Eleve.fromJson(Map<String, dynamic> json) {
    return Eleve(
      id: json['id'] ?? '',
      nom: json['nom'] ?? '',
      postNom: json['postNom'] ?? '',
      prenom: json['prenom'] ?? '',
      classe: json['classe'] ?? '',
      section: json['section'] ?? 'Primaire',
      pereNom: json['pereNom'] ?? '',
      mereNom: json['mereNom'] ?? '',
      adresse: json['adresse'] ?? '',
      dateNaissance: json['dateNaissance'] ?? '',
      photoBase64: json['photoBase64'] as String?,
      customFields: json['customFields'] != null
          ? Map<String, String>.from(json['customFields'] as Map)
          : {},
      montantMensuelPersonnalise:
      (json['montantMensuelPersonnalise'] as num?)?.toDouble(),
      exceptionsMoisPersonnalisees:
      (json['exceptionsMoisPersonnalisees'] as Map? ?? {}).map(
            (key, value) =>
            MapEntry(key.toString(), (value as num).toDouble()),
      ),
      moisDebloque: json['moisDebloque'] as String?,
    )
      ..paid = Map<String, double>.from(json['paid'] ?? {})
      ..transactions = (json['transactions'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  }
}

class Administration {
  String nom;
  double pourcentage;

  Administration({required this.nom, required this.pourcentage});

  Map<String, dynamic> toJson() => {
    'nom': nom,
    'pourcentage': pourcentage,
  };

  factory Administration.fromJson(Map<String, dynamic> json) {
    return Administration(
      nom: json['nom'] ?? '',
      pourcentage: (json['pourcentage'] ?? 0.0).toDouble(),
    );
  }
}

class SchoolConfig {
  String schoolName;
  double defaultMonthlyFee;
  List<String> sections = ['Primaire', 'Secondaire'];
  Map<String, double> feesBySection = {};
  Map<String, Map<String, double>> monthlyExceptionsBySection = {};
  List<Administration> administrations = [];

  Map<String, List<String>> classesBySection = {};
  Map<String, List<String>> subClassesByClasse = {};

  Map<String, double> feesByClasse = {};
  Map<String, Map<String, double>> monthlyExceptionsByClasse = {};

  List<String> customFieldQuestions = [];
  Map<String, String> sectionAliases = {};

  SchoolConfig({
    required this.schoolName,
    this.defaultMonthlyFee = 35000,
    List<String>? sections,
    Map<String, double>? feesBySection,
    Map<String, Map<String, double>>? monthlyExceptionsBySection,
    List<Administration>? administrations,
    Map<String, List<String>>? classesBySection,
    Map<String, List<String>>? subClassesByClasse,
    Map<String, double>? feesByClasse,
    Map<String, Map<String, double>>? monthlyExceptionsByClasse,
    List<String>? customFieldQuestions,
    Map<String, String>? sectionAliases,
  }) {
    this.sections =
        _dedupeSections(sections ?? ['Primaire', 'Secondaire']);
    this.feesBySection = feesBySection ?? {};
    this.monthlyExceptionsBySection = monthlyExceptionsBySection ?? {};
    this.administrations = administrations ?? [];
    this.classesBySection = classesBySection ?? {};
    this.subClassesByClasse = subClassesByClasse ?? {};
    this.feesByClasse = feesByClasse ?? {};
    this.monthlyExceptionsByClasse = monthlyExceptionsByClasse ?? {};
    this.customFieldQuestions = customFieldQuestions ?? [];
    this.sectionAliases = sectionAliases ?? {};
  }

  static List<String> _dedupeSections(Iterable<String> sections) {
    final seen = <String>{};
    final result = <String>[];
    for (final s in sections) {
      if (seen.add(s)) result.add(s);
    }
    return result;
  }

  static List<String> defaultClassesForSectionName(String section) {
    final normalized = section.trim().toLowerCase();
    if (normalized.contains('maternelle')) {
      return ['1ère', '2ème', '3ème'];
    } else if (normalized.contains('primaire')) {
      return ['1ère', '2ème', '3ème', '4ème', '5ème', '6ème'];
    } else if (normalized.contains('secondaire')) {
      return ['7ème', '8ème', '1ère', '2ème', '3ème', '4ème'];
    }
    return [];
  }

  Map<String, dynamic> toJson() => {
    'schoolName': schoolName,
    'defaultMonthlyFee': defaultMonthlyFee,
    'sections': sections,
    'feesBySection': feesBySection,
    'monthlyExceptionsBySection': monthlyExceptionsBySection,
    'administrations': administrations.map((a) => a.toJson()).toList(),
    'classesBySection': classesBySection,
    'subClassesByClasse': subClassesByClasse,
    'feesByClasse': feesByClasse,
    'monthlyExceptionsByClasse': monthlyExceptionsByClasse,
    'customFieldQuestions': customFieldQuestions,
    'sectionAliases': sectionAliases,
  };

  factory SchoolConfig.fromJson(Map<String, dynamic> json) {
    return SchoolConfig(
      schoolName: json['schoolName'] ?? "MAPENDO TCC",
      sections: _dedupeSections(
        List<String>.from(json['sections'] ?? ['Primaire', 'Secondaire']),
      ),
      feesBySection: Map<String, double>.from(json['feesBySection'] ?? {}),
      monthlyExceptionsBySection: (json['monthlyExceptionsBySection'] as Map? ?? {}).map(
            (key, value) => MapEntry(key, Map<String, double>.from(value)),
      ),
      administrations: (json['administrations'] as List? ?? [])
          .map((a) => Administration.fromJson(a))
          .toList(),
      classesBySection: (json['classesBySection'] as Map? ?? {}).map(
            (key, value) => MapEntry(
          key as String,
          List<String>.from(value as List? ?? []),
        ),
      ),
      subClassesByClasse: (json['subClassesByClasse'] as Map? ?? {}).map(
            (key, value) => MapEntry(
          key as String,
          List<String>.from(value as List? ?? []),
        ),
      ),
      feesByClasse: Map<String, double>.from(json['feesByClasse'] ?? {}),
      monthlyExceptionsByClasse: (json['monthlyExceptionsByClasse'] as Map? ?? {}).map(
            (key, value) => MapEntry(key as String, Map<String, double>.from(value)),
      ),
      customFieldQuestions:
      List<String>.from(json['customFieldQuestions'] ?? []),
      sectionAliases:
      Map<String, String>.from(json['sectionAliases'] ?? {}),
    );
  }
}

class SchoolYearData {
  List<Eleve> eleves;

  SchoolYearData({required this.eleves});

  Map<String, dynamic> toJson() => {
    'eleves': eleves.map((e) => e.toJson()).toList(),
  };

  factory SchoolYearData.fromJson(Map<String, dynamic> json) {
    return SchoolYearData(
      eleves: (json['eleves'] as List? ?? [])
          .map((e) => Eleve.fromJson(e))
          .toList(),
    );
  }
}