import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_helper.dart';
import '../screens/cronometro_disparado_screen.dart' show chaveCronometroFluxoResolvido;

/// Mesmo canal nativo já usado pelo Alarme de Rotina (`RotinaAlarmPlugin.kt`)
/// — reaproveitado aqui, com o extra `tipoAlarme: 'cronometro'`, em vez de
/// duplicar um canal/Activity/Service nativo só para o Cronômetro (ver
/// documentação completa em [AlarmeService.agendarAlarmeEmergencia]).
const MethodChannel _canalRotinaAlarme =
    MethodChannel('com.example.security_check_app/rotina_alarme');

/// Serviço responsável pelo alarme do Cronômetro Regressivo (aba
/// Segurança).
///
/// [inicializar] continua responsável por inicializar o plugin
/// `android_alarm_manager_plus` — usado extensivamente pelo Alarme de
/// Rotina (`rotina_alarme_service.dart`), por isso permanece aqui mesmo
/// após [agendarAlarmeEmergencia] ter deixado de usá-lo diretamente (ver
/// abaixo).
class AlarmeService {
  AlarmeService._internal();
  static final AlarmeService _instance = AlarmeService._internal();
  factory AlarmeService() => _instance;

  /// Id reservado (sentinel) usado para identificar, no lado nativo
  /// (Activity/Service/Receiver compartilhados com o Alarme de Rotina —
  /// ver `RotinaAlarmPlugin.kt`/`RotinaCheckinAlarmActivity.kt`), o
  /// alarme ÚNICO do Cronômetro Regressivo da aba Segurança. Fixo e
  /// reaproveitado entre ciclos (só um cronômetro ativo por vez — mesmo
  /// espírito do id fixo `'checkin_seguranca'` já usado do lado Firestore
  /// em `BackgroundLocationHeartbeatService`), escolhido bem acima da
  /// faixa de autoincrement do SQLite usada pelos alarmes de rotina, para
  /// nunca colidir com eles no mesmo `AlarmManager`/`PendingIntent`.
  static const int idAlarmeCronometroSeguranca = 999999;

  /// Tolerância sonora após o cronômetro zerar — especificação do
  /// usuário (2026-08-10, ajustada para 60s em 2026-08-11): ao zerar, o
  /// alarme toca e exibe o teclado de PIN por até 60 segundos (3
  /// tentativas incorretas OU o tempo se esgotando disparam o alerta de
  /// emergência com localização; qualquer tentativa CORRETA cancela
  /// tudo, sem enviar nada). Usado tanto pela tela
  /// `CronometroDisparadoScreen` (limite duro do teclado de PIN) quanto
  /// pelo prazo final registrado no heartbeat de nuvem — ver
  /// `seguranca_tab.dart`/`BackgroundLocationHeartbeatService`.
  static const Duration duracaoJanelaFinalCronometro = Duration(seconds: 60);

  /// Deve ser chamado uma única vez, bem no início do main.dart, ANTES
  /// de runApp(), para inicializar o plugin android_alarm_manager_plus
  /// (usado pelo Alarme de Rotina — ver `rotina_alarme_service.dart`).
  static Future<void> inicializar() async {
    await AndroidAlarmManager.initialize();
  }

  /// Agenda o disparo do Cronômetro Regressivo para acontecer em
  /// [duracaoAteDisparo] a partir de agora. Antes de agendar, salva no
  /// SQLite (via [DatabaseHelper.salvarContextoTimerAtivo]) a dica de
  /// contexto atual e o timestamp de expiração.
  ///
  /// GENERALIZAÇÃO (reespecificação do usuário, 2026-08-10): antes, este
  /// método agendava um alarme 100% Dart (`android_alarm_manager_plus`)
  /// cujo callback headless disparava o alerta de emergência IMEDIATAMENTE,
  /// sem nenhuma UI/chance de PIN — se o app estivesse em segundo plano
  /// ou fechado, não havia como pedir a senha antes de enviar o alerta.
  /// Agora reaproveita a MESMA infraestrutura nativa já validada do
  /// Alarme de Rotina (Activity/Service/Receiver — ver
  /// `RotinaAlarmPlugin.kt`, extra `tipoAlarme: 'cronometro'`), que abre
  /// uma tela dedicada com som + teclado de PIN por cima do Keyguard
  /// mesmo com o app fechado/bloqueado (Doze-proof, via
  /// `AlarmManager.setExactAndAllowWhileIdle` nativo) — ver
  /// `cronometro_disparado_screen.dart`.
  ///
  /// Diferente do Alarme de Rotina, propositalmente NÃO há um segundo
  /// alarme Dart headless em paralelo aqui: o caminho nativo acima já é
  /// o mesmo mecanismo Doze-proof usado lá (o motivo original de existir
  /// dessa redundância), e a rede de segurança para o caso do aparelho
  /// estar desligado/sem internet no momento do disparo já é coberta,
  /// de forma totalmente independente, pelo heartbeat de nuvem +
  /// `functions/scheduledAlarmMonitor.js` (ver
  /// `BackgroundLocationHeartbeatService.registrarCheckinAtivo`, chamado
  /// por `SegurancaTab._iniciarTimer`).
  Future<void> agendarAlarmeEmergencia({
    required Duration duracaoAteDisparo,
    required String contexto,
  }) async {
    final timestampExpiracao = DateTime.now().add(duracaoAteDisparo);

    await DatabaseHelper().salvarContextoTimerAtivo(
      contexto: contexto,
      timestampExpiracao: timestampExpiracao,
    );

    // BUG REAL CONFIRMADO (2026-08-12): diferente de
    // `chaveAlarmeFluxoResolvido` (Alarme de Rotina), que é resetada a
    // cada novo disparo dentro do próprio callback headless
    // (`_callbackCheckinRotina`, ver `rotina_alarme_service.dart`),
    // `chaveCronometroFluxoResolvido` NUNCA era resetada em lugar nenhum
    // — o Cronômetro não tem um callback Dart equivalente (ver
    // documentação da classe acima: propositalmente não há alarme Dart
    // headless em paralelo aqui). Resultado: assim que UM ciclo do
    // Cronômetro terminava (PIN certo OU alerta disparado), a flag
    // ficava gravada em `true` PARA SEMPRE. No PRÓXIMO ciclo,
    // `CronometroDisparadoScreen._iniciarPollingDeFluxoResolvido` lia
    // esse `true` residual do ciclo ANTERIOR já no primeiro tick
    // (~1s) e se autoencerrava imediatamente — parando o som e fechando
    // o teclado de PIN antes do usuário conseguir digitar nada. Sintoma
    // real reportado: "o teclado surge por menos de 1 segundo e é
    // destruído/fechado imediatamente". Resetar aqui, no início de CADA
    // novo ciclo (chamado por `SegurancaTab._iniciarTimer` sempre que o
    // cronômetro é armado), garante que a flag só reflita o ciclo atual.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(chaveCronometroFluxoResolvido);
    } catch (e) {
      debugPrint(
          '⚠️ Falha ao resetar chaveCronometroFluxoResolvido no novo ciclo: $e');
    }

    try {
      await _canalRotinaAlarme.invokeMethod('agendarAlarmeNativo', {
        'idAlarme': idAlarmeCronometroSeguranca,
        'epochMillis': timestampExpiracao.millisecondsSinceEpoch,
        'tipoAlarme': 'cronometro',
      });
    } catch (e) {
      debugPrint('⚠️ Falha ao agendar alarme nativo do Cronômetro de Segurança: $e');
    }

    debugPrint(
        '⏰ Alarme nativo do Cronômetro de Segurança agendado para ${timestampExpiracao.toIso8601String()}');
  }

  /// Cancela o alarme nativo agendado. Regra de segurança original: o
  /// simples toque no botão de desarmar, ou a abertura da tela de
  /// bloqueio, NUNCA cancela o alarme nativo sozinho — só duas coisas o
  /// fazem: o PIN correto sendo digitado, OU o alerta de emergência já
  /// tendo sido realmente disparado (3ª tentativa de PIN errada/tempo
  /// esgotado — ver `SegurancaTab._pararTimer`) — nos dois casos o ciclo
  /// já está definitivamente resolvido, nunca por uma ação sem prova de
  /// identidade.
  Future<void> cancelarAlarme() async {
    try {
      await _canalRotinaAlarme.invokeMethod('cancelarAlarmeNativo', {
        'idAlarme': idAlarmeCronometroSeguranca,
      });
    } catch (e) {
      debugPrint('⚠️ Falha ao cancelar alarme nativo do Cronômetro de Segurança: $e');
    }
    debugPrint('⏰ Alarme nativo do Cronômetro de Segurança cancelado.');
  }
}
