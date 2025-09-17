import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:agenda_digital/core/routes/app_routes.dart';
import 'package:agenda_digital/services/firebase_utils.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  bool _isLoading = false;
  String _errorMessage = '';

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text,
      );
      final uid = cred.user?.uid;
      if (uid == null) throw 'Usuário não encontrado.';
      await salvarTokenFCM();
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data();
      if (data == null) throw 'Dados do usuário não encontrados.';

      final bool firstAcesso = data['firstAcesso'] == true;
      final bool aceitouPolitica = data['aceitouPolitica'] == true;
      final String tipo = (data['tipo'] as String?)?.toLowerCase() ?? 'aluno';

      if (firstAcesso) {
        Navigator.of(context).pushReplacementNamed(
          tipo.contains('respons') ? AppRoutes.responsavelTrocarSenha : AppRoutes.alunoTrocarSenha,
        );
        return;
      }

      if (tipo.contains('respons') && !aceitouPolitica) {
        Navigator.of(context).pushReplacementNamed(AppRoutes.politicaPrivacidade);
        return;
      }

      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.dashboard,
            (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        switch (e.code) {
          case 'user-not-found':
            _errorMessage = 'Usuário não encontrado.';
            break;
          case 'wrong-password':
            _errorMessage = 'Senha incorreta.';
            break;
          default:
            _errorMessage = 'Erro de autenticação.';
        }
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Erro ao fazer login: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: primary,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: Image.asset('assets/logo.png', height: 120)),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: emailController,
                      decoration: const InputDecoration(
                        labelText: 'E-mail',
                        prefixIcon: Icon(Icons.email),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      validator: (value) =>
                      value != null && value.contains('@') ? null : 'E-mail inválido',
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: passwordController,
                      decoration: const InputDecoration(
                        labelText: 'Senha',
                        prefixIcon: Icon(Icons.lock),
                      ),
                      obscureText: true,
                      validator: (value) =>
                      value != null && value.length >= 6 ? null : 'Senha muito curta',
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.pushNamed(context, AppRoutes.recuperarSenha),
                      child: const Text(
                        'Esqueceu sua senha?',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : ElevatedButton(
                      onPressed: _login,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('Entrar', style: TextStyle(fontSize: 16)),
                    ),
                    if (_errorMessage.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage,
                        style: const TextStyle(color: Colors.red, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


























