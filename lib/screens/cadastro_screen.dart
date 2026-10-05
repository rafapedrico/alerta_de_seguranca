import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import '../services/firebase_auth_service.dart';
import '../services/firebase_sync_service.dart';
import '../services/indicacao_service.dart';
import '../utils/mensagens_erro_auth.dart';
import '../utils/telefone_utils.dart';
import '../widgets/campo_codigo_indicacao.dart';
import 'verificar_email_screen.dart';

/// Tela de Cadastro (primeiro acesso) do "SOS Security Personal".
///
/// Cria a conta real no Firebase Auth (e-mail/senha), grava o perfil
/// inicial em `usuarios/{uid}` (nome, e-mail, telefone em E.164) via
/// [FirebaseSyncService] e envia o e-mail de verificação.
/// `createUserWithEmailAndPassword` autentica automaticamente o usuário
/// recém-criado — essa sessão é MANTIDA (nunca encerrada aqui) e a tela
/// avança para [VerificarEmailScreen], que decide o que fazer com ela a
/// partir daí: só ela pode reenviar o e-mail, confirmar a verificação (e
/// então seguir DIRETO para o app, sem pedir login de novo) ou desistir
/// (aí sim encerrando a sessão e voltando ao Login) — nunca esta tela.
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
  final _codigoIndicacaoController = TextEditingController();

  /// Campo opcional "Tem um código de indicação?" aberto.
  bool _mostrarCodigoIndicacao = false;

  /// Código que veio do Install Referrer (link do site), se houver.
  String? _codigoDoReferrer;

  bool _senhaVisivel = false;
  bool _confirmarSenhaVisivel = false;
  bool _criandoConta = false;

  @override
  void initState() {
    super.initState();
    _preencherCodigoDoReferrer();
  }

  Future<void> _preencherCodigoDoReferrer() async {
    final codigo = await IndicacaoService().codigoDoReferrerGuardado();
    if (!mounted || codigo == null) return;
    setState(() {
      _codigoDoReferrer = codigo;
      _mostrarCodigoIndicacao = true;
      if (_codigoIndicacaoController.text.isEmpty) _codigoIndicacaoController.text = codigo;
    });
  }

  /// Vincula a conta recém-criada ao código de indicação, se informado.
  /// Nunca trava o cadastro: tem teto de tempo e a recusa só vira aviso.
  /// O código do Install Referrer, mantido como veio, sai com a origem
  /// `play_referrer` (o mesmo envio único de [IndicacaoService]).
  Future<String?> _registrarCodigoIndicacao(AppLocalizations l10n) async {
    final codigo = _codigoIndicacaoController.text.trim();
    if (codigo.isEmpty) return null;
    final servico = IndicacaoService();
    final doReferrer = _codigoDoReferrer != null &&
        IndicacaoService.normalizarCodigo(codigo) == _codigoDoReferrer;
    MotivoIndicacao? motivo;
    try {
      motivo = await (doReferrer
              ? servico.enviarReferrerSePendente()
              : servico.registrar(codigo, origem: IndicacaoService.origemDigitado))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      motivo = MotivoIndicacao.erro;
    }
    return motivo == null ? null : mensagemMotivoIndicacao(l10n, motivo);
  }

  @override
  void dispose() {
    _codigoIndicacaoController.dispose();
    _nomeController.dispose();
    _emailController.dispose();
    _celularController.dispose();
    _senhaController.dispose();
    _confirmarSenhaController.dispose();
    super.dispose();
  }

  /// Cria a conta real no Firebase Auth, grava o perfil inicial no
  /// Firestore e envia o e-mail de verificação — depois avança para
  /// [VerificarEmailScreen] (`pushReplacement`, substituindo esta tela na
  /// pilha), mantendo a sessão recém-criada ativa: é a PRÓXIMA tela quem
  /// decide o que fazer com ela dali em diante (reenviar, confirmar e
  /// seguir direto para o app, ou desistir e encerrar a sessão). Em caso
  /// de falha na CRIAÇÃO DA CONTA em si (e-mail já cadastrado, senha
  /// fraca, etc.), exibe o erro e permanece nesta tela.
  Future<void> _criarConta() async {
    if (_formKey.currentState?.validate() != true) return;
    if (_criandoConta) return;

    setState(() => _criandoConta = true);
    // Trocou ou apagou o código do link: o envio automático (assim que a
    // conta for criada) não pode passar na frente do código digitado.
    final referrer = _codigoDoReferrer;
    if (referrer != null &&
        IndicacaoService.normalizarCodigo(_codigoIndicacaoController.text) != referrer) {
      await IndicacaoService().descartarReferrer();
    }
    try {
      final credencial = await FirebaseAuthService().criarConta(
        email: _emailController.text.trim(),
        senha: _senhaController.text,
      );

      final uid = credencial.user?.uid;
      bool telefoneEmUso = false;
      if (uid != null) {
        await FirebaseSyncService().criarPerfilInicial(
          nome: _nomeController.text.trim(),
          email: _emailController.text.trim(),
        );

        // Se chegou até aqui, o validador do campo (ver
        // `_buildCampoCelular`) já garantiu que o número é válido em
        // alguma interpretação internacional razoável — o fallback ao
        // texto bruto é só uma rede de segurança, nunca deve ser
        // efetivamente usado na prática. `telefone` passa OBRIGATORIAMENTE
        // por `salvarTelefonePerfil` (unicidade estrita server-side, ver
        // `telefonePerfilService.js`) — nunca gravado direto por
        // `criarPerfilInicial` (decisão de arquitetura 2026-08-23).
        final resultado = await FirebaseSyncService().salvarTelefonePerfil(
          TelefoneUtils.normalizarE164(_celularController.text.trim()) ??
              _celularController.text.trim(),
        );
        // A conta em si já foi criada nesse ponto mesmo se o telefone
        // colidir com outra conta — não é um estado novo/pior do que já
        // existia para outros abandonos de cadastro (ex: fechar o app
        // antes de confirmar o e-mail); o usuário pode ajustar o telefone
        // depois em Configurações > Meu Perfil assim que confirmar o
        // e-mail e conseguir logar.
        telefoneEmUso = resultado == ResultadoSalvarTelefone.telefoneEmUso;
      }

      // CORREÇÃO DE BUG REAL (2026-09-05, pedido explícito do usuário —
      // "tratamento de erros robusto... limites de envio/throttling"):
      // isolado num try/catch PRÓPRIO, separado do try/catch de
      // `FirebaseAuthException` mais abaixo — a conta e o perfil JÁ foram
      // criados com sucesso neste ponto, então uma falha só ao ENVIAR o
      // e-mail (rede instável, `too-many-requests` do próprio Firebase
      // Auth) NUNCA deve ser reportada como "falha ao criar conta" (que
      // enganaria o usuário a tentar cadastrar de novo um e-mail que já
      // existe). Falha aqui é só um aviso, não um bloqueio — o usuário
      // sempre pode reenviar manualmente na tela seguinte.
      // Código de indicação (opcional) — com a conta já autenticada.
      String? avisoIndicacao;
      if (uid != null && mounted) {
        avisoIndicacao = await _registrarCodigoIndicacao(AppLocalizations.of(context)!);
      }

      String? avisoEnvioEmail;
      try {
        await FirebaseAuthService().enviarEmailVerificacao();
      } on FirebaseAuthException catch (e) {
        if (mounted) {
          avisoEnvioEmail =
              classificarErroEnvioVerificacao(e, AppLocalizations.of(context)!).mensagem;
        }
      } catch (e) {
        debugPrint('⚠️ [CadastroScreen] Falha ao enviar e-mail de verificação: $e');
      }

      if (!mounted) return;
      if (avisoIndicacao != null) {
        // O ScaffoldMessenger é o do app: o aviso continua na tela seguinte.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(avisoIndicacao), behavior: SnackBarBehavior.floating),
        );
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => VerificarEmailScreen(
            email: _emailController.text.trim(),
            avisoEnvioEmail: avisoEnvioEmail,
            avisoTelefoneEmUso: telefoneEmUso,
          ),
        ),
      );
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

  /// Mensagem de erro específica para uma falha no ENVIO do e-mail de
  /// verificação (ver [_criarConta]) — nunca confundida com
  /// [_mensagemErroCadastro] (falha em CRIAR a conta em si).
  /// `too-many-requests` ganha uma mensagem própria e orientativa: o
  /// Firebase Auth também limita a TAXA de envio deste e-mail específico
  /// (não só tentativas de login), então é um erro real e esperado em
  /// testes/reenvios rápidos, nunca um bug.
  String _mensagemErroCadastro(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':
        return AppLocalizations.of(context)!.erroCadastroEmailEmUso;
      case 'weak-password':
        return AppLocalizations.of(context)!.erroCadastroSenhaFraca;
      case 'invalid-email':
        return AppLocalizations.of(context)!.campoEmailInvalido;
      case 'network-request-failed':
        return AppLocalizations.of(context)!.erroCadastroSemConexao;
      case 'operation-not-allowed':
        return AppLocalizations.of(context)!.erroCadastroOperacaoNaoPermitida;
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
                  const SizedBox(height: 12),
                  _buildCampoCodigoIndicacao(),
                  const SizedBox(height: 20),
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

  /// "Tem um código de indicação?" — opcional, fechado até o toque (ou já
  /// aberto e preenchido com o código do link de indicação).
  Widget _buildCampoCodigoIndicacao() {
    final l10n = AppLocalizations.of(context)!;
    if (!_mostrarCodigoIndicacao) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _mostrarCodigoIndicacao = true),
          icon: const Icon(Icons.card_giftcard_outlined, size: 18),
          label: Text(l10n.indicacaoCampoTitulo),
          style: TextButton.styleFrom(foregroundColor: _corAcentoClaro),
        ),
      );
    }
    return TextFormField(
      controller: _codigoIndicacaoController,
      textCapitalization: TextCapitalization.characters,
      textInputAction: TextInputAction.done,
      maxLength: 9,
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: l10n.indicacaoCampoTitulo,
        icone: Icons.card_giftcard_outlined,
      ).copyWith(counterText: '', hintText: l10n.indicacaoCampoDica),
      validator: (valor) {
        if (valor == null || valor.trim().isEmpty) return null;
        return IndicacaoService.formatoValido(valor) ? null : l10n.indicacaoMsgFormato;
      },
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
