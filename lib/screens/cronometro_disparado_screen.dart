import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/alarme_nativo_service.dart';
import '../services/alarme_service.dart';
import '../services/alerta_desarme_service.dart';
import '../services/background_location_heartbeat_service.dart';
import '../services/database_helper.dart';
import '../services/historico_alertas_service.dart';
import '../services/l10n_headless_service.dart';
import '../services/location_service.dart';
import '../services/notificacao_service.dart';
import '../widgets/confirmacao_alerta_emergencia.dart';
import '../widgets/pin_dialog.dart';
import '../services/bloqueio_app_service.dart';

/// Chave (SharedPreferences) sinalizando que o ciclo atual do Cronômetro
/// foi resolvido (PIN correto ou alerta enviado) — sinal entre os dois
/// engines Flutter que podem mostrar esta tela ao mesmo tempo
/// (MainActivity + RotinaCheckinAlarmActivity).
const String chaveCronometroFluxoResolvido = 'cronometro_fluxo_resolvido';

/// Fim do Cronômetro Regressivo, por cima da tela bloqueada (aberta pelo
/// alarme exato nativo, ver `RotinaAlarmWakeService`): o teclado de PIN
/// abre na hora, com 60 s de tolerância e 3 tentativas.
///
/// O SOM é tocado pelo serviço nativo (um único som, o escolhido em
/// Configurações, respeitando o modo silencioso/vibrar) até o PIN correto
/// ou o fim da tolerância — esta tela não toca nada.
///
/// - PIN correto: nada é enviado; a ocorrência é marcada como resolvida NO
///   NATIVO (o fechamento forçado nunca mais dispara para ela), o som para
///   e aparece a notificação "Senha correta. O alerta de emergência não
///   foi enviado."
/// - 3 PINs errados: o teclado fecha na hora e o alerta
///   (`tentativa_desarme_incorreto`) é enviado; a confirmação e a
///   notificação citam as 3 tentativas.
/// - Tempo esgotado: alerta `cronometro_expirado`.
/// - App removido dos Recentes durante o alerta: alerta de fechamento
///   forçado (só se a ocorrência ainda não estava resolvida).
class CronometroDisparadoScreen extends StatefulWidget {
  final bool veioDoForeground;
  const CronometroDisparadoScreen({super.key, this.veioDoForeground = false});

  @override
  State<CronometroDisparadoScreen> createState() =>
      _CronometroDisparadoScreenState();
}

// Emergência: funciona sem desbloquear o app (ver BloqueioAppService).
class _CronometroDisparadoScreenState extends State<CronometroDisparadoScreen>
    with LiberaBloqueioEnquantoAberta<CronometroDisparadoScreen> {
  bool _dialogoPinAberto = false;
  bool _alertaJaProcessado = false;
  bool _fluxoEncerrado = false;

  /// Texto da confirmação depois do alerta (`null` = ainda não houve).
  String? _mensagemAlerta;

  /// Fim (epoch ms) do ciclo exibido e o prazo da tolerância.
  int? _fimCiclo;
  int? _prazo;

  Timer? _pollFluxoResolvidoTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_iniciar());
  }

  Future<void> _iniciar() async {
    final ocorrencia = await AlarmeNativoService.ocorrenciaDaTela();
    _fimCiclo = (ocorrencia != null && ocorrencia.ehCronometro)
        ? ocorrencia.ciclo
        : await AlarmeService().fimDoCicloAtual();
    if (_fimCiclo == null) {
      _fecharTela();
      return;
    }
    _prazo = (ocorrencia != null && ocorrencia.ehCronometro)
        ? ocorrencia.prazo
        : _fimCiclo! + AlarmeService.duracaoJanelaFinalCronometro.inMilliseconds;
    final chave = AlarmeService.chaveOcorrencia(_fimCiclo!);
    if (!mounted) return;

    // App removido dos Recentes com o alerta em andamento — o nativo só
    // devolve `true` se a ocorrência AINDA não foi resolvida.
    if (await AlarmeNativoService.consumirFechamentoForcado(chave)) {
      final l10n = await L10nHeadlessService.obter();
      await _dispararAlerta(
        tipo: TipoAlertaHistorico.tentativaDesarmeIncorreto,
        titulo: l10n.historicoTipoTentativaDesarme,
        motivo: l10n.historicoCronometroFechamentoForcadoMotivo,
        confirmacao: l10n.confirmacaoFechamentoForcadoCronometro,
      );
      return;
    }
    if (await AlarmeNativoService.estaResolvida(chave)) {
      _fecharTela();
      return;
    }

    _iniciarPollingDeFluxoResolvido();
    WidgetsBinding.instance.addPostFrameCallback((_) => _abrirTecladoPin());
  }

  @override
  void dispose() {
    _pollFluxoResolvidoTimer?.cancel();
    super.dispose();
  }

  /// O outro engine resolveu o ciclo: fecha em silêncio.
  void _iniciarPollingDeFluxoResolvido() {
    _pollFluxoResolvidoTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _fluxoEncerrado) {
        timer.cancel();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (prefs.getBool(chaveCronometroFluxoResolvido) ?? false) {
        _fluxoEncerrado = true;
        timer.cancel();
        if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
          _dialogoPinAberto = false;
        }
        _fecharTela();
      }
    });
  }

  int _segundosRestantes() {
    final prazo = _prazo;
    if (prazo == null) return AlarmeService.duracaoJanelaFinalCronometro.inSeconds;
    final restante = ((prazo - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    return restante.clamp(0, AlarmeService.duracaoJanelaFinalCronometro.inSeconds);
  }

  Future<void> _abrirTecladoPin() async {
    try {
      final config = await DatabaseHelper().getUserConfig();
      final pinGravado = config?['pin_real'] as String?;
      if (!mounted) return;

      final restantes = _segundosRestantes();
      if (restantes <= 0) {
        await _aoEsgotarTempoLimite();
        return;
      }

      _dialogoPinAberto = true;
      await exibirDialogoPin(
        context: context,
        pinEsperado: pinGravado,
        limiteErrosConsecutivos: 3,
        segundosLimiteDuro: restantes,
        aoAtingirLimiteDeErros: _aoAtingirTerceiraSenhaErrada,
        aoExpirarTempoLimite: _aoEsgotarTempoLimite,
        mensagemSucesso: AppLocalizations.of(context)!.notifPinCorretoCronometroCorpo,
        aoConfirmarPinCorreto: () async {
          _dialogoPinAberto = false;
          _fluxoEncerrado = true;
          _pollFluxoResolvidoTimer?.cancel();
          await _confirmarDesarme();
          if (!mounted) return;
          _fecharTela();
        },
      );
      _dialogoPinAberto = false;
      // Teclado fechado sem PIN e sem alerta: reabre (o tempo segue).
      if (!_fluxoEncerrado && !_alertaJaProcessado && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _abrirTecladoPin());
      }
    } catch (e) {
      debugPrint('⚠️ Erro no fluxo de PIN do cronômetro: $e');
      _dialogoPinAberto = false;
    }
  }

  /// PIN correto: resolve a ocorrência no nativo (som parado, tela cheia
  /// cancelada, fechamento forçado neutralizado), confirma o ciclo na nuvem
  /// e registra o desarme (com localização) na área protegida.
  Future<void> _confirmarDesarme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(chaveCronometroFluxoResolvido, true);
      final config = await DatabaseHelper().getUserConfig();
      final contexto = (config?['contexto_timer_ativo'] as String?) ?? '';

      await AlarmeService().cancelarAlarme();
      await BackgroundLocationHeartbeatService().confirmarCheckinSeguro();
      await DatabaseHelper().limparContextoTimerAtivo();

      final l10n = await L10nHeadlessService.obter();
      final posicao = await LocationService().posicaoRecente();
      await HistoricoAlertasService().registrarEvento(
        tipo: TipoAlertaHistorico.cronometroDesarmado,
        titulo: l10n.historicoCheckinDesarmadoTitulo,
        descricao: l10n.historicoCheckinDesarmadoDescricao,
        contexto: contexto,
        latitude: posicao?.latitude,
        longitude: posicao?.longitude,
        precisao: posicao?.accuracy,
      );
      await NotificacaoService.exibirNotificacaoInformativa(
        id: 70050,
        titulo: l10n.cronometroNotificacaoTituloAlerta,
        corpo: l10n.notifPinCorretoCronometroCorpo,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao confirmar desarme do cronômetro: $e');
    }
  }

  Future<void> _aoAtingirTerceiraSenhaErrada() async {
    // O teclado fecha NA HORA.
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
    }
    final l10n = await L10nHeadlessService.obter();
    await _dispararAlerta(
      tipo: TipoAlertaHistorico.tentativaDesarmeIncorreto,
      titulo: l10n.historicoTipoTentativaDesarme,
      motivo: l10n.historicoCronometroPinIncorretoMotivo,
      confirmacao: l10n.notif3PinsCronometroCorpo,
    );
  }

  Future<void> _aoEsgotarTempoLimite() async {
    final l10n = await L10nHeadlessService.obter();
    await _dispararAlerta(
      tipo: TipoAlertaHistorico.cronometroExpirado,
      titulo: l10n.historicoTipoCronometroExpirado,
      motivo: l10n.historicoCronometroFalhaMotivo,
      confirmacao: l10n.notifCronometroExpiradoCorpo,
    );
  }

  /// Alerta REAL (uma vez por ciclo, mesmo com dois engines abertos):
  /// histórico + Firestore + SMS com o tipo correto, o texto do usuário e a
  /// posição; o ciclo é encerrado no nativo e na nuvem.
  Future<void> _dispararAlerta({
    required String tipo,
    required String titulo,
    required String motivo,
    required String confirmacao,
  }) async {
    if (_alertaJaProcessado) return;
    _alertaJaProcessado = true;

    if (!await AlarmeService().reivindicarDisparoUnicoCronometro()) {
      debugPrint('🚫 [CRONÔMETRO] Outro engine já disparou este ciclo.');
      return;
    }
    _fluxoEncerrado = true;
    _pollFluxoResolvidoTimer?.cancel();
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
    }
    if (mounted) setState(() => _mensagemAlerta = confirmacao);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(chaveCronometroFluxoResolvido, true);
    } catch (_) {}

    final config = await DatabaseHelper().getUserConfig();
    final contexto = (config?['contexto_timer_ativo'] as String?) ?? '';
    final eventoId = _fimCiclo != null ? 'cronometro_$_fimCiclo' : null;

    // Som parado e ocorrência resolvida antes da rede (que pode demorar).
    await AlarmeService().cancelarAlarme();
    unawaited(BackgroundLocationHeartbeatService().confirmarAlertaJaDisparado());

    try {
      await AlertaDesarmeService.disparar(
        tipo: tipo,
        titulo: titulo,
        motivo: motivo,
        contexto: contexto,
        eventoId: eventoId,
      );
    } catch (e) {
      debugPrint('⚠️ [CRONÔMETRO] Falha ao disparar o alerta: $e');
    }
    await DatabaseHelper().limparContextoTimerAtivo();
    final l10n = await L10nHeadlessService.obter();
    await NotificacaoService.exibirNotificacaoAlertaEnviado(
      titulo: l10n.cronometroNotificacaoTituloAlerta,
      corpo: confirmacao,
    );
  }

  void _fecharTela() {
    if (!mounted) return;
    if (widget.veioDoForeground) {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    } else {
      SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_mensagemAlerta != null) {
      return ConfirmacaoAlertaEmergencia(mensagem: _mensagemAlerta, aoFechar: _fecharTela);
    }
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: SafeArea(
          child: Stack(
            children: [
              const Center(
                child: Icon(
                  Icons.security_rounded,
                  color: Color(0x40FF5252),
                  size: 140,
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Text(
                    AppLocalizations.of(context)!.cronometroNotificacaoCorpo,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
