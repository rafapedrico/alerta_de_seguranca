import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'firebase_sync_service.dart';
import 'notificacao_service.dart';

/// Serviço central do lado "guardião" da arquitetura híbrida de alertas:
/// mantém o `fcmToken` do aparelho sincronizado com
/// `usuarios/{uid}.fcmToken` (é por ele que a Cloud Function resolve para
/// onde mandar o Push App-para-App gratuito, ver
/// `functions/alertaHibridoService.js`) e trata as mensagens recebidas em
/// primeiro plano, segundo plano e com o app totalmente fechado.
///
/// As mensagens do pipeline de alerta são DATA-ONLY (sem o campo
/// `notification`, ver `enviarFcmParaContatos` no backend) — de
/// propósito, para que este serviço tenha controle total sobre COMO a
/// notificação é exibida (tela cheia sobre a lockscreen, mesmo padrão de
/// `NotificacaoService.exibirNotificacaoAlarmeCompleto`) em vez de deixar
/// o Android exibir automaticamente uma notificação padrão do sistema.
class FcmService {
  FcmService._internal();
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;

  static const String _tipoAlertaEmergencia = 'alerta_emergencia';

  bool _inicializado = false;

  /// Deve ser chamado uma única vez, logo após o login/cadastro (ou no
  /// cold start já autenticado, ver `main.dart`) — sem usuário logado não
  /// há `uid` para vincular o token.
  Future<void> inicializar() async {
    if (_inicializado) return;
    if (Firebase.apps.isEmpty) return;

    try {
      FirebaseMessaging.onBackgroundMessage(_aoReceberMensagemEmSegundoPlano);

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();

      final token = await messaging.getToken();
      if (token != null) {
        await FirebaseSyncService().atualizarFcmToken(token);
        debugPrint('📲 [FcmService] Token FCM inicial sincronizado.');
      }

      messaging.onTokenRefresh.listen((novoToken) {
        FirebaseSyncService().atualizarFcmToken(novoToken);
        debugPrint('📲 [FcmService] Token FCM renovado e sincronizado.');
      });

      FirebaseMessaging.onMessage.listen(_processarMensagem);

      _inicializado = true;
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao inicializar: $e');
    }
  }

  /// Handler de PRIMEIRO PLANO (app aberto e em uso).
  Future<void> _processarMensagem(RemoteMessage mensagem) async {
    debugPrint('📩 [FCM Recebido - Foreground] ${mensagem.data}');
    await _tratarDadosDoAlerta(mensagem.data);
  }

  /// Handler de SEGUNDO PLANO/TERMINADO — chamado pelo Android num
  /// isolate separado, precisa ser uma função top-level ou estática
  /// anotada com `@pragma('vm:entry-point')`, e re-inicializar o Firebase
  /// já que não compartilha nenhum estado com o processo principal.
  @pragma('vm:entry-point')
  static Future<void> _aoReceberMensagemEmSegundoPlano(RemoteMessage mensagem) async {
    debugPrint('📩 [FCM Recebido - Background] ${mensagem.data}');
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      }
      await FcmService()._tratarDadosDoAlerta(mensagem.data);
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao processar mensagem em segundo plano: $e');
    }
  }

  /// Lógica compartilhada entre primeiro e segundo plano: se for um
  /// alerta de emergência de terceiro, mostra a notificação de tela
  /// cheia e grava a confirmação de entrega no Firestore — é essa
  /// confirmação que o job de transbordo
  /// (`functions/transbordoWhatsappMonitor.js`) verifica antes de decidir
  /// se cobra o WhatsApp de contingência para este contato.
  Future<void> _tratarDadosDoAlerta(Map<String, dynamic> data) async {
    if (data['tipo'] != _tipoAlertaEmergencia) return;

    final idEntrega = data['idEntrega'] as String?;
    final mensagem = (data['mensagem'] as String?) ?? '';
    final nomeRemetente = data['nomeRemetente'] as String?;
    if (idEntrega == null) return;

    await NotificacaoService.exibirNotificacaoAlertaRecebido(
      idEntrega: idEntrega,
      mensagem: mensagem,
      nomeRemetente: nomeRemetente,
    );

    await FirebaseSyncService().confirmarEntregaAlerta(idEntrega);
    debugPrint('✅ [Confirmação de Entrega Enviada] entregas_alerta/$idEntrega');
  }
}
