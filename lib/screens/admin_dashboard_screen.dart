import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../frais_scolaires.dart';
import '../app_state.dart';
import '../services/epson_printer_service.dart';
import '../network_resolver.dart';
import '../local_server_service.dart';

const String _serverUrl = 'https://jsinf.onrender.com';

// ⚡⚡ Les 4 types d'accès qu'une clé peut porter. Chaque type
// correspond à un écran différent côté application sous-utilisateur.
enum KeyAccessType { paiement, discipline, inscription, autresFrais }

extension KeyAccessTypeX on KeyAccessType {
  // Code envoyé au serveur (doit correspondre à KEY_TYPES côté Python
  // ET à la logique du serveur local, voir local_server_service.dart).
  String get code {
    switch (this) {
      case KeyAccessType.paiement:
        return 'PAY';
      case KeyAccessType.discipline:
        return 'DISC';
      case KeyAccessType.inscription:
        return 'INSC';
      case KeyAccessType.autresFrais:
        return 'AFR';
    }
  }

  String get label {
    switch (this) {
      case KeyAccessType.paiement:
        return 'Paiement des frais scolaires';
      case KeyAccessType.discipline:
        return 'Discipline (absences, convocations, communiqués)';
      case KeyAccessType.inscription:
        return 'Inscription des élèves';
      case KeyAccessType.autresFrais:
        return 'Paiement des autres frais';
    }
  }

  IconData get icon {
    switch (this) {
      case KeyAccessType.paiement:
        return Icons.payments;
      case KeyAccessType.discipline:
        return Icons.gavel;
      case KeyAccessType.inscription:
        return Icons.person_add;
      case KeyAccessType.autresFrais:
        return Icons.receipt_long;
    }
  }
}

// Valeur spéciale utilisée dans le dropdown "Classe" pour signifier
// "toutes les classes de la section" (envoyée comme classe vide au
// serveur, ce que verify_key traduit en `classe: null`).
const String _kToutesLesClasses = '__TOUTES__';

class AdminDashboardScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const AdminDashboardScreen({super.key, required this.fraisScolaires});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  // ---------------- GÉNÉRATION DE CLÉ ----------------
  KeyAccessType selectedKeyType = KeyAccessType.paiement;

  // ⚡⚡⚡ Sélection MULTIPLE de sections/options pour une même clé. Le
  // sous-utilisateur connecté avec cette clé pourra ensuite basculer
  // librement entre toutes les sections cochées ici, sans avoir besoin
  // d'une clé différente par section.
  final Set<String> selectedSectionsForKey = {};

  // La classe précise n'a de sens que lorsqu'UNE SEULE section est
  // cochée (une classe appartient à une seule section). Dès que 2
  // sections ou plus sont sélectionnées, ce champ est automatiquement
  // ignoré et la clé donne accès à "toutes les classes" de chacune.
  String? selectedClasseForKey; // null / _kToutesLesClasses = toutes les classes
  bool isGeneratingKey = false;
  // ⚡⚡⚡ Indique qu'une sauvegarde automatique (déclenchée après une
  // génération de clé, en mode INTERNET uniquement) est en cours, pour
  // désactiver le bouton "Générer" et éviter les doubles clics pendant
  // l'upload.
  bool isAutoBackingUp = false;
  List<Map<String, dynamic>> generatedKeys = [];

  // ==========================================================================
  // ⚡ CORRIGÉ — DURÉE DE TRAVAIL AUTORISÉE APRÈS CONNEXION
  //
  // ⚠️ Important : ce délai ne limite PAS la possibilité de se
  // CONNECTER avec la clé — celle-ci reste utilisable à tout moment,
  // jusqu'à révocation manuelle. Il limite le temps que le sous-
  // utilisateur pourra ensuite passer à TRAVAILLER dans l'application
  // (payer des frais, inscrire des élèves, gérer la discipline...) à
  // partir du moment précis où il se connecte avec cette clé.
  //
  // L'admin choisit un nombre (ex: 1, 30...) puis une unité — "Jours"
  // ou "Minutes". Si "Jours" est choisi et que l'admin entre 1, le
  // sous-utilisateur pourra travailler 1 jour à partir de sa
  // connexion ; s'il entre 30, il pourra travailler 30 jours. Si
  // "Minutes" est choisi et qu'il entre 1, il ne pourra travailler
  // qu'une minute, et ainsi de suite. Cette information est envoyée au
  // serveur (local ou internet) à la génération, puis renvoyée par ce
  // même serveur à CHAQUE connexion du sous-utilisateur (voir
  // `/verify_key`), pour que l'application cliente démarre une
  // nouvelle fenêtre de travail de cette durée à chaque fois.
  // ==========================================================================
  final TextEditingController keyDurationController =
  TextEditingController(text: '30');
  int keyDurationValue = 30;
  String keyDurationUnit = 'days'; // 'days' | 'minutes'

  List<String> connectedUsers = [
    "Utilisateur Primaire 1",
    "Utilisateur Secondaire 1"
  ];

  // ---------------- PAIEMENTS EN ATTENTE (frais mensuels) ----------------
  List<Map<String, dynamic>> pendingPayments = [];
  bool hasPendingPayments = false;
  bool isValidating = false;
  bool isRefreshing = false;

  // ⚡⚡ INSCRIPTIONS EN ATTENTE
  List<Map<String, dynamic>> pendingRegistrations = [];
  bool isValidatingRegistrations = false;

  // ⚡⚡ AUTRES FRAIS EN ATTENTE
  List<Map<String, dynamic>> pendingAutresFrais = [];
  bool isValidatingAutresFrais = false;

  // ==========================================================================
  // ⚡ SERVEUR LOCAL (mode réseau sans internet)
  //
  // Ce serveur tourne DANS cette même app (voir local_server_service.dart)
  // et sert les sous-utilisateurs connectés au même réseau WiFi que ce
  // PC (point d'accès Windows OU Partage Internet macOS OU simple
  // routeur/box). ⚡ MODIFIÉ — l'adresse n'est plus fixe (elle dépendait
  // auparavant de l'IP Windows 192.168.137.1) : elle est désormais
  // détectée dynamiquement (voir LocalServerService.getCurrentLocalIp),
  // pour fonctionner identiquement sur Windows et macOS. L'activation du
  // point d'accès/partage lui-même reste manuelle (enseignée aux
  // utilisateurs) — ce toggle ne démarre QUE le petit serveur logiciel.
  // ==========================================================================
  bool _localServerRunning = false;
  bool _togglingLocalServer = false;

  // ⚡⚡⚡ La classe ne peut être restreinte que si exactement une
  // section est cochée. Les classes proposées dans le dropdown
  // proviennent alors de cette unique section sélectionnée.
  List<String> get _classesForSelectedSection {
    if (selectedSectionsForKey.length != 1) return [];
    final section = selectedSectionsForKey.first;
    return widget.fraisScolaires.config.classesBySection[section] ?? [];
  }

  bool get _classeSelectionAllowed => selectedSectionsForKey.length == 1;

  @override
  void initState() {
    super.initState();
    _localServerRunning = LocalServerService.isRunning;
  }

  @override
  void dispose() {
    keyDurationController.dispose();
    super.dispose();
  }

  void _toggleSection(String section, bool selected) {
    setState(() {
      if (selected) {
        selectedSectionsForKey.add(section);
      } else {
        selectedSectionsForKey.remove(section);
      }
      // Dès qu'on n'a plus exactement une seule section cochée, la
      // restriction de classe n'a plus de sens : on la réinitialise.
      if (!_classeSelectionAllowed) {
        selectedClasseForKey = null;
      }
    });
  }

  // ==========================================================================
  // ⚡ Libellé lisible de la durée choisie (ex: "1 jour", "30 jours",
  // "1 minute", "45 minutes"), utilisé à la fois sous le champ de
  // saisie et sur les cartes de clés déjà générées.
  // ==========================================================================
  String _formatDurationLabel(int value, String unit) {
    final bool isMinutes = unit == 'minutes';
    final String noun = isMinutes
        ? (value <= 1 ? 'minute' : 'minutes')
        : (value <= 1 ? 'jour' : 'jours');
    return '$value $noun';
  }

  /// ⚡ CORRIGÉ — texte affiché sur une carte de clé déjà générée,
  /// reformulé pour bien préciser qu'il s'agit d'un temps de TRAVAIL
  /// après connexion, et non d'une date d'expiration de la clé elle-
  /// même (la clé reste utilisable pour se connecter à tout moment).
  String _durationTextForGeneratedKey(Map<String, dynamic> keyData) {
    final int? value = keyData['durationValue'] is int
        ? keyData['durationValue'] as int
        : int.tryParse(keyData['durationValue']?.toString() ?? '');
    final String? unit = keyData['durationUnit']?.toString();
    if (value == null || unit == null) {
      return "Durée de travail non confirmée par le serveur";
    }
    return "Temps de travail autorisé : ${_formatDurationLabel(value, unit)} "
        "à chaque connexion avec cette clé";
  }

  // ==========================================================================
  // DÉMARRER / ARRÊTER LE SERVEUR LOCAL
  // ==========================================================================
  Future<void> _toggleLocalServer() async {
    setState(() => _togglingLocalServer = true);
    try {
      if (_localServerRunning) {
        await LocalServerService.stop();
        if (mounted) {
          setState(() => _localServerRunning = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Serveur local arrêté")),
          );
        }
      } else {
        final ok = await LocalServerService.start(widget.fraisScolaires);
        if (mounted) {
          setState(() => _localServerRunning = ok);
          if (ok) {
            NetworkResolver.invalidateCache();
            // ⚡ MODIFIÉ — l'adresse affichée est désormais détectée
            // dynamiquement (fonctionne sur Windows comme sur macOS),
            // au lieu de l'ancienne IP fixe Windows.
            final ip = await LocalServerService.getCurrentLocalIp();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    "✅ Serveur local démarré sur "
                        "${ip ?? '?'}:${NetworkResolver.localPort}\n"
                        "Les sous-utilisateurs connectés au même réseau "
                        "WiFi que ce PC peuvent maintenant travailler "
                        "sans internet.",
                  ),
                  backgroundColor: Colors.green,
                  duration: const Duration(seconds: 5),
                ),
              );
            }
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    "❌ Impossible de démarrer le serveur local (port déjà "
                        "utilisé ou droit réseau refusé)"),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    } finally {
      if (mounted) setState(() => _togglingLocalServer = false);
    }
  }

  Future<bool> _verifyAdminPassword() async {
    final appState = Provider.of<AppState>(context, listen: false);

    if (appState.backupPassword == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Aucun mot de passe administrateur défini. "
                "Rendez-vous dans les Paramètres pour en créer un.",
          ),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }

    final passController = TextEditingController();
    bool? result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Vérification Administrateur"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Cette action est protégée. Entrez le mot de passe "
                  "administrateur pour continuer.",
            ),
            const SizedBox(height: 14),
            TextField(
              controller: passController,
              obscureText: true,
              decoration: const InputDecoration(labelText: "Mot de passe"),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
          ElevatedButton(
            onPressed: () {
              if (passController.text.trim() == appState.backupPassword) {
                Navigator.pop(ctx, true);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Mot de passe incorrect."),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            child: const Text("Confirmer"),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ==========================================================================
  // ⚡ RAFRAÎCHISSEMENT : bascule automatiquement entre serveur
  // local et serveur internet selon ce qui est joignable maintenant (voir
  // NetworkResolver). En mode local, il n'y a rien à "restaurer" : les
  // données sont déjà celles de cette même instance qui héberge le
  // serveur — on va simplement chercher les files d'attente.
  // ==========================================================================
  Future<void> _refreshData() async {
    final appState = Provider.of<AppState>(context, listen: false);

    if (appState.schoolCode == null || appState.schoolCode!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Définissez d'abord le Code École"),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => isRefreshing = true);

    try {
      final base = await NetworkResolver.resolve(forceRefresh: true);
      final bool isLocal = base == NetworkResolver.localBaseUrl;

      bool success = true;
      String? errorMsg;

      if (isLocal) {
        // Rien à restaurer : cette instance EST la source de vérité en
        // mode local.
        success = true;
      } else {
        if (appState.backupPassword == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Définissez un mot de passe de sauvegarde")),
          );
          setState(() => isRefreshing = false);
          return;
        }
        final Map<String, dynamic> restoreResult =
        await widget.fraisScolaires.restoreFromServer(
          appState.schoolCode!,
          appState.backupPassword!,
        );
        success = restoreResult['success'] == true;
        errorMsg = restoreResult['error']?.toString();
      }

      // Paiements de frais mensuels en attente.
      List<Map<String, dynamic>> fetchedPending = [];
      try {
        final pendingResponse = await http
            .get(Uri.parse(
            '$base/get_pending_payments?school_code=${appState.schoolCode}'))
            .timeout(const Duration(seconds: 15));
        if (pendingResponse.statusCode == 200) {
          final data = jsonDecode(pendingResponse.body);
          final list = data['pending_payments'] as List<dynamic>? ?? [];
          fetchedPending =
              list.map((e) => Map<String, dynamic>.from(e)).toList();
        }
      } catch (_) {}

      // ⚡⚡ Inscriptions en attente.
      List<Map<String, dynamic>> fetchedRegistrations = [];
      try {
        final regResponse = await http
            .get(Uri.parse(
            '$base/school/get_pending_registrations?school_code=${appState.schoolCode}'))
            .timeout(const Duration(seconds: 15));
        if (regResponse.statusCode == 200) {
          final data = jsonDecode(regResponse.body);
          final list =
              data['pending_registrations'] as List<dynamic>? ?? [];
          fetchedRegistrations =
              list.map((e) => Map<String, dynamic>.from(e)).toList();
        }
      } catch (_) {}

      // ⚡⚡ Paiements d'autres frais en attente.
      List<Map<String, dynamic>> fetchedAutresFrais = [];
      try {
        final afrResponse = await http
            .get(Uri.parse(
            '$base/school/get_pending_autres_frais?school_code=${appState.schoolCode}'))
            .timeout(const Duration(seconds: 15));
        if (afrResponse.statusCode == 200) {
          final data = jsonDecode(afrResponse.body);
          final list =
              data['pending_autres_frais'] as List<dynamic>? ?? [];
          fetchedAutresFrais =
              list.map((e) => Map<String, dynamic>.from(e)).toList();
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          pendingPayments = fetchedPending;
          hasPendingPayments = pendingPayments.isNotEmpty;
          pendingRegistrations = fetchedRegistrations;
          pendingAutresFrais = fetchedAutresFrais;
        });

        if (success) {
          final int totalPending = pendingPayments.length +
              pendingRegistrations.length +
              pendingAutresFrais.length;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                (totalPending > 0
                    ? "✅ $totalPending élément(s) en attente de validation"
                    : "✅ Données récupérées") +
                    (isLocal ? " (mode local)" : ""),
              ),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "⚠️ Impossible de recharger les données générales : "
                    "${errorMsg ?? 'erreur inconnue'}",
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("❌ Erreur de connexion"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isRefreshing = false);
    }
  }

  // ==========================================================================
  // IMPRESSION AUTOMATIQUE GROUPÉE APRÈS VALIDATION D'UN LOT (inchangé —
  // fonctionne identiquement que la validation vienne du serveur local ou
  // du serveur internet, puisqu'elle se base sur les données déjà
  // rechargées dans `widget.fraisScolaires`).
  // ==========================================================================

  Future<Uint8List?> _loadLogoBytesFromDisk() async {
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

  String _studentKey(String nom, String postNom, String prenom) =>
      '${nom.trim().toLowerCase()}_${postNom.trim().toLowerCase()}_'
          '${prenom.trim().toLowerCase()}';

  Future<void> _printReceiptsForValidatedPayments(
      List<Map<String, dynamic>> payments) async {
    if (payments.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final printerName = prefs.getString('printer_name') ?? '';
    if (printerName.isEmpty) return; // pas d'imprimante — silencieux

    final logoBytes = await _loadLogoBytesFromDisk();
    final today = DateTime.now().toString().split(' ')[0];

    final Map<String, List<Map<String, dynamic>>> byStudent = {};
    for (final p in payments) {
      final key = _studentKey(
        (p['nom'] ?? '').toString(),
        (p['postNom'] ?? '').toString(),
        (p['prenom'] ?? '').toString(),
      );
      byStudent.putIfAbsent(key, () => []).add(p);
    }

    int printed = 0;
    for (final group in byStudent.values) {
      final first = group.first;
      final nom = (first['nom'] ?? '').toString();
      final postNom = (first['postNom'] ?? '').toString();
      final prenom = (first['prenom'] ?? '').toString();

      final eleve =
      widget.fraisScolaires.findStudentByFullName(nom, postNom, prenom);

      final String studentName = '$nom $postNom $prenom';
      final String studentId = eleve?.id ?? (first['id']?.toString() ?? '');
      final String classe =
          eleve?.classe ?? (first['classe'] ?? '').toString();
      final String section =
          eleve?.section ?? (first['section'] ?? '').toString();

      final transactions = group
          .map((p) => {
        'mois': p['mois'],
        'amount': p['amount'],
        'date': p['date'] ?? today,
      })
          .toList();

      final bool ok = await EscPosPrinterService.printTransactionsReceipt(
        printerName: printerName,
        schoolName: widget.fraisScolaires.config.schoolName,
        currentYear: widget.fraisScolaires.currentYear,
        studentName: studentName,
        studentId: studentId,
        classe: classe,
        section: section,
        transactions: transactions,
        logoBytes: logoBytes,
      );
      if (ok) printed++;
    }

    if (mounted && printed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("🖨️ $printed reçu(s) imprimé(s) automatiquement"),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _printReceiptsForValidatedAutresFrais(
      List<Map<String, dynamic>> paiements) async {
    if (paiements.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final printerName = prefs.getString('printer_name') ?? '';
    if (printerName.isEmpty) return;

    final logoBytes = await _loadLogoBytesFromDisk();
    final today = DateTime.now().toString().split(' ')[0];

    final Map<String, List<Map<String, dynamic>>> byStudent = {};
    for (final p in paiements) {
      final key = _studentKey(
        (p['nom'] ?? '').toString(),
        (p['postNom'] ?? '').toString(),
        (p['prenom'] ?? '').toString(),
      );
      byStudent.putIfAbsent(key, () => []).add(p);
    }

    int printed = 0;
    for (final group in byStudent.values) {
      final first = group.first;
      final nom = (first['nom'] ?? '').toString();
      final postNom = (first['postNom'] ?? '').toString();
      final prenom = (first['prenom'] ?? '').toString();

      final eleve =
      widget.fraisScolaires.findStudentByFullName(nom, postNom, prenom);

      final String studentName = '$nom $postNom $prenom';
      final String classe =
          eleve?.classe ?? (first['classe'] ?? '').toString();
      final String section =
          eleve?.section ?? (first['section'] ?? '').toString();

      final items = group
          .map((p) => {
        'nom': p['autreFraisNom'],
        'montant': p['montant'],
        'date': p['date'] ?? today,
      })
          .toList();

      final bool ok =
      await EscPosPrinterService.printAutresFraisTransactionsReceipt(
        printerName: printerName,
        schoolName: widget.fraisScolaires.config.schoolName,
        studentName: studentName,
        classe: classe,
        section: section,
        paiements: items,
        logoBytes: logoBytes,
      );
      if (ok) printed++;
    }

    if (mounted && printed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("🖨️ $printed reçu(s) imprimé(s) automatiquement"),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // ==================== PAIEMENTS DES FRAIS MENSUELS ====================

  void _showPendingPaymentsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Paiements en Attente de Validation"),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: pendingPayments.isEmpty
              ? const Center(child: Text("Aucun paiement en attente"))
              : ListView.builder(
            itemCount: pendingPayments.length,
            itemBuilder: (context, index) {
              final p = pendingPayments[index];
              return ListTile(
                title: Text(
                  "${p['nom']} ${p['postNom'] ?? ''} ${p['prenom']}",
                ),
                subtitle: Text(
                  "${p['mois']} - ${p['amount']} FC\n"
                      "Section: ${p['section'] ?? ''} | Classe: ${p['classe'] ?? ''}",
                ),
                trailing:
                const Icon(Icons.check_circle, color: Colors.green),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Annuler"),
          ),
          ElevatedButton(
            onPressed: pendingPayments.isEmpty
                ? null
                : () async {
              Navigator.pop(ctx);
              await _validateAllPayments();
            },
            child: const Text("Valider Tout"),
          ),
        ],
      ),
    );
  }

  Future<void> _validateAllPayments() async {
    final appState = Provider.of<AppState>(context, listen: false);

    if (appState.schoolCode == null || appState.schoolCode!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Code école manquant"),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final base = await NetworkResolver.resolve();
    final bool isLocal = base == NetworkResolver.localBaseUrl;

    if (!isLocal &&
        (appState.backupPassword == null || appState.backupPassword!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Mot de passe de sauvegarde manquant"),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => isValidating = true);

    // Copie du lot AVANT de le vider, pour l'impression groupée par élève.
    final List<Map<String, dynamic>> paymentsToPrint =
    List<Map<String, dynamic>>.from(pendingPayments);

    try {
      final ids = pendingPayments.map((p) => p['id']).toList();

      final response = await http
          .post(
        Uri.parse('$base/validate_payments'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'school_code': appState.schoolCode,
          'payment_ids': ids,
        }),
      )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        bool success;
        String? errorMsg;
        if (isLocal) {
          // Le serveur local a déjà appliqué les paiements directement
          // sur cette même instance — rien à restaurer depuis un autre
          // serveur, on s'assure juste que le fichier local est à jour.
          await widget.fraisScolaires.saveData();
          success = true;
        } else {
          final Map<String, dynamic> restoreResult =
          await widget.fraisScolaires.restoreFromServer(
            appState.schoolCode!,
            appState.backupPassword!,
          );
          success = restoreResult['success'] == true;
          errorMsg = restoreResult['error']?.toString();
        }

        if (success && mounted) {
          setState(() {
            hasPendingPayments = false;
            pendingPayments.clear();
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content:
              Text("✅ Tous les paiements ont été validés et enregistrés !"),
              backgroundColor: Colors.green,
            ),
          );

          await widget.fraisScolaires.loadData();
          if (mounted) setState(() {});

          // Impression automatique : un seul reçu par élève, regroupant
          // tous les mois qu'il vient de payer dans ce lot.
          await _printReceiptsForValidatedPayments(paymentsToPrint);
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "⚠️ Paiements validés côté serveur mais impossible de "
                    "recharger les données locales : ${errorMsg ?? 'erreur inconnue'}",
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("❌ Erreur lors de la validation côté serveur"),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Erreur lors de la validation"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isValidating = false);
    }
  }

  // ==================== ⚡⚡ INSCRIPTIONS EN ATTENTE ====================

  void _showPendingRegistrationsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Inscriptions en Attente de Validation"),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: pendingRegistrations.isEmpty
              ? const Center(child: Text("Aucune inscription en attente"))
              : ListView.builder(
            itemCount: pendingRegistrations.length,
            itemBuilder: (context, index) {
              final r = pendingRegistrations[index];
              return ListTile(
                leading: const Icon(Icons.person_add, color: Colors.indigo),
                title: Text("${r['nom']} ${r['postNom'] ?? ''} ${r['prenom'] ?? ''}"),
                subtitle: Text(
                  "Section: ${r['section']} | Classe: ${r['classe']}\n"
                      "Soumis par: ${r['submitted_by'] ?? ''}",
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Fermer"),
          ),
          ElevatedButton(
            onPressed: pendingRegistrations.isEmpty
                ? null
                : () async {
              Navigator.pop(ctx);
              await _validateAllRegistrations();
            },
            child: const Text("Valider Tout"),
          ),
        ],
      ),
    );
  }

  Future<void> _validateAllRegistrations() async {
    final appState = Provider.of<AppState>(context, listen: false);
    if (appState.schoolCode == null || appState.schoolCode!.isEmpty) return;

    final base = await NetworkResolver.resolve();
    final bool isLocal = base == NetworkResolver.localBaseUrl;

    setState(() => isValidatingRegistrations = true);
    try {
      final ids = pendingRegistrations.map((r) => r['id']).toList();
      final response = await http
          .post(
        Uri.parse('$base/school/validate_registrations'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'school_code': appState.schoolCode,
          'registration_ids': ids,
        }),
      )
          .timeout(const Duration(seconds: 15));

      final bool canSync = isLocal || appState.backupPassword != null;

      if (response.statusCode == 200 && canSync) {
        if (!isLocal) {
          await widget.fraisScolaires
              .restoreFromServer(appState.schoolCode!, appState.backupPassword!);
        }
        await widget.fraisScolaires.saveData();
        await widget.fraisScolaires.loadData();
        if (mounted) {
          setState(() => pendingRegistrations.clear());
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("✅ Inscriptions validées et élèves créés !"),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("❌ Erreur lors de la validation des inscriptions"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Erreur lors de la validation"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isValidatingRegistrations = false);
    }
  }

  // ==================== ⚡⚡ AUTRES FRAIS EN ATTENTE ====================

  void _showPendingAutresFraisDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Paiements d'Autres Frais en Attente"),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: pendingAutresFrais.isEmpty
              ? const Center(child: Text("Aucun paiement en attente"))
              : ListView.builder(
            itemCount: pendingAutresFrais.length,
            itemBuilder: (context, index) {
              final p = pendingAutresFrais[index];
              return ListTile(
                leading: const Icon(Icons.receipt_long, color: Colors.teal),
                title: Text("${p['nom']} ${p['postNom'] ?? ''} ${p['prenom'] ?? ''}"),
                subtitle: Text(
                  "${p['autreFraisNom']} - ${p['montant']} FC\n"
                      "Enregistré par: ${p['enregistrePar'] ?? ''}",
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Fermer"),
          ),
          ElevatedButton(
            onPressed: pendingAutresFrais.isEmpty
                ? null
                : () async {
              Navigator.pop(ctx);
              await _validateAllAutresFrais();
            },
            child: const Text("Valider Tout"),
          ),
        ],
      ),
    );
  }

  Future<void> _validateAllAutresFrais() async {
    final appState = Provider.of<AppState>(context, listen: false);
    if (appState.schoolCode == null || appState.schoolCode!.isEmpty) return;

    final base = await NetworkResolver.resolve();
    final bool isLocal = base == NetworkResolver.localBaseUrl;

    setState(() => isValidatingAutresFrais = true);

    final List<Map<String, dynamic>> autresFraisToPrint =
    List<Map<String, dynamic>>.from(pendingAutresFrais);

    try {
      final ids = pendingAutresFrais.map((p) => p['id']).toList();
      final response = await http
          .post(
        Uri.parse('$base/school/validate_autres_frais_payments'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'school_code': appState.schoolCode,
          'payment_ids': ids,
        }),
      )
          .timeout(const Duration(seconds: 15));

      final bool canSync = isLocal || appState.backupPassword != null;

      if (response.statusCode == 200 && canSync) {
        if (!isLocal) {
          await widget.fraisScolaires
              .restoreFromServer(appState.schoolCode!, appState.backupPassword!);
        }
        await widget.fraisScolaires.saveData();
        await widget.fraisScolaires.loadData();
        if (mounted) {
          setState(() => pendingAutresFrais.clear());
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("✅ Paiements d'autres frais validés !"),
              backgroundColor: Colors.green,
            ),
          );

          await _printReceiptsForValidatedAutresFrais(autresFraisToPrint);
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("❌ Erreur lors de la validation"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Erreur lors de la validation"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isValidatingAutresFrais = false);
    }
  }

  // ==================== ⚡⚡⚡ GÉNÉRATION DE CLÉ MULTI-SECTIONS ====================
  // ⚡⚡⚡ Après une génération de clé réussie EN MODE INTERNET, les
  // données sont automatiquement sauvegardées sur le serveur central,
  // pour que la clé soit immédiatement disponible depuis n'importe quel
  // appareil. EN MODE LOCAL, il n'y a rien à synchroniser : la clé vit
  // déjà dans les données locales, qui SONT la source de vérité tant que
  // l'appareil n'a pas internet.

  Future<String?> _autoBackupAfterKeyGeneration({required bool isLocal}) async {
    if (isLocal) return null; // rien à faire en mode local

    final appState = Provider.of<AppState>(context, listen: false);

    if (appState.schoolCode == null || appState.schoolCode!.isEmpty) {
      return "code école manquant";
    }
    if (appState.backupPassword == null || appState.backupPassword!.isEmpty) {
      return "mot de passe de sauvegarde non défini (Paramètres)";
    }

    setState(() => isAutoBackingUp = true);
    try {
      final result = await widget.fraisScolaires.backupToServer(
        appState.schoolCode!,
        appState.backupPassword!,
      );
      if (result['success'] == true) {
        return null;
      }
      return result['error']?.toString() ?? "erreur inconnue";
    } catch (e) {
      return "$e";
    } finally {
      if (mounted) setState(() => isAutoBackingUp = false);
    }
  }

  Future<void> _generateKey() async {
    final appState = Provider.of<AppState>(context, listen: false);

    if (selectedSectionsForKey.isEmpty) return;

    if (appState.schoolCode == null || appState.schoolCode!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Définissez d'abord le Code École"),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // ⚡ Valide la durée saisie juste avant de générer, au cas où
    // l'admin aurait laissé le champ vide ou tapé une valeur non
    // numérique sans que `onChanged` ait pu la corriger à temps.
    final int? parsedDuration = int.tryParse(keyDurationController.text.trim());
    if (parsedDuration == null || parsedDuration < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Entrez un nombre valide (1 ou plus) pour le temps de travail"),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    keyDurationValue = parsedDuration;

    final bool authorized = await _verifyAdminPassword();
    if (!authorized) return;

    // La classe n'est envoyée que si UNE SEULE section est cochée ET
    // qu'une classe précise (autre que "toutes") a été choisie.
    final String? classeToSend = (_classeSelectionAllowed &&
        selectedClasseForKey != null &&
        selectedClasseForKey != _kToutesLesClasses)
        ? selectedClasseForKey
        : null;

    final List<String> sectionsToSend = selectedSectionsForKey.toList();

    setState(() => isGeneratingKey = true);
    try {
      final base = await NetworkResolver.resolve();
      final bool isLocal = base == NetworkResolver.localBaseUrl;

      final response = await http
          .post(
        Uri.parse('$base/generate_key'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'school_code': appState.schoolCode,
          'sections': sectionsToSend,
          'type': selectedKeyType.code,
          'classe': classeToSend,
          // ⚡ Durée de TRAVAIL après connexion (pas d'expiration de la
          // clé elle-même) choisie par l'admin.
          'duration_value': keyDurationValue,
          'duration_unit': keyDurationUnit,
        }),
      )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<String> confirmedSections = (data['sections'] as List?)
            ?.map((s) => s.toString())
            .toList() ??
            sectionsToSend;
        // ⚡ La durée renvoyée par le serveur prime sur ce que l'admin a
        // choisi localement ; sinon on retombe sur son choix, pour
        // toujours afficher quelque chose de cohérent.
        final int confirmedDurationValue =
            (data['duration_value'] as num?)?.toInt() ?? keyDurationValue;
        final String confirmedDurationUnit =
        (data['duration_unit'] ?? keyDurationUnit).toString();

        setState(() {
          generatedKeys.add({
            'key': data['key'],
            'sections': confirmedSections,
            'type': data['type'] ?? selectedKeyType.code,
            'classe': data['classe'], // null = toutes les classes
            'isLocal': isLocal,
            // ⚡ Durée de TRAVAIL après connexion (pas d'expiration).
            'durationValue': confirmedDurationValue,
            'durationUnit': confirmedDurationUnit,
          });
        });

        final String sectionsLabel = confirmedSections.length > 1
            ? "${confirmedSections.length} sections (${confirmedSections.join(', ')})"
            : confirmedSections.first;

        final String keyMsg =
            "✅ Clé générée (${selectedKeyType.label}) pour "
            "$sectionsLabel"
            "${classeToSend != null ? ' - $classeToSend' : ' - toutes les classes'}"
            "\n⏳ Temps de travail alloué à chaque connexion : "
            "${_formatDurationLabel(confirmedDurationValue, confirmedDurationUnit)}"
            "\nℹ️ La clé elle-même reste utilisable pour se connecter à "
            "tout moment (jusqu'à révocation).";

        if (isLocal) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    "$keyMsg\n📶 Mode local — utilisable immédiatement par "
                        "les appareils connectés au même réseau WiFi que "
                        "ce PC"),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 6),
              ),
            );
          }
        } else {
          final String? backupError =
          await _autoBackupAfterKeyGeneration(isLocal: false);
          if (mounted) {
            if (backupError == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      "$keyMsg\n💾 Données également sauvegardées sur le serveur"),
                  backgroundColor: Colors.green,
                  duration: const Duration(seconds: 6),
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      "$keyMsg\n⚠️ Sauvegarde automatique impossible : $backupError"),
                  backgroundColor: Colors.orange,
                  duration: const Duration(seconds: 7),
                ),
              );
            }
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("❌ Le serveur n'a pas pu générer la clé"),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                "❌ Aucun serveur joignable (ni local, ni internet)"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isGeneratingKey = false);
    }
  }

  void _removeUser(String user) {
    setState(() => connectedUsers.remove(user));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("$user a été déconnecté")),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int totalPendingCount =
        pendingPayments.length + pendingRegistrations.length + pendingAutresFrais.length;
    final bool generateButtonBusy = isGeneratingKey || isAutoBackingUp;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Admin Dashboard - Contrôle Central"),
        backgroundColor: Colors.deepPurple,
        actions: [
          IconButton(
            icon: isRefreshing
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
                : const Icon(Icons.refresh),
            tooltip: "Rafraîchir les données",
            onPressed: isRefreshing ? null : _refreshData,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ==================== ⚡ SERVEUR LOCAL ====================
              Card(
                color: _localServerRunning
                    ? Colors.green.shade50
                    : Colors.grey.shade100,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.wifi_tethering,
                            color: _localServerRunning
                                ? Colors.green
                                : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            "Serveur Local (sans internet)",
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // ⚡ MODIFIÉ — texte générique (Windows OU macOS),
                      // plus de référence à une IP fixe.
                      Text(
                        _localServerRunning
                            ? "Actif — les appareils connectés au même réseau WiFi "
                            "que ce PC peuvent travailler avec les clés d'accès, "
                            "sans internet (détection automatique, aucune IP à saisir)."
                            : "Inactif. Étapes : 1) partagez votre connexion "
                            "(\"Point d'accès mobile\" sur Windows ou "
                            "\"Partage Internet\" sur macOS) depuis ce PC, "
                            "2) démarrez le serveur ci-dessous, 3) "
                            "connectez les autres appareils au WiFi "
                            "créé par ce partage.",
                        style: const TextStyle(fontSize: 12.5, color: Colors.black87),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: _togglingLocalServer
                                  ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                                  : Icon(_localServerRunning
                                  ? Icons.stop
                                  : Icons.play_arrow),
                              label: Text(_localServerRunning
                                  ? "Arrêter le serveur local"
                                  : "Démarrer le serveur local"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _localServerRunning
                                    ? Colors.red
                                    : Colors.green,
                                foregroundColor: Colors.white,
                              ),
                              onPressed:
                              _togglingLocalServer ? null : _toggleLocalServer,
                            ),
                          ),
                          if (_localServerRunning) ...[
                            const SizedBox(width: 8),
                            // ⚡ MODIFIÉ — l'adresse copiée est désormais
                            // détectée dynamiquement via
                            // LocalServerService.getCurrentLocalIp() au
                            // lieu de l'ancienne IP fixe Windows.
                            IconButton(
                              icon: const Icon(Icons.copy),
                              tooltip: "Copier l'adresse pour les agents",
                              onPressed: () async {
                                final ip =
                                await LocalServerService.getCurrentLocalIp();
                                Clipboard.setData(ClipboardData(
                                    text:
                                    "${ip ?? '?'}:${NetworkResolver.localPort}"));
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text("Adresse copiée")),
                                  );
                                }
                              },
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ==================== GÉNÉRATION DE CLÉ ====================
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Générer une Clé d'Accès",
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        "Le mot de passe administrateur sera demandé avant la "
                            "génération. La clé fonctionne automatiquement en "
                            "mode local (si le serveur local est démarré) ou "
                            "via internet, selon ce qui est disponible sur "
                            "cet appareil au moment de la génération.",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 16),

                      // 1) Type d'accès de la clé.
                      const Text("1. Pour quoi faire ?",
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: KeyAccessType.values.map((type) {
                          final bool isSelected = selectedKeyType == type;
                          return ChoiceChip(
                            avatar: Icon(type.icon,
                                size: 18,
                                color: isSelected
                                    ? Colors.white
                                    : Colors.deepPurple),
                            label: Text(type.label),
                            selected: isSelected,
                            selectedColor: Colors.deepPurple,
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.black87,
                              fontSize: 12,
                            ),
                            onSelected: (_) =>
                                setState(() => selectedKeyType = type),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),

                      // ⚡⚡⚡ 2) Sélection MULTIPLE de sections.
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("2. Quelle(s) section(s) ?",
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.bold)),
                          if (widget.fraisScolaires.config.sections.isNotEmpty)
                            TextButton.icon(
                              icon: Icon(
                                selectedSectionsForKey.length ==
                                    widget.fraisScolaires.config.sections.length
                                    ? Icons.deselect
                                    : Icons.select_all,
                                size: 16,
                              ),
                              label: Text(
                                selectedSectionsForKey.length ==
                                    widget.fraisScolaires.config.sections.length
                                    ? "Tout désélectionner"
                                    : "Tout sélectionner",
                                style: const TextStyle(fontSize: 12),
                              ),
                              onPressed: () {
                                setState(() {
                                  if (selectedSectionsForKey.length ==
                                      widget.fraisScolaires.config.sections
                                          .length) {
                                    selectedSectionsForKey.clear();
                                  } else {
                                    selectedSectionsForKey
                                      ..clear()
                                      ..addAll(
                                          widget.fraisScolaires.config.sections);
                                  }
                                  if (!_classeSelectionAllowed) {
                                    selectedClasseForKey = null;
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        "Cochez une ou plusieurs sections/options : le "
                            "sous-utilisateur pourra ensuite basculer "
                            "librement entre elles, une fois connecté avec "
                            "cette clé, sans avoir besoin d'une autre clé.",
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: widget.fraisScolaires.config.sections
                            .map((s) {
                          final bool isSelected =
                          selectedSectionsForKey.contains(s);
                          return FilterChip(
                            avatar: isSelected
                                ? const Icon(Icons.check, size: 16,
                                color: Colors.white)
                                : null,
                            label: Text(s),
                            selected: isSelected,
                            selectedColor: Colors.deepPurple,
                            checkmarkColor: Colors.white,
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.black87,
                              fontSize: 12,
                            ),
                            onSelected: (val) => _toggleSection(s, val),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),

                      // 3) Classe, ou "toutes les classes" — uniquement
                      // proposée quand une seule section est cochée.
                      const Text("3. Quelle(s) classe(s) ?",
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      if (!_classeSelectionAllowed)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: Text(
                            selectedSectionsForKey.isEmpty
                                ? "Sélectionnez d'abord une section."
                                : "Plusieurs sections sont sélectionnées : "
                                "toutes les classes de chacune seront "
                                "accessibles (restriction par classe "
                                "indisponible ici).",
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54),
                          ),
                        )
                      else
                        DropdownButton<String>(
                          isExpanded: true,
                          hint: const Text("Choisir la classe"),
                          value: selectedClasseForKey,
                          items: [
                            const DropdownMenuItem(
                              value: _kToutesLesClasses,
                              child: Text(
                                "Toutes les classes de la section",
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            ..._classesForSelectedSection.map(
                                  (c) => DropdownMenuItem(
                                  value: c, child: Text(c)),
                            ),
                          ],
                          onChanged: (val) =>
                              setState(() => selectedClasseForKey = val),
                        ),
                      const SizedBox(height: 16),

                      // ⚡ CORRIGÉ — 4) Temps de travail autorisé APRÈS
                      // connexion (et non expiration de la clé).
                      const Text("4. Pendant combien de temps peut-il travailler ?",
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      const Text(
                        "⚠️ Ce délai ne bloque PAS la connexion avec cette "
                            "clé : elle reste utilisable à tout moment, "
                            "jusqu'à ce que vous la révoquiez vous-même. Il "
                            "limite uniquement le temps que le sous-"
                            "utilisateur pourra passer à travailler dans "
                            "l'application UNE FOIS connecté. Entrez un "
                            "nombre puis choisissez l'unité : Jours (ex: 1 "
                            "= 1 jour, 30 = 30 jours) ou Minutes (ex: 1 = "
                            "1 minute).",
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: keyDurationController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: "Durée",
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (val) {
                                final parsed = int.tryParse(val.trim());
                                setState(() {
                                  keyDurationValue =
                                  (parsed != null && parsed > 0)
                                      ? parsed
                                      : keyDurationValue;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 3,
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ChoiceChip(
                                  label: const Text("Jours"),
                                  selected: keyDurationUnit == 'days',
                                  selectedColor: Colors.deepPurple,
                                  labelStyle: TextStyle(
                                    color: keyDurationUnit == 'days'
                                        ? Colors.white
                                        : Colors.black87,
                                    fontSize: 12,
                                  ),
                                  onSelected: (_) =>
                                      setState(() => keyDurationUnit = 'days'),
                                ),
                                ChoiceChip(
                                  label: const Text("Minutes"),
                                  selected: keyDurationUnit == 'minutes',
                                  selectedColor: Colors.deepPurple,
                                  labelStyle: TextStyle(
                                    color: keyDurationUnit == 'minutes'
                                        ? Colors.white
                                        : Colors.black87,
                                    fontSize: 12,
                                  ),
                                  onSelected: (_) => setState(
                                          () => keyDurationUnit = 'minutes'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        "Aperçu : le sous-utilisateur pourra travailler "
                            "${_formatDurationLabel(keyDurationValue, keyDurationUnit)} "
                            "à chaque fois qu'il se connecte avec cette clé.",
                        style: const TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: Colors.deepPurple),
                      ),
                      const SizedBox(height: 16),

                      ElevatedButton.icon(
                        icon: generateButtonBusy
                            ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                            : const Icon(Icons.key),
                        label: Text(
                          isGeneratingKey
                              ? "Génération en cours..."
                              : (isAutoBackingUp
                              ? "Sauvegarde automatique en cours..."
                              : "Générer la Clé"),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                          minimumSize: const Size(double.infinity, 50),
                        ),
                        onPressed: (selectedSectionsForKey.isEmpty ||
                            generateButtonBusy)
                            ? null
                            : _generateKey,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              const Text(
                "Clés Générées",
                style:
                TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              if (generatedKeys.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    "Aucune clé générée pour cette session.",
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else
                ...generatedKeys.map((keyData) {
                  final KeyAccessType type = KeyAccessType.values.firstWhere(
                        (t) => t.code == keyData['type'],
                    orElse: () => KeyAccessType.paiement,
                  );
                  final List<String> sections =
                  List<String>.from(keyData['sections'] ?? const []);
                  final String sectionsLabel = sections.isEmpty
                      ? "—"
                      : sections.join(' + ');
                  final String classeLabel =
                  keyData['classe'] == null ? "Toutes les classes" : keyData['classe'];
                  final bool isLocalKey = keyData['isLocal'] == true;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(type.icon, color: Colors.amber),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              keyData['key'],
                              style:
                              const TextStyle(fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isLocalKey) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.wifi_tethering,
                                size: 14, color: Colors.green),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        "${type.label}\nSection(s) : $sectionsLabel | Classe : $classeLabel\n"
                            "${_durationTextForGeneratedKey(keyData)}"
                            "${isLocalKey ? '\n(clé locale — sans internet)' : ''}",
                      ),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: "Copier la clé",
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: keyData['key']));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("✅ Clé copiée")),
                          );
                        },
                      ),
                    ),
                  );
                }),
              const SizedBox(height: 30),

              // ==================== VALIDATIONS EN ATTENTE ====================
              if (totalPendingCount > 0)
                ElevatedButton.icon(
                  icon: const Icon(Icons.visibility),
                  label: Text(
                    "Voir & Valider Tout ce qui est en Attente "
                        "($totalPendingCount)",
                  ),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 55),
                    backgroundColor: Colors.orange,
                  ),
                  onPressed: () {
                    if (pendingPayments.isNotEmpty) {
                      _showPendingPaymentsDialog();
                    } else if (pendingRegistrations.isNotEmpty) {
                      _showPendingRegistrationsDialog();
                    } else if (pendingAutresFrais.isNotEmpty) {
                      _showPendingAutresFraisDialog();
                    }
                  },
                )
              else
                ElevatedButton.icon(
                  icon: isRefreshing
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                      : const Icon(Icons.refresh),
                  label: Text(isRefreshing
                      ? "Rafraîchissement..."
                      : "Rafraîchir les Données"),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 55),
                    backgroundColor: Colors.teal,
                  ),
                  onPressed: isRefreshing ? null : _refreshData,
                ),
              const SizedBox(height: 12),

              // Détail des 3 files d'attente, chacune avec son propre
              // bouton (paiements / inscriptions / autres frais).
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(Icons.payments,
                          color: pendingPayments.isEmpty
                              ? Colors.grey
                              : Colors.green),
                      label: Text("Paiements (${pendingPayments.length})"),
                      onPressed: pendingPayments.isEmpty
                          ? null
                          : _showPendingPaymentsDialog,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(Icons.person_add,
                          color: pendingRegistrations.isEmpty
                              ? Colors.grey
                              : Colors.indigo),
                      label: Text("Inscriptions (${pendingRegistrations.length})"),
                      onPressed: pendingRegistrations.isEmpty
                          ? null
                          : _showPendingRegistrationsDialog,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(Icons.receipt_long,
                          color: pendingAutresFrais.isEmpty
                              ? Colors.grey
                              : Colors.teal),
                      label: Text("Autres frais (${pendingAutresFrais.length})"),
                      onPressed: pendingAutresFrais.isEmpty
                          ? null
                          : _showPendingAutresFraisDialog,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),

              const Text(
                "Utilisateurs Connectés",
                style:
                TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ...connectedUsers.map(
                    (user) => Card(
                  child: ListTile(
                    leading:
                    const Icon(Icons.person, color: Colors.green),
                    title: Text(user),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => _removeUser(user),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),

              Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    totalPendingCount > 0
                        ? "$totalPendingCount élément(s) envoyé(s) par les "
                        "sous-utilisateurs sont en attente (paiements, "
                        "inscriptions, autres frais).\n\n"
                        "Utilisez les boutons ci-dessus pour les voir et "
                        "les valider. Les reçus sont imprimés "
                        "automatiquement (un seul par élève) dès qu'une "
                        "imprimante est configurée."
                        : "Tout ce qui est envoyé par les sous-utilisateurs "
                        "(paiements, inscriptions, autres frais) apparaît "
                        "ici en attente de validation manuelle, que ce "
                        "soit en mode local ou via internet.",
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}