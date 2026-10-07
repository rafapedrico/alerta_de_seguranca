import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alarme_nativo_service.dart';
import 'database_helper.dart';
import '../screens/cronometro_disparado_screen.dart' show chaveCronometroFluxoResolvido;

/// Serviço responsável pelo alarme do Cronômetro Regressivo (aba
/// Segurança).
///
/// O fim do cronômetro é um alarme EXATO nativo (ver `DespertadorAgenda.kt`,
/// tipo `cronometro`): abre a [CronometroDisparadoScreen] por cima da tela
/// bloqueada, toca o som escolhido e mantém a localização a cada 1 min até
/// o fim da tolerância — com o app fechado e depois de reiniciar o
/// aparelho. A rede de segurança do aparelho desligado é o heartbeat de
/// nuvem + `functions/scheduledAlarmMonitor.js` (ver
/// `BackgroundLocationHeartbeatService.registrarCheckinAtivo`).
///
/// [inicializar] continua inicializando o `android_alarm_manager_plus`
/// (usado pela fila de reenvio e pelo backup do despertador).
class AlarmeService {
  AlarmeService._internal();
  static final AlarmeService _instance = AlarmeService._internal();
  factory AlarmeService() => _instance;

  /// Id reservado do Cronômetro no lado nativo (bem acima dos ids dos
  /// despertadores no SQLite) — mesmo `DespertadorAgenda.ID_CRONOMETRO`.
  static const int idAlarmeCronometroSeguranca = 999999;

  /// Tolerância após o cronômetro zerar: o teclado de PIN fica aberto e o
  /// som toca por até 60 s; 3 PINs errados ou o tempo esgotado disparam o
  /// alerta. É também o prazo da nuvem (fim + 60 s).
  static const Duration duracaoJanelaFinalCronometro = Duration(seconds: 60);

  /// Chave da trava atômica nativa contra disparo duplo (por ciclo).
  static String _chaveDisparoUnico(int fimEpochMs) => 'cronometro_$fimEpochMs';

  /// Chave da ocorrência nativa do ciclo que termina em [fimEpochMs].
  static String chaveOcorrencia(int fimEpochMs) =>
      '${OcorrenciaAlarme.tipoCronometro}:$idAlarmeCronometroSeguranca:$fimEpochMs';

  static Future<void> inicializar() async {
    await AndroidAlarmManager.initialize();
  }

  /// `true` se o alarme exato pode ser agendado (Android 12+: "Alarmes e
  /// lembretes"). Sem ela o cronômetro NÃO é iniciado (ver `SegurancaTab`).
  Future<bool> podeAgendarExato() => AlarmeNativoService.podeAgendarExato();

  /// Fim (epoch ms) do ciclo atual, gravado no início do cronômetro.
  Future<int?> fimDoCicloAtual() async {
    try {
      final config = await DatabaseHelper().getUserConfig();
      return int.tryParse((config?['timestamp_expiracao_alarme'] as String?) ?? '');
    } catch (_) {
      return null;
    }
  }

  /// `true` enquanto o ciclo anterior ainda não terminou de verdade: o
  /// tempo zerou mas a tolerância está correndo, ou o alerta ainda está
  /// sendo processado. Nesses casos um novo cronômetro NÃO pode começar
  /// (reiniciar o ciclo na nuvem cancelaria o alerta sem PIN).
  Future<bool> cicloAnteriorEmAndamento() async {
    final pendentes = await AlarmeNativoService.pendentes();
    if (pendentes.any((o) => o.ehCronometro)) return true;
    final fim = await fimDoCicloAtual();
    if (fim == null) return false;
    final agora = DateTime.now().millisecondsSinceEpoch;
    final prazo = fim + duracaoJanelaFinalCronometro.inMilliseconds;
    if (agora < fim || agora > prazo) return false;
    return !await AlarmeNativoService.estaResolvida(chaveOcorrencia(fim));
  }

  /// Agenda o fim do Cronômetro para daqui a [duracaoAteDisparo]: grava a
  /// dica de contexto e o fim no SQLite e arma o alarme exato nativo (com a
  /// localização a cada 1 min até o fim da tolerância). `false` se o
  /// alarme exato não pôde ser armado.
  Future<bool> agendarAlarmeEmergencia({
    required Duration duracaoAteDisparo,
    required String contexto,
  }) async {
    final fim = DateTime.now().add(duracaoAteDisparo);

    await DatabaseHelper().salvarContextoTimerAtivo(
      contexto: contexto,
      timestampExpiracao: fim,
    );

    // A flag de "fluxo resolvido" do ciclo ANTERIOR não pode vazar para
    // este (a tela se fecharia sozinha no primeiro segundo).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(chaveCronometroFluxoResolvido);
    } catch (e) {
      debugPrint('⚠️ Falha ao resetar chaveCronometroFluxoResolvido no novo ciclo: $e');
    }

    final armado = await AlarmeNativoService.armarCronometro(
      fim: fim,
      prazo: fim.add(duracaoJanelaFinalCronometro),
    );
    debugPrint('⏰ Cronômetro de Segurança armado para ${fim.toIso8601String()} (ok=$armado)');
    return armado;
  }

  /// Trava atômica NATIVA contra disparo duplo do ciclo atual (dois
  /// engines Flutter no mesmo processo): só o PRIMEIRO chamador recebe
  /// `true`. Falha técnica na trava = `true` (um disparo de segurança nunca
  /// é bloqueado por ela).
  Future<bool> reivindicarDisparoUnicoCronometro() async {
    final fim = await fimDoCicloAtual() ?? 0;
    return AlarmeNativoService.reivindicarDisparoUnico(_chaveDisparoUnico(fim));
  }

  /// Encerra o ciclo atual — PIN correto ou alerta já enviado: desarma o
  /// alarme exato e a localização, e MARCA A OCORRÊNCIA COMO RESOLVIDA no
  /// nativo (para o som, cancela a tela cheia; o fechamento forçado nunca
  /// mais dispara para ela, mesmo que o alarme ainda chegue).
  Future<void> cancelarAlarme() async {
    final fim = await fimDoCicloAtual();
    await AlarmeNativoService.encerrarCronometro();
    if (fim != null) await AlarmeNativoService.resolver(chaveOcorrencia(fim));
    debugPrint('⏰ Cronômetro de Segurança encerrado.');
  }
}
