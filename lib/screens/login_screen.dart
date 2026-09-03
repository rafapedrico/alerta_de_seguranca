import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../app_navigator.dart';
import '../main.dart' show TelaInicialComPossivelDialogoPin;
import '../services/contatos_emergencia_service.dart';
import '../services/fcm_service.dart';
import '../services/firebase_auth_service.dart';
import '../services/firebase_sync_service.dart';
import '../services/onboarding_service.dart';
import '../widgets/recuperar_senha_dialog.dart';
import 'onboarding_screen.dart';
import '../services/locale_service.dart';
import '../services/notificacao_service.dart';
import '../services/social_auth_service.dart';
import '../widgets/monitoramento_decisao_dialog.dart';
import 'cadastro_screen.dart';
import 'completar_perfil_screen.dart';

/// Provedores de login social suportados (ver [SocialAuthService]) —
/// Facebook removido em 2026-08-23 (decisão de arquitetura). Usado só
/// para saber QUAL botão mostra o spinner de carregamento na
/// [LoginScreen], já que os 2 ficam desabilitados juntos durante qualquer
/// autenticação em andamento.
enum _ProvedorSocial { google, apple }

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
/// Login social (Google/Apple, ver [SocialAuthService]) abaixo da opção
/// de e-mail/senha: como são identidades federadas em que o próprio
/// provedor já garante a posse do e-mail, o Firebase marca
/// `emailVerified == true` automaticamente nessas contas — a barreira de
/// e-mail verificado acima é específica do cadastro por e-mail/senha
/// (onde o Firebase NÃO garante isso sozinho) e não se aplica aqui.
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

  /// Provedor social com autenticação em andamento no momento (`null` se
  /// nenhum) — controla tanto QUAL botão mostra o spinner quanto o
  /// desabilitar dos 3 botões (e do botão "Entrar" padrão) enquanto dura.
  _ProvedorSocial? _provedorSocialCarregando;

  /// Verdadeiro durante QUALQUER autenticação em andamento (e-mail/senha
  /// OU social) — usado para desabilitar todos os botões de login juntos,
  /// evitando dois fluxos de autenticação concorrentes.
  bool get _autenticando => _fazendoLogin || _provedorSocialCarregando != null;

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

      // CORREÇÃO (Bug de entrega): a política "Opção A" desloga a sessão
      // a cada cold start (ver `main.dart`), então o único momento em que
      // sabemos o `uid` correto é logo após um login bem-sucedido como
      // este — [_finalizarLoginComSucesso] sincroniza aqui os contatos de
      // emergência já cadastrados no SQLite local com
      // `usuarios/{uid}.contatosEmergencia`, sem depender de o usuário
      // editar algo primeiro. Sem isto, a Cloud Function de alerta
      // (`functions/index.js`) podia ler uma lista vazia/desatualizada e
      // não disparar o Push.
      if (!mounted) return;
      await _finalizarLoginComSucesso(viaLoginSocial: false);
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

  /// Ponto único de entrada dos 3 botões sociais — [acao] é o método
  /// correspondente de [SocialAuthService]. Cuida do estado de
  /// carregamento (desabilita os botões, mostra o spinner no botão
  /// certo), do cancelamento pelo usuário (contrato: `null` = cancelado,
  /// sem crash e sem mensagem de erro) e do tratamento de exceções, e no
  /// sucesso segue EXATAMENTE o mesmo caminho pós-login do e-mail/senha
  /// ([_finalizarLoginComSucesso]).
  Future<void> _fazerLoginSocial(
    _ProvedorSocial provedor,
    Future<UserCredential?> Function() acao,
  ) async {
    if (_autenticando) return;

    setState(() => _provedorSocialCarregando = provedor);
    try {
      final credencial = await acao();
      if (credencial == null) {
        // Cancelado pelo usuário (fechou o seletor de conta/diálogo) —
        // não é erro, não mostra mensagem nenhuma.
        return;
      }
      if (!mounted) return;
      await _finalizarLoginComSucesso(viaLoginSocial: true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_mensagemErroLoginSocial(e)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
    } catch (e) {
      debugPrint('⚠️ [LoginScreen] Falha inesperada no login social ($provedor): $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.erroLoginGenerico),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _provedorSocialCarregando = null);
    }
  }

  /// Mensagens específicas para os códigos de [FirebaseAuthException] mais
  /// relevantes ao login social — os 3 provedores (Google/Apple) chegam
  /// aqui pelo mesmo caminho ([_fazerLoginSocial]), então cobre os casos
  /// comuns aos três em vez de duplicar por provedor. Qualquer código não
  /// listado (ou qualquer exceção que não seja [FirebaseAuthException] —
  /// ex: falha nativa do Google Sign-In/Credential Manager antes mesmo de
  /// chegar ao Firebase, tratada pelo `catch` genérico de
  /// [_fazerLoginSocial]) cai no texto genérico.
  String _mensagemErroLoginSocial(FirebaseAuthException e) {
    final l10n = AppLocalizations.of(context)!;
    switch (e.code) {
      case 'account-exists-with-different-credential':
        return l10n.loginSocialContaExistente;
      case 'invalid-credential':
        return l10n.loginSocialCredencialInvalida;
      case 'user-disabled':
        return l10n.erroLoginContaDesabilitada;
      case 'network-request-failed':
        return l10n.erroLoginSemConexao;
      case 'too-many-requests':
        return l10n.erroLoginMuitasTentativas;
      case 'operation-not-allowed':
        return l10n.loginSocialProvedorIndisponivel;
      default:
        return l10n.erroLoginGenerico;
    }
  }

  /// Passos comuns pós-login bem-sucedido, compartilhados entre o login
  /// por e-mail/senha ([_fazerLogin], `viaLoginSocial: false`) e os 3
  /// sociais ([_fazerLoginSocial], `viaLoginSocial: true`): inicializa o
  /// FCM, sincroniza os contatos de emergência locais com o Firestore
  /// (ver comentário original em [_fazerLogin]), grava nome/e-mail do
  /// login social em `usuarios/{uid}` (ver
  /// [FirebaseSyncService.sincronizarPerfilSocial] — no-op inofensivo
  /// para o login por e-mail/senha, que já grava isso via
  /// [CadastroScreen]).
  ///
  /// DECISÃO DE ARQUITETURA (2026-08-23): quando [viaLoginSocial] é
  /// `true` E a conta ainda não tem `usuarios/{uid}.telefone` gravado
  /// (nenhum dos provedores sociais devolve telefone por padrão), o fluxo
  /// é desviado para [CompletarPerfilScreen] (telefone como campo de
  /// perfil comum, sem SMS OTP — substituiu `VerificacaoTelefoneScreen`)
  /// ANTES de qualquer outra coisa — inclusive antes do Assistente de
  /// Configuração Inicial. Só depois do telefone salvo (ou já existente)
  /// é que [_decidirProximaTelaAposLogin] decide entre Onboarding e o
  /// fluxo principal.
  Future<void> _finalizarLoginComSucesso({required bool viaLoginSocial}) async {
    unawaited(FcmService().inicializar());
    unawaited(ContatosEmergenciaService.sincronizarAgora());
    unawaited(FirebaseSyncService().sincronizarPerfilSocial(
      nome: FirebaseAuthService().usuarioAtual?.displayName,
      email: FirebaseAuthService().usuarioAtual?.email,
    ));

    if (viaLoginSocial) {
      final telefoneAtual = await FirebaseSyncService().obterTelefoneAtual();
      final possuiTelefone = telefoneAtual != null && telefoneAtual.trim().isNotEmpty;
      if (!possuiTelefone) {
        appNavigatorKey.currentState?.pushReplacement(
          MaterialPageRoute(
            builder: (context) =>
                CompletarPerfilScreen(aoConcluir: _decidirProximaTelaAposLogin),
          ),
        );
        return;
      }
    }

    await _decidirProximaTelaAposLogin();
  }

  /// Decide entre o Assistente de Configuração Inicial
  /// ([OnboardingScreen], se ainda não concluído nesta instalação — ver
  /// [OnboardingService]) e o fluxo principal direto
  /// ([_navegarParaFluxoPrincipal]). Extraído de [_finalizarLoginComSucesso]
  /// para ser reutilizável como o callback `aoConcluir` de
  /// [CompletarPerfilScreen] — por isso usa [appNavigatorKey] (nunca
  /// `Navigator.of(context)`/`mounted` desta State): quando chamado a
  /// partir de lá (ou do próprio [OnboardingScreen] mais adiante),
  /// `_LoginScreenState` já foi substituída/descartada havia muito tempo
  /// (mesmo raciocínio já documentado em [_navegarParaFluxoPrincipal]).
  Future<void> _decidirProximaTelaAposLogin() async {
    final onboardingConcluido = await OnboardingService().jaConcluido();

    if (onboardingConcluido) {
      _navegarParaFluxoPrincipal();
    } else {
      appNavigatorKey.currentState?.pushReplacement(
        MaterialPageRoute(
          builder: (context) => OnboardingScreen(aoConcluir: _navegarParaFluxoPrincipal),
        ),
      );
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
      case 'user-disabled':
        return AppLocalizations.of(context)!.erroLoginContaDesabilitada;
      case 'network-request-failed':
        return AppLocalizations.of(context)!.erroLoginSemConexao;
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

  /// Navega para o fluxo principal SEMPRE (login concluído normalmente —
  /// nenhuma exceção à barreira de autenticação, ver política de segurança
  /// em `main.dart`). A ÚNICA diferença quando o app foi aberto por uma
  /// notificação de solicitação de localização (ver
  /// [NotificacaoService.consumirPayloadSolicitacaoPendente]): em vez de o
  /// usuário precisar navegar manualmente até a aba Monitoramento depois de
  /// logar, o modal de decisão já abre direto por cima da Home.
  ///
  /// CORREÇÃO DE BUG REAL (2026-08-16): usa [appNavigatorKey] (mesmo
  /// padrão já usado por [_abrirModalDecisaoAposLogin] logo abaixo) em vez
  /// de `Navigator.of(context)` — necessário desde que este método passou
  /// a também ser usado como o callback `aoConcluir` de [OnboardingScreen]
  /// (ver `_finalizarLoginComSucesso`): quando chamado a partir de lá,
  /// `_LoginScreenState` (e seu `context`) já foi DESCARTADO havia muito
  /// tempo (a troca de rota `pushReplacement` para o Assistente já
  /// aconteceu antes, e o usuário pode levar minutos decidindo as
  /// permissões) — usar o `context` antigo lançaria
  /// `FlutterError: This widget has been unmounted`. `appNavigatorKey`
  /// aponta para o Navigator RAIZ do app, sempre válido independente de
  /// qual tela specific o chamou.
  void _navegarParaFluxoPrincipal() {
    final payloadPendente = NotificacaoService.consumirPayloadSolicitacaoPendente();

    appNavigatorKey.currentState?.pushReplacement(
      MaterialPageRoute(
        builder: (context) =>
            const TelaInicialComPossivelDialogoPin(aguardandoConfirmacaoPin: false),
      ),
    );

    if (payloadPendente != null) {
      _abrirModalDecisaoAposLogin(payloadPendente);
    }
  }

  void _abrirModalDecisaoAposLogin(Map<String, dynamic> dados) {
    final idPermissao = dados['idPermissao'] as String?;
    final uidSolicitante = dados['uidSolicitante'] as String?;
    if (idPermissao == null || uidSolicitante == null) return;

    // A Home recém-empurrada acima ainda não terminou de montar neste ponto
    // — aguarda o próximo frame antes de usar o contexto do Navigator para
    // abrir o modal por cima dela.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final contextoNavegador = appNavigatorKey.currentContext;
      if (contextoNavegador == null) return;
      exibirDialogoDecisaoMonitoramento(
        context: contextoNavegador,
        idPermissao: idPermissao,
        uidSolicitante: uidSolicitante,
        nomeSolicitante: (dados['nomeSolicitante'] as String?) ?? '',
        telefoneSolicitante: (dados['telefoneSolicitante'] as String?) ?? '',
      );
    });
  }

  /// Abre o modal de recuperação de senha real via Firebase Auth (ver
  /// [RecuperarSenhaDialog]) — reespecificação do usuário (2026-08-16):
  /// antes só mostrava um SnackBar de placeholder. Pré-preenche o e-mail
  /// com o que o usuário já tiver digitado no formulário de login.
  void _abrirEsqueciMinhaSenha() {
    showDialog<void>(
      context: context,
      builder: (_) => RecuperarSenhaDialog(emailInicial: _emailController.text),
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
                  const SizedBox(height: 28),
                  _buildDivisorLoginSocial(),
                  const SizedBox(height: 20),
                  _buildBotoesLoginSocial(),
                  const SizedBox(height: 8),
                  _buildBotaoLimparSessao(),
                  const SizedBox(height: 12),
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
        onPressed: _autenticando ? null : _fazerLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: _corPrincipal,
          foregroundColor: Colors.white,
          disabledBackgroundColor: _corPrincipal.withOpacity(0.5),
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

  /// Divisor "── ou entre com ──" entre o login por e-mail/senha e os
  /// botões de login social, mantendo o tema escuro da tela.
  Widget _buildDivisorLoginSocial() {
    return Row(
      children: [
        const Expanded(child: Divider(color: Colors.white24, thickness: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            AppLocalizations.of(context)!.loginSocialDivisor,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
        const Expanded(child: Divider(color: Colors.white24, thickness: 1)),
      ],
    );
  }

  /// Os 2 botões de login social (Google, Apple — Facebook removido em
  /// 2026-08-23), centralizados lado a lado — círculos escuros com o
  /// ícone da marca, mesmo tema da tela. Desabilitados juntos (ver
  /// [_autenticando]) enquanto qualquer autenticação estiver em
  /// andamento; o botão do provedor em voo mostra um spinner discreto no
  /// lugar do ícone.
  Widget _buildBotoesLoginSocial() {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildBotaoSocial(
          provedor: _ProvedorSocial.google,
          tooltip: l10n.loginSocialGoogleTooltip,
          icone: const FaIcon(FontAwesomeIcons.google, color: Color(0xFFEA4335), size: 22),
          onPressed: () => _fazerLoginSocial(
            _ProvedorSocial.google,
            SocialAuthService().signInWithGoogle,
          ),
        ),
        const SizedBox(width: 20),
        _buildBotaoSocial(
          provedor: _ProvedorSocial.apple,
          tooltip: l10n.loginSocialAppleTooltip,
          icone: const FaIcon(FontAwesomeIcons.apple, color: Colors.white, size: 24),
          onPressed: () => _fazerLoginSocial(
            _ProvedorSocial.apple,
            SocialAuthService().signInWithApple,
          ),
        ),
      ],
    );
  }

  /// Botão utilitário de diagnóstico/teste — pedido do usuário
  /// (2026-08-10) para conseguir testar o login social do zero sem
  /// reaproveitar uma conta já em cache no aparelho (ver
  /// [SocialAuthService.encerrarSessoesSociais]). Deliberadamente
  /// discreto (texto pequeno, cinza) por não ser um botão de fluxo normal
  /// — só uma ferramenta de teste/depuração.
  Widget _buildBotaoLimparSessao() {
    return Center(
      child: TextButton.icon(
        onPressed: _autenticando ? null : _limparSessaoDeLoginSocial,
        icon: const Icon(Icons.logout, size: 16, color: Colors.white38),
        label: Text(
          AppLocalizations.of(context)!.loginLimparSessaoBotao,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ),
    );
  }

  Future<void> _limparSessaoDeLoginSocial() async {
    await SocialAuthService().encerrarSessoesSociais();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.loginLimparSessaoConfirmacao),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildBotaoSocial({
    required _ProvedorSocial provedor,
    required String tooltip,
    required Widget icone,
    required VoidCallback onPressed,
  }) {
    final bool carregandoEste = _provedorSocialCarregando == provedor;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 52,
        height: 52,
        child: Material(
          color: _corCampoFundo,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _autenticando ? null : onPressed,
            child: Center(
              child: carregandoEste
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(_corAcentoClaro),
                      ),
                    )
                  : Opacity(opacity: _autenticando ? 0.4 : 1, child: icone),
            ),
          ),
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
