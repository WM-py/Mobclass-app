import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

const Color primaryColor = Color(0xFF021E4C);

class FrequenciaScreen extends StatefulWidget {
  const FrequenciaScreen({Key? key}) : super(key: key);

  @override
  State<FrequenciaScreen> createState() => _FrequenciaScreenState();
}

class _FrequenciaScreenState extends State<FrequenciaScreen> {
  bool _booting = true;
  bool _mountedOnce = false;

  String _alunoUid = '';
  String _turmaId = '';
  String _turmaNome = '';

  Map<String, String> _materias = {};
  Map<String, String> _professores = {};
  final Map<String, List<AgendaItem>> _agendaPorDia = {};
  Stream<QuerySnapshot<Map<String, dynamic>>>? _frequenciasStream;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mountedOnce) return;
    _mountedOnce = true;

    final arg = ModalRoute.of(context)?.settings.arguments;
    if (arg is String && arg.isNotEmpty) {
      _alunoUid = arg;
      _initWithAluno(_alunoUid);
    } else {
      _initWithLoggedAluno();
    }
  }

  Future<void> _initWithLoggedAluno() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _booting = false);
      return;
    }
    _alunoUid = uid;
    await _initWithAluno(uid);
  }

  Future<void> _initWithAluno(String alunoUid) async {
    try {
      final alunoSnap = await FirebaseFirestore.instance.collection('alunos').doc(alunoUid).get();
      final turmaId = (alunoSnap.data() ?? const {})['turmaId'] as String?;
      if (turmaId == null || turmaId.isEmpty) {
        setState(() => _booting = false);
        return;
      }
      _turmaId = turmaId;

      final turmaSnap = await FirebaseFirestore.instance.collection('turmas').doc(turmaId).get();
      _turmaNome = (turmaSnap.data() ?? const {})['nome'] as String? ?? '';

      await Future.wait([
        _loadMaterias(),
        _loadProfessores(),
        _loadAgenda(turmaId),
      ]);

      _frequenciasStream = FirebaseFirestore.instance
          .collection('frequencias')
          .where('turmaId', isEqualTo: turmaId)
          .where('alunoId', isEqualTo: alunoUid)
          .snapshots();

      setState(() => _booting = false);
    } catch (_) {
      setState(() => _booting = false);
    }
  }

  Future<void> _loadMaterias() async {
    final qs = await FirebaseFirestore.instance.collection('materias').get();
    _materias = {for (final d in qs.docs) d.id: (d.data()['nome'] ?? '-') as String};
  }

  Future<void> _loadProfessores() async {
    final qs = await FirebaseFirestore.instance.collection('professores').get();
    _professores = {for (final d in qs.docs) d.id: (d.data()['nome'] ?? '-') as String};
  }

  Future<void> _loadAgenda(String turmaId) async {
    final qs = await FirebaseFirestore.instance
        .collection('agenda')
        .where('turmaId', isEqualTo: turmaId)
        .get();

    _agendaPorDia.clear();
    for (final doc in qs.docs) {
      final data = doc.data();
      final item = AgendaItem(
        diaSemana: (data['diaSemana'] as String?) ?? '',
        horario: (data['horario'] as String?) ?? '',
        materiaId: (data['materiaId'] as String?) ?? '',
        professorId: (data['professorId'] as String?),
      );
      if (item.diaSemana.isEmpty) continue;
      (_agendaPorDia[item.diaSemana] ??= []).add(item);
    }

    for (final k in _agendaPorDia.keys) {
      _agendaPorDia[k]!.sort((a, b) {
        final ha = _parseInicio(a.horario);
        final hb = _parseInicio(b.horario);
        return ha.compareTo(hb);
      });
    }
  }

  static final List<String> _diasSemana = const [
    'Segunda-feira',
    'Terça-feira',
    'Quarta-feira',
    'Quinta-feira',
    'Sexta-feira',
    'Sábado',
    'Domingo',
  ];

  String _weekdayPtBr(DateTime d) {
    const map = {
      1: 'Segunda-feira',
      2: 'Terça-feira',
      3: 'Quarta-feira',
      4: 'Quinta-feira',
      5: 'Sexta-feira',
      6: 'Sábado',
      7: 'Domingo',
    };
    return map[d.weekday]!;
  }

  String _fmtData(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  int _parseInicio(String horario) {
    final p = horario.split('-').first.trim();
    final hhmm = p.split(':');
    final h = int.tryParse(hhmm[0]) ?? 0;
    final m = int.tryParse(hhmm[1]) ?? 0;
    return h * 60 + m;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: primaryColor,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(' Frequência', style: TextStyle(color: Colors.white)),
      ),
      body: _booting
          ? const Center(child: CircularProgressIndicator())
          : (_turmaId.isEmpty
              ? const _CenteredMessage('Aluno sem turma vinculada.')
              : (_frequenciasStream == null
                  ? const _CenteredMessage('Não foi possível carregar a frequência.')
                  : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _frequenciasStream,
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return _ErrorState(
                            message: 'Erro ao carregar frequência.',
                            onRetry: () => _initWithAluno(_alunoUid),
                          );
                        }
                        if (!snap.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }

                        final presencaPorChave = <String, bool>{};
                        for (final d in snap.data!.docs) {
                          final data = d.data();
                          final dataIso = (data['data'] as String?) ?? '';
                          final materiaId = (data['materiaId'] as String?) ?? '';
                          final presenca = (data['presenca'] as bool?) ?? false;
                          if (dataIso.isNotEmpty && materiaId.isNotEmpty) {
                            presencaPorChave['$dataIso|$materiaId'] = presenca;
                          }
                        }

                        final total = presencaPorChave.length;
                        final presentes = presencaPorChave.values.where((v) => v == true).length;
                        final faltas = total - presentes;
                        final taxa = total == 0 ? 0.0 : (presentes / total);

                        final hoje = DateTime.now();
                        final inicioSemana = hoje.subtract(
                          Duration(days: (hoje.weekday + 6) % 7),
                        );

                        final dias = List<DateTime>.generate(
                          7,
                          (i) => DateTime(
                            inicioSemana.year,
                            inicioSemana.month,
                            inicioSemana.day + i,
                          ),
                        );

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 12),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Text('Resumo da Frequência',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade800,
                                  )),
                            ),
                            const SizedBox(height: 8),
                            _ResumoCards(taxa: taxa, presentes: presentes, faltas: faltas),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ListView.builder(
                                padding: const EdgeInsets.only(bottom: 24),
                                itemCount: dias.length,
                                itemBuilder: (context, i) {
                                  final d = dias[i];
                                  final nomeDia = _weekdayPtBr(d);
                                  final dataPt = _fmtData(d);
                                  final dataIso = _isoDate(d);
                                  final aulasDoDia = _agendaPorDia[nomeDia] ?? [];

                                  return _DiaSection(
                                    titulo: '$nomeDia  $dataPt',
                                    children: aulasDoDia.isEmpty
                                        ? [
                                            _LinhaSemAulas(),
                                          ]
                                        : [
                                            for (final a in aulasDoDia)
                                              _AulaTile(
                                                materia: _materias[a.materiaId] ?? '—',
                                                professor: _professores[a.professorId] ?? '—',
                                                horario: a.horario,
                                                status: () {
                                                  final chave = '$dataIso|${a.materiaId}';
                                                  if (!presencaPorChave.containsKey(chave)) {
                                                    return AulaStatus.semRegistro;
                                                  }
                                                  return presencaPorChave[chave] == true
                                                      ? AulaStatus.presente
                                                      : AulaStatus.ausente;
                                                }(),
                                              ),
                                          ],
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      },
                    ))),
    );
  }
}

class AgendaItem {
  final String diaSemana;
  final String horario;
  final String materiaId;
  final String? professorId;

  AgendaItem({
    required this.diaSemana,
    required this.horario,
    required this.materiaId,
    required this.professorId,
  });
}

class _ResumoCards extends StatelessWidget {
  final double taxa;
  final int presentes;
  final int faltas;

  const _ResumoCards({
    Key? key,
    required this.taxa,
    required this.presentes,
    required this.faltas,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final taxaPct = (taxa * 100).round();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 90),
              child: _ResumoCard(
                icon: Icons.calendar_month,
                titulo: 'Taxa de Presença',
                valor: '$taxaPct%',
                bg: Colors.blue.shade50,
                fg: Colors.blue.shade800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 90),
              child: _ResumoCard(
                icon: Icons.check_circle,
                titulo: 'Aulas Presentes',
                valor: '$presentes',
                bg: Colors.green.shade50,
                fg: Colors.green.shade700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 90),
              child: _ResumoCard(
                icon: Icons.cancel,
                titulo: 'Faltas',
                valor: '$faltas',
                bg: Colors.red.shade50,
                fg: Colors.red.shade700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResumoCard extends StatelessWidget {
  final IconData icon;
  final String titulo;
  final String valor;
  final Color bg;
  final Color fg;

  const _ResumoCard({
    Key? key,
    required this.icon,
    required this.titulo,
    required this.valor,
    required this.bg,
    required this.fg,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1.5,
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            Icon(icon, color: fg, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    titulo,
                    style: TextStyle(fontSize: 12, color: fg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      valor,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: fg,
                      ),
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

class _DiaSection extends StatelessWidget {
  final String titulo;
  final List<Widget> children;

  const _DiaSection({
    Key? key,
    required this.titulo,
    required this.children,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Colors.grey.shade200,
          child: Text(
            titulo,
            style: TextStyle(
              color: Colors.grey.shade800,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

enum AulaStatus { presente, ausente, semRegistro }

class _AulaTile extends StatelessWidget {
  final String materia;
  final String professor;
  final String horario;
  final AulaStatus status;

  const _AulaTile({
    Key? key,
    required this.materia,
    required this.professor,
    required this.horario,
    required this.status,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final config = _statusConfig(status);

    return ListTile(
      leading: Icon(config.icon, color: config.iconColor),
      title: Text(materia, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('Prof. $professor  •  $horario'),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: config.badgeBg,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          config.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: config.badgeFg,
          ),
        ),
      ),
    );
  }

  _StatusConfig _statusConfig(AulaStatus s) {
    switch (s) {
      case AulaStatus.presente:
        return _StatusConfig(
          label: 'PRESENTE',
          icon: Icons.check_circle,
          iconColor: Colors.green.shade600,
          badgeBg: Colors.green.shade50,
          badgeFg: Colors.green.shade700,
        );
      case AulaStatus.ausente:
        return _StatusConfig(
          label: 'AUSENTE',
          icon: Icons.cancel,
          iconColor: Colors.red.shade600,
          badgeBg: Colors.red.shade50,
          badgeFg: Colors.red.shade700,
        );
      case AulaStatus.semRegistro:
      default:
        return _StatusConfig(
          label: 'SEM REGISTRO',
          icon: Icons.check_box_outline_blank,
          iconColor: Colors.grey.shade500,
          badgeBg: Colors.grey.shade200,
          badgeFg: Colors.grey.shade700,
        );
    }
  }
}

class _StatusConfig {
  final String label;
  final IconData icon;
  final Color iconColor;
  final Color badgeBg;
  final Color badgeFg;

  _StatusConfig({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.badgeBg,
    required this.badgeFg,
  });
}

class _LinhaSemAulas extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(Icons.event_busy, color: Colors.grey.shade500),
      title: const Text('Sem aulas'),
      subtitle: const Text(''),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          '—',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Colors.grey.shade700,
          ),
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final String message;
  const _CenteredMessage(this.message, {Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(message, style: TextStyle(color: Colors.grey.shade700)),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({Key? key, required this.message, required this.onRetry})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: onRetry,
          style: ElevatedButton.styleFrom(backgroundColor: primaryColor),
          child: const Text('Tentar novamente', style: TextStyle(color: Colors.white)),
        ),
      ]),
    );
  }
}





















