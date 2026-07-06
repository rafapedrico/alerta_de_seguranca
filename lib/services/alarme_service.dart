import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';

import 'database_helper.dart';
import 'emergency_alert_service.dart';

/// Serviço responsável por agendar/cancelar o alarme NATIVO de disparo
/// de emergência via [AndroidAlarmManager] (android_alarm_manager_plus).
///
/// Diferente de um simples `Timer` do Dart (que morre junto com o
/// processo do app quando ele é fechado/removido da lista de recentes),
/// o AndroidAlarmManager agenda o disparo diretamente no sistema
/// operacional Android, garantindo que o callback [_callbackDeAlarme]
/// seja executado no horário exato mesmo que o app esteja completamente
/// fechado — o próprio Android acorda um FlutterEngine headless
/// (sem UI/Activity) só para rodar esse callback.
///
/// IMPORTANTE: [_callbackDeAlarme] precisa ser uma função de nível
/// top-level ou `static`, anotada com [pragma('vm:entry-point')], pois é
/// invocada pelo Android fora do ciclo de vida normal do app.
class AlarmeService {
  AlarmeService._internal();
  static final AlarmeService _instance = AlarmeService._internal();
  factory AlarmeService() => _instance;

  /// ID fixo usado para identificar o alarme de emergência único do app
  /// (não há múltiplos alarmes concorrentes: cada novo agendamento
  /// cancela/substitui o anterior).
  static const int _alarmeEmergenciaId = 9001;

  /// Deve ser chamado uma única vez, bem no início do main.dart, ANTES
  /// de runApp(), para inicializar o plugin android_alarm_manager_plus.
  static Future<void> inicializar() async {
    await AndroidAlarmManager.initialize();
  }

  /// Agenda o disparo automático de emergência para acontecer em
  /// [duracaoAteDisparo] a partir de agora. Antes de agendar, salva no
  /// SQLite (via [DatabaseHelper.salvarContextoTimerAtivo]) a dica de
  /// contexto atual e o timestamp de expiração, para que o callback
  /// headless — que não tem acesso a nenhum estado em memória do app —
  /// consiga montar a mesma mensagem de SMS.
  ///
  /// Regra de negócio: [duracaoAteDisparo] já deve incluir o tempo total
  /// escolhido pelo usuário no picker de horas/minutos SOMADO aos 60
  /// segundos fixos de tolerância da tela de bloqueio, replicando
  /// exatamente o comportamento hoje feito em memória (Timer + Timer de
  /// tolerância).
  Future<void> agendarAlarmeEmergencia({
    required Duration duracaoAteDisparo,
    required String contexto,
  }) async {
    final timestampExpiracao = DateTime.now().add(duracaoAteDisparo);

    await DatabaseHelper().salvarContextoTimerAtivo(
      contexto: contexto,
      timestampExpiracao: timestampExpiracao,
    );

    await AndroidAlarmManager.oneShot(
      duracaoAteDisparo,
      _alarmeEmergenciaId,
      _callbackDeAlarme,
      exact: true,
      wakeup: true,
      rescheduleOnReboot: false,
    );

    debugPrint(
        '⏰ Alarme nativo de emergência agendado para ${timestampExpiracao.toIso8601String()}');
  }

  /// Cancela o alarme nativo agendado. Deve ser chamado SOMENTE quando o
  /// PIN correto for digitado com sucesso (regra de segurança: o simples
  /// toque no botão de desarmar, ou a abertura da tela de bloqueio, NÃO
  /// cancela o alarme nativo — apenas o PIN correto o faz).
  Future<void> cancelarAlarme() async {
    await AndroidAlarmManager.cancel(_alarmeEmergenciaId);
    debugPrint('⏰ Alarme nativo de emergência cancelado.');
  }
}

/// Callback estático executado pelo Android em um FlutterEngine
/// headless (sem Activity/UI), possivelmente com o app totalmente
/// fechado. Roda TODO o fluxo de disparo de emergência (GPS, montagem de
/// mensagem e envio de SMS via MethodChannel nativo, registrado pelo
/// MainApplication.kt no engine headless) e, ao final, marca no SQLite
/// que o app deve exibir a tela de bloqueio de PIN assim que for
/// reaberto.
///
/// Precisa ser uma função top-level (fora de qualquer classe) e anotada
/// com `@pragma('vm:entry-point')` para que o Flutter não a remova via
/// tree-shaking e para que o Android consiga localizá-la pelo seu
/// handle/callback registrado.
@pragma('vm:entry-point')
void _callbackDeAlarme() async {
  debugPrint('🚨 [HEADLESS] Alarme de emergência disparado em segundo plano!');

  try {
    // Executa o disparo completo: GPS + contatos + montagem da mensagem
    // + envio via MethodChannel nativo (SmsManager, registrado pelo
    // MainApplication.kt neste FlutterEngine headless).
    await EmergencyAlertService().dispararAlertaDeEmergencia();
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha durante o disparo de emergência: $e');
  }

  try {
    // Marca no SQLite que o app deve exibir a tela de bloqueio de PIN
    // assim que for reaberto (cold start), até que o PIN correto seja
    // digitado.
    await DatabaseHelper().marcarAguardandoConfirmacaoPin();
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao marcar aguardando_confirmacao_pin: $e');
  }
}
