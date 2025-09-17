import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

const Color primaryColor = Color(0xFF021E4C);

class ComunicadosScreen extends StatefulWidget {
  const ComunicadosScreen({Key? key}) : super(key: key);

  @override
  State<ComunicadosScreen> createState() => _ComunicadosScreenState();
}

class _ComunicadosScreenState extends State<ComunicadosScreen> {
  String _alunoUid = '';
  String _turmaId = '';
  bool _loading = true;

  // === Novos estados de UX de filtros ===
  final int _cutoffDays = 30; // janela padrão
  bool _incluirAntigos = false; // por padrão, ocultar >30d

  DateTime _cutoffDate() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).subtract(Duration(days: _cutoffDays));
  }

  int _filtrosAtivosCount() {
    int n = 0;
    if (_incluirAntigos) n++;
    return n;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as String?;
    if (args != null && args.isNotEmpty) {
      _alunoUid = args;
      _initComAluno(_alunoUid);
    } else {
      _initComoAlunoLogado();
    }
  }

  Future<void> _initComAluno(String alunoUid) async {
    final alunoSnap =
    await FirebaseFirestore.instance.collection('alunos').doc(alunoUid).get();
    _turmaId = alunoSnap.data()?['turmaId'] ?? '';
    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _initComoAlunoLogado() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _alunoUid = uid;
      await _initComAluno(uid);
    }
  }

  // Stream que mescla comunicados da turma + comunicados gerais ("todas")
  // e aplica filtro de data (quando _incluirAntigos == false)
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _comunicadosStream() async* {
    if (_turmaId.isEmpty) yield [];

    Query<Map<String, dynamic>> turmaQ = FirebaseFirestore.instance
        .collection('comunicados')
        .where('turmaId', isEqualTo: _turmaId);

    Query<Map<String, dynamic>> todasQ = FirebaseFirestore.instance
        .collection('comunicados')
        .where('turmaId', isEqualTo: 'todas');

    if (!_incluirAntigos) {
      final cutoffTs = Timestamp.fromDate(_cutoffDate());
      turmaQ = turmaQ.where('data', isGreaterThanOrEqualTo: cutoffTs);
      todasQ = todasQ.where('data', isGreaterThanOrEqualTo: cutoffTs);
    }

    final turmaStream = turmaQ.orderBy('data', descending: true).snapshots();
    final todasStream = todasQ.orderBy('data', descending: true).snapshots();

    // Mescla simples: quando chegar um snapshot da turma,
    // pega o mais recente de "todas" e ordena junto (desc).
    await for (final turmaSnap in turmaStream) {
      final todasSnap = await todasStream.first;
      final todos = [...turmaSnap.docs, ...todasSnap.docs];
      todos.sort((a, b) => b.data()['data'].compareTo(a.data()['data']));
      yield todos;
    }
  }

  String _formatarData(Timestamp? ts) {
    if (ts == null) return '-';
    final d = ts.toDate();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  // ===== Bottom Sheet de filtros =====
  Future<void> _abrirFiltrosBottomSheet() async {
    bool incluirAntigos = _incluirAntigos;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final viewInsets = MediaQuery.of(context).viewInsets;
        return Padding(
          padding: EdgeInsets.only(bottom: viewInsets.bottom),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tune, color: primaryColor),
                      const SizedBox(width: 8),
                      const Text('Filtros', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Fechar',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  Row(
                    children: [
                      const Icon(Icons.history, size: 18, color: Colors.black54),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Incluir comunicados com mais de $_cutoffDays dias',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                      Switch(
                        value: incluirAntigos,
                        onChanged: (v) => incluirAntigos = v,
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() => _incluirAntigos = false);
                          Navigator.pop(context);
                        },
                        child: const Text('Limpar'),
                      ),
                      const Spacer(),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: primaryColor),
                        onPressed: () {
                          setState(() => _incluirAntigos = incluirAntigos);
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.check, color: Colors.white),
                        label: const Text('Aplicar', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text('Comunicados',
            style: TextStyle(color: Colors.white, fontSize: 22)),
        centerTitle: true,
        backgroundColor: primaryColor,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Filtros',
            icon: const Icon(Icons.tune, color: Colors.white),
            onPressed: _abrirFiltrosBottomSheet,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Barra compacta de filtros + contador + etiqueta de escopo
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _abrirFiltrosBottomSheet,
                  icon: const Icon(Icons.filter_list, color: primaryColor),
                  label: Row(
                    children: [
                      const Text('Filtros', style: TextStyle(color: primaryColor)),
                      const SizedBox(width: 6),
                      if (_filtrosAtivosCount() > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: primaryColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _filtrosAtivosCount().toString(),
                            style: const TextStyle(color: primaryColor, fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: primaryColor),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                    stream: _comunicadosStream(),
                    builder: (_, snap) => Text(
                      'Mostrando ${snap.data?.length ?? 0} comunicados',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _incluirAntigos
                    ? 'Mostrando todos (inclui +$_cutoffDays dias)'
                    : 'Mostrando últimos $_cutoffDays dias',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
            const SizedBox(height: 8),

            // Lista reativa
            Expanded(
              child: StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                stream: _comunicadosStream(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('Erro: ${snapshot.error}'));
                  }

                  final docs = snapshot.data ?? [];
                  if (docs.isEmpty) {
                    return Center(
                      child: Text(
                        _incluirAntigos
                            ? 'Nenhum comunicado disponível.'
                            : 'Nenhum comunicado nos últimos $_cutoffDays dias.\nVocê pode incluir antigos pelo filtro.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    );
                  }

                  return ListView.separated(
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final data = docs[index].data();
                      final assunto = data['assunto'] ?? '-';
                      final mensagem = data['mensagem'] ?? '-';
                      final ts = data['data'] as Timestamp?;
                      final dataFormatada = _formatarData(ts);

                      return Card(
                        elevation: 3,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.announcement, color: primaryColor, size: 26),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      assunto,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: primaryColor,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    dataFormatada,
                                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(mensagem, style: const TextStyle(fontSize: 16)),
                            ],
                          ),
                        ),
                      );
                    },
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








