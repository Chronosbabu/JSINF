import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import '../frais_scolaires.dart';
import '../app_state.dart';
import '../models.dart';

class StudentListScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const StudentListScreen({super.key, required this.fraisScolaires});

  @override
  State<StudentListScreen> createState() => _StudentListScreenState();
}

class _StudentListScreenState extends State<StudentListScreen> {
  String searchQuery = "";
  String? selectedSectionFilter;
  String? selectedClassFilter;

  // ====================================================================
  // MODE PASSATION VERS LA NOUVELLE ANNÉE
  // ====================================================================
  bool promotionMode = false;
  String? targetPromotionYear;
  final Map<String, bool> passToNextYear = {};
  final Map<String, bool> monterClasse = {};

  // ====================================================================
  // MODE SUPPRESSION D'ÉLÈVE
  // ====================================================================
  //
  // Quand deletionMode est actif, l'AppBar change de titre, les filtres
  // et la barre de recherche restent actifs (pour trouver rapidement
  // l'élève à supprimer), et chaque carte affiche un bouton de corbeille
  // rouge à droite. Un seul appui sur la corbeille déclenche la
  // vérification du mot de passe admin puis la confirmation avant
  // suppression définitive.
  bool deletionMode = false;

  // ==========================================================================
  // ⚡ NOUVEAU — LOGO DE L'ÉCOLE (RÉUTILISÉ SUR LA CARTE D'ÉLÈVE)
  // ==========================================================================
  // Le logo est déjà géré et sauvegardé localement par SettingsScreen (fichier
  // school_logo.png dans le dossier documents de l'application). On le
  // recharge simplement ici pour l'afficher sur la carte d'identité d'élève.
  Uint8List? _schoolLogoBytes;

  @override
  void initState() {
    super.initState();
    _loadSchoolLogo();
  }

  Future<void> _loadSchoolLogo() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/school_logo.png');
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (mounted) setState(() => _schoolLogoBytes = bytes);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final allEleves = widget.fraisScolaires.currentData.eleves;
    final filteredEleves = allEleves.where((eleve) {
      final matchesSearch =
          eleve.nom.toLowerCase().contains(searchQuery.toLowerCase()) ||
              eleve.postNom.toLowerCase().contains(searchQuery.toLowerCase()) ||
              eleve.prenom.toLowerCase().contains(searchQuery.toLowerCase()) ||
              eleve.id.toLowerCase().contains(searchQuery.toLowerCase());
      final matchesSection =
          selectedSectionFilter == null || eleve.section == selectedSectionFilter;
      final matchesClass =
          selectedClassFilter == null || eleve.classe == selectedClassFilter;
      return matchesSearch && matchesSection && matchesClass;
    }).toList();

    final classOptions = selectedSectionFilter != null
        ? List<String>.from(
        widget.fraisScolaires.getAllDisplayClassesForSection(selectedSectionFilter!))
        : List<String>.from(widget.fraisScolaires.getAllDisplayClasses());
    if (selectedClassFilter != null && !classOptions.contains(selectedClassFilter)) {
      classOptions.add(selectedClassFilter!);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          promotionMode
              ? "Passation vers $targetPromotionYear"
              : deletionMode
              ? "Sélectionner un élève à supprimer"
              : "Registre des Élèves",
        ),
        actions: _buildAppBarActions(),
      ),
      floatingActionButton: (promotionMode || deletionMode)
          ? null
          : FloatingActionButton(
        onPressed: () => _downloadCurrentListAsPdf(),
        tooltip: "Télécharger PDF",
        child: const Icon(Icons.download),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (promotionMode) _buildPromotionBanner(),
            if (deletionMode) _buildDeletionBanner(),
            TextField(
              decoration: const InputDecoration(
                labelText: "Rechercher par nom, post-nom, ID...",
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() => searchQuery = value);
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text("Toutes Sections"),
                    value: selectedSectionFilter,
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text("Toutes Sections")),
                      ...widget.fraisScolaires.config.sections
                          .map((s) => DropdownMenuItem(value: s, child: Text(s))),
                    ],
                    onChanged: (val) {
                      setState(() {
                        selectedSectionFilter = val;
                        final validClasses = val != null
                            ? widget.fraisScolaires
                            .getAllDisplayClassesForSection(val)
                            : widget.fraisScolaires.getAllDisplayClasses();
                        if (selectedClassFilter != null &&
                            !validClasses.contains(selectedClassFilter)) {
                          selectedClassFilter = null;
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text("Toutes Classes"),
                    value: selectedClassFilter,
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text("Toutes Classes")),
                      ...classOptions
                          .map((c) => DropdownMenuItem(value: c, child: Text(c))),
                    ],
                    onChanged: (val) =>
                        setState(() => selectedClassFilter = val),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              "Total : ${filteredEleves.length} élève(s)",
              style:
              const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filteredEleves.isEmpty
                  ? const Center(child: Text("Aucun élève trouvé"))
                  : ListView.builder(
                itemCount: filteredEleves.length,
                itemBuilder: (context, index) {
                  final e = filteredEleves[index];
                  if (promotionMode) return _buildPromotionCard(e);
                  if (deletionMode) return _buildDeletionCard(e);
                  return _buildNormalCard(e);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== ACTIONS APPBAR ====================
  List<Widget> _buildAppBarActions() {
    if (promotionMode) {
      return [
        IconButton(
          icon: const Icon(Icons.check_circle, color: Colors.greenAccent),
          tooltip: "Valider la passation",
          onPressed: _validatePromotion,
        ),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: "Annuler la passation",
          onPressed: _cancelPromotionMode,
        ),
      ];
    }

    if (deletionMode) {
      return [
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: "Quitter le mode suppression",
          onPressed: _cancelDeletionMode,
        ),
      ];
    }

    // Mode normal : 4 boutons côte à côte
    return [
      IconButton(
        icon: const Icon(Icons.move_up),
        tooltip: "Passation vers la nouvelle année",
        onPressed: _startPromotionMode,
      ),
      IconButton(
        icon: const Icon(Icons.delete_forever, color: Colors.red),
        tooltip: "Supprimer un élève",
        onPressed: _startDeletionMode,
      ),
      // ==================================================================
      // ⚡ NOUVEAU — BOUTON "ÉLÈVES SUPPRIMÉS"
      // ==================================================================
      // Ouvre directement la page listant tous les élèves supprimés /
      // exclus (archivés). Leur argent déjà payé reste comptabilisé dans
      // la caisse de l'école et leur historique complet reste consultable
      // ici, tant qu'on ne le supprime pas volontairement depuis cette
      // page (protégé par mot de passe admin).
      IconButton(
        icon: const Icon(Icons.history),
        tooltip: "Élèves Supprimés",
        onPressed: _openElevesSupprimesScreen,
      ),
      IconButton(
        icon: const Icon(Icons.picture_as_pdf),
        tooltip: "Télécharger la liste en PDF",
        onPressed: () => _downloadCurrentListAsPdf(),
      ),
    ];
  }

  // ==================== CARTE NORMALE (HORS MODES SPÉCIAUX) ====================
  Widget _buildNormalCard(Eleve e) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        // ⚡ NOUVEAU — clic sur un élève ouvre sa carte d'identité complète,
        // avec possibilité de voir et modifier ses informations
        // additionnelles (père, mère, adresse, date de naissance, photo,
        // questions personnalisées).
        onTap: () => _showStudentCard(e),
        leading: CircleAvatar(
          // ⚡ NOUVEAU — affiche la photo de l'élève si elle existe déjà,
          // sinon retombe sur les initiales comme avant.
          backgroundImage: (e.photoBase64 != null && e.photoBase64!.isNotEmpty)
              ? MemoryImage(base64Decode(e.photoBase64!))
              : null,
          child: (e.photoBase64 == null || e.photoBase64!.isEmpty)
              ? Text(
            e.id.isNotEmpty ? e.id.substring(0, 2) : "?",
            style: const TextStyle(fontWeight: FontWeight.bold),
          )
              : null,
        ),
        title: Text("${e.nom} ${e.postNom} ${e.prenom}"),
        subtitle: Text("${e.section} - ${e.classe}"),
        trailing: Text(
          e.id,
          style: const TextStyle(
              fontWeight: FontWeight.bold, color: Colors.indigo),
        ),
      ),
    );
  }

  // ==========================================================================
  // ⚡ NOUVEAU — OUVERTURE DE LA CARTE D'IDENTITÉ D'ÉLÈVE
  // ==========================================================================
  void _showStudentCard(Eleve eleve) {
    showDialog(
      context: context,
      builder: (ctx) => _StudentCardDialog(
        eleve: eleve,
        fraisScolaires: widget.fraisScolaires,
        schoolLogoBytes: _schoolLogoBytes,
        onSaved: () {
          if (mounted) setState(() {});
        },
      ),
    );
  }

  // ==========================================================================
  // ⚡ NOUVEAU — OUVERTURE DE LA PAGE "ÉLÈVES SUPPRIMÉS"
  // ==========================================================================
  void _openElevesSupprimesScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ElevesSupprimesScreen(fraisScolaires: widget.fraisScolaires),
      ),
    ).then((_) {
      // Au retour de cette page (après une éventuelle suppression
      // définitive dans l'archive), on rafraîchit l'écran au cas où.
      if (mounted) setState(() {});
    });
  }

  // ====================================================================
  // MODE SUPPRESSION — bannière + carte
  // ====================================================================

  Widget _buildDeletionBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withOpacity(0.35)),
      ),
      child: Row(
        children: const [
          Icon(Icons.warning_amber_rounded, color: Colors.red, size: 22),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              "Utilisez la recherche ou les filtres ci-dessous pour trouver "
                  "l'élève à supprimer, puis appuyez sur la corbeille 🗑 à côté "
                  "de son nom. Le mot de passe administrateur sera demandé.",
              style: TextStyle(fontSize: 12.5, color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeletionCard(Eleve e) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.red.shade50,
          backgroundImage: (e.photoBase64 != null && e.photoBase64!.isNotEmpty)
              ? MemoryImage(base64Decode(e.photoBase64!))
              : null,
          child: (e.photoBase64 == null || e.photoBase64!.isEmpty)
              ? Text(
            e.id.isNotEmpty ? e.id.substring(0, 2) : "?",
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.red),
          )
              : null,
        ),
        title: Text("${e.nom} ${e.postNom} ${e.prenom}"),
        subtitle: Text("${e.section} - ${e.classe}  |  ID : ${e.id}"),
        trailing: IconButton(
          icon: const Icon(Icons.delete, color: Colors.red, size: 28),
          tooltip: "Supprimer cet élève",
          onPressed: () => _requestDeleteStudent(e),
        ),
      ),
    );
  }

  // ==================== DÉMARRER / QUITTER LE MODE SUPPRESSION ====================
  void _startDeletionMode() {
    setState(() {
      deletionMode = true;
      // Réinitialiser la recherche pour partir d'une ardoise vide
      searchQuery = "";
    });
  }

  void _cancelDeletionMode() {
    setState(() {
      deletionMode = false;
      searchQuery = "";
    });
  }

  // ==================== SUPPRESSION SÉCURISÉE D'UN ÉLÈVE ====================
  //
  // Flux complet :
  //   1. Vérification du mot de passe administrateur (backupPassword de
  //      AppState, le même que pour les autres actions sensibles).
  //   2. Boîte de dialogue d'avertissement avec les informations de
  //      l'élève et rappel que l'élève ne sera plus visible dans ce
  //      registre.
  //   3. Si l'utilisateur confirme, l'élève est retiré de
  //      currentData.eleves ET ARCHIVÉ dans "Élèves Supprimés"
  //      (⚡ NOUVEAU — au lieu d'une suppression définitive). L'argent
  //      déjà payé par cet élève reste comptabilisé dans la caisse de
  //      l'école, et tout son historique de paiements reste consultable
  //      dans la page "Élèves Supprimés", tant qu'on ne le supprime pas
  //      volontairement et définitivement depuis cette page (protégé par
  //      mot de passe admin).
  //   4. Toutes les autres pages (PaiementEleveScreen, etc.) lisent
  //      currentData.eleves en direct : elles se mettent à jour
  //      automatiquement à leur prochain rebuild.
  //   5. Un message snackbar rappelle de sauvegarder sur le serveur pour
  //      propager la suppression à distance.
  Future<void> _requestDeleteStudent(Eleve eleve) async {
    // --- Étape 1 : Vérification du mot de passe admin ---
    final appState = Provider.of<AppState>(context, listen: false);

    if (appState.backupPassword == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Aucun mot de passe administrateur défini. "
                  "Définissez-en un dans les Paramètres avant de supprimer un élève."),
        ),
      );
      return;
    }

    final passController = TextEditingController();
    final bool? passwordOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Vérification Administrateur"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Entrez le mot de passe administrateur pour continuer.",
            ),
            const SizedBox(height: 14),
            TextField(
              controller: passController,
              obscureText: true,
              decoration:
              const InputDecoration(labelText: "Mot de passe"),
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
                  const SnackBar(content: Text("Mot de passe incorrect.")),
                );
              }
            },
            child: const Text("Confirmer"),
          ),
        ],
      ),
    );

    if (passwordOk != true) return;

    // --- Étape 2 : Avertissement et confirmation de suppression ---
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 26),
            SizedBox(width: 8),
            Text("Suppression de l'élève",
                style: TextStyle(color: Colors.red)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Vous êtes sur le point de retirer du registre actif l'élève "
                  "suivant de l'année scolaire en cours :",
              style: TextStyle(fontSize: 13.5),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${eleve.nom} ${eleve.postNom} ${eleve.prenom}",
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text("ID : ${eleve.id}"),
                  Text(
                      "Classe : ${eleve.classe}  |  Section : ${eleve.section}"),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              "ℹ️  L'élève n'apparaîtra plus dans ce registre. Cependant, "
                  "l'argent déjà payé reste comptabilisé dans la caisse de "
                  "l'école, et son historique complet (paiements, "
                  "informations) reste consultable dans \"Élèves "
                  "Supprimés\" tant qu'on ne le supprime pas définitivement "
                  "depuis cette page.\n\n"
                  "Après cette action, pensez à sauvegarder sur le serveur "
                  "(Paramètres → Sauvegarder sur le Serveur) pour que la "
                  "modification soit prise en compte sur tous les appareils.",
              style: TextStyle(fontSize: 12.5, color: Colors.black87),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Supprimer",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // --- Étape 3 : Archivage (⚡ NOUVEAU) au lieu d'une suppression définitive ---
    await widget.fraisScolaires.archiverEtSupprimerEleve(
      eleve,
      motif: 'Suppression manuelle depuis le registre des élèves',
    );
    if (mounted) setState(() {});

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ ${eleve.nom} ${eleve.postNom} ${eleve.prenom} a été retiré(e) "
                "du registre actif (visible dans \"Élèves Supprimés\"). "
                "Pensez à sauvegarder sur le serveur dans Paramètres.",
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  // ====================================================================
  // MODE PASSATION — bannière + carte (inchangés)
  // ====================================================================

  Widget _buildPromotionBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.indigo.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.indigo.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Passation vers \"$targetPromotionYear\"",
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          const Text(
            "Toutes les cases sont cochées par défaut. Décochez \"Passe\" pour "
                "un abandon (l'élève ne sera pas transféré). Décochez \"Monte\" "
                "pour un redoublant (il garde la même classe). Appuyez ensuite "
                "sur ✅ en haut pour valider.",
            style: TextStyle(fontSize: 12.5, color: Colors.black87),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.check_box, size: 18),
                label: const Text("Tous passent"),
                onPressed: () => _bulkSetPass(true),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.check_box_outline_blank, size: 18),
                label: const Text("Aucun ne passe"),
                onPressed: () => _bulkSetPass(false),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.arrow_upward, size: 18),
                label: const Text("Tous montent"),
                onPressed: () => _bulkSetMonter(true),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.horizontal_rule, size: 18),
                label: const Text("Aucun ne monte"),
                onPressed: () => _bulkSetMonter(false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPromotionCard(Eleve e) {
    final bool passe = passToNextYear[e.id] ?? true;
    final bool monte = monterClasse[e.id] ?? true;
    final String classeApercu = passe
        ? (monte ? widget.fraisScolaires.computePromotedClasse(e) : e.classe)
        : "—";

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            CircleAvatar(
              child: Text(
                e.id.isNotEmpty ? e.id.substring(0, 2) : "?",
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${e.nom} ${e.postNom} ${e.prenom}",
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    "${e.section} - ${e.classe}  →  $classeApercu",
                    style: TextStyle(
                      fontSize: 12.5,
                      color: passe ? Colors.indigo : Colors.red,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Passe", style: TextStyle(fontSize: 11)),
                    Checkbox(
                      value: passe,
                      onChanged: (v) => setState(() {
                        passToNextYear[e.id] = v ?? true;
                      }),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Monte", style: TextStyle(fontSize: 11)),
                    Checkbox(
                      value: monte,
                      onChanged: !passe
                          ? null
                          : (v) => setState(() {
                        monterClasse[e.id] = v ?? true;
                      }),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ==================== ACTIONS EN MASSE (PASSATION) ====================
  void _bulkSetPass(bool value) {
    setState(() {
      for (var e in widget.fraisScolaires.currentData.eleves) {
        passToNextYear[e.id] = value;
      }
    });
  }

  void _bulkSetMonter(bool value) {
    setState(() {
      for (var e in widget.fraisScolaires.currentData.eleves) {
        monterClasse[e.id] = value;
      }
    });
  }

  // ==================== DÉMARRER LE MODE PASSATION ====================
  void _startPromotionMode() async {
    final years = widget.fraisScolaires.history.keys
        .where((y) => y != widget.fraisScolaires.currentYear)
        .toList();

    String? chosenYear;
    final newYearController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: const Text("Passation vers la nouvelle année"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Choisissez une année scolaire déjà créée dans les "
                      "Paramètres, ou tapez directement le nom d'une "
                      "nouvelle année à créer.",
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 14),
                if (years.isNotEmpty) ...[
                  DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text("Choisir une année existante"),
                    value: chosenYear,
                    items: years
                        .map((y) =>
                        DropdownMenuItem(value: y, child: Text(y)))
                        .toList(),
                    onChanged: (v) => setStateDialog(() {
                      chosenYear = v;
                      newYearController.clear();
                    }),
                  ),
                  const SizedBox(height: 14),
                  const Text("— ou —", style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 14),
                ],
                TextField(
                  controller: newYearController,
                  decoration: const InputDecoration(
                    labelText: "Nouvelle année (ex: 2026-2027)",
                  ),
                  onChanged: (_) => setStateDialog(() => chosenYear = null),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Annuler")),
            ElevatedButton(
              onPressed: () {
                final value = chosenYear ?? newYearController.text.trim();
                if (value.isEmpty) return;
                Navigator.pop(ctx, value);
              },
              child: const Text("Continuer"),
            ),
          ],
        ),
      ),
    );

    if (result == null || result.isEmpty) return;

    setState(() {
      promotionMode = true;
      targetPromotionYear = result;
      passToNextYear.clear();
      monterClasse.clear();
      for (var e in widget.fraisScolaires.currentData.eleves) {
        passToNextYear[e.id] = true;
        monterClasse[e.id] = true;
      }
    });
  }

  // ==================== ANNULER LE MODE PASSATION ====================
  void _cancelPromotionMode() {
    setState(() {
      promotionMode = false;
      targetPromotionYear = null;
      passToNextYear.clear();
      monterClasse.clear();
    });
  }

  // ==================== VALIDER LA PASSATION ====================
  void _validatePromotion() async {
    if (targetPromotionYear == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Confirmer la passation"),
        content: Text(
          "Les élèves cochés \"Passe\" vont être copiés dans l'année "
              "\"$targetPromotionYear\", avec leur classe supérieure si "
              "\"Monte\" est cochée. Cette action ne supprime ni ne modifie "
              "rien dans l'année actuelle (${widget.fraisScolaires.currentYear}). "
              "Voulez-vous continuer ?",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Confirmer")),
        ],
      ),
    );
    if (confirm != true) return;

    final result = await widget.fraisScolaires.promoteStudents(
      studentsToProcess: widget.fraisScolaires.currentData.eleves,
      passToNextYear: passToNextYear,
      monterClasse: monterClasse,
      targetYear: targetPromotionYear!,
    );

    if (mounted) {
      final year = targetPromotionYear;
      setState(() {
        promotionMode = false;
        targetPromotionYear = null;
        passToNextYear.clear();
        monterClasse.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ ${result['promoted']} élève(s) envoyé(s) vers \"$year\" "
                "(${result['redoublants']} sans changement de classe), "
                "${result['abandoned']} non transféré(s) (abandons). "
                "Pensez à sauvegarder sur le serveur dans Paramètres.",
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  // ==================== TÉLÉCHARGEMENT PDF ====================
  Future<void> _downloadCurrentListAsPdf() async {
    final String sectionText = selectedSectionFilter ?? "Toutes_Sections";
    final String classText = selectedClassFilter ?? "Toutes_Classes";
    final filename =
        "Liste_Eleves_${sectionText}_${classText}_${DateTime.now().toString().split(' ')[0]}";

    await widget.fraisScolaires.generatePdf(
      filename: filename,
      reportType: "student_list",
      sectionFilter: selectedSectionFilter,
      classFilter: selectedClassFilter,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("✅ Liste des élèves téléchargée en PDF")),
      );
    }
  }
}

// ==============================================================================
// ⚡ NOUVEAU — BOÎTE DE DIALOGUE "CARTE D'IDENTITÉ D'ÉLÈVE"
// ==============================================================================
// Affichée au clic sur un élève dans le registre. Montre le logo de l'école,
// le nom de l'école, la photo de l'élève, sa classe, son ID, son nom complet,
// et toutes les informations additionnelles éventuellement remplies (père,
// mère, adresse, date de naissance, questions personnalisées).
//
// Un bouton "Modifier" permet de basculer la carte en mode édition : tous
// les champs additionnels deviennent modifiables (y compris ajouter de
// nouvelles questions personnalisées ou changer la photo), avec un bouton
// "Enregistrer" qui sauvegarde directement dans FraisScolaires (fichier
// local sur l'appareil).
class _StudentCardDialog extends StatefulWidget {
  final Eleve eleve;
  final FraisScolaires fraisScolaires;
  final Uint8List? schoolLogoBytes;
  final VoidCallback onSaved;

  const _StudentCardDialog({
    required this.eleve,
    required this.fraisScolaires,
    required this.schoolLogoBytes,
    required this.onSaved,
  });

  @override
  State<_StudentCardDialog> createState() => _StudentCardDialogState();
}

class _StudentCardDialogState extends State<_StudentCardDialog> {
  bool editing = false;
  bool saving = false;

  late TextEditingController pereNomController;
  late TextEditingController mereNomController;
  late TextEditingController adresseController;
  DateTime? selectedDateNaissance;
  Uint8List? photoBytes;
  late Map<String, TextEditingController> customFieldsControllers;

  @override
  void initState() {
    super.initState();
    final e = widget.eleve;
    pereNomController = TextEditingController(text: e.pereNom);
    mereNomController = TextEditingController(text: e.mereNom);
    adresseController = TextEditingController(text: e.adresse);
    selectedDateNaissance = _parseDate(e.dateNaissance);
    photoBytes = (e.photoBase64 != null && e.photoBase64!.isNotEmpty)
        ? base64Decode(e.photoBase64!)
        : null;
    customFieldsControllers = {
      for (var entry in e.customFields.entries)
        entry.key: TextEditingController(text: entry.value),
    };
  }

  DateTime? _parseDate(String s) {
    if (s.trim().isEmpty) return null;
    final parts = s.split('/');
    if (parts.length != 3) return null;
    final day = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final year = int.tryParse(parts[2]);
    if (day == null || month == null || year == null) return null;
    return DateTime(year, month, day);
  }

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}';
  }

  @override
  void dispose() {
    pereNomController.dispose();
    mereNomController.dispose();
    adresseController.dispose();
    for (var c in customFieldsControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    const typeGroup = XTypeGroup(
      label: 'images',
      extensions: ['png', 'jpg', 'jpeg'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() => photoBytes = bytes);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDateNaissance ?? DateTime(now.year - 10),
      firstDate: DateTime(1990),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => selectedDateNaissance = picked);
    }
  }

  Future<void> _addCustomField() async {
    final questionController = TextEditingController();
    final question = await showDialog<String>(
      context: context,
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
        setState(() {
          customFieldsControllers[question] = TextEditingController();
        });
      }
    }
  }

  void _removeCustomField(String question) {
    setState(() {
      customFieldsControllers[question]?.dispose();
      customFieldsControllers.remove(question);
    });
  }

  Future<void> _save() async {
    setState(() => saving = true);
    final e = widget.eleve;
    e.pereNom = pereNomController.text.trim();
    e.mereNom = mereNomController.text.trim();
    e.adresse = adresseController.text.trim();
    e.dateNaissance =
    selectedDateNaissance != null ? _formatDate(selectedDateNaissance!) : '';
    e.photoBase64 = photoBytes != null ? base64Encode(photoBytes!) : null;
    e.customFields = {
      for (var entry in customFieldsControllers.entries)
        entry.key: entry.value.text.trim(),
    }..removeWhere((k, v) => v.isEmpty);

    await widget.fraisScolaires.saveData();
    widget.onSaved();

    if (mounted) {
      setState(() {
        saving = false;
        editing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "✅ Informations mises à jour. Pensez à sauvegarder sur le serveur."),
        ),
      );
    }
  }

  Widget _infoRow(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.black54,
                fontSize: 12.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.eleve;
    final schoolName = widget.fraisScolaires.config.schoolName;

    final bool hasAnyExtraInfo = e.pereNom.isNotEmpty ||
        e.mereNom.isNotEmpty ||
        e.adresse.isNotEmpty ||
        e.dateNaissance.isNotEmpty ||
        e.customFields.values.any((v) => v.trim().isNotEmpty);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ==================== EN-TÊTE — CARTE D'IDENTITÉ ====================
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.indigo, Color(0xFF3F51B5)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.schoolLogoBytes != null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.memory(
                            widget.schoolLogoBytes!,
                            width: 34,
                            height: 34,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text(
                          schoolName.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      if (widget.schoolLogoBytes != null) ...[
                        const SizedBox(width: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.memory(
                            widget.schoolLogoBytes!,
                            width: 34,
                            height: 34,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "CARTE D'IDENTITÉ SCOLAIRE",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),

            // ==================== CORPS ====================
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // ---- Photo ----
                    Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        CircleAvatar(
                          radius: 55,
                          backgroundColor: Colors.grey.shade200,
                          backgroundImage:
                          photoBytes != null ? MemoryImage(photoBytes!) : null,
                          child: photoBytes == null
                              ? const Icon(Icons.person, size: 55, color: Colors.grey)
                              : null,
                        ),
                        if (editing)
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: Colors.indigo,
                            child: IconButton(
                              icon: const Icon(Icons.camera_alt,
                                  size: 16, color: Colors.white),
                              onPressed: _pickPhoto,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    Text(
                      "${e.nom} ${e.postNom} ${e.prenom}",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${e.section} — ${e.classe}",
                      style: const TextStyle(
                        color: Colors.indigo,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "ID : ${e.id}",
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 12.5,
                      ),
                    ),

                    const SizedBox(height: 18),
                    const Divider(),
                    const SizedBox(height: 6),

                    if (!editing) ...[
                      _infoRow("Père", e.pereNom),
                      _infoRow("Mère", e.mereNom),
                      _infoRow("Adresse", e.adresse),
                      _infoRow("Naissance", e.dateNaissance),
                      ...e.customFields.entries
                          .where((entry) => entry.value.trim().isNotEmpty)
                          .map((entry) => _infoRow(entry.key, entry.value)),
                      if (!hasAnyExtraInfo)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            "Aucune information additionnelle enregistrée pour cet élève.",
                            style: TextStyle(color: Colors.grey, fontSize: 12.5),
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ] else ...[
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
                        onTap: _pickDate,
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: "Date de naissance",
                            border: OutlineInputBorder(),
                            suffixIcon: Icon(Icons.calendar_today, size: 18),
                          ),
                          child: Text(
                            selectedDateNaissance != null
                                ? _formatDate(selectedDateNaissance!)
                                : "Non renseignée",
                          ),
                        ),
                      ),
                      if (customFieldsControllers.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            "Questions Personnalisées",
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13),
                          ),
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
                                  icon: const Icon(Icons.close,
                                      color: Colors.red, size: 20),
                                  onPressed: () => _removeCustomField(entry.key),
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
                        onPressed: _addCustomField,
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // ==================== ACTIONS ====================
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("Fermer"),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: editing
                        ? ElevatedButton.icon(
                      icon: saving
                          ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                          : const Icon(Icons.save),
                      label: Text(saving ? "Enregistrement..." : "Enregistrer"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.indigo,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: saving ? null : _save,
                    )
                        : ElevatedButton.icon(
                      icon: const Icon(Icons.edit),
                      label: const Text("Modifier"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.indigo,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => setState(() => editing = true),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==============================================================================
// ⚡ NOUVEAU — PAGE "ÉLÈVES SUPPRIMÉS" (HISTORIQUE / ARCHIVE)
// ==============================================================================
// Accessible depuis le bouton 🕘 dans l'AppBar du Registre des Élèves.
// Liste tous les élèves qui ont été supprimés/exclus du registre actif
// (widget.fraisScolaires.getElevesSupprimes()). L'argent déjà payé par ces
// élèves reste comptabilisé dans la caisse de l'école (géré directement dans
// FraisScolaires, aucune logique financière n'est dupliquée ici).
//
// Depuis cette page, on peut :
//   - Consulter la date et le motif de suppression de chaque élève.
//   - Supprimer DÉFINITIVEMENT un élève de l'archive (protégé par mot de
//     passe admin + confirmation) : son historique nominatif disparaît,
//     mais l'argent reste acquis à la caisse de l'école puisqu'il a déjà
//     été comptabilisé au moment du paiement.
//   - Vider complètement l'archive (protégé par mot de passe admin +
//     confirmation).
class ElevesSupprimesScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const ElevesSupprimesScreen({super.key, required this.fraisScolaires});

  @override
  State<ElevesSupprimesScreen> createState() => _ElevesSupprimesScreenState();
}

class _ElevesSupprimesScreenState extends State<ElevesSupprimesScreen> {
  String searchQuery = "";

  String _formatDateSuppression(String? iso) {
    if (iso == null || iso.trim().isEmpty) return "Date inconnue";
    final date = DateTime.tryParse(iso);
    if (date == null) return "Date inconnue";
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} à '
        '${two(date.hour)}:${two(date.minute)}';
  }

  Future<bool> _verifyAdminPassword() async {
    final appState = Provider.of<AppState>(context, listen: false);

    if (appState.backupPassword == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Aucun mot de passe administrateur défini. "
                  "Définissez-en un dans les Paramètres avant de continuer."),
        ),
      );
      return false;
    }

    final passController = TextEditingController();
    final bool? passwordOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Vérification Administrateur"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Entrez le mot de passe administrateur pour continuer.",
            ),
            const SizedBox(height: 14),
            TextField(
              controller: passController,
              obscureText: true,
              decoration:
              const InputDecoration(labelText: "Mot de passe"),
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
                  const SnackBar(content: Text("Mot de passe incorrect.")),
                );
              }
            },
            child: const Text("Confirmer"),
          ),
        ],
      ),
    );

    return passwordOk == true;
  }

  Future<void> _requestDeleteForever(Eleve eleve) async {
    final bool passwordOk = await _verifyAdminPassword();
    if (!passwordOk) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 26),
            SizedBox(width: 8),
            Text("Suppression définitive",
                style: TextStyle(color: Colors.red)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Vous êtes sur le point de supprimer définitivement l'historique "
                  "de l'élève suivant :",
              style: TextStyle(fontSize: 13.5),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${eleve.nom} ${eleve.postNom} ${eleve.prenom}",
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text("ID : ${eleve.id}"),
                  Text(
                      "Classe : ${eleve.classe}  |  Section : ${eleve.section}"),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              "⚠️  Cette action est IRRÉVERSIBLE : l'historique nominatif de "
                  "cet élève (informations, transactions) disparaîtra "
                  "complètement du logiciel. L'argent déjà payé reste acquis "
                  "à la caisse de l'école, puisqu'il a déjà été comptabilisé "
                  "au moment du paiement.\n\n"
                  "Après suppression, pensez à sauvegarder sur le serveur "
                  "(Paramètres → Sauvegarder sur le Serveur).",
              style: TextStyle(fontSize: 12.5, color: Colors.black87),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Supprimer définitivement",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await widget.fraisScolaires.supprimerDefinitivementEleveArchive(eleve.id);
    if (mounted) setState(() {});

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ Historique de ${eleve.nom} ${eleve.postNom} ${eleve.prenom} "
                "supprimé définitivement. Pensez à sauvegarder sur le serveur.",
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _requestClearAll() async {
    if (widget.fraisScolaires.getElevesSupprimes().isEmpty) return;

    final bool passwordOk = await _verifyAdminPassword();
    if (!passwordOk) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 26),
            SizedBox(width: 8),
            Text("Vider tout l'historique",
                style: TextStyle(color: Colors.red)),
          ],
        ),
        content: const Text(
          "Vous êtes sur le point de supprimer définitivement TOUT "
              "l'historique des élèves supprimés. Cette action est "
              "IRRÉVERSIBLE. L'argent déjà payé par ces élèves reste acquis "
              "à la caisse de l'école, puisqu'il a déjà été comptabilisé au "
              "moment du paiement.\n\n"
              "Voulez-vous vraiment continuer ?",
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Tout supprimer",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await widget.fraisScolaires.viderHistoriqueElevesSupprimes();
    if (mounted) setState(() {});

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "✅ Historique des élèves supprimés vidé. Pensez à sauvegarder "
                  "sur le serveur."),
          duration: Duration(seconds: 6),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final allSupprimes = widget.fraisScolaires.getElevesSupprimes();
    final filtered = allSupprimes.where((e) {
      return e.nom.toLowerCase().contains(searchQuery.toLowerCase()) ||
          e.postNom.toLowerCase().contains(searchQuery.toLowerCase()) ||
          e.prenom.toLowerCase().contains(searchQuery.toLowerCase()) ||
          e.id.toLowerCase().contains(searchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Élèves Supprimés"),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: "Vider tout l'historique",
            onPressed: allSupprimes.isEmpty ? null : _requestClearAll,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.indigo.withOpacity(0.07),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.indigo.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.indigo, size: 22),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Ces élèves ne figurent plus dans le registre actif, "
                          "mais l'argent qu'ils ont déjà payé reste comptabilisé "
                          "dans la caisse de l'école. La suppression définitive "
                          "d'un historique nécessite le mot de passe "
                          "administrateur.",
                      style: TextStyle(fontSize: 12.5, color: Colors.indigo),
                    ),
                  ),
                ],
              ),
            ),
            TextField(
              decoration: const InputDecoration(
                labelText: "Rechercher par nom, post-nom, ID...",
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() => searchQuery = value);
              },
            ),
            const SizedBox(height: 16),
            Text(
              "Total : ${filtered.length} élève(s) supprimé(s)",
              style:
              const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text("Aucun élève supprimé trouvé"))
                  : ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final e = filtered[index];
                  final double totalPaye =
                  widget.fraisScolaires.getStudentTotalPaid(e);
                  final String? dateSuppr = widget.fraisScolaires
                      .getDateSuppressionEleve(e.id);
                  final String? motif = widget.fraisScolaires
                      .getMotifSuppressionEleve(e.id);

                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            backgroundColor: Colors.grey.shade300,
                            backgroundImage: (e.photoBase64 != null &&
                                e.photoBase64!.isNotEmpty)
                                ? MemoryImage(base64Decode(e.photoBase64!))
                                : null,
                            child: (e.photoBase64 == null ||
                                e.photoBase64!.isEmpty)
                                ? Text(
                              e.id.isNotEmpty
                                  ? e.id.substring(0, 2)
                                  : "?",
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold),
                            )
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                              CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "${e.nom} ${e.postNom} ${e.prenom}",
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14.5),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "${e.section} - ${e.classe}  |  ID : ${e.id}",
                                  style: const TextStyle(
                                      fontSize: 12.5, color: Colors.black54),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "Total déjà payé : ${formatMontant(totalPaye)} FC",
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: Colors.green,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "Supprimé le : ${_formatDateSuppression(dateSuppr)}",
                                  style: const TextStyle(
                                      fontSize: 11.5, color: Colors.grey),
                                ),
                                if (motif != null && motif.trim().isNotEmpty)
                                  Text(
                                    "Motif : $motif",
                                    style: const TextStyle(
                                        fontSize: 11.5, color: Colors.grey),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_forever,
                                color: Colors.red, size: 26),
                            tooltip: "Supprimer définitivement l'historique",
                            onPressed: () => _requestDeleteForever(e),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}