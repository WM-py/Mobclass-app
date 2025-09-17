import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

const Color primaryColor = Color(0xFF021E4C);
const _dias = [
  'Segunda-feira',
  'Terça-feira',
  'Quarta-feira',
  'Quinta-feira',
  'Sexta-feira'
];

class AgendaEscolarScreen extends StatefulWidget {
  const AgendaEscolarScreen({Key? key}) : super(key: key);

  @override
  State<AgendaEscolarScreen> createState() => _AgendaEscolarScreenState();
}

class _AgendaEscolarScreenState extends State<AgendaEscolarScreen> {
  String _turmaId = '';
  String _searchText = '';
  Timer? _debounce;

  // mapas auxiliares
  Map<String, dynamic> _materias = {};                 // materiaId -> { nome, ... }
  Map<String, String> _professores = {};               // professorId -> nome
  Map<String, String> _professorPorMateriaETurma = {}; // "materiaId-turmaId" -> professorId

  @override
  void initState() {
    super.initState();
    _ativarPersistence();
    _initComoAlunoLogado();
  }

  Future<void> _ativarPersistence() async {
    try {
      await FirebaseFirestore.instance.enablePersistence();
    } catch (_) {}
  }

  Future<void> _initComoAlunoLogado() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final alunoSnap = await FirebaseFirestore.instance.collection('alunos').doc(uid).get();
      setState(() => _turmaId = alunoSnap.data()?['turmaId'] ?? '');
      await _loadMateriasEProfessores();
      if (mounted) setState(() {}); // força rebuild da StreamBuilder com mapas carregados
    }
  }

  Future<void> _loadMateriasEProfessores() async {
    // base
    final materiasSnap = FirebaseFirestore.instance.collection('materias').get();
    final professoresSnap = FirebaseFirestore.instance.collection('professores').get();

    // nome correto e filtrado por turma
    final vinculosSnap = FirebaseFirestore.instance
        .collection('professores_materias')
        .where('turmaId', isEqualTo: _turmaId)
        .get();

    final results = await Future.wait([materiasSnap, professoresSnap, vinculosSnap]);

    final materias = {
      for (var doc in results[0].docs) doc.id: doc.data(),
    };

    final professores = {
      for (var doc in results[1].docs) doc.id: (doc.data()['nome'] as String? ?? '—'),
    };

    final vinculos = <String, String>{};
    for (var doc in results[2].docs) {
      final data = doc.data();
      final materiaId = (data['materiaId'] as String?)?.trim() ?? '';
      final turmaId = (data['turmaId'] as String?)?.trim() ?? '';
      final professorId = (data['professorId'] as String?)?.trim() ?? '';
      if (materiaId.isEmpty || turmaId.isEmpty || professorId.isEmpty) continue;
      vinculos['$materiaId-$turmaId'] = professorId;
    }

    setState(() {
      _materias = materias;
      _professores = professores;
      _professorPorMateriaETurma = vinculos;
    });
  }

  Stream<List<Map<String, dynamic>>> _agendaFixaStream() {
    if (_turmaId.isEmpty) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection('agenda')
        .where('turmaId', isEqualTo: _turmaId)
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
  }

  Map<String, List<Map<String, dynamic>>> _groupByDia(List<Map<String, dynamic>> aulas) {
    final map = {for (final d in _dias) d: <Map<String, dynamic>>[]};

    for (final a in aulas) {
      final dia = (a['diaSemana'] ?? '') as String;
      if (!map.containsKey(dia)) continue;

      final materiaId = a['materiaId'] as String?;
      final profIdDoc = (a['professorId'] as String?)?.trim(); // pode vir vazio
      final materia = (materiaId != null && materiaId.isNotEmpty)
          ? (_materias[materiaId]?['nome'] ?? '')
          : '';

      // 1) usa professorId do doc se vier preenchido
      // 2) senão, busca no vínculo professores_materias por turma+matéria
      String prof = '';
      if (profIdDoc != null && profIdDoc.isNotEmpty) {
        prof = _professores[profIdDoc] ?? '';
      } else if (materiaId != null && materiaId.isNotEmpty) {
        final vincKey = '$materiaId-$_turmaId';
        final profId = _professorPorMateriaETurma[vincKey];
        if (profId != null && profId.isNotEmpty) {
          prof = _professores[profId] ?? '';
        }
      }

      // filtro de busca por matéria ou professor (case-insensitive)
      if (_searchText.isNotEmpty) {
        final q = _searchText.toLowerCase();
        final matchMateria = materia.toLowerCase().contains(q);
        final matchProf = prof.toLowerCase().contains(q);
        if (!matchMateria && !matchProf) continue;
      }

      map[dia]!.add({...a, '_materia': materia, '_prof': prof});
    }

    // ordenar por 'ordem' (se existir) ou pelo horário "HH:MM - HH:MM"
    for (final d in _dias) {
      map[d]!.sort((a, b) {
        final oa = a['ordem'] as int?;
        final ob = b['ordem'] as int?;
        if (oa != null && ob != null) return oa.compareTo(ob);
        return (a['horario'] as String? ?? '').compareTo(b['horario'] as String? ?? '');
      });
    }

    return map;
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      setState(() => _searchText = value);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text('Agenda Escolar', style: TextStyle(color: Colors.white)),
        centerTitle: true,
        backgroundColor: primaryColor,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Buscar por matéria ou professor',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _agendaFixaStream(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return _ErroCard(
                    mensagem: 'Não foi possível carregar a agenda.',
                    onRetry: () => setState(() {}),
                  );
                }

                final byDia = _groupByDia(snap.data ?? const []);
                final temAula = byDia.values.any((l) => l.isNotEmpty);
                if (!temAula) {
                  return const Center(child: Text('Nenhuma aula encontrada.'));
                }

                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final dia in _dias)
                      if ((byDia[dia] ?? const []).isNotEmpty) ...[
                        _HeaderDia(dia: dia),
                        const SizedBox(height: 8),
                        ...byDia[dia]!.map(_cardFromAula),
                        const SizedBox(height: 16),
                      ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardFromAula(Map<String, dynamic> a) {
    final horario = a['horario'] as String? ?? '-';
    final materiaId = a['materiaId'] as String?;
    final isIntervalo = materiaId == null || materiaId.isEmpty;

    if (isIntervalo) return _CardIntervalo(horario: horario);

    final materia = a['_materia'] as String? ?? 'Matéria indefinida';
    final professor = (a['_prof'] as String?)?.trim();
    final local = a['local'] as String?;

    return _CardAula(
      horario: horario,
      materia: materia,
      professor: (professor != null && professor.isNotEmpty)
          ? professor
          : 'Professor(a) não informado',
      local: local,
    );
  }
}

class _HeaderDia extends StatelessWidget {
  final String dia;
  const _HeaderDia({required this.dia});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2F6BF0),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(14),
      child: Text(
        dia,
        style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _CardAula extends StatelessWidget {
  final String horario;
  final String materia;
  final String professor;
  final String? local;
  const _CardAula({
    required this.horario,
    required this.materia,
    required this.professor,
    this.local,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('⏰ $horario', style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 4),
            Text('📘 $materia', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Row(
              children: [
                Text('👤 $professor', style: const TextStyle(fontSize: 14, color: Colors.grey)),
                if (local?.isNotEmpty == true) ...[
                  const Text(' · ', style: TextStyle(fontSize: 14, color: Colors.grey)),
                  const Text('📍 ', style: TextStyle(fontSize: 14, color: Colors.grey)),
                  Text(local ?? '', style: const TextStyle(fontSize: 14, color: Colors.grey)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CardIntervalo extends StatelessWidget {
  final String horario;
  const _CardIntervalo({required this.horario});

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Text('⏰ $horario', style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            const Text('Intervalo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _ErroCard extends StatelessWidget {
  final String mensagem;
  final VoidCallback? onRetry;
  const _ErroCard({required this.mensagem, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        color: Colors.red[50],
        margin: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                mensagem,
                style: const TextStyle(fontSize: 16, color: Colors.red),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onRetry,
                child: const Text('Tentar novamente'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}















