import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'database_helper.dart';
import 'rotina_alarme_service.dart';

/// Wrapper central do plugin `flutter_local_notifications`, responsável
/// por inicializar, exibir e cancelar as notificações locais de check-in
/// de rotina (Etapa 3), incluindo o tratamento da ação rápida
/// "✅ Cheguei bem" tanto em primeiro plano quanto em segundo
/// plano/headless (app fechado).
///
/// Mantido como uma classe de métodos estáticos (sem estado próprio),
/// já que precisa ser chamado tanto pelo main.dart normal quanto pelo
/// callback headless de [RotinaAlarmeService], que roda em um
/// FlutterEngine separado sem nenhum estado em memória compartilhado.
class NotificacaoService {
  NotificacaoService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Id do canal Android usado exclusivamente para as notificações de
  /// check-in de rotina.
  static const String canalId = 'checkin_rotina';
  static const String canalNome = 'Check-in de Rotina';
  static const String canalDescricao =
      'Lembretes de check-in de segurança dos alarmes de rotina cadastrados.';

  /// Id da ação rápida "Cheguei bem" exibida na notificação.
  static const String acaoConfirmarId = 'confirmar_checkin_rotina';

  static bool _inicializado = false;

  /// Deve ser chamado uma única vez, bem no início do app (main.dart),
  /// ANTES de runApp(). Também é chamado defensivamente pelo callback
  /// headless do [RotinaAlarmeService], já que o FlutterEngine headless
  /// não compartilha nenhuma inicialização feita pelo processo principal.
  static Future<void> inicializar() async {
    if (_inicializado) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _aoReceberRespostaEmPrimeiroPlano,
      onDidReceiveBackgroundNotificationResponse: _aoReceberRespostaEmSegundoPlano,
    );

    const canal = AndroidNotificationChannel(
      canalId,
      canalNome,
      description: canalDescricao,
      importance: Importance.max,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(canal);

    _inicializado = true;
  }

  /// Exibe a notificação de check-in de rotina para o [idAlarme]
  /// informado, com a ação rápida "✅ Cheguei bem". O [idAlarme] é
  /// codificado no próprio id da notificação Android para que o handler
  /// da ação consiga identificar exatamente qual alarme confirmar.
  static Future<void> exibirNotificacaoCheckin({
    required int idAlarme,
    required String etiqueta,
  }) async {
    await inicializar();

    final androidDetails = AndroidNotificationDetails(
      canalId,
      canalNome,
      channelDescription: canalDescricao,
      importance: Importance.max,
      priority: Priority.high,
      ongoing: true,
      autoCancel: false,
      actions: const [
        AndroidNotificationAction(
          acaoConfirmarId,
          '✅ Cheguei bem',
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      idAlarme,
      etiqueta.isNotEmpty ? etiqueta : 'Check-in de rotina',
      'Toque em "Cheguei bem" para confirmar seu check-in de segurança.',
      details,
      payload: idAlarme.toString(),
    );
  }

  /// Cancela (remove) a notificação de check-in de rotina exibida para
  /// o [idAlarme] informado. Chamado tanto quando o usuário confirma o
  /// check-in quanto quando o disparo de emergência já ocorreu (a
  /// notificação de pedido de confirmação não faz mais sentido).
  static Future<void> cancelarNotificacaoCheckin(int idAlarme) async {
    await inicializar();
    await _plugin.cancel(idAlarme);
  }

  /// Handler chamado quando o usuário interage com a notificação
  /// (toque no corpo ou na ação "Cheguei bem") com o app em primeiro
  /// plano ou no processo principal já ativo.
  static void _aoReceberRespostaEmPrimeiroPlano(
      NotificationResponse resposta) {
    _processarResposta(resposta);
  }

  /// Handler chamado pelo Android em um isolate headless separado
  /// quando o usuário interage com a notificação (ex: toca "Cheguei
  /// bem") com o app COMPLETAMENTE fechado. Precisa ser uma função
  /// top-level ou estática anotada com `@pragma('vm:entry-point')`.
  @pragma('vm:entry-point')
  static void _aoReceberRespostaEmSegundoPlano(
      NotificationResponse resposta) {
    _processarResposta(resposta);
  }

  /// Lógica compartilhada entre os dois handlers (primeiro e segundo
  /// plano): se a ação tocada foi "Cheguei bem", confirma o check-in de
  /// rotina correspondente via [RotinaAlarmeService], cancelando o
  /// alarme de tolerância agendado e registrando o evento no histórico.
  static void _processarResposta(NotificationResponse resposta) {
    if (resposta.actionId != acaoConfirmarId) return;

    final idAlarme = int.tryParse(resposta.payload ?? '');
    if (idAlarme == null) return;

    // Fire-and-forget: o processamento é assíncrono, mas o handler do
    // plugin não aguarda retorno.
    RotinaAlarmeService.confirmarCheckinRotina(idAlarme).catchError((e) {
      debugPrint('⚠️ Falha ao confirmar check-in de rotina: $e');
    });
  }

  /// Registra, de forma resiliente (nunca lança exceção), um evento no
  /// histórico administrativo (categoria 'sistema'), usado pelos fluxos
  /// de check-in de rotina confirmados/perdidos.
  static Future<void> registrarEventoSistema({
    required String titulo,
    required String descricao,
  }) async {
    try {
      await DatabaseHelper().inserirEventoHistorico(
        titulo: titulo,
        descricao: descricao,
        categoria: 'sistema',
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao registrar evento de sistema no histórico: $e');
    }
  }
}
