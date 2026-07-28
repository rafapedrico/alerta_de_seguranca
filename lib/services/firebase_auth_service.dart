import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Serviço central de autenticação do "Guardião X" — Firebase Auth real
/// (e-mail/senha), com barreira estrita de e-mail verificado: nenhuma
/// sessão dá acesso ao app sem que `emailVerified == true` (ver
/// verificação em [LoginScreen] e envio do e-mail em [CadastroScreen]).
/// Não há login social (Google/Facebook) implementado — nenhum atalho ou
/// bypass de autenticação deve existir neste serviço.
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

  /// Recarrega os dados do usuário atual diretamente do servidor —
  /// necessário para obter o valor mais recente de `emailVerified`: o
  /// SDK mantém um snapshot local que só reflete uma verificação
  /// concluída (o usuário clicou no link do e-mail) depois de um reload
  /// explícito. Chamado pela [LoginScreen] antes de checar
  /// `emailVerified`, garantindo que a barreira de e-mail verificado
  /// nunca libere acesso com base num estado desatualizado em cache.
  Future<void> recarregarUsuarioAtual() async {
    await _auth.currentUser?.reload();
  }

  /// Envia (ou reenvia) o e-mail de verificação para o usuário
  /// atualmente autenticado. Não faz nada se não houver sessão ativa.
  Future<void> enviarEmailVerificacao() async {
    await _auth.currentUser?.sendEmailVerification();
  }
}
