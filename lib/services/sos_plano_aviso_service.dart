import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n_headless_service.dart';
import 'notificacao_service.dart';
import 'plano_ciclo_service.dart';

/// Período do ciclo em que o botão SOS (Widget SOS) fica desativado no
/// Plano Free: do dia 11 ([inicio]) até a renovação do ciclo ([fim]) —
/// o mesmo do app iOS.
@immutable
class BloqueioSosPlano {
  const BloqueioSosPlano({required this.inicio, required this.fim});

  final DateTime inicio;
  final DateTime fim;

  /// Período do ciclo de [status]; `null` para Premium ou sem status.
  static BloqueioSosPlano? doCiclo(PlanoCicloStatus? status) {
    if (status == null || status.isPremium) return null;
    return BloqueioSosPlano(
      inicio: status.cycleStartDate.add(const Duration(days: 10)).toLocal(),
      fim: status.dataRenovacao.toLocal(),
    );
  }

  /// Período em vigor AGORA (botão desativado); `null` fora dele.
  static BloqueioSosPlano? vigente(PlanoCicloStatus? status) {
    if (status == null || status.ativo) return null;
    return doCiclo(status);
  }
}

/// "DD/MM" — mesmo padrão de data numérica usado no resto do app.
String formatarDiaMes(DateTime data) =>
    '${data.day.toString().padLeft(2, '0')}/${data.month.toString().padLeft(2, '0')}';

/// Avisa ANTES que o botão SOS vai parar nos dias bloqueados do Plano Free
/// (dias 11–30 do ciclo) — os mesmos avisos do app iOS:
///   - lembrete na véspera, às 10h: "ficará desativado a partir de amanhã
///     (DD/MM) até DD/MM…";
///   - no início do bloqueio (não antes das 8h): "está desativado até
///     DD/MM…".
/// Agendados pelo `AndroidAlarmManager` (mesma infraestrutura da
/// verificação do início do bloqueio em [PlanoCicloService]); o callback
/// confere de novo o plano em cache antes de avisar. Reagendados sempre
/// que o ciclo ou o plano mudam ([PlanoCicloService.statusStream]);
/// Premium cancela tudo.
class SosPlanoAvisoService {
  SosPlanoAvisoService._internal();
  static final SosPlanoAvisoService _instance = SosPlanoAvisoService._internal();
  factory SosPlanoAvisoService() => _instance;

  static const int _idLembrete = 510001;
  static const int _idInicio = 510002;
  static const String _chaveLembreteExibido = 'sos_plano_lembrete_exibido_ciclo';

  StreamSubscription<PlanoCicloStatus?>? _assinatura;
  String? _ultimaChave;

  /// Começa a acompanhar o ciclo. Chamado uma vez por sessão (ver
  /// `iniciarServicosPosLoginOuDashboard`).
  void iniciar() {
    if (_assinatura != null) return;
    _assinatura = PlanoCicloService().statusStream().listen((status) {
      if (status == null) return;
      final chave = '${status.isPremium}_${status.cycleStartDate.millisecondsSinceEpoch}';
      if (chave == _ultimaChave) return;
      _ultimaChave = chave;
      unawaited(_reagendar(status));
    });
  }

  Future<void> _reagendar(PlanoCicloStatus status) async {
    try {
      await AndroidAlarmManager.cancel(_idLembrete);
      await AndroidAlarmManager.cancel(_idInicio);
      final bloqueio = BloqueioSosPlano.doCiclo(status);
      if (bloqueio == null) {
        debugPrint('💎 [SosPlanoAviso] Premium — avisos do botão SOS cancelados.');
        return;
      }

      final agora = DateTime.now();
      final vespera = bloqueio.inicio.subtract(const Duration(days: 1));
      final momentoLembrete = DateTime(vespera.year, vespera.month, vespera.day, 10);
      if (momentoLembrete.isAfter(agora)) {
        await _agendar(_idLembrete, momentoLembrete, _callbackLembreteSosPlano);
      } else if (agora.isBefore(bloqueio.inicio)) {
        // Já passou das 10h da véspera (app aberto só agora): avisa já,
        // uma vez por ciclo.
        final prefs = await SharedPreferences.getInstance();
        final ciclo = status.cycleStartDate.millisecondsSinceEpoch;
        if (prefs.getInt(_chaveLembreteExibido) != ciclo) {
          await prefs.setInt(_chaveLembreteExibido, ciclo);
          await _exibirAviso(bloqueio, lembrete: true);
        }
      }

      final inicio = bloqueio.inicio;
      final oitoHoras = DateTime(inicio.year, inicio.month, inicio.day, 8);
      final momentoInicio = inicio.isBefore(oitoHoras) ? oitoHoras : inicio;
      if (momentoInicio.isAfter(agora)) {
        await _agendar(_idInicio, momentoInicio, _callbackInicioSosPlano);
      }
      debugPrint('💎 [SosPlanoAviso] Avisos do botão SOS agendados '
          '(bloqueio ${formatarDiaMes(bloqueio.inicio)}–${formatarDiaMes(bloqueio.fim)}).');
    } catch (e) {
      debugPrint('⚠️ [SosPlanoAviso] Falha ao agendar os avisos do botão SOS: $e');
    }
  }

  static Future<void> _agendar(int id, DateTime quando, Function callback) =>
      AndroidAlarmManager.oneShotAt(
        quando,
        id,
        callback,
        allowWhileIdle: true,
        rescheduleOnReboot: true,
      );

  static Future<void> _exibirAviso(BloqueioSosPlano bloqueio, {required bool lembrete}) async {
    final l10n = await L10nHeadlessService.obter();
    final fim = formatarDiaMes(bloqueio.fim);
    await NotificacaoService.exibirNotificacaoInformativa(
      id: lembrete ? _idLembrete : _idInicio,
      titulo: l10n.sosPlanoNotificacaoTitulo,
      corpo: lembrete
          ? l10n.sosPlanoLembreteNotificacao(formatarDiaMes(bloqueio.inicio), fim)
          : l10n.sosPlanoDesativadoAte(fim),
    );
  }

  /// Callback do alarme (isolate headless): só avisa se o plano em cache
  /// ainda disser que o bloqueio está para começar ([lembrete]) ou em vigor.
  static Future<void> _exibirAvisoAgendado({required bool lembrete}) async {
    try {
      final bloqueio = BloqueioSosPlano.doCiclo(await PlanoCicloService().statusEmCache());
      if (bloqueio == null) return;
      final agora = DateTime.now();
      final valido = lembrete
          ? agora.isBefore(bloqueio.inicio)
          : !agora.isBefore(bloqueio.inicio) && agora.isBefore(bloqueio.fim);
      if (!valido) return;
      await _exibirAviso(bloqueio, lembrete: lembrete);
    } catch (e) {
      debugPrint('⚠️ [HEADLESS] Falha no aviso do botão SOS do Plano Free: $e');
    }
  }
}

@pragma('vm:entry-point')
Future<void> _callbackLembreteSosPlano() =>
    SosPlanoAvisoService._exibirAvisoAgendado(lembrete: true);

@pragma('vm:entry-point')
Future<void> _callbackInicioSosPlano() =>
    SosPlanoAvisoService._exibirAvisoAgendado(lembrete: false);
