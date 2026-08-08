import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Serviço de login social (Google, Facebook e Apple) via Firebase Auth —
/// complementa [FirebaseAuthService] (e-mail/senha, ver
/// `lib/services/firebase_auth_service.dart`), sem alterar nada lá.
///
/// CONTRATO comum aos 3 métodos, para a [LoginScreen] poder tratar todos
/// da mesma forma:
/// - Retorna `null` quando o PRÓPRIO USUÁRIO cancela o fluxo (fechou o
///   seletor de conta Google, cancelou o diálogo do Facebook, fechou a
///   aba do Apple Sign In) — nunca lança exceção só por cancelamento.
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
/// - **Facebook**: App ID + Client Token reais já preenchidos em
///   2026-08-07 (ver `android/app/src/main/res/values/strings.xml`, chaves
///   `facebook_app_id`/`facebook_client_token` — app "Guardião-X" em
///   developers.facebook.com). Ainda faltam 2 passos manuais fora do
///   código, ambos exigindo login em conta/console de terceiros:
///   1. Cadastrar o pacote (`com.example.security_check_app`) + o key
///      hash da assinatura deste app em developers.facebook.com >
///      Configurações > Básico > plataforma Android. Key hash do
///      keystore de DEBUG atual: `/u/eOdSKbTsSmyrjqJ2iQEf3McY=` (gerar de
///      novo se o keystore de debug mudar; hash de RELEASE é outro,
///      precisa ser adicionado à parte antes de publicar).
///   2. Habilitar o provedor "Facebook" no Firebase Console (Authentication
///      > Sign-in method) informando o App ID e o **App Secret** (não é o
///      Client Token — fica em developers.facebook.com > Configurações >
///      Básico > "Chave secreta do aplicativo", exige reautenticação para
///      revelar). Sem isso o Firebase rejeita a credencial do Facebook
///      mesmo com o app Android 100% configurado.
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
  Future<UserCredential?> signInWithGoogle() async {
    final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) return null; // Cancelado pelo usuário

    final GoogleSignInAuthentication googleAuth =
        await googleUser.authentication;
    final OAuthCredential credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    return _auth.signInWithCredential(credential);
  }

  // ================================================================
  // FACEBOOK
  // ================================================================
  Future<UserCredential?> signInWithFacebook() async {
    final LoginResult result = await FacebookAuth.instance.login(
      permissions: const ['email', 'public_profile'],
      // Força o token "clássico" (compatível com
      // FacebookAuthProvider.credential) em vez do "limited" (JWT restrito
      // a rastreamento no iOS, que o Firebase não aceita aqui) — este app
      // só tem alvo Android, onde a SDK nativa sempre devolve clássico de
      // qualquer forma, mas deixar explícito documenta a intenção e
      // protege uma futura adição de projeto iOS.
      loginTracking: LoginTracking.enabled,
    );

    switch (result.status) {
      case LoginStatus.success:
        final AccessToken? token = result.accessToken;
        if (token == null) return null;
        if (token is! ClassicToken) {
          throw FirebaseAuthException(
            code: 'facebook-limited-token-unsupported',
            message:
                'Token do Facebook em modo "limited" não é compatível com '
                'o Firebase Auth (esperado apenas em iOS).',
          );
        }
        final OAuthCredential credential =
            FacebookAuthProvider.credential(token.tokenString);
        return _auth.signInWithCredential(credential);
      case LoginStatus.cancelled:
        return null; // Cancelado pelo usuário
      case LoginStatus.failed:
      case LoginStatus.operationInProgress:
        throw FirebaseAuthException(
          code: 'facebook-login-failed',
          message: result.message ?? 'Falha no login com Facebook.',
        );
    }
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
