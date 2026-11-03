import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
import '../app_state.dart';
import '../frais_scolaires.dart';
import '../models.dart';
import '../services/epson_printer_service.dart';
import '../services/student_import_service.dart';

class PaiementEleveScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const PaiementEleveScreen({super.key, required this.fraisScolaires});

  @override
  State<PaiementEleveScreen> createState() => _PaiementEleveScreenState();
}

class _PaiementEleveScreenState extends State<PaiementEleveScreen> {
  final searchController = TextEditingController();
  String? selectedClassFilter;
  String? selectedSectionFilter;
  List<Eleve> filtered = [];

  int _mobilePendingCount = 0;
  List<Map<String, dynamic>> _mobilePendingPayments = [];
  bool _loadingMobile = false;
  bool _reprinting = false;
  bool _importing = false;

  Timer? _pendingRequestsPoller;

  static const String _receiptsLockedPrefKey = 'receipts_locked';
  bool _receiptsLocked = false;

  static const String _autoImportSchoolName = 'COMPLEXE SCOLAIRE CHRIST SAUVEUR';
  static const String _autoImportFileName = 'liste.txt';

  List<String> _dedupe(Iterable<String> items) =>
      LinkedHashSet<String>.from(items).toList();

  String _classFilterKey(String section, String classe) => '$section|$classe';

  @override
  void initState() {
    super.initState();
    selectedSectionFilter = widget.fraisScolaires.lastSelectedSectionFilter;
    selectedClassFilter = widget.fraisScolaires.lastSelectedClassFilter;
    _filterEleves();
    searchController.addListener(_filterEleves);
    _loadReceiptsLockState();
    _fetchMobilePendingPayments();
    _flushPendingReceipts();
    _pendingRequestsPoller =
        Timer.periodic(const Duration(seconds: 5), (_) => _pollPendingRequests());
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _maybeAutoImportFromDesktop());
  }

  Future<void> _loadReceiptsLockState() async {
    final prefs = await SharedPreferences.getInstance();
    final locked = prefs.getBool(_receiptsLockedPrefKey) ?? false;
    if (mounted) {
      setState(() => _receiptsLocked = locked);
    }
  }

  Future<void> _setReceiptsLocked(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_receiptsLockedPrefKey, value);
    if (mounted) {
      setState(() => _receiptsLocked = value);
    }
  }

  Future<void> _toggleReceiptsLock() async {
    final bool nouveauEtat = !_receiptsLocked;
    final String titre = nouveauEtat
        ? "Bloquer l'impression des reçus ?"
        : "Débloquer l'impression des reçus ?";
    final String message = nouveauEtat
        ? "Tant que c'est bloqué, les nouveaux paiements seront enregistrés "
        "normalement, mais AUCUN reçu ne sera imprimé ni mis en attente "
        "d'impression pour ces paiements.\n\n"
        "Voulez-vous vraiment bloquer l'impression maintenant ?"
        : "Les nouveaux paiements seront à nouveau imprimés (ou mis en "
        "attente si aucune imprimante n'est disponible), comme "
        "d'habitude.\n\n"
        "Voulez-vous vraiment débloquer l'impression maintenant ?";

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titre),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: nouveauEtat ? Colors.red : Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(nouveauEtat ? "Bloquer" : "Débloquer"),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _setReceiptsLocked(nouveauEtat);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nouveauEtat
                  ? "🔒 Impression des reçus bloquée."
                  : "🔓 Impression des reçus débloquée.",
            ),
            backgroundColor: nouveauEtat ? Colors.red : Colors.green,
          ),
        );
      }
    }
  }

  Future<void> _flushPendingReceipts() async {
    if (_receiptsLocked) return;
    final count = await widget.fraisScolaires.flushReceiptQueue();
    if (mounted && count > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
          Text("🖨️ $count reçu(s) en attente ont été imprimés automatiquement."),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _maybeAutoImportFromDesktop() async {
    final targetName = _autoImportSchoolName.trim().toUpperCase();
    if (widget.fraisScolaires.config.schoolName.trim().toUpperCase() !=
        targetName) {
      return;
    }

    final path =
    await StudentImportService.findDesktopFile(_autoImportFileName);
    if (path == null) return;

    String content;
    try {
      content = await File(path).readAsString();
    } catch (_) {
      return;
    }
    if (content.trim().isEmpty) return;

    if (await AutoImportGuard.alreadyHandled(content)) return;
    if (!mounted) return;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Fichier d'élèves détecté"),
        content: const Text(
          "Un fichier \"liste.txt\" a été trouvé sur le Bureau. "
              "Voulez-vous importer ces élèves maintenant ?",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Plus tard")),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Importer")),
        ],
      ),
    );

    if (proceed == true) {
      await _runStudentImportFlow(content);
    }
    await AutoImportGuard.markHandled(content);
  }

  Future<void> _pickAndImportFile() async {
    if (_importing) return;
    const typeGroup =
    XTypeGroup(label: 'Liste d\'élèves', extensions: ['json', 'txt']);
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    final content = await file.readAsString();
    await _runStudentImportFlow(content);
  }

  Future<void> _runStudentImportFlow(String content) async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final parseResult = StudentImportParser.parse(content);
      if (parseResult.errors.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(parseResult.errors.first),
                backgroundColor: Colors.red),
          );
        }
        return;
      }
      if (parseResult.records.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Aucun élève trouvé dans ce fichier.")),
          );
        }
        return;
      }

      final analysis =
      StudentImportService.analyze(widget.fraisScolaires, parseResult.records);

      if (analysis.sectionConflicts.isNotEmpty) {
        final proceed = await _resolveSectionConflicts(analysis.sectionConflicts);
        if (!proceed) return;
        await StudentImportService.applySectionResolutions(
            widget.fraisScolaires, analysis.sectionConflicts);
      }

      final duplicates =
      StudentImportService.findDuplicates(widget.fraisScolaires, parseResult.records);
      final duplicateIncoming = duplicates.map((d) => d.incoming).toSet();
      final newRecords = parseResult.records
          .where((r) => !duplicateIncoming.contains(r))
          .toList();

      if (duplicates.isNotEmpty) {
        final proceed = await _resolveDuplicates(duplicates);
        if (!proceed) return;
      }

      final addedCount =
      await StudentImportService.importNewRecords(widget.fraisScolaires, newRecords);
      final completedCount =
      await StudentImportService.completeDuplicates(widget.fraisScolaires, duplicates);
      final ignoredCount = duplicates.length - completedCount;

      if (mounted) {
        _filterEleves();
        setState(() {});
        final parts = <String>["$addedCount élève(s) ajouté(s)"];
        if (completedCount > 0) parts.add("$completedCount fiche(s) complétée(s)");
        if (ignoredCount > 0) parts.add("$ignoredCount doublon(s) ignoré(s)");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("✅ Import terminé : ${parts.join(', ')}."),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<bool> _resolveSectionConflicts(List<SectionConflict> conflicts) async {
    final existingSections = _dedupe(widget.fraisScolaires.config.sections);
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: const Text("Sections inconnues détectées"),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Ces valeurs du fichier importé ne correspondent à aucune "
                        "section déjà connue. Pour chacune, choisissez une "
                        "section existante à fusionner, ou créez-la telle "
                        "quelle. La valeur d'origine reste toujours visible "
                        "sur la fiche des élèves concernés.",
                    style: TextStyle(fontSize: 12.5, color: Colors.grey),
                  ),
                  const SizedBox(height: 14),
                  ...conflicts.map((c) {
                    return Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('"${c.rawCandidate}"',
                              style:
                              const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          RadioListTile<bool>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text("Créer comme nouvelle section",
                                style: TextStyle(fontSize: 13)),
                            value: true,
                            groupValue: c.createNew,
                            onChanged: (v) =>
                                setStateDialog(() => c.createNew = true),
                          ),
                          if (c.createNew)
                            Padding(
                              padding: const EdgeInsets.only(left: 32, bottom: 6),
                              child: TextFormField(
                                initialValue: c.newSectionName,
                                decoration: const InputDecoration(
                                    labelText: "Nom de la nouvelle section"),
                                onChanged: (v) => c.newSectionName = v,
                              ),
                            ),
                          RadioListTile<bool>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                                "Fusionner vers une section existante",
                                style: TextStyle(fontSize: 13)),
                            value: false,
                            groupValue: c.createNew,
                            onChanged: (v) =>
                                setStateDialog(() => c.createNew = false),
                          ),
                          if (!c.createNew)
                            Padding(
                              padding: const EdgeInsets.only(left: 32),
                              child: DropdownButtonFormField<String>(
                                value: existingSections.contains(c.mergeTarget)
                                    ? c.mergeTarget
                                    : null,
                                hint: const Text("Choisir une section"),
                                items: existingSections
                                    .map((s) =>
                                    DropdownMenuItem(value: s, child: Text(s)))
                                    .toList(),
                                onChanged: (v) =>
                                    setStateDialog(() => c.mergeTarget = v),
                              ),
                            ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("Annuler l'import")),
            ElevatedButton(
              onPressed: () {
                for (final c in conflicts) {
                  if (!c.createNew &&
                      (c.mergeTarget == null || c.mergeTarget!.isEmpty)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              "Veuillez choisir une section pour chaque élément.")),
                    );
                    return;
                  }
                }
                Navigator.pop(ctx, true);
              },
              child: const Text("Continuer"),
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  Future<bool> _resolveDuplicates(List<DuplicateMatch> matches) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: Text("Élèves déjà existants (${matches.length})"),
          content: SizedBox(
            width: 480,
            height: 420,
            child: ListView.builder(
              itemCount: matches.length,
              itemBuilder: (context, i) {
                final m = matches[i];
                return CheckboxListTile(
                  value: m.completeMissingInfo,
                  onChanged: (v) =>
                      setStateDialog(() => m.completeMissingInfo = v ?? false),
                  title: Text(
                      "${m.existing.nom} ${m.existing.postNom} ${m.existing.prenom}"),
                  subtitle: Text(
                    "Déjà dans ${m.existing.classe} (ID: ${m.existing.id}).\n"
                        "Le fichier apporte peut-être des informations que "
                        "la fiche actuelle n'a pas (téléphone, tuteur, lieu "
                        "de naissance...). Compléter automatiquement la "
                        "fiche existante avec ce qui manque ?",
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  isThreeLine: true,
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                for (final m in matches) {
                  m.completeMissingInfo = false;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text("Ignorer tous les doublons"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Continuer"),
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  Future<void> _fetchMobilePendingPayments() async {
    final schoolCode = widget.fraisScolaires.schoolCode;
    if (schoolCode == null || schoolCode.isEmpty) return;
    setState(() => _loadingMobile = true);
    try {
      final response = await http
          .get(Uri.parse(
          'https://jsinf.onrender.com/get_mobile_payments?school_code=$schoolCode'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final list = (data['mobile_payments'] as List? ?? []);
        if (mounted) {
          setState(() {
            _mobilePendingCount = list.length;
            _mobilePendingPayments =
                list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          });
        }
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingMobile = false);
    }
  }

  void _showMobilePaymentsDialog() {
    if (_mobilePendingPayments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Aucun paiement mobile en attente")),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Paiements Mobile Money (${_mobilePendingPayments.length})"),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: ListView.builder(
            itemCount: _mobilePendingPayments.length,
            itemBuilder: (context, index) {
              final p = _mobilePendingPayments[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.green,
                    child: Icon(_networkIcon(p['network']?.toString() ?? ''),
                        color: Colors.white, size: 18),
                  ),
                  title:
                  Text("${p['nom']} ${p['postNom'] ?? ''} ${p['prenom']}"),
                  subtitle: Text(
                    "${p['mois']} — ${(p['amount'] as num?)?.toStringAsFixed(0) ?? '0'} FC\n"
                        "Réseau: ${p['network'] ?? '—'} • ${p['date'] ?? ''}",
                  ),
                  trailing: const Icon(Icons.phone_android, color: Colors.green),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton.icon(
            icon: const Icon(Icons.check_circle),
            label: Text("Confirmer tout (${_mobilePendingPayments.length})"),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              await _confirmAllMobilePayments();
            },
          ),
        ],
      ),
    );
  }

  IconData _networkIcon(String network) {
    switch (network.toLowerCase()) {
      case 'airtel':
        return Icons.signal_cellular_alt;
      case 'orange':
        return Icons.signal_cellular_4_bar;
      case 'vodacom':
      case 'mpesa':
        return Icons.mobile_screen_share;
      default:
        return Icons.phone_android;
    }
  }

  Future<void> _confirmAllMobilePayments() async {
    final schoolCode = widget.fraisScolaires.schoolCode;
    if (schoolCode == null || schoolCode.isEmpty) return;
    setState(() => _loadingMobile = true);
    try {
      final ids = _mobilePendingPayments.map((p) => p['id']).toList();
      final response = await http
          .post(
        Uri.parse('https://jsinf.onrender.com/confirm_mobile_payments'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'school_code': schoolCode, 'payment_ids': ids}),
      )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final appState = Provider.of<AppState>(context, listen: false);
        if (appState.backupPassword != null) {
          await widget.fraisScolaires
              .restoreFromServer(schoolCode, appState.backupPassword!);
          await widget.fraisScolaires.saveData();
        }
        if (mounted) {
          setState(() {
            _mobilePendingCount = 0;
            _mobilePendingPayments = [];
          });
          _filterEleves();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("✅ Paiements mobile confirmés et enregistrés !"),
                backgroundColor: Colors.green),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("❌ Erreur lors de la confirmation"),
              backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Erreur de connexion"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingMobile = false);
    }
  }

  Future<void> _pollPendingRequests() async {
    bool changed = false;
    for (final eleve in widget.fraisScolaires.currentData.eleves) {
      for (final t in eleve.transactions) {
        final reqId = t['pendingRequestId'];
        if (reqId == null) continue;
        final status =
        await widget.fraisScolaires.checkPromoterRequestStatus(reqId as String);
        final st = status['status'];
        if (st == 'approved') {
          await widget.fraisScolaires
              .applyApprovedRequest(t['pendingRequestType'] as String, eleve, t, status);
          t.remove('pendingRequestId');
          t.remove('pendingRequestType');
          changed = true;
        } else if (st == 'rejected') {
          t.remove('pendingRequestId');
          t.remove('pendingRequestType');
          changed = true;
        }
      }
    }
    if (changed) {
      await widget.fraisScolaires.saveData();
      if (mounted) {
        setState(() {});
        _filterEleves();
      }
    }
  }

  Future<void> _sendPromoterRequest({
    required String type,
    required Eleve eleve,
    required Map<String, dynamic> transaction,
    required String mois,
    double? nouveauMontant,
  }) async {
    final result = await widget.fraisScolaires.createPromoterRequest(
      type: type,
      eleve: eleve,
      transaction: transaction,
      mois: mois,
      nouveauMontant: nouveauMontant,
    );
    if (result['success'] == true) {
      transaction['pendingRequestId'] = result['request_id'];
      transaction['pendingRequestType'] = type;
      await widget.fraisScolaires.saveData();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Demande envoyée au promoteur — en attente de confirmation.")),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Échec de l'envoi : ${result['error']}"),
            backgroundColor: Colors.red),
      );
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'reprint':
        return "réimpression";
      case 'modify':
        return "modification";
      case 'cancel':
        return "annulation";
      default:
        return type;
    }
  }

  void _showTransactionActionsSheet(
      Eleve eleve, Map<String, dynamic> transaction, String mois) {
    final pendingType = transaction['pendingRequestType'];
    if (pendingType != null) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Demande en cours"),
          content: Text(
            "Une demande de ${_typeLabel(pendingType as String)} pour ce paiement "
                "est déjà en attente de confirmation du promoteur.",
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Fermer")),
          ],
        ),
      );
      return;
    }

    final confirmed = _isReceiptConfirmed(transaction);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            if (confirmed)
              ListTile(
                leading: const Icon(Icons.print, color: Colors.indigo),
                title: const Text("Demander une réimpression (duplicata)"),
                onTap: () {
                  Navigator.pop(ctx);
                  _sendPromoterRequest(
                      type: 'reprint', eleve: eleve, transaction: transaction, mois: mois);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.blue),
              title: const Text("Demander une modification"),
              onTap: () {
                Navigator.pop(ctx);
                _promptModifyAmount(eleve, transaction, mois);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text("Demander une annulation"),
              onTap: () {
                Navigator.pop(ctx);
                _confirmRequestCancel(eleve, transaction, mois);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmRequestCancel(
      Eleve eleve, Map<String, dynamic> transaction, String mois) {
    final montant = (transaction['amount'] as num?)?.toDouble() ?? 0;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Demander l'annulation"),
        content: Text(
          "Envoyer au promoteur une demande d'annulation du paiement de "
              "${montant.toStringAsFixed(0)} FC pour \"$mois\" ?\n\n"
              "Le paiement ne sera annulé qu'après confirmation du promoteur.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Non")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _sendPromoterRequest(
                  type: 'cancel', eleve: eleve, transaction: transaction, mois: mois);
            },
            child: const Text("Envoyer la demande"),
          ),
        ],
      ),
    );
  }

  void _promptModifyAmount(
      Eleve eleve, Map<String, dynamic> transaction, String mois) {
    final currentAmount = (transaction['amount'] as num?)?.toDouble() ?? 0;
    final controller =
    TextEditingController(text: currentAmount.toStringAsFixed(0));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Demander une modification — $mois"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Nouveau montant (FC)"),
            ),
            const SizedBox(height: 10),
            const Text(
              "Cette modification ne sera appliquée qu'après confirmation du promoteur.",
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              final newAmount = double.tryParse(controller.text);
              if (newAmount == null || newAmount < 0) return;
              Navigator.pop(ctx);
              _sendPromoterRequest(
                type: 'modify',
                eleve: eleve,
                transaction: transaction,
                mois: mois,
                nouveauMontant: newAmount,
              );
            },
            child: const Text("Envoyer la demande"),
          ),
        ],
      ),
    );
  }

  bool _isReceiptConfirmed(Map<String, dynamic> t) => t['receiptConfirmed'] == true;

  Future<void> _retryPrintUnconfirmed(
      Eleve eleve, Map<String, dynamic> transaction) async {
    if (_reprinting) return;
    if (_receiptsLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "🔒 L'impression des reçus est actuellement bloquée. "
                  "Débloquez-la depuis le bouton en haut de l'écran pour imprimer."),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() => _reprinting = true);
    try {
      final printerName = await _currentPrinterName();
      if (printerName.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Aucune imprimante configurée dans les Paramètres."),
                backgroundColor: Colors.red),
          );
        }
        return;
      }
      final logoBytes = await _loadLogoBytesLocal();
      final ok = await widget.fraisScolaires.retryPrintPrincipalReceipt(
        eleve: eleve,
        transaction: transaction,
        printerName: printerName,
        logoBytes: logoBytes,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? "🖨️ Reçu imprimé avec succès" : "❌ Échec de l'impression"),
            backgroundColor: ok ? Colors.green : Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _reprinting = false);
    }
  }

  Future<String> _currentPrinterName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('printer_name') ?? '';
  }

  Future<Uint8List?> _loadLogoBytesLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('has_logo') ?? false)) return null;
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/school_logo.png');
      if (await file.exists()) return await file.readAsBytes();
      return null;
    } catch (_) {
      return null;
    }
  }

  void _filterEleves() {
    final query = searchController.text.toLowerCase().trim();
    setState(() {
      filtered = widget.fraisScolaires.currentData.eleves.where((e) {
        final idMatch = e.id.toLowerCase().contains(query);
        final nameMatch =
        '${e.nom} ${e.postNom} ${e.prenom}'.toLowerCase().contains(query);
        final classMatch =
            selectedClassFilter == null || e.classe == selectedClassFilter;
        final sectionMatch =
            selectedSectionFilter == null || e.section == selectedSectionFilter;
        return (idMatch || nameMatch) && classMatch && sectionMatch;
      }).toList();
    });
  }

  @override
  void dispose() {
    widget.fraisScolaires.lastSelectedClassFilter = selectedClassFilter;
    widget.fraisScolaires.lastSelectedSectionFilter = selectedSectionFilter;
    widget.fraisScolaires.saveData();
    searchController.dispose();
    _pendingRequestsPoller?.cancel();
    super.dispose();
  }

  String? _extractClasseNumero(String classeComplete) {
    final parts = classeComplete.trim().split(' ');
    return parts.isNotEmpty && parts.first.isNotEmpty ? parts.first : null;
  }

  String? _extractSousClasse(String classeComplete) {
    final parts = classeComplete.trim().split(' ');
    if (parts.length > 1) {
      final rest = parts.sublist(1).join(' ').trim();
      return rest.isEmpty ? null : rest;
    }
    return null;
  }

  String? _premierMoisNonPaye(Eleve eleve) {
    for (final m in widget.fraisScolaires.months) {
      final required =
      widget.fraisScolaires.getRequiredForMonthForEleve(eleve, m);
      final paid = eleve.paid[m] ?? 0;
      if (paid < required) return m;
    }
    return null;
  }

  String? _moisDebloqueActif(Eleve eleve) {
    final m = eleve.moisDebloque;
    if (m == null || m.isEmpty) return null;
    if (!widget.fraisScolaires.months.contains(m)) return null;
    final required = widget.fraisScolaires.getRequiredForMonthForEleve(eleve, m);
    final paid = eleve.paid[m] ?? 0;
    if (paid >= required) return null;
    return m;
  }

  bool _peutPayerCeMois(Eleve eleve, String mois) {
    final required =
    widget.fraisScolaires.getRequiredForMonthForEleve(eleve, mois);
    final paid = eleve.paid[mois] ?? 0;
    if (paid >= required) return false;
    if (_moisDebloqueActif(eleve) == mois) return true;
    final premierNonPaye = _premierMoisNonPaye(eleve);
    if (premierNonPaye == null) return false;
    return mois == premierNonPaye;
  }

  bool _paiementViaDeblocage(Eleve eleve, String mois) {
    if (_moisDebloqueActif(eleve) != mois) return false;
    return _premierMoisNonPaye(eleve) != mois;
  }

  Future<void> _deverrouillerMois(Eleve eleve, String mois) async {
    final actif = _moisDebloqueActif(eleve);
    if (actif != null && actif != mois) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              "Un seul mois peut être déverrouillé à la fois : \"$actif\" est "
                  "déjà déverrouillé. Soldez-le ou re-verrouillez-le d'abord."),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final premierNonPaye = _premierMoisNonPaye(eleve);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Déverrouiller \"$mois\" ?"),
        content: Text(
          "Vous pourrez payer \"$mois\" sans avoir soldé les mois précédents.\n\n"
              "Si le montant payé dépasse ce qui est dû pour \"$mois\", le "
              "surplus sera automatiquement réparti sur les mois en priorité"
              "${premierNonPaye != null ? ", en commençant par \"$premierNonPaye\"" : ""}.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Déverrouiller"),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await widget.fraisScolaires.setMoisDebloquePourEleve(eleve, mois);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("🔓 Mois \"$mois\" déverrouillé pour cet élève."),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _reverrouillerMois(Eleve eleve) async {
    await widget.fraisScolaires.setMoisDebloquePourEleve(eleve, null);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("🔒 Mois re-verrouillé.")),
      );
    }
  }

  void _showEditStudentDialog(Eleve eleve) {
    final nomController = TextEditingController(text: eleve.nom);
    final postNomController = TextEditingController(text: eleve.postNom);
    final prenomController = TextEditingController(text: eleve.prenom);
    String? selectedSectionEdit = eleve.section;
    String? selectedClasseNumeroEdit = _extractClasseNumero(eleve.classe);
    String? selectedSousClasseEdit = _extractSousClasse(eleve.classe);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          final sectionsOptions = _dedupe(widget.fraisScolaires.config.sections);
          if (selectedSectionEdit != null &&
              !sectionsOptions.contains(selectedSectionEdit)) {
            sectionsOptions.add(selectedSectionEdit!);
          }
          final classesNumeros = selectedSectionEdit != null
              ? _dedupe(
              widget.fraisScolaires.getClassesForSection(selectedSectionEdit!))
              : <String>[];
          if (selectedClasseNumeroEdit != null &&
              !classesNumeros.contains(selectedClasseNumeroEdit)) {
            classesNumeros.add(selectedClasseNumeroEdit!);
          }
          final sousClasses = (selectedSectionEdit != null &&
              selectedClasseNumeroEdit != null)
              ? _dedupe(widget.fraisScolaires
              .getSubClassesFor(selectedSectionEdit!, selectedClasseNumeroEdit!))
              : <String>[];
          if (selectedSousClasseEdit != null &&
              !sousClasses.contains(selectedSousClasseEdit)) {
            sousClasses.add(selectedSousClasseEdit!);
          }

          return AlertDialog(
            title: const Text("Modifier l'élève"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("ID: ${eleve.id}",
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  TextField(
                      controller: nomController,
                      decoration: const InputDecoration(labelText: "Nom")),
                  TextField(
                      controller: postNomController,
                      decoration: const InputDecoration(labelText: "Post-nom")),
                  TextField(
                      controller: prenomController,
                      decoration: const InputDecoration(labelText: "Prénom")),
                  const SizedBox(height: 15),
                  DropdownButtonFormField<String>(
                    value: selectedSectionEdit,
                    decoration: const InputDecoration(labelText: "Section"),
                    items: sectionsOptions
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (value) {
                      setStateDialog(() {
                        selectedSectionEdit = value;
                        selectedClasseNumeroEdit = null;
                        selectedSousClasseEdit = null;
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: selectedClasseNumeroEdit,
                    decoration: const InputDecoration(labelText: "Numéro de classe"),
                    items: classesNumeros
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: (value) {
                      setStateDialog(() {
                        selectedClasseNumeroEdit = value;
                        selectedSousClasseEdit = null;
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: selectedSousClasseEdit,
                    decoration: const InputDecoration(
                        labelText: "Sous-classe (optionnel)",
                        helperText: "Ex: A, B, C..."),
                    items: sousClasses
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (value) =>
                        setStateDialog(() => selectedSousClasseEdit = value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
              ElevatedButton(
                onPressed: () async {
                  if (nomController.text.trim().isNotEmpty &&
                      postNomController.text.trim().isNotEmpty &&
                      selectedClasseNumeroEdit != null &&
                      selectedSectionEdit != null) {
                    final duplicateEleve =
                    widget.fraisScolaires.findDuplicateFullName(
                      nom: nomController.text.trim(),
                      postNom: postNomController.text.trim(),
                      prenom: prenomController.text.trim(),
                      excludeId: eleve.id,
                    );
                    if (duplicateEleve != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            "⚠️ Un autre élève (${duplicateEleve.classe} - "
                                "ID: ${duplicateEleve.id}) a déjà exactement "
                                "ce Nom, Post-nom et Prénom. Modifiez au "
                                "moins un des trois champs pour continuer.",
                          ),
                          backgroundColor: Colors.red,
                          duration: const Duration(seconds: 5),
                        ),
                      );
                      return;
                    }
                    eleve.nom = nomController.text.trim();
                    eleve.postNom = postNomController.text.trim();
                    eleve.prenom = prenomController.text.trim();
                    eleve.classe = widget.fraisScolaires.buildFullClasseName(
                      selectedClasseNumeroEdit!,
                      selectedSousClasseEdit,
                    );
                    eleve.section = selectedSectionEdit!;
                    await widget.fraisScolaires.saveData();
                    _filterEleves();
                    if (mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Élève modifié avec succès")),
                      );
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content:
                          Text("Veuillez remplir tous les champs obligatoires")),
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

  @override
  Widget build(BuildContext context) {
    final List<Map<String, String>> classFilterEntries = selectedSectionFilter != null
        ? _dedupe(widget.fraisScolaires
        .getAllDisplayClassesForSection(selectedSectionFilter!))
        .map((c) => {'classe': c, 'section': selectedSectionFilter!, 'label': c})
        .toList()
        : widget.fraisScolaires.getAllDisplayClassesWithSection();

    String? selectedClassFilterKey =
    (selectedClassFilter != null && selectedSectionFilter != null)
        ? _classFilterKey(selectedSectionFilter!, selectedClassFilter!)
        : null;

    if (selectedClassFilterKey != null &&
        !classFilterEntries.any((e) =>
        _classFilterKey(e['section']!, e['classe']!) == selectedClassFilterKey)) {
      classFilterEntries.add({
        'classe': selectedClassFilter!,
        'section': selectedSectionFilter!,
        'label': selectedClassFilter!,
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Paiements des Élèves"),
        actions: [
          IconButton(
            icon: Icon(
              _receiptsLocked ? Icons.lock : Icons.lock_open,
              color: _receiptsLocked ? Colors.red : Colors.white,
            ),
            tooltip: _receiptsLocked
                ? "Impression des reçus bloquée — appuyer pour débloquer"
                : "Impression des reçus active — appuyer pour bloquer",
            onPressed: _toggleReceiptsLock,
          ),
          IconButton(
            icon: _importing
                ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.upload_file),
            tooltip: "Importer une liste d'élèves (JSON/TXT)",
            onPressed: _importing ? null : _pickAndImportFile,
          ),
          GestureDetector(
            onTap: _showMobilePaymentsDialog,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IconButton(
                    icon: _loadingMobile
                        ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.phone_android),
                    tooltip: "Paiements Mobile Money en attente",
                    onPressed: _showMobilePaymentsDialog,
                  ),
                  if (_mobilePendingCount > 0)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration:
                        const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                        constraints:
                        const BoxConstraints(minWidth: 18, minHeight: 18),
                        child: Text(
                          '$_mobilePendingCount',
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "Rafraîchir les paiements mobile",
            onPressed: _fetchMobilePendingPayments,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_receiptsLocked)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: const [
                  Icon(Icons.lock, color: Colors.red, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Impression des reçus bloquée : les paiements sont "
                          "enregistrés, mais aucun reçu n'est imprimé ni "
                          "mis en attente.",
                      style: TextStyle(color: Colors.red, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: searchController,
                  decoration: const InputDecoration(
                    labelText: "Rechercher par ID ou Nom",
                    prefixIcon: Icon(Icons.search),
                    hintText: "Ex: BB26B10 ou BARAKA",
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButton<String>(
                        hint: const Text("Toutes les sections"),
                        value: selectedSectionFilter,
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem(
                              value: null, child: Text("Toutes les sections")),
                          ..._dedupe(widget.fraisScolaires.config.sections)
                              .map((s) => DropdownMenuItem(value: s, child: Text(s))),
                        ],
                        onChanged: (value) {
                          setState(() {
                            selectedSectionFilter = value;
                            final validClasses = value != null
                                ? widget.fraisScolaires
                                .getAllDisplayClassesForSection(value)
                                : widget.fraisScolaires.getAllDisplayClasses();
                            if (selectedClassFilter != null &&
                                !validClasses.contains(selectedClassFilter)) {
                              selectedClassFilter = null;
                            }
                            _filterEleves();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButton<String>(
                        hint: const Text("Toutes les classes"),
                        value: selectedClassFilterKey,
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem<String>(
                              value: null, child: Text("Toutes les classes")),
                          ...classFilterEntries.map((e) => DropdownMenuItem<String>(
                            value: _classFilterKey(e['section']!, e['classe']!),
                            child: Text(e['label']!),
                          )),
                        ],
                        onChanged: (value) {
                          setState(() {
                            if (value == null) {
                              selectedClassFilter = null;
                            } else {
                              final entry = classFilterEntries.firstWhere((e) =>
                              _classFilterKey(e['section']!, e['classe']!) ==
                                  value);
                              selectedClassFilter = entry['classe'];
                              selectedSectionFilter = entry['section'];
                            }
                            _filterEleves();
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final eleve = filtered[index];
                final moisDebloqueActif = _moisDebloqueActif(eleve);
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text(eleve.id.length >= 2
                          ? eleve.id.substring(0, 2)
                          : (eleve.id.isNotEmpty ? eleve.id : "?")),
                    ),
                    title: Text('${eleve.nom} ${eleve.postNom} ${eleve.prenom}'),
                    subtitle: Text(
                      'ID: ${eleve.id}\n'
                          'Classe: ${eleve.classe} | Section: ${eleve.section}\n'
                          'Total payé: ${widget.fraisScolaires.getStudentTotalPaid(eleve)} FC'
                          '${eleve.montantMensuelPersonnalise != null ? '\n⭐ Montant personnalisé : ${eleve.montantMensuelPersonnalise!.toStringAsFixed(0)} FC/mois' : ''}'
                          '${eleve.exceptionsMoisPersonnalisees.isNotEmpty ? '\n⭐ ${eleve.exceptionsMoisPersonnalisees.length} mois en exception' : ''}'
                          '${moisDebloqueActif != null ? '\n🔓 Mois déverrouillé : $moisDebloqueActif' : ''}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, color: Colors.blue),
                          onPressed: () => _showEditStudentDialog(eleve),
                        ),
                        const Icon(Icons.arrow_forward_ios),
                      ],
                    ),
                    onTap: () => _showMonthsDialog(context, eleve),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showMonthsDialog(BuildContext context, Eleve eleve) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title:
          Text('${eleve.nom} ${eleve.prenom} - ${eleve.classe} (${eleve.section})'),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: ListView.builder(
              itemCount: widget.fraisScolaires.months.length,
              itemBuilder: (context, i) {
                final mois = widget.fraisScolaires.months[i];
                final required = widget.fraisScolaires
                    .getRequiredForMonthForEleve(eleve, mois);
                final paid = eleve.paid[mois] ?? 0;
                final isFullyPaid = paid >= required;
                final estGratuit = required <= 0;
                final estDebloque = !isFullyPaid && _moisDebloqueActif(eleve) == mois;
                final estOuvert = isFullyPaid || _peutPayerCeMois(eleve, mois);
                final nbPaiements =
                    eleve.transactions.where((t) => t['mois'] == mois).length;
                return ListTile(
                  title: Text(mois),
                  subtitle: Text(
                    estGratuit
                        ? 'Mois gratuit (0 FC)'
                        : 'Requis: $required FC | Payé: $paid FC'
                        '${nbPaiements > 0 ? ' • $nbPaiements paiement(s)' : ''}'
                        '${estDebloque ? '\n🔓 Déverrouillé' : ''}'
                        '${!isFullyPaid && !estOuvert ? '\nSoldez d\'abord les mois précédents ou déverrouillez ce mois' : ''}',
                    style: (!isFullyPaid && !estOuvert)
                        ? const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)
                        : null,
                  ),
                  trailing: estGratuit
                      ? const Icon(Icons.card_giftcard, color: Colors.green)
                      : isFullyPaid
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : (estDebloque
                      ? const Icon(Icons.lock_open, color: Colors.indigo)
                      : (estOuvert
                      ? const Icon(Icons.warning, color: Colors.orange)
                      : const Icon(Icons.lock_outline, color: Colors.grey))),
                  onTap: () async {
                    await _showMonthDetailDialog(context, eleve, mois);
                    setStateDialog(() {});
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Fermer")),
          ],
        ),
      ),
    );
  }

  Future<void> _showMonthDetailDialog(
      BuildContext context, Eleve eleve, String mois) async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          final required = widget.fraisScolaires
              .getRequiredForMonthForEleve(eleve, mois);
          final paid = eleve.paid[mois] ?? 0;
          final isFullyPaid = paid >= required;
          final peutPayer = !isFullyPaid && _peutPayerCeMois(eleve, mois);
          final premierNonPaye = _premierMoisNonPaye(eleve);
          final estDebloque = !isFullyPaid && _moisDebloqueActif(eleve) == mois;
          final viaDeblocage = estDebloque && premierNonPaye != mois;
          final historique = eleve.transactions.where((t) => t['mois'] == mois).toList()
            ..sort((a, b) =>
                (a['date'] ?? '').toString().compareTo((b['date'] ?? '').toString()));

          return AlertDialog(
            title: Text("$mois - ${eleve.nom} ${eleve.prenom}"),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    required <= 0
                        ? "Ce mois est gratuit pour cet élève (0 FC)."
                        : "Requis : ${required.toStringAsFixed(0)} FC\n"
                        "Déjà payé : ${paid.toStringAsFixed(0)} FC",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (!isFullyPaid && !peutPayer && premierNonPaye != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.orange.withAlpha(30),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.lock_outline,
                                color: Colors.orange, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                "Ce mois ne peut pas encore être payé. "
                                    "Vous devez d'abord solder entièrement \"$premierNonPaye\", "
                                    "ou déverrouiller ce mois avec le bouton ci-dessous.",
                                style: const TextStyle(
                                    color: Colors.deepOrange, fontSize: 12.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (viaDeblocage)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.indigo.withAlpha(25),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.indigo),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.lock_open,
                                color: Colors.indigo, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                "Ce mois est déverrouillé. Un paiement complétera "
                                    "d'abord \"$mois\", puis le surplus ira sur "
                                    "\"${premierNonPaye ?? ''}\" et les mois suivants.",
                                style: const TextStyle(
                                    color: Colors.indigo, fontSize: 12.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Historique des paiements :",
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      if (historique.isNotEmpty)
                        const Text(
                          "✅ imprimé • 🖨️ à imprimer • ⏳ demande en cours",
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (historique.isEmpty)
                    const Text("Aucun paiement enregistré pour ce mois.",
                        style: TextStyle(color: Colors.grey))
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: historique.length,
                        itemBuilder: (context, i) {
                          final t = historique[i];
                          final montant = (t['amount'] as num?)?.toDouble() ?? 0;
                          final date = t['date']?.toString() ?? "Date inconnue";
                          final isFromParent = t['from_parent'] == true;
                          final confirmed = _isReceiptConfirmed(t);
                          final pendingType = t['pendingRequestType'];

                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              isFromParent ? Icons.phone_android : Icons.receipt_long,
                              size: 20,
                              color: isFromParent ? Colors.green : Colors.indigo,
                            ),
                            title: Text(date),
                            subtitle: isFromParent
                                ? Text("Via ${t['network'] ?? 'Mobile Money'}",
                                style:
                                const TextStyle(fontSize: 11, color: Colors.green))
                                : null,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text("${montant.toStringAsFixed(0)} FC",
                                    style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(width: 4),
                                if (pendingType != null)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: Icon(Icons.hourglass_top,
                                        color: Colors.orange, size: 20),
                                  )
                                else
                                  IconButton(
                                    icon: _reprinting
                                        ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child:
                                        CircularProgressIndicator(strokeWidth: 2))
                                        : Icon(
                                      confirmed ? Icons.check_circle : Icons.print,
                                      color:
                                      confirmed ? Colors.green : Colors.indigo,
                                      size: 20,
                                    ),
                                    tooltip:
                                    confirmed ? "Reçu déjà imprimé" : "Imprimer",
                                    onPressed: _reprinting
                                        ? null
                                        : () {
                                      if (confirmed) {
                                        Navigator.pop(ctx);
                                        _showTransactionActionsSheet(
                                            eleve, t, mois);
                                      } else {
                                        _retryPrintUnconfirmed(eleve, t);
                                      }
                                    },
                                  ),
                              ],
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _showTransactionActionsSheet(eleve, t, mois);
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Fermer")),
              if (!isFullyPaid && !peutPayer)
                OutlinedButton.icon(
                  icon: const Icon(Icons.lock_open),
                  label: const Text("Déverrouiller ce mois"),
                  onPressed: () async {
                    await _deverrouillerMois(eleve, mois);
                    setStateDialog(() {});
                  },
                ),
              if (viaDeblocage)
                TextButton.icon(
                  icon: const Icon(Icons.lock_outline, color: Colors.red),
                  label: const Text("Re-verrouiller",
                      style: TextStyle(color: Colors.red)),
                  onPressed: () async {
                    await _reverrouillerMois(eleve);
                    setStateDialog(() {});
                  },
                ),
              if (peutPayer)
                ElevatedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text("Ajouter un paiement"),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _showPaymentDialog(context, eleve, mois);
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  double _soldeMaxRestantAPartirDe(Eleve eleve, String mois) {
    final idx = widget.fraisScolaires.months.indexOf(mois);
    if (idx == -1) return 0;
    double total = 0;
    for (var i = idx; i < widget.fraisScolaires.months.length; i++) {
      final m = widget.fraisScolaires.months[i];
      final requis =
      widget.fraisScolaires.getRequiredForMonthForEleve(eleve, m);
      final dejaPaye = eleve.paid[m] ?? 0;
      final restant = requis - dejaPaye;
      if (restant > 0) total += restant;
    }
    return total;
  }

  double _soldeTotalRestantAnnee(Eleve eleve) {
    double total = 0;
    for (final m in widget.fraisScolaires.months) {
      final requis =
      widget.fraisScolaires.getRequiredForMonthForEleve(eleve, m);
      final dejaPaye = eleve.paid[m] ?? 0;
      final restant = requis - dejaPaye;
      if (restant > 0) total += restant;
    }
    return total;
  }

  void _showPaymentDialog(BuildContext context, Eleve eleve, String mois) {
    if (!_peutPayerCeMois(eleve, mois)) {
      final premierNonPaye = _premierMoisNonPaye(eleve);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            premierNonPaye != null
                ? "Veuillez d'abord solder entièrement \"$premierNonPaye\" avant de payer \"$mois\", ou déverrouillez ce mois."
                : "Tous les mois sont déjà soldés pour cet élève.",
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final controller = TextEditingController();
    bool isSubmitting = false;
    final bool viaDeblocageAffichage = _paiementViaDeblocage(eleve, mois);
    final String? premierPrioritaire = _premierMoisNonPaye(eleve);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          Future<void> onConfirmPressed() async {
            if (isSubmitting) return;
            setStateDialog(() => isSubmitting = true);

            final amount = double.tryParse(controller.text);
            if (amount == null || amount <= 0) {
              setStateDialog(() => isSubmitting = false);
              return;
            }

            if (!_peutPayerCeMois(eleve, mois)) {
              Navigator.pop(ctx);
              final premierNonPaye = _premierMoisNonPaye(eleve);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    premierNonPaye != null
                        ? "Impossible : \"$premierNonPaye\" doit être soldé en premier."
                        : "Tous les mois sont déjà soldés pour cet élève.",
                  ),
                  backgroundColor: Colors.orange,
                ),
              );
              return;
            }

            final bool viaDeblocage = _paiementViaDeblocage(eleve, mois);

            if (viaDeblocage) {
              final double soldeTotal = _soldeTotalRestantAnnee(eleve);
              if (amount > soldeTotal) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      "Le montant saisi (${amount.toStringAsFixed(0)} FC) dépasse "
                          "le solde total restant de l'année "
                          "(${soldeTotal.toStringAsFixed(0)} FC). "
                          "Veuillez corriger le montant.",
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
                setStateDialog(() => isSubmitting = false);
                return;
              }
            } else {
              final double soldeMax = _soldeMaxRestantAPartirDe(eleve, mois);
              if (soldeMax > 0 && amount > soldeMax) {
                final bool? continuer = await showDialog<bool>(
                  context: context,
                  builder: (ctx2) => AlertDialog(
                    title: const Text("Montant supérieur au solde dû"),
                    content: Text(
                      "Le montant saisi (${amount.toStringAsFixed(0)} FC) "
                          "dépasse le solde total restant à payer par cet élève "
                          "sur toute l'année scolaire (${soldeMax.toStringAsFixed(0)} FC).\n\n"
                          "L'excédent éventuel sera tout de même conservé et "
                          "ajouté au dernier mois de l'année.",
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx2, false),
                          child: const Text("Corriger le montant")),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange, foregroundColor: Colors.white),
                        onPressed: () => Navigator.pop(ctx2, true),
                        child: const Text("Confirmer quand même"),
                      ),
                    ],
                  ),
                );
                if (continuer != true) {
                  setStateDialog(() => isSubmitting = false);
                  return;
                }
              }
            }

            final List<Map<String, dynamic>> nouvellesTransactions = viaDeblocage
                ? widget.fraisScolaires.handlePaymentMoisDebloque(eleve, mois, amount)
                : widget.fraisScolaires.handlePayment(eleve, mois, amount);

            if (eleve.moisDebloque != null) {
              final moisDeb = eleve.moisDebloque!;
              final requisDeb = widget.fraisScolaires
                  .getRequiredForMonthForEleve(eleve, moisDeb);
              if ((eleve.paid[moisDeb] ?? 0) >= requisDeb) {
                eleve.moisDebloque = null;
              }
            }

            await widget.fraisScolaires.saveData();
            if (ctx.mounted) Navigator.pop(ctx);

            if (mounted) {
              _filterEleves();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("✅ Paiement enregistré avec succès")),
              );

              if (_receiptsLocked) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                          "🔒 Impression bloquée : ce paiement a été "
                              "enregistré, mais aucun reçu n'a été imprimé "
                              "ni mis en attente."),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              } else {
                int nbRecusImprimes = 0;
                for (final transaction in nouvellesTransactions) {
                  final printed = await widget.fraisScolaires
                      .printOrQueuePrincipalReceipt(
                      eleve: eleve, transaction: transaction);
                  transaction['receiptConfirmed'] = printed;
                  if (printed) nbRecusImprimes++;
                }
                if (nouvellesTransactions.isNotEmpty) {
                  await widget.fraisScolaires.saveData();
                }

                if (mounted) {
                  final int totalRecus = nouvellesTransactions.length;
                  String message;
                  Color color;
                  if (totalRecus == 0) {
                    message = "Aucune transaction créée.";
                    color = Colors.orange;
                  } else if (nbRecusImprimes == totalRecus) {
                    message = totalRecus == 1
                        ? "🖨️ Reçu imprimé avec succès"
                        : "🖨️ $nbRecusImprimes reçu(s) imprimé(s) avec succès "
                        "(paiement réparti sur $totalRecus mois)";
                    color = Colors.green;
                  } else if (nbRecusImprimes == 0) {
                    message = totalRecus == 1
                        ? "📥 Aucune imprimante disponible — le reçu sortira "
                        "automatiquement dès qu'une imprimante sera prête."
                        : "📥 $totalRecus reçu(s) en attente d'impression.";
                    color = Colors.orange;
                  } else {
                    message = "🖨️ $nbRecusImprimes/$totalRecus reçu(s) imprimé(s).";
                    color = Colors.orange;
                  }
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
                }
              }
            }
          }

          return AlertDialog(
            title: Text("Paiement - $mois (${eleve.section})"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (viaDeblocageAffichage)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withAlpha(20),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.indigo),
                      ),
                      child: Text(
                        "🔓 Mois déverrouillé : le montant complétera d'abord "
                            "\"$mois\", puis le surplus sera réparti sur "
                            "\"${premierPrioritaire ?? ''}\" et les mois suivants.",
                        style: const TextStyle(color: Colors.indigo, fontSize: 11.5),
                      ),
                    ),
                  ),
                if (eleve.montantMensuelPersonnalise != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withAlpha(20),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.indigo),
                      ),
                      child: Text(
                        "⭐ Cet élève a un montant mensuel personnalisé : "
                            "${eleve.montantMensuelPersonnalise!.toStringAsFixed(0)} FC/mois "
                            "(exception de paiement).",
                        style: const TextStyle(color: Colors.indigo, fontSize: 11.5),
                      ),
                    ),
                  ),
                if (_receiptsLocked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.red.withAlpha(25),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.red),
                      ),
                      child: const Text(
                        "🔒 Impression bloquée : ce paiement sera enregistré, "
                            "mais aucun reçu ne sera imprimé ni mis en attente.",
                        style: TextStyle(color: Colors.red, fontSize: 11.5),
                      ),
                    ),
                  ),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  enabled: !isSubmitting,
                  decoration: const InputDecoration(labelText: "Montant (FC)"),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting ? null : () => Navigator.pop(ctx),
                child: const Text("Annuler"),
              ),
              ElevatedButton(
                onPressed: isSubmitting ? null : onConfirmPressed,
                child: isSubmitting
                    ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text("Confirmer"),
              ),
            ],
          );
        },
      ),
    );
  }
}