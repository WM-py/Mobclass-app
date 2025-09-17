import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

Future<void> salvarTokenFCM() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  final token = await FirebaseMessaging.instance.getToken();
  if (token == null) return;

  // Atualiza o campo `fcmToken` no documento do usuário logado
  await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
    'fcmToken': token,
  }, SetOptions(merge: true));
}
