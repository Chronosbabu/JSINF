import 'package:flutter/material.dart';

import '../frais_scolaires.dart';
class GrilleFraisScreen extends StatefulWidget {
  final FraisScolaires fraisScolaires;
  const GrilleFraisScreen({super.key, required this.fraisScolaires});
  @override
  State<GrilleFraisScreen> createState() => _GrilleFraisScreenState();
}
class _GrilleFraisScreenState extends State<GrilleFraisScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String? _filterSection; // null = toutes les sections
  String? _filterClasse; // null = toutes les classes (dans la section choisie)
  String? _autresFraisFilterSection;
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }
  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
  FraisScolaires get fs => widget.fraisScolaires;

  String _formatFc(double v) {

    final s = v.round().toString();

    final buffer = StringBuffer();

    for (int i = 0; i < s.length; i++) {

      final posFromEnd = s.length - i;

      buffer.write(s[i]);

      if (posFromEnd > 1 && posFromEnd % 3 == 1) buffer.write(' ');

    }

    return buffer.toString();

  }

  String _autreFraisScopeLabel(AutreFrais f) {

    switch (f.scope) {

      case 'section':

        return "Section : ${f.section ?? '-'}";

      case 'classe':

        return "Classe : ${f.classe ?? '-'}";

      default:

        return "Toute l'école (toutes sections)";

    }

  }

  bool _autreFraisMatchesSectionFilter(AutreFrais f, String? section) {

    if (section == null) return true;

    switch (f.scope) {

      case 'all':

        return true;

      case 'section':

        return f.section == section;

      case 'classe':

        final classesDeLaSection = fs.getAllDisplayClassesForSection(section);

        return f.classe != null && classesDeLaSection.contains(f.classe);

      default:

        return true;

    }

  }

  // ==========================================================================

  // BUILD PRINCIPAL

  // ==========================================================================

  @override

  Widget build(BuildContext context) {

    return Scaffold(

      appBar: AppBar(

        title: const Text("Grille des Frais"),

        bottom: TabBar(

          controller: _tabController,

          tabs: const [

            Tab(text: "Frais Mensuel", icon: Icon(Icons.calendar_month)),

            Tab(text: "Autres Frais", icon: Icon(Icons.receipt_long)),

          ],

        ),

      ),

      body: TabBarView(

        controller: _tabController,

        children: [

          _buildFraisMensuelTab(),

          _buildAutresFraisTab(),

        ],

      ),

    );

  }

  // ==========================================================================

  // ONGLET 1 : FRAIS MENSUEL (par Section / par Classe)

  // ==========================================================================

  Widget _buildFraisMensuelTab() {

    final sections = fs.config.sections;

    if (sections.isEmpty) {

      return const Center(

        child: Text(

          "Aucune section configurée pour le moment.",

          style: TextStyle(color: Colors.grey),

        ),

      );

    }

    final classesForFilterSection = _filterSection != null

        ? fs.getClassesForSection(_filterSection!)

        : <String>[];

    final totalClasses = sections.fold<int>(

        0, (sum, s) => sum + fs.getClassesForSection(s).length);

    final totalAutresFrais = fs.getAutresFrais().length;

    return Column(

      children: [

        // --------------------- BARRE DE FILTRES ---------------------

        Container(

          padding: const EdgeInsets.all(12),

          color: Colors.indigo.withAlpha(12),

          child: Column(

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              Row(

                children: [

                  Expanded(

                    child: DropdownButtonFormField<String>(

                      value: _filterSection,

                      isExpanded: true,

                      decoration: const InputDecoration(

                        labelText: "Section / Option",

                        border: OutlineInputBorder(),

                        isDense: true,

                        filled: true,

                        fillColor: Colors.white,

                      ),

                      items: [

                        const DropdownMenuItem<String>(

                          value: null,

                          child: Text("Toutes les sections"),

                        ),

                        ...sections.map(

                              (s) => DropdownMenuItem(value: s, child: Text(s)),

                        ),

                      ],

                      onChanged: (v) => setState(() {

                        _filterSection = v;

                        _filterClasse = null;

                      }),

                    ),

                  ),

                  if (_filterSection != null) ...[

                    const SizedBox(width: 10),

                    Expanded(

                      child: DropdownButtonFormField<String>(

                        value: _filterClasse,

                        isExpanded: true,

                        decoration: const InputDecoration(

                          labelText: "Classe",

                          border: OutlineInputBorder(),

                          isDense: true,

                          filled: true,

                          fillColor: Colors.white,

                        ),

                        items: [

                          const DropdownMenuItem<String>(

                            value: null,

                            child: Text("Toutes les classes"),

                          ),

                          ...classesForFilterSection.map(

                                (c) => DropdownMenuItem(value: c, child: Text(c)),

                          ),

                        ],

                        onChanged: (v) => setState(() => _filterClasse = v),

                      ),

                    ),

                  ],

                ],

              ),

              const SizedBox(height: 8),

              Wrap(

                spacing: 8,

                runSpacing: 6,

                children: [

                  _statChip(Icons.apartment, "$totalClasses classe(s)"),

                  _statChip(Icons.layers, "${sections.length} section(s)"),

                  _statChip(

                      Icons.receipt_long, "$totalAutresFrais autre(s) frais"),

                ],

              ),

              const SizedBox(height: 6),

              Row(

                children: [

                  Icon(Icons.info_outline,

                      size: 14, color: Colors.orange.shade700),

                  const SizedBox(width: 4),

                  Expanded(

                    child: Text(

                      "Les cases orange indiquent un montant différent du "

                          "frais de base de la section (exception).",

                      style: TextStyle(

                        fontSize: 11,

                        color: Colors.grey.shade700,

                        fontStyle: FontStyle.italic,

                      ),

                    ),

                  ),

                ],

              ),

            ],

          ),

        ),

        const Divider(height: 1),

        // --------------------- CONTENU ---------------------

        Expanded(

          child: (_filterSection != null && _filterClasse != null)

              ? _buildFocusedClasseView(_filterSection!, _filterClasse!)

              : ListView(

            padding: const EdgeInsets.all(12),

            children:

            (_filterSection != null ? [_filterSection!] : sections)

                .map(

                  (section) => _buildSectionCard(

                section,

                initiallyExpanded: _filterSection != null ||

                    sections.indexOf(section) == 0,

              ),

            )

                .toList(),

          ),

        ),

      ],

    );

  }

  Widget _statChip(IconData icon, String label) {

    return Chip(

      avatar: Icon(icon, size: 16, color: Colors.indigo),

      label: Text(label, style: const TextStyle(fontSize: 12)),

      backgroundColor: Colors.white,

      side: BorderSide(color: Colors.indigo.shade100),

      visualDensity: VisualDensity.compact,

    );

  }

  /// Carte dépliable pour une section : tarif de base + tableau

  /// "Classe × Mois" pour toutes les classes de cette section.

  Widget _buildSectionCard(String section, {bool initiallyExpanded = false}) {

    final baseFeeExemple = fs.getRequiredForMonth(fs.months.first, section);

    final classesNumero = fs.getClassesForSection(section);

    return Card(

      margin: const EdgeInsets.only(bottom: 12),

      elevation: 1.5,

      child: ExpansionTile(

        initiallyExpanded: initiallyExpanded,

        title: Text(

          section,

          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),

        ),

        subtitle: Padding(

          padding: const EdgeInsets.only(top: 4),

          child: Text(

            "Frais de base : ${_formatFc(baseFeeExemple)} FC / mois  •  "

                "${classesNumero.length} classe(s)",

            style: const TextStyle(fontSize: 12),

          ),

        ),

        childrenPadding: const EdgeInsets.only(bottom: 12),

        children: [

          if (classesNumero.isEmpty)

            const Padding(

              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),

              child: Text(

                "Aucune classe définie pour cette section.",

                style:

                TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),

              ),

            )

          else

            SingleChildScrollView(

              scrollDirection: Axis.horizontal,

              padding: const EdgeInsets.symmetric(horizontal: 12),

              child: _buildSectionTable(section, classesNumero),

            ),

        ],

      ),

    );

  }

  /// Construit le tableau "Classe × Mois" pour une section donnée.

  /// Une première ligne de référence montre le tarif de base de la

  /// section (sans aucune exception de classe), pour comparaison visuelle

  /// immédiate avec les lignes suivantes (une par classe).

  Widget _buildSectionTable(String section, List<String> classesNumero) {

    final months = fs.months;

    final columns = <DataColumn>[

      const DataColumn(

        label: Text('Classe', style: TextStyle(fontWeight: FontWeight.bold)),

      ),

      ...months.map(

            (m) => DataColumn(

          label: Text(

            m.length > 4 ? m.substring(0, 4) : m,

            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),

          ),

          tooltip: m,

        ),

      ),

    ];

    final baseRow = DataRow(

      color: WidgetStateProperty.all(Colors.indigo.withAlpha(15)),

      cells: [

        const DataCell(

          Text(

            "Base (section)",

            style:

            TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.w600),

          ),

        ),

        ...months.map((m) {

          final v = fs.getRequiredForMonth(m, section);

          return DataCell(Text(_formatFc(v)));

        }),

      ],

    );

    final classRows = classesNumero.map((numero) {

      final subs = fs.getSubClassesFor(section, numero);

      final label = subs.isEmpty ? numero : "$numero (${subs.join(', ')})";

      return DataRow(

        cells: [

          DataCell(

            Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),

          ),

          ...months.map((m) {

            final v = fs.getRequiredForMonth(m, section, numero);

            final base = fs.getRequiredForMonth(m, section);

            final estException = (v - base).abs() > 0.001;

            return DataCell(

              Container(

                padding:

                const EdgeInsets.symmetric(horizontal: 6, vertical: 3),

                decoration: estException

                    ? BoxDecoration(

                  color: Colors.orange.withAlpha(40),

                  borderRadius: BorderRadius.circular(4),

                )

                    : null,

                child: Text(

                  _formatFc(v),

                  style: TextStyle(

                    fontWeight:

                    estException ? FontWeight.bold : FontWeight.normal,

                    color: estException ? Colors.orange.shade800 : null,

                  ),

                ),

              ),

            );

          }),

        ],

      );

    }).toList();

    return DataTable(

      headingRowHeight: 36,

      dataRowHeight: 42,

      columnSpacing: 18,

      columns: columns,

      rows: [baseRow, ...classRows],

    );

  }

  /// Vue "focus" affichée quand Section ET Classe sont précisément

  /// sélectionnées : répond directement à "combien paient les élèves de

  /// telle classe, pour tel mois ?" sous forme de liste mois par mois.

  Widget _buildFocusedClasseView(String section, String classeNumero) {

    final months = fs.months;

    final subs = fs.getSubClassesFor(section, classeNumero);

    final base = fs.getRequiredForMonth(months.first, section);

    return ListView(

      padding: const EdgeInsets.all(16),

      children: [

        Card(

          color: Colors.indigo.withAlpha(18),

          child: Padding(

            padding: const EdgeInsets.all(14),

            child: Column(

              crossAxisAlignment: CrossAxisAlignment.start,

              children: [

                Text(

                  "$section — $classeNumero",

                  style:

                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),

                ),

                if (subs.isNotEmpty)

                  Padding(

                    padding: const EdgeInsets.only(top: 4),

                    child: Text(

                      "Sous-classes concernées : ${subs.join(', ')}",

                      style: const TextStyle(fontSize: 12, color: Colors.grey),

                    ),

                  ),

                const SizedBox(height: 6),

                Text(

                  "Frais de base de la section : ${_formatFc(base)} FC / mois",

                  style: const TextStyle(fontSize: 12, color: Colors.grey),

                ),

              ],

            ),

          ),

        ),

        const SizedBox(height: 14),

        ...months.map((m) {

          final v = fs.getRequiredForMonth(m, section, classeNumero);

          final baseM = fs.getRequiredForMonth(m, section);

          final estException = (v - baseM).abs() > 0.001;

          return Card(

            margin: const EdgeInsets.only(bottom: 8),

            child: ListTile(

              leading: Icon(

                estException ? Icons.priority_high : Icons.check_circle_outline,

                color: estException ? Colors.orange : Colors.green,

              ),

              title: Text(m),

              trailing: Text(

                "${_formatFc(v)} FC",

                style: TextStyle(

                  fontWeight: FontWeight.bold,

                  fontSize: 15,

                  color: estException ? Colors.orange.shade800 : null,

                ),

              ),

              subtitle: estException

                  ? Text(

                "Exception — différent du frais de base "

                    "(${_formatFc(baseM)} FC)",

                style: const TextStyle(fontSize: 11),

              )

                  : null,

            ),

          );

        }),

      ],

    );

  }

  // ==========================================================================

  // ONGLET 2 : AUTRES FRAIS (ponctuels)

  // ==========================================================================

  Widget _buildAutresFraisTab() {

    final allFrais = fs.getAutresFrais();

    final filtered = allFrais

        .where(

            (f) => _autreFraisMatchesSectionFilter(f, _autresFraisFilterSection))

        .toList();

    return Column(

      children: [

        Container(

          padding: const EdgeInsets.all(12),

          color: Colors.indigo.withAlpha(12),

          child: DropdownButtonFormField<String>(

            value: _autresFraisFilterSection,

            isExpanded: true,

            decoration: const InputDecoration(

              labelText: "Filtrer par section",

              border: OutlineInputBorder(),

              isDense: true,

              filled: true,

              fillColor: Colors.white,

            ),

            items: [

              const DropdownMenuItem<String>(

                value: null,

                child: Text("Toutes les sections"),

              ),

              ...fs.config.sections.map(

                    (s) => DropdownMenuItem(value: s, child: Text(s)),

              ),

            ],

            onChanged: (v) => setState(() => _autresFraisFilterSection = v),

          ),

        ),

        const Divider(height: 1),

        Expanded(

          child: filtered.isEmpty

              ? const Center(

            child: Text(

              "Aucun frais additionnel pour ce filtre.",

              style: TextStyle(color: Colors.grey),

            ),

          )

              : ListView.builder(

            padding: const EdgeInsets.all(12),

            itemCount: filtered.length,

            itemBuilder: (ctx, i) => _buildAutreFraisCard(filtered[i]),

          ),

        ),

      ],

    );

  }

  Widget _buildAutreFraisCard(AutreFrais frais) {

    final eligibles = fs.getEligibleStudentsForAutreFrais(frais);

    final paiements = fs

        .getAutresFraisPaiementsForYear()

        .where((p) => p.autreFraisId == frais.id)

        .toList();

    final nbPayes = paiements.length;

    final totalCollecte = paiements.fold(0.0, (s, p) => s + p.montant);

    final totalPotentiel = eligibles.length * frais.montant;

    final progress = eligibles.isEmpty ? 0.0 : nbPayes / eligibles.length;

    return Card(

      margin: const EdgeInsets.only(bottom: 12),

      child: Padding(

        padding: const EdgeInsets.all(14),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Row(

              children: [

                Expanded(

                  child: Text(

                    frais.nom,

                    style:

                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),

                  ),

                ),

                Text(

                  "${_formatFc(frais.montant)} FC",

                  style: const TextStyle(

                    fontSize: 16,

                    fontWeight: FontWeight.bold,

                    color: Colors.indigo,

                  ),

                ),

              ],

            ),

            const SizedBox(height: 4),

            Text(

              _autreFraisScopeLabel(frais),

              style: const TextStyle(fontSize: 12, color: Colors.grey),

            ),

            const SizedBox(height: 10),

            ClipRRect(

              borderRadius: BorderRadius.circular(6),

              child: LinearProgressIndicator(

                value: progress.clamp(0.0, 1.0),

                minHeight: 8,

                backgroundColor: Colors.grey.shade200,

                color: progress >= 1.0 ? Colors.green : Colors.indigo,

              ),

            ),

            const SizedBox(height: 6),

            Row(

              mainAxisAlignment: MainAxisAlignment.spaceBetween,

              children: [

                Text(

                  "$nbPayes / ${eligibles.length} élève(s) ont payé",

                  style: const TextStyle(fontSize: 12),

                ),

                Text(

                  "${_formatFc(totalCollecte)} / ${_formatFc(totalPotentiel)} FC",

                  style:

                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),

                ),

              ],

            ),

          ],

        ),

      ),

    );

  }
}
