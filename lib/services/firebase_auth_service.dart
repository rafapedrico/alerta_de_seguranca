import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Serviço central de autenticação do "Guardião X" — Firebase Auth real
/// (e-mail/senha), com barreira estrita de e-mail verificado: nenhuma
/// sessão dá acesso ao app sem que `emailVerified == true` (ver
/// verificação em [LoginScreen] e envio do e-mail em [CadastroScreen]).
/// Não há login social (Google/Facebook) implementado — nenhum atalho ou
/// bypass de autenticação deve existir neste serviço.
///
/// POLÍTICA DE SEGURANÇA (Opção A): sessões do Firebase Auth NUNCA
/// sobrevivem a um cold start NORMAL — `main()` chama [logout] logo após
/// inicializar o Firebase, antes de `runApp`, para que o app sempre
/// reabra na `LoginScreen` e exija credenciais de novo (ver
/// `_telaInicial` em `main.dart`). EXCEÇÃO deliberada: um cold start via
/// SOS físico (botão de Volume+ com o app fechado, ver
/// `LockscreenCameraActivity`/`main.dart`) NÃO chama [logout] — esse
/// fluxo nunca exibe nenhuma UI de conta (só a câmera), então preservar
/// a sessão não expõe nada a quem estiver com o aparelho, e é o que
/// permite o SOS físico disparar com Push/WhatsApp/link real da foto
/// mesmo 100% a frio (sem essa exceção, `uidAtual` ficava sempre `null`
/// nesse cenário, e o SOS físico caía sempre no SMS de fallback sem
/// link real).
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

  /// Resolve o `uid` com segurança contra a corrida de restauração da
  /// sessão: `currentUser`/[uidAtual] é uma leitura SÍNCRONA do SDK, mas
  /// logo após `Firebase.initializeApp()` (caso de um engine recém-criado,
  /// ver `LockscreenCameraActivity`/`RotinaCheckinAlarmActivity`), o SDK
  /// ainda pode estar restaurando de forma ASSÍNCRONA, em segundo plano, a
  /// sessão persistida em disco — nesses primeiros instantes,
  /// `currentUser` pode retornar `null` mesmo havendo uma sessão válida
  /// salva, fazendo o chamador concluir (incorretamente) "sem sessão" e
  /// cair num fallback sem nuvem/link real (bug real observado no SOS via
  /// botão físico: a foto — P2, que roda alguns segundos DEPOIS do
  /// disparo inicial — às vezes usava o SMS de fallback com link falso).
  ///
  /// Caminho rápido: se [uidAtual] já está disponível, devolve na hora,
  /// sem nenhuma espera (não atrasa o caso comum, imensa maioria das
  /// chamadas). Só quando `null`, aguarda a primeira emissão de
  /// [mudancasDeEstado] (o SDK garante emitir assim que a restauração
  /// termina, com o usuário real OU `null` se de fato não há sessão) —
  /// com um teto de tempo para nunca travar um fluxo de emergência
  /// esperando indefinidamente por uma sessão que genuinamente não existe.
  Future<String?> aguardarUidPronto({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final String? imediato = uidAtual;
    if (imediato != null) return imediato;

    try {
      final User? usuario = await mudancasDeEstado.first.timeout(timeout);
      return usuario?.uid;
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseAuthService] Timeout/erro aguardando restauração da sessão — seguindo com uidAtual atual ($uidAtual): $e');
      return uidAtual;
    }
  }

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
