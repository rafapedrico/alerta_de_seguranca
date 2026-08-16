import 'dart:async';
import 'dart:convert';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
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
  /// BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-15, via
  /// `dumpsys notification`): o Android trava as configurações de ÁUDIO
  /// de um canal (`audioAttributesUsage`, som) no momento em que ele é
  /// criado pela PRIMEIRA vez — o mecanismo de "deletar e recriar" usado
  /// para migrar canais já existentes (ver [inicializar]) se mostrou NÃO
  /// confiável na prática: mesmo depois de rodar, um aparelho de teste
  /// real continuou mostrando `usage=USAGE_NOTIFICATION` (som padrão do
  /// sistema) em vez de `USAGE_ALARM` no canal deste alerta —
  /// silenciosamente incapaz de furar o modo Silencioso/Não Perturbe, o
  /// PRÓPRIO objetivo do ajuste "Despertador de Emergência". Trocar o ID
  /// do canal é a forma robusta/padrão de resolver isso: um ID NOVO
  /// nunca existiu antes, então o Android o cria do zero, com as
  /// configurações corretas, sem depender de deletar+recriar
  /// funcionar de forma confiável em 100% dos aparelhos/versões do
  /// Android. Quem já tinha o app instalado ganha automaticamente o novo
  /// canal (com as configurações certas) na próxima vez que este método
  /// rodar — o canal antigo `alerta_emergencia_recebido` fica órfão,
  /// inofensivo, e pode ser removido manualmente pelo usuário em
  /// Configurações do Android se desejar (não reaparece).
  /// CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-16, Moto G7
  /// Play, via `dumpsys notification` ao vivo): incrementar SÓ a flag de
  /// migração (`_chaveCanaisMigrados`, delete+recreate do MESMO id) não
  /// foi suficiente para desativar `enableVibration` em instalações que
  /// já tinham este canal — `dumpsys notification` continuou mostrando
  /// `mVibrationEnabled=true` mesmo minutos depois da migração ter
  /// rodado (confirmado sem nenhuma exceção nos logs). Suspeita: uma
  /// corrida no lado nativo do Android entre `deleteNotificationChannel`
  /// (processado de forma assíncrona pelo `system_server`) e o
  /// `createNotificationChannel` seguinte, chamados em sequência rápida
  /// demais para o MESMO id. Em vez de depurar essa corrida a fundo,
  /// aplicada a MESMA solução definitiva já usada da `_v1` pra `_v2`
  /// (2026-08-15): um id de canal NOVO, que nunca existiu neste
  /// aparelho — sem migração alguma envolvida, `createNotificationChannel`
  /// aplica as configurações (agora com `enableVibration: false`) sem
  /// ambiguidade nenhuma.
  static const String canalAlertaRecebidoId = 'alerta_emergencia_recebido_v3';
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

  /// Canal Android dedicado à confirmação de envio exibida DEPOIS do
  /// gesto de descarte (arrastar o botão azul/teclado de PIN para cima —
  /// ver `AlarmeDisparadoScreen._descartarPorArraste`): como a
  /// especificação exige que a tela/Activity do alarme feche IMEDIATAMENTE
  /// (controle 100% devolvido ao Android) assim que o gesto é detectado,
  /// não há mais nenhuma UI do app na tela para mostrar um diálogo
  /// in-app — a confirmação "mensagem enviada" precisa ser uma
  /// notificação do sistema. Importância baixa e sem som/vibração
  /// (o alarme já foi silenciado por este mesmo fluxo): é só uma
  /// confirmação informativa, não um novo alarme.
  static const String canalAlertaEnviadoId = 'alerta_enviado_confirmacao';
  static String canalAlertaEnviadoNome = 'Confirmação de Alerta Enviado';
  static String canalAlertaEnviadoDescricao =
      'Confirma que um alerta de emergência com localização foi enviado para os contatos cadastrados.';

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
      canalAlertaEnviadoNome = l10n.notifCanalAlertaEnviadoNome;
      canalAlertaEnviadoDescricao = l10n.notifCanalAlertaEnviadoDescricao;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao localizar nomes de canais: $e');
    }
  }

  /// Id da ação rápida "Cheguei bem" exibida na notificação.
  static const String acaoConfirmarId = 'confirmar_checkin_rotina';

  static bool _inicializado = false;

  /// Chave em disco (sobrevive entre isolates, ao contrário de
  /// [_inicializado]) que marca se a migração ÚNICA de canais antigos
  /// (deletar + recriar) já rodou nesta instalação — ver [inicializar].
  /// Incrementada para `_v2` (2026-08-16): força a migração rodar de
  /// novo mesmo em instalações que já tinham passado pela `_v1`,
  /// necessário para o canal `alerta_emergencia_recebido_v2` (já
  /// existente nesses aparelhos, com vibração habilitada) ser recriado
  /// com a vibração desativada — ver [exibirNotificacaoAlertaRecebido].
  static const String _chaveCanaisMigrados =
      'notificacao_canais_migrados_v2';

  /// Payload de uma notificação de SOLICITAÇÃO ('solicitacao_monitoramento')
  /// recebida antes de existir uma sessão autenticada — capturado tanto no
  /// cold start (ver [inicializar]/[_capturarPayloadSolicitacaoPendente])
  /// quanto por um toque com o app já rodando mas ainda sem login (ver
  /// [_processarRespostaPayloadJson]). NUNCA usado para pular a barreira de
  /// login: é só guardado aqui até a [LoginScreen] concluir um login com
  /// sucesso e consumi-lo via [consumirPayloadSolicitacaoPendente], abrindo
  /// o modal de decisão direto em vez da Home normal.
  static Map<String, dynamic>? payloadSolicitacaoPendente;

  /// Payload de um alerta de emergência RECEBIDO de outro usuário (tipo
  /// `'alerta_recebido'`, ver [exibirNotificacaoAlertaRecebido]) capturado
  /// num COLD START via toque nesta notificação (app 100% fechado) —
  /// mesma mecânica de [payloadSolicitacaoPendente], mas com um
  /// tratamento DIFERENTE e deliberado: reespecificação do usuário
  /// (2026-08-14) exige que o usuário NUNCA precise logar para ver a
  /// mensagem/localização de um alerta recebido. Por isso este payload é
  /// consumido em `main.dart` (ver `_inicializarNotificacoesEAbrirAlertaPendente`)
  /// para pular a barreira de login e abrir [AlertaRecebidoScreen] direto
  /// — ao contrário de [payloadSolicitacaoPendente], que é sempre
  /// guardado até um login de verdade acontecer.
  static Map<String, dynamic>? payloadAlertaRecebidoPendente;

  static void _capturarPayloadSolicitacaoPendente(String? payload) {
    if (payload == null || !payload.startsWith('{')) return;
    try {
      final dados = jsonDecode(payload) as Map<String, dynamic>;
      if (dados['tipo'] == 'monitoramento_push' &&
          dados['subTipo'] == 'solicitacao_monitoramento') {
        payloadSolicitacaoPendente = dados;
      } else if (dados['tipo'] == 'alerta_recebido') {
        payloadAlertaRecebidoPendente = dados;
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

  /// Lê e limpa o payload de alerta recebido pendente — chamado por
  /// `main.dart` logo após [inicializar] resolver, ANTES de qualquer
  /// LoginScreen aparecer (ver [payloadAlertaRecebidoPendente]). Devolve
  /// `null` no fluxo normal (cold start sem nenhuma notificação
  /// envolvida).
  static Map<String, dynamic>? consumirPayloadAlertaRecebidoPendente() {
    final dados = payloadAlertaRecebidoPendente;
    payloadAlertaRecebidoPendente = null;
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

  /// Modo "Despertador de Emergência" (reespecificação do usuário,
  /// 2026-08-15) — ver `AlertaRecebidoAlarmService.kt`/
  /// `AlertaRecebidoAlarmPlugin.kt` para a implementação nativa completa
  /// (alarme sonoro em loop, volume máximo do STREAM_ALARM, desarme via
  /// notificação/toque/arraste). Usado por [exibirNotificacaoAlertaRecebido]
  /// (iniciar) e por `AlertaRecebidoScreen` (parar, ao abrir a tela ou
  /// tocar no link do mapa).
  static const MethodChannel _canalAlertaRecebidoAlarme =
      MethodChannel('com.example.security_check_app/alerta_recebido_alarme');

  /// Inicia o alarme sonoro contínuo em volume máximo — chamado junto com
  /// a notificação de tela cheia em [exibirNotificacaoAlertaRecebido].
  /// Protegido: uma falha aqui (ex: `MissingPluginException` no engine
  /// headless do `firebase_messaging` com o app 100% fechado — ver
  /// documentação completa em `AlertaRecebidoAlarmService.kt`) NUNCA deve
  /// impedir a notificação de tela cheia (que já funciona nesse cenário)
  /// de aparecer.
  static Future<void> iniciarAlarmeCritico() async {
    try {
      await _canalAlertaRecebidoAlarme.invokeMethod('iniciarAlarme');
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao iniciar o Despertador de Emergência: $e');
    }
  }

  /// Para o alarme sonoro contínuo — chamado sempre que o usuário toma
  /// qualquer ação sobre o alerta recebido (abre a tela, toca no link do
  /// mapa etc., ver `AlertaRecebidoScreen`). Idempotente e seguro chamar
  /// mesmo se nenhum alarme estiver tocando.
  static Future<void> pararAlarmeCritico() async {
    try {
      await _canalAlertaRecebidoAlarme.invokeMethod('pararAlarme');
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao parar o Despertador de Emergência: $e');
    }
  }

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
      // CORREÇÃO (bug real observado em teste — "toque duplo"): sem
      // `playSound: false`, este canal tocava o som PADRÃO de
      // notificação do Android (~1 minuto, sem controle de volume pelo
      // app) em PARALELO ao alarme sonoro customizado do próprio
      // Guardião-X (player nativo/Dart, ver AlarmeDisparadoScreen), toda
      // vez que o alarme de rotina disparava. O áudio do alerta passa a
      // ficar 100% sob controle do player do app.
      playSound: false,
    );
    final canalAlertaRecebido = AndroidNotificationChannel(
      canalAlertaRecebidoId,
      canalAlertaRecebidoNome,
      description: canalAlertaRecebidoDescricao,
      importance: Importance.max,
      // Modo "Despertador de Emergência" (2026-08-15): roteia o som
      // desta notificação pelo canal STREAM_ALARM do Android (em vez do
      // STREAM_NOTIFICATION padrão) — o mesmo canal usado por
      // despertadores do sistema, que NÃO é silenciado pelo modo
      // Silencioso/Vibrar do aparelho. Efeito mesmo no pior caso (app
      // 100% fechado, ver `AlertaRecebidoAlarmService.kt`), onde o loop
      // sonoro contínuo em volume máximo daquele serviço não chega a
      // iniciar — este ajuste garante que ao menos o som PADRÃO desta
      // notificação já fure o silencioso.
      audioAttributesUsage: AudioAttributesUsage.alarm,
      // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-16, Moto
      // G7 Play — reespecificação do usuário): vibração desativada por
      // completo neste canal — ver documentação completa (motor de
      // vibração ficando preso em loop infinito, som permanece
      // funcionando normalmente) em [exibirNotificacaoAlertaRecebido].
      // Esta é a configuração que REALMENTE vale: o Android trava as
      // opções de vibração/som de um canal no momento em que ele é
      // criado pela PRIMEIRA vez, então é aqui — não no
      // `enableVibration: false` da notificação individual — que a
      // mudança precisa acontecer para valer também em instalações já
      // existentes (ver a migração `_chaveCanaisMigrados` em
      // [inicializar], incrementada para forçar a recriação deste canal).
      enableVibration: false,
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
    final canalAlertaEnviado = AndroidNotificationChannel(
      canalAlertaEnviadoId,
      canalAlertaEnviadoNome,
      description: canalAlertaEnviadoDescricao,
      importance: Importance.low,
      playSound: false,
    );
    final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    // CORREÇÃO DE BUG REAL (2026-08-15, diagnosticado ao vivo via
    // logcat): o migration de canais abaixo (deletar + recriar,
    // necessário SÓ UMA VEZ por instalação para aplicar `playSound:
    // false`/`audioAttributesUsage: alarm` a canais já existentes de
    // versões antigas — ver comentários originais preservados logo
    // abaixo) rodava TODA VEZ que [inicializar] era chamado, inclusive
    // em CADA isolate headless novo do `firebase_messaging`
    // (`_inicializado` é um `bool` estático — não sobrevive entre
    // isolates, cada mensagem em segundo plano criava um isolate 100%
    // novo). Cada mensagem recebida disparava, então, 2 chamadas nativas
    // extras de `deleteNotificationChannel` — round-trips desnecessários
    // (o canal já teria sido migrado da PRIMEIRA vez) que competiam pela
    // janela de execução CURTA que o Android concede a um
    // `BroadcastReceiver`/isolate headless antes de matá-lo. Sintoma real
    // observado: o isolate reiniciava do zero a cada mensagem (mesma
    // sequência completa de logs repetindo), e a notificação de alerta
    // NUNCA chegava a ser exibida (`dumpsys notification` confirmou
    // ausência). Uma flag persistida em disco (sobrevive entre isolates,
    // ao contrário do `bool` estático) garante que a migração rode
    // literalmente UMA vez por instalação, nunca de novo — deixando
    // [inicializar] rápido o bastante para caber na janela do isolate
    // headless.
    final prefsMigracao = await SharedPreferences.getInstance();
    final bool canaisJaMigrados =
        prefsMigracao.getBool(_chaveCanaisMigrados) ?? false;

    if (!canaisJaMigrados) {
      // O Android trava as configurações de um canal (incluindo som) no
      // momento em que ele é criado pela PRIMEIRA vez — chamar
      // `createNotificationChannel` de novo com `playSound: false` NÃO
      // atualiza um canal 'checkin_rotina' já existente em instalações
      // anteriores ao ajuste acima. Remover e recriar aqui garante que a
      // correção do "toque duplo" também se aplique a quem já tinha o app
      // instalado, não só a instalações novas. Idempotente e seguro: apagar
      // um canal inexistente (instalação nova) é um no-op.
      try {
        await implementacaoAndroid?.deleteNotificationChannel(canalId);
      } catch (e) {
        debugPrint('⚠️ [NotificacaoService] Falha ao remover canal antigo de check-in: $e');
      }
      // Mesmo motivo acima: quem já tinha o app instalado ANTES do ajuste
      // "Despertador de Emergência" (2026-08-15, `audioAttributesUsage:
      // AudioAttributesUsage.alarm`) ficaria preso no canal antigo
      // (STREAM_NOTIFICATION) para sempre sem isto.
      try {
        await implementacaoAndroid?.deleteNotificationChannel(canalAlertaRecebidoId);
      } catch (e) {
        debugPrint('⚠️ [NotificacaoService] Falha ao remover canal antigo de alerta recebido: $e');
      }
      try {
        await prefsMigracao.setBool(_chaveCanaisMigrados, true);
      } catch (e) {
        debugPrint('⚠️ [NotificacaoService] Falha ao persistir flag de migração de canais: $e');
      }
    }

    // `createNotificationChannel` é barato/seguro chamar sempre, mesmo
    // com o canal já existente (o Android trata como no-op) — os
    // próprios canais em si são um recurso PERSISTIDO pelo sistema
    // operacional (sobrevivem a reinícios do app), diferente da migração
    // acima.
    await implementacaoAndroid?.createNotificationChannel(canal);
    await implementacaoAndroid?.createNotificationChannel(canalAlertaRecebido);
    await implementacaoAndroid?.createNotificationChannel(canalMonitoramento);
    await implementacaoAndroid?.createNotificationChannel(canalSolicitacaoMonitoramento);
    await implementacaoAndroid?.createNotificationChannel(canalAlertaEnviado);

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

  /// `true` se o app já pode agendar alarmes EXATOS (`AlarmManager.
  /// canScheduleExactAlarms()`) — checagem 100% silenciosa, nunca navega
  /// para Configurações (ao contrário de [solicitarAlarmesExatos]). Usado
  /// por [OnboardingService] para mostrar o status do item "Notificações
  /// e alarmes" sem disparar nenhuma navegação indesejada só de exibir a
  /// tela. Sempre `true` em versões do Android onde a permissão nem existe
  /// (< 12) — nunca lança exceção (permissivo em caso de erro/plataforma
  /// não suportada).
  static Future<bool> podeAgendarAlarmesExatos() async {
    try {
      final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await implementacaoAndroid?.canScheduleExactNotifications() ?? true;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao checar permissão de alarmes exatos: $e');
      return true;
    }
  }

  /// Solicita a permissão de alarmes exatos — abre a tela nativa de
  /// Configurações se ainda não concedida (Android 12+); no-op imediato
  /// (retorna `true`) em versões mais antigas ou se já concedida. Usado
  /// pelo botão "Conceder" do item "Notificações e alarmes" em
  /// [OnboardingService]/`OnboardingScreen`.
  static Future<bool> solicitarAlarmesExatos() async {
    try {
      final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await implementacaoAndroid?.requestExactAlarmsPermission() ?? true;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao solicitar permissão de alarmes exatos: $e');
      return true;
    }
  }

  /// Solicita a permissão de notificação em tela cheia (`USE_FULL_SCREEN_INTENT`,
  /// só existe a partir do Android 14) — abre a tela nativa de
  /// Configurações se ainda não concedida; no-op imediato (retorna `true`)
  /// em versões mais antigas ou se já concedida. Diferente de
  /// [podeAgendarAlarmesExatos], não há um método NATIVO separado só de
  /// checagem silenciosa para esta permissão específica (ver
  /// `FlutterLocalNotificationsPlugin.java`) — por isso
  /// `OnboardingScreen` só atualiza o status deste item DEPOIS do
  /// usuário tocar em "Conceder" (nunca ao simples abrir a tela).
  static Future<bool> solicitarPermissaoTelaCheia() async {
    try {
      final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await implementacaoAndroid?.requestFullScreenIntentPermission() ?? true;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao solicitar permissão de tela cheia: $e');
      return true;
    }
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
      // Áudio 100% sob controle do player do próprio app (ver o mesmo
      // ajuste, com a explicação completa, no canal 'checkin_rotina' em
      // [inicializar]) — nunca o som padrão de notificação do sistema.
      playSound: false,
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
      // Modo "Despertador de Emergência" (item 4, reespecificação do
      // usuário, 2026-08-15): precisa continuar DESCARTÁVEL por arraste
      // — `ongoing: true` (valor anterior) bloqueia completamente o
      // gesto de swipe, o que impediria o usuário de silenciar o alarme
      // dessa forma. `autoCancel` continua `false` de propósito: um
      // toque simples abre o app SEM remover a notificação sozinho — é
      // [cancelarNotificacaoAlertaRecebido] (chamado explicitamente ao
      // abrir `AlertaRecebidoScreen`) quem a remove de fato, o que por
      // sua vez para o som insistente (ver `additionalFlags` abaixo).
      ongoing: false,
      fullScreenIntent: true,
      autoCancel: false,
      playSound: true,
      // Ver comentário completo no canal (acima, em [inicializar]) —
      // roteia o som desta notificação pelo STREAM_ALARM.
      audioAttributesUsage: AudioAttributesUsage.alarm,
      // MODO "DESPERTADOR DE EMERGÊNCIA" (items 3/4, reespecificação do
      // usuário, 2026-08-15) — `Notification.FLAG_INSISTENT` (valor 4),
      // aplicado via `additionalFlags` (recurso nativo padrão do
      // Android, não um hack): repete o SOM em loop contínuo até a
      // notificação ser CANCELADA (arrastada para descartar, ou removida
      // programaticamente — ver [cancelarNotificacaoAlertaRecebido]).
      // ÚNICO mecanismo de loop que funciona de forma 100% confiável
      // mesmo com o app TOTALMENTE fechado: roda inteiramente dentro da
      // MESMA chamada `flutter_local_notifications` que já posta esta
      // notificação com sucesso no isolate headless do
      // `firebase_messaging` (diferente do plugin nativo customizado
      // `AlertaRecebidoAlarmService`/`AlertaRecebidoAlarmPlugin`, que só
      // funciona quando o app já tem um engine "de verdade" rodando —
      // ver documentação completa em `AlertaRecebidoAlarmService.kt`).
      additionalFlags: Int32List.fromList(<int>[4]),
      // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-16, Moto
      // G7 Play — reespecificação do usuário): a vibração REMOVIDA por
      // completo — `FLAG_INSISTENT` (acima) mantém o motor de vibração
      // repetindo pra sempre em loop junto com o som, e nesse aparelho
      // esse loop ficava PRESO mesmo depois da notificação já ter sido
      // cancelada (só desligar o aparelho parava) — um bug de
      // fabricante/SO fora do nosso controle de código, mas que só afeta
      // a vibração; o som (roteado por STREAM_ALARM, ver
      // `audioAttributesUsage` acima) continua funcionando e sendo
      // corretamente interrompido pelos mesmos mecanismos já existentes
      // (toque na notificação, abrir o app, ou o teto de 5 minutos — ver
      // [_tempoMaximoAlarmeRecebido]). `enableVibration: false` aqui é
      // redundante com o mesmo ajuste já feito no CANAL (ver
      // [inicializar]) — o Android decide pelo canal, mas deixar
      // explícito também aqui documenta a intenção sem depender de
      // ninguém ler o outro lugar.
      enableVibration: false,
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
      // Item pendente (2026-08-14, reespecificação do usuário): "todas as
      // mensagens" devem mostrar o horário e data EXATA — capturado aqui,
      // no momento real da entrega no dispositivo (mesmo instante em que
      // AlertasRecebidosService.registrarAlertaRecebido grava `recebido_em`
      // no SQLite local), e propagado pelo payload até AlertaRecebidoScreen
      // (ver `recebidoEm` abaixo e em [_processarRespostaPayloadJson]).
      'recebidoEm': DateTime.now().toIso8601String(),
      if (nomeRemetente != null) 'nomeRemetente': nomeRemetente,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (fotoUrl != null && fotoUrl.isNotEmpty) 'fotoUrl': fotoUrl,
    });

    // Modo "Despertador de Emergência" (item 3 do pedido): inicia o
    // alarme sonoro contínuo em volume máximo EM PARALELO à notificação
    // de tela cheia abaixo — ver [iniciarAlarmeCritico].
    unawaited(iniciarAlarmeCritico());

    await _plugin.show(
      _idNotificacaoAlertaRecebido(idEntrega),
      tituloAlerta,
      mensagem,
      details,
      payload: payload,
    );

    // TETO DE SEGURANÇA (2026-08-15, mesmo pedido do usuário que motivou
    // a correção do "não consegui fazer parar de vibrar"; ajustado de 3
    // para 5 minutos no mesmo dia, após confirmar em teste físico que o
    // teto nativo/este agendado já disparavam corretamente): agenda um
    // alarme nativo de UMA VEZ, em [_tempoMaximoAlarmeRecebido] (5
    // minutos — MESMO valor já usado por
    // `AlertaRecebidoAlarmService._TEMPO_MAXIMO_TOCANDO`, do lado
    // nativo), que cancela esta notificação sozinho se o usuário nunca
    // interagir com ela.
    //
    // POR QUE NÃO REAPROVEITAR O TIMEOUT NATIVO JÁ EXISTENTE: aquele
    // timeout vive DENTRO de `AlertaRecebidoAlarmService` — mas esse
    // Service só chega a INICIAR quando `iniciarAlarmeCritico()` (acima)
    // funciona, e ele já é protegido por try/catch justamente porque
    // FALHA (`MissingPluginException`) sempre que esta função roda no
    // isolate HEADLESS do FCM (app fechado) — exatamente o cenário onde
    // uma rede de segurança é mais necessária. `AndroidAlarmManager`
    // (usado abaixo) é um plugin FEDERADO de verdade (registrado em
    // QUALQUER engine automaticamente, mesmo padrão já usado com sucesso
    // em outros callbacks headless deste app, ver
    // `RotinaAlarmeService`/`RetryUploadService`), então funciona de
    // forma confiável não importa o estado do app.
    try {
      await AndroidAlarmManager.oneShot(
        _tempoMaximoAlarmeRecebido,
        _idAlarmeSegurancaAlertaRecebido(idEntrega),
        _callbackTimeoutSegurancaAlertaRecebido,
        exact: true,
        wakeup: true,
        allowWhileIdle: true, // bypassa Doze — o dispositivo receptor pode estar com a tela apagada/bloqueada pelos 5 minutos inteiros.
        rescheduleOnReboot: false,
        params: {'idEntrega': idEntrega},
      );
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao agendar o teto de segurança '
          'do alerta recebido — a notificação só será cancelada por interação '
          'manual do usuário: $e');
    }
  }

  /// Mesmo teto (5 minutos — reespecificado pelo usuário, 2026-08-15;
  /// era 3 minutos) já usado pelo timeout nativo de
  /// `AlertaRecebidoAlarmService._TEMPO_MAXIMO_TOCANDO` — ver
  /// documentação completa em [exibirNotificacaoAlertaRecebido] sobre por
  /// que este, implementado separadamente via `AndroidAlarmManager`, é
  /// necessário mesmo já existindo aquele.
  static const Duration _tempoMaximoAlarmeRecebido = Duration(minutes: 5);

  /// Id estável derivado do [idEntrega] — evita colidir com os ids de
  /// notificação de check-in de rotina (idAlarme/idAlarme+10000).
  /// Compartilhado entre [exibirNotificacaoAlertaRecebido] (posta) e
  /// [cancelarNotificacaoAlertaRecebido] (remove) para nunca divergir.
  static int _idNotificacaoAlertaRecebido(String idEntrega) =>
      30000 + (idEntrega.hashCode.abs() % 60000);

  /// Id do alarme nativo do teto de segurança (ver
  /// [_tempoMaximoAlarmeRecebido]) — faixa DELIBERADAMENTE separada de
  /// [_idNotificacaoAlertaRecebido] (namespace diferente do
  /// `AndroidAlarmManager`, mas por clareza/depuração nunca reaproveita o
  /// mesmo número) e dos demais ids de alarme nativo já usados neste app
  /// (`RotinaAlarmeService`, `RetryUploadService`, `AlarmeService`).
  static int _idAlarmeSegurancaAlertaRecebido(String idEntrega) =>
      90000 + (idEntrega.hashCode.abs() % 60000);

  /// Remove a notificação do alerta recebido — item 4 do pedido
  /// ("Despertador de Emergência"): cancelar a notificação
  /// programaticamente é o que efetivamente para o som insistente em
  /// loop (`Notification.FLAG_INSISTENT`, ver
  /// [exibirNotificacaoAlertaRecebido]), já que este só continua
  /// tocando "até a notificação ser cancelada". Chamado por
  /// `AlertaRecebidoScreen` assim que o usuário abre a tela (qualquer
  /// caminho: toque na notificação, no card do Histórico, etc.) ou toca
  /// no link do mapa. Seguro chamar mesmo sem nenhuma notificação ativa
  /// com este [idEntrega] (no-op).
  static Future<void> cancelarNotificacaoAlertaRecebido(String idEntrega) async {
    try {
      await _plugin.cancel(_idNotificacaoAlertaRecebido(idEntrega));
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao cancelar notificação de alerta recebido: $e');
    }
    // Cancela também o teto de segurança agendado (ver
    // [exibirNotificacaoAlertaRecebido]) — a notificação já foi resolvida
    // por interação do usuário, então o alarme de 5 minutos não precisa
    // mais disparar. Puramente cosmético/limpeza: mesmo se este cancel
    // falhar ou o alarme já tiver disparado, [_callbackTimeoutSegurancaAlertaRecebido]
    // chamar [cancelarNotificacaoAlertaRecebido] de novo é inofensivo
    // (idempotente).
    try {
      await AndroidAlarmManager.cancel(_idAlarmeSegurancaAlertaRecebido(idEntrega));
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao cancelar o teto de segurança do alerta recebido: $e');
    }
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

  /// Exibe a notificação de confirmação "alerta enviado" — usada
  /// especificamente pelo gesto de descarte do Alarme de Rotina (arrastar
  /// o botão azul/teclado de PIN para cima, ver
  /// `AlarmeDisparadoScreen._descartarPorArraste`), o único caso em que o
  /// app precisa devolver a tela 100% ao Android ANTES de conseguir
  /// mostrar qualquer confirmação — por isso vira uma notificação do
  /// sistema, em vez do diálogo/tela cheia in-app usado nos demais
  /// disparos (3ª tentativa de PIN incorreta, tempo esgotado etc., que já
  /// mostram a própria tela verde de confirmação sem precisar disto).
  static Future<void> exibirNotificacaoAlertaEnviado() async {
    await inicializar();
    final l10n = await L10nHeadlessService.obter();

    final androidDetails = AndroidNotificationDetails(
      canalAlertaEnviadoId,
      canalAlertaEnviadoNome,
      channelDescription: canalAlertaEnviadoDescricao,
      importance: Importance.low,
      priority: Priority.low,
      autoCancel: true,
      playSound: false,
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      // Id fixo e estável: não há necessidade de múltiplas notificações
      // deste tipo simultâneas — uma nova sempre substitui a anterior.
      70000,
      l10n.notifDescarteAlertaEnviadoTitulo,
      l10n.notifDescarteAlertaEnviadoCorpo,
      details,
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

      // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-15, Moto
      // G7 Play — "vibrou e não consegui fazer parar"): antes, parar o
      // alarme sonoro/vibração insistente (`FLAG_INSISTENT`) só acontecia
      // DENTRO de [AlertaRecebidoScreen] (`initState`) — ou seja,
      // dependia inteiramente do `push()` abaixo ter sucesso. Mas esta
      // função também roda no isolate HEADLESS de
      // `onDidReceiveBackgroundNotificationResponse` (toque na
      // notificação com o app TOTALMENTE fechado) — nesse isolate NUNCA
      // existe `runApp()`/Navigator, então `appNavigatorKey.currentState`
      // é sempre `null` e `?.push(...)` é um NO-OP silencioso: a tela
      // nunca abria, [cancelarNotificacaoAlertaRecebido] nunca era
      // chamado, e a notificação (com sua vibração/som em loop,
      // `Notification.FLAG_INSISTENT`) ficava tocando/vibrando PARA
      // SEMPRE, sem nenhuma forma de parar a não ser matar o app pelo
      // sistema. Agora, parar o alarme e cancelar a notificação
      // acontecem AQUI, incondicionalmente, ANTES da tentativa de
      // navegação — [cancelarNotificacaoAlertaRecebido] usa só
      // `flutter_local_notifications` (plugin federado, registrado
      // automaticamente em QUALQUER engine, inclusive headless — ao
      // contrário do MethodChannel customizado usado por
      // [pararAlarmeCritico], protegido por seu próprio try/catch), então
      // funciona de forma confiável não importa o estado do app. A
      // navegação para [AlertaRecebidoScreen] continua best-effort logo
      // abaixo — quando não há Navigator vivo (app fechado), o usuário só
      // vê os detalhes ao reabrir o app manualmente (já persistidos
      // localmente por `AlertasRecebidosService`), mas o alarme já para
      // na hora do toque, não importa o estado do app.
      final idEntregaAlerta = dados['idEntrega'] as String?;
      unawaited(pararAlarmeCritico());
      if (idEntregaAlerta != null) {
        unawaited(cancelarNotificacaoAlertaRecebido(idEntregaAlerta));
      }

      appNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) => AlertaRecebidoScreen(
            mensagem: (dados['mensagem'] as String?) ?? '',
            nomeRemetente: dados['nomeRemetente'] as String?,
            latitude: (dados['latitude'] as num?)?.toDouble(),
            longitude: (dados['longitude'] as num?)?.toDouble(),
            fotoUrl: dados['fotoUrl'] as String?,
            idEntrega: idEntregaAlerta,
            recebidoEm: dados['recebidoEm'] as String?,
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

/// Callback headless do teto de segurança agendado por
/// [NotificacaoService.exibirNotificacaoAlertaRecebido] — roda num
/// isolate/engine SEPARADO do processo principal (mesmo mecanismo já
/// usado por `RotinaAlarmeService`/`RetryUploadService`), por isso é uma
/// função TOP-LEVEL (fora de qualquer classe) anotada com
/// `@pragma('vm:entry-point')`, obrigatória para o `AndroidAlarmManager`
/// conseguir encontrá-la mesmo depois do tree-shaking do Dart AOT em
/// builds de release.
///
/// Se os 5 minutos se esgotarem sem o usuário ter interagido com a
/// notificação (que já teria cancelado este mesmo alarme, ver
/// [NotificacaoService.cancelarNotificacaoAlertaRecebido]), para o
/// alarme sonoro nativo (best-effort — pode já nem estar tocando, ver
/// documentação completa em [NotificacaoService.exibirNotificacaoAlertaRecebido]
/// sobre por que este teto existe SEPARADO daquele) e cancela a
/// notificação (o que efetivamente encerra o som/vibração insistentes do
/// `flutter_local_notifications`, o caminho que SEMPRE funciona
/// independente do estado do app).
@pragma('vm:entry-point')
void _callbackTimeoutSegurancaAlertaRecebido(int id, Map<String, dynamic> params) async {
  final idEntrega = params['idEntrega'] as String?;
  if (idEntrega == null) return;

  debugPrint('⏰ [HEADLESS] Teto de segurança (5min) do alerta recebido '
      '#$idEntrega atingido sem confirmação — parando o alarme.');

  await NotificacaoService.pararAlarmeCritico();
  await NotificacaoService.cancelarNotificacaoAlertaRecebido(idEntrega);
}