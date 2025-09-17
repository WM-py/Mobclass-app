import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

const Color primaryColor = Color(0xFF021E4C);

class MinhasNotasScreen extends StatefulWidget {
  const MinhasNotasScreen({Key? key}) : super(key: key);

  @override
  State<MinhasNotasScreen> createState() => _MinhasNotasScreenState();
}

class _MinhasNotasScreenState extends State<MinhasNotasScreen> {
  String _alunoUid = '';
  String _turmaId = '';
  bool _booting = true;

  String _bimestreSelecionado = '1º';
  final List<String> _bimestres = const ['1º', '2º', '3º', '4º'];

  // null (todas) | 'aprovadas' | 'recuperacao'
  String? _statusFiltro;

  // Regra: Recuperação substitui a média apenas se for MAIOR
  final bool _aplicaRecuperacao = true;

  // Caches
  Map<String, String> _materias = {};            // materiaId -> nome
  Map<String, String> _professores = {};         // professorId -> nome
  Map<String, String> _professorPorMateria = {}; // materiaId -> professorId (via professores_materias)

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final arg = ModalRoute.of(context)?.settings.arguments;
    if (arg is String && arg.isNotEmpty) {
      _alunoUid = arg;
    } else {
      _alunoUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    }
    _init();
  }

  Future<void> _init() async {
    try {
      await _carregarTurmaDoAluno();
      await Future.wait([
        _carregarMaterias(),
        _carregarProfessores(),
      ]);
      if (_turmaId.isNotEmpty) {
        await _carregarVinculosProfessoresMaterias();
      }
    } finally {
      if (mounted) setState(() => _booting = false);
    }
  }

  Future<void> _carregarTurmaDoAluno() async {
    if (_alunoUid.isEmpty) return;
    final doc = await FirebaseFirestore.instance.collection('alunos').doc(_alunoUid).get();
    _turmaId = (doc.data() ?? const {})['turmaId'] as String? ?? '';
  }

  Future<void> _carregarMaterias() async {
    final snap = await FirebaseFirestore.instance.collection('materias').get();
    _materias = {for (final d in snap.docs) d.id: (d.data()['nome'] ?? '—') as String};
  }

  Future<void> _carregarProfessores() async {
    final snap = await FirebaseFirestore.instance.collection('professores').get();
    _professores = {for (final d in snap.docs) d.id: (d.data()['nome'] ?? '—') as String};
  }

  Future<void> _carregarVinculosProfessoresMaterias() async {
    final qs = await FirebaseFirestore.instance
        .collection('professores_materias')
        .where('turmaId', isEqualTo: _turmaId)
        .get();

    _professorPorMateria = {};
    for (final d in qs.docs) {
      final data = d.data();
      final materiaId = data['materiaId'] as String? ?? '';
      final professorId = data['professorId'] as String? ?? '';
      if (materiaId.isNotEmpty && professorId.isNotEmpty) {
        _professorPorMateria.putIfAbsent(materiaId, () => professorId);
      }
    }
  }

  // ===== STREAM =====
  Stream<QuerySnapshot<Map<String, dynamic>>> _avaliacoesStream() {
    if (_alunoUid.isEmpty) return const Stream.empty();
    final q = FirebaseFirestore.instance
        .collection('notas')
        .where('alunoUid', isEqualTo: _alunoUid)
        .where('bimestre', isEqualTo: _bimestreSelecionado)
        .orderBy('materiaId') // <- se não quiser criar índice, REMOVA esta linha
        .orderBy('dataLancamento', descending: true);
    return q.snapshots();
  }

  // ===== AGRUPAMENTO/CÁLCULO =====
  List<GrupoDisciplina> _agruparPorDisciplina(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final avaliacoes = <String, List<Avaliacao>>{}; // materiaId -> lista

    for (final d in docs) {
      final data = d.data();
      final materiaId = (data['materiaId'] as String?) ?? '';
      if (materiaId.isEmpty) continue;

      final ts = (data['dataLancamento'] as Timestamp?) ?? Timestamp.now();
      final professorId = data['professorId'] as String?;

      // MODELO ATUAL DO SEU BANCO: notaParcial / notaGlobal / notaParticipacao / notaRecuperacao
      final parcial = (data['notaParcial'] as num?)?.toDouble();
      final global  = (data['notaGlobal']  as num?)?.toDouble();
      final part    = (data['notaParticipacao'] as num?)?.toDouble();
      final recup   = (data['notaRecuperacao']  as num?)?.toDouble();

      avaliacoes.putIfAbsent(materiaId, () => []);

      if (parcial != null) {
        avaliacoes[materiaId]!.add(Avaliacao(
          tipo: 'Parcial', peso: 1, nota: parcial.clamp(0, 10),
          data: ts, professorId: professorId,
        ));
      }
      if (global != null) {
        avaliacoes[materiaId]!.add(Avaliacao(
          tipo: 'Global', peso: 1, nota: global.clamp(0, 10),
          data: ts, professorId: professorId,
        ));
      }
      if (part != null) {
        avaliacoes[materiaId]!.add(Avaliacao(
          tipo: 'Participação', peso: 1, nota: part.clamp(0, 10),
          data: ts, professorId: professorId,
        ));
      }
      if (recup != null) {
        avaliacoes[materiaId]!.add(Avaliacao(
          tipo: 'Recuperação', peso: 1, nota: recup.clamp(0, 10),
          data: ts, professorId: professorId,
        ));
      }
    }

    final grupos = <GrupoDisciplina>[];
    for (final entry in avaliacoes.entries) {
      final materiaId = entry.key;
      final lista = entry.value;

      // manter a avaliação MAIS RECENTE por tipo
      final porTipo = <String, Avaliacao>{};
      Timestamp? ultima;
      String? profPreferencial;

      for (final av in lista) {
        final atual = porTipo[av.tipo];
        if (atual == null || av.data.compareTo(atual.data) > 0) {
          porTipo[av.tipo] = av;
        }
        if (ultima == null || av.data.compareTo(ultima!) > 0) {
          ultima = av.data;
          profPreferencial = av.professorId;
        }
      }

      // === REGRAS DE CÁLCULO ===
      // (Parcial + Global)/2 + Participação (participação como bônus)
      final parcial = porTipo['Parcial']?.nota;
      final global  = porTipo['Global']?.nota;
      final part    = porTipo['Participação']?.nota ?? 0.0;

      final baseCompleta = (parcial != null && global != null);

      double mediaBase;
      if (baseCompleta) {
        mediaBase = ((parcial! + global!) / 2.0) + part;
      } else if (parcial != null) {
        mediaBase = parcial + part;
      } else if (global != null) {
        mediaBase = global + part;
      } else {
        mediaBase = part; // só participação lançada
      }

      // Recuperação substitui se for MAIOR
      double mediaFinal = mediaBase;
      final rec = porTipo['Recuperação'];
      if (_aplicaRecuperacao && rec != null) {
        mediaFinal = rec.nota > mediaFinal ? rec.nota : mediaFinal;
      }

      // Status só é avaliado quando baseCompleta = true
      final professorFinal = _professorPorMateria[materiaId] ?? profPreferencial;
      final aprovado = baseCompleta && mediaFinal >= 6.0;

      grupos.add(GrupoDisciplina(
        materiaId: materiaId,
        porTipoMaisRecente: porTipo,
        mediaFinal: mediaFinal,
        ultimaData: ultima ?? Timestamp.now(),
        professorIdPreferencial: professorFinal,
        baseCompleta: baseCompleta,
        aprovado: aprovado,
      ));
    }

    // Filtro client-side (ignora "Em avaliação")
    List<GrupoDisciplina> itens = grupos;
    if (_statusFiltro == 'aprovadas') {
      itens = itens.where((g) => g.baseCompleta && g.aprovado).toList();
    } else if (_statusFiltro == 'recuperacao') {
      itens = itens.where((g) => g.baseCompleta && !g.aprovado).toList();
    }

    // Ordenar por nome de matéria
    itens.sort((a, b) {
      final an = (_materias[a.materiaId] ?? '').toLowerCase();
      final bn = (_materias[b.materiaId] ?? '').toLowerCase();
      return an.compareTo(bn);
    });

    return itens;
  }

  String _professorNomeParaMateria(String materiaId, {String? fallbackProfessorId}) {
    final profIdVinculo = _professorPorMateria[materiaId];
    if (profIdVinculo != null && profIdVinculo.isNotEmpty) {
      return _professores[profIdVinculo] ?? '—';
    }
    if (fallbackProfessorId != null && fallbackProfessorId.isNotEmpty) {
      return _professores[fallbackProfessorId] ?? '—';
    }
    return '—';
  }

  // ===== UI Helpers =====
  int _filtrosAtivosCount() {
    int n = 0;
    if (_bimestreSelecionado != '1º') n++;
    if (_statusFiltro != null) n++;
    return n;
  }

  Future<void> _abrirBottomSheetFiltros() async {
    String bimestre = _bimestreSelecionado;
    String? status = _statusFiltro;

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
                      )
                    ],
                  ),
                  const SizedBox(height: 8),

                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Bimestre',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    value: bimestre,
                    items: _bimestres.map((b) => DropdownMenuItem(value: b, child: Text(b))).toList(),
                    onChanged: (v) => bimestre = v ?? bimestre,
                  ),
                  const SizedBox(height: 12),

                  const Text('Status', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _chipFiltro('Todas', status == null, onTap: () => status = null),
                      _chipFiltro('Aprovadas', status == 'aprovadas', onTap: () => status = 'aprovadas'),
                      _chipFiltro('Recuperação', status == 'recuperacao', onTap: () => status = 'recuperacao'),
                    ],
                  ),

                  const SizedBox(height: 16),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _bimestreSelecionado = '1º';
                            _statusFiltro = null;
                          });
                          Navigator.pop(context);
                        },
                        child: const Text('Limpar'),
                      ),
                      const Spacer(),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: primaryColor),
                        onPressed: () {
                          setState(() {
                            _bimestreSelecionado = bimestre;
                            _statusFiltro = status;
                          });
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

  Widget _chipFiltro(String label, bool selected, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? primaryColor.withOpacity(0.1) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? primaryColor : Colors.grey.shade300),
        ),
        child: Text(label, style: TextStyle(color: selected ? primaryColor : Colors.black87)),
      ),
    );
  }

  // ===== BUILD =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: const Text('Minhas Notas', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Filtros',
            icon: const Icon(Icons.tune, color: Colors.white),
            onPressed: _abrirBottomSheetFiltros,
          ),
        ],
      ),
      body: _booting
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          // Barra compacta com filtros + indicador
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _abrirBottomSheetFiltros,
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
                  child: Text(
                    'Bimestre: $_bimestreSelecionado'
                        '${_statusFiltro == null ? '' : _statusFiltro == 'aprovadas' ? ' • Aprovadas' : ' • Recuperação'}',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _avaliacoesStream(),
              builder: (context, snap) {
                if (snap.hasError) {
                  // ignore: avoid_print
                  print('Notas stream error: ${snap.error}');
                  return _ErrorState(message: 'Erro ao carregar notas.', onRetry: _init);
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final grupos = _agruparPorDisciplina(snap.data!.docs);
                final resumo = _calcularResumo(grupos);

                return ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      child: Text(
                        'Resumo do ${_bimestreSelecionado} Bimestre',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade800,
                        ),
                      ),
                    ),
                    _ResumoBimestre(
                      mediaGeral: resumo.mediaGeral,
                      aprovadas: resumo.aprovadas,
                      recuperacao: resumo.recuperacao,
                      onTapAprovadas: () => setState(() {
                        _statusFiltro = _statusFiltro == 'aprovadas' ? null : 'aprovadas';
                      }),
                      onTapRecuperacao: () => setState(() {
                        _statusFiltro = _statusFiltro == 'recuperacao' ? null : 'recuperacao';
                      }),
                    ),
                    const SizedBox(height: 10),

                    for (final g in grupos)
                      _DisciplinaTile(
                        titulo: _materias[g.materiaId] ?? '—',
                        professor: _professorNomeParaMateria(
                          g.materiaId,
                          fallbackProfessorId: g.professorIdPreferencial,
                        ),
                        grupo: g,
                      ),

                    if (resumo.recuperacao > 0) ...[
                      const SizedBox(height: 12),
                      _AlertaRecuperacao(qtd: resumo.recuperacao, bimestre: _bimestreSelecionado),
                    ],

                    if (grupos.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: Center(
                          child: Text('Nenhuma nota encontrada.', style: TextStyle(color: Colors.grey.shade700)),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  ResumoNotas _calcularResumo(List<GrupoDisciplina> grupos) {
    final completas = grupos.where((g) => g.baseCompleta).toList();
    if (completas.isEmpty) return const ResumoNotas(mediaGeral: 0, aprovadas: 0, recuperacao: 0);

    final medias = completas.map((g) => g.mediaFinal).toList();
    final mediaGeral = medias.reduce((a, b) => a + b) / medias.length;
    final aprovadas = completas.where((g) => g.aprovado).length;
    final recuperacao = completas.length - aprovadas;

    return ResumoNotas(mediaGeral: mediaGeral, aprovadas: aprovadas, recuperacao: recuperacao);
  }
}

// ===== MODELOS =====
class Avaliacao {
  final String tipo;         // "Parcial", "Global", "Participação", "Recuperação"
  final double nota;         // 0..10
  final double peso;         // >= 0 (default 1) - apenas exibição neste modelo
  final Timestamp data;      // data de lançamento
  final String? professorId; // opcional

  Avaliacao({
    required this.tipo,
    required this.nota,
    required this.peso,
    required this.data,
    this.professorId,
  });
}

class GrupoDisciplina {
  final String materiaId;
  final Map<String, Avaliacao> porTipoMaisRecente; // tipo -> avaliação (só a mais recente)
  final double mediaFinal; // ((Parcial+Global)/2)+Participação, c/ recuperação se maior
  final Timestamp ultimaData;
  final String? professorIdPreferencial;

  /// true quando existe Parcial **e** Global
  final bool baseCompleta;

  /// válido somente quando [baseCompleta] = true
  final bool aprovado;

  GrupoDisciplina({
    required this.materiaId,
    required this.porTipoMaisRecente,
    required this.mediaFinal,
    required this.ultimaData,
    required this.professorIdPreferencial,
    required this.baseCompleta,
    required this.aprovado,
  });
}

class ResumoNotas {
  final double mediaGeral;
  final int aprovadas;
  final int recuperacao;

  const ResumoNotas({
    required this.mediaGeral,
    required this.aprovadas,
    required this.recuperacao,
  });
}

// ===== WIDGETS =====
class _ResumoBimestre extends StatelessWidget {
  final double mediaGeral;
  final int aprovadas;
  final int recuperacao;
  final VoidCallback? onTapAprovadas;
  final VoidCallback? onTapRecuperacao;

  const _ResumoBimestre({
    Key? key,
    required this.mediaGeral,
    required this.aprovadas,
    required this.recuperacao,
    this.onTapAprovadas,
    this.onTapRecuperacao,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final mediaStr = mediaGeral.toStringAsFixed(1);

    return Row(
      children: [
        Expanded(
          child: _ResumoCard(
            icon: Icons.emoji_events,
            titulo: 'Média Geral',
            valor: mediaStr,
            bg: Colors.blue.shade50,
            fg: Colors.blue.shade900,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ResumoCard(
            icon: Icons.check_box,
            titulo: 'Disciplinas Aprovadas',
            valor: '$aprovadas',
            bg: Colors.green.shade50,
            fg: Colors.green.shade700,
            onTap: onTapAprovadas,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ResumoCard(
            icon: Icons.warning_amber_rounded,
            titulo: 'Em Recuperação',
            valor: '$recuperacao',
            bg: Colors.red.shade50,
            fg: Colors.red.shade700,
            onTap: onTapRecuperacao,
          ),
        ),
      ],
    );
  }
}

class _ResumoCard extends StatelessWidget {
  final IconData icon;
  final String titulo;
  final String valor;
  final Color bg;
  final Color fg;
  final VoidCallback? onTap;

  static const double _height = 96;

  const _ResumoCard({
    Key? key,
    required this.icon,
    required this.titulo,
    required this.valor,
    required this.bg,
    required this.fg,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final content = Card(
      elevation: 1.5,
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        height: _height,
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titulo, style: TextStyle(fontSize: 12, color: fg), maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Text(
                      valor,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: fg),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return onTap == null
        ? content
        : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12), child: content);
  }
}

class _DisciplinaTile extends StatelessWidget {
  final String titulo;
  final String professor;
  final GrupoDisciplina grupo;

  const _DisciplinaTile({
    Key? key,
    required this.titulo,
    required this.professor,
    required this.grupo,
  }) : super(key: key);

  String _fmt(Timestamp ts) {
    final d = ts.toDate();
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString();
    return '$dd/$mm/$yyyy';
  }

  List<String> _ordemTipos(Map<String, Avaliacao> m) {
    const ordemBase = ['Parcial', 'Global', 'Trabalho', 'Participação', 'Recuperação'];
    final existentes = m.keys.toList();
    existentes.sort((a, b) {
      final ia = ordemBase.indexOf(a);
      final ib = ordemBase.indexOf(b);
      if (ia == -1 && ib == -1) return a.compareTo(b);
      if (ia == -1) return 1;
      if (ib == -1) return -1;
      return ia.compareTo(ib);
    });
    return existentes;
  }

  @override
  Widget build(BuildContext context) {
    final mediaStr = grupo.baseCompleta ? grupo.mediaFinal.toStringAsFixed(1) : '—';
    final statusLabel = !grupo.baseCompleta
        ? 'Em avaliação'
        : (grupo.aprovado ? 'Aprovado' : 'Recuperação');

    final Color chipBg = !grupo.baseCompleta
        ? Colors.grey.shade200
        : (grupo.aprovado ? Colors.green.shade50 : Colors.red.shade50);

    final Color chipFg = !grupo.baseCompleta
        ? Colors.grey.shade700
        : (grupo.aprovado ? Colors.green.shade700 : Colors.red.shade700);

    return Card(
      elevation: 1.5,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          leading: const Icon(Icons.menu_book, color: primaryColor),
          title: Text(
            titulo,
            style: const TextStyle(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Prof. $professor',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                'Atualizado em ${_fmt(grupo.ultimaData)}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          // Limita o espaço do trailing para não empurrar o título para fora
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    mediaStr,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: chipBg,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: chipFg,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          children: [
            const SizedBox(height: 6),
            for (final tipo in _ordemTipos(grupo.porTipoMaisRecente))
              _LinhaAvaliacao(av: grupo.porTipoMaisRecente[tipo]!),
            const SizedBox(height: 8),
            Divider(color: Colors.grey.shade200, height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.calculate, size: 18, color: primaryColor),
                const SizedBox(width: 6),
                // ⬇️ Impede overflow e permite quebra
                Expanded(
                  child: Text(
                    grupo.baseCompleta
                        ? 'Média: $mediaStr • ${statusLabel}'
                        : 'Média parcial: Aguardando notas',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    softWrap: true,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }


}

// ===== Widget separado =====
class _LinhaAvaliacao extends StatelessWidget {
  final Avaliacao av;
  const _LinhaAvaliacao({Key? key, required this.av}) : super(key: key);

  String _fmt(Timestamp ts) {
    final d = ts.toDate();
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString();
    return '$dd/$mm/$yyyy';
  }

  @override
  Widget build(BuildContext context) {
    final isRec = av.tipo.toLowerCase().contains('recupera');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            height: 36,
            width: 36,
            decoration: BoxDecoration(
              color: isRec ? Colors.red.shade50 : primaryColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(isRec ? Icons.restart_alt : Icons.assignment, color: isRec ? Colors.red.shade700 : primaryColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${av.tipo} • Peso ${av.peso.toStringAsFixed(av.peso.truncateToDouble() == av.peso ? 0 : 1)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: (av.nota / 10).clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: Colors.grey.shade200,
                  ),
                ),
                const SizedBox(height: 4),
                Text('Lançada em ${_fmt(av.data)}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(av.nota.toStringAsFixed(1), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _AlertaRecuperacao extends StatelessWidget {
  final int qtd;
  final String bimestre;

  const _AlertaRecuperacao({Key? key, required this.qtd, required this.bimestre}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFF8E1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Atenção: Você possui $qtd disciplina(s) em recuperação no $bimestre bimestre. '
                    'Foque nos estudos para melhorar seu desempenho.',
                style: TextStyle(color: Colors.orange.shade900, height: 1.25),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({Key? key, required this.message, required this.onRetry}) : super(key: key);

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

















