import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_navigator.dart'; // <--- O IMPORT CORRETO AQUI
import '../screens/alarme_disparado_screen.dart';
import '../screens/alerta_recebido_screen.dart';
import '../screens/home_screen.dart';
import '../widgets/monitoramento_decisao_dialog.dart';
import 'database_helper.dart';
import 'firebase_auth_service.dart';
import 'l10n_headless_service.dart';
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
  // Nomes/descrições de canal traduzidos via [AppLocalizations] — não
  // podem mais ser `const`, pois dependem do idioma ativo do usuário
  // (carregados uma vez em [inicializar] via [_carregarNomesCanaisLocalizados]).
  // Mantêm um valor padrão em português apenas como fallback antes da
  // primeira inicialização.
  static String canalNome = 'Check-in de Rotina';
  static String canalDescricao =
      'Lembretes de check-in de segurança dos alarmes de rotina cadastrados.';

  /// Canal Android dedicado ao Push App-para-App recebido via FCM (ver
  /// [FcmService]) — alerta de emergência de OUTRO usuário que cadastrou
  /// este aparelho como contato de emergência. Separado do canal de
  /// check-in de rotina para que o usuário possa configurar volume/som
  /// de forma independente para cada tipo de alerta.
  static const String canalAlertaRecebidoId = 'alerta_emergencia_recebido';
  static String canalAlertaRecebidoNome = 'Alerta de Emergência Recebido';
  static String canalAlertaRecebidoDescricao =
      'Alertas de segurança de contatos que cadastraram este aparelho como emergência.';

  /// Canal Android dedicado às RESPOSTAS de push da aba Monitoramento
  /// (aprovada, recusada, bloqueada ou expirada — ver [FcmService] e
  /// `functions/monitoramentoService.js`). Notificações NORMAIS (sem tela
  /// cheia, sem som/vibração persistentes) — são só informativas, sobre uma
  /// solicitação que o PRÓPRIO usuário enviou. Deliberadamente SEPARADO de
  /// [canalSolicitacaoMonitoramentoId] abaixo, que é o único que precisa de
  /// urgência máxima (é o único que exige uma DECISÃO do usuário).
  static const String canalMonitoramentoId = 'monitoramento';
  static String canalMonitoramentoNome = 'Monitoramento de Localização';
  static String canalMonitoramentoDescricao =
      'Respostas a solicitações de compartilhamento de localização enviadas pela aba Monitoramento.';

  /// Canal Android dedicado à SOLICITAÇÃO de localização recebida (tipo
  /// `'solicitacao_monitoramento'`, ver [FcmService]) — o único evento da
  /// aba Monitoramento que exige uma decisão explícita do usuário
  /// (Aceitar/Recusar). Importância MÁXIMA + `fullScreenIntent` (mesmo
  /// padrão de [canalAlertaRecebidoId]/[exibirNotificacaoAlertaRecebido]):
  /// com o aparelho bloqueado, "acorda" a tela e abre por cima da
  /// lockscreen, estilo chamada recebida — em vez de só aparecer
  /// silenciosamente na bandeja como as respostas informativas acima.
  static const String canalSolicitacaoMonitoramentoId = 'solicitacao_monitoramento';
  static String canalSolicitacaoMonitoramentoNome =
      'Solicitação de Localização Recebida';
  static String canalSolicitacaoMonitoramentoDescricao =
      'Alerta prioritário quando um familiar solicita ver sua localização em tempo real — exige Aceitar ou Recusar.';

  /// Carrega os nomes/descrições dos 4 canais Android no idioma
  /// atualmente selecionado pelo usuário (ver [L10nHeadlessService]),
  /// chamado uma única vez no início de [inicializar] — antes da criação
  /// efetiva dos canais logo abaixo.
  static Future<void> _carregarNomesCanaisLocalizados() async {
    try {
      final l10n = await L10nHeadlessService.obter();
      canalNome = l10n.notifCanalCheckinNome;
      canalDescricao = l10n.notifCanalCheckinDescricao;
      canalAlertaRecebidoNome = l10n.notifCanalAlertaRecebidoNome;
      canalAlertaRecebidoDescricao = l10n.notifCanalAlertaRecebidoDescricao;
      canalMonitoramentoNome = l10n.notifCanalMonitoramentoNome;
      canalMonitoramentoDescricao = l10n.notifCanalMonitoramentoDescricao;
      canalSolicitacaoMonitoramentoNome = l10n.notifCanalSolicitacaoMonitoramentoNome;
      canalSolicitacaoMonitoramentoDescricao =
          l10n.notifCanalSolicitacaoMonitoramentoDescricao;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao localizar nomes de canais: $e');
    }
  }

  /// Id da ação rápida "Cheguei bem" exibida na notificação.
  static const String acaoConfirmarId = 'confirmar_checkin_rotina';

  static bool _inicializado = false;

  /// Payload de uma notificação de SOLICITAÇÃO ('solicitacao_monitoramento')
  /// recebida antes de existir uma sessão autenticada — capturado tanto no
  /// cold start (ver [inicializar]/[_capturarPayloadSolicitacaoPendente])
  /// quanto por um toque com o app já rodando mas ainda sem login (ver
  /// [_processarRespostaPayloadJson]). NUNCA usado para pular a barreira de
  /// login: é só guardado aqui até a [LoginScreen] concluir um login com
  /// sucesso e consumi-lo via [consumirPayloadSolicitacaoPendente], abrindo
  /// o modal de decisão direto em vez da Home normal.
  static Map<String, dynamic>? payloadSolicitacaoPendente;

  static void _capturarPayloadSolicitacaoPendente(String? payload) {
    if (payload == null || !payload.startsWith('{')) return;
    try {
      final dados = jsonDecode(payload) as Map<String, dynamic>;
      if (dados['tipo'] == 'monitoramento_push' &&
          dados['subTipo'] == 'solicitacao_monitoramento') {
        payloadSolicitacaoPendente = dados;
      }
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao decodificar payload de lançamento: $e');
    }
  }

  /// Lê e limpa o payload pendente — chamado pela `LoginScreen` logo após
  /// um login bem-sucedido. Devolve `null` se não havia nenhuma solicitação
  /// pendente (fluxo normal, sem notificação envolvida).
  static Map<String, dynamic>? consumirPayloadSolicitacaoPendente() {
    final dados = payloadSolicitacaoPendente;
    payloadSolicitacaoPendente = null;
    return dados;
  }

  /// Canal nativo dedicado ao fluxo de "acordar a tela" para solicitações
  /// de monitoramento (ver `SolicitacaoMonitoramentoWakeService`/
  /// `SolicitacaoMonitoramentoFcmReceiver`, no lado Kotlin, e
  /// `MainActivity.configureFlutterEngine`/`onNewIntent`, que registram
  /// este canal). `'obterPayloadPendente'` é chamado UMA VEZ por
  /// [inicializar] (mesmo padrão de `getNotificationAppLaunchDetails`)
  /// para resgatar os extras de um COLD START; `'solicitacaoRecebida'` é
  /// invocado NATIVO->DART quando o Intent chega com o engine já rodando
  /// (app em primeiro/segundo plano, via `onNewIntent`).
  static const MethodChannel _canalSolicitacaoNativa =
      MethodChannel('com.example.security_check_app/solicitacao_monitoramento');

  /// Ids de permissão com o modal de decisão atualmente aberto — evita
  /// empilhar dois diálogos para a MESMA solicitação quando mais de um
  /// caminho (Intent nativo aqui, FCM em primeiro plano em [FcmService],
  /// toque na notificação) processa o mesmo evento quase ao mesmo tempo.
  static final Set<String> _idsComDialogoAbertoViaNativo = {};

  /// Ponto único de decisão para um payload de solicitação recebido pelo
  /// caminho nativo (`SolicitacaoMonitoramentoWakeService`): se já houver
  /// sessão autenticada e um `BuildContext` disponível, abre o modal de
  /// decisão DIRETO por cima da tela atual; caso contrário — cold start
  /// ainda na barreira de login — só guarda em [payloadSolicitacaoPendente]
  /// para a `LoginScreen` consumir depois. NUNCA pula a autenticação.
  static Future<void> _tratarPayloadSolicitacaoNativo(
    Map<String, dynamic> dados,
  ) async {
    final idPermissao = dados['idPermissao'] as String?;
    final uidSolicitante = dados['uidSolicitante'] as String?;
    if (idPermissao == null || uidSolicitante == null) return;

    final autenticado =
        Firebase.apps.isNotEmpty && FirebaseAuthService().uidAtual != null;
    final context = appNavigatorKey.currentContext;

    if (autenticado && context != null) {
      if (_idsComDialogoAbertoViaNativo.contains(idPermissao)) return;
      _idsComDialogoAbertoViaNativo.add(idPermissao);
      try {
        await exibirDialogoDecisaoMonitoramento(
          context: context,
          idPermissao: idPermissao,
          uidSolicitante: uidSolicitante,
          nomeSolicitante: (dados['nomeSolicitante'] as String?) ?? '',
          telefoneSolicitante: (dados['telefoneSolicitante'] as String?) ?? '',
        );
      } finally {
        _idsComDialogoAbertoViaNativo.remove(idPermissao);
      }
      return;
    }

    payloadSolicitacaoPendente = {
      'tipo': 'monitoramento_push',
      'subTipo': 'solicitacao_monitoramento',
      'idPermissao': idPermissao,
      'uidSolicitante': uidSolicitante,
      'nomeSolicitante': (dados['nomeSolicitante'] as String?) ?? '',
      'telefoneSolicitante': (dados['telefoneSolicitante'] as String?) ?? '',
    };
  }

  static Future<dynamic> _aoReceberChamadaNativa(MethodCall call) async {
    if (call.method != 'solicitacaoRecebida') return null;
    try {
      final dados = Map<String, dynamic>.from(call.arguments as Map);
      await _tratarPayloadSolicitacaoNativo(dados);
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao processar solicitação nativa recebida: $e');
    }
    return null;
  }

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

    // Cold start via toque numa notificação (app estava totalmente
    // fechado): `onDidReceiveNotificationResponse` acima só dispara para
    // toques que acontecem DEPOIS do app já estar rodando — a notificação
    // que efetivamente abriu o processo agora precisa ser resgatada aqui,
    // explicitamente, ANTES de qualquer tela ser construída. Sem isto, o
    // payload se perdia silenciosamente sempre que o app era relançado do
    // zero por uma notificação (é exatamente esse o cold start em que a
    // barreira de login — ver política de segurança em `main.dart` — SEMPRE
    // aparece primeiro; o payload capturado aqui é só guardado para a
    // LoginScreen consumir DEPOIS de um login bem-sucedido, nunca usado
    // para pular a autenticação).
    try {
      final detalhesLancamento = await _plugin.getNotificationAppLaunchDetails();
      final respostaDeLancamento = detalhesLancamento?.notificationResponse;
      if (detalhesLancamento?.didNotificationLaunchApp == true &&
          respostaDeLancamento != null) {
        _capturarPayloadSolicitacaoPendente(respostaDeLancamento.payload);
      }
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao ler notificação de lançamento: $e');
    }

    // Mesma ideia acima, mas para o caminho 100% nativo (ver
    // SolicitacaoMonitoramentoWakeService): resgata os extras deixados no
    // Intent que abriu o app num cold start disparado por esse Service, e
    // passa a escutar chamadas futuras (app já rodando, via onNewIntent).
    _canalSolicitacaoNativa.setMethodCallHandler(_aoReceberChamadaNativa);
    try {
      final payloadPendente = await _canalSolicitacaoNativa
          .invokeMapMethod<String, dynamic>('obterPayloadPendente');
      if (payloadPendente != null) {
        await _tratarPayloadSolicitacaoNativo(payloadPendente);
      }
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao ler payload nativo pendente: $e');
    }

    // Carrega os nomes/descrições dos canais no idioma ativo do usuário
    // ANTES de criá-los de fato (ver [_carregarNomesCanaisLocalizados]).
    await _carregarNomesCanaisLocalizados();

    final canal = AndroidNotificationChannel(
      canalId,
      canalNome,
      description: canalDescricao,
      importance: Importance.max,
    );
    final canalAlertaRecebido = AndroidNotificationChannel(
      canalAlertaRecebidoId,
      canalAlertaRecebidoNome,
      description: canalAlertaRecebidoDescricao,
      importance: Importance.max,
    );
    final canalMonitoramento = AndroidNotificationChannel(
      canalMonitoramentoId,
      canalMonitoramentoNome,
      description: canalMonitoramentoDescricao,
      importance: Importance.high,
    );
    final canalSolicitacaoMonitoramento = AndroidNotificationChannel(
      canalSolicitacaoMonitoramentoId,
      canalSolicitacaoMonitoramentoNome,
      description: canalSolicitacaoMonitoramentoDescricao,
      importance: Importance.max,
    );
    final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await implementacaoAndroid?.createNotificationChannel(canal);
    await implementacaoAndroid?.createNotificationChannel(canalAlertaRecebido);
    await implementacaoAndroid?.createNotificationChannel(canalMonitoramento);
    await implementacaoAndroid?.createNotificationChannel(canalSolicitacaoMonitoramento);

    // A partir do Android 14/15+, `USE_FULL_SCREEN_INTENT` deixou de ser
    // concedida automaticamente para apps sem função de chamada/alarme — sem
    // esta solicitação explícita, o `fullScreenIntent: true` das notificações
    // acima é silenciosamente rebaixado para um heads-up normal, que NÃO
    // acorda a tela com o aparelho bloqueado (é exatamente esse sintoma que
    // motivou este ajuste). Em versões do Android onde a permissão não se
    // aplica (< 14), a chamada é um no-op seguro do lado nativo.
    try {
      await implementacaoAndroid?.requestFullScreenIntentPermission();
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao solicitar permissão de full-screen intent: $e');
    }

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
    final l10n = await L10nHeadlessService.obter();

    await _plugin.show(
      idAlarme,
      l10n.familiaEtiquetaPadrao,
      l10n.notifCheckinCorpo,
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
    final l10n = await L10nHeadlessService.obter();

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
      actions: [
        AndroidNotificationAction(
          'pausar_alarme',
          l10n.notifPausarAlarmeAcao,
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      idAlarme + 10000, // ID diferente para não conflitar com a notificação normal
      etiqueta.isNotEmpty ? etiqueta : l10n.notifAlarmeSegurancaTitulo,
      l10n.notifAlarmeSegurancaCorpo,
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
    String? fotoUrl,
  }) async {
    await inicializar();
    final l10n = await L10nHeadlessService.obter();
    final String tituloAlerta = nomeRemetente != null && nomeRemetente.isNotEmpty
        ? l10n.notifAlertaDeNome(nomeRemetente)
        : l10n.notifAlertaSegurancaGenerico;

    // P2 da sequência unificada de SOS (ver SosDisparoService no
    // remetente): quando o alerta inclui uma foto, baixa os bytes ANTES
    // de montar a notificação e usa BigPictureStyle para exibi-la
    // embutida — best-effort: uma falha no download (sem rede, link
    // expirado, timeout) NUNCA deve impedir a notificação de
    // texto/localização de aparecer, só cai para o estilo padrão.
    Uint8List? fotoBytes;
    if (fotoUrl != null && fotoUrl.isNotEmpty) {
      try {
        final resposta = await http.get(Uri.parse(fotoUrl)).timeout(const Duration(seconds: 15));
        if (resposta.statusCode == 200) {
          fotoBytes = resposta.bodyBytes;
        }
      } catch (e) {
        debugPrint('⚠️ [NotificacaoService] Falha ao baixar foto do SOS para exibição: $e');
      }
    }

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
      styleInformation: fotoBytes != null
          ? BigPictureStyleInformation(
              ByteArrayAndroidBitmap(fotoBytes),
              contentTitle: tituloAlerta,
              summaryText: mensagem,
            )
          : null,
    );

    final details = NotificationDetails(android: androidDetails);

    final payload = jsonEncode({
      'tipo': 'alerta_recebido',
      'idEntrega': idEntrega,
      'mensagem': mensagem,
      if (nomeRemetente != null) 'nomeRemetente': nomeRemetente,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (fotoUrl != null && fotoUrl.isNotEmpty) 'fotoUrl': fotoUrl,
    });

    await _plugin.show(
      // Id estável derivado do idEntrega — evita colidir com os ids de
      // notificação de check-in de rotina (idAlarme/idAlarme+10000).
      30000 + (idEntrega.hashCode.abs() % 60000),
      tituloAlerta,
      mensagem,
      details,
      payload: payload,
    );
  }

  /// Exibe a notificação para os eventos de push da aba Monitoramento —
  /// solicitação de localização recebida, aprovada, recusada, bloqueada ou
  /// expirada (ver [FcmService._tratarPushMonitoramento] e
  /// `functions/monitoramentoService.js`/`monitoramentoExpiracaoMonitor.js`).
  ///
  /// SÓ o tipo `'solicitacao_monitoramento'` — o único que exige uma decisão
  /// do usuário — usa [canalSolicitacaoMonitoramentoId] com
  /// `fullScreenIntent` (mesmo padrão de
  /// [exibirNotificacaoAlertaRecebido]): com o aparelho bloqueado, "acorda"
  /// a tela e abre por cima da lockscreen, estilo chamada recebida. As
  /// respostas informativas (aprovado/negado/bloqueado/expirado) continuam
  /// em [canalMonitoramentoId], uma notificação normal — a aba Monitoramento
  /// nunca deve se comportar como alarme/sirene fora do caso que realmente
  /// precisa de uma resposta.
  ///
  /// Ao tocar na notificação, a barreira de login (ver política de
  /// segurança em `main.dart`) continua obrigatória; o modal de decisão só
  /// abre DEPOIS de autenticado (ver [_processarRespostaPayloadJson] e
  /// `LoginScreen._navegarParaFluxoPrincipal`).
  static Future<void> exibirNotificacaoMonitoramento({
    required String tipo,
    required String idPermissao,
    String? nomeContraparte,
    String? uidSolicitante,
    String? telefoneSolicitante,
  }) async {
    await inicializar();
    final l10n = await L10nHeadlessService.obter();

    final nome = (nomeContraparte != null && nomeContraparte.trim().isNotEmpty)
        ? nomeContraparte.trim()
        : l10n.notifMonitContatoGenerico;

    final String titulo;
    final String corpo;
    switch (tipo) {
      case 'solicitacao_monitoramento':
        titulo = l10n.notifMonitSolicitacaoTitulo;
        corpo = l10n.notifMonitSolicitacaoCorpo(nome);
        break;
      case 'monitoramento_aprovado':
        titulo = l10n.notifMonitAprovadoTitulo;
        corpo = l10n.notifMonitAprovadoCorpo(nome);
        break;
      case 'monitoramento_negado':
        titulo = l10n.notifMonitNegadoTitulo;
        corpo = l10n.notifMonitNegadoCorpo(nome);
        break;
      case 'monitoramento_bloqueado':
        titulo = l10n.notifMonitBloqueadoTitulo;
        corpo = l10n.notifMonitBloqueadoCorpo(nome);
        break;
      case 'monitoramento_expirado':
        titulo = l10n.notifMonitExpiradoTitulo;
        corpo = l10n.notifMonitExpiradoCorpo(nome);
        break;
      default:
        // Tipo de push de monitoramento ainda não mapeado — ignora em vez
        // de exibir uma notificação vazia/confusa.
        return;
    }

    final bool ehSolicitacao = tipo == 'solicitacao_monitoramento';

    final androidDetails = ehSolicitacao
        ? AndroidNotificationDetails(
            canalSolicitacaoMonitoramentoId,
            canalSolicitacaoMonitoramentoNome,
            channelDescription: canalSolicitacaoMonitoramentoDescricao,
            importance: Importance.max,
            priority: Priority.high,
            fullScreenIntent: true,
            autoCancel: true,
            playSound: true,
            visibility: NotificationVisibility.public,
            vibrationPattern: Int64List.fromList([0, 800, 400, 800]),
          )
        : AndroidNotificationDetails(
            canalMonitoramentoId,
            canalMonitoramentoNome,
            channelDescription: canalMonitoramentoDescricao,
            importance: Importance.high,
            priority: Priority.high,
            autoCancel: true,
          );

    final details = NotificationDetails(android: androidDetails);
    final payload = jsonEncode({
      'tipo': 'monitoramento_push',
      'subTipo': tipo,
      'idPermissao': idPermissao,
      // Só preenchidos para 'solicitacao_monitoramento' (ver
      // FcmService._tratarPushMonitoramento) — usados pelo deep link em
      // [_processarRespostaPayloadJson] para abrir o modal de decisão
      // direto, sem precisar de uma nova consulta ao Firestore.
      if (uidSolicitante != null) 'uidSolicitante': uidSolicitante,
      if (tipo == 'solicitacao_monitoramento') 'nomeSolicitante': nomeContraparte ?? '',
      if (telefoneSolicitante != null) 'telefoneSolicitante': telefoneSolicitante,
    });

    await _plugin.show(
      // Faixa de id dedicada — evita colidir com check-in (idAlarme),
      // alarme completo (idAlarme+10000) e alerta recebido (30000+...).
      90000 + (idPermissao.hashCode.abs() % 9000),
      titulo,
      corpo,
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

    // Payload JSON — alerta de emergência de OUTRO usuário (ver
    // exibirNotificacaoAlertaRecebido) ou push da aba Monitoramento (ver
    // exibirNotificacaoMonitoramento), distintos do alarme de rotina do
    // próprio usuário tratado no restante deste método.
    if (payload.startsWith('{')) {
      _processarRespostaPayloadJson(payload);
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
      RotinaAlarmeService.pausarAlarme(idAlarme).then((_) async {
        // 3. Atualiza e remove o destaque da notificação
        final l10n = await L10nHeadlessService.obter();
        _plugin.show(
          idAlarme,
          l10n.familiaEtiquetaPadrao,
          l10n.notifCheckinCanceladoCorpo,
          NotificationDetails(
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

  /// Decodifica um payload JSON de notificação e roteia para a tela
  /// correta conforme o campo `tipo`:
  /// - `'monitoramento_push'` (ver [exibirNotificacaoMonitoramento]): abre
  ///   a HomeScreen diretamente na aba Monitoramento (índice 2).
  /// - qualquer outro valor (compatibilidade com payloads antigos, ver
  ///   [exibirNotificacaoAlertaRecebido]): alerta de emergência de
  ///   terceiro, navega para [AlertaRecebidoScreen].
  ///
  /// Protegido contra payload malformado — nunca deixa a interação com a
  /// notificação derrubar o app.
  static void _processarRespostaPayloadJson(String payload) {
    try {
      final dados = jsonDecode(payload) as Map<String, dynamic>;

      if (dados['tipo'] == 'monitoramento_push') {
        final subTipo = dados['subTipo'] as String?;
        final idPermissao = dados['idPermissao'] as String?;
        final uidSolicitante = dados['uidSolicitante'] as String?;
        final ehSolicitacao = subTipo == 'solicitacao_monitoramento' &&
            idPermissao != null &&
            uidSolicitante != null;

        // Redirecionamento direto (deep link): só para uma SOLICITAÇÃO
        // recebida (não uma resposta a uma solicitação já enviada) e só
        // quando o usuário já está autenticado NESTA sessão do app — fora
        // disso (app recém-aberto por um isolate headless sem Firebase
        // inicializado, ou sessão sem login) cai no fallback abaixo, que
        // apenas abre a aba Monitoramento normalmente. Sem essa checagem,
        // tentar ler `FirebaseAuth.instance` num isolate onde o Firebase
        // nunca foi inicializado lançaria uma exceção.
        final autenticado =
            Firebase.apps.isNotEmpty && FirebaseAuthService().uidAtual != null;

        if (ehSolicitacao && autenticado) {
          final context = appNavigatorKey.currentContext;
          if (context != null) {
            exibirDialogoDecisaoMonitoramento(
              context: context,
              idPermissao: idPermissao,
              uidSolicitante: uidSolicitante,
              nomeSolicitante: (dados['nomeSolicitante'] as String?) ?? '',
              telefoneSolicitante: (dados['telefoneSolicitante'] as String?) ?? '',
            );
            return;
          }
        }

        if (ehSolicitacao && !autenticado) {
          // Sem sessão ativa agora (barreira de login obrigatória à
          // frente, ver política de segurança em `main.dart`) — NUNCA
          // pula o login. Só guarda o payload para a LoginScreen abrir o
          // modal de decisão direto assim que o login terminar com
          // sucesso, em vez de deixar a solicitação se perder.
          payloadSolicitacaoPendente = dados;
          return;
        }

        appNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (context) => const HomeScreen(abaInicial: 2),
          ),
        );
        return;
      }

      appNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) => AlertaRecebidoScreen(
            mensagem: (dados['mensagem'] as String?) ?? '',
            nomeRemetente: dados['nomeRemetente'] as String?,
            latitude: (dados['latitude'] as num?)?.toDouble(),
            longitude: (dados['longitude'] as num?)?.toDouble(),
            fotoUrl: dados['fotoUrl'] as String?,
            idEntrega: dados['idEntrega'] as String?,
          ),
        ),
      );
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao processar payload JSON da notificação: $e');
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