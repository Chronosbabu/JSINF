import 'package:flutter/material.dart';
import '../frais_scolaires.dart';
import '../models.dart';
import 'communique_screen.dart';

class DisciplineRegistreScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;

  const DisciplineRegistreScreen({super.key, required this.fraisScolaires});

  @override
  State<DisciplineRegistreScreen> createState() =>
      _DisciplineRegistreScreenState();
}

class _DisciplineRegistreScreenState extends State<DisciplineRegistreScreen> {
  String? selectedSection;
  String? selectedClasse;
  DateTime selectedDate = DateTime.now();

  final Set<String> absentIds = {};
  bool isLoadingAttendance = false;
  bool isSending           = false;

  @override
  void initState() {
    super.initState();
    selectedSection = widget.fraisScolaires.lastSelectedSectionFilter;
    selectedClasse  = widget.fraisScolaires.lastSelectedClassFilter;
    if (selectedSection != null && selectedClasse != null) {
      _loadExistingAttendance();
    }
  }

  String get _dateStr =>
      "${selectedDate.year.toString().padLeft(4, '0')}-"
          "${selectedDate.month.toString().padLeft(2, '0')}-"
          "${selectedDate.day.toString().padLeft(2, '0')}";

  List<Eleve> get _filteredStudents {
    final list = widget.fraisScolaires.getStudentsBySectionAndClass(
      selectedSection,
      selectedClasse,
    );
    list.sort((a, b) => a.nom.compareTo(b.nom));
    return list;
  }

  Future<void> _loadExistingAttendance() async {
    if (selectedClasse == null) return;
    setState(() => isLoadingAttendance = true);
    final result = await widget.fraisScolaires.getAttendance(
      classe: selectedClasse!,
      date:   _dateStr,
    );
    if (!mounted) return;
    setState(() {
      absentIds
        ..clear()
        ..addAll(List<String>.from(result['absents'] ?? []));
      isLoadingAttendance = false;
    });
  }

  void _onSectionChanged(String? value) {
    setState(() {
      selectedSection = value;
      selectedClasse  = null;
      absentIds.clear();
    });
    widget.fraisScolaires.lastSelectedSectionFilter = value;
    widget.fraisScolaires.lastSelectedClassFilter    = null;
    widget.fraisScolaires.saveData();
  }

  void _onClasseChanged(String? value) {
    setState(() => selectedClasse = value);
    widget.fraisScolaires.lastSelectedClassFilter = value;
    widget.fraisScolaires.saveData();
    _loadExistingAttendance();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2023),
      lastDate: DateTime(2030),
    );
    if (picked != null) {
      setState(() => selectedDate = picked);
      _loadExistingAttendance();
    }
  }

  void _toggleAbsent(String id) {
    setState(() {
      if (absentIds.contains(id)) {
        absentIds.remove(id);
      } else {
        absentIds.add(id);
      }
    });
  }

  Future<void> _sendAbsences() async {
    if (selectedClasse == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Sélectionnez d'abord une section et une classe")),
      );
      return;
    }
    if (absentIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Aucun élève coché comme absent")),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Confirmer l'envoi"),
        content: Text(
          "Envoyer une notification d'absence non justifiée aux parents "
              "de ${absentIds.length} élève(s) pour le $_dateStr ?",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Envoyer"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => isSending = true);
    final result = await widget.fraisScolaires.recordAbsences(
      absentIds: absentIds.toList(),
      classe:    selectedClasse!,
      section:   selectedSection!,
      date:      _dateStr,
    );
    if (!mounted) return;
    setState(() => isSending = false);

    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              "✅ ${result['notified_count']} parent(s) notifié(s)"),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("⚠️ ${result['error'] ?? 'Erreur inconnue'}"),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  void _showConvocationDialog(Eleve eleve) {
    final titleController = TextEditingController(
        text: "Convocation des parents");
    final messageController = TextEditingController(
      text: "Nous souhaitons vous rencontrer au sujet du comportement de "
          "votre enfant ${eleve.nom} ${eleve.prenom} à l'école. Merci de "
          "vous présenter à l'administration dans les meilleurs délais.",
    );
    bool sending = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text("Convoquer — ${eleve.nom} ${eleve.prenom}"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: "Titre",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: messageController,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: "Message au parent",
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Annuler")),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white),
              onPressed: sending
                  ? null
                  : () async {
                if (messageController.text.trim().isEmpty) return;
                setDialogState(() => sending = true);
                final result = await widget.fraisScolaires.sendConvocation(
                  studentId: eleve.id,
                  title:     titleController.text.trim(),
                  message:   messageController.text.trim(),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        result['success'] == true
                            ? "✅ Convocation envoyée au parent"
                            : "⚠️ ${result['error'] ?? 'Échec de l\'envoi'}",
                      ),
                      backgroundColor: result['success'] == true
                          ? Colors.green
                          : Colors.orange,
                    ),
                  );
                }
              },
              child: sending
                  ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : const Text("Envoyer"),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final students = _filteredStudents;
    final classesDisponibles = selectedSection == null
        ? <String>[]
        : widget.fraisScolaires
        .getAllDisplayClassesForSection(selectedSection!);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Registre de Discipline"),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.campaign),
            tooltip: "Lancer un communiqué",
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    CommuniqueScreen(fraisScolaires: widget.fraisScolaires),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: selectedSection,
                        decoration: const InputDecoration(
                          labelText: "Section",
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: widget.fraisScolaires.config.sections
                            .map((s) =>
                            DropdownMenuItem(value: s, child: Text(s)))
                            .toList(),
                        onChanged: _onSectionChanged,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: selectedClasse,
                        decoration: const InputDecoration(
                          labelText: "Classe",
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: classesDisponibles
                            .map((c) =>
                            DropdownMenuItem(value: c, child: Text(c)))
                            .toList(),
                        onChanged:
                        selectedSection == null ? null : _onClasseChanged,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: "Date",
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.calendar_today, size: 18),
                    ),
                    child: Text(_dateStr),
                  ),
                ),
              ],
            ),
          ),
          if (selectedClasse != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "${students.length} élève(s) • "
                        "${absentIds.length} absent(s) coché(s)",
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  if (isLoadingAttendance)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
          const Divider(),
          Expanded(
            child: selectedClasse == null
                ? const Center(
                child: Text(
                    "Sélectionnez une section et une classe pour "
                        "commencer le registre du jour."))
                : students.isEmpty
                ? const Center(child: Text("Aucun élève trouvé"))
                : ListView.builder(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 6),
              itemCount: students.length,
              itemBuilder: (context, index) {
                final e = students[index];
                final isAbsent = absentIds.contains(e.id);
                return Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  color: isAbsent ? Colors.red.shade50 : null,
                  child: ListTile(
                    leading: Checkbox(
                      value: isAbsent,
                      activeColor: Colors.red,
                      onChanged: (_) => _toggleAbsent(e.id),
                    ),
                    title: Text("${e.nom} ${e.postNom} ${e.prenom}"),
                    subtitle: Text(
                      isAbsent ? "Marqué ABSENT aujourd'hui" : "Présent",
                      style: TextStyle(
                        color: isAbsent ? Colors.red : Colors.green,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.campaign_outlined,
                          color: Colors.orange),
                      tooltip: "Convoquer le parent",
                      onPressed: () => _showConvocationDialog(e),
                    ),
                    onTap: () => _toggleAbsent(e.id),
                  ),
                );
              },
            ),
          ),
          if (selectedClasse != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: isSending
                      ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send),
                  label: Text(
                    isSending
                        ? "Envoi en cours..."
                        : "Envoyer les absences (${absentIds.length})",
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: isSending ? null : _sendAbsences,
                ),
              ),
            ),
        ],
      ),
    );
  }
}