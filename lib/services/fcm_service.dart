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
///
/// CRITÉRIO DE CANCELAMENTO DO WHATSAPP DE CONTINGÊNCIA: o job de
/// transbordo (`functions/transbordoWhatsappMonitor.js`) cancela a
/// cobrança quando o Push é confirmado como ENTREGUE NO DISPOSITIVO —
/// não quando o usuário abre o app ou lê a notificação. Este serviço
/// grava essa confirmação assim que `onMessage`/`onBackgroundMessage`
/// executa (ver [_tratarDadosDoAlerta]), o que acontece automaticamente
/// na entrega da mensagem pelo SO, mesmo com a tela bloqueada e o app
/// fechado — nunca depende de interação do usuário.
class FcmService {
  FcmService._internal();
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;

  static const String _tipoAlertaEmergencia = 'alerta_emergencia';

  /// Tipos de push da aba Monitoramento (ver `functions/monitoramentoService.js`
  /// e `functions/monitoramentoExpiracaoMonitor.js`) — notificações NORMAIS
  /// (sem tela cheia, sem confirmação de entrega/transbordo), distintas do
  /// pipeline de alerta de emergência acima.
  static const Set<String> _tiposPushMonitoramento = {
    'solicitacao_monitoramento',
    'monitoramento_aprovado',
    'monitoramento_negado',
    'monitoramento_bloqueado',
    'monitoramento_expirado',
  };

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

  /// Lógica compartilhada entre primeiro e segundo plano: despacha o
  /// tratamento conforme o campo `tipo` da mensagem data-only recebida —
  /// alerta de emergência de terceiro ([_tratarAlertaEmergencia]) ou push
  /// da aba Monitoramento ([_tratarPushMonitoramento]). Qualquer outro
  /// `tipo` (ou ausente) é ignorado silenciosamente.
  Future<void> _tratarDadosDoAlerta(Map<String, dynamic> data) async {
    final tipo = data['tipo'] as String?;

    if (tipo == _tipoAlertaEmergencia) {
      await _tratarAlertaEmergencia(data);
      return;
    }

    if (tipo != null && _tiposPushMonitoramento.contains(tipo)) {
      await _tratarPushMonitoramento(data, tipo);
      return;
    }
  }

  /// Se for um alerta de emergência de terceiro, confirma a ENTREGA NO
  /// DISPOSITIVO e só então tenta exibir a notificação de tela cheia.
  ///
  /// ORDEM CRÍTICA E DE PROPÓSITO: este método só é chamado quando o SO
  /// já entregou a mensagem FCM a este aparelho (é exatamente isso que
  /// dispara `onMessage`/`onBackgroundMessage`, mesmo com a tela
  /// bloqueada e o app fechado) — ou seja, a mera execução deste método
  /// JÁ É a prova de entrega no dispositivo, independente de qualquer
  /// interação do usuário (abrir o app, tocar na notificação, etc.).
  /// Por isso a confirmação ([FirebaseSyncService.confirmarEntregaAlerta])
  /// é gravada PRIMEIRO, em seu próprio try/catch — uma falha ao MOSTRAR
  /// a notificação de tela cheia (ex: canal ainda não criado, permissão
  /// negada) NUNCA deve impedir o registro da entrega já confirmada pelo
  /// FCM, o que faria o job de transbordo
  /// (`functions/transbordoWhatsappMonitor.js`) cobrar WhatsApp
  /// desnecessariamente mesmo com o Push já entregue.
  Future<void> _tratarAlertaEmergencia(Map<String, dynamic> data) async {
    final idEntrega = data['idEntrega'] as String?;
    final mensagem = (data['mensagem'] as String?) ?? '';
    final nomeRemetente = data['nomeRemetente'] as String?;
    if (idEntrega == null) return;

    try {
      await FirebaseSyncService().confirmarEntregaAlerta(idEntrega);
      debugPrint('✅ [Confirmação de Entrega Enviada] entregas_alerta/$idEntrega');
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao confirmar entrega no dispositivo: $e');
    }

    try {
      await NotificacaoService.exibirNotificacaoAlertaRecebido(
        idEntrega: idEntrega,
        mensagem: mensagem,
        nomeRemetente: nomeRemetente,
      );
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao exibir notificação de alerta recebido: $e');
    }
  }

  /// Exibe a notificação NORMAL (sem tela cheia, sem som/vibração
  /// persistentes — ver [NotificacaoService.exibirNotificacaoMonitoramento])
  /// para um push da aba Monitoramento, funcionando com o app em
  /// primeiro plano, segundo plano ou totalmente fechado. Diferente de
  /// [_tratarAlertaEmergencia], não há nenhuma confirmação de
  /// entrega/transbordo a registrar aqui — a expiração de 24h da
  /// solicitação (ver `monitoramentoExpiracaoMonitor.js`) é decidida
  /// inteiramente no servidor a partir do Firestore, não da entrega deste
  /// Push.
  ///
  /// [tipo] é `'solicitacao_monitoramento'` (nome vem de `nomeSolicitante`,
  /// quem está pedindo a localização) ou uma resposta a uma solicitação
  /// já enviada — `'monitoramento_aprovado'`, `'monitoramento_negado'`,
  /// `'monitoramento_bloqueado'` ou `'monitoramento_expirado'` (nome vem
  /// de `nomeAlvo`, quem respondeu/deixou expirar).
  Future<void> _tratarPushMonitoramento(
    Map<String, dynamic> data,
    String tipo,
  ) async {
    final idPermissao = data['idPermissao'] as String?;
    if (idPermissao == null) return;

    final nomeContraparte = tipo == 'solicitacao_monitoramento'
        ? data['nomeSolicitante'] as String?
        : data['nomeAlvo'] as String?;

    try {
      await NotificacaoService.exibirNotificacaoMonitoramento(
        tipo: tipo,
        idPermissao: idPermissao,
        nomeContraparte: nomeContraparte,
      );
    } catch (e) {
      debugPrint(
          '⚠️ [FcmService] Falha ao exibir notificação de monitoramento ($tipo): $e');
    }
  }
}
