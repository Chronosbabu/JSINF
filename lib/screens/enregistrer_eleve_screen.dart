import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import '../frais_scolaires.dart';
import '../models.dart';

class EnregistrerEleveScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const EnregistrerEleveScreen({super.key, required this.fraisScolaires});

  @override
  State<EnregistrerEleveScreen> createState() => _EnregistrerEleveScreenState();
}

class _EnregistrerEleveScreenState extends State<EnregistrerEleveScreen> {
  final nomController = TextEditingController();
  final postNomController = TextEditingController();
  final prenomController = TextEditingController();

  String? selectedSection;
  String? selectedClasseNumero;
  String? selectedSousClasse;

  // Focus pour navigation rapide
  final FocusNode nomFocus = FocusNode();
  final FocusNode postNomFocus = FocusNode();
  final FocusNode prenomFocus = FocusNode();

  bool _isSaving = false;

  // ==========================================================================
  // AUTRES INFORMATIONS SUR L'IDENTITÉ DE L'ÉLÈVE (OPTIONNEL)
  // ==========================================================================
  final pereNomController = TextEditingController();
  final mereNomController = TextEditingController();
  final adresseController = TextEditingController();
  DateTime? selectedDateNaissance;
  Uint8List? photoBytes;
  final Map<String, TextEditingController> customFieldsControllers = {};

  // ==========================================================================
  // PAIEMENT OPTIONNEL DÈS L'INSCRIPTION, CUMULABLE.
  // ==========================================================================
  bool _payerPrincipal = false;
  final _montantPrincipalController = TextEditingController();

  bool _payerAutreFrais = false;
  AutreFrais? _selectedAutreFraisPaiement;

  @override
  void initState() {
    super.initState();
    if (widget.fraisScolaires.config.sections.isNotEmpty) {
      selectedSection = widget.fraisScolaires.config.sections.first;
    }
    // ⚡ NOUVEAU — à l'ouverture de cet écran de paiement/inscription, on
    // tente de vider la file d'attente des reçus non encore imprimés (ex:
    // paiements faits pendant que l'imprimante était débranchée). Cela
    // fonctionne même après un redémarrage complet de l'application ou de
    // l'ordinateur, puisque cette file est persistée dans le fichier JSON
    // local (voir FraisScolaires.receiptQueue / flushReceiptQueue).
    _flushPendingReceipts();
  }

  // ⚡ NOUVEAU
  Future<void> _flushPendingReceipts() async {
    final count = await widget.fraisScolaires.flushReceiptQueue();
    if (mounted && count > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              "🖨️ $count reçu(s) en attente ont été imprimés automatiquement."),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  void dispose() {
    nomController.dispose();
    postNomController.dispose();
    prenomController.dispose();
    nomFocus.dispose();
    postNomFocus.dispose();
    prenomFocus.dispose();
    pereNomController.dispose();
    mereNomController.dispose();
    adresseController.dispose();
    for (var c in customFieldsControllers.values) {
      c.dispose();
    }
    _montantPrincipalController.dispose();
    super.dispose();
  }

  void _clearFields() {
    nomController.clear();
    postNomController.clear();
    prenomController.clear();
    pereNomController.clear();
    mereNomController.clear();
    adresseController.clear();
    for (var c in customFieldsControllers.values) {
      c.clear();
    }
    setState(() {
      selectedClasseNumero = null;
      selectedSousClasse = null;
      // On garde la section sélectionnée pour accélérer la saisie en série
      selectedDateNaissance = null;
      photoBytes = null;
      _payerPrincipal = false;
      _montantPrincipalController.clear();
      _payerAutreFrais = false;
      _selectedAutreFraisPaiement = null;
    });
    nomFocus.requestFocus();
  }

  // ==================== GÉNÉRATION D'ID 100% LOCALE ====================
  String _generateLocalStudentId() {
    final config = widget.fraisScolaires.config;

    String schoolInitials = config.schoolName
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w.replaceAll(RegExp(r'[^A-Za-z0-9]'), ''))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0])
        .join()
        .toUpperCase();
    if (schoolInitials.isEmpty) schoolInitials = "EL";

    final yearPart = widget.fraisScolaires.currentYear.split('-').first;

    final existingIds = <String>{};
    for (var yearData in widget.fraisScolaires.history.values) {
      for (var e in yearData.eleves) {
        if (e.id.isNotEmpty) existingIds.add(e.id);
      }
    }
    for (var e in widget.fraisScolaires.currentData.eleves) {
      if (e.id.isNotEmpty) existingIds.add(e.id);
    }

    int sequence = widget.fraisScolaires.currentData.eleves.length + 1;
    String candidate;
    do {
      candidate = "$schoolInitials$yearPart-${sequence.toString().padLeft(4, '0')}";
      sequence++;
    } while (existingIds.contains(candidate));

    return candidate;
  }

  // ==================== AJOUT MANUEL D'UN NUMÉRO DE CLASSE ====================
  Future<void> _addClasseNumeroDialog() async {
    if (selectedSection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Veuillez d'abord choisir une section")),
      );
      return;
    }
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Nouveau numéro de classe"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: "Ex: 7ème, 1ère...",
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () async {
              final value = controller.text.trim();
              if (value.isNotEmpty) {
                await widget.fraisScolaires.addClasseNumero(selectedSection!, value);
                if (mounted) {
                  setState(() {
                    selectedClasseNumero = value;
                    selectedSousClasse = null;
                    _selectedAutreFraisPaiement = null;
                  });
                }
              }
              if (mounted) Navigator.pop(ctx);
            },
            child: const Text("Ajouter"),
          ),
        ],
      ),
    );
  }

  // ==================== AJOUT MANUEL D'UNE SOUS-CLASSE ====================
  Future<void> _addSousClasseDialog() async {
    if (selectedSection == null || selectedClasseNumero == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Veuillez d'abord choisir une section et un numéro de classe")),
      );
      return;
    }
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Nouvelle sous-classe pour $selectedClasseNumero"),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: "Ex: A, B, C...",
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () async {
              final value = controller.text.trim();
              if (value.isNotEmpty) {
                await widget.fraisScolaires.addSubClasse(
                  selectedSection!,
                  selectedClasseNumero!,
                  value,
                );
                if (mounted) {
                  setState(() {
                    selectedSousClasse = value;
                    _selectedAutreFraisPaiement = null;
                  });
                }
              }
              if (mounted) Navigator.pop(ctx);
            },
            child: const Text("Ajouter"),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // HELPERS POUR LE PAIEMENT À L'INSCRIPTION
  // ==========================================================================
  String? get _classeCompleteSelectionnee {
    if (selectedClasseNumero == null) return null;
    return widget.fraisScolaires
        .buildFullClasseName(selectedClasseNumero!, selectedSousClasse);
  }

  double? get _montantMensuelIndicatif {
    if (selectedSection == null) return null;
    return widget.fraisScolaires.getRequiredForMonth(
      widget.fraisScolaires.months.first,
      selectedSection!,
      _classeCompleteSelectionnee,
    );
  }

  List<AutreFrais> get _autresFraisEligibles {
    if (selectedSection == null) return [];
    final classeComplete = _classeCompleteSelectionnee;
    return widget.fraisScolaires.getAutresFrais().where((f) {
      switch (f.scope) {
        case 'section':
          return f.section == selectedSection;
        case 'classe':
          return classeComplete != null && f.classe == classeComplete;
        case 'all':
        default:
          return true;
      }
    }).toList();
  }

  // ==========================================================================
  // BOÎTE DE DIALOGUE "AUTRES INFORMATIONS" (OPTIONNEL)
  // ==========================================================================
  Future<void> _showAutresInfosDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> pickPhoto() async {
            const typeGroup = XTypeGroup(
              label: 'images',
              extensions: ['png', 'jpg', 'jpeg'],
            );
            final file = await openFile(acceptedTypeGroups: [typeGroup]);
            if (file == null) return;
            final bytes = await file.readAsBytes();
            setDialogState(() => photoBytes = bytes);
          }

          Future<void> pickDate() async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: ctx,
              initialDate: selectedDateNaissance ?? DateTime(now.year - 10),
              firstDate: DateTime(1990),
              lastDate: now,
            );
            if (picked != null) {
              setDialogState(() => selectedDateNaissance = picked);
            }
          }

          Future<void> addCustomField() async {
            final questionController = TextEditingController();
            final question = await showDialog<String>(
              context: ctx,
              builder: (ctx2) => AlertDialog(
                title: const Text("Nouvelle Question Personnalisée"),
                content: TextField(
                  controller: questionController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: "Ex: Numéro de téléphone du parent",
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx2),
                    child: const Text("Annuler"),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      final q = questionController.text.trim();
                      if (q.isNotEmpty) Navigator.pop(ctx2, q);
                    },
                    child: const Text("Ajouter"),
                  ),
                ],
              ),
            );
            if (question != null && question.isNotEmpty) {
              if (!customFieldsControllers.containsKey(question)) {
                setDialogState(() {
                  customFieldsControllers[question] = TextEditingController();
                });
              }
            }
          }

          void removeCustomField(String question) {
            setDialogState(() {
              customFieldsControllers[question]?.dispose();
              customFieldsControllers.remove(question);
            });
          }

          final dateLabel = selectedDateNaissance != null
              ? "${selectedDateNaissance!.day.toString().padLeft(2, '0')}/"
              "${selectedDateNaissance!.month.toString().padLeft(2, '0')}/"
              "${selectedDateNaissance!.year}"
              : "Non renseignée";

          return AlertDialog(
            title: const Text("Autres Informations (Optionnel)"),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Ces informations sont facultatives. Remplissez uniquement "
                          "ce dont votre école a besoin.",
                      style: TextStyle(color: Colors.grey, fontSize: 12.5),
                    ),
                    const SizedBox(height: 16),

                    Center(
                      child: Column(
                        children: [
                          CircleAvatar(
                            radius: 45,
                            backgroundColor: Colors.grey.shade200,
                            backgroundImage: photoBytes != null
                                ? MemoryImage(photoBytes!)
                                : null,
                            child: photoBytes == null
                                ? const Icon(Icons.person, size: 45, color: Colors.grey)
                                : null,
                          ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            icon: const Icon(Icons.photo_camera, size: 18),
                            label: Text(
                              photoBytes == null ? "Choisir une photo" : "Changer la photo",
                            ),
                            onPressed: pickPhoto,
                          ),
                          if (photoBytes != null)
                            TextButton.icon(
                              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                              label: const Text("Retirer", style: TextStyle(color: Colors.red)),
                              onPressed: () => setDialogState(() => photoBytes = null),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    TextField(
                      controller: pereNomController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: "Nom du père",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: mereNomController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: "Nom de la mère",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: adresseController,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: "Adresse",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: pickDate,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: "Date de naissance",
                          border: OutlineInputBorder(),
                          suffixIcon: Icon(Icons.calendar_today, size: 18),
                        ),
                        child: Text(dateLabel),
                      ),
                    ),

                    if (customFieldsControllers.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Text(
                        "Questions Personnalisées",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      ...customFieldsControllers.entries.map(
                            (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: entry.value,
                                  decoration: InputDecoration(
                                    labelText: entry.key,
                                    border: const OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.red, size: 20),
                                tooltip: "Supprimer cette question",
                                onPressed: () => removeCustomField(entry.key),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text("Ajouter une Question Personnalisée"),
                      onPressed: addCustomField,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Terminé"),
              ),
            ],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  int _countFilledExtras() {
    int count = 0;
    if (pereNomController.text.trim().isNotEmpty) count++;
    if (mereNomController.text.trim().isNotEmpty) count++;
    if (adresseController.text.trim().isNotEmpty) count++;
    if (selectedDateNaissance != null) count++;
    if (photoBytes != null) count++;
    count += customFieldsControllers.values
        .where((c) => c.text.trim().isNotEmpty)
        .length;
    return count;
  }

  Future<void> _ajouterEleve() async {
    if (nomController.text.trim().isEmpty ||
        postNomController.text.trim().isEmpty ||
        prenomController.text.trim().isEmpty ||
        selectedSection == null ||
        selectedClasseNumero == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Veuillez remplir tous les champs")),
      );
      return;
    }

    // ==========================================================================
    // ⚡ NOUVEAU — UNICITÉ STRICTE NOM + POST-NOM + PRÉNOM
    //
    // Deux élèves peuvent partager deux de ces trois informations (même nom
    // et même post-nom, ou même nom et même prénom, etc.), mais JAMAIS les
    // TROIS à la fois. On vérifie ici via `findDuplicateFullName` (méthode
    // déjà présente dans FraisScolaires) avant toute création : si un
    // élève strictement homonyme existe déjà, l'inscription est bloquée et
    // l'utilisateur doit corriger au moins un des trois champs (typiquement
    // le prénom).
    // ==========================================================================
    final duplicateEleve = widget.fraisScolaires.findDuplicateFullName(
      nom: nomController.text.trim(),
      postNom: postNomController.text.trim(),
      prenom: prenomController.text.trim(),
    );
    if (duplicateEleve != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "⚠️ Un élève avec exactement le même Nom, Post-nom et Prénom "
                "existe déjà (${duplicateEleve.classe} - ID: ${duplicateEleve.id}). "
                "Veuillez corriger au moins un des trois champs (par exemple "
                "le prénom) pour continuer.",
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    double? montantPrincipalAPayer;
    if (_payerPrincipal) {
      montantPrincipalAPayer =
          double.tryParse(_montantPrincipalController.text.trim());
      if (montantPrincipalAPayer == null || montantPrincipalAPayer <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                "Veuillez indiquer un montant valide pour le paiement du frais principal, "
                    "ou décochez \"Payer le Frais Principal\"."),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    if (_payerAutreFrais && _selectedAutreFraisPaiement == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Veuillez choisir un frais additionnel à payer, ou "
                  "décochez \"Payer un Autre Frais\"."),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      String generatedId = _generateLocalStudentId();

      String classeFinale = widget.fraisScolaires.buildFullClasseName(
        selectedClasseNumero!,
        selectedSousClasse,
      );

      String dateNaissanceStr = '';
      if (selectedDateNaissance != null) {
        final d = selectedDateNaissance!;
        String two(int n) => n.toString().padLeft(2, '0');
        dateNaissanceStr = "${two(d.day)}/${two(d.month)}/${d.year}";
      }

      final Map<String, String> customFieldsMap = {
        for (var entry in customFieldsControllers.entries)
          entry.key: entry.value.text.trim(),
      }..removeWhere((k, v) => v.isEmpty);

      final nouvelEleve = Eleve(
        id: generatedId,
        nom: nomController.text.trim(),
        postNom: postNomController.text.trim(),
        prenom: prenomController.text.trim(),
        classe: classeFinale,
        section: selectedSection!,
        pereNom: pereNomController.text.trim(),
        mereNom: mereNomController.text.trim(),
        adresse: adresseController.text.trim(),
        dateNaissance: dateNaissanceStr,
        photoBase64: photoBytes != null ? base64Encode(photoBytes!) : null,
        customFields: customFieldsMap,
      );

      widget.fraisScolaires.currentData.eleves.add(nouvelEleve);

      // ==========================================================================
      // APPLICATION DES DEUX PAIEMENTS OPTIONNELS, DE MANIÈRE CUMULABLE.
      //
      // ⚡ CORRIGÉ — `handlePayment` renvoie désormais la liste des
      // transactions qu'il vient de créer (une par mois affecté, plus
      // l'éventuelle transaction d'excédent sur le dernier mois si le
      // montant dépasse un mois). On conserve cette liste pour pouvoir
      // imprimer (ou mettre en file d'attente) UN REÇU PAR TRANSACTION,
      // exactement comme dans l'écran "Paiements des Élèves".
      // ==========================================================================
      String? moisPrincipalPaye;
      List<Map<String, dynamic>> transactionsPrincipal = [];
      if (_payerPrincipal && montantPrincipalAPayer != null) {
        moisPrincipalPaye = widget.fraisScolaires.months.first;
        transactionsPrincipal = widget.fraisScolaires.handlePayment(
          nouvelEleve,
          moisPrincipalPaye,
          montantPrincipalAPayer,
        );
      }

      AutreFrais? autreFraisPaye;
      if (_payerAutreFrais && _selectedAutreFraisPaiement != null) {
        final fraisChoisi = _selectedAutreFraisPaiement!;
        await widget.fraisScolaires.payAutreFrais(
          frais: fraisChoisi,
          eleve: nouvelEleve,
          enregistrePar: 'Direction',
        );
        autreFraisPaye = fraisChoisi;
      }

      await widget.fraisScolaires.saveData(); // Sauvegarde locale (fichier sur l'appareil)

      // ==========================================================================
      // ⚡ CORRIGÉ — IMPRESSION DÉSORMAIS GÉRÉE EXCLUSIVEMENT PAR LE SYSTÈME
      // CENTRALISÉ DE FraisScolaires (anti-doublon + file d'attente
      // persistante) : voir `printOrQueuePrincipalReceipt` et
      // `printOrQueueAutreFraisReceipt`. Avant, cet écran imprimait
      // directement lui-même (méthodes locales désormais supprimées), sans
      // jamais vérifier si un reçu identique avait déjà été imprimé
      // ailleurs, et sans jamais mettre en file d'attente si l'imprimante
      // était débranchée. Maintenant :
      //   - Si un reçu identique (même transaction) a déjà été imprimé une
      //     fois, peu importe depuis quel écran, il ne sera JAMAIS
      //     réimprimé.
      //   - Si aucune imprimante n'est branchée, le reçu est mis en attente
      //     et sortira automatiquement dès qu'une imprimante redevient
      //     disponible (même après extinction complète de l'ordinateur ou
      //     de l'application), voir `flushReceiptQueue`.
      //
      // ⚡ CORRIGÉ #2 — `printOrQueuePrincipalReceipt` attend désormais un
      // paramètre `transaction:` (et non plus `mois:` / `montantPaye:`).
      // On imprime donc UN REÇU PAR TRANSACTION créée par `handlePayment`.
      // ==========================================================================
      int nbRecusPrincipalImprimes = 0;
      for (final transaction in transactionsPrincipal) {
        final printed = await widget.fraisScolaires.printOrQueuePrincipalReceipt(
          eleve: nouvelEleve,
          transaction: transaction,
        );
        transaction['receiptConfirmed'] = printed;
        if (printed) nbRecusPrincipalImprimes++;
      }
      if (transactionsPrincipal.isNotEmpty) {
        await widget.fraisScolaires.saveData();
      }
      final bool principalRecuImprimeMaintenant =
          transactionsPrincipal.isNotEmpty &&
              nbRecusPrincipalImprimes == transactionsPrincipal.length;

      bool autreFraisRecuImprimeMaintenant = false;
      if (autreFraisPaye != null) {
        autreFraisRecuImprimeMaintenant =
        await widget.fraisScolaires.printOrQueueAutreFraisReceipt(
          eleve: nouvelEleve,
          frais: autreFraisPaye,
        );
      }

      if (!mounted) return;

      String messagePaiement = '';
      if (moisPrincipalPaye != null && montantPrincipalAPayer != null) {
        messagePaiement +=
        "\n💰 Frais Principal : ${montantPrincipalAPayer.toStringAsFixed(0)} FC"
            "${principalRecuImprimeMaintenant ? '' : ' (reçu en attente d\'impression)'}";
      }
      if (autreFraisPaye != null) {
        messagePaiement +=
        "\n💰 ${autreFraisPaye.nom} : ${autreFraisPaye.montant.toStringAsFixed(0)} FC"
            "${autreFraisRecuImprimeMaintenant ? '' : ' (reçu en attente d\'impression)'}";
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              "✅ ${nouvelEleve.nom} ${nouvelEleve.postNom} ajouté\nID: ${nouvelEleve.id}$messagePaiement"),
          duration: const Duration(seconds: 3),
        ),
      );
      _clearFields();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur lors de l'ajout : $e")),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Widget _buildPaiementInscriptionSection() {
    final montantMensuel = _montantMensuelIndicatif;
    final autresFraisEligibles = _autresFraisEligibles;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Paiement à l'inscription (optionnel)",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const SizedBox(height: 4),
        const Text(
          "Vous pouvez encaisser le Frais Principal, un Autre Frais, "
              "ou les deux à la fois, directement ici sans repasser par "
              "un autre écran.",
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 12),

        Card(
          elevation: 2,
          color: Colors.indigo.withAlpha(12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.indigo.withAlpha(60)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Row(
                    children: [
                      Icon(Icons.school, size: 20, color: Colors.indigo),
                      SizedBox(width: 8),
                      Text(
                        "Payer le Frais Principal",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  subtitle: const Text(
                    "Optionnel — encaisse le frais mensuel principal dès "
                        "l'inscription.",
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _payerPrincipal,
                  activeColor: Colors.indigo,
                  onChanged: (value) =>
                      setState(() => _payerPrincipal = value),
                ),
                if (_payerPrincipal) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _montantPrincipalController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: "Montant à payer (FC)",
                      border: const OutlineInputBorder(),
                      helperText: montantMensuel != null
                          ? "Frais mensuel habituel pour cette classe : "
                          "${montantMensuel.toStringAsFixed(0)} FC"
                          : null,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    "Le paiement démarre automatiquement au premier mois de "
                        "l'année scolaire (Septembre), comme dans \"Paiements "
                        "des Élèves\". Si le montant dépasse un mois, il est "
                        "reporté automatiquement sur les mois suivants.",
                    style: TextStyle(fontSize: 11.5, color: Colors.grey),
                  ),
                ],
              ],
            ),
          ),
        ),

        const SizedBox(height: 14),

        Card(
          elevation: 2,
          color: Colors.teal.withAlpha(12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.teal.withAlpha(60)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Row(
                    children: [
                      Icon(Icons.receipt_long, size: 20, color: Colors.teal),
                      SizedBox(width: 8),
                      Text(
                        "Payer un Autre Frais",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  subtitle: const Text(
                    "Optionnel — encaisse un frais additionnel (ex: Frais "
                        "de l'État, Frais d'Aide...) dès l'inscription.",
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _payerAutreFrais,
                  activeColor: Colors.teal,
                  onChanged: (value) =>
                      setState(() => _payerAutreFrais = value),
                ),
                if (_payerAutreFrais) ...[
                  const SizedBox(height: 8),
                  if (autresFraisEligibles.isEmpty)
                    const Text(
                      "Aucun frais additionnel ne s'applique à la section/classe "
                          "sélectionnée. Allez dans Paramètres > \"Autres Frais de "
                          "Paiement\" pour en ajouter.",
                      style: TextStyle(color: Colors.red, fontSize: 12.5),
                    )
                  else
                    DropdownButtonFormField<AutreFrais>(
                      value: autresFraisEligibles
                          .contains(_selectedAutreFraisPaiement)
                          ? _selectedAutreFraisPaiement
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: "Frais additionnel à payer",
                        border: OutlineInputBorder(),
                      ),
                      items: autresFraisEligibles
                          .map(
                            (f) => DropdownMenuItem(
                          value: f,
                          child: Text(
                              "${f.nom} — ${f.montant.toStringAsFixed(0)} FC"),
                        ),
                      )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _selectedAutreFraisPaiement = value),
                    ),
                ],
              ],
            ),
          ),
        ),

        if (_payerPrincipal && _payerAutreFrais) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.withAlpha(25),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green),
            ),
            child: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Les deux paiements (Frais Principal + Autre Frais) "
                        "seront enregistrés en même temps pour cet élève.",
                    style: TextStyle(fontSize: 12, color: Colors.green),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final classesNumeros = selectedSection != null
        ? widget.fraisScolaires.getClassesForSection(selectedSection!)
        : <String>[];

    final sousClasses = (selectedSection != null && selectedClasseNumero != null)
        ? widget.fraisScolaires.getSubClassesFor(selectedSection!, selectedClasseNumero!)
        : <String>[];

    final extrasCount = _countFilledExtras();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Ajouter des Élèves"),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Inscription Rapide d'Élève",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Remplissez le formulaire et ajoutez plusieurs élèves rapidement",
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 25),
            TextField(
              controller: nomController,
              focusNode: nomFocus,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: "Nom",
                border: OutlineInputBorder(),
              ),
              onEditingComplete: () => postNomFocus.requestFocus(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: postNomController,
              focusNode: postNomFocus,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: "Post-nom",
                border: OutlineInputBorder(),
              ),
              onEditingComplete: () => prenomFocus.requestFocus(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: prenomController,
              focusNode: prenomFocus,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: "Prénom",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            DropdownButtonFormField<String>(
              value: selectedSection,
              decoration: const InputDecoration(
                labelText: "Section",
                border: OutlineInputBorder(),
                helperText: "Ex: Maternelle, Primaire, Secondaire...",
              ),
              items: widget.fraisScolaires.config.sections.map((section) {
                return DropdownMenuItem(value: section, child: Text(section));
              }).toList(),
              onChanged: (value) {
                setState(() {
                  selectedSection = value;
                  selectedClasseNumero = null;
                  selectedSousClasse = null;
                  _selectedAutreFraisPaiement = null;
                });
              },
            ),
            const SizedBox(height: 20),

            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: selectedClasseNumero,
                    decoration: const InputDecoration(
                      labelText: "Numéro de classe",
                      border: OutlineInputBorder(),
                    ),
                    items: classesNumeros.map((c) {
                      return DropdownMenuItem(value: c, child: Text(c));
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        selectedClasseNumero = value;
                        selectedSousClasse = null;
                        _selectedAutreFraisPaiement = null;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: "Ajouter un numéro de classe",
                  icon: const Icon(Icons.add_circle, color: Colors.indigo),
                  onPressed: _addClasseNumeroDialog,
                ),
              ],
            ),
            const SizedBox(height: 20),

            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: selectedSousClasse,
                    decoration: const InputDecoration(
                      labelText: "Sous-classe (optionnel)",
                      border: OutlineInputBorder(),
                      helperText: "Ex: A, B, C...",
                    ),
                    items: sousClasses.map((s) {
                      return DropdownMenuItem(value: s, child: Text(s));
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        selectedSousClasse = value;
                        _selectedAutreFraisPaiement = null;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: "Ajouter une sous-classe",
                  icon: const Icon(Icons.add_circle, color: Colors.indigo),
                  onPressed: _addSousClasseDialog,
                ),
              ],
            ),

            const SizedBox(height: 24),
            _buildPaiementInscriptionSection(),

            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                icon: _isSaving
                    ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
                    : const Icon(Icons.person_add, size: 28),
                label: Text(
                  _isSaving ? "Ajout en cours..." : "Ajouter l'Élève",
                  style: const TextStyle(fontSize: 18),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                ),
                onPressed: _isSaving ? null : _ajouterEleve,
              ),
            ),
            const SizedBox(height: 15),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.check),
                label: const Text("Terminer et Retourner"),
                onPressed: () => Navigator.pop(context),
              ),
            ),

            const SizedBox(height: 15),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.badge_outlined),
                label: Text(
                  extrasCount > 0
                      ? "Autres Informations ($extrasCount rempli(s))"
                      : "Autres Informations (Optionnel)",
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.indigo,
                  side: const BorderSide(color: Colors.indigo),
                ),
                onPressed: _showAutresInfosDialog,
              ),
            ),
            const SizedBox(height: 6),
            const Center(
              child: Text(
                "Nom du père, nom de la mère, adresse, date de naissance, photo, "
                    "et vos propres questions personnalisées.",
                style: TextStyle(color: Colors.grey, fontSize: 11.5),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 30),
            const Center(
              child: Text(
                "Les champs se vident automatiquement après chaque ajout\n"
                    "L'ID unique est généré automatiquement, hors ligne, pour chaque élève",
                style: TextStyle(color: Colors.grey, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}