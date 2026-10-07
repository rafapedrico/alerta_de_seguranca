import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../models/alarme_rotina.dart';
import '../services/alarme_nativo_service.dart';
import '../services/alerta_desarme_service.dart';
import '../services/bloqueio_app_service.dart';
import '../services/database_helper.dart';
import '../services/historico_alertas_service.dart';
import '../services/l10n_headless_service.dart';
import '../services/notificacao_service.dart';
import '../services/rotina_alarme_service.dart';
import '../widgets/confirmacao_alerta_emergencia.dart';
import '../widgets/pin_dialog.dart';
import 'cronometro_disparado_screen.dart';

/// Tela do despertador tocando (aba Família), por cima da tela bloqueada —
/// aberta pelo serviço nativo (`RotinaAlarmWakeService`), que toca o som
/// escolhido em loop (como um despertador, mesmo no silencioso) até o PIN
/// correto ou o fim da tolerância.
///
/// - Botão "Desativar despertador" (também na notificação, que abre direto
///   no teclado) → teclado de PIN com o tempo até o fim da tolerância.
/// - PIN correto: o som para e aparece "Despertador desativado (pausado)";
///   o ciclo vira CONFIRMADO_SEGURA e só então a próxima ocorrência é
///   armada.
/// - 3 PINs errados: o teclado fecha na hora, o alerta é enviado e aparece
///   a notificação "Um alerta de emergência foi enviado aos seus contatos
///   cadastrados."
/// - Sem ação: o alerta sai EXATAMENTE no fim da tolerância (sem janela
///   extra de "última chance").
/// - Arrastar a tela para cima não conta como falha.
/// - Vários despertadores ao mesmo tempo: um de cada vez; resolver um nunca
///   fecha nem silencia o outro.
class AlarmeDisparadoScreen extends StatefulWidget {
  final bool veioDoForeground;
  const AlarmeDisparadoScreen({super.key, this.veioDoForeground = false});

  @override
  State<AlarmeDisparadoScreen> createState() => _AlarmeDisparadoScreenState();
}

// Emergência: funciona sem desbloquear o app (ver BloqueioAppService).
class _AlarmeDisparadoScreenState extends State<AlarmeDisparadoScreen>
    with LiberaBloqueioEnquantoAberta<AlarmeDisparadoScreen> {
  static const EventChannel _eventos =
      EventChannel('com.example.security_check_app/rotina_alarme_events');

  OcorrenciaAlarme? _ocorrencia;
  AlarmeRotina? _alarme;

  /// Chaves já resolvidas nesta tela (nunca reexibidas).
  final Set<String> _resolvidas = {};

  bool _dialogoPinAberto = false;
  bool _processando = false;
  String? _mensagemAlerta;
  Timer? _timerPrazo;
  Timer? _timerRelogio;
  StreamSubscription<dynamic>? _assinaturaEventos;

  @override
  void initState() {
    super.initState();
    _assinaturaEventos = _eventos.receiveBroadcastStream().listen(_aoNovoIntent, onError: (_) {});
    unawaited(_carregar(preferida: null));
  }

  @override
  void dispose() {
    _timerPrazo?.cancel();
    _timerRelogio?.cancel();
    _assinaturaEventos?.cancel();
    super.dispose();
  }

  /// A Activity já aberta recebeu outro Intent (nova ocorrência ou o botão
  /// "Desativar despertador" da notificação).
  void _aoNovoIntent(dynamic dados) {
    final nova = OcorrenciaAlarme.deMapa(dados);
    if (nova == null || !mounted) return;
    if (nova.ehCronometro) {
      if (_ocorrencia == null) _abrirCronometro();
      return;
    }
    if (_ocorrencia?.chave == nova.chave) {
      if (nova.abrirTeclado && _mensagemAlerta == null) _abrirTecladoPin();
      return;
    }
    // Outra ocorrência: aparece depois da atual (um de cada vez).
    if (_ocorrencia == null) unawaited(_carregar(preferida: nova));
  }

  /// Escolhe a ocorrência a exibir: a do Intent (se ainda pendente) ou a
  /// mais antiga em andamento; nenhuma → cronômetro pendente ou fecha.
  Future<void> _carregar({OcorrenciaAlarme? preferida}) async {
    final daTela = preferida ?? await AlarmeNativoService.ocorrenciaDaTela();
    final pendentes = await AlarmeNativoService.pendentes();
    final agora = DateTime.now().millisecondsSinceEpoch;
    OcorrenciaAlarme? escolhida;
    bool abrirTeclado = false;
    if (daTela != null &&
        !daTela.ehCronometro &&
        !_resolvidas.contains(daTela.chave) &&
        pendentes.any((p) => p.chave == daTela.chave)) {
      escolhida = pendentes.firstWhere((p) => p.chave == daTela.chave);
      abrirTeclado = daTela.abrirTeclado;
    } else {
      for (final p in pendentes) {
        if (p.ehCronometro || _resolvidas.contains(p.chave)) continue;
        if (p.prazo + 5 * 60 * 1000 < agora) continue;
        escolhida = p;
        break;
      }
    }
    if (!mounted) return;
    if (escolhida == null) {
      if (pendentes.any((p) => p.ehCronometro)) {
        _abrirCronometro();
      } else {
        _fecharTela();
      }
      return;
    }

    final dados = await DatabaseHelper().buscarAlarmePorId(escolhida.id);
    if (!mounted) return;
    setState(() {
      _ocorrencia = escolhida;
      _alarme = dados != null ? AlarmeRotina.fromMap(dados) : null;
      _mensagemAlerta = null;
      _processando = false;
    });
    try {
      await DatabaseHelper().marcarUltimoDisparo(escolhida.id, escolhida.ciclo);
    } catch (_) {}
    unawaited(RotinaAlarmeService.agendarBackupFimTolerancia(escolhida));

    // App removido dos Recentes com este despertador tocando (o nativo só
    // devolve `true` se ainda não estava resolvido).
    if (await AlarmeNativoService.consumirFechamentoForcado(escolhida.chave)) {
      final l10n = await L10nHeadlessService.obter();
      await _dispararAlerta(
        tipo: TipoAlertaHistorico.tentativaDesarmeIncorreto,
        titulo: l10n.historicoTipoTentativaDesarme,
        motivo: l10n.historicoCheckinRotinaFechamentoForcadoMotivo(_etiqueta(l10n)),
      );
      return;
    }

    _armarPrazo(escolhida);
    if (abrirTeclado) WidgetsBinding.instance.addPostFrameCallback((_) => _abrirTecladoPin());
  }

  void _armarPrazo(OcorrenciaAlarme ocorrencia) {
    _timerPrazo?.cancel();
    _timerRelogio?.cancel();
    final restanteMs = ocorrencia.prazo - DateTime.now().millisecondsSinceEpoch;
    _timerPrazo = Timer(Duration(milliseconds: restanteMs.clamp(0, 1 << 31)), _aoFimDaTolerancia);
    _timerRelogio = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  String _etiqueta(AppLocalizations l10n) =>
      _alarme?.etiquetaExibida(l10n) ?? l10n.familiaEtiquetaPadrao;

  int _segundosRestantes() {
    final o = _ocorrencia;
    if (o == null) return 0;
    return ((o.prazo - DateTime.now().millisecondsSinceEpoch) / 1000).ceil().clamp(0, 1 << 30);
  }

  Future<void> _abrirTecladoPin() async {
    final ocorrencia = _ocorrencia;
    if (ocorrencia == null || _dialogoPinAberto || _processando || _mensagemAlerta != null) return;
    final config = await DatabaseHelper().getUserConfig();
    final pinGravado = config?['pin_real'] as String?;
    if (!mounted) return;
    final restantes = _segundosRestantes();
    if (restantes <= 0) {
      await _aoFimDaTolerancia();
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    _dialogoPinAberto = true;
    await exibirDialogoPin(
      context: context,
      pinEsperado: pinGravado,
      limiteErrosConsecutivos: 3,
      segundosLimiteDuro: restantes,
      mensagemSucesso: l10n.despertadorDesativadoPausado,
      aoAtingirLimiteDeErros: () => _aoTerceiraSenhaErrada(ocorrencia),
      aoExpirarTempoLimite: _aoFimDaTolerancia,
      aoConfirmarPinCorreto: () async {
        _dialogoPinAberto = false;
        await _aoPinCorreto(ocorrencia);
      },
    );
    _dialogoPinAberto = false;
  }

  Future<void> _aoPinCorreto(OcorrenciaAlarme ocorrencia) async {
    if (_processando) return;
    _processando = true;
    _timerPrazo?.cancel();
    _resolvidas.add(ocorrencia.chave);
    await RotinaAlarmeService.confirmarDesativacao(ocorrencia);
    if (!mounted) return;
    _ocorrencia = null;
    await _proximaOuFechar();
  }

  Future<void> _aoTerceiraSenhaErrada(OcorrenciaAlarme ocorrencia) async {
    // O teclado fecha NA HORA.
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
    }
    final l10n = await L10nHeadlessService.obter();
    await _dispararAlerta(
      tipo: TipoAlertaHistorico.tentativaDesarmeIncorreto,
      titulo: l10n.historicoTipoTentativaDesarme,
      motivo: l10n.historicoCheckinRotinaPinIncorretoMotivo(_etiqueta(l10n)),
    );
  }

  /// Fim da tolerância sem PIN: o alerta sai agora.
  Future<void> _aoFimDaTolerancia() async {
    if (_ocorrencia == null) return;
    final l10n = await L10nHeadlessService.obter();
    await _dispararAlerta(
      tipo: TipoAlertaHistorico.despertadorExpirado,
      titulo: l10n.historicoTipoDespertadorExpirado,
      motivo: l10n.historicoCheckinRotinaFalhaMotivo(_etiqueta(l10n)),
    );
  }

  Future<void> _dispararAlerta({
    required String tipo,
    required String titulo,
    required String motivo,
  }) async {
    final ocorrencia = _ocorrencia;
    if (ocorrencia == null || _processando) return;
    _processando = true;
    _timerPrazo?.cancel();
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
    }
    _resolvidas.add(ocorrencia.chave);
    final l10n = await L10nHeadlessService.obter();
    if (mounted) setState(() => _mensagemAlerta = l10n.despertadorNotif3ErrosCorpo);

    // O backup do fim da tolerância não dispara de novo.
    await RotinaAlarmeService.marcarResolvidoLocal(ocorrencia.chave);
    try {
      await AlertaDesarmeService.disparar(
        tipo: tipo,
        titulo: titulo,
        motivo: motivo,
        contexto: _alarme?.contextoPersonalizado,
        eventoId: 'rotina_${ocorrencia.id}_${ocorrencia.ciclo}',
      );
    } catch (e) {
      debugPrint('⚠️ [DESPERTADOR] Falha ao disparar o alerta: $e');
    }
    await RotinaAlarmeService.registrarAlertaEnviado(ocorrencia);
    await NotificacaoService.exibirNotificacaoAlertaEnviado(
      titulo: _etiqueta(l10n),
      corpo: l10n.despertadorNotif3ErrosCorpo,
    );
  }

  /// Depois de resolver: o próximo despertador em andamento (um de cada
  /// vez), o cronômetro, ou fecha.
  Future<void> _proximaOuFechar() async {
    _timerRelogio?.cancel();
    setState(() {
      _ocorrencia = null;
      _mensagemAlerta = null;
    });
    await _carregar(preferida: null);
  }

  void _abrirCronometro() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => CronometroDisparadoScreen(veioDoForeground: widget.veioDoForeground)),
    );
  }

  void _fecharTela() {
    if (!mounted) return;
    if (widget.veioDoForeground) {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    } else {
      AlarmeNativoService.fecharTela();
      SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_mensagemAlerta != null) {
      return ConfirmacaoAlertaEmergencia(
        mensagem: _mensagemAlerta,
        aoFechar: () => unawaited(_proximaOuFechar()),
      );
    }
    final ocorrencia = _ocorrencia;
    final horario = ocorrencia != null
        ? TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ocorrencia.ciclo)).format(context)
        : '';
    final restantes = _segundosRestantes();
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                const Spacer(),
                const Icon(Icons.alarm, color: Colors.white54, size: 96),
                const SizedBox(height: 16),
                Text(
                  horario,
                  style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  _etiqueta(l10n),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 18),
                ),
                const SizedBox(height: 16),
                if (ocorrencia != null)
                  Text(
                    l10n.pinTempoTolerancia(restantes),
                    style: const TextStyle(color: Colors.amber, fontSize: 15),
                  ),
                const Spacer(),
                Text(
                  l10n.alarmeRotinaAtivoDescricao,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                    ),
                    onPressed: ocorrencia == null ? null : _abrirTecladoPin,
                    icon: const Icon(Icons.alarm_off, size: 26),
                    label: Text(
                      l10n.despertadorAcaoDesativar,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
