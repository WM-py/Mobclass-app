import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:agenda_digital/core/routes/app_routes.dart';


const Color primaryColor = Color(0xFF021E4C);

class PoliticaPrivacidadeScreen extends StatefulWidget {
  const PoliticaPrivacidadeScreen({super.key});

  @override
  State<PoliticaPrivacidadeScreen> createState() => _PoliticaPrivacidadeScreenState();
}

class _PoliticaPrivacidadeScreenState extends State<PoliticaPrivacidadeScreen> {
  bool _aceito = false;
  bool _carregando = false;

  Future<void> _aceitarPolitica() async {
    setState(() => _carregando = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'aceitouPolitica': true,
      });

      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.dashboard,
            (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Política de Privacidade', style: TextStyle(color: Colors.white)),
        backgroundColor: primaryColor,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  '''
Política de Privacidade – MobClassApp
Última atualização: 24/04/2025

A BW Tecnologia, responsável pelo aplicativo MobClassApp, respeita sua privacidade e se compromete a proteger os dados pessoais de alunos, responsáveis, professores e demais usuários. Esta Política de Privacidade explica como coletamos, usamos, armazenamos e protegemos seus dados, conforme a LGPD (Lei nº 13.709/2018).

1. Quem somos
O MobClassApp é um aplicativo de agenda escolar digital que centraliza a comunicação entre escolas, alunos, pais e professores. Ele é mantido pela BW Tecnologia, CNPJ 60.536.561/0001-31.

2. Quais dados coletamos
Dados de identificação: nome completo e e-mail.
Dados escolares: notas, frequência, agenda, comunicados (gerenciados pela escola).
Dados de acesso: login, senha criptografada, registros de uso.

3. Como usamos os dados
Exibição de informações escolares
Comunicação entre escola e responsáveis
Envio de notificações
Segurança dos alunos
Não vendemos ou compartilhamos dados com fins comerciais.

4. Consentimento dos responsáveis
Alunos menores de idade só podem ser cadastrados por pais ou responsáveis legais.

5. Compartilhamento de dados
Com o próprio usuário, escola e equipe BW Tecnologia (somente para suporte técnico).

6. Segurança da informação
Criptografia, autenticação segura, backups regulares, acesso restrito.

7. Seus direitos
Solicitar acesso, correção ou exclusão de dados
Revogar consentimento
Solicitar informações pelo e-mail: bwtecnologia25@gmail.com

8. Alterações nesta política
Notificaremos via app em caso de mudanças significativas.

Ao clicar em "Aceito", você confirma que é o responsável legal e concorda com os termos desta política.
''',
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ),
            Row(
              children: [
                Checkbox(
                  value: _aceito,
                  onChanged: (val) => setState(() => _aceito = val ?? false),
                ),
                const Expanded(
                  child: Text(
                    'Li e concordo com a política de privacidade.',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _aceito ? _aceitarPolitica : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                ),
                child: const Text('Aceito'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}