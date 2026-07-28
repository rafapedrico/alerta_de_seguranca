import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_navigator.dart'; // <--- O IMPORT CORRETO AQUI
import '../main.dart';
import '../screens/alarme_disparado_screen.dart';
import '../screens/alerta_recebido_screen.dart';
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

  /// Canal Android dedicado ao Push App-para-App recebido via FCM (ver
  /// [FcmService]) — alerta de emergência de OUTRO usuário que cadastrou
  /// este aparelho como contato de emergência. Separado do canal de
  /// check-in de rotina para que o usuário possa configurar volume/som
  /// de forma independente para cada tipo de alerta.
  static const String canalAlertaRecebidoId = 'alerta_emergencia_recebido';
  static const String canalAlertaRecebidoNome = 'Alerta de Emergência Recebido';
  static const String canalAlertaRecebidoDescricao =
      'Alertas de segurança de contatos que cadastraram este aparelho como emergência.';

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
    const canalAlertaRecebido = AndroidNotificationChannel(
      canalAlertaRecebidoId,
      canalAlertaRecebidoNome,
      description: canalAlertaRecebidoDescricao,
      importance: Importance.max,
    );
    final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await implementacaoAndroid?.createNotificationChannel(canal);
    await implementacaoAndroid?.createNotificationChannel(canalAlertaRecebido);

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
      fullScreenIntent: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      idAlarme,
      'Alarme de rotina',
      'Toque para cancelar o alarme.',
      details,
      payload: idAlarme.toString(),
    );
  }

  /// Exibe uma notificação de alarme completo com som e vibração persistentes,
  /// usando uma intenção de tela cheia para aparecer sobre a tela de bloqueio.
  static Future<void> exibirNotificacaoAlarmeCompleto({
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
      fullScreenIntent: true,
      autoCancel: false,
      playSound: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),
      actions: const [
        AndroidNotificationAction(
          'pausar_alarme',
          '⏸️ Pausar Alarme',
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      idAlarme + 10000, // ID diferente para não conflitar com a notificação normal
      etiqueta.isNotEmpty ? etiqueta : 'Alarme de Segurança',
      'Confirme sua segurança ou pause o alarme!',
      details,
      payload: 'alarme_${idAlarme.toString()}',
    );
  }

  /// Exibe, com tela cheia mesmo sobre a lockscreen (mesmo mecanismo de
  /// [exibirNotificacaoAlarmeCompleto]: `fullScreenIntent` + `Importance.max`
  /// + vibração/som persistentes), o alerta de emergência de OUTRO
  /// usuário recebido via Push FCM (ver [FcmService]) — canal próprio
  /// [canalAlertaRecebidoId], distinto do alarme de rotina do PRÓPRIO
  /// usuário.
  ///
  /// [idEntrega] identifica o documento `entregas_alerta/{idEntrega}` no
  /// Firestore (ver `functions/alertaHibridoService.js`) — usado para
  /// codificar um id de notificação Android estável e para levar o
  /// payload completo (remetente/mensagem/localização) até
  /// [AlertaRecebidoScreen] quando o usuário tocar a notificação.
  static Future<void> exibirNotificacaoAlertaRecebido({
    required String idEntrega,
    required String mensagem,
    String? nomeRemetente,
    double? latitude,
    double? longitude,
  }) async {
    await inicializar();

    final androidDetails = AndroidNotificationDetails(
      canalAlertaRecebidoId,
      canalAlertaRecebidoNome,
      channelDescription: canalAlertaRecebidoDescricao,
      importance: Importance.max,
      priority: Priority.high,
      ongoing: true,
      fullScreenIntent: true,
      autoCancel: false,
      playSound: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),
    );

    final details = NotificationDetails(android: androidDetails);

    final payload = jsonEncode({
      'tipo': 'alerta_recebido',
      'idEntrega': idEntrega,
      'mensagem': mensagem,
      if (nomeRemetente != null) 'nomeRemetente': nomeRemetente,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
    });

    await _plugin.show(
      // Id estável derivado do idEntrega — evita colidir com os ids de
      // notificação de check-in de rotina (idAlarme/idAlarme+10000).
      30000 + (idEntrega.hashCode.abs() % 60000),
      nomeRemetente != null && nomeRemetente.isNotEmpty
          ? '🚨 Alerta de $nomeRemetente'
          : '🚨 Alerta de segurança',
      mensagem,
      details,
      payload: payload,
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
    final payload = resposta.payload ?? '';

    // Payload JSON (ver exibirNotificacaoAlertaRecebido) — alerta de
    // emergência de OUTRO usuário, distinto do alarme de rotina do
    // próprio usuário tratado no restante deste método.
    if (payload.startsWith('{')) {
      _processarRespostaAlertaRecebido(payload);
      return;
    }

    final idAlarme = int.tryParse(payload.startsWith('alarme_')
        ? payload.replaceFirst('alarme_', '')
        : payload);

    if (idAlarme == null) return;

    if (resposta.actionId == acaoConfirmarId) {
      // 1. Gravação síncrona de prioridade máxima no disco para cessar o loop do reprodutor em background
      SharedPreferences.getInstance().then((prefs) async {
        await prefs.setBool('stop_current_alarm', true);
        await prefs.remove('alarme_disparando_no_momento');
        debugPrint('⏹️ [NotificacaoService] Flags de cancelamento persistidas no disco.');
      }).catchError((e) {
        debugPrint('⚠️ Erro ao persistir cancelamento no SharedPreferences: $e');
      });

      // 2. Tenta fazer a limpeza silenciosa das rotinas locais
      RotinaAlarmeService.pausarAlarme(idAlarme).then((_) {
        // 3. Atualiza e remove o destaque da notificação
        _plugin.show(
          idAlarme,
          'Alarme de rotina',
          'Alarme cancelado.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              canalId,
              canalNome,
              importance: Importance.low,
              priority: Priority.low,
              ongoing: false,
              autoCancel: true,
            ),
          ),
        );
      }).catchError((e) {
        debugPrint('⚠️ Falha ao registrar pausa no service: $e');
      });
      
    } else if (resposta.actionId == 'pausar_alarme') {
      RotinaAlarmeService.pausarAlarme(idAlarme).catchError((e) {
        debugPrint('⚠️ Falha ao pausar alarme: $e');
      });
    } else if (resposta.actionId == null) {
      appNavigatorKey.currentState?.push(
        MaterialPageRoute(builder: (context) => const AlarmeDisparadoScreen()),
      );
    }
  }

  /// Decodifica o payload JSON de um alerta de emergência de terceiro
  /// (ver [exibirNotificacaoAlertaRecebido]) e navega para
  /// [AlertaRecebidoScreen]. Protegido contra payload malformado — nunca
  /// deixa a interação com a notificação derrubar o app.
  static void _processarRespostaAlertaRecebido(String payload) {
    try {
      final dados = jsonDecode(payload) as Map<String, dynamic>;
      appNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) => AlertaRecebidoScreen(
            mensagem: (dados['mensagem'] as String?) ?? '',
            nomeRemetente: dados['nomeRemetente'] as String?,
            latitude: (dados['latitude'] as num?)?.toDouble(),
            longitude: (dados['longitude'] as num?)?.toDouble(),
          ),
        ),
      );
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao processar payload de alerta recebido: $e');
    }
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