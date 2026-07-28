import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Serviço central de autenticação do "Guardião X" — Firebase Auth real
/// (e-mail/senha). O login social (Google/Facebook) permanece mockado por
/// enquanto (sem Client ID/App ID configurados) — ver [loginComGoogle]/
/// [loginComFacebook].
///
/// Toda a arquitetura híbrida de alertas (carteira em USD, vínculo
/// telefone/fcmToken, regras do Firestore) depende de um `uid` real: é
/// ele que passa a identificar o documento em `usuarios/{uid}` no lugar
/// do antigo `ApiService.usuarioIdPadrao` fixo.
class FirebaseAuthService {
  FirebaseAuthService._internal();
  static final FirebaseAuthService _instance = FirebaseAuthService._internal();
  factory FirebaseAuthService() => _instance;

  FirebaseAuth get _auth => FirebaseAuth.instance;

  /// `uid` do usuário autenticado no momento, ou `null` se não houver
  /// sessão ativa.
  String? get uidAtual => _auth.currentUser?.uid;

  User? get usuarioAtual => _auth.currentUser;

  /// Stream do estado de autenticação, usada por `main.dart` para decidir
  /// entre `LoginScreen` e o fluxo principal do app.
  Stream<User?> get mudancasDeEstado => _auth.authStateChanges();

  /// Cria a conta com e-mail/senha. Lança [FirebaseAuthException] em caso
  /// de falha (e-mail já em uso, senha fraca, etc.) — quem chama deve
  /// tratar e exibir a mensagem adequada.
  Future<UserCredential> criarConta({
    required String email,
    required String senha,
  }) {
    return _auth.createUserWithEmailAndPassword(email: email, password: senha);
  }

  /// Login com e-mail/senha. Lança [FirebaseAuthException] em caso de
  /// falha (usuário inexistente, senha incorreta, etc.).
  Future<UserCredential> login({
    required String email,
    required String senha,
  }) {
    return _auth.signInWithEmailAndPassword(email: email, password: senha);
  }

  Future<void> logout() async {
    try {
      await _auth.signOut();
    } catch (e) {
      debugPrint('⚠️ [FirebaseAuthService] Falha ao encerrar sessão: $e');
    }
  }

  /// Simula o login social via Google. Retorna `true` em caso de
  /// "sucesso" (sempre, neste mock) — ainda não há projeto Google
  /// Sign-In configurado.
  Future<bool> loginComGoogle() async {
    await Future.delayed(const Duration(milliseconds: 600));
    return true;
  }

  /// Simula o login social via Facebook. Retorna `true` em caso de
  /// "sucesso" (sempre, neste mock) — ainda não há App ID do Facebook
  /// configurado.
  Future<bool> loginComFacebook() async {
    await Future.delayed(const Duration(milliseconds: 600));
    return true;
  }
}
