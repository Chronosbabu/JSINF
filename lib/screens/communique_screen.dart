import 'package:flutter/material.dart';
import '../frais_scolaires.dart';
import '../models.dart';

enum _CibleType { toutLecole, section, classe, eleves }

class CommuniqueScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;

  const CommuniqueScreen({super.key, required this.fraisScolaires});

  @override
  State<CommuniqueScreen> createState() => _CommuniqueScreenState();
}

class _CommuniqueScreenState extends State<CommuniqueScreen> {
  final titleController   = TextEditingController(text: "Communiqué de l'école");
  final messageController = TextEditingController();

  _CibleType cible = _CibleType.toutLecole;
  String? selectedSection;
  String? selectedClasse;
  final Set<String> selectedStudentIds = {};

  bool isSending = false;

  List<Eleve> get _allStudents => widget.fraisScolaires.currentData.eleves;

  List<Eleve> get _studentsForPicker {
    final list = List<Eleve>.from(_allStudents);
    list.sort((a, b) => a.nom.compareTo(b.nom));
    return list;
  }

  String get _targetKey {
    switch (cible) {
      case _CibleType.toutLecole:
        return 'all';
      case _CibleType.section:
        return 'section';
      case _CibleType.classe:
        return 'classe';
      case _CibleType.eleves:
        return 'students';
    }
  }

  int get _estimatedRecipients {
    switch (cible) {
      case _CibleType.toutLecole:
        return _allStudents.length;
      case _CibleType.section:
        return selectedSection == null
            ? 0
            : _allStudents.where((e) => e.section == selectedSection).length;
      case _CibleType.classe:
        return selectedClasse == null
            ? 0
            : _allStudents.where((e) => e.classe == selectedClasse).length;
      case _CibleType.eleves:
        return selectedStudentIds.length;
    }
  }

  Future<void> _send() async {
    final title   = titleController.text.trim();
    final message = messageController.text.trim();

    if (message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Le message ne peut pas être vide")),
      );
      return;
    }
    if (cible == _CibleType.section && selectedSection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Sélectionnez une section")),
      );
      return;
    }
    if (cible == _CibleType.classe && selectedClasse == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Sélectionnez une classe")),
      );
      return;
    }
    if (cible == _CibleType.eleves && selectedStudentIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Sélectionnez au moins un élève")),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Confirmer l'envoi"),
        content: Text(
          "Envoyer ce communiqué à environ $_estimatedRecipients parent(s) ?",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Envoyer"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => isSending = true);
    final result = await widget.fraisScolaires.sendAnnouncement(
      title:   title.isEmpty ? "Communiqué de l'école" : title,
      message: message,
      target:  _targetKey,
      classe:  selectedClasse,
      section: selectedSection,
      studentIds: selectedStudentIds.toList(),
    );
    if (!mounted) return;
    setState(() => isSending = false);

    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
          Text("✅ Communiqué envoyé à ${result['notified_count']} parent(s)"),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("⚠️ ${result['error'] ?? 'Erreur inconnue'}"),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Widget _buildTargetPicker() {
    switch (cible) {
      case _CibleType.toutLecole:
        return const SizedBox.shrink();
      case _CibleType.section:
        return DropdownButtonFormField<String>(
          value: selectedSection,
          decoration: const InputDecoration(
            labelText: "Section",
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: widget.fraisScolaires.config.sections
              .map((s) => DropdownMenuItem(value: s, child: Text(s)))
              .toList(),
          onChanged: (v) => setState(() => selectedSection = v),
        );
      case _CibleType.classe:
        return Column(
          children: [
            DropdownButtonFormField<String>(
              value: selectedSection,
              decoration: const InputDecoration(
                labelText: "Section",
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: widget.fraisScolaires.config.sections
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() {
                selectedSection = v;
                selectedClasse  = null;
              }),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: selectedClasse,
              decoration: const InputDecoration(
                labelText: "Classe",
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: (selectedSection == null
                  ? <String>[]
                  : widget.fraisScolaires
                  .getAllDisplayClassesForSection(selectedSection!))
                  .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                  .toList(),
              onChanged: selectedSection == null
                  ? null
                  : (v) => setState(() => selectedClasse = v),
            ),
          ],
        );
      case _CibleType.eleves:
        return SizedBox(
          height: 260,
          child: ListView.builder(
            itemCount: _studentsForPicker.length,
            itemBuilder: (context, index) {
              final e = _studentsForPicker[index];
              final isSelected = selectedStudentIds.contains(e.id);
              return CheckboxListTile(
                dense: true,
                value: isSelected,
                title: Text("${e.nom} ${e.postNom} ${e.prenom}"),
                subtitle: Text("${e.classe} • ${e.section}"),
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      selectedStudentIds.add(e.id);
                    } else {
                      selectedStudentIds.remove(e.id);
                    }
                  });
                },
              );
            },
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Communiqué aux Parents"),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: "Titre du communiqué",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: messageController,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: "Message",
                hintText: "Rédigez ici le communiqué à envoyer aux parents...",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            const Text("Destinataires",
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text("Toute l'école"),
                  selected: cible == _CibleType.toutLecole,
                  onSelected: (_) =>
                      setState(() => cible = _CibleType.toutLecole),
                ),
                ChoiceChip(
                  label: const Text("Par section"),
                  selected: cible == _CibleType.section,
                  onSelected: (_) =>
                      setState(() => cible = _CibleType.section),
                ),
                ChoiceChip(
                  label: const Text("Par classe"),
                  selected: cible == _CibleType.classe,
                  onSelected: (_) => setState(() => cible = _CibleType.classe),
                ),
                ChoiceChip(
                  label: const Text("Élèves sélectionnés"),
                  selected: cible == _CibleType.eleves,
                  onSelected: (_) => setState(() => cible = _CibleType.eleves),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildTargetPicker(),
            const SizedBox(height: 20),
            Text(
              "Ce communiqué sera envoyé à environ $_estimatedRecipients parent(s).",
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: isSending
                    ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send),
                label: Text(isSending ? "Envoi en cours..." : "Envoyer le communiqué"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: isSending ? null : _send,
              ),
            ),
          ],
        ),
      ),
    );
  }
}