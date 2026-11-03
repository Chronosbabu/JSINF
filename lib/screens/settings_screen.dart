import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import '../frais_scolaires.dart';
import '../app_state.dart';
import '../models.dart';
import '../services/epson_printer_service.dart';
import 'recovery_screen.dart';
import 'aide.dart';
import 'grille_frais_screen.dart';

class _ExceptionDraft {
  final Eleve eleve;
  bool tousLesMois;
  final Set<String> mois;
  final TextEditingController montantController;

  _ExceptionDraft({
    required this.eleve,
    required this.tousLesMois,
    Set<String>? mois,
    String montant = '',
  })  : mois = mois ?? <String>{},
        montantController = TextEditingController(text: montant);
}

class SettingsScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const SettingsScreen({super.key, required this.fraisScolaires});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final nameController = TextEditingController();
  final feeController = TextEditingController();
  String? selectedYear;

  String? selectedSectionForFee;
  String? selectedClasseScopeForFee;
  String? selectedSectionForException;
  String? selectedMonthForException;
  String? selectedClasseScopeForException;
  final TextEditingController newClasseController = TextEditingController();

  final TextEditingController eleveExceptionSearchController =
  TextEditingController();
  List<Eleve> _resultatsRechercheEleveException = [];
  final List<_ExceptionDraft> _brouillonsException = [];

  List<String> _availablePrinters = [];
  String? _selectedPrinterName;
  bool _loadingPrinters = false;
  bool _testingPrint = false;

  Uint8List? _logoBytes;
  bool _loadingLogo = false;

  bool _showBackupReminder = true;

  @override
  void initState() {
    super.initState();
    nameController.text = widget.fraisScolaires.config.schoolName;
    selectedYear = widget.fraisScolaires.currentYear;
    selectedSectionForFee = widget.fraisScolaires.config.sections.isNotEmpty
        ? widget.fraisScolaires.config.sections.first
        : null;
    _loadPrinterConfig();
    _loadSavedLogo();
  }

  @override
  void dispose() {
    eleveExceptionSearchController.dispose();
    for (final d in _brouillonsException) {
      d.montantController.dispose();
    }
    super.dispose();
  }

  Future<void> _loadPrinterConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('printer_name');
    if (saved != null && saved.isNotEmpty) {
      setState(() => _selectedPrinterName = saved);
    }
  }

  void _openAide() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const AideScreen()));
  }

  void _openGrilleFrais() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            GrilleFraisScreen(fraisScolaires: widget.fraisScolaires),
      ),
    );
  }

  Future<bool> _verifyBackupPassword() async {
    final appState = Provider.of<AppState>(context, listen: false);
    if (appState.backupPassword == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
            Text("Veuillez d'abord définir un mot de passe de sauvegarde")),
      );
      return false;
    }

    final passController = TextEditingController();
    bool? isCorrect = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Vérification de Sécurité"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Entrez votre mot de passe de sauvegarde pour continuer"),
            const SizedBox(height: 15),
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
              child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              if (passController.text.trim() == appState.backupPassword) {
                Navigator.pop(ctx, true);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Mot de passe incorrect")),
                );
              }
            },
            child: const Text("Confirmer"),
          ),
        ],
      ),
    );
    return isCorrect ?? false;
  }

  Future<String?> _askRecalculMode(BuildContext context) async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Comment recalculer les paiements ?"),
        content: const Text(
          "Le nouveau montant est plus bas que l'ancien pour au moins un "
              "mois concerné.\n\n"
              "• Intelligent (habituel) : reprend le total déjà payé par "
              "chaque élève sur toute l'année et le redistribue selon les "
              "nouveaux montants — un éventuel excédent peut compléter "
              "automatiquement les mois suivants.\n\n"
              "• Constant : ne touche QUE le(s) mois dont le montant a "
              "baissé. Si un élève avait déjà payé plus que le nouveau "
              "montant pour ce mois, son paiement est simplement ramené à "
              "ce nouveau montant (le mois reste coché comme payé) — le "
              "reste n'est PAS reporté automatiquement sur les autres mois.",
          style: TextStyle(fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'intelligent'),
            child: const Text("Intelligent"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'constant'),
            child: const Text("Constant"),
          ),
        ],
      ),
    );
  }

  void _saveSchoolName() async {
    final newName = nameController.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Le nom ne peut pas être vide")),
      );
      return;
    }
    widget.fraisScolaires.config.schoolName = newName;
    await widget.fraisScolaires.saveData();
    final appState = Provider.of<AppState>(context, listen: false);
    await appState.updateSchoolName(newName);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                "✅ Nom de l'école enregistré — il sera utilisé sur les "
                    "prochains PDF et reçus imprimés")),
      );
    }
  }

  void _changeBackupPassword(BuildContext context, AppState appState) async {
    if (appState.backupPassword == null) {
      _setBackupPassword(context, appState);
      return;
    }

    final oldPassController = TextEditingController();
    bool? oldCorrect = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Changer le mot de passe"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Entrez votre ancien mot de passe"),
            const SizedBox(height: 10),
            TextField(
              controller: oldPassController,
              obscureText: true,
              decoration: const InputDecoration(labelText: "Ancien mot de passe"),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              if (oldPassController.text.trim() == appState.backupPassword) {
                Navigator.pop(ctx, true);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Ancien mot de passe incorrect")),
                );
              }
            },
            child: const Text("Continuer"),
          ),
        ],
      ),
    );

    if (oldCorrect != true) return;

    final newPassController = TextEditingController();
    final confirmPassController = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Nouveau mot de passe"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: newPassController,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: "Nouveau mot de passe (min 6 caractères)"),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirmPassController,
              obscureText: true,
              decoration:
              const InputDecoration(labelText: "Confirmer le nouveau mot de passe"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              final newPass = newPassController.text.trim();
              final confirmPass = confirmPassController.text.trim();
              if (newPass.length < 6) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content:
                      Text("Le mot de passe doit contenir au moins 6 caractères")),
                );
                return;
              }
              if (newPass != confirmPass) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text("Les deux mots de passe ne correspondent pas")),
                );
                return;
              }
              appState.setBackupPassword(newPass);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("✅ Mot de passe changé avec succès")),
              );
            },
            child: const Text("Enregistrer"),
          ),
        ],
      ),
    );
  }

  void _deconnexion() async {
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 8),
            Text("Déconnexion"),
          ],
        ),
        content: const Text(
          "⚠️ ATTENTION — La déconnexion va supprimer TOUTES les données "
              "locales de votre PC (élèves, paiements, configuration).\n\n"
              "Pour ne pas perdre vos données, vous devez absolument les "
              "sauvegarder sur le serveur avant de vous déconnecter.\n\n"
              "Que voulez-vous faire ?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text("Annuler"),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.cloud_upload),
            label: const Text("Sauvegarder puis déconnecter"),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, 'save_then_logout'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text("Déconnecter sans sauvegarder"),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, 'logout_only'),
          ),
        ],
      ),
    );

    if (action == null || action == 'cancel') return;

    if (action == 'save_then_logout') {
      final appState = Provider.of<AppState>(context, listen: false);
      if (appState.schoolCode == null || appState.backupPassword == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content:
                Text("Impossible de sauvegarder : code école ou mot de passe manquant")),
          );
        }
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("⏳ Sauvegarde en cours..."),
              duration: Duration(seconds: 2)),
        );
      }

      final backupResult = await widget.fraisScolaires
          .backupToServer(appState.schoolCode!, appState.backupPassword!);
      final bool backupSuccess = backupResult['success'] == true;

      if (!backupSuccess) {
        if (mounted) {
          final String errMsg = backupResult['error']?.toString() ?? "Erreur inconnue";
          final forceLogout = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text("Échec de la sauvegarde"),
              content: Text(
                "La sauvegarde sur le serveur a échoué :\n$errMsg\n\n"
                    "Voulez-vous quand même vous déconnecter ?\n"
                    "(Vos données locales seront perdues)",
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text("Annuler")),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red, foregroundColor: Colors.white),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text("Déconnecter quand même"),
                ),
              ],
            ),
          );
          if (forceLogout != true) return;
        } else {
          return;
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("✅ Sauvegarde réussie ! Résumé promoteur mis à jour."),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    await widget.fraisScolaires.clearLocalData();

    if (mounted) {
      final appState = Provider.of<AppState>(context, listen: false);
      await appState.logout();
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const RecoveryScreen()),
            (route) => false,
      );
    }
  }

  Future<void> _detectPrinters() async {
    setState(() => _loadingPrinters = true);
    final printers = await EscPosPrinterService.getAvailablePrinters();
    setState(() {
      _availablePrinters = printers;
      _loadingPrinters = false;
      if (_selectedPrinterName != null &&
          !_availablePrinters.contains(_selectedPrinterName)) {
        _availablePrinters.insert(0, _selectedPrinterName!);
      }
    });
    if (printers.isEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Aucune imprimante détectée. Vérifiez que l'Epson TM-T20III "
                  "est branchée en USB et que son pilote est installé "
                  "(elle doit apparaître dans \"Imprimantes et scanners\" "
                  "de Windows)."),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _saveSelectedPrinter(String printerName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('printer_name', printerName);
    setState(() => _selectedPrinterName = printerName);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("✅ Imprimante \"$printerName\" sauvegardée")),
      );
    }
  }

  Future<String> _logoFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/school_logo.png';
  }

  Future<void> _loadSavedLogo() async {
    final prefs = await SharedPreferences.getInstance();
    final hasLogo = prefs.getBool('has_logo') ?? false;
    if (!hasLogo) return;
    try {
      final path = await _logoFilePath();
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (mounted) setState(() => _logoBytes = bytes);
      }
    } catch (_) {}
  }

  Future<void> _pickLogo() async {
    setState(() => _loadingLogo = true);
    try {
      const typeGroup =
      XTypeGroup(label: 'images', extensions: ['png', 'jpg', 'jpeg']);
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) {
        setState(() => _loadingLogo = false);
        return;
      }

      final rawBytes = await file.readAsBytes();
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) {
        setState(() => _loadingLogo = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("⚠️ Image invalide ou format non supporté")),
          );
        }
        return;
      }

      final pngBytes = Uint8List.fromList(img.encodePng(decoded));
      final path = await _logoFilePath();
      await File(path).writeAsBytes(pngBytes);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_logo', true);

      setState(() {
        _logoBytes = pngBytes;
        _loadingLogo = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✅ Logo enregistré — il apparaîtra sur les prochains reçus"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _loadingLogo = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("⚠️ Erreur lors de la sélection du logo : $e")),
        );
      }
    }
  }

  Future<void> _removeLogo() async {
    try {
      final path = await _logoFilePath();
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_logo', false);
    setState(() => _logoBytes = null);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Logo retiré")),
      );
    }
  }

  Future<void> _testPrint() async {
    if (_selectedPrinterName == null) return;
    setState(() => _testingPrint = true);
    final ok = await EscPosPrinterService.printReceipt(
      printerName: _selectedPrinterName!,
      schoolName: widget.fraisScolaires.config.schoolName,
      currentYear: widget.fraisScolaires.currentYear,
      studentName: 'TEST ELEVE',
      studentId: 'TEST-001',
      classe: '7eme A',
      section: 'Secondaire',
      moisPaye: 'Septembre',
      montantPaye: 35000,
      montantRequis: 35000,
      resteAPayerMois: 0,
      totalDejaPayeAnnee: 35000,
      totalRequis: 350000,
      historiqueTransactions: [
        {
          'date': DateTime.now().toString().split(' ')[0],
          'mois': 'Septembre',
          'amount': 35000,
        }
      ],
      logoBytes: _logoBytes,
    );
    setState(() => _testingPrint = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? "✅ Page de test imprimée avec succès"
              : "❌ Échec — vérifiez que l'Epson TM-T20III est allumée, "
              "branchée en USB, et bien sélectionnée ci-dessus "
              "($_selectedPrinterName)"),
          backgroundColor: ok ? Colors.green : Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  String _autreFraisScopeLabel(AutreFrais f) {
    switch (f.scope) {
      case 'section':
        return "Section : ${f.section ?? ''}";
      case 'classe':
        return "Classe : ${f.classe ?? ''}";
      default:
        return "Toutes les classes (toute l'école)";
    }
  }

  void _showAddAutreFraisDialog() async {
    if (!await _verifyBackupPassword()) return;

    final nomController = TextEditingController();
    final montantController = TextEditingController();
    String? dialogSection;
    String? dialogClasse;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final classesOptions = dialogSection != null
              ? widget.fraisScolaires.getClassesForSection(dialogSection!)
              : <String>[];
          return AlertDialog(
            title: const Text("Nouveau Frais Additionnel"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nomController,
                    decoration: const InputDecoration(
                      labelText: "Nom du frais",
                      hintText: "Ex: Frais de l'État, Frais d'Aide...",
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: montantController,
                    keyboardType: TextInputType.number,
                    decoration:
                    const InputDecoration(labelText: "Montant par défaut (FC)"),
                  ),
                  const SizedBox(height: 6),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Ce montant par défaut s'applique à tout élève "
                          "éligible. Vous pourrez ensuite définir des "
                          "montants différents par section ou par classe "
                          "depuis le bouton \"Montants par section/classe\" "
                          "(icône ⚙) dans la liste ci-dessous, sans changer "
                          "l'éligibilité de ce frais.",
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Ce frais concerne :",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 6),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: dialogSection,
                    hint: const Text("Toutes les classes (toute l'école)"),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text("Toutes les classes (toute l'école)"),
                      ),
                      ...widget.fraisScolaires.config.sections.map(
                            (s) => DropdownMenuItem(value: s, child: Text("Section : $s")),
                      ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      dialogSection = value;
                      dialogClasse = null;
                    }),
                  ),
                  if (dialogSection != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: dialogClasse,
                        hint: const Text("Toutes les classes de cette section"),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text("Toutes les classes de cette section"),
                          ),
                          ...classesOptions
                              .map((c) => DropdownMenuItem(value: c, child: Text(c))),
                        ],
                        onChanged: (value) =>
                            setDialogState(() => dialogClasse = value),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
              ElevatedButton(
                onPressed: () async {
                  final nom = nomController.text.trim();
                  final montant = double.tryParse(montantController.text);
                  if (nom.isEmpty || montant == null || montant <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text("Veuillez entrer un nom et un montant valides")),
                    );
                    return;
                  }
                  final scope =
                  dialogSection == null ? 'all' : (dialogClasse == null ? 'section' : 'classe');
                  await widget.fraisScolaires.addAutreFrais(
                    nom: nom,
                    montant: montant,
                    scope: scope,
                    section: dialogSection,
                    classe: dialogClasse,
                  );
                  if (mounted) {
                    Navigator.pop(ctx);
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("✅ Frais ajouté avec succès")),
                    );
                  }
                },
                child: const Text("Ajouter"),
              ),
            ],
          );
        },
      ),
    );
  }

  void _editAutreFraisDialog(AutreFrais frais) async {
    if (!await _verifyBackupPassword()) return;

    final nomController = TextEditingController(text: frais.nom);
    final montantController = TextEditingController(text: frais.montant.toString());
    String? dialogSection = frais.scope == 'all' ? null : frais.section;
    String? dialogClasse = frais.scope == 'classe' ? frais.classe : null;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final classesOptions = dialogSection != null
              ? widget.fraisScolaires.getClassesForSection(dialogSection!)
              : <String>[];
          return AlertDialog(
            title: const Text("Modifier le Frais Additionnel"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nomController,
                    decoration: const InputDecoration(labelText: "Nom du frais"),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: montantController,
                    keyboardType: TextInputType.number,
                    decoration:
                    const InputDecoration(labelText: "Montant par défaut (FC)"),
                  ),
                  const SizedBox(height: 16),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Ce frais concerne :",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 6),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: dialogSection,
                    hint: const Text("Toutes les classes (toute l'école)"),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text("Toutes les classes (toute l'école)"),
                      ),
                      ...widget.fraisScolaires.config.sections.map(
                            (s) => DropdownMenuItem(value: s, child: Text("Section : $s")),
                      ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      dialogSection = value;
                      dialogClasse = null;
                    }),
                  ),
                  if (dialogSection != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: dialogClasse,
                        hint: const Text("Toutes les classes de cette section"),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text("Toutes les classes de cette section"),
                          ),
                          ...classesOptions
                              .map((c) => DropdownMenuItem(value: c, child: Text(c))),
                        ],
                        onChanged: (value) =>
                            setDialogState(() => dialogClasse = value),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
              ElevatedButton(
                onPressed: () async {
                  final nom = nomController.text.trim();
                  final montant = double.tryParse(montantController.text);
                  if (nom.isEmpty || montant == null || montant <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text("Veuillez entrer un nom et un montant valides")),
                    );
                    return;
                  }
                  final scope =
                  dialogSection == null ? 'all' : (dialogClasse == null ? 'section' : 'classe');
                  await widget.fraisScolaires.updateAutreFrais(
                    frais.id,
                    nom: nom,
                    montant: montant,
                    scope: scope,
                    section: dialogSection,
                    classe: dialogClasse,
                  );
                  if (mounted) {
                    Navigator.pop(ctx);
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("✅ Frais modifié avec succès")),
                    );
                  }
                },
                child: const Text("Enregistrer"),
              ),
            ],
          );
        },
      ),
    );
  }

  void _manageMontantsAutreFrais(AutreFrais frais) async {
    if (!await _verifyBackupPassword()) return;
    _showManageMontantsDialog(frais);
  }

  void _showManageMontantsDialog(AutreFrais frais) {
    final montantSectionController = TextEditingController();
    final montantClasseController = TextEditingController();
    String? sectionPourSection;
    String? sectionPourClasse;
    String? classePourClasse;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final classesOptionsPourClasse = sectionPourClasse != null
              ? widget.fraisScolaires.getClassesForSection(sectionPourClasse!)
              : <String>[];

          Future<void> refresh() async {
            setDialogState(() {});
            if (mounted) setState(() {});
          }

          return AlertDialog(
            title: Text("Montants par Section/Classe — ${frais.nom}"),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Montant par défaut : ${frais.montant.toStringAsFixed(0)} FC",
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      "S'applique à tout élève éligible qui n'a AUCUNE "
                          "exception ci-dessous. L'éligibilité (qui doit "
                          "payer ce frais) ne change pas ici — elle reste "
                          "définie dans \"Modifier le Frais\".",
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      "Montant spécifique par Section",
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13, color: Colors.indigo),
                    ),
                    const SizedBox(height: 6),
                    if (frais.montantsParSection.isEmpty)
                      const Text(
                        "Aucune exception par section pour ce frais.",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      )
                    else
                      ...frais.montantsParSection.entries.map(
                            (e) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(e.key),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text("${e.value.toStringAsFixed(0)} FC"),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.red),
                                tooltip: "Retirer cette exception",
                                onPressed: () async {
                                  await widget.fraisScolaires
                                      .removeMontantSectionPourAutreFrais(frais.id, e.key);
                                  await refresh();
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          flex: 2,
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: sectionPourSection,
                            hint: const Text("Choisir une section"),
                            items: widget.fraisScolaires.config.sections
                                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                                .toList(),
                            onChanged: (v) => setDialogState(() => sectionPourSection = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 1,
                          child: TextField(
                            controller: montantSectionController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: "Montant (FC)"),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle, color: Colors.indigo),
                          tooltip: "Ajouter / Remplacer",
                          onPressed: () async {
                            final montant =
                            double.tryParse(montantSectionController.text.trim());
                            if (sectionPourSection == null || montant == null || montant <= 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text("Choisissez une section et un montant valides")),
                              );
                              return;
                            }
                            await widget.fraisScolaires.setMontantSectionPourAutreFrais(
                                frais.id, sectionPourSection!, montant);
                            montantSectionController.clear();
                            await refresh();
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 30),
                    const Text(
                      "Montant spécifique par Classe (priorité absolue)",
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13, color: Colors.indigo),
                    ),
                    const SizedBox(height: 6),
                    if (frais.montantsParClasse.isEmpty)
                      const Text(
                        "Aucune exception par classe pour ce frais.",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      )
                    else
                      ...frais.montantsParClasse.entries.map((e) {
                        final parts = e.key.split('|');
                        final label = parts.length == 2 ? "${parts[0]} - ${parts[1]}" : e.key;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(label),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text("${e.value.toStringAsFixed(0)} FC"),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.red),
                                tooltip: "Retirer cette exception",
                                onPressed: () async {
                                  if (parts.length == 2) {
                                    await widget.fraisScolaires
                                        .removeMontantClassePourAutreFrais(
                                        frais.id, parts[0], parts[1]);
                                    await refresh();
                                  }
                                },
                              ),
                            ],
                          ),
                        );
                      }),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: sectionPourClasse,
                            hint: const Text("Section"),
                            items: widget.fraisScolaires.config.sections
                                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                                .toList(),
                            onChanged: (v) => setDialogState(() {
                              sectionPourClasse = v;
                              classePourClasse = null;
                            }),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: classePourClasse,
                            hint: const Text("Classe"),
                            items: classesOptionsPourClasse
                                .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                                .toList(),
                            onChanged: (v) => setDialogState(() => classePourClasse = v),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: montantClasseController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: "Montant (FC)"),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.add_circle, color: Colors.indigo),
                          tooltip: "Ajouter / Remplacer",
                          onPressed: () async {
                            final montant =
                            double.tryParse(montantClasseController.text.trim());
                            if (sectionPourClasse == null ||
                                classePourClasse == null ||
                                montant == null ||
                                montant <= 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content:
                                    Text("Choisissez section + classe et un montant valides")),
                              );
                              return;
                            }
                            await widget.fraisScolaires.setMontantClassePourAutreFrais(
                              frais.id,
                              sectionPourClasse!,
                              classePourClasse!,
                              montant,
                            );
                            montantClasseController.clear();
                            await refresh();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Fermer")),
            ],
          );
        },
      ),
    );
  }

  void _deleteAutreFrais(AutreFrais frais) async {
    if (!await _verifyBackupPassword()) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Supprimer ce frais ?"),
        content: Text(
          "Voulez-vous vraiment supprimer \"${frais.nom}\" ?\n\n"
              "Les paiements déjà enregistrés pour ce frais resteront "
              "dans l'historique, mais il ne sera plus proposé pour de "
              "nouveaux paiements.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Supprimer"),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await widget.fraisScolaires.deleteAutreFrais(frais.id);
      if (mounted) setState(() {});
    }
  }

  void _renameClasseNumeroDialog(String section, String oldNumero) async {
    if (!await _verifyBackupPassword()) return;

    final controller = TextEditingController(text: oldNumero);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Renommer \"$oldNumero\""),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: "Nouveau nom de la classe"),
            ),
            const SizedBox(height: 10),
            const Text(
              "Ce changement sera appliqué immédiatement à tous les élèves "
                  "déjà inscrits dans cette classe (année en cours et années "
                  "précédentes), ainsi qu'aux frais, exceptions et \"Autres "
                  "Frais\" (éligibilité ciblée ou montant spécifique) déjà "
                  "configurés pour elle.",
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Le nom ne peut pas être vide")),
                );
                return;
              }
              await widget.fraisScolaires.renameClasseNumero(section, oldNumero, newName);
              if (mounted) {
                Navigator.pop(ctx);
                setState(() {
                  if (selectedClasseScopeForFee == oldNumero) {
                    selectedClasseScopeForFee = newName;
                  }
                  if (selectedClasseScopeForException == oldNumero) {
                    selectedClasseScopeForException = newName;
                  }
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        "✅ Classe renommée en \"$newName\" — mis à jour partout dans l'application"),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
            child: const Text("Renommer"),
          ),
        ],
      ),
    );
  }

  void _deleteClasseNumeroDialog(String section, String numero) async {
    if (!await _verifyBackupPassword()) return;

    final result = await widget.fraisScolaires.deleteClasseNumero(section, numero);

    if (result['success'] == true) {
      if (mounted) {
        setState(() {
          if (selectedClasseScopeForFee == numero) selectedClasseScopeForFee = null;
          if (selectedClasseScopeForException == numero) {
            selectedClasseScopeForException = null;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Classe supprimée")),
        );
      }
      return;
    }

    final int studentCount = result['studentCount'] as int? ?? 0;
    final int autresFraisCount = result['autresFraisCount'] as int? ?? 0;
    if (!mounted) return;

    final List<String> impacts = [];
    if (studentCount > 0) {
      impacts.add(
        "• $studentCount élève(s) sont actuellement dans la classe "
            "\"$numero\" (année en cours ou années précédentes). Si vous "
            "supprimez cette classe, elle n'apparaîtra plus dans les "
            "listes de choix, mais ces élèves garderont \"$numero\" comme "
            "classe jusqu'à ce que vous les réaffectiez manuellement (ou "
            "que vous renommiez cette classe au lieu de la supprimer).",
      );
    }
    if (autresFraisCount > 0) {
      impacts.add(
        "• $autresFraisCount \"Autre(s) Frais\" référencent précisément "
            "cette classe (éligibilité \"cette classe précise\" et/ou "
            "montant spécifique défini pour elle). Après suppression, un "
            "frais ciblé sur \"$numero\" retombera automatiquement sur "
            "toute la section \"$section\" (au lieu de ne s'appliquer à "
            "personne), et tout montant spécifique déjà défini pour cette "
            "classe précise sera retiré.",
      );
    }

    final forceDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Classe non vide"),
        content: Text("${impacts.join('\n\n')}\n\nVoulez-vous continuer ?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Supprimer quand même"),
          ),
        ],
      ),
    );

    if (forceDelete == true) {
      await widget.fraisScolaires.deleteClasseNumero(section, numero, force: true);
      if (mounted) {
        setState(() {
          if (selectedClasseScopeForFee == numero) selectedClasseScopeForFee = null;
          if (selectedClasseScopeForException == numero) {
            selectedClasseScopeForException = null;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Classe supprimée")),
        );
      }
    }
  }

  void _rechercherElevesPourException(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _resultatsRechercheEleveException = [];
      } else {
        final dejaChoisis = _brouillonsException.map((d) => d.eleve.id).toSet();
        _resultatsRechercheEleveException = widget
            .fraisScolaires.currentData.eleves
            .where((e) =>
        !dejaChoisis.contains(e.id) &&
            ('${e.nom} ${e.postNom} ${e.prenom}'.toLowerCase().contains(q) ||
                e.id.toLowerCase().contains(q)))
            .take(15)
            .toList();
      }
    });
  }

  void _ajouterBrouillonException(Eleve eleve) {
    if (_brouillonsException.any((d) => d.eleve.id == eleve.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Cet élève est déjà dans la liste en cours de modification")),
      );
      return;
    }
    bool tousLesMois = true;
    Set<String> mois = <String>{};
    String montant = '';
    if (eleve.exceptionsMoisPersonnalisees.isNotEmpty) {
      tousLesMois = false;
      mois = eleve.exceptionsMoisPersonnalisees.keys.toSet();
      final valeurs = eleve.exceptionsMoisPersonnalisees.values.toSet();
      if (valeurs.length == 1) {
        montant = valeurs.first.toStringAsFixed(0);
      }
    } else if (eleve.montantMensuelPersonnalise != null) {
      montant = eleve.montantMensuelPersonnalise!.toStringAsFixed(0);
    }
    setState(() {
      _brouillonsException.add(_ExceptionDraft(
        eleve: eleve,
        tousLesMois: tousLesMois,
        mois: mois,
        montant: montant,
      ));
      eleveExceptionSearchController.clear();
      _resultatsRechercheEleveException = [];
    });
  }

  void _retirerBrouillonException(_ExceptionDraft draft) {
    setState(() {
      _brouillonsException.remove(draft);
    });
    draft.montantController.dispose();
  }

  Future<void> _enregistrerBrouillonsException() async {
    if (_brouillonsException.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Veuillez d'abord rechercher et ajouter au moins un élève")),
      );
      return;
    }

    final List<Map<String, dynamic>> lot = [];
    final List<MapEntry<Eleve, double>> montantsGlobaux = [];

    for (final d in _brouillonsException) {
      final nomComplet = '${d.eleve.nom} ${d.eleve.postNom} ${d.eleve.prenom}';
      final montant = double.tryParse(d.montantController.text.trim());
      if (montant == null || montant < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                "Montant invalide pour $nomComplet (entrez 0 pour un mois gratuit)"),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      if (d.tousLesMois) {
        if (montant > 0) {
          montantsGlobaux.add(MapEntry(d.eleve, montant));
        } else {
          lot.add({
            'eleve': d.eleve,
            'exceptions': <String, double>{
              for (final m in widget.fraisScolaires.months) m: 0.0,
            },
          });
        }
      } else {
        if (d.mois.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Choisissez au moins un mois pour $nomComplet"),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        lot.add({
          'eleve': d.eleve,
          'exceptions': <String, double>{
            for (final m in d.mois) m: montant,
          },
        });
      }
    }

    if (!await _verifyBackupPassword()) return;

    for (final entree in montantsGlobaux) {
      await widget.fraisScolaires
          .setMontantMensuelPersonnalise(entree.key, entree.value);
    }
    if (lot.isNotEmpty) {
      await widget.fraisScolaires.setExceptionsMoisPourPlusieursEleves(lot);
    }

    final int total = _brouillonsException.length;
    for (final d in _brouillonsException) {
      d.montantController.dispose();
    }

    if (mounted) {
      setState(() {
        _brouillonsException.clear();
        eleveExceptionSearchController.clear();
        _resultatsRechercheEleveException = [];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ Exceptions enregistrées pour $total élève(s). Leurs paiements "
                "déjà enregistrés ont été recalculés automatiquement pour "
                "rester cohérents.",
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _retirerToutesExceptionsEleve(Eleve eleve) async {
    if (!await _verifyBackupPassword()) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Retirer les exceptions ?"),
        content: Text(
          "Voulez-vous vraiment retirer toutes les exceptions de paiement de "
              "${eleve.nom} ${eleve.postNom} ${eleve.prenom} (montant "
              "personnalisé et exceptions par mois) ?\n\n"
              "Il repaiera ensuite le montant normal de sa section/classe, "
              "et ses paiements déjà enregistrés seront recalculés "
              "automatiquement selon ce montant normal.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Retirer"),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await widget.fraisScolaires.setMontantMensuelPersonnalise(eleve, null);
      await widget.fraisScolaires.removeToutesExceptionsMoisPourEleve(eleve);
      if (mounted) {
        final brouillons =
        _brouillonsException.where((d) => d.eleve.id == eleve.id).toList();
        setState(() {
          for (final d in brouillons) {
            _brouillonsException.remove(d);
          }
        });
        for (final d in brouillons) {
          d.montantController.dispose();
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  "Exceptions retirées — l'élève repaie le montant normal de sa section/classe")),
        );
      }
    }
  }

  Future<void> _retirerExceptionMois(Eleve eleve, String mois) async {
    if (!await _verifyBackupPassword()) return;
    await widget.fraisScolaires.removeExceptionMoisPourEleve(eleve, mois);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Exception de $mois retirée pour ${eleve.nom} ${eleve.prenom}")),
      );
    }
  }

  Widget _buildBrouillonException(_ExceptionDraft d) {
    final nomComplet = '${d.eleve.nom} ${d.eleve.postNom} ${d.eleve.prenom}';
    return Card(
      key: ValueKey('draft_${d.eleve.id}'),
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.person, color: Colors.indigo, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$nomComplet (${d.eleve.classe} - ${d.eleve.section})',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.indigo),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: "Retirer de la liste",
                  onPressed: () => _retirerBrouillonException(d),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text("Tous les mois"),
                  selected: d.tousLesMois,
                  onSelected: (_) => setState(() => d.tousLesMois = true),
                ),
                ChoiceChip(
                  label: const Text("Certains mois"),
                  selected: !d.tousLesMois,
                  onSelected: (_) => setState(() => d.tousLesMois = false),
                ),
              ],
            ),
            if (!d.tousLesMois) ...[
              const SizedBox(height: 8),
              const Text(
                "Cochez le ou les mois concernés (les autres mois restent au "
                    "montant normal de la section/classe) :",
                style: TextStyle(fontSize: 11.5, color: Colors.grey),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: widget.fraisScolaires.months
                    .map((m) => FilterChip(
                  label: Text(m),
                  selected: d.mois.contains(m),
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      d.mois.add(m);
                    } else {
                      d.mois.remove(m);
                    }
                  }),
                ))
                    .toList(),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: d.montantController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: d.tousLesMois
                    ? "Montant mensuel fixe pour tous les mois (FC)"
                    : "Montant pour les mois cochés (FC)",
                helperText: "Entrez 0 pour rendre le mois gratuit (rien à payer)",
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCarteEleveException(Eleve e) {
    final moisConcernes = widget.fraisScolaires.months
        .where((m) => e.exceptionsMoisPersonnalisees.containsKey(m))
        .toList();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.star, color: Colors.indigo),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${e.nom} ${e.postNom} ${e.prenom}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('${e.classe} - ${e.section}',
                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 18, color: Colors.blue),
                  tooltip: "Modifier",
                  onPressed: () => _ajouterBrouillonException(e),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                  tooltip: "Retirer toutes les exceptions",
                  onPressed: () => _retirerToutesExceptionsEleve(e),
                ),
              ],
            ),
            if (e.montantMensuelPersonnalise != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  "Tous les mois : ${e.montantMensuelPersonnalise!.toStringAsFixed(0)} FC/mois"
                      "${moisConcernes.isNotEmpty ? ' (sauf les mois précisés ci-dessous)' : ''}",
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.indigo, fontSize: 12.5),
                ),
              ),
            if (moisConcernes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: moisConcernes.map((m) {
                    final v = e.exceptionsMoisPersonnalisees[m] ?? 0;
                    return InputChip(
                      label: Text(v <= 0
                          ? "$m : Gratuit"
                          : "$m : ${v.toStringAsFixed(0)} FC"),
                      onDeleted: () => _retirerExceptionMois(e, m),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _addOptionDialog() async {
    if (!await _verifyBackupPassword()) return;
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Nouvelle Option"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: "Nom de l'option",
                hintText: "Ex : Technique",
              ),
            ),
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Vous pourrez ensuite y imbriquer les sections que vous "
                    "voulez regrouper (icône ⚙ \"Gérer les sections\" une "
                    "fois l'option créée).",
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () async {
              final nom = controller.text.trim();
              final erreur = await widget.fraisScolaires.addOption(nom);
              if (erreur != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(erreur)),
                );
                return;
              }
              if (mounted) {
                Navigator.pop(ctx);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("✅ Option \"$nom\" créée")),
                );
              }
            },
            child: const Text("Créer"),
          ),
        ],
      ),
    );
  }

  void _renameOptionDialog(String option) async {
    if (!await _verifyBackupPassword()) return;
    final controller = TextEditingController(text: option);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Renommer \"$option\""),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: "Nouveau nom de l'option"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () async {
              final nouveau = controller.text.trim();
              final erreur =
              await widget.fraisScolaires.renameOption(option, nouveau);
              if (erreur != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(erreur)),
                );
                return;
              }
              if (mounted) {
                Navigator.pop(ctx);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("✅ Option renommée")),
                );
              }
            },
            child: const Text("Renommer"),
          ),
        ],
      ),
    );
  }

  void _deleteOptionDialog(String option) async {
    if (!await _verifyBackupPassword()) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Supprimer cette option ?"),
        content: Text(
          "Voulez-vous vraiment supprimer l'option \"$option\" ?\n\n"
              "Les sections qu'elle contenait ne sont PAS supprimées : "
              "elles redeviennent simplement des sections \"seules\" dans "
              "les rapports (comme si aucune option n'existait pour elles).",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Supprimer"),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await widget.fraisScolaires.deleteOption(option);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Option supprimée")),
        );
      }
    }
  }

  void _manageOptionSectionsDialog(String option) async {
    if (!await _verifyBackupPassword()) return;

    final Set<String> selection =
    widget.fraisScolaires.getSectionsPourOption(option).toSet();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Text("Sections de l'option \"$option\""),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Cochez toutes les sections que vous voulez imbriquer "
                          "dans cette option. Une section ne peut appartenir "
                          "qu'à une seule option à la fois : si elle est "
                          "déjà dans une autre option, la cocher ici l'en "
                          "retirera automatiquement.",
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 10),
                    if (widget.fraisScolaires.config.sections.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          "Aucune section n'existe encore dans l'école.",
                          style: TextStyle(
                              color: Colors.grey, fontStyle: FontStyle.italic),
                        ),
                      )
                    else
                      ...widget.fraisScolaires.config.sections.map((s) {
                        final autreOption =
                        widget.fraisScolaires.getOptionDeSection(s);
                        final estDansAutreOption =
                            autreOption != null && autreOption != option;
                        return CheckboxListTile(
                          dense: true,
                          value: selection.contains(s),
                          title: Text(s),
                          subtitle: estDansAutreOption
                              ? Text(
                            "Actuellement dans l'option \"$autreOption\"",
                            style: const TextStyle(
                                fontSize: 11, color: Colors.orange),
                          )
                              : null,
                          onChanged: (checked) {
                            setDialogState(() {
                              if (checked == true) {
                                selection.add(s);
                              } else {
                                selection.remove(s);
                              }
                            });
                          },
                        );
                      }),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
              ElevatedButton(
                onPressed: () async {
                  await widget.fraisScolaires
                      .setSectionsPourOption(option, selection.toList());
                  if (mounted) {
                    Navigator.pop(ctx);
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("✅ Sections de l'option mises à jour")),
                    );
                  }
                },
                child: const Text("Enregistrer"),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildOptionsSection() {
    final optionsNoms = widget.fraisScolaires.getOptionsNoms();
    return [
      const Divider(),
      const Text("Options (Regroupement de Sections) — Facultatif",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      const Text(
        "Une option regroupe une ou plusieurs sections déjà créées (ex : "
            "\"Technique\" peut contenir plusieurs sections techniques). "
            "C'est totalement facultatif : si vous n'imbriquez aucune "
            "section dans aucune option, rien ne change dans l'application "
            "ni dans les rapports. Une section ne peut appartenir qu'à une "
            "seule option à la fois. Dès qu'au moins une option contient "
            "des sections, un tableau supplémentaire \"Répartition par "
            "option\" apparaît automatiquement dans les rapports PDF, à "
            "côté du tableau \"Répartition par section\".",
        style: TextStyle(color: Colors.grey, fontSize: 12),
      ),
      const SizedBox(height: 10),
      ElevatedButton.icon(
        icon: const Icon(Icons.add),
        label: const Text("Créer une nouvelle Option"),
        onPressed: _addOptionDialog,
      ),
      const SizedBox(height: 10),
      if (optionsNoms.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            "Aucune option créée pour le moment — les sections apparaissent "
                "chacune seule dans les rapports, comme d'habitude.",
            style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
          ),
        )
      else
        ...optionsNoms.map((option) {
          final sections = widget.fraisScolaires.getSectionsPourOption(option);
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              title: Text(option),
              subtitle: Text(
                sections.isEmpty
                    ? "Aucune section imbriquée pour l'instant"
                    : "Sections imbriquées : ${sections.join(', ')}",
                style: TextStyle(
                  color: sections.isEmpty ? Colors.orange : null,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.tune, color: Colors.teal),
                    tooltip: "Gérer les sections de cette option",
                    onPressed: () => _manageOptionSectionsDialog(option),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.indigo),
                    tooltip: "Renommer l'option",
                    onPressed: () => _renameOptionDialog(option),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    tooltip: "Supprimer l'option",
                    onPressed: () => _deleteOptionDialog(option),
                  ),
                ],
              ),
            ),
          );
        }),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);

    final classesForFeeSection = selectedSectionForFee != null
        ? widget.fraisScolaires.getClassesForSection(selectedSectionForFee!)
        : <String>[];

    final classesForExceptionSection = selectedSectionForException != null
        ? widget.fraisScolaires.getClassesForSection(selectedSectionForException!)
        : <String>[];

    final classFeesForSection = selectedSectionForFee != null
        ? widget.fraisScolaires.config.feesByClasse.entries
        .where((e) => e.key.startsWith("${selectedSectionForFee!}|"))
        .toList()
        : <MapEntry<String, double>>[];

    final autresFraisList = widget.fraisScolaires.getAutresFrais();

    final double totalPourcentAdmins =
    widget.fraisScolaires.getTotalPourcentageAdministrations();
    final bool totalAdminsCorrect = widget.fraisScolaires.config.administrations.isEmpty ||
        (totalPourcentAdmins - 100).abs() < 0.01;

    final double totalPourcentAutresFraisAdmins =
    widget.fraisScolaires.getTotalPourcentageAutresFraisAdministrations();
    final bool totalAutresFraisAdminsCorrect =
        widget.fraisScolaires.autresFraisAdministrations.isEmpty ||
            (totalPourcentAutresFraisAdmins - 100).abs() < 0.01;

    final List<String> sectionsSansFrais =
    widget.fraisScolaires.getSectionsSansFraisConfigure();

    final List<Eleve> elevesAvecExceptionPersonnalisee =
    widget.fraisScolaires.getElevesAvecExceptionPersonnalisee();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Paramètres"),
        actions: [
          IconButton(
            icon: const Icon(Icons.table_chart),
            tooltip: "Grille des Frais",
            onPressed: _openGrilleFrais,
          ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: "Aide",
            onPressed: _openAide,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            if (_showBackupReminder)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade300),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_upload, color: Colors.orange),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        "💡 Sauvegardez régulièrement sur le serveur : cela "
                            "permet aux parents de retrouver leurs enfants, "
                            "sécurise vos données, et met à jour en temps "
                            "réel le résumé consulté par le promoteur.",
                        style: TextStyle(fontSize: 12, color: Colors.orange),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: Colors.orange),
                      onPressed: () => setState(() => _showBackupReminder = false),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: "Nom de l'établissement"),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(onPressed: _saveSchoolName, child: const Text("Enregistrer")),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              "Ce nom apparaît sur les PDF générés et sur les reçus imprimés.",
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            if (appState.schoolCode != null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.indigo.withAlpha(15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: Colors.indigo),
                    const SizedBox(width: 8),
                    Text(
                      "Code école : ${appState.schoolCode}",
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigo),
                    ),
                    const SizedBox(width: 4),
                    const Text("(à retenir pour la reconnexion)",
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            const Text("Gestion des Sections",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("Ajouter une nouvelle Section"),
              onPressed: _addNewSection,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: widget.fraisScolaires.config.sections
                  .map((section) => Chip(
                label: Text(section),
                deleteIcon: const Icon(Icons.close, size: 18),
                onDeleted: () => _removeSection(section),
              ))
                  .toList(),
            ),

            ..._buildOptionsSection(),

            const Divider(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Text("Frais Mensuel par Section ou par Classe",
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.table_chart, size: 18),
                  label: const Text("Voir la grille complète"),
                  onPressed: _openGrilleFrais,
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              "Choisissez \"Toutes les classes\" pour fixer le frais de toute "
                  "la section, ou une classe précise si elle paie un montant différent.",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 10),
            if (sectionsSansFrais.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade300),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "⚠️ Aucun frais mensuel de base n'a jamais été "
                            "défini pour : ${sectionsSansFrais.join(', ')}. "
                            "Ces sections facturent actuellement le montant "
                            "de secours par défaut (35 000 FC) — "
                            "configurez leur vrai montant ci-dessous dès que possible.",
                        style: const TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            DropdownButton<String>(
              value: selectedSectionForFee,
              isExpanded: true,
              items: widget.fraisScolaires.config.sections
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (value) => setState(() {
                selectedSectionForFee = value;
                selectedClasseScopeForFee = null;
              }),
            ),
            const SizedBox(height: 10),
            if (selectedSectionForFee != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: newClasseController,
                        decoration: InputDecoration(
                          labelText: "Ajouter une classe à \"$selectedSectionForFee\"",
                          hintText: "Ex: 1ère, 2ème, Niveau 1...",
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: () async {
                        final value = newClasseController.text.trim();
                        if (value.isEmpty) return;
                        if (!await _verifyBackupPassword()) return;
                        await widget.fraisScolaires
                            .addClasseNumero(selectedSectionForFee!, value);
                        newClasseController.clear();
                        if (mounted) setState(() => selectedClasseScopeForFee = value);
                      },
                      child: const Text("Ajouter"),
                    ),
                  ],
                ),
              ),
            if (selectedSectionForFee != null && classesForFeeSection.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Classes existantes (touchez l'icône crayon pour "
                          "corriger un nom, ou la croix pour supprimer) :",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: classesForFeeSection.map((c) {
                        return Container(
                          padding: const EdgeInsets.only(left: 12, right: 4, top: 2, bottom: 2),
                          decoration: BoxDecoration(
                            color: Colors.indigo.withAlpha(18),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.indigo.shade100),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(c, style: const TextStyle(fontWeight: FontWeight.w500)),
                              const SizedBox(width: 2),
                              IconButton(
                                icon: const Icon(Icons.edit, size: 16, color: Colors.indigo),
                                tooltip: "Renommer cette classe",
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                                onPressed: () =>
                                    _renameClasseNumeroDialog(selectedSectionForFee!, c),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                                tooltip: "Supprimer cette classe",
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                                onPressed: () =>
                                    _deleteClasseNumeroDialog(selectedSectionForFee!, c),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            DropdownButton<String>(
              value: selectedClasseScopeForFee,
              isExpanded: true,
              hint: const Text("Toutes les classes"),
              items: [
                const DropdownMenuItem<String>(value: null, child: Text("Toutes les classes")),
                ...classesForFeeSection.map((c) => DropdownMenuItem(value: c, child: Text(c))),
              ],
              onChanged: (value) => setState(() => selectedClasseScopeForFee = value),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: feeController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: selectedClasseScopeForFee != null
                    ? "Frais mensuel pour ${selectedSectionForFee ?? ''} - $selectedClasseScopeForFee"
                    : "Frais mensuel pour toute la section ${selectedSectionForFee ?? ''}",
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () async {
                if (selectedSectionForFee == null) return;
                if (await _verifyBackupPassword()) {
                  final amount = double.tryParse(feeController.text);
                  if (amount != null) {
                    final Map<String, double> anciensRequis =
                    widget.fraisScolaires.snapshotRequisTousMoisPour(
                      selectedSectionForFee!,
                      selectedClasseScopeForFee,
                    );

                    if (selectedClasseScopeForFee == null) {
                      widget.fraisScolaires.config.feesBySection[selectedSectionForFee!] = amount;
                    } else {
                      final key = "${selectedSectionForFee!}|${selectedClasseScopeForFee!}";
                      widget.fraisScolaires.config.feesByClasse[key] = amount;
                    }
                    await widget.fraisScolaires.saveData();

                    final bool unMoisEstPlusBas = anciensRequis.entries.any((e) =>
                    widget.fraisScolaires.getRequiredForMonth(
                        e.key, selectedSectionForFee!, selectedClasseScopeForFee) < e.value);

                    String mode = 'intelligent';
                    if (unMoisEstPlusBas && mounted) {
                      final choix = await _askRecalculMode(context);
                      if (choix != null) mode = choix;
                    }

                    final int nbRecalcules = mode == 'constant'
                        ? await widget.fraisScolaires.recalculerPaiementsPourModeConstant(
                      section: selectedSectionForFee,
                      classeNumero: selectedClasseScopeForFee,
                      anciensRequisParMois: anciensRequis,
                    )
                        : await widget.fraisScolaires.recalculerPaiementsPour(
                      section: selectedSectionForFee,
                      classeNumero: selectedClasseScopeForFee,
                    );
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(mode == 'constant'
                              ? "✅ Frais mis à jour (mode constant) — "
                              "$nbRecalcules élève(s) ajusté(s) "
                              "uniquement sur le(s) mois concerné(s), "
                              "sans report vers les autres mois"
                              : "✅ Frais mis à jour — $nbRecalcules élève(s) "
                              "recalculé(s) automatiquement pour rester "
                              "cohérents avec le nouveau montant"),
                          backgroundColor: Colors.green,
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    }
                  }
                }
              },
              child: Text(
                selectedClasseScopeForFee == null
                    ? "Enregistrer pour Toute la Section"
                    : "Enregistrer pour $selectedClasseScopeForFee Uniquement",
              ),
            ),
            if (selectedClasseScopeForFee != null &&
                widget.fraisScolaires.config.feesByClasse
                    .containsKey("${selectedSectionForFee}|${selectedClasseScopeForFee}"))
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: Text(
                  "Retirer l'exception pour $selectedClasseScopeForFee",
                  style: const TextStyle(color: Colors.red),
                ),
                onPressed: () async {
                  if (!await _verifyBackupPassword()) return;

                  final Map<String, double> anciensRequis =
                  widget.fraisScolaires.snapshotRequisTousMoisPour(
                    selectedSectionForFee!,
                    selectedClasseScopeForFee,
                  );

                  widget.fraisScolaires.config.feesByClasse
                      .remove("${selectedSectionForFee}|${selectedClasseScopeForFee}");
                  await widget.fraisScolaires.saveData();

                  final bool unMoisEstPlusBas = anciensRequis.entries.any((e) =>
                  widget.fraisScolaires.getRequiredForMonth(
                      e.key, selectedSectionForFee!, selectedClasseScopeForFee) < e.value);

                  String mode = 'intelligent';
                  if (unMoisEstPlusBas && mounted) {
                    final choix = await _askRecalculMode(context);
                    if (choix != null) mode = choix;
                  }

                  final int nbRecalcules = mode == 'constant'
                      ? await widget.fraisScolaires.recalculerPaiementsPourModeConstant(
                    section: selectedSectionForFee,
                    classeNumero: selectedClasseScopeForFee,
                    anciensRequisParMois: anciensRequis,
                  )
                      : await widget.fraisScolaires.recalculerPaiementsPour(
                    section: selectedSectionForFee,
                    classeNumero: selectedClasseScopeForFee,
                  );
                  if (mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(mode == 'constant'
                            ? "Exception retirée (mode constant) — "
                            "$nbRecalcules élève(s) ajusté(s) uniquement "
                            "sur le(s) mois concerné(s)"
                            : "Exception retirée — $nbRecalcules élève(s) "
                            "recalculé(s) automatiquement"),
                      ),
                    );
                  }
                },
              ),
            if (classFeesForSection.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                "Frais spécifiques déjà définis pour cette section :",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              ...classFeesForSection.map((entry) {
                final classeNumero = entry.key.split('|')[1];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(classeNumero),
                  trailing: Text("${entry.value.toStringAsFixed(0)} FC"),
                );
              }),
            ],
            const Divider(),
            const Text("Exceptions par Mois, par Section ou par Classe",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            DropdownButton<String>(
              value: selectedSectionForException,
              hint: const Text("Choisir une section"),
              isExpanded: true,
              items: widget.fraisScolaires.config.sections
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (value) => setState(() {
                selectedSectionForException = value;
                selectedClasseScopeForException = null;
              }),
            ),
            const SizedBox(height: 10),
            DropdownButton<String>(
              value: selectedClasseScopeForException,
              hint: const Text("Toutes les classes"),
              isExpanded: true,
              items: [
                const DropdownMenuItem<String>(value: null, child: Text("Toutes les classes")),
                ...classesForExceptionSection
                    .map((c) => DropdownMenuItem(value: c, child: Text(c))),
              ],
              onChanged: (value) => setState(() => selectedClasseScopeForException = value),
            ),
            const SizedBox(height: 10),
            DropdownButton<String>(
              value: selectedMonthForException,
              hint: const Text("Choisir un mois"),
              isExpanded: true,
              items: widget.fraisScolaires.months
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (value) => setState(() => selectedMonthForException = value),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => _editExceptionForSection(),
              child: const Text("Ajouter / Modifier Exception"),
            ),

            const Divider(),
            const Text("Exception de Paiement par Élève",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              "Pour un ou plusieurs élèves précis qui doivent payer un montant "
                  "différent de celui de leur section/classe (ex: enfant d'un "
                  "enseignant). Recherchez les élèves un par un : chacun est "
                  "ajouté à la liste ci-dessous, et vous choisissez pour lui "
                  "soit \"Tous les mois\", soit un ou plusieurs mois précis "
                  "(les autres mois restent au montant normal). Entrez 0 pour "
                  "qu'un mois soit gratuit. Vous enregistrez ensuite tout "
                  "d'un seul coup.",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: eleveExceptionSearchController,
              decoration: const InputDecoration(
                labelText: "Rechercher un élève (nom ou ID)",
                prefixIcon: Icon(Icons.search),
                hintText: "Ex: BARAKA ou BB26B10",
              ),
              onChanged: _rechercherElevesPourException,
            ),
            if (_resultatsRechercheEleveException.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 6),
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _resultatsRechercheEleveException.length,
                  itemBuilder: (context, i) {
                    final e = _resultatsRechercheEleveException[i];
                    final aException = e.montantMensuelPersonnalise != null ||
                        e.exceptionsMoisPersonnalisees.isNotEmpty;
                    return ListTile(
                      dense: true,
                      leading: aException
                          ? const Icon(Icons.star, color: Colors.indigo, size: 18)
                          : const Icon(Icons.person_add_alt, size: 18),
                      title: Text('${e.nom} ${e.postNom} ${e.prenom}'),
                      subtitle: Text('ID: ${e.id} — ${e.classe} (${e.section})'),
                      onTap: () => _ajouterBrouillonException(e),
                    );
                  },
                ),
              ),
            ..._brouillonsException.map(_buildBrouillonException),
            if (_brouillonsException.isNotEmpty) ...[
              const SizedBox(height: 12),
              ElevatedButton.icon(
                icon: const Icon(Icons.check),
                label: Text(
                    "Enregistrer les exceptions (${_brouillonsException.length} élève(s))"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 46),
                ),
                onPressed: _enregistrerBrouillonsException,
              ),
            ],
            const SizedBox(height: 16),
            if (elevesAvecExceptionPersonnalisee.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  "Aucun élève n'a actuellement d'exception de paiement.",
                  style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                ),
              )
            else ...[
              Text(
                "Élèves avec une exception de paiement (${elevesAvecExceptionPersonnalisee.length}) :",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              ...elevesAvecExceptionPersonnalisee.map(_buildCarteEleveException),
            ],

            const Divider(),
            const Text("Recalcul de Sécurité des Paiements",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              "À utiliser si vous avez remarqué qu'un frais était mal "
                  "configuré (ex: montant par défaut jamais corrigé) et que "
                  "des élèves ont déjà payé avec l'ancien montant. Ce bouton "
                  "ne supprime ni n'ajoute aucun argent : il redistribue "
                  "simplement, mois par mois et pour chaque élève, ce qu'il "
                  "a déjà payé, en respectant les montants requis ACTUELS "
                  "(y compris les montants personnalisés déjà fixés, qui ne "
                  "sont jamais écrasés par ce recalcul général).",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_fix_high),
              label: const Text("Recalculer TOUS les paiements de l'année en cours"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 46),
              ),
              onPressed: () async {
                if (!await _verifyBackupPassword()) return;
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text("Confirmer le recalcul général"),
                    content: const Text(
                      "Ceci va recalculer, pour TOUS les élèves de l'année "
                          "en cours, la répartition mois par mois de ce "
                          "qu'ils ont déjà payé, selon les montants requis "
                          "actuels.\n\nAucun montant payé ne sera perdu ni "
                          "ajouté : seule la répartition entre les mois sera "
                          "corrigée.\n\nContinuer ?",
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text("Annuler")),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text("Confirmer"),
                      ),
                    ],
                  ),
                );
                if (confirm != true) return;
                final int nbRecalcules = await widget.fraisScolaires.recalculerPaiementsPour();
                if (mounted) {
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("✅ Recalcul terminé — $nbRecalcules élève(s) mis à jour"),
                      backgroundColor: Colors.green,
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              },
            ),
            const Divider(),
            const Text("Administrations & Répartition (%)",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (!totalAdminsCorrect)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade300),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "⚠️ La somme des pourcentages des administrations "
                            "est actuellement de ${totalPourcentAdmins.toStringAsFixed(1)}% "
                            "(devrait être 100%). Vérifiez la répartition ci-dessous.",
                        style: const TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            ...widget.fraisScolaires.config.administrations
                .map(
                  (admin) => ListTile(
                title: Text(admin.nom),
                subtitle: Text("${admin.pourcentage}%"),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () => _editAdministration(admin),
                ),
              ),
            )
                .toList(),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("Ajouter Administration"),
              onPressed: _addAdministration,
            ),
            const Divider(),
            const Text("Autres Frais de Paiement",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              "Frais ponctuels propres à votre école. Un frais défini pour "
                  "\"toute l'école\" peut malgré tout être payé à un montant "
                  "différent selon la section ou la classe via l'icône ⚙ "
                  "\"Montants par section/classe\".",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 10),
            if (autresFraisList.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  "Aucun frais additionnel défini pour le moment.",
                  style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                ),
              )
            else
              ...autresFraisList.map((f) {
                final nbExceptions = f.montantsParSection.length + f.montantsParClasse.length;
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    title: Text(f.nom),
                    subtitle: Text(
                      "${f.montant.toStringAsFixed(0)} FC — ${_autreFraisScopeLabel(f)}"
                          "${nbExceptions > 0 ? ' • $nbExceptions montant(s) spécifique(s)' : ''}",
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, color: Colors.indigo),
                          tooltip: "Modifier le frais",
                          onPressed: () => _editAutreFraisDialog(f),
                        ),
                        IconButton(
                          icon: const Icon(Icons.tune, color: Colors.teal),
                          tooltip: "Montants par section/classe",
                          onPressed: () => _manageMontantsAutreFrais(f),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          tooltip: "Supprimer",
                          onPressed: () => _deleteAutreFrais(f),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.add_box),
              label: const Text("Ajouter un Frais Additionnel"),
              onPressed: _showAddAutreFraisDialog,
            ),
            const Divider(),
            const Text("Administrations & Répartition — Autres Frais (%)",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              "Liste TOTALEMENT INDÉPENDANTE des administrations des frais "
                  "mensuels principaux ci-dessus.",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (!totalAutresFraisAdminsCorrect)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade300),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "⚠️ La somme des pourcentages des administrations "
                            "des \"Autres Frais\" est actuellement de "
                            "${totalPourcentAutresFraisAdmins.toStringAsFixed(1)}% "
                            "(devrait être 100%). Vérifiez la répartition ci-dessous.",
                        style: const TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.fraisScolaires.autresFraisAdministrations.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  "Aucune administration définie pour les Autres Frais.",
                  style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                ),
              )
            else
              ...widget.fraisScolaires.autresFraisAdministrations
                  .map(
                    (admin) => ListTile(
                  title: Text(admin.nom),
                  subtitle: Text("${admin.pourcentage}%"),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _editAutreFraisAdministration(admin),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => _deleteAutreFraisAdministration(admin),
                      ),
                    ],
                  ),
                ),
              )
                  .toList(),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("Ajouter Administration (Autres Frais)"),
              onPressed: _addAutreFraisAdministration,
            ),
            const Divider(),
            const Text("Année Scolaire",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            DropdownButton<String>(
              value: selectedYear,
              isExpanded: true,
              items: [
                ...widget.fraisScolaires.history.keys
                    .map((year) => DropdownMenuItem(value: year, child: Text(year))),
                const DropdownMenuItem(
                    value: "Nouvelle Annee", child: Text("Créer nouvelle année")),
              ],
              onChanged: (value) async {
                if (value == "Nouvelle Annee") {
                  final controller = TextEditingController();
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text("Nouvelle Année Scolaire"),
                      content: TextField(
                        controller: controller,
                        decoration: const InputDecoration(labelText: "Ex: 2026-2027"),
                      ),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
                        ElevatedButton(
                          onPressed: () async {
                            if (controller.text.isNotEmpty) {
                              if (await _verifyBackupPassword()) {
                                await widget.fraisScolaires
                                    .changeYear(controller.text.trim());
                                if (mounted) {
                                  setState(() => selectedYear = controller.text.trim());
                                }
                              }
                            }
                            Navigator.pop(ctx);
                          },
                          child: const Text("Créer"),
                        ),
                      ],
                    ),
                  );
                } else if (value != null) {
                  if (await _verifyBackupPassword()) {
                    await widget.fraisScolaires.changeYear(value);
                    if (mounted) setState(() => selectedYear = value);
                  }
                }
              },
            ),
            const Divider(),
            const Text("Synchronisation Serveur",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: const Text(
                "⚠️ Sauvegardez régulièrement : les parents peuvent alors "
                    "retrouver leurs enfants via l'app parent, et le "
                    "promoteur reçoit un résumé à jour et les nouvelles "
                    "demandes en attente.",
                style: TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ),
            const SizedBox(height: 10),
            if (appState.schoolCode == null)
              ElevatedButton.icon(
                icon: const Icon(Icons.lock),
                label: const Text("Définir Code École"),
                onPressed: () => _setSchoolCode(context, appState),
              )
            else
              ListTile(
                title: const Text("Code de l'école"),
                subtitle: Text(appState.schoolCode!),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () => _setSchoolCode(context, appState),
                ),
              ),
            const SizedBox(height: 10),
            if (appState.backupPassword == null)
              ElevatedButton.icon(
                icon: const Icon(Icons.password),
                label: const Text("Définir Mot de Passe Sauvegarde"),
                onPressed: () => _setBackupPassword(context, appState),
              )
            else
              ListTile(
                title: const Text("Mot de Passe Sauvegarde"),
                subtitle: const Text("••••••••"),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () => _changeBackupPassword(context, appState),
                ),
              ),
            const SizedBox(height: 15),
            ElevatedButton.icon(
              icon: const Icon(Icons.cloud_upload),
              label: const Text("Sauvegarder sur le Serveur"),
              onPressed: () async {
                if (appState.schoolCode == null || appState.backupPassword == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Définissez le code et le mot de passe")),
                  );
                  return;
                }
                final result = await widget.fraisScolaires
                    .backupToServer(appState.schoolCode!, appState.backupPassword!);
                final bool success = result['success'] == true;
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success
                          ? "✅ Sauvegarde réussie — résumé promoteur mis à jour, "
                          "et les parents peuvent maintenant accéder aux données"
                          : "❌ Erreur de sauvegarde : ${result['error'] ?? 'inconnue'}"),
                      backgroundColor: success ? Colors.green : Colors.red,
                      duration: Duration(seconds: success ? 3 : 6),
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.cloud_download),
              label: const Text("Récupérer depuis le Serveur"),
              onPressed: () async {
                if (appState.schoolCode == null || appState.backupPassword == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Définissez le code et le mot de passe")),
                  );
                  return;
                }
                final result = await widget.fraisScolaires
                    .restoreFromServer(appState.schoolCode!, appState.backupPassword!);
                final bool success = result['success'] == true;
                if (success && mounted) {
                  setState(() {
                    selectedYear = widget.fraisScolaires.currentYear;
                    nameController.text = widget.fraisScolaires.config.schoolName;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("✅ Données récupérées et fusionnées")),
                  );
                } else if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          "❌ Échec : ${result['error'] ?? 'mot de passe incorrect ou aucune donnée'}"),
                      duration: const Duration(seconds: 6),
                    ),
                  );
                }
              },
            ),
            const Divider(),
            const Text("Imprimante de Reçus (Epson TM-T20III — USB)",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              "1. Branchez l'Epson TM-T20III en USB et installez son pilote.\n"
                  "2. Cliquez \"Détecter\".\n"
                  "3. Sélectionnez l'Epson dans la liste.\n"
                  "4. Testez avec \"Imprimer page de test\".",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text("Choisir l'imprimante"),
                    value: _selectedPrinterName,
                    items: _availablePrinters
                        .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) _saveSelectedPrinter(val);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  icon: _loadingPrinters
                      ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: const Text("Détecter"),
                  onPressed: _loadingPrinters ? null : _detectPrinters,
                ),
              ],
            ),
            if (_selectedPrinterName != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  "Imprimante actuelle : $_selectedPrinterName",
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo),
                ),
              ),
            const SizedBox(height: 18),
            const Text("Logo de l'établissement (sur les reçus)",
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              "Le logo choisi sera imprimé à gauche ET à droite, en haut "
                  "du reçu, avec le nom de l'établissement centré entre les deux.",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: _logoBytes != null
                        ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(_logoBytes!, fit: BoxFit.contain),
                    )
                        : const Icon(Icons.image_not_supported, color: Colors.grey),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      _logoBytes != null ? "Logo actuel" : "Aucun logo sélectionné",
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  ElevatedButton.icon(
                    icon: _loadingLogo
                        ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.upload, size: 18),
                    label: Text(_logoBytes == null ? "Choisir" : "Changer"),
                    onPressed: _loadingLogo ? null : _pickLogo,
                  ),
                  if (_logoBytes != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      tooltip: "Retirer le logo",
                      onPressed: _loadingLogo ? null : _removeLogo,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              icon: _testingPrint
                  ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.print),
              label: Text(_testingPrint ? "Impression en cours..." : "Imprimer page de test"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
              ),
              onPressed: (_selectedPrinterName == null || _testingPrint) ? null : _testPrint,
            ),
            const Divider(),
            SwitchListTile(
              title: const Text("Mode Sombre"),
              value: appState.isDarkMode,
              onChanged: (_) => appState.toggleTheme(),
            ),
            const Divider(),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.logout, color: Colors.white),
              label: const Text("Déconnexion", style: TextStyle(fontSize: 16)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                minimumSize: const Size(double.infinity, 52),
              ),
              onPressed: _deconnexion,
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _addNewSection() async {
    if (!await _verifyBackupPassword()) return;
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Nouvelle Section"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: "Nom de la section"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                final newSection = controller.text.trim();
                if (!widget.fraisScolaires.config.sections.contains(newSection)) {
                  widget.fraisScolaires.config.sections.add(newSection);
                  widget.fraisScolaires.saveData();
                  if (mounted) setState(() {});
                }
                Navigator.pop(ctx);
              }
            },
            child: const Text("Ajouter"),
          ),
        ],
      ),
    );
  }

  void _removeSection(String section) async {
    if (!await _verifyBackupPassword()) return;
    if (widget.fraisScolaires.config.sections.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Vous devez garder au moins une section")),
      );
      return;
    }
    setState(() {
      widget.fraisScolaires.config.sections.remove(section);
      widget.fraisScolaires.config.feesBySection.remove(section);
      widget.fraisScolaires.config.monthlyExceptionsBySection.remove(section);
      widget.fraisScolaires.config.feesByClasse
          .removeWhere((key, _) => key.startsWith("$section|"));
      widget.fraisScolaires.config.monthlyExceptionsByClasse
          .removeWhere((key, _) => key.startsWith("$section|"));
      widget.fraisScolaires.config.classesBySection.remove(section);
      widget.fraisScolaires.retirerSectionDesOptions(section);
    });
    await widget.fraisScolaires.saveData();
  }

  void _editExceptionForSection() async {
    if (selectedSectionForException == null || selectedMonthForException == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Veuillez choisir une section et un mois")),
      );
      return;
    }
    if (!await _verifyBackupPassword()) return;

    final controller = TextEditingController();
    final scopeLabel = selectedClasseScopeForException ?? "Toutes les classes";

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            "Exception - $selectedMonthForException ($selectedSectionForException - $scopeLabel)"),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: "Montant (FC)",
            helperText: "Laisser vide pour supprimer l'exception existante",
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () async {
              final amount = double.tryParse(controller.text);

              final double ancienRequisPourCeMois = widget.fraisScolaires.getRequiredForMonth(
                selectedMonthForException!,
                selectedSectionForException!,
                selectedClasseScopeForException,
              );

              if (selectedClasseScopeForException == null) {
                if (amount != null) {
                  widget.fraisScolaires.config.monthlyExceptionsBySection
                      .putIfAbsent(selectedSectionForException!, () => {})[
                  selectedMonthForException!] = amount;
                } else {
                  widget.fraisScolaires
                      .config.monthlyExceptionsBySection[selectedSectionForException!]
                      ?.remove(selectedMonthForException);
                }
              } else {
                final key = "${selectedSectionForException!}|${selectedClasseScopeForException!}";
                if (amount != null) {
                  widget.fraisScolaires.config.monthlyExceptionsByClasse
                      .putIfAbsent(key, () => {})[selectedMonthForException!] = amount;
                } else {
                  widget.fraisScolaires.config.monthlyExceptionsByClasse[key]
                      ?.remove(selectedMonthForException);
                }
              }
              await widget.fraisScolaires.saveData();

              Navigator.pop(ctx);

              final double nouveauRequisPourCeMois = widget.fraisScolaires.getRequiredForMonth(
                selectedMonthForException!,
                selectedSectionForException!,
                selectedClasseScopeForException,
              );
              final bool montantEstPlusBas = nouveauRequisPourCeMois < ancienRequisPourCeMois;

              String mode = 'intelligent';
              if (montantEstPlusBas && mounted) {
                final choix = await _askRecalculMode(context);
                if (choix != null) mode = choix;
              }

              final int nbRecalcules = mode == 'constant'
                  ? await widget.fraisScolaires.recalculerPaiementsPourModeConstant(
                section: selectedSectionForException,
                classeNumero: selectedClasseScopeForException,
                anciensRequisParMois: {selectedMonthForException!: ancienRequisPourCeMois},
              )
                  : await widget.fraisScolaires.recalculerPaiementsPour(
                section: selectedSectionForException,
                classeNumero: selectedClasseScopeForException,
              );
              if (mounted) {
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(mode == 'constant'
                        ? "Exception enregistrée (mode constant) — "
                        "$nbRecalcules élève(s) ajusté(s) uniquement "
                        "pour $selectedMonthForException, sans report "
                        "vers les autres mois"
                        : "Exception enregistrée — $nbRecalcules élève(s) "
                        "recalculé(s) automatiquement"),
                  ),
                );
              }
            },
            child: const Text("Enregistrer"),
          ),
        ],
      ),
    );
  }

  void _addAdministration() async {
    if (!await _verifyBackupPassword()) return;
    final nomController = TextEditingController();
    final percentController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Nouvelle Administration"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nomController, decoration: const InputDecoration(labelText: "Nom")),
            TextField(
              controller: percentController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Pourcentage (%)"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              final percent = double.tryParse(percentController.text);
              if (nomController.text.isNotEmpty && percent != null) {
                widget.fraisScolaires.config.administrations
                    .add(Administration(nom: nomController.text, pourcentage: percent));
                widget.fraisScolaires.saveData();
                if (mounted) setState(() {});
                Navigator.pop(ctx);
              }
            },
            child: const Text("Ajouter"),
          ),
        ],
      ),
    );
  }

  void _editAdministration(Administration admin) async {
    if (!await _verifyBackupPassword()) return;
    final nomController = TextEditingController(text: admin.nom);
    final percentController = TextEditingController(text: admin.pourcentage.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Modifier Administration"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nomController, decoration: const InputDecoration(labelText: "Nom")),
            TextField(
              controller: percentController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Pourcentage (%)"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              final percent = double.tryParse(percentController.text);
              if (nomController.text.isNotEmpty && percent != null) {
                admin.nom = nomController.text;
                admin.pourcentage = percent;
                widget.fraisScolaires.saveData();
                if (mounted) setState(() {});
                Navigator.pop(ctx);
              }
            },
            child: const Text("Enregistrer"),
          ),
        ],
      ),
    );
  }

  void _addAutreFraisAdministration() async {
    if (!await _verifyBackupPassword()) return;
    final nomController = TextEditingController();
    final percentController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Nouvelle Administration (Autres Frais)"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nomController, decoration: const InputDecoration(labelText: "Nom")),
            TextField(
              controller: percentController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Pourcentage (%)"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () async {
              final percent = double.tryParse(percentController.text);
              if (nomController.text.isNotEmpty && percent != null) {
                await widget.fraisScolaires.addAutreFraisAdministration(
                  nom: nomController.text,
                  pourcentage: percent,
                );
                if (mounted) {
                  setState(() {});
                  Navigator.pop(ctx);
                }
              }
            },
            child: const Text("Ajouter"),
          ),
        ],
      ),
    );
  }

  void _editAutreFraisAdministration(AutreFraisAdministration admin) async {
    if (!await _verifyBackupPassword()) return;
    final nomController = TextEditingController(text: admin.nom);
    final percentController = TextEditingController(text: admin.pourcentage.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Modifier Administration (Autres Frais)"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nomController, decoration: const InputDecoration(labelText: "Nom")),
            TextField(
              controller: percentController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Pourcentage (%)"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () async {
              final percent = double.tryParse(percentController.text);
              if (nomController.text.isNotEmpty && percent != null) {
                await widget.fraisScolaires.updateAutreFraisAdministration(
                  admin.id,
                  nom: nomController.text,
                  pourcentage: percent,
                );
                if (mounted) {
                  setState(() {});
                  Navigator.pop(ctx);
                }
              }
            },
            child: const Text("Enregistrer"),
          ),
        ],
      ),
    );
  }

  void _deleteAutreFraisAdministration(AutreFraisAdministration admin) async {
    if (!await _verifyBackupPassword()) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Supprimer cette administration ?"),
        content: Text(
          "Voulez-vous vraiment supprimer \"${admin.nom}\" de la répartition des Autres Frais ?",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Supprimer"),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await widget.fraisScolaires.deleteAutreFraisAdministration(admin.id);
      if (mounted) setState(() {});
    }
  }

  void _setSchoolCode(BuildContext context, AppState appState) {
    final codeController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Code de Récupération"),
        content: TextField(
          controller: codeController,
          decoration: const InputDecoration(labelText: "Code unique (ex: MAPENDO)"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              if (codeController.text.trim().isNotEmpty) {
                appState.setSchoolCode(codeController.text.trim());
                Navigator.pop(ctx);
              }
            },
            child: const Text("Enregistrer"),
          ),
        ],
      ),
    );
  }

  void _setBackupPassword(BuildContext context, AppState appState) {
    final passController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Mot de Passe de Sauvegarde"),
        content: TextField(
          controller: passController,
          obscureText: true,
          decoration: const InputDecoration(labelText: "Mot de passe (min 6 caractères)"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              if (passController.text.trim().length >= 6) {
                appState.setBackupPassword(passController.text.trim());
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Mot de passe enregistré")),
                );
              }
            },
            child: const Text("Enregistrer"),
          ),
        ],
      ),
    );
  }
}