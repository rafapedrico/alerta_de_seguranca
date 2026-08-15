import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

import '../app_navigator.dart';
import '../firebase_options.dart';
import '../widgets/monitoramento_decisao_dialog.dart';
import 'alertas_recebidos_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_sync_service.dart';
import 'notificacao_service.dart';

/// Handler de SEGUNDO PLANO/TERMINADO do FCM — chamado pelo Android num
/// ISOLATE/ENGINE TOTALMENTE SEPARADO, sem NENHUM estado compartilhado
/// com o processo principal do app.
///
/// REESPECIFICAÇÃO DO USUÁRIO (2026-08-15, requisitos oficiais do
/// Flutter/FlutterFire): antes, este handler era um método ESTÁTICO
/// dentro da classe [FcmService] — funciona na prática na maioria dos
/// casos, mas diverge do padrão oficial documentado pela própria
/// FlutterFire (`FirebaseMessaging.onBackgroundMessage`), que exige uma
/// função TOP-LEVEL (fora de qualquer classe), não um método de classe
/// "que precise de inicialização". Diagnosticado ao vivo via logcat
/// (2026-08-15): o broadcast nativo do FCM chegava
/// (`FLTFireMsgReceiver: broadcast received for message`), mas a engine
/// Flutter de background nunca era instanciada
/// (`FLTFireBGExecutor: Creating background FlutterEngine instance`
/// nunca aparecia nos logs) — o Android ficava reagendando via
/// `AlarmManager: setExactAndAllowWhileIdle [name: FcmRetry...]`
/// repetidamente, sem nunca completar. Descoberto em paralelo que o
/// "Battery Care"/"Smart Background" PRÓPRIO da Motorola também
/// restringia o app (`BatteryCare: [SmartBackgroundController] skip
/// foreground package`, fora do controle deste código — precisa de
/// ajuste manual nas configurações do aparelho), mas mover este handler
/// para o formato 100% conforme à documentação oficial é a correção de
/// código correta e a que efetivamente está ao alcance do app, eliminando
/// de vez a divergência como possível causa/agravante.
///
/// `@pragma('vm:entry-point')` é OBRIGATÓRIO: sem ele, o compilador
/// Dart AOT (release) pode fazer tree-shaking desta função por não
/// enxergar nenhuma chamada estática a ela no código (só é referenciada
/// via callback handle nativo) — resultando exatamente no sintoma
/// observado (nada acontece em segundo plano, sem nenhuma exceção
/// visível). `WidgetsFlutterBinding.ensureInitialized()` também é
/// exigido pela documentação oficial antes de usar qualquer plugin
/// (`flutter_local_notifications`, `http`, `Firebase`) neste isolate
/// novo/isolado — sem binding próprio, sem estado compartilhado com o
/// processo principal.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage mensagem) async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('📩 [FCM Recebido - Background] ${mensagem.data}');
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }
    // Requisito 4 (renderização nativa a partir do isolate de
    // background): [FcmService._tratarDadosDoAlerta] já despacha para
    // [NotificacaoService.exibirNotificacaoAlertaRecebido], que monta o
    // canal de alta prioridade (`Importance.max`) com `fullScreenIntent:
    // true` e `audioAttributesUsage: AudioAttributesUsage.alarm` (som
    // roteado pelo STREAM_ALARM) via `flutter_local_notifications` —
    // funciona sem alterações a partir deste isolate, já que o plugin
    // (diferente de plugins locais customizados deste app, ver
    // `SmsSender.kt`) é registrado automaticamente em QUALQUER engine
    // Flutter, inclusive este headless.
    await FcmService()._tratarDadosDoAlerta(mensagem.data);
  } catch (e) {
    debugPrint('⚠️ [FcmService] Falha ao processar mensagem em segundo plano: $e');
  }
}

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
/// CONFIRMAÇÃO DE ENTREGA: grava em `entregas_alerta/{id}/confirmacoes`
/// que o Push foi ENTREGUE NO DISPOSITIVO — não quando o usuário abre o
/// app ou lê a notificação. Este serviço grava essa confirmação assim
/// que `onMessage`/`onBackgroundMessage` executa (ver
/// [_tratarDadosDoAlerta]), o que acontece automaticamente na entrega da
/// mensagem pelo SO, mesmo com a tela bloqueada e o app fechado — nunca
/// depende de interação do usuário.
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

  bool _infraestruturaRegistrada = false;
  bool _listenerDeRenovacaoRegistrado = false;

  /// Registra o handler de background do FCM, solicita a permissão de
  /// notificação (`POST_NOTIFICATIONS`) e liga o listener de primeiro
  /// plano — nada disto depende de um usuário autenticado, então deve
  /// rodar uma única vez por processo, o mais cedo possível (ver
  /// `main.dart`, logo após `Firebase.initializeApp()`).
  ///
  /// CORREÇÃO: antes, todo este registro só acontecia dentro de
  /// [inicializar], chamado exclusivamente em `login_screen.dart` após um
  /// login manual bem-sucedido — como a política "Opção A"
  /// (`FirebaseAuthService().logout()` a cada cold start) sempre deixa o
  /// app sem sessão logo no início, um aparelho recém-instalado (ou que
  /// ainda não completou o primeiro login nesta execução) ficava sem o
  /// handler de background e sem a permissão de notificação armados —
  /// alertas chegando nessa janela eram perdidos silenciosamente. Separar
  /// este registro (sem dependência de login) da sincronização do token
  /// (que precisa de `uid`, ver [inicializar]) resolve isso: agora a
  /// entrega/exibição da notificação funciona independente de estar
  /// logado no momento em que o Push chega.
  Future<void> registrarInfraestrutura() async {
    if (_infraestruturaRegistrada) return;
    if (Firebase.apps.isEmpty) return;

    try {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      await FirebaseMessaging.instance.requestPermission();
      FirebaseMessaging.onMessage.listen(_processarMensagem);
      _infraestruturaRegistrada = true;
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao registrar infraestrutura de FCM: $e');
    }
  }

  /// Sincroniza o `fcmToken` atual do aparelho com `usuarios/{uid}.fcmToken`
  /// — deve ser chamado a cada login bem-sucedido (não só uma vez por
  /// processo: "Sair da conta" em Configurações permite logar de novo com
  /// outra conta sem cold start, ver `configuracoes_tab.dart`), já que
  /// precisa do `uid` da sessão ativa para saber em qual documento gravar.
  /// Garante primeiro que [registrarInfraestrutura] já rodou.
  Future<void> inicializar() async {
    await registrarInfraestrutura();
    if (Firebase.apps.isEmpty) return;

    try {
      final messaging = FirebaseMessaging.instance;

      // CORREÇÃO (bug real confirmado em teste físico, 2026-08-14 — Razr
      // com `fcmToken` gravado no Firestore, mas TODO envio a ele falhava
      // no `[FCM Enviado] 0 enviado(s), 1 falha(s) de 1 token(s)` da Cloud
      // Function): `getToken()` sozinho devolve o token já em CACHE local
      // sempre que existir um — um `pm clear`/reinstalação some com esse
      // cache, mas qualquer outra causa de invalidação do lado do servidor
      // FCM (ex: o token expirar/ser revogado sem o SDK perceber) deixa o
      // cache local "vivo" apontando pra um registro morto, e `getToken()`
      // nunca vai buscar um substituto sozinho. `deleteToken()` força o
      // SDK a esquecer esse cache e negociar um registro NOVO de verdade
      // no próximo `getToken()` — a única forma confiável de garantir que
      // o valor gravado no Firestore é sempre um registro vivo, não uma
      // cópia local potencialmente morta.
      try {
        await messaging.deleteToken();
      } catch (e) {
        debugPrint('⚠️ [FcmService] Falha ao invalidar token em cache (seguindo mesmo assim): $e');
      }

      final token = await messaging.getToken();
      if (token != null) {
        debugPrint('📲 [FcmService] Novo token FCM obtido (...${token.substring(token.length - 12)}) — sincronizando com o Firestore.');
        await FirebaseSyncService().atualizarFcmToken(token);
        debugPrint('📲 [FcmService] Token FCM inicial sincronizado.');
      } else {
        // ANTES: esse caso não gerava NENHUM log — uma falha silenciosa
        // real (getToken() devolvendo null, ex: sem Google Play Services
        // disponível/atualizado) ficava indistinguível de "tudo certo".
        debugPrint('⚠️ [FcmService] getToken() devolveu null — nenhum token para sincronizar com o Firestore.');
      }

      if (!_listenerDeRenovacaoRegistrado) {
        messaging.onTokenRefresh.listen((novoToken) {
          debugPrint('📲 [FcmService] Token FCM renovado pelo SO (...${novoToken.substring(novoToken.length - 12)}) — sincronizando.');
          FirebaseSyncService().atualizarFcmToken(novoToken);
        });
        _listenerDeRenovacaoRegistrado = true;
      }
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao sincronizar token FCM: $e');
    }
  }

  /// Handler de PRIMEIRO PLANO (app aberto e em uso).
  Future<void> _processarMensagem(RemoteMessage mensagem) async {
    debugPrint('📩 [FCM Recebido - Foreground] ${mensagem.data}');
    await _tratarDadosDoAlerta(mensagem.data, emPrimeiroPlano: true);
  }

  /// Lógica compartilhada entre primeiro e segundo plano: despacha o
  /// tratamento conforme o campo `tipo` da mensagem data-only recebida —
  /// alerta de emergência de terceiro ([_tratarAlertaEmergencia]) ou push
  /// da aba Monitoramento ([_tratarPushMonitoramento]). Qualquer outro
  /// `tipo` (ou ausente) é ignorado silenciosamente.
  ///
  /// [emPrimeiroPlano] só é `true` quando chamado por [_processarMensagem]
  /// (app aberto e em uso, ver `FirebaseMessaging.onMessage`) — usado por
  /// [_tratarPushMonitoramento] para decidir entre abrir o modal de decisão
  /// direto ou apenas exibir a notificação normal.
  Future<void> _tratarDadosDoAlerta(
    Map<String, dynamic> data, {
    bool emPrimeiroPlano = false,
  }) async {
    final tipo = data['tipo'] as String?;

    if (tipo == _tipoAlertaEmergencia) {
      await _tratarAlertaEmergencia(data);
      return;
    }

    if (tipo != null && _tiposPushMonitoramento.contains(tipo)) {
      await _tratarPushMonitoramento(data, tipo, emPrimeiroPlano: emPrimeiroPlano);
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
  /// FCM.
  Future<void> _tratarAlertaEmergencia(Map<String, dynamic> data) async {
    final idEntrega = data['idEntrega'] as String?;
    final mensagem = (data['mensagem'] as String?) ?? '';
    final nomeRemetente = data['nomeRemetente'] as String?;
    final fotoUrl = data['fotoUrl'] as String?;
    // Valores do FCM `data` chegam sempre como String — ver
    // functions/alertaHibridoService.js, que serializa com `.toString()`.
    final latitude = double.tryParse((data['latitude'] as String?) ?? '');
    final longitude = double.tryParse((data['longitude'] as String?) ?? '');
    if (idEntrega == null) return;

    try {
      await FirebaseSyncService().confirmarEntregaAlerta(idEntrega);
      debugPrint('✅ [Confirmação de Entrega Enviada] entregas_alerta/$idEntrega');
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao confirmar entrega no dispositivo: $e');
    }

    // Persiste localmente (indicador de "não visualizado" no HomeScreen +
    // item clicável na aba Histórico, ver AlertasRecebidosService) —
    // best-effort, nunca bloqueia os passos acima/abaixo.
    unawaited(AlertasRecebidosService.registrarAlertaRecebido(
      idEntrega: idEntrega,
      nomeRemetente: nomeRemetente,
      mensagem: mensagem,
      latitude: latitude,
      longitude: longitude,
      fotoUrl: fotoUrl,
    ));

    try {
      await NotificacaoService.exibirNotificacaoAlertaRecebido(
        idEntrega: idEntrega,
        mensagem: mensagem,
        nomeRemetente: nomeRemetente,
        fotoUrl: fotoUrl,
        latitude: latitude,
        longitude: longitude,
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
    String tipo, {
    required bool emPrimeiroPlano,
  }) async {
    final idPermissao = data['idPermissao'] as String?;
    if (idPermissao == null) return;

    final nomeContraparte = tipo == 'solicitacao_monitoramento'
        ? data['nomeSolicitante'] as String?
        : data['nomeAlvo'] as String?;

    // Só relevante para 'solicitacao_monitoramento': permite que o toque na
    // notificação abra DIRETO no modal de decisão (ver
    // `NotificacaoService.exibirNotificacaoMonitoramento`/deep link),
    // sem precisar de uma nova consulta ao Firestore para descobrir quem
    // está solicitando.
    final uidSolicitante = tipo == 'solicitacao_monitoramento'
        ? data['uidSolicitante'] as String?
        : null;
    final telefoneSolicitante = tipo == 'solicitacao_monitoramento'
        ? data['telefoneSolicitante'] as String?
        : null;

    // Com o app já ABERTO em primeiro plano, uma SOLICITAÇÃO recebida (não
    // uma resposta a uma solicitação já enviada) NÃO deve passar por um
    // banner/notificação discreta — abre o modal de decisão DIRETO no
    // centro da tela, sem exigir que o usuário toque em nada primeiro. Se
    // não houver um `BuildContext` válido no momento (ex: app em transição
    // de tela), cai no fallback abaixo e mostra a notificação normalmente.
    if (emPrimeiroPlano &&
        tipo == 'solicitacao_monitoramento' &&
        uidSolicitante != null) {
      final abriuDireto = await _tentarAbrirDecisaoDireto(
        idPermissao: idPermissao,
        uidSolicitante: uidSolicitante,
        nomeSolicitante: nomeContraparte ?? '',
        telefoneSolicitante: telefoneSolicitante ?? '',
      );
      if (abriuDireto) return;
    }

    try {
      await NotificacaoService.exibirNotificacaoMonitoramento(
        tipo: tipo,
        idPermissao: idPermissao,
        nomeContraparte: nomeContraparte,
        uidSolicitante: uidSolicitante,
        telefoneSolicitante: telefoneSolicitante,
      );
    } catch (e) {
      debugPrint(
          '⚠️ [FcmService] Falha ao exibir notificação de monitoramento ($tipo): $e');
    }
  }

  /// Ids de permissão com o modal de decisão ([exibirDialogoDecisaoMonitoramento])
  /// atualmente aberto — evita empilhar dois diálogos para a MESMA
  /// solicitação caso o FCM reentregue a mesma mensagem (retry do SO)
  /// enquanto o primeiro ainda está na tela.
  static final Set<String> _idsComDialogoAberto = {};

  /// Tenta abrir o modal de decisão direto sobre a tela atual (sem navegar
  /// para nenhuma aba/tela intermediária). Só funciona com o app
  /// efetivamente rodando em primeiro plano E o usuário já autenticado
  /// nesta sessão — fora disso (sem `BuildContext` disponível, ou sessão
  /// sem login) retorna `false` para o chamador cair no fallback de
  /// notificação normal.
  Future<bool> _tentarAbrirDecisaoDireto({
    required String idPermissao,
    required String uidSolicitante,
    required String nomeSolicitante,
    required String telefoneSolicitante,
  }) async {
    if (Firebase.apps.isEmpty || FirebaseAuthService().uidAtual == null) {
      return false;
    }
    final context = appNavigatorKey.currentContext;
    if (context == null) return false;

    if (_idsComDialogoAberto.contains(idPermissao)) {
      // Já em exibição (reentrega do FCM) — não empilha um segundo modal,
      // mas ainda assim reporta como "tratado" para não cair no fallback.
      return true;
    }

    _idsComDialogoAberto.add(idPermissao);
    try {
      await exibirDialogoDecisaoMonitoramento(
        context: context,
        idPermissao: idPermissao,
        uidSolicitante: uidSolicitante,
        nomeSolicitante: nomeSolicitante,
        telefoneSolicitante: telefoneSolicitante,
      );
    } finally {
      _idsComDialogoAberto.remove(idPermissao);
    }
    return true;
  }
}
