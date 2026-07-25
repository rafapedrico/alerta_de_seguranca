import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../main.dart' show TelaInicialComPossivelDialogoPin;
import '../services/firebase_auth_service.dart';
import '../services/locale_service.dart';
import 'cadastro_screen.dart';

/// Tela de Login do "SOS Security Personal".
///
/// MOCK/TEMPORÁRIO: por enquanto não existe integração real com backend
/// de autenticação — o botão "Entrar" apenas simula um login bem-sucedido
/// (sem validar e-mail/senha contra nenhum servidor) e navega diretamente
/// para o fluxo já existente do app ([TelaInicialComPossivelDialogoPin],
/// que por sua vez exibe a [HomeScreen] com toda a lógica de segurança
/// já implementada: check-in, PIN de coação, alarme nativo, etc.).
///
/// Esta tela é puramente visual/de UX nesta etapa. A troca por um fluxo
/// de autenticação real (validação de credenciais, persistência de
/// sessão/token, tela de erro em caso de falha) fica para uma etapa
/// futura.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const Color _corPrincipal = Color(0xFF4C7040);
  static const Color _corFundo = Color(0xFF14212E);
  static const Color _corCampoFundo = Color(0xFF1E313F);
  static const Color _corAcentoClaro = Color(0xFF9CCC65);

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _senhaController = TextEditingController();
  bool _senhaVisivel = false;

  @override
  void dispose() {
    _emailController.dispose();
    _senhaController.dispose();
    super.dispose();
  }

  /// MOCK: simula um login bem-sucedido sem nenhuma validação real de
  /// backend, e navega diretamente para o fluxo principal do app já
  /// existente ([TelaInicialComPossivelDialogoPin]), substituindo a rota
  /// de Login na pilha de navegação (o usuário não deve conseguir voltar
  /// para o Login apertando o botão "voltar" do Android após logar).
  void _fazerLoginMock() {
    if (_formKey.currentState?.validate() != true) return;
    _navegarParaFluxoPrincipal();
  }

  /// Simula o login social via Google (ver [FirebaseAuthService] para o
  /// que precisa mudar quando a integração real com Firebase existir).
  Future<void> _loginComGoogle() async {
    final sucesso = await FirebaseAuthService().loginComGoogle();
    if (!sucesso || !mounted) return;
    _navegarParaFluxoPrincipal();
  }

  /// Simula o login social via Facebook (ver [FirebaseAuthService]).
  Future<void> _loginComFacebook() async {
    final sucesso = await FirebaseAuthService().loginComFacebook();
    if (!sucesso || !mounted) return;
    _navegarParaFluxoPrincipal();
  }

  void _navegarParaFluxoPrincipal() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) =>
            const TelaInicialComPossivelDialogoPin(aguardandoConfirmacaoPin: false),
      ),
    );
  }

  void _abrirEsqueciMinhaSenha() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.recuperacaoSenhaEmBreve)),
    );
  }

  void _abrirCadastro() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const CadastroScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _corFundo,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCabecalho(),
                  const SizedBox(height: 32),
                  _buildCampoEmail(),
                  const SizedBox(height: 16),
                  _buildCampoSenha(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _abrirEsqueciMinhaSenha,
                      child: Text(
                        AppLocalizations.of(context)!.esqueciMinhaSenha,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildBotaoEntrar(),
                  const SizedBox(height: 24),
                  _buildDivisorSocial(),
                  const SizedBox(height: 20),
                  _buildBotoesLoginSocial(),
                  const SizedBox(height: 20),
                  _buildLinkCadastro(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Topo: marca "Guardião X" (ícone + título + subtítulo) e a
  /// ilustração central, recortadas do mockup de design original. A
  /// imagem exibida depende do idioma selecionado em Configurações (ver
  /// [LocaleService.caminhoImagemLoginPara]); se o arquivo do idioma
  /// escolhido ainda não tiver sido adicionado a assets/images/, cai
  /// automaticamente para a versão em português.
  Widget _buildCabecalho() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: ValueListenableBuilder<String>(
        valueListenable: LocaleService.codigoIdiomaCompletoNotifier,
        builder: (context, codigoIdioma, _) {
          return Image.asset(
            LocaleService.caminhoImagemLoginPara(codigoIdioma),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Image.asset(
              LocaleService.imagemLoginPadrao,
              fit: BoxFit.cover,
            ),
          );
        },
      ),
    );
  }

  /// Divisor "ou entre com" entre o login por e-mail/senha e os botões
  /// de login social.
  Widget _buildDivisorSocial() {
    return Row(
      children: [
        const Expanded(child: Divider(color: Colors.white24)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            AppLocalizations.of(context)!.ouEntreCom,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
        const Expanded(child: Divider(color: Colors.white24)),
      ],
    );
  }

  Widget _buildBotoesLoginSocial() {
    return Row(
      children: [
        Expanded(
          child: _buildBotaoSocial(
            label: AppLocalizations.of(context)!.loginGoogle,
            icone: const Text(
              'G',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFFEA4335),
              ),
            ),
            onPressed: _loginComGoogle,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildBotaoSocial(
            label: AppLocalizations.of(context)!.loginFacebook,
            icone: const Icon(Icons.facebook, color: Color(0xFF1877F2)),
            onPressed: _loginComFacebook,
          ),
        ),
      ],
    );
  }

  Widget _buildBotaoSocial({
    required String label,
    required Widget icone,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: icone,
        label: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.white38),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  Widget _buildCampoEmail() {
    return TextFormField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoEmailLabel,
        icone: Icons.email_outlined,
      ),
      validator: (valor) {
        if (valor == null || valor.trim().isEmpty) {
          return AppLocalizations.of(context)!.campoEmailObrigatorio;
        }
        if (!valor.contains('@') || !valor.contains('.')) {
          return AppLocalizations.of(context)!.campoEmailInvalido;
        }
        return null;
      },
    );
  }

  Widget _buildCampoSenha() {
    return TextFormField(
      controller: _senhaController,
      obscureText: !_senhaVisivel,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _fazerLoginMock(),
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoSenhaLabel,
        icone: Icons.lock_outline,
        sufixo: IconButton(
          icon: Icon(
            _senhaVisivel ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: Colors.white70,
          ),
          onPressed: () => setState(() => _senhaVisivel = !_senhaVisivel),
        ),
      ),
      validator: (valor) {
        if (valor == null || valor.isEmpty) {
          return AppLocalizations.of(context)!.campoSenhaObrigatoria;
        }
        return null;
      },
    );
  }

  Widget _buildBotaoEntrar() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _fazerLoginMock,
        style: ElevatedButton.styleFrom(
          backgroundColor: _corPrincipal,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 2,
        ),
        child: Text(
          AppLocalizations.of(context)!.botaoEntrar,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildLinkCadastro() {
    // Wrap (em vez de Row) permite que o texto quebre para uma segunda
    // linha em idiomas cuja tradução é mais longa que o espaço
    // disponível, evitando overflow horizontal.
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(AppLocalizations.of(context)!.naoTemConta, style: const TextStyle(color: Colors.white70)),
        TextButton(
          onPressed: _abrirCadastro,
          child: Text(
            AppLocalizations.of(context)!.cadastreSe,
            style: const TextStyle(color: _corAcentoClaro, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// Estilo compartilhado (arredondado, discreto) para os inputs desta
  /// tela e da tela de Cadastro.
  static InputDecoration _decoracaoInput({
    required String label,
    required IconData icone,
    Widget? sufixo,
  }) {
    final borda = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    );
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white70),
      prefixIcon: Icon(icone, color: Colors.white70),
      suffixIcon: sufixo,
      filled: true,
      fillColor: _corCampoFundo,
      border: borda,
      enabledBorder: borda,
      focusedBorder: borda.copyWith(
        borderSide: const BorderSide(color: _corAcentoClaro, width: 1.5),
      ),
      errorBorder: borda.copyWith(
        borderSide: const BorderSide(color: Colors.redAccent, width: 1.2),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
    );
  }
}
