import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../app_navigator.dart';
import '../services/database_helper.dart';
import '../services/firebase_auth_service.dart';
import '../services/firebase_sync_service.dart';
import '../utils/telefone_utils.dart';
import 'login_screen.dart';

enum _EtapaOtp { numero, codigo }

/// Tela OBRIGATÓRIA de verificação de telefone por SMS OTP, exibida logo
/// após o PRIMEIRO login social (Google/Facebook/Apple) bem-sucedido
/// quando a conta ainda não tem `usuarios/{uid}.telefone` gravado (ver
/// `LoginScreen._finalizarLoginComSucesso`).
///
/// REESPECIFICAÇÃO DE SEGURANÇA (2026-08-16): fecha o trade-off aceito na
/// correção anterior (campo "Meu número de contato" tornado somente
/// leitura, ver `ConfiguracoesTab`) — contas sociais, que nunca recebem
/// telefone verificado do próprio provedor, agora são obrigadas a provar
/// a posse de um número por SMS ANTES de alcançar o Dashboard, em vez de
/// simplesmente nunca terem telefone algum.
///
/// Fluxo: usuário digita o número -> Firebase envia um código de 6
/// dígitos por SMS -> usuário digita o código -> o código vira uma
/// [PhoneAuthCredential], VINCULADA (nunca substitui) à sessão social já
/// autenticada via [FirebaseAuthService.vincularTelefoneVerificado] — só
/// então o número é gravado em `usuarios/{uid}.telefone` E no cache local
/// (`user_config.telefone`).
///
/// [PopScope] com `canPop: false`: a ÚNICA saída sem completar a
/// verificação é o botão "Sair" (encerra a sessão e volta ao Login) —
/// nunca avança para o Dashboard sem o telefone verificado.
class VerificacaoTelefoneScreen extends StatefulWidget {
  const VerificacaoTelefoneScreen({super.key, required this.aoConcluir});

  /// Chamado exclusivamente após o telefone ser verificado e gravado com
  /// sucesso — decide a PRÓXIMA tela (Onboarding ou Dashboard direto, ver
  /// `LoginScreen._decidirProximaTelaAposLogin`).
  final Future<void> Function() aoConcluir;

  @override
  State<VerificacaoTelefoneScreen> createState() => _VerificacaoTelefoneScreenState();
}

class _VerificacaoTelefoneScreenState extends State<VerificacaoTelefoneScreen> {
  static const Color _corFundo = Color(0xFF14212E);
  static const Color _corCampoFundo = Color(0xFF1E313F);
  static const Color _corAcentoClaro = Color(0xFF9CCC65);

  final _formKeyNumero = GlobalKey<FormState>();
  final _telefoneController = TextEditingController();
  final _codigoController = TextEditingController();

  _EtapaOtp _etapa = _EtapaOtp.numero;
  String? _numeroE164;
  String? _verificationId;
  int? _resendToken;

  bool _enviando = false;
  bool _verificando = false;
  bool _saindo = false;
  String? _erro;

  DateTime? _proximoReenvioLiberadoEm;
  Timer? _timerCooldown;
  int _segundosRestantesReenvio = 0;

  @override
  void dispose() {
    _telefoneController.dispose();
    _codigoController.dispose();
    _timerCooldown?.cancel();
    super.dispose();
  }

  /// Bloqueia o botão "Reenviar código" por 30s — evita spam de SMS (custo
  /// real por mensagem) e satura menos rápido a cota antifraude do
  /// Firebase Phone Auth para o mesmo número/aparelho.
  void _iniciarCooldownReenvio() {
    _timerCooldown?.cancel();
    _proximoReenvioLiberadoEm = DateTime.now().add(const Duration(seconds: 30));
    setState(() => _segundosRestantesReenvio = 30);
    _timerCooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final restante = _proximoReenvioLiberadoEm!.difference(DateTime.now()).inSeconds;
      if (restante <= 0) {
        timer.cancel();
        setState(() => _segundosRestantesReenvio = 0);
      } else {
        setState(() => _segundosRestantesReenvio = restante);
      }
    });
  }

  Future<void> _enviarCodigo() async {
    if (_etapa == _EtapaOtp.numero && _formKeyNumero.currentState?.validate() != true) {
      return;
    }
    final numero = _numeroE164 ?? TelefoneUtils.normalizarE164(_telefoneController.text);
    if (numero == null) return; // já coberto pelo validator, defensivo

    setState(() {
      _enviando = true;
      _erro = null;
      _numeroE164 = numero;
    });

    try {
      await FirebaseAuthService().enviarCodigoVerificacaoTelefone(
        telefone: numero,
        forcarReenvioToken: _resendToken,
        aoCompletarAutomaticamente: (credential) async {
          // Auto-retrieval do Android: o SDK já capturou o SMS sozinho,
          // sem o usuário precisar digitar nada — completa o fluxo direto.
          await _finalizarComCredencial(credential);
        },
        aoFalhar: (e) {
          if (!mounted) return;
          setState(() {
            _enviando = false;
            _erro = _mensagemErroEnvio(e);
          });
        },
        aoEnviarCodigo: (verificationId, resendToken) {
          if (!mounted) return;
          setState(() {
            _enviando = false;
            _verificationId = verificationId;
            _resendToken = resendToken;
            _etapa = _EtapaOtp.codigo;
          });
          _iniciarCooldownReenvio();
        },
        aoExpirarAutoRetrieval: (verificationId) {
          _verificationId = verificationId;
        },
      );
    } catch (e) {
      debugPrint('⚠️ [VerificacaoTelefoneScreen] Falha ao enviar código: $e');
      if (!mounted) return;
      setState(() {
        _enviando = false;
        _erro = AppLocalizations.of(context)!.otpErroGenerico;
      });
    }
  }

  Future<void> _verificarCodigo() async {
    final l10n = AppLocalizations.of(context)!;
    final codigo = _codigoController.text.trim();
    if (codigo.isEmpty) {
      setState(() => _erro = l10n.otpCodigoObrigatorio);
      return;
    }
    if (codigo.length != 6 || _verificationId == null) {
      setState(() => _erro = l10n.otpCodigoInvalido);
      return;
    }

    setState(() {
      _verificando = true;
      _erro = null;
    });

    final credential = PhoneAuthProvider.credential(
      verificationId: _verificationId!,
      smsCode: codigo,
    );
    await _finalizarComCredencial(credential);
  }

  /// Passo final, comum aos dois caminhos possíveis (código digitado
  /// manualmente OU auto-retrieval do Android): vincula a credencial à
  /// sessão social já autenticada e só então grava o número — nunca ao
  /// contrário. Ver [FirebaseAuthService.vincularTelefoneVerificado].
  Future<void> _finalizarComCredencial(PhoneAuthCredential credential) async {
    final numero = _numeroE164;
    if (numero == null) return; // defensivo: nunca deveria acontecer aqui

    try {
      await FirebaseAuthService().vincularTelefoneVerificado(credential);

      final sucessoNuvem = await FirebaseSyncService().gravarTelefoneVerificado(numero);
      try {
        await DatabaseHelper().salvarTelefoneLocal(numero);
      } catch (e) {
        debugPrint('⚠️ [VerificacaoTelefoneScreen] Falha ao gravar telefone no SQLite local: $e');
      }

      if (!mounted) return;

      if (!sucessoNuvem) {
        // O vínculo de autenticação já foi feito com sucesso, mas a
        // gravação no Firestore falhou (ex: sem rede no exato instante).
        // Deixa o usuário tentar de novo em vez de travar aqui — como o
        // número já está vinculado à conta, reenviar o SMS para o MESMO
        // número funciona normalmente numa nova tentativa.
        setState(() {
          _enviando = false;
          _verificando = false;
          _erro = AppLocalizations.of(context)!.otpErroGenerico;
        });
        return;
      }

      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.otpSucessoMensagem),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.green,
        ),
      );
      await widget.aoConcluir();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _enviando = false;
        _verificando = false;
        _erro = _mensagemErroVerificacao(e);
      });
    } catch (e) {
      debugPrint('⚠️ [VerificacaoTelefoneScreen] Falha inesperada ao vincular telefone: $e');
      if (!mounted) return;
      setState(() {
        _enviando = false;
        _verificando = false;
        _erro = AppLocalizations.of(context)!.otpErroGenerico;
      });
    }
  }

  String _mensagemErroEnvio(FirebaseAuthException e) {
    final l10n = AppLocalizations.of(context)!;
    switch (e.code) {
      case 'invalid-phone-number':
        return l10n.campoCelularInvalido;
      case 'too-many-requests':
        return l10n.erroLoginMuitasTentativas;
      default:
        return l10n.otpErroGenerico;
    }
  }

  String _mensagemErroVerificacao(FirebaseAuthException e) {
    final l10n = AppLocalizations.of(context)!;
    switch (e.code) {
      case 'invalid-verification-code':
        return l10n.otpErroCodigoIncorreto;
      case 'session-expired':
      case 'invalid-verification-id':
        return l10n.otpErroCodigoExpirado;
      // `credential-already-in-use`: exatamente o cenário que esta tela
      // existe para barrar — alguém tentando verificar um número que já
      // está vinculado a OUTRA conta (possível tentativa de sequestro de
      // alertas de terceiros, ver documentação em
      // `FirebaseSyncService.obterTelefoneAtual`).
      case 'credential-already-in-use':
      case 'account-exists-with-different-credential':
        return l10n.otpErroNumeroJaEmUso;
      default:
        return l10n.otpErroGenerico;
    }
  }

  void _trocarNumero() {
    setState(() {
      _etapa = _EtapaOtp.numero;
      _codigoController.clear();
      _erro = null;
      _verificationId = null;
      _resendToken = null;
    });
    _timerCooldown?.cancel();
    setState(() => _segundosRestantesReenvio = 0);
  }

  /// Única saída possível sem completar a verificação — encerra a sessão
  /// e volta ao Login. Usa [appNavigatorKey] (não `Navigator.of(context)`)
  /// porque esta tela substitui a própria `LoginScreen` na pilha (ver
  /// `pushReplacement` em `_finalizarLoginComSucesso`) e o app NÃO
  /// escuta `authStateChanges()` para trocar de tela automaticamente
  /// (`_telaInicial()`, em main.dart, só decide uma vez no cold start).
  Future<void> _sair() async {
    setState(() => _saindo = true);
    await FirebaseAuthService().logout();
    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _corFundo,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.sms_outlined, color: _corAcentoClaro, size: 56),
                    const SizedBox(height: 16),
                    Text(
                      l10n.otpTitulo,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _etapa == _EtapaOtp.numero
                          ? l10n.otpIntroducao
                          : l10n.otpCodigoEnviadoPara(_numeroE164 ?? ''),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                    ),
                    const SizedBox(height: 28),
                    if (_etapa == _EtapaOtp.numero)
                      _buildEtapaNumero(l10n)
                    else
                      _buildEtapaCodigo(l10n),
                    if (_erro != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _erro!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: _saindo ? null : _sair,
                      child: Text(
                        l10n.sairDaContaConfirmar,
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEtapaNumero(AppLocalizations l10n) {
    return Form(
      key: _formKeyNumero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _telefoneController,
            keyboardType: TextInputType.phone,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: _decoracaoInput(
              label: l10n.campoCelularLabel,
              icone: Icons.phone_android_outlined,
            ),
            validator: (valor) {
              if (valor == null || valor.trim().isEmpty) {
                return l10n.campoCelularObrigatorio;
              }
              if (TelefoneUtils.normalizarE164(valor) == null) {
                return l10n.campoCelularInvalido;
              }
              return null;
            },
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _enviando ? null : _enviarCodigo,
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            child: _enviando
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(l10n.otpBotaoEnviarCodigo),
          ),
        ],
      ),
    );
  }

  Widget _buildEtapaCodigo(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _codigoController,
          keyboardType: TextInputType.number,
          autofocus: true,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 22, letterSpacing: 8),
          decoration: _decoracaoInput(
            label: l10n.otpCampoCodigoLabel,
            icone: Icons.password_outlined,
          ).copyWith(counterText: ''),
          onSubmitted: (_) {
            if (!_verificando) _verificarCodigo();
          },
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _verificando ? null : _verificarCodigo,
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          child: _verificando
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text(l10n.otpBotaoVerificar),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: _trocarNumero,
              child:
                  Text(l10n.otpBotaoTrocarNumero, style: const TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: _segundosRestantesReenvio > 0 ? null : _enviarCodigo,
              child: Text(
                _segundosRestantesReenvio > 0
                    ? '${l10n.otpBotaoReenviarCodigo} (${_segundosRestantesReenvio}s)'
                    : l10n.otpBotaoReenviarCodigo,
                style: TextStyle(
                  color: _segundosRestantesReenvio > 0 ? Colors.white38 : _corAcentoClaro,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  InputDecoration _decoracaoInput({required String label, required IconData icone}) {
    final borda = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    );
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white70),
      prefixIcon: Icon(icone, color: Colors.white70),
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
