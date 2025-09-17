// tarefas_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

const Color primaryColor = Color(0xFF021E4C);

class _TarefaLink {
  final String label;
  final String url;
  const _TarefaLink(this.label, this.url);

  factory _TarefaLink.fromMap(Map<String, dynamic> map) {
    final rawLabel = (map['label'] ?? map['descricao'] ?? '').toString().trim();
    final rawUrl = (map['url'] ?? '').toString().trim();

    String label = rawLabel;
    if (label.isEmpty && rawUrl.isNotEmpty) {
      try {
        final host = Uri.parse(rawUrl).host;
        if (host.isNotEmpty) label = host;
      } catch (_) {}
    }

    try {
      final uri = Uri.parse(rawUrl);
      if (!uri.hasScheme || uri.host.isEmpty) {
        return const _TarefaLink('', '');
      }
    } catch (_) {
      return const _TarefaLink('', '');
    }

    return _TarefaLink(label, rawUrl);
  }
}

class _Tarefa {
  final String id;
  final String titulo;
  final String descricao;
  final String materiaId;
  final String materiaNome;
  final String? professorId;
  final String? professorNome;
  final DateTime dataEntrega;
  final String? horaEntrega;
  final List<_TarefaLink> links;

  _Tarefa({
    required this.id,
    required this.titulo,
    required this.descricao,
    required this.materiaId,
    required this.materiaNome,
    required this.professorId,
    required this.professorNome,
    required this.dataEntrega,
    required this.horaEntrega,
    required this.links,
  });

  factory _Tarefa.fromDoc(
    DocumentSnapshot doc,
    String materiaNome, {
    String? professorNome,
  }) {
    final d = doc.data() as Map<String, dynamic>? ?? {};

    DateTime data;
    final rawData = d['dataEntrega'];
    if (rawData is Timestamp) {
      data = rawData.toDate();
    } else if (rawData is String) {
      final s = rawData.trim();
      data = DateTime.tryParse(s) ??
          DateTime.tryParse('${s}T00:00:00.000') ??
          DateTime.now();
    } else {
      data = DateTime.now();
    }

    final rawLinks = (d['links'] is List) ? (d['links'] as List) : const [];
    final links = rawLinks
        .whereType<Map<String, dynamic>>()
        .map(_TarefaLink.fromMap)
        .where((l) => l.url.isNotEmpty)
        .toList();

    String titulo = (d['titulo'] ?? '').toString().trim();
    if (titulo.isEmpty) {
      final desc = (d['descricao'] ?? '').toString();
      titulo = desc.split('\n').first.split('.').first.trim();
    }

    final professorId = (d['professorId'] ?? '').toString().trim();

    return _Tarefa(
      id: doc.id,
      titulo: titulo,
      descricao: (d['descricao'] ?? '').toString(),
      materiaId: (d['materiaId'] ?? '').toString(),
      materiaNome: materiaNome,
      professorId: professorId.isEmpty ? null : professorId,
      professorNome: (professorNome ?? (d['professorNome'] ?? '')).toString().trim().isEmpty
          ? null
          : (professorNome ?? (d['professorNome'] as String)),
      dataEntrega: data,
      horaEntrega: (d['horaEntrega'] ?? '').toString().trim().isEmpty
          ? null
          : (d['horaEntrega'] as String),
      links: links,
    );
  }
}

String getStatusTarefa({
  required bool concluida,
  required String? statusEntrega,
  required DateTime dataEntrega,
}) {
  final agora = DateTime.now();
  final inicioHoje = DateTime(agora.year, agora.month, agora.day);
  final dueDate = DateTime(dataEntrega.year, dataEntrega.month, dataEntrega.day);

  final s = (statusEntrega ?? '').trim().toLowerCase();
  final confirmadaPeloProfessor =
      s == 'concluida' || s == 'confirmada' || s == 'recebida';

  if (confirmadaPeloProfessor) return 'confirmada';
  if (concluida) return 'entregue';
  if (dueDate.isBefore(inicioHoje)) return 'atrasada';
  return 'pendente';
}

class TarefasScreen extends StatefulWidget {
  const TarefasScreen({Key? key}) : super(key: key);

  @override
  State<TarefasScreen> createState() => _TarefasScreenState();
}

class _TarefasScreenState extends State<TarefasScreen> {
  String _alunoUid = '';
  String _turmaNome = '';
  String _turmaId = '';
  bool _loading = false;
  String _erro = '';
  List<_Tarefa> _tarefas = [];
  List<String> _tarefasConcluidas = [];
  Map<String, String> _materias = {};
  Map<String, String> _professores = {};

  String _search = '';
  String? _materiaFiltro;
  String? _statusFiltro;

  final int cutoffDays = 30;
  bool showOldOverdues = false;
  final Set<String> _hiddenIds = {};
  final ValueNotifier<List<_Tarefa>> _tarefasFiltradas =
      ValueNotifier<List<_Tarefa>>([]);
  Timer? _debounce;

  final Map<String, String> _statusEntregas = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final alunoUid = ModalRoute.of(context)?.settings.arguments as String?;
    if (alunoUid != null && alunoUid != _alunoUid) {
      _alunoUid = alunoUid;
      _initComAluno(_alunoUid);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tarefasFiltradas.dispose();
    super.dispose();
  }

  Future<void> _loadMaterias() async {
    final snap = await FirebaseFirestore.instance.collection('materias').get();
    _materias = {
      for (var doc in snap.docs) doc.id: (doc.data()['nome'] ?? '—').toString()
    };
  }

  Future<void> _loadProfessores() async {
    _professores.clear();
    final profSnap =
        await FirebaseFirestore.instance.collection('professores').get();
    if (profSnap.docs.isNotEmpty) {
      _professores = {
        for (var doc in profSnap.docs)
          doc.id: (doc.data()['nome'] ?? doc.id).toString()
      };
      return;
    }
    final users = await FirebaseFirestore.instance
        .collection('usuarios')
        .where('tipoUsuario', isEqualTo: 'professores')
        .get();
    for (final d in users.docs) {
      _professores[d.id] = (d.data()['nome'] ?? d.id).toString();
    }
  }

  Future<void> _loadHiddenForUser() async {
    _hiddenIds.clear();
    final snap = await FirebaseFirestore.instance
        .collection('tarefas_escondidas')
        .where('alunoId', isEqualTo: _alunoUid)
        .get();
    for (final d in snap.docs) {
      final tId = (d.data()['tarefaId'] ?? '').toString();
      if (tId.isNotEmpty) _hiddenIds.add(tId);
    }
  }

  Future<void> _loadStatusEntregas() async {
    _statusEntregas.clear();
    if (_alunoUid.isEmpty) return;
    final snap = await FirebaseFirestore.instance
        .collection('entregas')
        .where('alunoId', isEqualTo: _alunoUid)
        .get();
    for (final d in snap.docs) {
      final m = d.data();
      final tId = (m['tarefaId'] ?? '').toString();
      final status = (m['status'] ?? '').toString();
      if (tId.isNotEmpty && status.isNotEmpty) {
        _statusEntregas[tId] = status;
      }
    }
  }

  Future<void> _initComAluno(String alunoUid) async {
    setState(() {
      _loading = true;
      _erro = '';
    });

    try {
      final alunoSnap = await FirebaseFirestore.instance
          .collection('alunos')
          .doc(alunoUid)
          .get();
      final turmaId = alunoSnap.data()?['turmaId'] as String? ?? '';

      if (turmaId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _turmaNome = '';
          _turmaId = '';
          _tarefas = [];
          _tarefasConcluidas = [];
          _loading = false;
        });
        _tarefasFiltradas.value = [];
        return;
      }

      final turmaSnap =
          await FirebaseFirestore.instance.collection('turmas').doc(turmaId).get();

      await _loadMaterias();
      await _loadProfessores();

      final tarefasSnap = await FirebaseFirestore.instance
          .collection('tarefas')
          .where('turmaId', isEqualTo: turmaId)
          .orderBy('dataEntrega')
          .get();

      final tarefas = tarefasSnap.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        final materiaId = (data['materiaId'] ?? '').toString();
        final materiaNome = _materias[materiaId] ?? '—';

        final professorId = (data['professorId'] ?? '').toString();
        final professorNome = _professores[professorId];

        return _Tarefa.fromDoc(
          doc,
          materiaNome,
          professorNome: professorNome,
        );
      }).toList();

      final concluidasSnap = await FirebaseFirestore.instance
          .collection('tarefas_concluidas')
          .where('alunoId', isEqualTo: alunoUid)
          .get();
      final concluidas =
          concluidasSnap.docs.map((doc) => (doc['tarefaId'] as String)).toList();

      await _loadHiddenForUser();
      await _loadStatusEntregas();

      if (!mounted) return;
      setState(() {
        _turmaNome = turmaSnap.data()?['nome'] ?? '';
        _turmaId = turmaId;
        _tarefas = tarefas;
        _tarefasConcluidas = concluidas;
        _loading = false;
      });

      _atualizarTarefasFiltradas();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = 'Erro ao carregar dados.';
        _loading = false;
      });
      _tarefasFiltradas.value = [];
    }
  }

  Future<void> _alternarConclusao(_Tarefa t, bool marcar) async {
    final statusEntrega = _statusEntregas[t.id];
    final s = (statusEntrega ?? '').toLowerCase();
    final confirmada = s == 'concluida' || s == 'confirmada' || s == 'recebida';
    if (confirmada) return;

    final ref = FirebaseFirestore.instance.collection('tarefas_concluidas');
    if (marcar) {
      await ref.add({
        'alunoId': _alunoUid,
        'tarefaId': t.id,
        'concluidaEm': FieldValue.serverTimestamp()
      });
      if (!mounted) return;
      setState(() => _tarefasConcluidas.add(t.id));
    } else {
      final snap = await ref
          .where('alunoId', isEqualTo: _alunoUid)
          .where('tarefaId', isEqualTo: t.id)
          .get();
      for (var d in snap.docs) {
        await d.reference.delete();
      }
      if (!mounted) return;
      setState(() => _tarefasConcluidas.remove(t.id));
    }
    _atualizarTarefasFiltradas();
  }

  Future<void> _toggleHide(_Tarefa t, {required bool hide}) async {
    final col = FirebaseFirestore.instance.collection('tarefas_escondidas');
    if (hide) {
      await col.add({
        'alunoId': _alunoUid,
        'tarefaId': t.id,
        'hiddenAt': FieldValue.serverTimestamp()
      });
      setState(() => _hiddenIds.add(t.id));
      _atualizarTarefasFiltradas();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Tarefa escondida'),
          action: SnackBarAction(
            label: 'Desfazer',
            onPressed: () => _toggleHide(t, hide: false),
          ),
        ),
      );
    } else {
      final snap = await col
          .where('alunoId', isEqualTo: _alunoUid)
          .where('tarefaId', isEqualTo: t.id)
          .get();
      for (final d in snap.docs) {
        await d.reference.delete();
      }
      setState(() => _hiddenIds.remove(t.id));
      _atualizarTarefasFiltradas();
    }
  }

  bool _isOlderThanCutoff(DateTime due) {
    final cutoff = DateTime.now().subtract(Duration(days: cutoffDays));
    final cutoffDate = DateTime(cutoff.year, cutoff.month, cutoff.day);
    final d = DateTime(due.year, due.month, due.day);
    return d.isBefore(cutoffDate);
  }

  int _oldOverdueCount() {
    return _tarefas.where((t) {
      final status = getStatusTarefa(
        concluida: _tarefasConcluidas.contains(t.id),
        statusEntrega: _statusEntregas[t.id],
        dataEntrega: t.dataEntrega,
      );
      return status == 'atrasada' && _isOlderThanCutoff(t.dataEntrega);
    }).length;
  }

  int _statusRank({
    required String status,
    required DateTime dataEntrega,
  }) {
    final hoje = DateTime.now();
    final isHoje = dataEntrega.year == hoje.year &&
        dataEntrega.month == hoje.month &&
        dataEntrega.day == hoje.day;

    switch (status) {
      case 'pendente':
        return isHoje ? -1 : 5;
      case 'atrasada':
        return 0;
      case 'entregue':
        return 2;
      case 'confirmada':
        return 3;
      default:
        return 6;
    }
  }

  List<_Tarefa> _filtrarTarefas() {
    var list = List<_Tarefa>.from(_tarefas.reversed);

    list = list.where((t) => !_hiddenIds.contains(t.id)).toList();

    if (!showOldOverdues) {
      list = list.where((t) {
        final status = getStatusTarefa(
          concluida: _tarefasConcluidas.contains(t.id),
          statusEntrega: _statusEntregas[t.id],
          dataEntrega: t.dataEntrega,
        );
        final isOldOverdue =
            status == 'atrasada' && _isOlderThanCutoff(t.dataEntrega);
        return !isOldOverdue;
      }).toList();
    }

    if (_search.trim().isNotEmpty) {
      final s = _search.trim().toLowerCase();
      list = list
          .where((t) =>
              t.titulo.toLowerCase().contains(s) ||
              t.descricao.toLowerCase().contains(s) ||
              t.materiaNome.toLowerCase().contains(s))
          .toList();
    }

    if (_materiaFiltro?.isNotEmpty == true) {
      list = list.where((t) => t.materiaId == _materiaFiltro).toList();
    }
    if (_statusFiltro?.isNotEmpty == true) {
      list = list.where((t) {
        final status = getStatusTarefa(
          concluida: _tarefasConcluidas.contains(t.id),
          statusEntrega: _statusEntregas[t.id],
          dataEntrega: t.dataEntrega,
        );
        return status == _statusFiltro;
      }).toList();
    }

    list.sort((a, b) {
      final aStatus = getStatusTarefa(
        concluida: _tarefasConcluidas.contains(a.id),
        statusEntrega: _statusEntregas[a.id],
        dataEntrega: a.dataEntrega,
      );
      final bStatus = getStatusTarefa(
        concluida: _tarefasConcluidas.contains(b.id),
        statusEntrega: _statusEntregas[b.id],
        dataEntrega: b.dataEntrega,
      );

      if (aStatus == 'pendente' && bStatus != 'pendente') return -1;
      if (aStatus != 'pendente' && bStatus == 'pendente') return 1;

      final ra = _statusRank(status: aStatus, dataEntrega: a.dataEntrega);
      final rb = _statusRank(status: bStatus, dataEntrega: b.dataEntrega);

      if (ra != rb) return ra.compareTo(rb);
      return a.dataEntrega.compareTo(b.dataEntrega);
    });

    return list;
  }

  void _atualizarTarefasFiltradas() {
    _tarefasFiltradas.value = _filtrarTarefas();
  }

  void _onFiltroMudou() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _atualizarTarefasFiltradas);
  }

  int _filtrosAtivosCount() {
    int n = 0;
    if (_search.trim().isNotEmpty) n++;
    if (_materiaFiltro?.isNotEmpty == true) n++;
    if (_statusFiltro?.isNotEmpty == true) n++;
    return n;
  }

  Future<void> _abrirFiltrosBottomSheet(
      List<MapEntry<String, String>> materiasDropdown) async {
    String search = _search;
    String? materia = _materiaFiltro ?? '';
    String? status = _statusFiltro ?? '';

    final searchController = TextEditingController(text: _search);

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
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: searchController,
                    decoration: const InputDecoration(labelText: 'Buscar'),
                    onChanged: (v) => search = v,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: materia!.isEmpty ? null : materia,
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('Todas as matérias')),
                      ...materiasDropdown.map((e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value))),
                    ],
                    onChanged: (v) => materia = v ?? '',
                    decoration: const InputDecoration(labelText: 'Matéria'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: status!.isEmpty ? null : status,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: '', child: Text('Todos os status')),
                      DropdownMenuItem(value: 'confirmada', child: Text('Entregue e confirmada')),
                      DropdownMenuItem(
                          value: 'entregue',
                          child: Text('Entregue, aguardando confirmação')),
                      DropdownMenuItem(value: 'atrasada', child: Text('Atrasada')),
                      DropdownMenuItem(value: 'pendente', child: Text('Pendente')),
                    ],
                    onChanged: (v) => status = v ?? '',
                    decoration: const InputDecoration(labelText: 'Status'),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _search = search;
                            _materiaFiltro = (materia?.isEmpty ?? true) ? null : materia;
                            _statusFiltro = (status?.isEmpty ?? true) ? null : status;
                          });
                          _onFiltroMudou();
                          Navigator.pop(context);
                        },
                        child: const Text('Aplicar'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _search = '';
                            _materiaFiltro = null;
                            _statusFiltro = null;
                          });
                          _onFiltroMudou();
                          Navigator.pop(context);
                        },
                        child: const Text('Limpar'),
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
    final materiasDropdown = {
      for (final t in _tarefas)
        if (t.materiaId.isNotEmpty) t.materiaId: t.materiaNome
    }.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));

    if (_materiaFiltro != null &&
        !materiasDropdown.any((e) => e.key == _materiaFiltro)) {
      _materiaFiltro = null;
    }

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: const Text('Tarefas', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Filtros',
            icon: const Icon(Icons.tune, color: Colors.white),
            onPressed: () => _abrirFiltrosBottomSheet(materiasDropdown),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _erro.isNotEmpty
              ? Center(child: Text(_erro))
              : _turmaId.isEmpty
                  ? const Center(child: Text('Nenhuma turma vinculada.'))
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '📝 Tarefas',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: primaryColor,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Gerencie suas atividades escolares',
                            style: TextStyle(fontSize: 16),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  decoration: const InputDecoration(
                                    labelText: 'Buscar tarefa',
                                    prefixIcon: Icon(Icons.search),
                                    border: OutlineInputBorder(),
                                  ),
                                  onChanged: (v) {
                                    setState(() => _search = v);
                                    _onFiltroMudou();
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                icon: const Icon(Icons.filter_alt),
                                onPressed: () =>
                                    _abrirFiltrosBottomSheet(materiasDropdown),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_filtrosAtivosCount() > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE0E7FF),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${_filtrosAtivosCount()} filtro(s) ativo(s)',
                                style: const TextStyle(
                                    color: primaryColor,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          const SizedBox(height: 8),
                          if (_oldOverdueCount() > 0)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF7ED),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: const Color(0xFFFCD34D)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.info_outline),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${_oldOverdueCount()} atividade(s) atrasada(s) há mais de $cutoffDays dias foram ocultadas.',
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        setState(() =>
                                            showOldOverdues = !showOldOverdues);
                                        _atualizarTarefasFiltradas();
                                      },
                                      child: Text(
                                          showOldOverdues ? 'Ocultar' : 'Mostrar'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          Expanded(
                            child: ValueListenableBuilder<List<_Tarefa>>(
                              valueListenable: _tarefasFiltradas,
                              builder: (context, tarefas, _) {
                                if (tarefas.isEmpty) {
                                  // --- ESTADO VAZIO CENTRALIZADO ---
                                  return Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text(
                                          'Nenhuma tarefa encontrada.',
                                          style: TextStyle(fontSize: 16),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 8),
                                        if (_filtrosAtivosCount() > 0)
                                          TextButton(
                                            onPressed: () {
                                              setState(() {
                                                _search = '';
                                                _materiaFiltro = null;
                                                _statusFiltro = null;
                                              });
                                              _onFiltroMudou();
                                            },
                                            child: const Text(
                                              'Limpar filtros',
                                              style: TextStyle(
                                                fontSize: 15,
                                                color: primaryColor,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                }
                                return ListView.builder(
                                  itemCount: tarefas.length,
                                  itemBuilder: (context, idx) {
                                    final t = tarefas[idx];
                                    final concluida =
                                        _tarefasConcluidas.contains(t.id);
                                    final statusEntrega = _statusEntregas[t.id];
                                    final status = getStatusTarefa(
                                      concluida: concluida,
                                      statusEntrega: statusEntrega,
                                      dataEntrega: t.dataEntrega,
                                    );

                                    return Dismissible(
                                      key: Key('tarefa-${t.id}'),
                                      background: Container(
                                        alignment: Alignment.centerLeft,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 20),
                                        color: const Color(0xFFD1FAE5),
                                        child: const Row(
                                          children: [
                                            Icon(Icons.check,
                                                color: Color(0xFF065F46)),
                                            SizedBox(width: 8),
                                            Text('Concluir',
                                                style: TextStyle(
                                                    color: Color(0xFF065F46),
                                                    fontWeight:
                                                        FontWeight.w700)),
                                          ],
                                        ),
                                      ),
                                      secondaryBackground: Container(
                                        alignment: Alignment.centerRight,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 20),
                                        color: const Color(0xFFFEE2E2),
                                        child: const Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            Text('Esconder',
                                                style: TextStyle(
                                                    color: Color(0xFF991B1B),
                                                    fontWeight:
                                                        FontWeight.w700)),
                                            SizedBox(width: 8),
                                            Icon(Icons.visibility_off,
                                                color: Color(0xFF991B1B)),
                                          ],
                                        ),
                                      ),
                                      confirmDismiss: (direction) async {
                                        if (direction ==
                                            DismissDirection.startToEnd) {
                                          await _alternarConclusao(
                                              t, !concluida);
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(concluida
                                                  ? 'Tarefa marcada como pendente'
                                                  : 'Tarefa marcada como concluída'),
                                              action: SnackBarAction(
                                                label: 'Desfazer',
                                                onPressed: () =>
                                                    _alternarConclusao(
                                                        t, concluida),
                                              ),
                                            ),
                                          );
                                          return false;
                                        } else {
                                          await _toggleHide(t, hide: true);
                                          return false;
                                        }
                                      },
                                      child: TarefaCard(
                                        tarefa: t,
                                        concluida: concluida,
                                        status: status,
                                        statusEntrega: statusEntrega,
                                        onAlternarConclusao: (marcar) =>
                                            _alternarConclusao(t, marcar),
                                        onHide: () =>
                                            _toggleHide(t, hide: true),
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

class TarefaCard extends StatelessWidget {
  final _Tarefa tarefa;
  final bool concluida;
  final String status;
  final String? statusEntrega;
  final void Function(bool marcar) onAlternarConclusao;
  final VoidCallback onHide;

  const TarefaCard({
    required this.tarefa,
    required this.concluida,
    required this.status,
    required this.statusEntrega,
    required this.onAlternarConclusao,
    required this.onHide,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final isHoje = tarefa.dataEntrega.day == DateTime.now().day &&
        tarefa.dataEntrega.month == DateTime.now().month &&
        tarefa.dataEntrega.year == DateTime.now().year;

    final checkboxEnabled = status != 'confirmada';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: const Border(
          left: BorderSide(color: primaryColor, width: 4),
        ),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14000000),
              blurRadius: 8,
              offset: Offset(0, 2)),
        ],
      ),
      child: IntrinsicHeight(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            tarefa.titulo,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: primaryColor),
                          ),
                        ),
                        const SizedBox(width: 6),
                        PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'hide') onHide();
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                                value: 'hide', child: Text('Esconder')),
                          ],
                          icon: const Icon(Icons.more_vert, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tarefa.descricao,
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 14,
                      runSpacing: 8,
                      children: [
                        _meta(Icons.menu_book, tarefa.materiaNome),
                        if (tarefa.professorNome?.isNotEmpty == true)
                          _meta(Icons.person, tarefa.professorNome!),
                        _meta(
                          Icons.calendar_today,
                          '${tarefa.dataEntrega.day.toString().padLeft(2, '0')}/${tarefa.dataEntrega.month.toString().padLeft(2, '0')}/${tarefa.dataEntrega.year}',
                          style: TextStyle(
                            color: isHoje ? const Color(0xFF9A3412) : null,
                            fontWeight: isHoje
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        if (tarefa.horaEntrega?.isNotEmpty == true)
                          _meta(Icons.schedule, tarefa.horaEntrega!),
                      ],
                    ),
                    if (tarefa.links.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Links úteis${tarefa.links.length > 1 ? ' (${tarefa.links.length})' : ''}',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: tarefa.links.map((l) {
                          return InkWell(
                            onTap: () async {
                              final uri = Uri.parse(l.url);
                              final ok = await launchUrl(uri,
                                  mode: LaunchMode.externalApplication);
                              if (!ok) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Não foi possível abrir o link')),
                                );
                              }
                            },
                            borderRadius: BorderRadius.circular(999),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                    color: const Color(0xFFBFDBFE)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.link,
                                      size: 16, color: primaryColor),
                                  const SizedBox(width: 4),
                                  Text(l.label,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: primaryColor)),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                    if (status == 'confirmada') ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD1FAE5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                            '✅ Entregue e confirmada pelo professor',
                            style: TextStyle(
                                color: Color(0xFF065F46),
                                fontWeight: FontWeight.w700)),
                      ),
                    ] else if (status == 'entregue') ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('⏳ Entregue, aguardando confirmação',
                            style: TextStyle(
                                color: Color(0xFF92400E),
                                fontWeight: FontWeight.w700)),
                      ),
                    ] else if (status == 'atrasada') ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('❌ Atrasada!',
                            style: TextStyle(
                                color: Color(0xFF991B1B),
                                fontWeight: FontWeight.w700)),
                      ),
                    ] else if (status == 'pendente' && isHoje) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEDD5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('⚠️ Vence hoje!',
                            style: TextStyle(
                                color: Color(0xFF9A3412),
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: concluida || status == 'confirmada',
                            onChanged: (checkboxEnabled)
                                ? (v) => onAlternarConclusao(v ?? false)
                                : null,
                          ),
                          Text(checkboxEnabled
                              ? 'Concluída'
                              : 'Confirmada pelo professor'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text, {TextStyle? style}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Colors.black54),
        const SizedBox(width: 4),
        Text(text, style: style ?? const TextStyle(fontSize: 13)),
      ],
    );
  }
}































