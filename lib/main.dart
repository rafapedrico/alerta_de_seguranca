import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/encryption_service.dart';

import 'services/wallpaper_service.dart';
import 'services/font_scale_service.dart';
import 'services/database_helper.dart';
import 'services/alarme_service.dart';
import 'services/notificacao_service.dart';
import 'services/api_service.dart';
import 'services/volume_sos_service.dart';
import 'services/emergency_alert_service.dart';
import 'services/plano_limite_service.dart';
import 'services/captura_dissuasao_service.dart';
import 'services/rotina_alarme_service.dart';
import 'app_navigator.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'widgets/pin_dialog.dart';

/// Rota especial reconhecida no cold start quando o app é iniciado pela
/// `LockscreenCameraActivity` nativa (gatilho físico de SOS com o
/// aparelho bloqueado/app completamente fechado). Precisa espelhar
/// EXATAMENTE a constante `ROTA_INICIAL_SOS_FISICO` declarada in
/// `LockscreenCameraActivity.kt`.
///
/// IMPORTANTE: esta string NUNCA é usada como uma rota nomeada de fato
/// navegável pelo `Navigator` — o [MaterialApp] não possui nenhum
/// sistema de rotas nomeadas (`routes`/`initialRoute`), apenas `home` +
/// [onGenerateRoute] (ver [SecurityCheckApp]), que sempre resolve
/// QUALQUER nome de rota de volta para a tela padrão (`LoginScreen`),
/// evitando por completo o erro "Could not navigate to initial route".
/// Esta constante é apenas INSPECIONADA uma única vez, aqui em
/// `main()`, via `PlatformDispatcher.defaultRouteName`, para decidir se
/// o fluxo de SOS deve ser disparado automaticamente assim que o
/// primeiro frame do app for renderizado.
const String _rotaInicialSosFisico = '/sos_fisico_lockscreen';

/// Rota especial reconhecida no cold start quando o app é iniciado pela
/// `RotinaCheckinAlarmActivity` nativa (disparo de um alarme de
/// check-in de ROTINA com o aparelho bloqueado/app fechado). Precisa
/// espelhar EXATAMENTE a constante `ROTA_INICIAL_ROTINA_ALARME` declarada em
/// `RotinaCheckinAlarmActivity.kt`. Assim como `_rotaInicialSosFisico`,
/// é apenas INSPECIONADA uma única vez aqui em `main()` — a navegação
/// real para o diálogo de confirmação de check-in é feita via
/// `appNavigatorKey` após o primeiro frame, e não através de rotas
/// nomeadas de fato.
const String _rotaInicialRotinaAlarme = '/rotina_alarme_confirmacao';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Detecta, ainda ANTES de qualquer inicialização assíncrona, se este
  // cold start específico foi disparado pela LockscreenCameraActivity
  // nativa (gatilho físico de SOS com o aparelho bloqueado/app
  // fechado). O valor é apenas guardado aqui — o disparo efetivo do SOS
  // só ocorre depois que o Navigator estiver pronto (ver
  // addPostFrameCallback logo abaixo de runApp()), garantindo que
  // `appNavigatorKey.currentState` já exista.
  final bool coldStartViaSosFisico =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
          _rotaInicialSosFisico;

  // Idem, para o cold start disparado pela RotinaCheckinAlarmActivity
  // nativa (alarme de check-in de rotina tocando em loop, com o
  // aparelho bloqueado/app fechado).
  final bool coldStartViaRotinaAlarme =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
          _rotaInicialRotinaAlarme;

  // Initialize AES-256 encryption service before running the app
  EncryptionService().initialize();

  // Carrega as preferências salvas (plano de fundo e tamanho de fonte)
  // antes de exibir a UI, garantindo que o app já abra com os valores
  // corretos escolhidos anteriormente pelo usuário.
  await WallpaperService.inicializar();
  await FontScaleService.inicializar();

  // Regra de segurança/privacidade: a cada cold start real do aplicativo
  // (processo novo), o estado de liberação da Auditoria de Eventos
  // Sensíveis é resetado. Isso garante que, mesmo que a trava de 3h já
  // tenha sido cumprida em uma sessão anterior, o app sempre "esqueça"
  // essa liberação assim que for totalmente fechado e reaberto — embora,
  // se as 3h desde a última solicitação já tiverem se passado, a tela de
  // auditoria libera novamente de forma automática ao ser reaberta.
  await DatabaseHelper().resetarSessaoAuditoria();

  // Inicializa o plugin android_alarm_manager_plus, necessário para o
  // agendamento de alarmes NATIVOS que garantem o disparo de emergência
  // mesmo com o app fechado ou em segundo plano (ver AlarmeService).
  await AlarmeService.inicializar();

  // Inicializa o plugin flutter_local_notifications (Etapa 3), usado
  // pelos alarmes de rotina/check-in para exibir a notificação com a
  // ação rápida "✅ Cheguei bem", tanto em primeiro quanto em segundo
  // plano.
  await NotificacaoService.inicializar();

  // Inicia o Foreground Service nativo (VolumeSosService) que monitora
  // o gatilho físico de SOS: segurar o botão de Volume+ por 3 segundos
  // consecutivos, mesmo com a tela apagada ou o app minimizado. A
  // notificação persistente exigida pelo Android para manter o Service
  // ativo é exibida discretamente ("Segurança ativa"). Executado ANTES
  // de runApp() para garantir que o monitoramento já esteja de pé assim
  // que o usuário abrir o app.
  await VolumeSosService().iniciarMonitoramento();

  // Inicializa os contadores mensais de limite do Plano Gratuito (5
  // alertas + 2 fotos por mês), garantindo que já estejam sincronizados
  // com o mês corrente antes de qualquer disparo de emergência.
  await PlanoLimiteService().inicializar();

  // Assim que o gatilho físico de SOS for detectado (evento recebido do
  // lado nativo via EventChannel — cenário de app já em primeiro
  // plano/segundo plano, mas com o processo/engine vivo), aciona o
  // fluxo completo de SOS (ver [_dispararFluxoCompletoDeSos]).
  VolumeSosService().aoDispararSos.listen((_) {
    _dispararFluxoCompletoDeSos(
      origem: 'EventChannel (app em primeiro/segundo plano)',
    );
  });

  // Assim que um NOVO disparo de alarme de check-in de rotina chegar
  // via onNewIntent (cenário em que o app já está aberto/em primeiro
  // plano, e a RotinaCheckinAlarmActivity nativa já está viva), exibe
  // imediatamente o diálogo de PIN (com o botão "Pausar Alarme") por
  // cima da tela atual. Ver RotinaAlarmEventBridge/RotinaAlarmPlugin.kt.
  const EventChannel('com.example.security_check_app/rotina_alarme_events')
      .receiveBroadcastStream()
      .listen((_) {
    _exibirPinDeRotinaAoAbrirPorAlarme();
  }, onError: (e) {
    debugPrint('⚠️ [main] Erro no EventChannel de alarme de rotina: $e');
  });

  // Teste inicial de conectividade com o backend FastAPI (security_backend):
  // dispara um heartbeat para /api/status logo na abertura do app, apenas
  // para validação em desenvolvimento (visível no terminal do Uvicorn).
  // Executado em fire-and-forget (sem await) para NUNCA atrasar o boot do
  // app caso o servidor esteja fora do ar ou inacessível.
  _testarConectividadeInicialComBackend();

  // Regra de negócio crítica (Etapa 2), CORRIGIDA: verifica no SQLite se
  // um disparo de emergência já ocorreu em segundo plano (callback
  // headless do AlarmeService) enquanto o app estava fechado. Se sim, o
  // app NÃO É MAIS bloqueado por uma tela de PIN em tela cheia — em vez
  // disso, a HomeScreen é sempre aberta normalmente, e um diálogo leve
  // de confirmação de PIN é exibido POR CIMA dela (ver
  // [_TelaInicialComPossivelDialogoPin]), preservando a navegação livre
  // entre as abas (Segurança, Família, Histórico) o tempo todo.
  final bool aguardandoConfirmacaoPin =
      await DatabaseHelper().isAguardandoConfirmacaoPin();

  runApp(SecurityCheckApp(
    aguardandoConfirmacaoPin: aguardandoConfirmacaoPin,
  ));

  // Se este cold start foi disparado pelo gatilho físico de SOS com o
  // aparelho bloqueado/app fechado (LockscreenCameraActivity), aciona o
  // MESMO fluxo completo de SOS (dupla localização + SMS + Captura e
  // Dissuasão) assim que o primeiro frame do app for renderizado —
  // momento em que `appNavigatorKey.currentState` já está garantidamente
  // disponível para a navegação em tela cheia até a CameraCapturaScreen.
  if (coldStartViaSosFisico) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dispararFluxoCompletoDeSos(
        origem: 'cold start via LockscreenCameraActivity (SOS físico)',
      );
    });
  }

  // Se este cold start foi disparado pela RotinaCheckinAlarmActivity
  // nativa (alarme de check-in de rotina tocando in loop, com o
  // aparelho bloqueado/app fechado), exibe o diálogo de PIN (com o
  // botão "Pausar Alarme") assim que o primeiro frame for renderizado.
  // Como o app não usa rotas nomeadas de fato (ver onGenerateRoute),
  // não é possível ler um "idAlarme" via argumentos de rota — por isso
  // o valor é obtido diretamente do lado nativo através do
  // EventChannel/MethodChannel do RotinaAlarmPlugin (ver
  // [_exibirPinDeRotinaAoAbrirPorAlarme]).
  if (coldStartViaRotinaAlarme) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _exibirPinDeRotinaAoAbrirPorAlarme();
    });
  }
}

/// Exibe o diálogo de PIN (com o botão "Pausar Alarme" visível) por
/// cima da tela atual, usado tanto no cold start via
/// [RotinaCheckinAlarmActivity] quanto sempre que o
/// [RotinaAlarmeService] sinalizar (via EventChannel) um novo disparo
/// de alarme de rotina enquanto o app já está em primeiro/segundo
/// plano. Como não há como repassar o `idAlarme` por uma rota nomeada
/// de fato, esta função apenas identifica o ALARME DE ROTINA MAIS
/// RECENTE disparado (`ultimo_disparo_epoch`) para montar o contexto
/// exibido ao usuário — o próprio `pin_dialog.dart` não exige o
/// `idAlarme` para funcionar (o cancelamento nativo do som/alarme de
/// tolerância é feito de forma "global" no lado nativo/HEADLESS, ver
/// `RotinaAlarmSomBridge`).
Future<void> _exibirPinDeRotinaAoAbrirPorAlarme() async {
  final context = appNavigatorKey.currentContext;
  if (context == null) return;

  try {
    final config = await DatabaseHelper().getUserConfig();
    final pinReal = config?['pin_real'] as String?;

    // Busca, dentre todos os alarmes de rotina cadastrados, aquele com
    // o `ultimo_disparo_epoch` mais recente — presumivelmente o que
    // acabou de disparar e abriu a RotinaCheckinAlarmActivity.
    final alarmes = await DatabaseHelper().listarAlarmes();
    Map<String, dynamic>? maisRecente;
    for (final alarme in alarmes) {
      final epoch = alarme['ultimo_disparo_epoch'] as int?;
      if (epoch == null) continue;
      final epochAtual = maisRecente?['ultimo_disparo_epoch'] as int?;
      if (epochAtual == null || epoch > epochAtual) {
        maisRecente = alarme;
      }
    }
    final idAlarme = maisRecente?['id'] as int?;

    await exibirDialogoPin(
      context: context,
      pinEsperado: pinReal,
      segundosTolerancia: null,
      mostrarBotaoCancelar: true,
      aoConfirmarPinCorreto: () async {
        if (idAlarme != null) {
          await RotinaAlarmeService.confirmarCheckinRotina(idAlarme);
        }
      },
      aoCancelar: () {
        if (idAlarme != null) {
          RotinaAlarmeService.pausarAlarme(idAlarme);
        }
      },
    );
  } catch (e) {
    debugPrint('⚠️ Falha ao exibir diálogo de PIN do alarme de rotina: $e');
  }
}

/// Dispara, em sequência, o fluxo completo de emergência física:
/// 1. [EmergencyAlertService.dispararSosComDuplaLocalizacao] — envia o
///    primeiro SMS instantâneo (última localização em cache) seguido de
///    uma atualização com a localização em tempo real.
/// 2. [CapturaDissuasaoService.abrirCapturaSePermitido] — abre a
///    [CameraCapturaScreen] em tela cheia via [appNavigatorKey].
///
/// Reaproveitado tanto pelo listener do [VolumeSosService.aoDispararSos]
/// (app já em primeiro/segundo plano, engine "quente") quanto pelo
/// cenário de cold start via [LockscreenCameraActivity] (app
/// completamente fechado antes do gatilho físico). Fire-and-forget (sem
/// await no ponto de chamada), protegido internamente para NUNCA lançar
/// exceção nem travar o app — apenas logado via [debugPrint].
void _dispararFluxoCompletoDeSos({required String origem}) {
  debugPrint('🆘 [main] Disparando fluxo completo de SOS — origem: $origem');
  EmergencyAlertService().dispararSosComDuplaLocalizacao().then((_) {
    CapturaDissuasaoService().abrirCapturaSePermitido();
  }).catchError((e) {
    debugPrint('⚠️ [main] Falha ao processar SOS ($origem): $e');
  });
}

/// Dispara um heartbeat inicial para `/api/status` no backend FastAPI,
/// usado exclusivamente para validar em desenvolvimento que o app
/// conseguiu se conectar com sucesso ao servidor (visível nos logs do
/// Uvicorn). Protegido para nunca lançar exceção nem atrasar o startup.
///
/// OBS: o percentual de bateria é enviado com um valor fixo/simulado
/// (100%) por enquanto, evitando a dependência de um plugin extra
/// (ex: battery_plus) apenas para esse heartbeat de desenvolvimento.
Future<void> _testarConectividadeInicialComBackend() async {
  try {
    const double bateriaSimulada = 100;
    await ApiService().enviarStatus(bateriaSimulada, '1.0.0');
  } catch (e) {
    debugPrint('⚠️ Falha ao testar conectividade inicial com o backend: $e');
  }
}

class SecurityCheckApp extends StatelessWidget {
  const SecurityCheckApp({super.key, required this.aguardandoConfirmacaoPin});

  /// Quando `true` (verificado em main.dart via
  /// [DatabaseHelper.isAguardandoConfirmacaoPin]), indica que um disparo
  /// de emergência já ocorreu em segundo plano (callback headless do
  /// AlarmeService) enquanto o app estava fechado, e que o diálogo de
  /// confirmação de PIN deve ser exibido assim que a HomeScreen for
  /// montada — SEM bloquear a navegação/rota como antes.
  final bool aguardandoConfirmacaoPin;

  @override
  Widget build(BuildContext context) {
    // Ouve o fator de escala de fonte escolhido pelo usuário e reconstrói
    // todo o MaterialApp instantaneamente quando ele mudar, aplicando o
    // tamanho de letra em todas as telas do app.
    return ValueListenableBuilder<double>(
      valueListenable: FontScaleService.fontScaleNotifier,
      builder: (context, fatorFonte, _) {
        return MaterialApp(
          navigatorKey: appNavigatorKey,
          title: 'Security Check',
          debugShowCheckedModeBanner: false,

          theme: ThemeData(
            colorSchemeSeed: Colors.blue,
            useMaterial3: true,
          ),
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(fatorFonte),
              ),
              child: child!,
            );
          },
          // MOCK/TEMPORÁRIO: o app agora abre na tela de Login em vez de
          // ir direto para a HomeScreen. O botão "Entrar"/"Criar Conta"
          // dessas telas navega para a TelaInicialComPossivelDialogoPin
          // (fluxo principal já existente), simulando um login/cadastro
          // bem-sucedido sem nenhuma integração real de backend ainda.
          home: const LoginScreen(),

          // IMPORTANTE (correção do crash "Could not navigate to initial
          // route"): quando o app é iniciado a partir da
          // LockscreenCameraActivity nativa (gatilho físico de SOS com o
          // aparelho bloqueado/app fechado), o Android/Flutter tenta
          // resolver a rota nomeada especial `_rotaInicialSosFisico` como
          // rota INICIAL do MaterialApp. Como este app nunca usou rotas
          // nomeadas (`routes`/`initialRoute`), essa resolução falhava
          // com uma tela de erro vermelha, pois não havia absolutamente
          // nenhum `onGenerateRoute` para capturá-la.
          //
          // A partir de agora, QUALQUER nome de rota desconhecido
          // (incluindo `_rotaInicialSosFisico` e qualquer outro que
          // eventualmente apareça no futuro) é silenciosamente resolvido
          // de volta para a tela padrão (`LoginScreen`), preservando
          // exatamente o mesmo comportamento de `home`. O disparo real
          // do fluxo de SOS + a navegação para a CameraCapturaScreen NÃO
          // dependem desta rota nomeada — são tratados separadamente via
          // `coldStartViaSosFisico` + `addPostFrameCallback` em main(),
          // que empurra a CameraCapturaScreen por cima usando o
          // `appNavigatorKey`, assim que o Navigator já estiver pronto.
          onGenerateRoute: (settings) {
            return MaterialPageRoute(
              builder: (_) => const LoginScreen(),
              settings: settings,
            );
          },
        );
      },
    );
  }
}

/// Wrapper leve em torno da [HomeScreen] responsável por, se necessário
/// (cenário de cold start pós-disparo headless), exibir o diálogo de PIN
/// automaticamente logo após o primeiro frame — sem NUNCA substituir a
/// árvore de navegação por uma tela de bloqueio cheia. Isso corrige o
/// erro de design original: a HomeScreen (com Segurança, Família e
/// Histórico) fica sempre acessível, mesmo com o diálogo aberto por
/// cima dela.
class TelaInicialComPossivelDialogoPin extends StatefulWidget {
  const TelaInicialComPossivelDialogoPin({
    super.key,
    required this.aguardandoConfirmacaoPin,
  });

  final bool aguardandoConfirmacaoPin;

  @override
  State<TelaInicialComPossivelDialogoPin> createState() =>
      _TelaInicialComPossivelDialogoPinState();
}

class _TelaInicialComPossivelDialogoPinState
    extends State<TelaInicialComPossivelDialogoPin> {
  @override
  void initState() {
    super.initState();
    if (widget.aguardandoConfirmacaoPin) {
      // Agenda a exibição do diálogo para depois do primeiro frame,
      // garantindo que o BuildContext já esteja totalmente montado na
      // árvore (necessário para showDialog).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _exibirDialogoDePinPendente();
      });
    }
  }

  /// Busca o PIN real cadastrado e exibe o diálogo de confirmação por
  /// cima da HomeScreen. Protegido por try/catch para NUNCA travar a UI
  /// caso a consulta ao banco falhe por qualquer motivo.
  Future<void> _exibirDialogoDePinPendente() async {
    if (!mounted) return;
    try {
      final config = await DatabaseHelper().getUserConfig();
      final pinReal = config?['pin_real'] as String?;
      if (!mounted) return;
      await exibirDialogoPin(
        context: context,
        pinEsperado: pinReal,
        // segundosTolerancia null: cenário "pós cold start", sem
        // contagem regressiva (o disparo já ocorreu em background).
        segundosTolerancia: null,
        aoConfirmarPinCorreto: _aoConfirmarPinCorreto,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao exibir diálogo de PIN pendente: $e');
    }
  }

  /// Chamado quando o PIN correto é digitado neste cenário de cold
  /// start: apenas limpa a flag persistida no SQLite. Envolvido em
  /// try/catch para nunca travar o diálogo/UI em caso de falha.
  Future<void> _aoConfirmarPinCorreto() async {
    try {
      await DatabaseHelper().limparAguardandoConfirmacaoPin();
    } catch (e) {
      debugPrint('⚠️ Falha ao limpar flag de confirmação de PIN: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // A HomeScreen (com toda a navegação: Segurança, Família, Histórico)
    // é SEMPRE exibida, independentemente de haver ou não um diálogo de
    // PIN pendente sendo aberto por cima dela.
    return const HomeScreen();
  }
}