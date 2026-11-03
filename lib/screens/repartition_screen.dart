import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../frais_scolaires.dart';
import '../app_state.dart';

class RepartitionScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const RepartitionScreen({super.key, required this.fraisScolaires});

  @override
  State<RepartitionScreen> createState() => _RepartitionScreenState();
}

class _RepartitionScreenState extends State<RepartitionScreen> {
  FraisScolaires get fraisScolaires => widget.fraisScolaires;

  // Période sélectionnée pour la répartition globale par
  // administration : 'today', 'month' ou 'year'.
  String _periodeGlobale = 'year';

  // ==========================================================================
  // VÉRIFICATION MOT DE PASSE (même principe que Paramètres)
  // Sécurise toute sortie de caisse (ajout d'une dépense) et toute
  // suppression d'historique de dépenses.
  // ==========================================================================
  Future<bool> _verifyBackupPassword() async {
    final appState = Provider.of<AppState>(context, listen: false);
    if (appState.backupPassword == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                "Veuillez d'abord définir un mot de passe de sauvegarde "
                    "(Paramètres) avant de gérer les dépenses.")),
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
            const Text(
                "Entrez votre mot de passe de sauvegarde pour continuer"),
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

  // ==========================================================================
  // Libellés / couleurs des types de dépenses
  // ==========================================================================
  String _labelPortee(String portee) {
    switch (portee) {
      case kDepenseIndependante:
        return "Indépendante";
      case kDepenseMixte:
        return "Mixte";
      case kDepenseGlobale:
      default:
        return "Globale";
    }
  }

  Color _couleurPortee(String portee) {
    switch (portee) {
      case kDepenseIndependante:
        return Colors.deepOrange;
      case kDepenseMixte:
        return Colors.purple;
      case kDepenseGlobale:
      default:
        return Colors.red.shade700;
    }
  }

  // ⚡ NOUVEAU — formatte une date (sans l'heure) au format jj/mm/aaaa,
  // utilisé pour l'affichage du sélecteur de date dans le formulaire
  // d'ajout d'une dépense.
  String _formatDateCourte(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return "${two(d.day)}/${two(d.month)}/${d.year}";
  }

  // ==========================================================================
  // Dialogue : ajouter une nouvelle dépense
  //   1. Type : Globale / Indépendante / Mixte
  //   2. Section(s) concernée(s) (+ classes, facultatif)
  //   3. Rubrique (administration) sur laquelle l'argent sort
  //   4. Motif + montant
  //   5. Date (facultatif — aujourd'hui par défaut)
  // SÉCURISÉ — demande le mot de passe de sauvegarde avant d'ouvrir le
  // formulaire.
  // ==========================================================================
  Future<void> _startAddDepense() async {
    if (!await _verifyBackupPassword()) return;
    await _openAddDepenseDialog();
  }

  Future<void> _openAddDepenseDialog() async {
    final motifController = TextEditingController();
    final montantController = TextEditingController();

    String portee = kDepenseGlobale;
    String? sectionIndep;
    final Set<String> sectionsMixte = {};
    final Set<String> classesSel = {};
    String? rubrique;
    // ⚡ NOUVEAU — date optionnelle de la dépense. Si non renseignée
    // (null), la date d'aujourd'hui sera utilisée automatiquement par
    // `addDepense`. Utile lorsque le caissier enregistre aujourd'hui
    // une dépense faite un autre jour (ex. hier).
    DateTime? dateSelectionnee;

    final sectionsDisponibles = fraisScolaires.config.sections;
    final rubriquesDisponibles = fraisScolaires.getRubriquesDisponibles();

    List<String> sectionsChoisies() {
      if (portee == kDepenseIndependante) {
        final s = sectionIndep;
        return s == null ? <String>[] : <String>[s];
      }
      if (portee == kDepenseMixte) return sectionsMixte.toList();
      return <String>[];
    }

    List<String> classesProposees() {
      final result = <String>[];
      for (final s in sectionsChoisies()) {
        for (final c in fraisScolaires.getAllDisplayClassesForSection(s)) {
          if (!result.contains(c)) result.add(c);
        }
      }
      return result;
    }

    double? soldeDisponible() {
      final r = rubrique;
      if (r == null) return null;
      final secs = sectionsChoisies();
      if (portee != kDepenseGlobale && secs.isEmpty) return null;
      return fraisScolaires.getSoldeDisponibleRubrique(
        rubrique: r,
        portee: portee,
        sections: secs,
      );
    }

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final secs = sectionsChoisies();
            final classesOptions = classesProposees();
            final solde = soldeDisponible();

            // ⚡ Détermine le numéro d'étape suivant, en fonction de la
            // présence ou non des sections/classes (portée globale ou
            // non), pour que la numérotation de la section "Date"
            // s'enchaîne correctement avec "Motif et montant".
            final int numeroDate = portee == kDepenseGlobale ? 4 : 5;

            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.money_off, color: Colors.red),
                  SizedBox(width: 8),
                  Expanded(child: Text("Nouvelle Dépense")),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("1. Type de dépense",
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          ChoiceChip(
                            label: const Text("Globale (toute l'école)"),
                            selected: portee == kDepenseGlobale,
                            selectedColor: Colors.red.shade100,
                            onSelected: (_) => setDialogState(() {
                              portee = kDepenseGlobale;
                              classesSel.clear();
                            }),
                          ),
                          ChoiceChip(
                            label: const Text("Indépendante (1 section)"),
                            selected: portee == kDepenseIndependante,
                            selectedColor: Colors.deepOrange.shade100,
                            onSelected: (_) => setDialogState(() {
                              portee = kDepenseIndependante;
                              classesSel.clear();
                            }),
                          ),
                          ChoiceChip(
                            label: const Text("Mixte (2 sections ou plus)"),
                            selected: portee == kDepenseMixte,
                            selectedColor: Colors.purple.shade100,
                            onSelected: (_) => setDialogState(() {
                              portee = kDepenseMixte;
                              classesSel.clear();
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        portee == kDepenseGlobale
                            ? "Concerne toute l'école."
                            : portee == kDepenseIndependante
                            ? "Concerne une seule section."
                            : "Concerne plusieurs sections : le montant sera "
                            "réparti à parts égales entre elles.",
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black54),
                      ),

                      // ---- Section(s) -----------------------------------
                      if (portee == kDepenseIndependante) ...[
                        const SizedBox(height: 14),
                        const Text("2. Section concernée",
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          value: sectionIndep,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: "Choisir la section",
                            border: OutlineInputBorder(),
                          ),
                          items: sectionsDisponibles
                              .map((s) =>
                              DropdownMenuItem(value: s, child: Text(s)))
                              .toList(),
                          onChanged: (v) => setDialogState(() {
                            sectionIndep = v;
                            classesSel.clear();
                          }),
                        ),
                      ],
                      if (portee == kDepenseMixte) ...[
                        const SizedBox(height: 14),
                        const Text("2. Sections concernées (2 ou plus)",
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: sectionsDisponibles.map((s) {
                            final sel = sectionsMixte.contains(s);
                            return FilterChip(
                              label: Text(s),
                              selected: sel,
                              selectedColor: Colors.purple.shade100,
                              onSelected: (v) => setDialogState(() {
                                if (v) {
                                  sectionsMixte.add(s);
                                } else {
                                  sectionsMixte.remove(s);
                                }
                                classesSel.clear();
                              }),
                            );
                          }).toList(),
                        ),
                      ],

                      // ---- Classes (facultatif) -------------------------
                      if (portee != kDepenseGlobale &&
                          classesOptions.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        const Text("Classes concernées (facultatif)",
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(
                          classesSel.isEmpty
                              ? "Aucune sélection = toutes les classes."
                              : "${classesSel.length} classe(s) choisie(s).",
                          style: const TextStyle(
                              fontSize: 11, color: Colors.black54),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: classesOptions.map((c) {
                            final sel = classesSel.contains(c);
                            return FilterChip(
                              label: Text(c),
                              selected: sel,
                              onSelected: (v) => setDialogState(() {
                                if (v) {
                                  classesSel.add(c);
                                } else {
                                  classesSel.remove(c);
                                }
                              }),
                            );
                          }).toList(),
                        ),
                      ],

                      // ---- Rubrique -------------------------------------
                      const SizedBox(height: 14),
                      Text(
                          portee == kDepenseGlobale
                              ? "2. Rubrique (administration)"
                              : "3. Rubrique (administration)",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        value: rubrique,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: "Sortir l'argent de la rubrique",
                          border: OutlineInputBorder(),
                        ),
                        items: rubriquesDisponibles
                            .map((r) =>
                            DropdownMenuItem(value: r, child: Text(r)))
                            .toList(),
                        onChanged: (v) => setDialogState(() => rubrique = v),
                      ),
                      if (fraisScolaires.config.administrations.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            "Aucune administration configurée dans les "
                                "Paramètres : seule la rubrique « Autre » est "
                                "disponible.",
                            style: TextStyle(
                                fontSize: 11, color: Colors.orange),
                          ),
                        ),
                      if (solde != null) ...[
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: solde >= 0
                                ? Colors.green.withAlpha(25)
                                : Colors.red.withAlpha(25),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            "Solde disponible sur cette rubrique : "
                                "${formatMontant(solde)} FC",
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: solde >= 0
                                  ? Colors.green.shade800
                                  : Colors.red.shade800,
                            ),
                          ),
                        ),
                      ],

                      // ---- Motif + montant ------------------------------
                      const SizedBox(height: 14),
                      Text(
                          portee == kDepenseGlobale
                              ? "3. Motif et montant"
                              : "4. Motif et montant",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: motifController,
                        textCapitalization: TextCapitalization.sentences,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: "Motif / Justification",
                          hintText:
                          "Ex: Achat de craies, réparation, transport...",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: montantController,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          labelText: "Montant à faire sortir (FC)",
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.attach_money),
                        ),
                      ),
                      if (secs.isNotEmpty && portee != kDepenseGlobale) ...[
                        const SizedBox(height: 8),
                        Text(
                          "Imputée à : ${secs.join(', ')}"
                              "${classesSel.isNotEmpty ? ' — ${classesSel.join(', ')}' : ''}",
                          style: const TextStyle(
                              fontSize: 11, color: Colors.black54),
                        ),
                      ],

                      // ---- Date (facultatif) -----------------------------
                      // ⚡ NOUVEAU — permet de préciser la date réelle de
                      // la dépense si elle diffère du jour de saisie.
                      // Laissé vide, le système prend automatiquement la
                      // date d'aujourd'hui, exactement comme avant.
                      const SizedBox(height: 14),
                      Text(
                        "$numeroDate. Date (facultatif)",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        "Laissez vide pour utiliser la date d'aujourd'hui. "
                            "Utile si vous enregistrez maintenant une "
                            "dépense faite un autre jour (par ex. hier).",
                        style: TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: dialogContext,
                            initialDate: dateSelectionnee ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate:
                            DateTime.now().add(const Duration(days: 365)),
                            helpText: "Choisir la date de la dépense",
                            cancelText: "Annuler",
                            confirmText: "Valider",
                          );
                          if (picked != null) {
                            setDialogState(() => dateSelectionnee = picked);
                          }
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.calendar_today,
                                  size: 18, color: Colors.indigo),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  dateSelectionnee == null
                                      ? "Aujourd'hui (par défaut)"
                                      : _formatDateCourte(dateSelectionnee!),
                                  style: TextStyle(
                                    color: dateSelectionnee == null
                                        ? Colors.black54
                                        : Colors.black87,
                                    fontWeight: dateSelectionnee == null
                                        ? FontWeight.normal
                                        : FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (dateSelectionnee != null)
                                InkWell(
                                  onTap: () => setDialogState(
                                          () => dateSelectionnee = null),
                                  child: const Padding(
                                    padding: EdgeInsets.all(2),
                                    child: Icon(Icons.close,
                                        size: 18, color: Colors.grey),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text("Annuler"),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final motif = motifController.text.trim();
                    final montantText =
                    montantController.text.trim().replaceAll(',', '.');
                    final montant = double.tryParse(montantText);
                    final r = rubrique;
                    final sectionsFinales = sectionsChoisies();

                    void erreur(String message) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text(message)),
                      );
                    }

                    if (portee == kDepenseIndependante &&
                        sectionsFinales.isEmpty) {
                      erreur("Veuillez choisir la section concernée.");
                      return;
                    }
                    if (portee == kDepenseMixte && sectionsFinales.length < 2) {
                      erreur("Une dépense mixte doit concerner au moins "
                          "deux sections.");
                      return;
                    }
                    if (r == null) {
                      erreur("Veuillez choisir la rubrique.");
                      return;
                    }
                    if (motif.isEmpty) {
                      erreur("Veuillez indiquer un motif.");
                      return;
                    }
                    if (montant == null || montant <= 0) {
                      erreur("Montant invalide.");
                      return;
                    }

                    // Avertissement si la sortie dépasse le solde disponible.
                    final soldeActuel = soldeDisponible();
                    if (soldeActuel != null && montant > soldeActuel) {
                      final continuer = await showDialog<bool>(
                        context: dialogContext,
                        builder: (ctx) => AlertDialog(
                          title: const Row(
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  color: Colors.orange),
                              SizedBox(width: 8),
                              Expanded(child: Text("Solde insuffisant")),
                            ],
                          ),
                          content: Text(
                            "Le solde disponible sur la rubrique « $r » est de "
                                "${formatMontant(soldeActuel)} FC, mais vous "
                                "voulez sortir ${formatMontant(montant)} FC.\n\n"
                                "Le reste deviendra négatif. Continuer quand même ?",
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text("Annuler"),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white),
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text("Continuer"),
                            ),
                          ],
                        ),
                      );
                      if (continuer != true) return;
                    }

                    await fraisScolaires.addDepense(
                      motif: motif,
                      montant: montant,
                      portee: portee,
                      sections: sectionsFinales,
                      classes: classesSel.toList(),
                      rubrique: r,
                      // ⚡ NOUVEAU — date optionnelle ; si l'utilisateur
                      // n'a rien choisi, `addDepense` utilisera
                      // automatiquement la date d'aujourd'hui.
                      date: dateSelectionnee,
                    );

                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  },
                  child: const Text("Valider la sortie"),
                ),
              ],
            );
          },
        );
      },
    );
    if (mounted) setState(() {});
  }

  // ==========================================================================
  // Confirmation de suppression d'une dépense (erreur de saisie, etc.)
  // SÉCURISÉ — demande le mot de passe de sauvegarde après confirmation.
  // ==========================================================================
  Future<bool> _confirmDeleteDepense(Depense depense) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Supprimer cette dépense ?"),
        content: Text(
          "${depense.motif}\n"
              "${formatMontant(depense.montant)} FC — ${depense.dateFormatee}\n"
              "Type : ${depense.porteeLabel} | ${depense.sectionsLabel}\n"
              "Rubrique : ${depense.rubriqueAffichee}",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Supprimer", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return false;
    if (!await _verifyBackupPassword()) return false;
    await fraisScolaires.deleteDepense(depense.id);
    return true;
  }

  // ==========================================================================
  // ⚡ NOUVEAU — Modifier la date d'une dépense déjà enregistrée.
  // Utile lorsque le caissier a oublié d'enregistrer une sortie de
  // caisse le jour même et le fait plus tard : il peut corriger la date
  // pour qu'elle reflète le jour réel de la dépense. La dépense
  // apparaîtra alors dans le rapport journalier/mensuel/annuel
  // correspondant à sa NOUVELLE date.
  // SÉCURISÉ — demande le mot de passe de sauvegarde après le choix de
  // la nouvelle date.
  // ==========================================================================
  Future<bool> _editDepenseDate(Depense depense) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: depense.date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: "Choisir la date réelle de cette dépense",
      cancelText: "Annuler",
      confirmText: "Valider",
    );
    if (picked == null) return false;

    // On conserve l'heure d'origine et on ne change que le jour, le mois
    // et l'année, pour rester cohérent avec le format "date + heure"
    // utilisé dans dateFormatee.
    final newDate = DateTime(
      picked.year,
      picked.month,
      picked.day,
      depense.date.hour,
      depense.date.minute,
    );

    if (!await _verifyBackupPassword()) return false;
    await fraisScolaires.updateDepenseDate(depense.id, newDate);
    return true;
  }

  // ==========================================================================
  // Vider tout l'historique des dépenses de l'année en cours.
  // Action irréversible : double protection (confirmation + mot de passe).
  // ==========================================================================
  Future<bool> _confirmClearAllDepenses(int count) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text("Tout effacer ?"),
          ],
        ),
        content: Text(
          "Cette action va supprimer DÉFINITIVEMENT les $count dépense(s) "
              "enregistrées pour l'année ${fraisScolaires.currentYear} "
              "(tous types confondus).\n\n"
              "Cette action est irréversible. Voulez-vous continuer ?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Tout effacer"),
          ),
        ],
      ),
    );
    if (confirm != true) return false;
    if (!await _verifyBackupPassword()) return false;
    await fraisScolaires.clearDepensesForYear();
    return true;
  }

  // ==========================================================================
  // Dialogue : historique complet des dépenses de l'année (filtrable par type)
  // ==========================================================================
  void _openHistoriqueDialog() {
    String filtre = 'all';
    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final toutes = fraisScolaires.getDepensesForYear();
            final depenses = filtre == 'all'
                ? toutes
                : toutes.where((d) => d.portee == filtre).toList();
            final totalAffiche =
            depenses.fold(0.0, (sum, d) => sum + d.montant);

            Widget filtreChip(String value, String label) {
              return ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 11)),
                selected: filtre == value,
                selectedColor: Colors.indigo.shade100,
                onSelected: (_) => setDialogState(() => filtre = value),
              );
            }

            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.history, color: Colors.indigo),
                  SizedBox(width: 8),
                  Expanded(child: Text("Historique des Dépenses")),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        filtreChip('all', "Toutes"),
                        filtreChip(kDepenseGlobale, "Globales"),
                        filtreChip(kDepenseIndependante, "Indépendantes"),
                        filtreChip(kDepenseMixte, "Mixtes"),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        "Total affiché : ${formatMontant(totalAffiche)} FC",
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const Divider(height: 10),
                    Flexible(
                      child: depenses.isEmpty
                          ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          "Aucune dépense enregistrée pour ce filtre.",
                          textAlign: TextAlign.center,
                        ),
                      )
                          : ListView.separated(
                        shrinkWrap: true,
                        itemCount: depenses.length,
                        separatorBuilder: (_, __) =>
                        const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final d = depenses[index];
                          final couleur = _couleurPortee(d.portee);
                          return ListTile(
                            dense: true,
                            isThreeLine: true,
                            leading: Icon(Icons.remove_circle,
                                color: couleur),
                            title: Text(d.motif),
                            subtitle: Text(
                              "${d.porteeLabel} — ${d.sectionsLabel}\n"
                                  "Rubrique : ${d.rubriqueAffichee}"
                                  "${d.portee != kDepenseGlobale && d.classes.isNotEmpty ? '\nClasses : ${d.classes.join(', ')}' : ''}\n"
                                  "${d.dateFormatee}",
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: Column(
                              mainAxisAlignment:
                              MainAxisAlignment.center,
                              crossAxisAlignment:
                              CrossAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  "-${formatMontant(d.montant)} FC",
                                  style: TextStyle(
                                      color: couleur,
                                      fontWeight: FontWeight.bold),
                                ),
                                // ⚡ NOUVEAU — bouton pour modifier la
                                // date de cette dépense, à côté du
                                // bouton de suppression déjà existant.
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkWell(
                                      onTap: () async {
                                        final edited =
                                        await _editDepenseDate(d);
                                        if (edited) {
                                          setDialogState(() {});
                                        }
                                      },
                                      child: const Padding(
                                        padding:
                                        EdgeInsets.only(top: 4, right: 10),
                                        child: Icon(Icons.edit_calendar,
                                            size: 18, color: Colors.indigo),
                                      ),
                                    ),
                                    InkWell(
                                      onTap: () async {
                                        final deleted =
                                        await _confirmDeleteDepense(d);
                                        if (deleted) {
                                          setDialogState(() {});
                                        }
                                      },
                                      child: const Padding(
                                        padding: EdgeInsets.only(top: 4),
                                        child: Icon(Icons.delete_outline,
                                            size: 18, color: Colors.grey),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                if (toutes.isNotEmpty)
                  TextButton.icon(
                    icon: const Icon(Icons.delete_forever, color: Colors.red),
                    label: const Text("Tout effacer",
                        style: TextStyle(color: Colors.red)),
                    onPressed: () async {
                      final cleared =
                      await _confirmClearAllDepenses(toutes.length);
                      if (cleared) setDialogState(() {});
                    },
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text("Fermer"),
                ),
              ],
            );
          },
        );
      },
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  // ==========================================================================
  // Ouvre l'écran "Autres Répartitions" (par Option et par Section
  // pédagogique).
  // ==========================================================================
  void _openAutresRepartitions() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            _AutresRepartitionsScreen(fraisScolaires: fraisScolaires),
      ),
    );
  }

  // ==========================================================================
  // Ouvre l'écran "Courbe d'Évolution".
  // ==========================================================================
  void _openEvolution() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EvolutionScreen(fraisScolaires: fraisScolaires),
      ),
    );
  }

  String _labelPeriode(String periode) {
    switch (periode) {
      case 'today':
        return "Aujourd'hui";
      case 'month':
        return "Ce mois "
            "(${fraisScolaires.currentSchoolMonthName ?? 'hors année'})";
      case 'year':
      default:
        return "Cette Année (${fraisScolaires.currentYear})";
    }
  }

  Widget _periodeChips(String selected, ValueChanged<String> onChanged) {
    Widget chip(String value, String label) {
      final bool isSelected = selected == value;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: ChoiceChip(
            label: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? Colors.white : Colors.black87,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            selected: isSelected,
            selectedColor: Colors.indigo,
            backgroundColor: Colors.grey.shade200,
            onSelected: (_) => onChanged(value),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('today', "Aujourd'hui"),
        chip('month', "Ce mois"),
        chip('year', "Cette année"),
      ],
    );
  }

  Widget _ligneCategorie(String label, double montant, Color couleur) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration:
                BoxDecoration(color: couleur, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
          Text(
            "-${formatMontant(montant)} FC",
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: couleur),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalCollecte = fraisScolaires.getYearTotalCollected();
    final totalsByClass = fraisScolaires.getTotalByClass();
    final depenses = fraisScolaires.getDepensesForYear();
    final totalDepenses = fraisScolaires.getTotalDepenses();
    final soldeNet = totalCollecte - totalDepenses;
    final depensesApercu = depenses.take(3).toList();

    final double depGlobales =
    fraisScolaires.getTotalDepensesParPortee(kDepenseGlobale);
    final double depIndep =
    fraisScolaires.getTotalDepensesParPortee(kDepenseIndependante);
    final double depMixtes =
    fraisScolaires.getTotalDepensesParPortee(kDepenseMixte);

    // Statistiques (collecté, dépenses par rubrique, reste) pour la période
    // choisie dans la répartition globale par administration.
    final stats = fraisScolaires.computeDepensesStats(_periodeGlobale);
    final double collectePeriode = stats.totalCollecte;
    final double depensesPeriode = stats.totalDepenses;
    final double soldeNetPeriode = stats.reste;

    final nomsAdmins = fraisScolaires.config.administrations
        .map((a) => a.nom.trim())
        .toSet();
    final rubriquesHorsAdmin = stats.rubriques
        .where((r) => !nomsAdmins.contains(r.rubrique) && r.total != 0)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text("Répartition par Administration")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------------------------------------------------------------
            // Carte Total (enrichie avec dépenses + solde net)
            // ---------------------------------------------------------------
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Total Collecté Global (Cette Année)",
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    Text("${totalCollecte.toStringAsFixed(0)} FC",
                        style: const TextStyle(
                            fontSize: 24, color: Colors.green)),
                    if (totalDepenses > 0) ...[
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Total des dépenses",
                              style: TextStyle(color: Colors.black54)),
                          Text("- ${formatMontant(totalDepenses)} FC",
                              style: const TextStyle(
                                  color: Colors.red,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Solde net en caisse",
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16)),
                          Text("${formatMontant(soldeNet)} FC",
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: Colors.indigo)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // ---------------------------------------------------------------
            // Boutons Dépenses / Historique
            // ---------------------------------------------------------------
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _startAddDepense,
                    icon: const Icon(Icons.money_off),
                    label: const Text("Dépenses"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade600,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openHistoriqueDialog,
                    icon: const Icon(Icons.history),
                    label: const Text("Historique"),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openAutresRepartitions,
                icon: const Icon(Icons.account_tree),
                label: const Text("Autres Répartitions (par Section)"),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  foregroundColor: Colors.indigo,
                  side: const BorderSide(color: Colors.indigo),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openEvolution,
                icon: const Icon(Icons.show_chart),
                label: const Text("Courbe d'Évolution"),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  foregroundColor: Colors.teal.shade700,
                  side: BorderSide(color: Colors.teal.shade700),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // ---------------------------------------------------------------
            // Dépenses par catégorie (année en cours)
            // ---------------------------------------------------------------
            if (totalDepenses > 0) ...[
              const Text("Dépenses par catégorie (Cette Année)",
                  style:
                  TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    _ligneCategorie("Globales (toute l'école)", depGlobales,
                        _couleurPortee(kDepenseGlobale)),
                    _ligneCategorie("Indépendantes (une section)", depIndep,
                        _couleurPortee(kDepenseIndependante)),
                    _ligneCategorie("Mixtes (plusieurs sections)", depMixtes,
                        _couleurPortee(kDepenseMixte)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ---------------------------------------------------------------
            // Aperçu des dernières dépenses (max 3, sans surcharger l'écran)
            // ---------------------------------------------------------------
            if (depensesApercu.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("Dernières Dépenses",
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  if (depenses.length > depensesApercu.length)
                    TextButton(
                      onPressed: _openHistoriqueDialog,
                      child: Text("Voir tout (${depenses.length})"),
                    ),
                ],
              ),
              ...depensesApercu.map((d) => ListTile(
                leading: Icon(Icons.remove_circle_outline,
                    color: _couleurPortee(d.portee)),
                title: Text(d.motif),
                subtitle: Text(
                  "${_labelPortee(d.portee)} — ${d.sectionsLabel}\n"
                      "Rubrique : ${d.rubriqueAffichee} • ${d.dateFormatee}",
                  style: const TextStyle(fontSize: 11),
                ),
                isThreeLine: true,
                trailing: Text(
                  "-${formatMontant(d.montant)} FC",
                  style: TextStyle(
                      color: _couleurPortee(d.portee),
                      fontWeight: FontWeight.bold),
                ),
              )),
              const Divider(),
            ],

            // ---------------------------------------------------------------
            // Montant par classe (annuel, inchangé)
            // ---------------------------------------------------------------
            const Text("Montant par Classe (Cette Année)",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ...totalsByClass.entries.map((entry) => ListTile(
              title: Text(entry.key),
              trailing: Text("${entry.value.toStringAsFixed(0)} FC"),
            )),
            const Divider(),

            // ---------------------------------------------------------------
            // Répartition GLOBALE aux administrations, avec choix de la
            // période. Le reste de chaque administration tient compte des
            // dépenses imputées à sa rubrique.
            // ---------------------------------------------------------------
            const Text("Répartition Globale aux Administrations",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              "Ce que chaque administration (enseignants, gestionnaire, "
                  "etc.) a accumulé pour TOUTE L'ÉCOLE sur la période choisie, "
                  "après déduction des dépenses sorties de sa rubrique.",
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 10),
            _periodeChips(
              _periodeGlobale,
                  (value) => setState(() => _periodeGlobale = value),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.indigo.withAlpha(15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Collecté — ${_labelPeriode(_periodeGlobale)}",
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  Text("${formatMontant(collectePeriode)} FC",
                      style: const TextStyle(
                          fontSize: 18,
                          color: Colors.green,
                          fontWeight: FontWeight.bold)),
                  if (depensesPeriode > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      "Dépenses sur cette période : "
                          "-${formatMontant(depensesPeriode)} FC",
                      style: const TextStyle(fontSize: 12, color: Colors.red),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Solde net sur cette période : "
                          "${formatMontant(soldeNetPeriode)} FC",
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (fraisScolaires.config.administrations.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  "Aucune administration configurée (Paramètres).",
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              ...fraisScolaires.config.administrations.map((admin) {
                final r = stats.rubriqueParNom(admin.nom.trim());
                final double collecte = r?.collecte ??
                    (collectePeriode * admin.pourcentage / 100);
                final double depense = r?.total ?? 0;
                final double reste = collecte - depense;
                return ListTile(
                  title: Text(admin.nom),
                  subtitle: Text(
                    "${admin.pourcentage}% • Part : ${formatMontant(collecte)} FC"
                        "${depense > 0 ? ' • Dépenses : -${formatMontant(depense)} FC' : ''}",
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Text(
                    "${formatMontant(reste)} FC",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: reste >= 0 ? Colors.black87 : Colors.red,
                    ),
                  ),
                );
              }).toList(),
            ...rubriquesHorsAdmin.map((r) => ListTile(
              title: Text(r.rubrique),
              subtitle: const Text(
                "Rubrique hors administration",
                style: TextStyle(fontSize: 11),
              ),
              trailing: Text(
                "-${formatMontant(r.total)} FC",
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.red),
              ),
            )),
          ],
        ),
      ),
    );
  }
}

// ==============================================================================
// ÉCRAN "AUTRES RÉPARTITIONS"
// Répartition par Option (ex: Primaire / Secondaire / Maternelle) et, à
// l'intérieur d'une option, par Section pédagogique (ex: Électricité,
// Commerciale...) ou "Éducation de Base" pour les classes sans section
// (7ème/8ème dans le système éducatif de la RDC).
// Sélecteur de période (Aujourd'hui / Ce mois / Cette année). Le reste de
// chaque administration déduit les dépenses indépendantes et mixtes
// rattachées à la section.
// ==============================================================================
class _AutresRepartitionsScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const _AutresRepartitionsScreen({required this.fraisScolaires});

  @override
  State<_AutresRepartitionsScreen> createState() =>
      _AutresRepartitionsScreenState();
}

class _AutresRepartitionsScreenState
    extends State<_AutresRepartitionsScreen> {
  String? selectedOption;
  String _periode = 'year';

  @override
  void initState() {
    super.initState();
    final options = widget.fraisScolaires.getOptions();
    if (options.isNotEmpty) selectedOption = options.first;
  }

  String _labelPeriode(String periode) {
    switch (periode) {
      case 'today':
        return "Aujourd'hui";
      case 'month':
        return "Ce mois "
            "(${widget.fraisScolaires.currentSchoolMonthName ?? 'hors année'})";
      case 'year':
      default:
        return "Cette Année (${widget.fraisScolaires.currentYear})";
    }
  }

  Widget _periodeChips() {
    Widget chip(String value, String label) {
      final bool isSelected = _periode == value;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: ChoiceChip(
            label: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? Colors.white : Colors.black87,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            selected: isSelected,
            selectedColor: Colors.indigo,
            backgroundColor: Colors.grey.shade200,
            onSelected: (_) => setState(() => _periode = value),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('today', "Aujourd'hui"),
        chip('month', "Ce mois"),
        chip('year', "Cette année"),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final fraisScolaires = widget.fraisScolaires;
    final options = fraisScolaires.getOptions();

    return Scaffold(
      appBar: AppBar(title: const Text("Autres Répartitions")),
      body: options.isEmpty
          ? const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "Aucune option/section n'est configurée pour le moment.",
            textAlign: TextAlign.center,
          ),
        ),
      )
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.indigo.withAlpha(15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                "Les totaux par option/section sont BRUTS (avant "
                    "dépenses). Dans le détail d'une option, le « reste » de "
                    "chaque administration déduit les dépenses indépendantes "
                    "et mixtes rattachées à cette section. Les dépenses "
                    "globales de l'école ne sont pas déduites ici.",
                style: TextStyle(fontSize: 12, color: Colors.indigo),
              ),
            ),
            const SizedBox(height: 12),

            const Text("Période",
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _periodeChips(),
            const SizedBox(height: 16),

            Text("Vue d'ensemble par Option — ${_labelPeriode(_periode)}",
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...options.map((option) {
              final detail = fraisScolaires.getRepartitionForOptionPeriod(
                  option, _periode);
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(option,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  trailing: Text(
                    "${detail.total.toStringAsFixed(0)} FC",
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.green),
                  ),
                ),
              );
            }),

            const Divider(height: 32),

            Text("Détail par Option — ${_labelPeriode(_periode)}",
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: selectedOption,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: "Choisir une option",
                border: OutlineInputBorder(),
              ),
              items: options
                  .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                  .toList(),
              onChanged: (value) => setState(() => selectedOption = value),
            ),
            const SizedBox(height: 16),

            if (selectedOption != null) ...[
              _buildOptionDetail(fraisScolaires, selectedOption!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOptionDetail(FraisScolaires fraisScolaires, String option) {
    final detailOption =
    fraisScolaires.getRepartitionForOptionPeriod(option, _periode);
    final hasSousSections = fraisScolaires.optionHasSousSections(option);
    final sousSections =
    fraisScolaires.getSousSectionsForOptionPeriod(option, _periode);

    // Statistiques de dépenses rattachées à cette section pour la période.
    final stats = fraisScolaires.computeDepensesStats(
      _periode,
      sectionFilter: option,
    );
    final rubriquesAffichees = stats.rubriques
        .where((r) => r.collecte != 0 || r.total != 0)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          color: Colors.indigo.withAlpha(15),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Total $option — ${_labelPeriode(_periode)}",
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  "${detailOption.total.toStringAsFixed(0)} FC",
                  style: const TextStyle(
                      fontSize: 22, color: Colors.green,
                      fontWeight: FontWeight.bold),
                ),
                if (stats.totalDepenses > 0) ...[
                  const SizedBox(height: 6),
                  Text(
                    "Dépenses de la section : "
                        "-${formatMontant(stats.totalDepenses)} FC",
                    style: const TextStyle(fontSize: 12, color: Colors.red),
                  ),
                  Text(
                    "Reste après dépenses : ${formatMontant(stats.reste)} FC",
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.indigo),
                  ),
                ],
                const SizedBox(height: 12),
                const Text("Répartition par administration :",
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                if (rubriquesAffichees.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      "Aucune administration configurée.",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  )
                else
                  ...rubriquesAffichees.map(
                        (r) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r.rubrique),
                                Text(
                                  "Part : ${formatMontant(r.collecte)} FC"
                                      "${r.total > 0 ? ' − Dépenses : ${formatMontant(r.total)} FC' : ''}",
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.black54),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            "${formatMontant(r.reste)} FC",
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: r.reste >= 0
                                  ? Colors.black87
                                  : Colors.red,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 20),

        if (hasSousSections) ...[
          Text(
            "Détail par Section ($option) — ${_labelPeriode(_periode)}",
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            "Les classes sans section pédagogique (ex: 7ème, 8ème) "
                "apparaissent sous \"Éducation de Base\".",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          ...sousSections.map((detail) => Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              title: Text(detail.label,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text("${detail.total.toStringAsFixed(0)} FC"),
              children: detail.parAdministration.isEmpty
                  ? [
                const Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  child: Text(
                    "Aucune administration configurée.",
                    style:
                    TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ]
                  : detail.parAdministration.entries
                  .map(
                    (e) => ListTile(
                  dense: true,
                  title: Text(e.key),
                  trailing: Text("${e.value.toStringAsFixed(0)} FC"),
                ),
              )
                  .toList(),
            ),
          )),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              "Aucune section pédagogique définie pour \"$option\" — "
                  "le total ci-dessus représente déjà l'ensemble de "
                  "l'option.",
              style: const TextStyle(
                  color: Colors.grey, fontStyle: FontStyle.italic),
            ),
          ),
      ],
    );
  }
}

// ==============================================================================
// ÉCRAN "COURBE D'ÉVOLUTION"
// Courbe mensuelle (Septembre → Juin) des montants collectés, comme un
// graphique en ligne Excel classique. Filtrable par Option, Section
// pédagogique (ou "Éducation de Base" pour 7ème/8ème) et Classe.
// ==============================================================================
class _EvolutionScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const _EvolutionScreen({required this.fraisScolaires});

  @override
  State<_EvolutionScreen> createState() => _EvolutionScreenState();
}

class _EvolutionScreenState extends State<_EvolutionScreen> {
  String? selectedOption;      // null = toute l'école
  String? selectedSousSection; // null = toutes les sections
  String? selectedClasse;      // null = toutes les classes
  bool cumulatif = false;

  static const List<String> _moisCourts = [
    'Sep', 'Oct', 'Nov', 'Déc', 'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Jun'
  ];

  void _onOptionChanged(String? value) {
    setState(() {
      selectedOption = value;
      selectedSousSection = null;
      selectedClasse = null;
    });
  }

  void _onSousSectionChanged(String? value) {
    setState(() {
      selectedSousSection = value;
      selectedClasse = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final fraisScolaires = widget.fraisScolaires;
    final options = fraisScolaires.getOptions();

    final bool hasSousSections = selectedOption != null &&
        fraisScolaires.optionHasSousSections(selectedOption!);
    final sousSections = selectedOption != null
        ? fraisScolaires.getSousSectionsForOption(selectedOption!)
        : <RepartitionDetail>[];

    final classesOptions = selectedOption != null
        ? fraisScolaires.getClassesForOptionAndSousSection(
        selectedOption!, selectedSousSection)
        : <String>[];

    final rawValues = fraisScolaires.getMonthlyEvolution(
      option: selectedOption,
      sousSectionLabel: selectedSousSection,
      classe: selectedClasse,
    );

    final List<double> displayValues;
    if (cumulatif) {
      double running = 0;
      displayValues = rawValues.map((v) {
        running += v;
        return running;
      }).toList();
    } else {
      displayValues = rawValues;
    }

    final double total = rawValues.fold(0.0, (a, b) => a + b);
    final double maxY = displayValues.isEmpty
        ? 100
        : (displayValues.reduce((a, b) => a > b ? a : b) * 1.2)
        .clamp(100, double.infinity);

    String scopeLabel = "Toute l'école";
    if (selectedOption != null) {
      scopeLabel = selectedOption!;
      if (selectedSousSection != null) {
        scopeLabel += " — $selectedSousSection";
      }
      if (selectedClasse != null) {
        scopeLabel += " — $selectedClasse";
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Courbe d'Évolution")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ------------------------------------------------------------
            // Filtres
            // ------------------------------------------------------------
            const Text("Filtrer la courbe",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: selectedOption,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: "Option",
                border: OutlineInputBorder(),
              ),
              hint: const Text("Toute l'école"),
              items: [
                const DropdownMenuItem<String>(
                    value: null, child: Text("Toute l'école")),
                ...options.map(
                        (o) => DropdownMenuItem(value: o, child: Text(o))),
              ],
              onChanged: _onOptionChanged,
            ),
            if (selectedOption != null && hasSousSections) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: selectedSousSection,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: "Section pédagogique",
                  border: OutlineInputBorder(),
                ),
                hint: const Text("Toutes les sections"),
                items: [
                  const DropdownMenuItem<String>(
                      value: null, child: Text("Toutes les sections")),
                  ...sousSections.map(
                        (s) => DropdownMenuItem(
                        value: s.label, child: Text(s.label)),
                  ),
                ],
                onChanged: _onSousSectionChanged,
              ),
            ],
            if (selectedOption != null && classesOptions.isNotEmpty) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: selectedClasse,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: "Classe",
                  border: OutlineInputBorder(),
                ),
                hint: const Text("Toutes les classes"),
                items: [
                  const DropdownMenuItem<String>(
                      value: null, child: Text("Toutes les classes")),
                  ...classesOptions.map(
                        (c) => DropdownMenuItem(value: c, child: Text(c)),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => selectedClasse = value),
              ),
            ],
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("Vue cumulée"),
              subtitle: const Text(
                "Somme progressive mois après mois, au lieu du montant "
                    "de chaque mois seul.",
                style: TextStyle(fontSize: 11),
              ),
              value: cumulatif,
              onChanged: (value) => setState(() => cumulatif = value),
            ),

            const Divider(height: 32),

            // ------------------------------------------------------------
            // Résumé
            // ------------------------------------------------------------
            Text(
              scopeLabel,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: Colors.indigo),
            ),
            const SizedBox(height: 4),
            Text(
              "Total sur la période : ${total.toStringAsFixed(0)} FC",
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 20),

            // ------------------------------------------------------------
            // Courbe
            // ------------------------------------------------------------
            if (total == 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    "Aucune donnée de paiement pour cette sélection.",
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            else
              SizedBox(
                height: 320,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16, top: 8),
                  child: LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: (fraisScolaires.months.length - 1).toDouble(),
                      minY: 0,
                      maxY: maxY,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: maxY / 4,
                        getDrawingHorizontalLine: (value) => FlLine(
                          color: Colors.grey.withAlpha(60),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border(
                          bottom: BorderSide(color: Colors.grey.shade400),
                          left: BorderSide(color: Colors.grey.shade400),
                        ),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 28,
                            interval: 1,
                            getTitlesWidget: (value, meta) {
                              final i = value.toInt();
                              if (i < 0 || i >= _moisCourts.length) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  _moisCourts[i],
                                  style: const TextStyle(fontSize: 11),
                                ),
                              );
                            },
                          ),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 56,
                            interval: maxY / 4,
                            getTitlesWidget: (value, meta) {
                              return Text(
                                value >= 1000
                                    ? "${(value / 1000).toStringAsFixed(0)}k"
                                    : value.toStringAsFixed(0),
                                style: const TextStyle(fontSize: 10),
                              );
                            },
                          ),
                        ),
                      ),
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (spots) => spots.map((s) {
                            final i = s.x.toInt();
                            final label = (i >= 0 && i < _moisCourts.length)
                                ? _moisCourts[i]
                                : '';
                            return LineTooltipItem(
                              "$label\n${s.y.toStringAsFixed(0)} FC",
                              const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            );
                          }).toList(),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: [
                            for (int i = 0; i < displayValues.length; i++)
                              FlSpot(i.toDouble(), displayValues[i]),
                          ],
                          isCurved: true,
                          curveSmoothness: 0.25,
                          color: Colors.indigo,
                          barWidth: 3,
                          dotData: const FlDotData(show: true),
                          belowBarData: BarAreaData(
                            show: true,
                            color: Colors.indigo.withAlpha(30),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}