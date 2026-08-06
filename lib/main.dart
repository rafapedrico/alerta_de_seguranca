import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_navigator.dart';
import 'firebase_options.dart';
import 'screens/alarme_disparado_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/alarme_service.dart';
import 'services/api_service.dart';
import 'services/background_location_heartbeat_service.dart';
import 'services/captura_dissuasao_service.dart';
import 'services/database_helper.dart';
import 'services/emergency_alert_service.dart';
import 'services/encryption_service.dart';
import 'services/fcm_service.dart';
import 'services/firebase_auth_service.dart';
import 'services/firebase_sync_service.dart';
import 'services/font_scale_service.dart';
import 'services/locale_service.dart';
import 'services/notificacao_service.dart';
import 'services/plano_limite_service.dart';
import 'services/retry_upload_service.dart';
import 'services/rotina_alarme_service.dart';
import 'services/sos_disparo_service.dart';
import 'services/volume_sos_service.dart';
import 'services/wallet_service.dart';
import 'services/wallpaper_service.dart';
import 'widgets/pin_dialog.dart';

const String _rotaInicialSosFisico = '/sos_fisico_lockscreen';
const String _rotaInicialRotinaAlarme = '/rotina_alarme_confirmacao';

// ================================================================
// ARQUITETURA DE COLD START — LAZY LOADING ESTRITO EM 3 ETAPAS
// (reescrita completa a pedido explícito do usuário: a versão anterior,
// mesmo já adiando os serviços nativos pesados para depois do runApp(),
// ainda tinha WallpaperService/FontScaleService/LocaleService + 2
// leituras de disco `await`adas ANTES do runApp() — medido ~7s de cold
// start em debug. Meta: ZERO `await` antes do runApp()).
//
// ETAPA 1 (main, abaixo): só ensureInitialized() + 2 checagens 100%
// SÍNCRONAS de rota (sem I/O, não são `await` — decidem qual widget é
// o primeiro frame) + runApp() imediato.
//
// ETAPA 2 (_inicializarFirebaseEAuth): disparada (sem `await`) logo
// após o runApp() — SÓ Firebase core + FirebaseAuth, o mínimo para os
// botões de login funcionarem. Nada de FCM/heartbeat/wallet aqui.
//
// ETAPA 3 (iniciarServicosPosLoginOuDashboard, chamada por
// HomeScreen.initState — ver home_screen.dart): TODOS os serviços
// nativos pesados (Alarme, Notificação, VolumeSos, RetryUpload,
// PlanoLimite, WalletService, BackgroundLocationHeartbeat, FCM,
// AlarmManager) só sobem depois que o usuário efetivamente loga e
// chega no dashboard — nunca antes, nem em paralelo com o cold start.
//
// TRADE-OFF DE SEGURANÇA DELIBERADO (pedido explícito do usuário,
// ETAPA 3): como a Opção A força logout a cada cold start normal, o
// Foreground Service nativo do botão físico (VolumeSosService) e o
// AlarmeService de rotina só reativam DEPOIS do próximo login — ou
// seja, entre um cold start normal e o usuário efetivamente logar de
// novo, o botão físico de SOS e os alarmes de rotina ficam inativos.
// Isso é uma mudança de comportamento real (antes, esses serviços
// religavam em paralelo com QUALQUER cold start, sem depender de
// login) — ver relato ao usuário.
// ================================================================

/// Guarda para [iniciarServicosPosLoginOuDashboard] disparar UMA ÚNICA
/// vez por sessão do engine, mesmo que HomeScreen seja desmontada/
/// remontada (troca de aba, deep-link, etc.).
bool _servicosPosLoginJaIniciados = false;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // ETAPA 1 — checagens 100% SÍNCRONAS (leitura de memória já resolvida
  // pelo binding, sem I/O nenhum): NÃO são `await`, custam
  // microssegundos, e são essenciais para decidir o primeiro frame.
  // Removê-las faria a LoginScreen (com campos de texto) desenhar por
  // cima da lockscreen no SOS físico — bug de segurança já corrigido
  // antes — ou atrasaria a AlarmeDisparadoScreen.
  final bool coldStartViaSosFisico =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
          _rotaInicialSosFisico;

  final bool coldStartViaRotinaAlarme =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
          _rotaInicialRotinaAlarme;

  // Síncrono, idempotente, sem I/O — ver encryption_service.dart (só
  // deriva a chave em memória; os demais serviços chamam de novo
  // sozinhos caso ainda não tenha rodado).
  EncryptionService().initialize();

  // Dispara (chama, SEM `await`) a inicialização de Firebase+Auth —
  // isso já executa o corpo síncrono da função até o primeiro `await`
  // interno, mas retorna a Future imediatamente sem bloquear main().
  // Capturada aqui para repassar para a SplashGate/callback abaixo, que
  // usam essa Future para saber quando é seguro liberar o login (SOS
  // físico) ou trocar a splash pela LoginScreen de verdade (cold start
  // normal) — sem isso, um usuário/disparo rápido poderia agir antes do
  // Firebase estar pronto.
  final Future<void> futuroFirebaseEAuth =
      _inicializarFirebaseEAuth(coldStartViaSosFisico: coldStartViaSosFisico);

  // ETAPA 1, fim: primeiro frame disparado imediatamente — ZERO
  // `await` entre ensureInitialized() e este runApp().
  runApp(SecurityCheckApp(
    abertoViaAlarmeRotina: coldStartViaRotinaAlarme,
    abertoViaSosFisico: coldStartViaSosFisico,
    futuroFirebaseEAuth: futuroFirebaseEAuth,
  ));

  // A partir daqui, tudo roda EM PARALELO com o primeiro frame já na
  // tela — nada abaixo bloqueia ou atrasa o runApp() acima.

  if (coldStartViaSosFisico) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint(
          '🚨 [main] SOS Físico via Lockscreen: aguardando Firebase+Auth antes de disparar P1->P2.');
      // Só aguarda AQUI (depois do primeiro frame, tela preta já
      // visível) — nunca antes do runApp(). O disparo em si precisa do
      // Firebase pronto para usar Push/WhatsApp/link real da foto (ver
      // política de sessão em [_inicializarFirebaseEAuth]).
      futuroFirebaseEAuth.then((_) {
        _dispararSequenciaUnificadaDeSos(origem: 'sos_fisico');
      });
    });
  }

  if (coldStartViaRotinaAlarme) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint(
          '🚨 [main] PRIORIDADE MÁXIMA: Forçando abertura da AlarmeDisparadoScreen.');
      navigateToAlarmeDisparado();
    });
  }

  // Wallpaper/fonte/idioma persistidos: puramente visuais (o
  // MaterialApp já nasce com os valores padrão dos ValueNotifiers e
  // reconstrói reativamente assim que estes carregarem) — nunca
  // precisam bloquear o primeiro frame. Fire-and-forget.
  unawaited(_inicializarPreferenciasVisuais());
}

/// Wallpaper, escala de fonte e idioma persistidos — só afetam
/// aparência (ver comentário em [main]), nunca bloqueiam o cold start.
Future<void> _inicializarPreferenciasVisuais() async {
  await WallpaperService.inicializar();
  await FontScaleService.inicializar();
  await LocaleService.inicializar();
}

/// ETAPA 2: o MÍNIMO de Firebase necessário para os botões de login
/// funcionarem — só `Firebase.initializeApp()` + a política de sessão
/// (Opção A). Nada de FCM/heartbeat/wallet aqui (ver ETAPA 3,
/// [iniciarServicosPosLoginOuDashboard]). Chamada sem `await` logo após
/// o runApp() em [main] — nunca antes. Protegida por try/catch e NUNCA
/// lança exceção: se o Firebase falhar ao inicializar (sem rede,
/// projeto mal configurado, etc.), o app continua funcional para login
/// local/SMS, que não dependem dele.
Future<void> _inicializarFirebaseEAuth({required bool coldStartViaSosFisico}) async {
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    debugPrint('☁️ [Firebase] Inicializado com sucesso.');

    // POLÍTICA DE SEGURANÇA (Opção A): todo cold start NORMAL (usuário
    // abrindo o app pelo ícone) encerra qualquer sessão do Firebase Auth
    // persistida no disco — o app NUNCA deve abrir direto na Home usando
    // uma sessão antiga, mesmo que o dispositivo/emulador já tivesse um
    // login válido de uma execução anterior. Login (com a barreira de
    // `emailVerified`) volta a ser exigido a cada abertura normal.
    //
    // EXCEÇÃO DELIBERADA (bug real corrigido): cold start via SOS FÍSICO
    // NUNCA exibe nenhuma tela de login/conta — a UI vai direto para
    // `_TelaPretaAguardandoSos` (tela preta, zero dado de usuário) e
    // depois para a câmera. Fazer logout() TAMBÉM nesse fluxo zerava
    // `FirebaseAuthService().uidAtual` ANTES do `SosDisparoService`
    // sequer rodar, forçando SEMPRE o SMS de fallback sem link real da
    // foto e desativando Push/WhatsApp — justamente no cenário mais
    // crítico (app fechado, botão físico). Como nenhuma UI de conta é
    // exibida nesse fluxo, preservar a sessão aqui mantém a MESMA
    // garantia de segurança da Opção A (nunca mostrar dados de conta sem
    // reautenticação) e permite que o SOS físico dispare com todos os
    // canais (SMS com link real + Push + WhatsApp), mesmo 100% a frio.
    if (!coldStartViaSosFisico) {
      await FirebaseAuthService().logout();
    }
  } catch (e) {
    debugPrint('⚠️ [Firebase] Falha ao inicializar (app segue 100% funcional '
        'apenas com os recursos locais): $e');
  }
}

/// ETAPA 3 (pedido explícito do usuário): TODOS os serviços nativos
/// pesados — Alarme de rotina, canais de notificação, Foreground
/// Service do botão físico, fila de retry offline, FCM, heartbeat de
/// localização, carteira de créditos e limites do plano — só sobem
/// DEPOIS que o usuário chega no dashboard (chamada em
/// `HomeScreen.initState()`, ver home_screen.dart), nunca antes/em
/// paralelo com o cold start. Guardada por [_servicosPosLoginJaIniciados]
/// para nunca rodar duas vezes na mesma sessão do engine.
///
/// TRADE-OFF DE SEGURANÇA: ver nota completa no cabeçalho deste
/// arquivo — entre um cold start normal (que sempre força logout, ver
/// Opção A) e o usuário logar de novo, o botão físico de SOS e os
/// alarmes de rotina ficam inativos, já que dependem deste bloco.
Future<void> iniciarServicosPosLoginOuDashboard() async {
  if (_servicosPosLoginJaIniciados) return;
  _servicosPosLoginJaIniciados = true;

  debugPrint('🚀 [main] Login/Dashboard alcançado — iniciando serviços nativos em segundo plano.');

  // Registra o handler de background do FCM e pede a permissão de
  // notificação — token sync (que precisa de `uid`) continua separado,
  // em `FcmService().inicializar()`, chamado direto por login_screen.dart.
  FcmService().registrarInfraestrutura();

  // Heartbeat de localização (a cada 5 min, só quando faltar ≤2h para
  // algum alarme de rotina ativo) e listener de compras (in_app_purchase)
  // para não perder confirmação de recarga.
  BackgroundLocationHeartbeatService().iniciar();
  WalletService();

  await DatabaseHelper().resetarSessaoAuditoria();
  await AlarmeService.inicializar();
  await NotificacaoService.inicializar();
  await VolumeSosService().iniciarMonitoramento();
  await PlanoLimiteService().inicializar();

  // Resiliência offline do P2 do SOS (ver RetryUploadService): reagenda
  // o alarme periódico de retry (precisa do AndroidAlarmManager já
  // inicializado por AlarmeService.inicializar() acima) e tenta drenar a
  // fila imediatamente — cobre o caso comum de o app ser reaberto depois
  // que a conectividade voltou.
  RetryUploadService().iniciar();

  VolumeSosService().aoDispararSos.listen((_) {
    _dispararFluxoCompletoDeSos(origem: 'sos_fisico');
  });

  const EventChannel('com.example.security_check_app/rotina_alarme_events')
      .receiveBroadcastStream()
      .listen((_) {
    _exibirPinDeRotinaAoAbrirPorAlarme();
  }, onError: (e) {
    debugPrint('⚠️ [main] Erro no EventChannel de alarme de rotina: $e');
  });

  _testarConectividadeInicialComBackend();
}

/// Dispara P1 (localização imediata, deduplicada entre engines — ver
/// [SosDisparoService]) e P2 (abre a câmera) EM PARALELO — P1 continua
/// enviando o SMS/nuvem de localização assim que possível, mas NUNCA
/// bloqueia a abertura da câmera, que é a etapa perceptível pelo
/// usuário (câmera física ~3s: obturador livre quase instantaneamente).
/// Antes, P2 só começava depois de P1 concluir (SMS + geolocalização),
/// somando vários segundos de espera com a tela preta antes do
/// obturador aparecer. Compartilhado pelos DOIS pontos de entrada do
/// botão físico (cold-start via lockscreen acima e o EventChannel de
/// [_dispararFluxoCompletoDeSos] abaixo).
Future<void> _dispararSequenciaUnificadaDeSos({required String origem}) async {
  // Fire-and-forget: P1 (SMS + nuvem) roda em paralelo, nunca atrasa P2.
  unawaited(SosDisparoService().executarP1LocalizacaoImediata(origem: origem));
  // CapturaDissuasaoService encapsula a checagem de limite mensal de
  // fotos do Plano Gratuito e o retry-loop de NavigatorState — reusado
  // aqui (em vez de `navigateToCameraCaptura` direto) para preservar
  // essa regra também no botão físico, igual já acontecia no SOS manual.
  await CapturaDissuasaoService().abrirCapturaSePermitido(origemUnificada: origem);
}

/// Redireciona a navegação para a AlarmeDisparadoScreen
void navigateToAlarmeDisparado() {
  try {
    final state = appNavigatorKey.currentState;
    if (state != null) {
      state.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/alarme_disparado'),
          builder: (context) => const AlarmeDisparadoScreen(),
        ),
      );
    }
  } catch (e) {
    debugPrint('⚠️ Falha ao navegar para AlarmeDisparadoScreen: $e');
  }
}

Future<void> _exibirPinDeRotinaAoAbrirPorAlarme() async {
  try {
    debugPrint(
        '📱 [main] Redirecionando cold-start de rotina para AlarmeDisparadoScreen.');
    navigateToAlarmeDisparado();
  } catch (e) {
    debugPrint('⚠️ Falha ao redirecionar tela no cold-start de rotina: $e');
  }
}

void _dispararFluxoCompletoDeSos({required String origem}) {
  debugPrint('🆘 [main] Disparando fluxo completo de SOS — origem: $origem');
  _dispararSequenciaUnificadaDeSos(origem: origem).catchError((e) {
    debugPrint('⚠️ [main] Falha ao processar SOS ($origem): $e');
  });
}

Future<void> _testarConectividadeInicialComBackend() async {
  try {
    const double bateriaSimulada = 100;
    await ApiService().enviarStatus(bateriaSimulada, '1.0.0');
  } catch (e) {
    debugPrint('⚠️ Falha ao testar conectividade inicial com o backend: $e');
  }
}

class SecurityCheckApp extends StatefulWidget {
  final bool abertoViaAlarmeRotina;
  final bool abertoViaSosFisico;

  /// Future da inicialização de Firebase+Auth em voo (ver [main],
  /// ETAPA 2) — repassada para a [_SplashGate] (cold start normal) e
  /// aguardada antes do disparo do SOS físico, para saber quando é
  /// seguro liberar o login/o disparo de verdade.
  final Future<void> futuroFirebaseEAuth;

  const SecurityCheckApp({
    super.key,
    required this.futuroFirebaseEAuth,
    this.abertoViaAlarmeRotina = false,
    this.abertoViaSosFisico = false,
  });

  @override
  State<SecurityCheckApp> createState() => _SecurityCheckAppState();
}

class _SecurityCheckAppState extends State<SecurityCheckApp> {
  late ValueNotifier<bool> _alarmeAtivoNotifier;

  @override
  void initState() {
    super.initState();
    _alarmeAtivoNotifier = ValueNotifier<bool>(widget.abertoViaAlarmeRotina);
    _monitorarMudancasNoDisco();
  }

  bool _travaProcessandoAbertura = false;

  void _monitorarMudancasNoDisco() {
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final bool ativoNoDisco =
          prefs.getBool('alarme_disparando_no_momento') ?? false;

      if (!ativoNoDisco) {
        _travaProcessandoAbertura = false;
      }

      if (ativoNoDisco) {
        final state = appNavigatorKey.currentState;
        if (state != null) {
          bool jaEstaNaTela = false;

          state.popUntil((route) {
            final String? nomeRota = route.settings.name;
            if (nomeRota == '/alarme_disparado' ||
                route.toString().contains('AlarmeDisparadoScreen')) {
              jaEstaNaTela = true;
            }
            return true;
          });

          if (!jaEstaNaTela && !_travaProcessandoAbertura) {
            _travaProcessandoAbertura = true;

            state.push(
              MaterialPageRoute(
                settings: const RouteSettings(name: '/alarme_disparado'),
                builder: (context) =>
                    const AlarmeDisparadoScreen(veioDoForeground: true),
              ),
            );
            debugPrint(
                '🚀 [SUCESSO] Tela do botão azul forçada com segurança total anti-duplicação!');
          }
        }
      }

      if (_alarmeAtivoNotifier.value !=
          (widget.abertoViaAlarmeRotina || ativoNoDisco)) {
        _alarmeAtivoNotifier.value =
            widget.abertoViaAlarmeRotina || ativoNoDisco;
      }
    });
  }

  Future<void> _cancelarAlarmeGlobal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      _alarmeAtivoNotifier.value = false;

      final alarmes = await DatabaseHelper().listarAlarmes();
      if (alarmes.isNotEmpty) {
        final idAlarme = alarmes.first['id'] as int?;
        if (idAlarme != null) {
          await RotinaAlarmeService.pausarAlarme(idAlarme);
          debugPrint(
              '⏹️ [GlobalButton] Alarme #$idAlarme silenciado com sucesso.');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao cancelar alarme pelo botão global: $e');
    }
  }

  @override
  void dispose() {
    _alarmeAtivoNotifier.dispose();
    super.dispose();
  }

  /// Escolhe a tela raiz do MaterialApp. No cold start via SOS Físico
  /// (botão de volume com o aparelho bloqueado) NUNCA construímos a
  /// LoginScreen: ela tem campos de texto e, mesmo sem autofocus, não deve
  /// chegar a existir sobre a lockscreen. Uma tela preta neutra ocupa esse
  /// instante até a CameraCapturaScreen ser empurrada por cima.
  ///
  /// POLÍTICA DE SEGURANÇA (Opção A): fora desses casos especiais de
  /// emergência, SEMPRE mostra a LoginScreen — o app nunca pula direto
  /// para dentro do fluxo principal com base numa sessão persistida do
  /// Firebase Auth. Isso é garantido em duas camadas: `main()` já força
  /// `FirebaseAuthService().logout()` a cada cold start antes de chamar
  /// `runApp`, e esta função nem chega a checar sessão — só entra em
  /// [TelaInicialComPossivelDialogoPin] através da navegação explícita
  /// feita por [LoginScreen] após um login real com `emailVerified ==
  /// true` (ver [LoginScreen._fazerLogin]).
  ///
  /// No cold start NORMAL, a LoginScreen não aparece direto: primeiro
  /// vem a [_SplashGate] (mesmo fundo escuro da splash nativa do
  /// Android, ver `launch_background.xml`, com o logo do app e um
  /// spinner discreto) — cobre visualmente o tempo da inicialização de
  /// Firebase/Auth adiada para depois do primeiro frame (ver [main]) e
  /// só troca para a LoginScreen de verdade quando ela terminar,
  /// evitando um usuário rápido conseguir tocar em "Entrar" antes do
  /// Firebase estar pronto.
  Widget _telaInicial() {
    if (widget.abertoViaAlarmeRotina) return const AlarmeDisparadoScreen();
    if (widget.abertoViaSosFisico) return const _TelaPretaAguardandoSos();
    return _SplashGate(aguardar: widget.futuroFirebaseEAuth);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: LocaleService.localeNotifier,
      builder: (context, locale, __) {
        return ValueListenableBuilder<double>(
          valueListenable: FontScaleService.fontScaleNotifier,
          builder: (context, fatorFonte, _) {
            return MaterialApp(
              navigatorKey: appNavigatorKey,
              title: 'Security Check App',
              debugShowCheckedModeBanner: false,
              locale: locale,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) {
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(fatorFonte),
                  ),
                  child: child!,
                );
              },
              home: _telaInicial(),
              onGenerateRoute: (settings) {
                return MaterialPageRoute(
                  builder: (_) => _telaInicial(),
                  settings: settings,
                );
              },
            );
          },
        );
      },
    );
  }
}

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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _exibirDialogoDePinPendente();
      });
    }
  }

  Future<void> _exibirDialogoDePinPendente() async {
    if (!mounted) return;
    try {
      final config = await DatabaseHelper().getUserConfig();
      final pinReal = config?['pin_real'] as String?;
      if (!mounted) return;
      await exibirDialogoPin(
        context: context,
        pinEsperado: pinReal,
        segundosTolerancia: null,
        aoConfirmarPinCorreto: _aoConfirmarPinCorreto,
        aoAtingirLimiteDeErros: _aoErrarPinDuasVezes,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao exibir diálogo de PIN pendente: $e');
    }
  }

  Future<void> _aoConfirmarPinCorreto() async {
    try {
      await DatabaseHelper().limparAguardandoConfirmacaoPin();
    } catch (e) {
      debugPrint('⚠️ Falha ao limpar flag de confirmação de PIN: $e');
    }
  }

  Future<void> _aoErrarPinDuasVezes() async {
    // ORDEM CRÍTICA: alerta para a nuvem primeiro e aguardado, antes de
    // qualquer outro processamento — ver mesma lógica em
    // SegurancaTab._dispararSosDeCoacao.
    try {
      await FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto();
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar alerta prioritário na nuvem: $e');
    }
    try {
      await EmergencyAlertService().dispararAlertaTentativaDesarmeIncorreto();
    } catch (e) {
      debugPrint(
          '⚠️ Falha ao disparar alerta de tentativa de desarme incorreta: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const HomeScreen();
  }
}

/// Placeholder neutro (sem nenhum campo de texto/foco) exibido só durante o
/// instante do cold start via SOS Físico, antes da CameraCapturaScreen ser
/// empurrada por cima em [navigateToCameraCaptura].
class _TelaPretaAguardandoSos extends StatelessWidget {
  const _TelaPretaAguardandoSos();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: Colors.black);
  }
}

/// Cor de fundo AMOLED escura compartilhada pela splash nativa do
/// Android (ver `android/app/.../drawable/launch_background.xml` e
/// `values/colors.xml`, `@color/launch_background`), pela [_SplashGate]
/// e pelo restante do app (mesmo tom usado no ícone do launcher e em
/// `home_screen.dart`) — garante zero "flash" de cor entre o toque no
/// ícone e o primeiro frame do Flutter.
const Color _corSplashDeMarca = Color(0xFF12131C);

/// Gate puramente visual exibido como a rota inicial do app (dentro do
/// `home:` do MaterialApp — nunca via Navigator, então não interfere em
/// nenhuma navegação por nome já existente) no cold start NORMAL.
/// Mostra a identidade visual do app (logo + spinner discreto) sobre o
/// MESMO fundo escuro da splash nativa, cobrindo visualmente o tempo da
/// inicialização de Firebase/Auth que [main] adia para depois do
/// primeiro frame — e só troca para a [LoginScreen] de verdade quando
/// ela realmente termina, para que nunca seja possível tocar em
/// "Entrar" antes do Firebase estar pronto.
class _SplashGate extends StatefulWidget {
  const _SplashGate({required this.aguardar});

  /// Future de [_inicializarFirebaseEAuth] já em voo (ver [main]).
  final Future<void> aguardar;

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  bool _pronto = false;

  @override
  void initState() {
    super.initState();
    _aguardarProntidao();
  }

  Future<void> _aguardarProntidao() async {
    // Duração mínima só para a marca não "piscar" instantaneamente em
    // reaberturas muito rápidas (engine já aquecido) — a splash some
    // com o que demorar mais entre essa duração mínima e o término real
    // da inicialização de Firebase/Auth.
    await Future.wait<void>([
      Future<void>.delayed(const Duration(milliseconds: 700)),
      widget.aguardar,
    ]);
    if (mounted) setState(() => _pronto = true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: _pronto ? const LoginScreen() : const _ConteudoSplashDeMarca(),
    );
  }
}

/// Conteúdo visual da splash de marca: logo do app (mesma arte do ícone
/// do launcher) e um spinner discreto — nada de texto/campo interativo,
/// só identidade visual + indicação de carregamento em andamento.
class _ConteudoSplashDeMarca extends StatelessWidget {
  const _ConteudoSplashDeMarca();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('splash_de_marca'),
      backgroundColor: _corSplashDeMarca,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ClipOval: o arquivo-fonte do ícone (assets/images/app_icon.png)
            // tem transparência "gravada" como um xadrez cinza nos 4 cantos
            // em vez de alfa real (defeito pré-existente do asset) — o
            // recorte circular remove exatamente essa área quadriculada,
            // sobrando só o emblema redondo do logo.
            ClipOval(
              child: Image.asset(
                'assets/images/app_icon.png',
                width: 112,
                height: 112,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 40),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4C7040)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}