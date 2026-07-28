import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../main.dart' show TelaInicialComPossivelDialogoPin;
import '../services/fcm_service.dart';
import '../services/firebase_auth_service.dart';
import '../services/locale_service.dart';
import 'cadastro_screen.dart';

/// Tela de Login do "SOS Security Personal".
///
/// Login real via Firebase Auth (e-mail/senha), com BARREIRA ESTRITA de
/// e-mail verificado: após autenticar com sucesso, recarrega o usuário
/// (`user.reload()`) e só libera o acesso ao fluxo principal
/// ([TelaInicialComPossivelDialogoPin]) se `emailVerified == true`. Caso
/// contrário, encerra a sessão imediatamente e exibe um diálogo
/// explicando que é preciso confirmar o e-mail antes, com a opção de
/// reenviar a mensagem de verificação — em NENHUMA hipótese de erro ou
/// e-mail não verificado a navegação para a Home acontece.
///
/// Não há login social (Google/Facebook) implementado — nenhum atalho de
/// autenticação deve existir nesta tela.
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
  bool _fazendoLogin = false;

  @override
  void dispose() {
    _emailController.dispose();
    _senhaController.dispose();
    super.dispose();
  }

  /// Login real via Firebase Auth. Em caso de sucesso, RECARREGA o
  /// usuário e exige `emailVerified == true` antes de navegar para o
  /// fluxo principal — se o e-mail ainda não foi confirmado, a sessão é
  /// imediatamente encerrada (nunca fica logado sem verificação) e um
  /// diálogo explica o bloqueio, com a opção de reenviar o e-mail. Em
  /// qualquer outra falha (credenciais inválidas, muitas tentativas,
  /// erro inesperado), exibe a mensagem correspondente e NUNCA navega.
  Future<void> _fazerLogin() async {
    if (_formKey.currentState?.validate() != true) return;
    if (_fazendoLogin) return;

    setState(() => _fazendoLogin = true);
    try {
      await FirebaseAuthService().login(
        email: _emailController.text.trim(),
        senha: _senhaController.text,
      );

      // Recarrega ANTES de checar emailVerified — o SDK só reflete uma
      // verificação concluída em outro dispositivo/aba depois de um
      // reload explícito; sem isto, um e-mail já confirmado poderia ser
      // erroneamente barrado por um snapshot local desatualizado.
      await FirebaseAuthService().recarregarUsuarioAtual();
      final usuario = FirebaseAuthService().usuarioAtual;

      if (usuario == null || !usuario.emailVerified) {
        if (mounted) {
          await _exibirDialogoEmailNaoVerificado(usuario);
        }
        // Encerra a sessão SÓ DEPOIS do diálogo (que pode reenviar o
        // e-mail usando a sessão ainda ativa) — garante que, ao sair
        // desta função, NUNCA existe uma sessão autenticada com e-mail
        // não verificado sobrevivendo.
        await FirebaseAuthService().logout();
        return;
      }

      unawaited(FcmService().inicializar());
      if (!mounted) return;
      _navegarParaFluxoPrincipal();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_mensagemErroLogin(e)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
    } catch (e) {
      debugPrint('⚠️ [LoginScreen] Falha inesperada no login: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.erroLoginGenerico),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _fazendoLogin = false);
    }
  }

  String _mensagemErroLogin(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return AppLocalizations.of(context)!.erroLoginCredenciaisInvalidas;
      case 'invalid-email':
        return AppLocalizations.of(context)!.campoEmailInvalido;
      case 'too-many-requests':
        return AppLocalizations.of(context)!.erroLoginMuitasTentativas;
      default:
        return AppLocalizations.of(context)!.erroLoginGenerico;
    }
  }

  /// Exibe o diálogo de bloqueio por e-mail não verificado, com a opção
  /// de reenviar a mensagem de confirmação. [usuario] ainda está
  /// autenticado neste ponto (o logout só acontece depois que este
  /// diálogo fecha, ver [_fazerLogin]) — é isso que permite
  /// `User.sendEmailVerification()` funcionar no botão "Reenviar".
  Future<void> _exibirDialogoEmailNaoVerificado(User? usuario) async {
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.emailNaoVerificadoTitulo),
        content: Text(l10n.emailNaoVerificadoMensagem),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.fechar),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _reenviarEmailVerificacao(usuario);
            },
            child: Text(l10n.emailNaoVerificadoReenviar),
          ),
        ],
      ),
    );
  }

  Future<void> _reenviarEmailVerificacao(User? usuario) async {
    try {
      await usuario?.sendEmailVerification();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.emailVerificacaoReenviada),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      debugPrint('⚠️ [LoginScreen] Falha ao reenviar e-mail de verificação: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.emailVerificacaoReenvioFalhou),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
    }
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
      onFieldSubmitted: (_) => _fazerLogin(),
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
        onPressed: _fazendoLogin ? null : _fazerLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: _corPrincipal,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 2,
        ),
        child: _fazendoLogin
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
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
