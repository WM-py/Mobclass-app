import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:rxdart/rxdart.dart';

import 'package:agenda_digital/features/auth/presentation/screens/login_screen.dart';
import 'package:agenda_digital/core/routes/app_routes.dart';

/// Cor primária do app (use a mesma em outras telas para manter o tema)
const Color primaryColor = Color(0xFF021E4C);

/// Tipos de notificação exibidas no painel
enum NotifTipo { comunicado, agenda, novaTarefa }

/// Modelo de item de notificação (deixei público para evitar warnings de “private type”)
class NotifItem {
  final String id;
  final NotifTipo tipo;
  final String titulo;
  final String subtitulo;
  final DateTime data;
  final bool isNovo;
  final String? rota;

  const NotifItem({
    required this.id,
    required this.tipo,
    required this.titulo,
    required this.subtitulo,
    required this.data,
    required this.isNovo,
    this.rota,
  });

  factory NotifItem.comunicado(QueryDocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    final dt = _parseDate(d['data']);
    return NotifItem(
      id: doc.id,
      tipo: NotifTipo.comunicado,
      titulo: d['titulo'] ?? 'Comunicado',
      subtitulo: d['descricao'] ?? '',
      data: dt,
      isNovo: !(d['lida'] ?? false),
      rota: AppRoutes.comunicados,
    );
  }

  factory NotifItem.tarefa(QueryDocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    final dt = _parseDate(d['criadoEm']);
    return NotifItem(
      id: doc.id,
      tipo: NotifTipo.novaTarefa,
      titulo: d['titulo'] ?? 'Nova tarefa',
      subtitulo: d['descricao'] ?? '',
      data: dt,
      isNovo: true,
      rota: AppRoutes.tarefas,
    );
  }

  factory NotifItem.agenda(QueryDocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    final dt = _parseDate(d['data']);
    return NotifItem(
      id: doc.id,
      tipo: NotifTipo.agenda,
      titulo: d['titulo'] ?? 'Evento',
      subtitulo: d['descricao'] ?? '',
      data: dt,
      isNovo: true,
      rota: AppRoutes.agendaEscolar,
    );
  }

  static DateTime _parseDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
    if (v is DateTime) return v;
    return DateTime.now();
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.nomeAluno = '', this.turma = ''});

  final String nomeAluno;
  final String turma;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Firebase
  final _auth = FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;
  final _localNotifications = FlutterLocalNotificationsPlugin();

  // Estado
  StreamSubscription? _notifSub;
  bool _loading = true;
  bool _isResponsavel = false;

  // Dados do(s) aluno(s)
  List<Map<String, String>> _filhos = [];
  Map<String, String>? _selecionado;

  String _alunoUid = '';
  String _nome = '';
  String _turma = '';
  String _frequencia = '--';
  String _turmaId = '';

  @override
  void initState() {
    super.initState();
    _setup();
    _initMessaging();
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }

  // ===================== Push/Local Notifications =====================
  Future<void> _initMessaging() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _localNotifications.initialize(
      const InitializationSettings(android: androidInit),
    );

    const channel = AndroidNotificationChannel(
      'default_channel',
      'Notificações',
      description: 'Canal padrão de notificações.',
      importance: Importance.max,
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    FirebaseMessaging.onMessage.listen((message) {
      final n = message.notification;
      final android = n?.android;
      if (n != null && android != null) {
        _localNotifications.show(
          n.hashCode,
          n.title,
          n.body,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'default_channel',
              'Notificações',
              importance: Importance.max,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
            ),
          ),
        );
      }
    });
  }

  // ===================== Carregamento de dados =====================
  Future<void> _setup() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    final respDoc = await _firestore.collection('responsaveis').doc(uid).get();
    if (!mounted) return;

    if (respDoc.exists) {
      _isResponsavel = true;
      final data = respDoc.data()!;
      final filhosIds = List<String>.from(data['filhos'] ?? <String>[]);
      final filhos = <Map<String, String>>[];

      for (final id in filhosIds) {
        final alunoDoc = await _firestore.collection('alunos').doc(id).get();
        if (!alunoDoc.exists) continue;
        final a = alunoDoc.data()!;
        filhos.add({'uid': id, 'nome': (a['nome'] ?? '—').toString()});
      }

      _filhos = filhos;
      if (_filhos.isNotEmpty) {
        _selecionado = _filhos.first;
        _alunoUid = _selecionado!['uid']!;
        await _loadData(_alunoUid);
      }
    } else {
      _isResponsavel = false;
      _alunoUid = uid;
      await _loadData(uid);
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _loadData(String uid) async {
    await _notifSub?.cancel();

    final userDoc = await _firestore.collection('users').doc(uid).get();
    final alunoDoc = await _firestore.collection('alunos').doc(uid).get();
    final user = userDoc.data() ?? <String, dynamic>{};
    final aluno = alunoDoc.data() ?? <String, dynamic>{};

    var turmaNome = '';
    final turmaId = (aluno['turmaId'] as String?) ?? '';
    if (turmaId.isNotEmpty) {
      final tdoc = await _firestore.collection('turmas').doc(turmaId).get();
      turmaNome = (tdoc.data()?['nome'] ?? '').toString();
    }

    var freqPct = 0.0;
    if (turmaId.isNotEmpty) {
      final s = await _firestore
          .collection('frequencias')
          .where('alunoId', isEqualTo: uid)
          .where('turmaId', isEqualTo: turmaId)
          .get();
      final total = s.docs.length;
      final pres = s.docs.where((d) => d.data()['presenca'] == true).length;
      if (total > 0) freqPct = pres / total * 100.0;
    }

    if (!mounted) return;
    setState(() {
      _nome = (user['nome'] ?? '').toString();
      _turma = turmaNome;
      _frequencia = freqPct > 0 ? '${freqPct.toStringAsFixed(1)}%' : '--';
      _turmaId = turmaId;
    });
  }

  // ===================== Navegação & utilitários =====================
  Future<void> _logout() async {
    await _auth.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
    );
  }

  void _abrirRota(String rota) {
    Navigator.pushNamed(context, rota, arguments: _alunoUid);
  }

  Stream<int> _streamComunicadosCount(String turmaId) {
    if (turmaId.isEmpty) return Stream<int>.value(0);
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return _firestore
        .collection('comunicados')
        .where('turmaId', isEqualTo: turmaId)
        .where('data', isGreaterThanOrEqualTo: cutoff)
        .snapshots()
        .map((s) => s.docs.length);
  }

  Stream<List<NotifItem>> _streamNotifs(String turmaId) {
    if (turmaId.isEmpty) {
      return Stream<List<NotifItem>>.value(<NotifItem>[]);
    }
    final cutoff = DateTime.now().subtract(const Duration(days: 10));

    final com = _firestore
        .collection('comunicados')
        .where('turmaId', isEqualTo: turmaId)
        .where('data', isGreaterThanOrEqualTo: cutoff)
        .snapshots()
        .map((s) => s.docs.map(NotifItem.comunicado).toList());

    final tar = _firestore
        .collection('tarefas')
        .where('turmaId', isEqualTo: turmaId)
        .where('criadoEm', isGreaterThanOrEqualTo: cutoff)
        .snapshots()
        .map((s) => s.docs.map(NotifItem.tarefa).toList());

    final ag = _firestore
        .collection('agenda')
        .where('turmaId', isEqualTo: turmaId)
        .where('data', isGreaterThanOrEqualTo: cutoff)
        .snapshots()
        .map((s) => s.docs.map(NotifItem.agenda).toList());

    return Rx.combineLatest3<List<NotifItem>, List<NotifItem>, List<NotifItem>,
        List<NotifItem>>(com, tar, ag, (a, b, c) {
      final all = <NotifItem>[...a, ...b, ...c]
        ..sort((x, y) => y.data.compareTo(x.data));
      return all;
    });
  }

  // ===================== UI blocks =====================
  Widget _filhoSelector() {
    if (!_isResponsavel || _filhos.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Selecionar aluno',
          contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            value: _selecionado?['uid'],
            items: _filhos
                .map((f) => DropdownMenuItem<String>(
              value: f['uid'],
              child: Text(
                f['nome'] ?? '—',
                overflow: TextOverflow.ellipsis,
              ),
            ))
                .toList(),
            onChanged: (v) async {
              final novo = _filhos.firstWhere((e) => e['uid'] == v);
              setState(() {
                _selecionado = novo;
                _alunoUid = novo['uid']!;
              });
              await _loadData(_alunoUid);
            },
          ),
        ),
      ),
    );
  }

  Widget _welcomeCard() {
    return Card(
      color: primaryColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 3,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 32,
              backgroundColor: Colors.white,
              child: Icon(Icons.person, color: primaryColor, size: 40),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isResponsavel ? 'Bem-vindo(a)' : 'Bem-vindo(a), $_nome',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_turma.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Turma $_turma',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                      const TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gridShortcuts(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final cross = w >= 600 ? 3 : 2;

    final List<Widget> cards = [
      _CardItem(
        label: 'Tarefas',
        icon: Icons.task,
        onTap: () => _abrirRota(AppRoutes.tarefas),
      ),
      _CardItem(
        label: 'Notas',
        icon: Icons.grade,
        onTap: () => _abrirRota(AppRoutes.notasDesempenho),
      ),
      StreamBuilder<int>(
        stream: _streamComunicadosCount(_turmaId),
        builder: (ctx, snap) {
          final n = snap.data ?? 0;
          final label = n > 0 ? 'Comunicados ($n)' : 'Comunicados';
          return _CardItem(
            label: label,
            icon: Icons.notifications,
            onTap: () => _abrirRota(AppRoutes.comunicados),
          );
        },
      ),
      _CardItem(
        label: 'Agenda',
        icon: Icons.calendar_today,
        onTap: () => _abrirRota(AppRoutes.agendaEscolar),
      ),
      _CardItem(
        label: 'Frequência${_frequencia != '--' ? ' ($_frequencia)' : ''}',
        icon: Icons.checklist,
        onTap: () => _abrirRota(AppRoutes.frequenciaEscolar),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: GridView.builder(
        itemCount: cards.length,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cross,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.15,
        ),
        itemBuilder: (_, i) => cards[i],
      ),
    );
  }

  Widget _notificationsSection() {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications, color: primaryColor),
                const SizedBox(width: 8),
                const Text(
                  'Notificações',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const Spacer(),
                StreamBuilder<int>(
                  stream: _streamComunicadosCount(_turmaId),
                  builder: (ctx, snap) {
                    final n = snap.data ?? 0;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: primaryColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$n',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    );
                  },
                ),
                TextButton(
                  onPressed: () => _abrirRota(AppRoutes.comunicados),
                  child: const Text('Ver todas'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<NotifItem>>(
              stream: _streamNotifs(_turmaId),
              builder: (ctx, snap) {
                final items = snap.data ?? const <NotifItem>[];
                if (items.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('Sem notificações recentes')),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) => InkWell(
                    onTap: () =>
                        _abrirRota(items[i].rota ?? AppRoutes.comunicados),
                    child: _notifCard(items[i]),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _notifCard(NotifItem n) {
    final isTask = n.tipo == NotifTipo.novaTarefa;
    final bg = isTask ? const Color(0xFFECFDF5) : const Color(0xFFEEF5FF);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration:
      BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(isTask ? Icons.check_circle : Icons.notifications,
              color: primaryColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n.titulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  n.subtitulo,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.black54),
                ),
              ],
            ),
          ),
          if (n.isNovo)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text(
                '• Nova',
                style:
                TextStyle(color: Colors.green, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }

  // ===================== build =====================
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text(_isResponsavel ? 'Painel do Responsável' : 'Dashboard do Aluno'),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_isResponsavel) _filhoSelector(),
                    _welcomeCard(),
                    _gridShortcuts(context),
                    _notificationsSection(),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ===================== Card de atalho =====================
class _CardItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _CardItem({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 40, color: primaryColor),
              const SizedBox(height: 12),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                softWrap: true,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: primaryColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}









