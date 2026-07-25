/// Serviço de autenticação social (Google/Facebook) do "Guardião X".
///
/// MOCK/TEMPORÁRIO: ainda não há projeto Firebase configurado no
/// repositório (sem google-services.json, sem Client ID do Google nem
/// App ID do Facebook). Os métodos abaixo simulam um login bem-sucedido
/// (mesmo padrão mock já usado em [LoginScreen]/[CadastroScreen] para o
/// login por e-mail/senha), permitindo validar toda a UI e a navegação
/// antes de existir um backend real.
///
/// PARA ATIVAR A INTEGRAÇÃO REAL (quando houver projeto Firebase e
/// credenciais do Facebook Developer):
/// 1. Descomentar firebase_core/firebase_auth/google_sign_in/
///    flutter_facebook_auth em pubspec.yaml (ver comentário lá).
/// 2. Chamar `Firebase.initializeApp()` em main.dart antes de runApp().
/// 3. Substituir o corpo de [loginComGoogle] por algo como:
///      final googleUser = await GoogleSignIn().signIn();
///      final googleAuth = await googleUser?.authentication;
///      final credential = GoogleAuthProvider.credential(
///        accessToken: googleAuth?.accessToken,
///        idToken: googleAuth?.idToken,
///      );
///      final userCredential =
///          await FirebaseAuth.instance.signInWithCredential(credential);
///      // Se userCredential.additionalUserInfo?.isNewUser == true,
///      // sincronizar/criar o documento do usuário (ex: Firestore).
/// 4. Substituir o corpo de [loginComFacebook] de forma análoga, usando
///    `FacebookAuth.instance.login()` + `FacebookAuthProvider.credential`.
class FirebaseAuthService {
  FirebaseAuthService._internal();
  static final FirebaseAuthService _instance = FirebaseAuthService._internal();
  factory FirebaseAuthService() => _instance;

  /// Simula o login social via Google. Retorna `true` em caso de
  /// "sucesso" (sempre, neste mock). Quando a integração real existir,
  /// deve retornar `false`/lançar uma exceção se o usuário cancelar o
  /// fluxo do Google Sign-In.
  Future<bool> loginComGoogle() async {
    await Future.delayed(const Duration(milliseconds: 600));
    return true;
  }

  /// Simula o login social via Facebook. Retorna `true` em caso de
  /// "sucesso" (sempre, neste mock).
  Future<bool> loginComFacebook() async {
    await Future.delayed(const Duration(milliseconds: 600));
    return true;
  }
}
