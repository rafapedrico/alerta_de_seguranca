import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import '../services/firebase_auth_service.dart';
import '../services/firebase_sync_service.dart';
import '../utils/telefone_utils.dart';

/// Tela de Cadastro (primeiro acesso) do "SOS Security Personal".
///
/// Cria a conta real no Firebase Auth (e-mail/senha), grava o perfil
/// inicial em `usuarios/{uid}` (nome, e-mail, telefone em E.164) via
/// [FirebaseSyncService] e envia o e-mail de verificação.
/// `createUserWithEmailAndPassword` autentica
/// automaticamente o usuário recém-criado — mas como o e-mail ainda não
/// foi confirmado, essa sessão é encerrada IMEDIATAMENTE em seguida e o
/// usuário é devolvido à LoginScreen (nunca entra direto no app sem
/// verificar o e-mail primeiro; é lá que a barreira de `emailVerified`
/// é aplicada de verdade no próximo login).
class CadastroScreen extends StatefulWidget {
  const CadastroScreen({super.key});

  @override
  State<CadastroScreen> createState() => _CadastroScreenState();
}

class _CadastroScreenState extends State<CadastroScreen> {
  static const Color _corPrincipal = Color(0xFF4C7040);
  static const Color _corFundo = Color(0xFF14212E);
  static const Color _corCampoFundo = Color(0xFF1E313F);
  static const Color _corAcentoClaro = Color(0xFF9CCC65);

  final _formKey = GlobalKey<FormState>();
  final _nomeController = TextEditingController();
  final _emailController = TextEditingController();
  final _celularController = TextEditingController();
  final _senhaController = TextEditingController();
  final _confirmarSenhaController = TextEditingController();

  bool _senhaVisivel = false;
  bool _confirmarSenhaVisivel = false;
  bool _criandoConta = false;

  @override
  void dispose() {
    _nomeController.dispose();
    _emailController.dispose();
    _celularController.dispose();
    _senhaController.dispose();
    _confirmarSenhaController.dispose();
    super.dispose();
  }

  /// Cria a conta real no Firebase Auth, grava o perfil inicial no
  /// Firestore e envia o e-mail de verificação. Sempre encerra a sessão
  /// recém-criada antes de retornar à LoginScreen — em NENHUMA hipótese
  /// (sucesso ou falha) esta tela navega para dentro do app. Em caso de
  /// falha (e-mail já cadastrado, senha fraca, etc.), exibe o erro em
  /// vez disso.
  Future<void> _criarConta() async {
    if (_formKey.currentState?.validate() != true) return;
    if (_criandoConta) return;

    setState(() => _criandoConta = true);
    try {
      final credencial = await FirebaseAuthService().criarConta(
        email: _emailController.text.trim(),
        senha: _senhaController.text,
      );

      final uid = credencial.user?.uid;
      if (uid != null) {
        // Se chegou até aqui, o validador do campo (ver
        // `_buildCampoCelular`) já garantiu que o número é válido em
        // alguma interpretação internacional razoável — o fallback ao
        // texto bruto é só uma rede de segurança, nunca deve ser
        // efetivamente usado na prática.
        await FirebaseSyncService().criarPerfilInicial(
          nome: _nomeController.text.trim(),
          email: _emailController.text.trim(),
          telefone: TelefoneUtils.normalizarE164(_celularController.text.trim()) ??
              _celularController.text.trim(),
        );
        await FirebaseAuthService().enviarEmailVerificacao();
      }

      // Encerra a sessão automática do createUserWithEmailAndPassword —
      // o e-mail ainda não foi verificado, então este usuário NÃO deve
      // permanecer autenticado. O login real (com a barreira de
      // emailVerified) só acontece na LoginScreen.
      await FirebaseAuthService().logout();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.cadastroEmailVerificacaoEnviado),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
      Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_mensagemErroCadastro(e)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _criandoConta = false);
    }
  }

  String _mensagemErroCadastro(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':
        return AppLocalizations.of(context)!.erroCadastroEmailEmUso;
      case 'weak-password':
        return AppLocalizations.of(context)!.erroCadastroSenhaFraca;
      case 'invalid-email':
        return AppLocalizations.of(context)!.campoEmailInvalido;
      default:
        return AppLocalizations.of(context)!.erroCadastroGenerico;
    }
  }

  void _voltarParaLogin() {
    Navigator.of(context).pop();
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
                  const SizedBox(height: 40),
                  _buildCampoNome(),
                  const SizedBox(height: 16),
                  _buildCampoEmail(),
                  const SizedBox(height: 16),
                  _buildCampoCelular(),
                  const SizedBox(height: 16),
                  _buildCampoSenha(),
                  const SizedBox(height: 16),
                  _buildCampoConfirmarSenha(),
                  const SizedBox(height: 28),
                  _buildBotaoCriarConta(),
                  const SizedBox(height: 20),
                  _buildLinkVoltarParaLogin(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Topo idêntico ao da tela de Login, mantendo a mesma identidade
  /// visual do "SOS Security Personal".
  Widget _buildCabecalho() {
    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: const BoxDecoration(
            color: _corPrincipal,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.shield, color: Colors.white, size: 44),
        ),
        const SizedBox(height: 18),
        const Text(
          'SOS Security Personal',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.3,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          AppLocalizations.of(context)!.cadastroSubtitulo,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ],
    );
  }

  Widget _buildCampoNome() {
    return TextFormField(
      controller: _nomeController,
      textInputAction: TextInputAction.next,
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoNomeLabel,
        icone: Icons.person_outline,
      ),
      validator: (valor) {
        if (valor == null || valor.trim().isEmpty) {
          return AppLocalizations.of(context)!.campoNomeObrigatorio;
        }
        return null;
      },
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

  Widget _buildCampoCelular() {
    return TextFormField(
      controller: _celularController,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.next,
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoCelularLabel,
        icone: Icons.phone_android_outlined,
      ),
      validator: (valor) {
        if (valor == null || valor.trim().isEmpty) {
          return AppLocalizations.of(context)!.campoCelularObrigatorio;
        }
        if (TelefoneUtils.normalizarE164(valor) == null) {
          return AppLocalizations.of(context)!.campoCelularInvalido;
        }
        return null;
      },
    );
  }

  Widget _buildCampoSenha() {
    return TextFormField(
      controller: _senhaController,
      obscureText: !_senhaVisivel,
      textInputAction: TextInputAction.next,
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
        if (valor.length < 6) {
          return AppLocalizations.of(context)!.campoSenhaMinima;
        }
        return null;
      },
    );
  }

  Widget _buildCampoConfirmarSenha() {
    return TextFormField(
      controller: _confirmarSenhaController,
      obscureText: !_confirmarSenhaVisivel,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _criarConta(),
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoConfirmarSenhaLabel,
        icone: Icons.lock_outline,
        sufixo: IconButton(
          icon: Icon(
            _confirmarSenhaVisivel ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: Colors.white70,
          ),
          onPressed: () => setState(() => _confirmarSenhaVisivel = !_confirmarSenhaVisivel),
        ),
      ),
      validator: (valor) {
        if (valor == null || valor.isEmpty) {
          return AppLocalizations.of(context)!.campoConfirmarSenhaObrigatoria;
        }
        if (valor != _senhaController.text) {
          return AppLocalizations.of(context)!.senhasNaoCoincidem;
        }
        return null;
      },
    );
  }

  Widget _buildBotaoCriarConta() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _criandoConta ? null : _criarConta,
        style: ElevatedButton.styleFrom(
          backgroundColor: _corPrincipal,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 2,
        ),
        child: _criandoConta
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
          AppLocalizations.of(context)!.botaoCriarConta,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildLinkVoltarParaLogin() {
    // Wrap (em vez de Row) permite que o texto quebre para uma segunda
    // linha em idiomas cuja tradução é mais longa que o espaço
    // disponível, evitando overflow horizontal.
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(AppLocalizations.of(context)!.jaTemConta, style: const TextStyle(color: Colors.white70)),
        TextButton(
          onPressed: _voltarParaLogin,
          child: Text(
            AppLocalizations.of(context)!.facaLogin,
            style: const TextStyle(color: _corAcentoClaro, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// Mesmo estilo de input arredondado/discreto usado na tela de Login.
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
