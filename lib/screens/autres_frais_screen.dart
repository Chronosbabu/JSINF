import 'package:flutter/material.dart';
import '../frais_scolaires.dart';
import '../models.dart';

class AutresFraisScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const AutresFraisScreen({super.key, required this.fraisScolaires});

  @override
  State<AutresFraisScreen> createState() => _AutresFraisScreenState();
}

class _AutresFraisScreenState extends State<AutresFraisScreen> {
  final searchController = TextEditingController();
  AutreFrais? selectedFrais;
  final Set<String> selectedStudentIds = {};
  bool _processing = false;

  // ⚡ NOUVEAU — Filtres optionnels Section / Classe pour la fenêtre de
  // paiement. Ils ne changent JAMAIS l'éligibilité au frais (celle-ci
  // reste définie par le scope du frais dans les Paramètres) : ils
  // servent uniquement à naviguer plus facilement dans la liste des
  // élèves et à consulter la répartition par administration limitée à
  // une section/classe précise (voir `_showAdminRepartitionDialog`).
  String? filterSection;
  String? filterClasse;

  @override
  void initState() {
    super.initState();
    final frais = widget.fraisScolaires.getAutresFrais();
    if (frais.isNotEmpty) selectedFrais = frais.first;
    searchController.addListener(() => setState(() {}));
    // ⚡ NOUVEAU — vide la file d'attente des reçus non encore imprimés à
    // l'ouverture de l'écran (voir FraisScolaires.flushReceiptQueue). Cela
    // fonctionne même si l'imprimante était débranchée au moment du
    // paiement et que l'application/l'ordinateur a été éteint entretemps.
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
    searchController.dispose();
    super.dispose();
  }

  List<Eleve> get _eligibleFiltered {
    if (selectedFrais == null) return [];
    final query = searchController.text.toLowerCase().trim();
    var eligible =
    widget.fraisScolaires.getEligibleStudentsForAutreFrais(selectedFrais!);

    // ⚡ NOUVEAU — filtres Section/Classe, purement pour la navigation
    // dans cette fenêtre de paiement (n'affecte jamais l'éligibilité
    // définie dans les Paramètres).
    if (filterSection != null) {
      eligible = eligible.where((e) => e.section == filterSection).toList();
    }
    if (filterClasse != null) {
      eligible = eligible.where((e) => e.classe == filterClasse).toList();
    }

    if (query.isEmpty) return eligible;
    return eligible.where((e) {
      final idMatch = e.id.toLowerCase().contains(query);
      final nameMatch =
      '${e.nom} ${e.postNom} ${e.prenom}'.toLowerCase().contains(query);
      return idMatch || nameMatch;
    }).toList();
  }

  String _scopeLabel(AutreFrais f) {
    switch (f.scope) {
      case 'section':
        return f.section ?? 'Section';
      case 'classe':
        return f.classe ?? 'Classe';
      default:
        return 'Toutes les classes';
    }
  }

  void _toggleStudent(Eleve e) {
    if (selectedFrais == null) return;
    if (widget.fraisScolaires.hasPaidAutreFrais(e, selectedFrais!)) return;
    setState(() {
      if (selectedStudentIds.contains(e.id)) {
        selectedStudentIds.remove(e.id);
      } else {
        selectedStudentIds.add(e.id);
      }
    });
  }

  // ==========================================================================
  // ⚡ CORRIGÉ — L'IMPRESSION PASSE DÉSORMAIS EXCLUSIVEMENT PAR LE SYSTÈME
  // CENTRALISÉ ANTI-DOUBLON + FILE D'ATTENTE DE FraisScolaires
  // (`printOrQueueAutreFraisReceipt`). Un reçu déjà imprimé pour cet élève
  // et ce frais précis ne sera plus jamais réimprimé automatiquement, d'où
  // que vienne la demande. Si aucune imprimante n'est branchée, le reçu
  // reste en attente et sort automatiquement dès qu'une imprimante devient
  // disponible (voir `flushReceiptQueue`, appelée à l'ouverture de l'écran).
  //
  // ⚡ SUR DEMANDE DE LA DIRECTION — tous les boutons de réimpression
  // manuelle ont été retirés de cet écran (le personnel se trompait avec
  // des reçus réimprimés plus tard). La SEULE impression possible est
  // désormais automatique, immédiatement après le paiement.
  //
  // ⚡ NOUVEAU — TRANCHES : quand le frais fonctionne par tranches pour la
  // classe/section de l'élève, chaque paiement règle la PROCHAINE tranche
  // non payée de cet élève, et le reçu imprimé porte le nom de la tranche
  // (ex. "Frais de l'État - Deuxième tranche (2/3)") avec le montant de la
  // tranche. Chaque tranche a son propre reçu anti-doublon.
  // ==========================================================================

  Future<void> _payerUnSeul(Eleve eleve) async {
    if (selectedFrais == null) return;
    if (widget.fraisScolaires.hasPaidAutreFrais(eleve, selectedFrais!)) return;
    setState(() => _processing = true);
    final frais = selectedFrais!;
    try {
      final paiement =
      await widget.fraisScolaires.payAutreFrais(frais: frais, eleve: eleve);
      final printed = await widget.fraisScolaires.printOrQueueAutreFraisReceipt(
        eleve: eleve,
        frais: frais,
        paiement: paiement,
      );
      final String libelleTranche = paiement.trancheLibelle.isEmpty
          ? ''
          : ' (${paiement.trancheLibelle})';
      if (mounted) {
        setState(() {
          selectedStudentIds.remove(eleve.id);
          _processing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              printed
                  ? "✅ ${frais.nom}$libelleTranche enregistré et reçu imprimé pour ${eleve.nom} ${eleve.prenom}"
                  : "✅ ${frais.nom}$libelleTranche enregistré pour ${eleve.nom} ${eleve.prenom} — reçu en attente d'impression",
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _processing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("❌ Paiement impossible : $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _payerSelection() async {
    if (selectedFrais == null || selectedStudentIds.isEmpty) return;
    setState(() => _processing = true);

    final frais = selectedFrais!;
    final students = widget.fraisScolaires.currentData.eleves
        .where((e) => selectedStudentIds.contains(e.id))
        .toList();

    int success = 0;
    int printedCount = 0;
    for (final eleve in students) {
      if (widget.fraisScolaires.hasPaidAutreFrais(eleve, frais)) continue;
      try {
        final paiement = await widget.fraisScolaires
            .payAutreFrais(frais: frais, eleve: eleve);
        success++;
        final printed =
        await widget.fraisScolaires.printOrQueueAutreFraisReceipt(
          eleve: eleve,
          frais: frais,
          paiement: paiement,
        );
        if (printed) printedCount++;
      } catch (_) {
        // Élève déjà soldé entre-temps : on passe au suivant.
      }
    }

    if (mounted) {
      setState(() {
        selectedStudentIds.clear();
        _processing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ Paiement de \"${frais.nom}\" enregistré pour $success élève(s)"
                "${printedCount < success ? ' ($printedCount reçu(s) imprimé(s), le reste en attente)' : (success > 0 ? ' — tous les reçus imprimés' : '')}",
          ),
        ),
      );
    }
  }

  void _confirmPaiementUnique(Eleve eleve) {
    if (selectedFrais == null) return;
    // ⚡ NOUVEAU — montant réellement dû par CET élève maintenant : montant
    // de la prochaine tranche si le frais fonctionne par tranches, sinon
    // montant complet (qui peut varier selon sa section/classe, voir
    // FraisScolaires.getMontantAutreFraisPourEleve).
    final prochaine = widget.fraisScolaires
        .getProchaineTrancheAutreFrais(selectedFrais!, eleve);
    final double montant = widget.fraisScolaires
        .getMontantProchainPaiementAutreFrais(selectedFrais!, eleve);
    final tranches =
    widget.fraisScolaires.getTranchesPourEleve(selectedFrais!, eleve);
    String libelleTranche = '';
    if (prochaine != null) {
      final idx = tranches.indexWhere((t) => t.id == prochaine.id);
      libelleTranche =
      "${prochaine.nom} (${idx + 1}/${tranches.length}) — ";
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(selectedFrais!.nom),
        content: Text(
          "Confirmer le paiement de $libelleTranche"
              "${montant.toStringAsFixed(0)} FC pour "
              "${eleve.nom} ${eleve.prenom} (${eleve.classe}) ?",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _payerUnSeul(eleve);
            },
            child: const Text("Confirmer"),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // TOTAUX PAR CLASSE, PAR OPTION ET PAR TRANCHE POUR LE FRAIS SÉLECTIONNÉ
  // (purement informatif, n'a rien à voir avec l'impression).
  // ==========================================================================
  Map<String, double> _totalsByClasseForSelected() {
    final totals = <String, double>{};
    if (selectedFrais == null) return totals;
    final paiements = widget.fraisScolaires
        .getAutresFraisPaiementsForYear()
        .where((p) => p.autreFraisId == selectedFrais!.id);
    for (final p in paiements) {
      Eleve? eleve;
      for (final e in widget.fraisScolaires.currentData.eleves) {
        if (e.id == p.eleveId) {
          eleve = e;
          break;
        }
      }
      final label = eleve != null ? eleve.classe : "Élève(s) introuvable(s)";
      totals[label] = (totals[label] ?? 0) + p.montant;
    }
    return totals;
  }

  Map<String, double> _totalsByOptionForSelected() {
    final totals = <String, double>{};
    if (selectedFrais == null) return totals;
    final paiements = widget.fraisScolaires
        .getAutresFraisPaiementsForYear()
        .where((p) => p.autreFraisId == selectedFrais!.id);
    for (final p in paiements) {
      Eleve? eleve;
      for (final e in widget.fraisScolaires.currentData.eleves) {
        if (e.id == p.eleveId) {
          eleve = e;
          break;
        }
      }
      final label = eleve != null ? eleve.section : "Élève(s) introuvable(s)";
      totals[label] = (totals[label] ?? 0) + p.montant;
    }
    return totals;
  }

  // ⚡ NOUVEAU — total collecté par tranche pour le frais sélectionné.
  // Les paiements faits sans tranche apparaissent sous "Paiement unique".
  Map<String, double> _totalsByTrancheForSelected() {
    final totals = <String, double>{};
    if (selectedFrais == null) return totals;
    final paiements = widget.fraisScolaires
        .getAutresFraisPaiementsForYear()
        .where((p) => p.autreFraisId == selectedFrais!.id);
    for (final p in paiements) {
      final label =
      p.trancheNom.trim().isEmpty ? "Paiement unique" : p.trancheNom.trim();
      totals[label] = (totals[label] ?? 0) + p.montant;
    }
    return totals;
  }

  List<MapEntry<String, double>> _sortedEntries(Map<String, double> map) {
    final entries = map.entries.toList();
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  void _showTotalsDialog() {
    if (selectedFrais == null) return;
    final frais = selectedFrais!;
    final byClasse = _sortedEntries(_totalsByClasseForSelected());
    final byOption = _sortedEntries(_totalsByOptionForSelected());
    final byTranche = _sortedEntries(_totalsByTrancheForSelected());
    final totalGeneral = byClasse.fold<double>(
        0.0, (sum, e) => sum + e.value);
    final bool afficherTranches =
    byTranche.any((e) => e.key != "Paiement unique");

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Totaux — ${frais.nom}"),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Total général : ${totalGeneral.toStringAsFixed(0)} FC",
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                const Text(
                  "Par option",
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.indigo),
                ),
                const SizedBox(height: 6),
                if (byOption.isEmpty)
                  const Text("Aucun paiement enregistré pour ce frais.",
                      style: TextStyle(fontSize: 12, color: Colors.grey))
                else
                  ...byOption.map(
                        (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text(e.key)),
                          Text(
                            "${e.value.toStringAsFixed(0)} FC",
                            style: const TextStyle(
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                const Text(
                  "Par classe",
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.indigo),
                ),
                const SizedBox(height: 6),
                if (byClasse.isEmpty)
                  const Text("Aucun paiement enregistré pour ce frais.",
                      style: TextStyle(fontSize: 12, color: Colors.grey))
                else
                  ...byClasse.map(
                        (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text(e.key)),
                          Text(
                            "${e.value.toStringAsFixed(0)} FC",
                            style: const TextStyle(
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (afficherTranches) ...[
                  const SizedBox(height: 18),
                  const Text(
                    "Par tranche",
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.indigo),
                  ),
                  const SizedBox(height: 6),
                  ...byTranche.map(
                        (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text(e.key)),
                          Text(
                            "${e.value.toStringAsFixed(0)} FC",
                            style: const TextStyle(
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Fermer"),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // ⚡ NOUVEAU — CONFIGURATION DES TRANCHES DIRECTEMENT DEPUIS CET ÉCRAN
  // ==========================================================================
  // Demande de la direction : les "Autres Frais" comme le Frais de l'État se
  // paient par tranches (Première, Deuxième, Troisième…). Plus besoin
  // d'aller dans les Paramètres : on choisit un frais déjà configuré (pour
  // telle section ou telle classe dans les Paramètres), on clique sur
  // "Tranches", et on ajoute les tranches pour la cible voulue :
  //   - toute l'école (seulement si le frais est défini pour toutes les
  //     classes),
  //   - une section,
  //   - une classe précise.
  //
  // Pour un élève, on applique les tranches de la cible la plus précise qui
  // en possède (classe, puis section, puis toute l'école). Les élèves dont
  // la classe a des tranches paient donc tranche par tranche (la prochaine
  // non payée), et non plus en une seule fois. Le reçu et le rapport PDF
  // reprennent le nom de la tranche.
  //
  // ⚠️ Les tranches n'ont AUCUN effet sur les frais principaux : tout passe
  // par les méthodes dédiées de FraisScolaires (`getTranchesPourCle`,
  // `addTranchePourAutreFrais`, `updateTranchePourAutreFrais`,
  // `deleteTranchePourAutreFrais`, …).
  // ==========================================================================
  void _showTranchesDialog() {
    if (selectedFrais == null) return;
    final frais = selectedFrais!;
    final fs = widget.fraisScolaires;

    // Cible de départ : celle du frais (section/classe définie dans les
    // Paramètres), ou le filtre actif de l'écran si le frais est global.
    String? cibleSection =
    frais.scope == 'all' ? filterSection : frais.section;
    String? cibleClasse;
    if (frais.scope == 'classe') {
      cibleClasse = frais.classe;
    } else if (cibleSection != null &&
        filterClasse != null &&
        cibleSection == filterSection) {
      cibleClasse = fs.classeNumeroFromFullClasse(filterClasse!);
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final List<String> sectionsDispo = frais.scope == 'all'
              ? List<String>.from(fs.config.sections)
              : <String>[if (frais.section != null) frais.section!];

          if (cibleSection != null && !sectionsDispo.contains(cibleSection)) {
            cibleSection = null;
            cibleClasse = null;
          }

          List<String> classesDispo = <String>[];
          if (cibleSection != null) {
            if (frais.scope == 'classe') {
              classesDispo = <String>[if (frais.classe != null) frais.classe!];
            } else {
              classesDispo = fs.getClassesForSection(cibleSection!);
            }
          }
          if (cibleClasse != null && !classesDispo.contains(cibleClasse)) {
            cibleClasse = null;
          }

          final bool sectionVerrouillee = frais.scope != 'all';
          final bool classeVerrouillee = frais.scope == 'classe';

          final String cle = fs.cleTranchePourCible(
            section: cibleSection,
            classeNumero: cibleClasse,
          );
          final List<AutreFraisTranche> tranches =
          fs.getTranchesPourCle(frais, cle);
          final double montantTotalFrais = fs.getMontantAutreFraisPourCible(
            frais,
            section: cibleSection,
            classeNumero: cibleClasse,
          );
          final double sommeTranches =
          tranches.fold(0.0, (sum, t) => sum + t.montant);
          final double resteARepartir = montantTotalFrais - sommeTranches;

          final String cibleLabel = cibleClasse != null
              ? "la classe $cibleClasse ($cibleSection)"
              : (cibleSection != null
              ? "la section $cibleSection"
              : "toute l'école");

          Future<void> rafraichir() async {
            setDialogState(() {});
            if (mounted) setState(() {});
          }

          Future<void> ajouterOuModifier({AutreFraisTranche? existante}) async {
            final bool? ok = await _showEditTrancheDialog(
              ctx,
              frais: frais,
              cle: cle,
              tranche: existante,
              nomSuggere: fs.nomTrancheSuggere(tranches.length + 1),
              montantSuggere: resteARepartir > 0 ? resteARepartir : 0,
            );
            if (ok == true) await rafraichir();
          }

          Future<void> supprimer(AutreFraisTranche t) async {
            final bool? confirme = await showDialog<bool>(
              context: ctx,
              builder: (ctx2) => AlertDialog(
                title: const Text("Supprimer cette tranche ?"),
                content: Text(
                  "Voulez-vous vraiment supprimer \"${t.nom}\" "
                      "(${t.montant.toStringAsFixed(0)} FC) pour $cibleLabel ?",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx2, false),
                    child: const Text("Annuler"),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white),
                    onPressed: () => Navigator.pop(ctx2, true),
                    child: const Text("Supprimer"),
                  ),
                ],
              ),
            );
            if (confirme != true) return;
            final bool supprimee = await fs.deleteTranchePourAutreFrais(
              autreFraisId: frais.id,
              cle: cle,
              trancheId: t.id,
            );
            if (!supprimee && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      "Impossible : des paiements ont déjà été enregistrés "
                          "pour cette tranche."),
                  backgroundColor: Colors.red,
                ),
              );
            }
            await rafraichir();
          }

          // Message de cohérence entre le montant du frais et les tranches.
          Widget messageCoherence() {
            if (tranches.isEmpty) {
              return const Text(
                "Aucune tranche pour cette cible : les élèves concernés "
                    "paient ce frais en une seule fois (sauf si une tranche "
                    "existe pour une cible plus large).",
                style: TextStyle(fontSize: 11, color: Colors.grey),
              );
            }
            if (resteARepartir.abs() < 0.5) {
              return const Text(
                "✅ La somme des tranches correspond exactement au montant "
                    "du frais.",
                style: TextStyle(fontSize: 11, color: Colors.green),
              );
            }
            if (resteARepartir > 0) {
              return Text(
                "⚠️ Il reste ${resteARepartir.toStringAsFixed(0)} FC à "
                    "répartir pour atteindre le montant du frais.",
                style: const TextStyle(fontSize: 11, color: Colors.orange),
              );
            }
            return Text(
              "⚠️ Les tranches dépassent le montant du frais de "
                  "${(-resteARepartir).toStringAsFixed(0)} FC.",
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            );
          }

          return AlertDialog(
            title: Text("Tranches — ${frais.nom}"),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Choisissez à qui s'appliquent les tranches :",
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo),
                    ),
                    const SizedBox(height: 6),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: cibleSection,
                      hint: const Text("Toute l'école"),
                      items: [
                        if (!sectionVerrouillee)
                          const DropdownMenuItem<String>(
                              value: null, child: Text("Toute l'école")),
                        ...sectionsDispo.map((s) =>
                            DropdownMenuItem(value: s, child: Text(s))),
                      ],
                      onChanged: sectionVerrouillee
                          ? null
                          : (v) => setDialogState(() {
                        cibleSection = v;
                        cibleClasse = null;
                      }),
                    ),
                    const SizedBox(height: 4),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: cibleClasse,
                      hint: Text(cibleSection == null
                          ? "Choisissez d'abord une section"
                          : "Toute la section"),
                      items: [
                        if (!classeVerrouillee)
                          const DropdownMenuItem<String>(
                              value: null, child: Text("Toute la section")),
                        ...classesDispo.map((c) =>
                            DropdownMenuItem(value: c, child: Text(c))),
                      ],
                      onChanged: (cibleSection == null || classeVerrouillee)
                          ? null
                          : (v) => setDialogState(() => cibleClasse = v),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withAlpha(20),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Cible : $cibleLabel",
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.indigo),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "Montant du frais : "
                                "${montantTotalFrais.toStringAsFixed(0)} FC  |  "
                                "Somme des tranches : "
                                "${sommeTranches.toStringAsFixed(0)} FC",
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    messageCoherence(),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Tranches",
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.indigo),
                        ),
                        TextButton.icon(
                          onPressed: () => ajouterOuModifier(),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text("Ajouter une tranche",
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    if (tranches.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          "Aucune tranche ajoutée pour cette cible.",
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      )
                    else
                      ...List.generate(tranches.length, (i) {
                        final t = tranches[i];
                        final int nbPaiements =
                        fs.compterPaiementsPourTranche(t.id);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                  CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "${i + 1}. ${t.nom}",
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w500),
                                    ),
                                    Text(
                                      "${t.montant.toStringAsFixed(0)} FC"
                                          "${nbPaiements > 0 ? '  •  $nbPaiements paiement(s)' : ''}",
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.indigo,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit,
                                    size: 18, color: Colors.indigo),
                                tooltip: "Modifier",
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 32, minHeight: 32),
                                onPressed: () =>
                                    ajouterOuModifier(existante: t),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.red),
                                tooltip: "Supprimer",
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 32, minHeight: 32),
                                onPressed: () => supprimer(t),
                              ),
                            ],
                          ),
                        );
                      }),
                    const SizedBox(height: 12),
                    const Text(
                      "Règle : pour un élève, on applique les tranches de la "
                          "cible la plus précise (classe, puis section, puis "
                          "toute l'école). Il paie les tranches dans l'ordre. "
                          "Le reçu et le rapport affichent la tranche payée.",
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Fermer"),
              ),
            ],
          );
        },
      ),
    );
  }

  // Fenêtre d'ajout / modification d'une tranche. Retourne true si une
  // tranche a bien été enregistrée.
  Future<bool?> _showEditTrancheDialog(
      BuildContext ctx, {
        required AutreFrais frais,
        required String cle,
        AutreFraisTranche? tranche,
        required String nomSuggere,
        required double montantSuggere,
      }) {
    final nomCtrl =
    TextEditingController(text: tranche != null ? tranche.nom : nomSuggere);
    final montantCtrl = TextEditingController(
      text: tranche != null
          ? tranche.montant.toStringAsFixed(0)
          : (montantSuggere > 0 ? montantSuggere.toStringAsFixed(0) : ''),
    );
    final bool isEditing = tranche != null;

    return showDialog<bool>(
        context: ctx,
        builder: (ctx2) => AlertDialog(
            title: Text(isEditing ? "Modifier la tranche" : "Nouvelle tranche"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nomCtrl,
                  decoration: const InputDecoration(
                    labelText: "Nom de la tranche",
                    hintText: "Ex: Première tranche",
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: montantCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "Montant de la tranche (FC)",
                    hintText: "Ex: 5000",
                  ),
                ),
              ],
            ),
            actions: [           TextButton(
              onPressed: () => Navigator.pop(ctx2, false),
              child: const Text("Annuler"),
            ),
              ElevatedButton(
                onPressed: () async {
                  final nom = nomCtrl.text.trim();
                  final montant = double.tryParse(
                      montantCtrl.text.trim().replaceAll(' ', '').replaceAll(',', '.'));
                  if (nom.isEmpty || montant == null || montant <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            "Veuillez entrer un nom et un montant valides"),
                      ),
                    );
                    return;
                  }
                  if (isEditing) {
                    await widget.fraisScolaires.updateTranchePourAutreFrais(
                      autreFraisId: frais.id,
                      cle: cle,
                      trancheId: tranche!.id,
                      nom: nom,
                      montant: montant,
                    );
                  } else {
                    await widget.fraisScolaires.addTranchePourAutreFrais(
                      autreFraisId: frais.id,
                      cle: cle,
                      nom: nom,
                      montant: montant,
                    );
                  }
                  if (ctx2.mounted) Navigator.pop(ctx2, true);
                },
                child: const Text("Enregistrer"),
              ),
            ],
        ),
    );
  }

  // ==========================================================================
  // ⚡ NOUVEAU — ADMINISTRATIONS & RÉPARTITION POUR LES "AUTRES FRAIS"
  // ==========================================================================
  // Demande de la direction : pouvoir AJOUTER, MODIFIER et SUPPRIMER des
  // administrations (nom + pourcentage) DIRECTEMENT depuis cet écran
  // "Autres Frais de Paiement" — sans jamais avoir besoin d'aller dans
  // Paramètres — et voir, pour le frais additionnel sélectionné, combien
  // chaque administration reçoit en % et en FC. Exactement le même
  // fonctionnement que pour les frais principaux, mais entièrement séparé.
  //
  // ⚡ NOUVEAU — cette répartition respecte désormais les filtres
  // Section/Classe actifs dans cet écran (`filterSection` / `filterClasse`).
  // Sans filtre, elle couvre TOUJOURS l'argent collecté pour ce frais dans
  // TOUTE l'école (comportement historique inchangé) — un seul frais, une
  // seule liste d'administrations, une seule répartition globale, quel que
  // soit le nombre de montants différents définis par section/classe (et
  // quel que soit le nombre de tranches : le total collecté additionne tous
  // les paiements de tranches).
  //
  // ⚠️⚠️⚠️ SÉPARATION TOTALE ET DÉFINITIVE AVEC LES FRAIS PRINCIPAUX ⚠️⚠️⚠️
  // Tout ce bloc utilise EXCLUSIVEMENT les méthodes dédiées côté
  // FraisScolaires : `getAutresFraisAdministrations`,
  // `addAutreFraisAdministration`, `updateAutreFraisAdministration`,
  // `deleteAutreFraisAdministration`, `getTotalPaidForAutreFrais` et
  // `getAdminDistributionForAutreFrais`. Aucune de ces méthodes ne touche à
  // `config.administrations` ni à `eleve.paid` — c'est-à-dire qu'AUCUNE
  // information saisie ici ne peut jamais apparaître dans la page de
  // "Répartition par Administration" des frais PRINCIPAUX, et
  // inversement les administrations des frais principaux n'apparaissent
  // JAMAIS ici. Les deux listes, les deux calculs et les deux écrans de
  // gestion restent strictement indépendants, comme demandé, pour ne
  // jamais créer de confusion ni de risque de calcul erroné entre écoles.
  //
  // Si aucune administration n'a encore été ajoutée pour les Autres Frais,
  // l'écran continue de fonctionner normalement : le paiement des frais,
  // les reçus et les totaux restent inchangés — seul un message invite à
  // en ajouter une si l'utilisateur le souhaite.
  // ==========================================================================
  void _showAdminRepartitionDialog() {
    if (selectedFrais == null) return;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final frais = selectedFrais!;
          final double total = widget.fraisScolaires.getTotalPaidForAutreFrais(
            frais,
            sectionFilter: filterSection,
            classFilter: filterClasse,
          );
          final Map<String, double> distribution = widget.fraisScolaires
              .getAdminDistributionForAutreFrais(
            frais,
            sectionFilter: filterSection,
            classFilter: filterClasse,
          );
          final administrations =
          widget.fraisScolaires.getAutresFraisAdministrations();

          final String filtreLabel = (filterSection == null &&
              filterClasse == null)
              ? "Toute l'école"
              : [
            if (filterSection != null) "Section : $filterSection",
            if (filterClasse != null) "Classe : $filterClasse",
          ].join(' — ');

          Future<void> refreshAndRebuild() async {
            setDialogState(() {});
            if (mounted) setState(() {});
          }

          void showAddOrEditAdminDialog({
            String? idToEdit,
            String initialNom = '',
            double? initialPourcentage,
          }) {
            final nomCtrl = TextEditingController(text: initialNom);
            final pourcentageCtrl = TextEditingController(
              text: initialPourcentage != null
                  ? initialPourcentage.toString()
                  : '',
            );
            final isEditing = idToEdit != null;

            showDialog(
              context: ctx,
              builder: (ctx2) => AlertDialog(
                title: Text(isEditing
                    ? "Modifier l'administration"
                    : "Nouvelle Administration (Autres Frais)"),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nomCtrl,
                      decoration: const InputDecoration(
                        labelText: "Nom de l'administration",
                        hintText: "Ex: Direction Provinciale",
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: pourcentageCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: "Pourcentage (%)",
                        hintText: "Ex: 10",
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx2),
                    child: const Text("Annuler"),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      final nom = nomCtrl.text.trim();
                      final pourcentage =
                      double.tryParse(pourcentageCtrl.text.trim());
                      if (nom.isEmpty ||
                          pourcentage == null ||
                          pourcentage < 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                "Veuillez entrer un nom et un pourcentage valides"),
                          ),
                        );
                        return;
                      }
                      if (isEditing) {
                        await widget.fraisScolaires
                            .updateAutreFraisAdministration(
                          idToEdit,
                          nom: nom,
                          pourcentage: pourcentage,
                        );
                      } else {
                        await widget.fraisScolaires
                            .addAutreFraisAdministration(
                          nom: nom,
                          pourcentage: pourcentage,
                        );
                      }
                      if (ctx2.mounted) Navigator.pop(ctx2);
                      await refreshAndRebuild();
                    },
                    child: const Text("Enregistrer"),
                  ),
                ],
              ),
            );
          }

          void confirmDeleteAdmin(String id, String nom) {
            showDialog(
              context: ctx,
              builder: (ctx2) => AlertDialog(
                title: const Text("Supprimer cette administration ?"),
                content: Text(
                  "Voulez-vous vraiment supprimer \"$nom\" de la liste des "
                      "administrations des Autres Frais ?",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx2),
                    child: const Text("Annuler"),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white),
                    onPressed: () async {
                      await widget.fraisScolaires
                          .deleteAutreFraisAdministration(id);
                      if (ctx2.mounted) Navigator.pop(ctx2);
                      await refreshAndRebuild();
                    },
                    child: const Text("Supprimer"),
                  ),
                ],
              ),
            );
          }

          return AlertDialog(
            title: Text("Administrations — ${frais.nom}"),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withAlpha(20),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        "Filtre actif : $filtreLabel",
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.indigo),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Total Collecté (\"${frais.nom}\") : "
                          "${total.toStringAsFixed(0)} FC",
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      "Ce montant ne comprend QUE les paiements de ce frais "
                          "additionnel — il n'inclut jamais les frais "
                          "mensuels principaux, et ces administrations "
                          "n'affectent jamais la répartition des frais "
                          "principaux.",
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Administrations (Autres Frais)",
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.indigo),
                        ),
                        TextButton.icon(
                          onPressed: () => showAddOrEditAdminDialog(),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text("Ajouter",
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (administrations.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          "Aucune administration ajoutée pour le moment. "
                              "Utilisez le bouton \"Ajouter\" ci-dessus pour "
                              "en créer une (nom + pourcentage). Tant "
                              "qu'aucune n'est ajoutée, le paiement des "
                              "Autres Frais continue de fonctionner "
                              "normalement.",
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      )
                    else
                      ...administrations.map((admin) {
                        final montant = distribution[admin.nom] ?? 0.0;
                        return Padding(
                          padding:
                          const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                  CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "${admin.nom} "
                                          "(${admin.pourcentage.toStringAsFixed(0)}%)",
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w500),
                                    ),
                                    Text(
                                      "${montant.toStringAsFixed(0)} FC",
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.indigo,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit,
                                    size: 18, color: Colors.indigo),
                                tooltip: "Modifier",
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 32, minHeight: 32),
                                onPressed: () => showAddOrEditAdminDialog(
                                  idToEdit: admin.id,
                                  initialNom: admin.nom,
                                  initialPourcentage: admin.pourcentage,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.red),
                                tooltip: "Supprimer",
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 32, minHeight: 32),
                                onPressed: () => confirmDeleteAdmin(
                                    admin.id, admin.nom),
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
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Fermer"),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fraisList = widget.fraisScolaires.getAutresFrais();

    // ⚡ NOUVEAU — options de classe pour le filtre, dépendantes de la
    // section choisie (utilise les classes AVEC sous-classe, comme
    // affichées pour chaque élève, pour que le filtre corresponde
    // exactement à `eleve.classe`).
    final classesOptionsForFilter = filterSection != null
        ? widget.fraisScolaires.getAllDisplayClassesForSection(filterSection!)
        : <String>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text("Autres Frais de Paiement"),
        actions: [
          // ⚡ CORRIGÉ — le bouton "Réimprimer un reçu" a été retiré (sur
          // demande de la direction) ; le bouton des totaux reste.
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: "Totaux par classe, option et tranche",
            onPressed: selectedFrais == null ? null : _showTotalsDialog,
          ),
          // ⚡ NOUVEAU — configuration des tranches du frais sélectionné
          // (par section ou par classe), directement depuis cet écran.
          IconButton(
            icon: const Icon(Icons.splitscreen),
            tooltip: "Tranches du frais",
            onPressed: selectedFrais == null ? null : _showTranchesDialog,
          ),
          // ⚡ NOUVEAU — accès rapide, depuis l'AppBar, à la gestion des
          // administrations (ajout/modification/suppression) et à la
          // répartition en % pour le frais actuellement sélectionné (et
          // le filtre section/classe actif, s'il y en a un).
          IconButton(
            icon: const Icon(Icons.account_balance),
            tooltip: "Administrations (Autres Frais)",
            onPressed:
            selectedFrais == null ? null : _showAdminRepartitionDialog,
          ),
        ],
      ),
      body: fraisList.isEmpty
          ? _buildEmptyState()
          : Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                DropdownButtonFormField<AutreFrais>(
                  value: selectedFrais,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: "Type de frais",
                    border: OutlineInputBorder(),
                  ),
                  items: fraisList.map((f) {
                    final hasExceptions = f.montantsParSection.isNotEmpty ||
                        f.montantsParClasse.isNotEmpty;
                    final hasTranches = f.tranchesParCle.values
                        .any((liste) => liste.isNotEmpty);
                    return DropdownMenuItem(
                      value: f,
                      child: Text(
                          "${f.nom} — ${f.montant.toStringAsFixed(0)} FC (${_scopeLabel(f)})"
                              "${hasExceptions ? ' • montants variables' : ''}"
                              "${hasTranches ? ' • par tranches' : ''}"),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      selectedFrais = value;
                      selectedStudentIds.clear();
                      // ⚡ NOUVEAU — on réinitialise les filtres quand on
                      // change de type de frais, pour éviter un filtre
                      // hérité qui ne correspondrait plus au nouveau frais.
                      filterSection = null;
                      filterClasse  = null;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: searchController,
                  decoration: const InputDecoration(
                    labelText: "Rechercher par ID ou Nom",
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                // ⚡ NOUVEAU — filtres optionnels Section / Classe, pour
                // naviguer facilement même sur un frais "toute l'école".
                if (selectedFrais != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: filterSection,
                          hint: const Text("Toutes les sections"),
                          items: [
                            const DropdownMenuItem<String>(
                                value: null,
                                child: Text("Toutes les sections")),
                            ...widget.fraisScolaires.config.sections.map(
                                    (s) => DropdownMenuItem(
                                    value: s, child: Text(s))),
                          ],
                          onChanged: (v) => setState(() {
                            filterSection = v;
                            filterClasse  = null;
                          }),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: filterClasse,
                          hint: const Text("Toutes les classes"),
                          items: [
                            const DropdownMenuItem<String>(
                                value: null,
                                child: Text("Toutes les classes")),
                            ...classesOptionsForFilter.map(
                                    (c) => DropdownMenuItem(
                                    value: c, child: Text(c))),
                          ],
                          onChanged: filterSection == null
                              ? null
                              : (v) => setState(() => filterClasse = v),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // ⚡ NOUVEAU — dès qu'un frais est sélectionné, les boutons
          // "Tranches" et de répartition par administration apparaissent
          // EN HAUT de la liste des élèves, juste à côté du bouton "Voir
          // les totaux" déjà existant (regroupés dans un Wrap pour rester
          // lisibles même sur un écran étroit).
          if (selectedFrais != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${_eligibleFiltered.length} élève(s) concerné(s) — cochez "
                        "ceux qui payent, ou utilisez le bouton paiement direct.",
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: _showTotalsDialog,
                        icon: const Icon(Icons.bar_chart, size: 18),
                        label: const Text("Voir les totaux",
                            style: TextStyle(fontSize: 12)),
                      ),
                      TextButton.icon(
                        onPressed: _showTranchesDialog,
                        icon: const Icon(Icons.splitscreen, size: 18),
                        label: const Text("Tranches",
                            style: TextStyle(fontSize: 12)),
                      ),
                      TextButton.icon(
                        onPressed: _showAdminRepartitionDialog,
                        icon: const Icon(Icons.account_balance, size: 18),
                        label: const Text(
                            "Administrations & Répartition",
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (selectedFrais != null)
            Expanded(
              child: ListView.builder(
                itemCount: _eligibleFiltered.length,
                itemBuilder: (context, index) {
                  final eleve = _eligibleFiltered[index];
                  final fs = widget.fraisScolaires;
                  final dejaPaye =
                  fs.hasPaidAutreFrais(eleve, selectedFrais!);
                  final partiel = fs.hasPaidPartiellementAutreFrais(
                      eleve, selectedFrais!);
                  final isSelected = selectedStudentIds.contains(eleve.id);
                  // ⚡ NOUVEAU — montant réellement dû par CET élève
                  // (dépend de ses éventuelles exceptions par
                  // section/classe pour ce frais).
                  final double montantEleve = fs
                      .getMontantAutreFraisPourEleve(selectedFrais!, eleve);
                  // ⚡ NOUVEAU — informations de tranches pour CET élève.
                  final tranchesEleve =
                  fs.getTranchesPourEleve(selectedFrais!, eleve);
                  final prochaine = fs.getProchaineTrancheAutreFrais(
                      selectedFrais!, eleve);
                  final int nbPayees = fs.getNombreTranchesPayeesAutreFrais(
                      eleve, selectedFrais!);
                  final double montantProchain = fs
                      .getMontantProchainPaiementAutreFrais(
                      selectedFrais!, eleve);

                  String ligneTranches = '';
                  if (tranchesEleve.isNotEmpty) {
                    ligneTranches =
                    'Tranches : $nbPayees/${tranchesEleve.length} payée(s)';
                    if (prochaine != null) {
                      ligneTranches +=
                      ' — prochaine : ${prochaine.nom} '
                          '(${montantProchain.toStringAsFixed(0)} FC)';
                    }
                  }

                  return Card(
                    margin:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    color: dejaPaye
                        ? Colors.green.withAlpha(20)
                        : (partiel ? Colors.orange.withAlpha(25) : null),
                    child: ListTile(
                      leading: dejaPaye
                          ? const Icon(Icons.check_circle,
                          color: Colors.green)
                          : Checkbox(
                        value: isSelected,
                        onChanged: (_) => _toggleStudent(eleve),
                      ),
                      title: Text(
                          '${eleve.nom} ${eleve.postNom} ${eleve.prenom}'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ID: ${eleve.id} | Classe: ${eleve.classe} (${eleve.section}) | '
                                'Montant: ${montantEleve.toStringAsFixed(0)} FC',
                          ),
                          if (ligneTranches.isNotEmpty)
                            Text(
                              ligneTranches,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: dejaPaye
                                    ? Colors.green
                                    : Colors.indigo,
                              ),
                            ),
                        ],
                      ),
                      // ⚡ CORRIGÉ — le bouton de réimpression manuelle a
                      // été retiré ; un élève entièrement payé n'affiche
                      // plus qu'un simple statut "Payé". ⚡ NOUVEAU — un
                      // élève qui n'a payé qu'une partie des tranches
                      // garde le bouton de paiement (prochaine tranche).
                      trailing: dejaPaye
                          ? const Text(
                        "Payé",
                        style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold),
                      )
                          : IconButton(
                        icon: const Icon(Icons.payment,
                            color: Colors.indigo),
                        tooltip: prochaine != null
                            ? "Payer : ${prochaine.nom}"
                            : "Payer",
                        onPressed: _processing
                            ? null
                            : () => _confirmPaiementUnique(eleve),
                      ),
                      onTap: dejaPaye ? null : () => _toggleStudent(eleve),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
      bottomNavigationBar:
      (selectedFrais != null && selectedStudentIds.isNotEmpty)
          ? SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            icon: _processing
                ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.payment),
            label: Text(_processing
                ? "Traitement..."
                : "Payer pour ${selectedStudentIds.length} élève(s)"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 50),
            ),
            onPressed: _processing ? null : _payerSelection,
          ),
        ),
      )
          : null,
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.receipt_long, size: 60, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              "Aucun frais additionnel défini pour le moment.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              "Allez dans Paramètres > \"Autres Frais de Paiement\" pour en "
                  "ajouter (ex: Frais de l'État, Frais d'Aide...). Les "
                  "tranches se configurent ensuite directement ici, avec "
                  "le bouton \"Tranches\".",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}