import 'package:flutter/material.dart';

// Auth change password screens
import 'package:agenda_digital/features/auth/presentation/screens/aluno_trocar_senha_screen.dart';
import 'package:agenda_digital/features/auth/presentation/screens/responsavel_trocar_senha_screen.dart';
import 'package:agenda_digital/features/auth/presentation/screens/recuperar_senha_screen.dart';

// Unified Dashboard
import 'package:agenda_digital/features/aluno/presentation/screens/dashboard_screen.dart';

// Feature screens
import 'package:agenda_digital/features/aluno/presentation/screens/agenda_escolar_screen.dart';
import 'package:agenda_digital/features/aluno/presentation/screens/comunicados_screen.dart';
import 'package:agenda_digital/features/aluno/presentation/screens/frequencia_screen.dart';
import 'package:agenda_digital/features/aluno/presentation/screens/minhas_notas_screen.dart';
import 'package:agenda_digital/features/aluno/presentation/screens/politica_privacidade_screen.dart';
import 'package:agenda_digital/features/aluno/presentation/screens/tarefas_screen.dart';

class AppRoutes {
  // Password recovery & change
  static const String alunoTrocarSenha       = '/aluno-trocar-senha';
  static const String responsavelTrocarSenha = '/responsavel-trocar-senha';
  static const String recuperarSenha         = '/recuperar-senha';

  // Dashboard (unificado)
  static const String dashboard              = '/dashboard';

  // Features
  static const String agendaEscolar          = '/agenda-escolar';
  static const String comunicados            = '/comunicados';
  static const String frequenciaEscolar      = '/frequencia-escolar';

  // Mantemos o identificador da rota por compatibilidade,
  // mas o widget é MinhasNotasScreen.
  static const String notasDesempenho        = '/notas-desempenho';

  static const String politicaPrivacidade    = '/politica-privacidade';
  static const String tarefas                = '/tarefas';
}

/// Static route mapping (no "/" entry)
final Map<String, WidgetBuilder> appRoutes = {
  // Auth flows
  AppRoutes.alunoTrocarSenha:        (ctx) => const AlunoTrocarSenhaScreen(),
  AppRoutes.responsavelTrocarSenha:  (ctx) => const ResponsavelTrocarSenhaScreen(),
  AppRoutes.recuperarSenha:          (ctx) => const RecuperarSenhaScreen(),

  // Dashboard (unificado)
  AppRoutes.dashboard: (ctx) => const DashboardScreen(),

  // Features
  AppRoutes.agendaEscolar:           (ctx) => const AgendaEscolarScreen(),
  AppRoutes.comunicados:             (ctx) => const ComunicadosScreen(),
  AppRoutes.frequenciaEscolar:       (ctx) => const FrequenciaScreen(),

  // >>> Correção principal aqui: usar MinhasNotasScreen()
  AppRoutes.notasDesempenho:         (ctx) => const MinhasNotasScreen(),

  AppRoutes.politicaPrivacidade:     (ctx) => const PoliticaPrivacidadeScreen(),
  AppRoutes.tarefas:                 (ctx) => const TarefasScreen(),
};










