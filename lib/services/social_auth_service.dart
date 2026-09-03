import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Serviço de login social (Google e Apple) via Firebase Auth —
/// complementa [FirebaseAuthService] (e-mail/senha, ver
/// `lib/services/firebase_auth_service.dart`), sem alterar nada lá.
///
/// Facebook REMOVIDO em 2026-08-23 (decisão de arquitetura — reduzir
/// superfície de manutenção; o login social ficou restrito a provedores
/// que o próprio Firebase Auth garante e-mail verificado automaticamente).
///
/// CONTRATO comum aos 2 métodos, para a [LoginScreen] poder tratar ambos
/// da mesma forma:
/// - Retorna `null` quando o PRÓPRIO USUÁRIO cancela o fluxo (fechou o
///   seletor de conta Google, fechou a aba do Apple Sign In) — nunca
///   lança exceção só por cancelamento.
/// - Qualquer outra falha real (rede, configuração ausente/incorreta,
///   credencial rejeitada pelo Firebase) propaga a exceção original
///   (`FirebaseAuthException` ou a exceção nativa do respectivo plugin)
///   para quem chamou tratar/exibir.
///
/// NOTA DE CONFIGURAÇÃO (fora do escopo deste arquivo — exige acesso aos
/// consoles/contas de desenvolvedor do usuário, não só código):
/// - **Google**: precisa do SHA-1 (debug e release) da assinatura deste
///   app cadastrado no Firebase Console (Project Settings > app Android
///   "guardiaox") — sem isso o Google devolve `DEVELOPER_ERROR` mesmo com
///   o código 100% correto.
/// - **Apple**: "Sign in with Apple" exige Apple Developer Program (pago)
///   + um Services ID + um domínio/endpoint de redirect verificado — ver
///   [_appleWebAuthOptions] abaixo (hoje só placeholders). Sem isso o
///   botão abre a aba do navegador e falha no redirect de volta pro app.
class SocialAuthService {
  SocialAuthService._internal();
  static final SocialAuthService _instance = SocialAuthService._internal();
  factory SocialAuthService() => _instance;

  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ================================================================
  // GOOGLE
  // ================================================================

  /// `true` assim que [GoogleSignIn.instance.initialize] for chamado com
  /// sucesso pela primeira vez — a API 7.x exige essa chamada ANTES de
  /// qualquer outro método da instância singleton, e chamá-la de novo a
  /// cada tentativa de login seria redundante (a própria instância já é
  /// reaproveitada entre chamadas).
  bool _googleSignInInicializado = false;

  /// Client ID OAuth do tipo "Web" (client_type 3) do projeto Firebase
  /// "guardiaox" — ver `android/app/google-services.json`. CORREÇÃO
  /// (bug real diagnosticado em teste, 2026-08-10): diferente da API
  /// 6.x (que resolvia isso sozinha a partir do google-services.json),
  /// a 7.x EXIGE esse valor explicitamente em Android
  /// (`GoogleSignInExceptionCode.clientConfigurationError: serverClientId
  /// must be provided on Android` — erro real observado em teste). Tem
  /// que ser o client ID do tipo Web (não o Android), pois é a
  /// audiência que o Firebase espera ao validar o idToken em
  /// `GoogleAuthProvider.credential`.
  static const String _googleServerClientId =
      '555863351772-vrlhh2c4kv0a1ci7eu34i36rq5jro327.apps.googleusercontent.com';

  /// CORREÇÃO (bug real diagnosticado em teste, 2026-08-10 — login com
  /// Google travando indefinidamente, sem erro nenhum): migrado da API
  /// "clássica" (`GoogleSignIn().signIn()`, removida/descontinuada em
  /// runtime pelo próprio Play Services) para a API 7.x baseada em
  /// Credential Manager — instância singleton (`GoogleSignIn.instance`),
  /// `initialize()` obrigatório antes de qualquer chamada, e
  /// `authenticate()` no lugar de `signIn()`. Autenticação (identidade,
  /// `idToken`) e autorização (`accessToken`/escopos, via
  /// `authorizationClient`) agora são passos SEPARADOS — o Firebase só
  /// precisa do `idToken` para `GoogleAuthProvider.credential` (mesmo
  /// padrão da documentação oficial do FlutterFire).
  ///
  /// SEGUNDO BUG REAL (2026-08-11, aparelho Android 9/API 28 mais
  /// antigo — "moto g7 play"): mesmo a API 7.x/Credential Manager pode
  /// ficar PENDURADA para sempre em `authenticate()` (nem sucesso, nem
  /// exceção) quando o Google Play Services do aparelho está
  /// desatualizado/não suporta bem o Credential Manager — o botão fica
  /// girando indefinidamente, EXATAMENTE o mesmo sintoma do bug original
  /// de App Check (ver `main.dart`), só que num ponto diferente do
  /// fluxo. `.timeout(...)` aqui NÃO conserta o Credential Manager do
  /// aparelho (isso é uma limitação de SO/Play Services fora do
  /// controle deste app), mas garante que o usuário sempre receba um
  /// erro claro (capturado pelo `catch` genérico de
  /// [LoginScreen._fazerLoginSocial]) em vez de um spinner infinito sem
  /// nenhum feedback.
  Future<UserCredential?> signInWithGoogle() async {
    try {
      if (!_googleSignInInicializado) {
        await GoogleSignIn.instance
            .initialize(serverClientId: _googleServerClientId)
            .timeout(const Duration(seconds: 15));
        _googleSignInInicializado = true;
      }

      final GoogleSignInAccount googleUser = await GoogleSignIn.instance
          .authenticate()
          .timeout(const Duration(seconds: 45));
      final GoogleSignInAuthentication googleAuth =
          googleUser.authentication;
      final String? idToken = googleAuth.idToken;
      // Defensivo: `idToken` é nullable no plugin (`GoogleSignInAuthentication`,
      // ver `google_sign_in` 7.x) — na prática só deveria vir nulo se o
      // `serverClientId` estiver mal configurado ou o Google devolver uma
      // resposta incompleta. Sem esta checagem, `GoogleAuthProvider.credential`
      // seguiria adiante com `idToken: null` e o Firebase falharia mais
      // abaixo com um erro genérico difícil de diagnosticar — melhor
      // sinalizar aqui, no ponto exato da causa.
      if (idToken == null) {
        throw FirebaseAuthException(
          code: 'invalid-credential',
          message: 'O Google não retornou um idToken válido para esta conta.',
        );
      }
      final OAuthCredential credential = GoogleAuthProvider.credential(
        idToken: idToken,
      );
      return await _auth.signInWithCredential(credential);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return null; // Cancelado pelo usuário
      }
      rethrow;
    }
  }

  // ================================================================
  // UTILITÁRIO DE DIAGNÓSTICO/TESTE
  // ================================================================

  /// Encerra qualquer sessão/cache LOCAL de login social (Google +
  /// Firebase) — usado pelo botão de diagnóstico da [LoginScreen] (pedido
  /// do usuário, 2026-08-10, para poder testar o login do zero sem
  /// reaproveitar uma conta/sessão já em cache no aparelho).
  ///
  /// [GoogleSignIn.disconnect] é mais completo que [GoogleSignIn.signOut]:
  /// além de encerrar a sessão, REVOGA o acesso concedido e limpa por
  /// completo a conta lembrada localmente pelo plugin — sem isso, o
  /// próximo toque no botão do Google pode pular direto para a MESMA
  /// conta de antes (sign-in silencioso) em vez de mostrar o seletor de
  /// contas de novo. Best-effort: nunca lança exceção (cada etapa é
  /// independente e protegida, mesmo que a conta já esteja desconectada).
  Future<void> encerrarSessoesSociais() async {
    try {
      if (!_googleSignInInicializado) {
        await GoogleSignIn.instance.initialize(serverClientId: _googleServerClientId);
        _googleSignInInicializado = true;
      }
    } catch (_) {}
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    try {
      await GoogleSignIn.instance.disconnect();
    } catch (_) {}
    try {
      await _auth.signOut();
    } catch (_) {}
  }

  // ================================================================
  // APPLE
  // ================================================================

  /// Services ID + redirect da configuração "Sign in with Apple" feita no
  /// Apple Developer (developer.apple.com > Certificates, IDs & Profiles >
  /// Identifiers > Services IDs) — OBRIGATÓRIO no Android/Web: diferente
  /// do iOS nativo, aqui o plugin abre um fluxo OAuth via Chrome Custom
  /// Tab que precisa saber para onde voltar. PLACEHOLDERS — substitua
  /// pelos valores reais do Apple Developer Program antes de publicar.
  static final WebAuthenticationOptions _appleWebAuthOptions =
      WebAuthenticationOptions(
    clientId: 'com.example.security_check_app.signin',
    redirectUri: Uri.parse(
      'https://guardiaox.firebaseapp.com/__/auth/handler',
    ),
  );

  Future<UserCredential?> signInWithApple() async {
    // Nonce aleatório: gerado localmente (helper oficial do próprio
    // pacote), hasheado (SHA-256) e enviado na REQUISIÇÃO à Apple; a Apple
    // embute o hash dentro do `identityToken` (JWT) devolvido, e o
    // Firebase exige o valor CRU (`rawNonce`) na credencial pra provar que
    // o token não foi reaproveitado (proteção contra replay attack).
    // Usar outro campo (como `state`) no lugar do rawNonce real faz o
    // Firebase rejeitar o login com `auth/invalid-credential`.
    final String rawNonce = generateNonce();
    final String nonceHasheado =
        sha256.convert(utf8.encode(rawNonce)).toString();

    final AuthorizationCredentialAppleID appleCredential;
    try {
      appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: nonceHasheado,
        webAuthenticationOptions: _appleWebAuthOptions,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        return null; // Cancelado pelo usuário
      }
      rethrow;
    }

    final String? identityToken = appleCredential.identityToken;
    if (identityToken == null) return null;

    final OAuthCredential credential = OAuthProvider('apple.com').credential(
      idToken: identityToken,
      rawNonce: rawNonce,
    );
    return _auth.signInWithCredential(credential);
  }
}
