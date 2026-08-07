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
// ETAPA 2 (_iniciarFirebaseEAuth): disparada (sem `await`) logo após o
// runApp() — SÓ Firebase core + FirebaseAuth, o mínimo para os botões
// de login funcionarem. Nada de FCM/heartbeat/wallet aqui. Devolve dois
// futuros (core rápido vs. completo com logout) — ver a função.
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

  // Dispara (chama, SEM `await`) a inicialização de Firebase+Auth — isso
  // já executa o corpo síncrono da função até o primeiro `await`
  // interno, mas retorna a Future imediatamente sem bloquear main().
  //
  // MEDIDO no dispositivo físico (2026-08-06): `Firebase.initializeApp()`
  // sozinho pode levar 4s+ (I/O real do SDK nativo). Descoberta chave:
  // mesmo SEM nenhum `await` esperando por ele, esse trabalho nativo
  // compete pela MESMA UI thread usada pelos frames da splash animada —
  // rodar em paralelo com a animação a deixava visivelmente mais lenta
  // mesmo sem nenhum código Dart "esperando". Por isso, no cold start
  // NORMAL (nenhuma das duas flags abaixo), o disparo do Firebase é
  // ADIADO para depois da animação da splash terminar (ver
  // [_SplashGateState._aguardarProntidao]) — a splash roda inteira sem
  // nenhum trabalho pesado competindo, e o Firebase só liga junto com a
  // LoginScreen, aproveitando o tempo que o usuário leva pra digitar
  // e-mail/senha.
  //
  // Já os fluxos de SOS físico e rotina de alarme (abaixo) NÃO têm
  // nenhuma animação para proteger — disparam o Firebase imediatamente,
  // como antes.
  Future<void>? futuroFirebaseEAuthImediato;
  if (coldStartViaSosFisico || coldStartViaRotinaAlarme) {
    futuroFirebaseEAuthImediato =
        _iniciarFirebaseEAuth(coldStartViaSosFisico: coldStartViaSosFisico);
  }

  // ETAPA 1, fim: primeiro frame disparado imediatamente — ZERO
  // `await` entre ensureInitialized() e este runApp().
  runApp(SecurityCheckApp(
    abertoViaAlarmeRotina: coldStartViaRotinaAlarme,
    abertoViaSosFisico: coldStartViaSosFisico,
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
      // política de sessão em [_iniciarFirebaseEAuth]).
      futuroFirebaseEAuthImediato!.then((_) {
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
/// o runApp() em [main] — nunca antes.
///
/// NINGUÉM na UI aguarda este futuro completo para trocar a splash pela
/// LoginScreen (pedido explícito do usuário, 2026-08-06 — MEDIDO no
/// dispositivo físico: `Firebase.initializeApp()` sozinho pode levar 4s+,
/// I/O real do SDK nativo, e o `logout()` da política de sessão abaixo
/// pode somar mais alguns segundos quando já existe uma sessão real
/// logada; nenhum dos dois é algo que dá pra acelerar reorganizando
/// `await`s no Dart). [_SplashGate] só espera a animação terminar (ver
/// [_ConteudoSplashAnimadaState]) — Firebase termina de inicializar 100%
/// em segundo plano, aproveitando o tempo que o usuário leva pra digitar
/// e-mail/senha antes de tocar em "Entrar". Só o SOS físico em [main]
/// continua aguardando este futuro por completo, já que esse fluxo
/// precisa da sessão 100% resolvida antes de disparar.
///
/// Não bloquear a LoginScreen no Firebase/`logout()` é seguro: a tela
/// não lê nem exibe nenhum dado da sessão anterior (só um formulário
/// estático), e qualquer novo login (`signInWithEmailAndPassword` ou
/// social) sempre substitui a sessão antiga no SDK, independente deste
/// futuro já ter resolvido ou não — a garantia real da Opção A (nunca
/// abrir direto na Home com sessão persistida) não depende deste timing.
/// Se o usuário tocar em "Entrar" antes do Firebase estar pronto, o
/// `catch` genérico já existente em [LoginScreen] mostra a mensagem de
/// erro padrão, sem crash — caso raro, dado o tempo normal de digitação.
///
/// Protegida por try/catch e NUNCA lança exceção: se o Firebase falhar
/// ao inicializar (sem rede, projeto mal configurado, etc.), o app
/// continua funcional para login local/SMS, que não dependem dele.
Future<void> _iniciarFirebaseEAuth({required bool coldStartViaSosFisico}) async {
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    debugPrint('☁️ [Firebase] Inicializado com sucesso.');
  } catch (e) {
    debugPrint('⚠️ [Firebase] Falha ao inicializar (app segue 100% funcional '
        'apenas com os recursos locais): $e');
  }

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
  try {
    if (!coldStartViaSosFisico) {
      await FirebaseAuthService().logout();
    }
  } catch (e) {
    debugPrint('⚠️ [Firebase] Falha ao aplicar política de sessão: $e');
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

  const SecurityCheckApp({
    super.key,
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
    // Adiado (pedido explícito do usuário, 2026-08-06): este monitor só
    // importa para detectar um alarme de rotina disparando enquanto o
    // app JÁ está em uso (empurra a AlarmeDisparadoScreen por cima da
    // tela atual) — não é necessário durante o cold start/splash/login.
    // Rodar `SharedPreferences.reload()` (I/O de disco) a cada 1s desde
    // o primeiro frame competia com o boot do engine bem na janela mais
    // sensível. Atraso curto e fixo (em vez de acoplar à splash) porque
    // este widget não tem visibilidade de quando ela termina.
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) _monitorarMudancasNoDisco();
    });
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
  /// Firebase Auth. Isso é garantido em duas camadas: `main()` já dispara
  /// `FirebaseAuthService().logout()` (via [_iniciarFirebaseEAuth]) logo
  /// no cold start, e esta função nem chega a checar sessão — só entra
  /// em [TelaInicialComPossivelDialogoPin] através da navegação explícita
  /// feita por [LoginScreen] após um login real com `emailVerified ==
  /// true` (ver [LoginScreen._fazerLogin]).
  ///
  /// No cold start NORMAL, a LoginScreen não aparece direto: primeiro
  /// vem a [_SplashGate] (mesmo fundo escuro da splash nativa do
  /// Android, ver `launch_background.xml`) rodando a splash cinematográfica
  /// — troca para a LoginScreen de verdade assim que essa animação
  /// termina de verdade E o núcleo do Firebase (rápido, só
  /// `Firebase.initializeApp()`) estiver pronto, o que evita um usuário
  /// rápido conseguir tocar em "Entrar" antes do Firebase estar pronto,
  /// sem somar nenhum delay artificial por cima da animação.
  Widget _telaInicial() {
    if (widget.abertoViaAlarmeRotina) return const AlarmeDisparadoScreen();
    if (widget.abertoViaSosFisico) return const _TelaPretaAguardandoSos();
    return const _SplashGate();
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

/// Cor de fundo preta pura compartilhada pela splash nativa do Android
/// (ver `android/app/.../drawable/launch_background.xml` e
/// `values/colors.xml`, `@color/launch_background`) e pela
/// [_ConteudoSplashAnimada] — garante zero "flash" de cor entre o
/// toque no ícone e o primeiro frame do Flutter.
const Color _corSplashDeMarca = Colors.black;

/// Crossfade final da splash para a LoginScreen — dispara assim que a
/// animação da [_ConteudoSplashAnimada] termina de verdade (ver
/// [_SplashGateState._aguardarProntidao]), sem nenhum orçamento fixo
/// adicional somado por cima.
const Duration _duracaoCrossfadeParaLogin = Duration(milliseconds: 300);

/// Chave do SharedPreferences que guarda o ÍNDICE (0-5) da PRÓXIMA
/// frase de marca a exibir na splash — persiste entre aberturas do app
/// para que as 6 frases apareçam em loop sequencial (1→2→…→6→1…), uma
/// por abertura, em vez de repetir/sortear (ver [_SplashGateState]).
const String _prefsChaveIndiceFraseSplash = 'splash_frase_indice_proxima';

/// As 6 frases de marca (uma por abertura, em loop) exibidas na splash
/// cinematográfica — ver `lib/l10n/app_*.arb` (`splashFrase1..6`).
/// Cada frase é dividida em linhas por "\n"; a linha cujo conteúdo
/// (normalizado) é exatamente "GUARDIÃO X" fica FIXA na tela durante a
/// animação de saída, as demais deslizam para cima e desaparecem — ver
/// [_ConteudoSplashAnimada._ehLinhaDaMarca].
List<String> _frasesSplash(AppLocalizations l10n) => <String>[
      l10n.splashFrase1,
      l10n.splashFrase2,
      l10n.splashFrase3,
      l10n.splashFrase4,
      l10n.splashFrase5,
      l10n.splashFrase6,
    ];

/// Gate puramente visual exibido como a rota inicial do app (dentro do
/// `home:` do MaterialApp — nunca via Navigator, então não interfere em
/// nenhuma navegação por nome já existente) no cold start NORMAL.
/// Mostra a splash cinematográfica de marca ([_ConteudoSplashAnimada])
/// sobre o MESMO fundo preto da splash nativa, e troca para a
/// [LoginScreen] assim que a animação termina de verdade (ver
/// [_aguardarProntidao]), sem nenhum delay extra acumulado por cima.
///
/// NÃO espera o Firebase ([main]/[_iniciarFirebaseEAuth]) de propósito
/// (pedido explícito do usuário, 2026-08-06 — MEDIDO no dispositivo
/// físico: `Firebase.initializeApp()` sozinho pode levar 4s+, e esperar
/// por ele quase dobrava o tempo da splash). A LoginScreen é só um
/// formulário estático (não lê nada da sessão), e o Firebase termina de
/// inicializar em segundo plano — ver comentário completo em
/// [_iniciarFirebaseEAuth] sobre por que isso é seguro.
class _SplashGate extends StatefulWidget {
  const _SplashGate();

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  bool _pronto = false;

  /// Sinalizado por [_ConteudoSplashAnimada] (via `onConcluida`) assim
  /// que a sequência real de animação (digitação + pausa + saída — ver
  /// [_ConteudoSplashAnimadaState]) termina. É o ÚNICO gatilho de
  /// [_aguardarProntidao] — substitui o antigo orçamento fixo de tempo,
  /// que somava um delay artificial por cima da animação de verdade.
  final Completer<void> _animacaoConcluidaCompleter = Completer<void>();

  /// Índice (0-5) da frase a exibir nesta abertura — só fica não-nulo
  /// depois da leitura (rápida, mas assíncrona) do SharedPreferences,
  /// para nunca trocar a frase NO MEIO da animação de digitação (ver
  /// [_carregarIndiceFrase]).
  int? _indiceFrase;

  @override
  void initState() {
    super.initState();
    _carregarIndiceFrase();
    _aguardarProntidao();
  }

  Future<void> _carregarIndiceFrase() async {
    int indiceSorteado = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      indiceSorteado = (prefs.getInt(_prefsChaveIndiceFraseSplash) ?? 0) % 6;
      // Fire-and-forget: já grava o índice da PRÓXIMA abertura — não
      // precisa ser aguardado, e não deve atrasar a splash atual.
      unawaited(
        prefs.setInt(_prefsChaveIndiceFraseSplash, (indiceSorteado + 1) % 6),
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao ler índice da frase de splash: $e');
    }
    if (mounted) setState(() => _indiceFrase = indiceSorteado);
  }

  void _aoAnimacaoConcluir() {
    if (!_animacaoConcluidaCompleter.isCompleted) {
      _animacaoConcluidaCompleter.complete();
    }
  }

  Future<void> _aguardarProntidao() async {
    // Transição dispara assim que a animação de verdade terminar — ver
    // [_animacaoConcluidaCompleter] — sem nenhum orçamento fixo de tempo
    // adicional por cima: nenhuma alteração na digitação/pausa/saída.
    await _animacaoConcluidaCompleter.future;

    // SÓ AGORA (animação já terminou, splash saindo de tela) dispara o
    // Firebase — ver comentário completo em [main]: rodá-lo ANTES/EM
    // PARALELO com a animação a deixava visivelmente mais lenta, mesmo
    // sem nenhum `await` Dart esperando por ele (compete pela mesma UI
    // thread nativa dos frames). Fire-and-forget: a LoginScreen (que vai
    // aparecer no próximo frame) não precisa dele pronto para renderizar,
    // só quando o usuário efetivamente tocar em "Entrar" — ver
    // [_iniciarFirebaseEAuth] para a explicação completa de por que isso
    // é seguro.
    unawaited(_iniciarFirebaseEAuth(coldStartViaSosFisico: false));

    if (mounted) setState(() => _pronto = true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _duracaoCrossfadeParaLogin,
      child: _pronto
          ? const LoginScreen()
          : (_indiceFrase == null
              // Placeholder preto (idêntico ao fundo da splash nativa
              // E da splash animada) só pelos poucos milissegundos da
              // leitura assíncrona do índice da frase — invisível na
              // prática, sem nenhum "flash" de cor.
              ? const ColoredBox(
                  key: ValueKey('splash_preta_aguardando_indice'),
                  color: _corSplashDeMarca,
                )
              : _ConteudoSplashAnimada(
                  key: ValueKey('splash_de_marca_$_indiceFrase'),
                  indiceFrase: _indiceFrase!,
                  onConcluida: _aoAnimacaoConcluir,
                )),
    );
  }
}

/// Splash cinematográfica de marca: a frase do índice sorteado (ver
/// [_frasesSplash]) é digitada letra por letra, linha por linha
/// ("efeito máquina de escrever"); ao terminar, uma breve pausa e então
/// a animação de saída — a linha "GUARDIÃO X" fica FIXA na tela e as
/// demais deslizam para cima enquanto desaparecem (fade out). Fundo
/// preto puro, texto em negrito verde neon com efeito de brilho/glow.
class _ConteudoSplashAnimada extends StatefulWidget {
  const _ConteudoSplashAnimada({
    super.key,
    required this.indiceFrase,
    this.onConcluida,
  });

  final int indiceFrase;

  /// Chamado UMA VEZ, assim que a sequência (digitação + pausa + saída)
  /// termina de verdade — ver [_ConteudoSplashAnimadaState._iniciarSequenciaDeAnimacao].
  /// Não altera em nada o ritmo/duração da animação em si, só notifica
  /// quem está esperando (ver [_SplashGateState]).
  final VoidCallback? onConcluida;

  @override
  State<_ConteudoSplashAnimada> createState() =>
      _ConteudoSplashAnimadaState();
}

class _ConteudoSplashAnimadaState extends State<_ConteudoSplashAnimada>
    with TickerProviderStateMixin {
  static const Color _verdeNeon = Color(0xFF39FF14);

  // Timings da animação em si — INTOCADOS a pedido explícito do usuário
  // (2026-08-06): a velocidade de digitação e o restante do efeito devem
  // continuar exatamente como estão. A splash agora transiciona para a
  // LoginScreen assim que esta sequência termina de verdade (ver
  // [_SplashGateState._aguardarProntidao]), sem nenhum orçamento fixo
  // adicional somado por cima — soma ≈ 3.2s (2.1s digitando + 0.3s de
  // pausa com "GUARDIÃO X" sozinha na tela + 0.8s de saída).
  static const Duration _duracaoDigitacao = Duration(milliseconds: 2100);
  static const Duration _duracaoPausaPosDigitacao =
      Duration(milliseconds: 300);
  static const Duration _duracaoSaida = Duration(milliseconds: 800);

  late final AnimationController _digitacaoController;
  late final AnimationController _saidaController;
  late final Animation<double> _curvaSaida;

  List<String> _linhas = const <String>[];
  int _totalCaracteres = 0;

  @override
  void initState() {
    super.initState();
    _digitacaoController = AnimationController(
      vsync: this,
      duration: _duracaoDigitacao,
    );
    _saidaController = AnimationController(
      vsync: this,
      duration: _duracaoSaida,
    );
    _curvaSaida = CurvedAnimation(
      parent: _saidaController,
      curve: Curves.easeInCubic,
    );
    _iniciarSequenciaDeAnimacao();
  }

  Future<void> _iniciarSequenciaDeAnimacao() async {
    await _digitacaoController.forward();
    if (!mounted) return;
    await Future<void>.delayed(_duracaoPausaPosDigitacao);
    if (!mounted) return;
    await _saidaController.forward();
    // Sequência de verdade terminou — libera a troca para a LoginScreen
    // (ver [_SplashGateState]) imediatamente, sem esperas extras.
    widget.onConcluida?.call();
  }

  @override
  void dispose() {
    _digitacaoController.dispose();
    _saidaController.dispose();
    super.dispose();
  }

  /// A marca "GUARDIÃO X" fica fixa na tela durante a saída — as demais
  /// linhas da frase é que sobem/desaparecem (ver classe doc).
  bool _ehLinhaDaMarca(String linha) {
    final String normalizada = linha.trim().toUpperCase();
    return normalizada == 'GUARDIÃO X' || normalizada == 'GUARDIÃO-X';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final frases = _frasesSplash(l10n);
    final frase = frases[widget.indiceFrase % frases.length];
    _linhas = frase.split('\n');
    _totalCaracteres =
        _linhas.fold<int>(0, (soma, linha) => soma + linha.length);

    return Scaffold(
      backgroundColor: _corSplashDeMarca,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: SizedBox(
              width: double.infinity,
              child: AnimatedBuilder(
                animation: Listenable.merge(
                  <Listenable>[_digitacaoController, _saidaController],
                ),
                builder: (context, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _construirLinhas(context),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _construirLinhas(BuildContext context) {
    final double valorDigitacao = _digitacaoController.value;
    final int caracteresVisiveis =
        (_totalCaracteres * valorDigitacao).round();

    // Tamanho-base responsivo: proporcional à largura da tela, com
    // limites para não "apertar" em telas pequenas nem sobrar espaço
    // excessivo em telas grandes/tablets — o FittedBox abaixo ainda
    // encolhe por linha se, mesmo assim, algum texto não couber.
    final double larguraTela = MediaQuery.of(context).size.width;
    final double fonteMarca = (larguraTela * 0.135).clamp(30.0, 52.0);
    final double fonteDemais = fonteMarca * 0.6;

    int acumulado = 0;
    final widgets = <Widget>[];
    for (final linha in _linhas) {
      final int inicioLinha = acumulado;
      acumulado += linha.length;
      final int visivelNaLinha =
          (caracteresVisiveis - inicioLinha).clamp(0, linha.length);
      final String textoParcial = linha.substring(0, visivelNaLinha);
      final bool aindaDigitandoEstaLinha =
          visivelNaLinha > 0 && visivelNaLinha < linha.length;

      final bool fixa = _ehLinhaDaMarca(linha);
      final double progressoSaida = fixa ? 0.0 : _curvaSaida.value;
      final double fonteLinha = fixa ? fonteMarca : fonteDemais;
      final String textoExibido =
          textoParcial + (aindaDigitandoEstaLinha ? '▏' : '');

      // FittedBox com um filho de largura intrínseca ZERO (Text('')) faz o
      // Flutter estourar 'width > 0.0': is not true dentro de
      // BoxFit.scaleDown (assert só ativo em modo debug — por isso passou
      // despercebido testando só builds release) — acontece exatamente no
      // instante em que uma linha ainda não começou a "digitar" (nenhum
      // caractere nem cursor visível ainda). Nesse caso, reserva a MESMA
      // altura da linha com um SizedBox simples (sem FittedBox) em vez de
      // tentar ajustar-a-caber um texto vazio — evita tanto o crash quanto
      // um "pulo" de layout no instante em que a 1ª letra aparece.
      final Widget conteudoLinha = textoExibido.isEmpty
          ? SizedBox(height: fonteLinha * 1.15)
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: _TextoNeon(
                texto: textoExibido,
                fontSize: fonteLinha,
                cor: _verdeNeon,
              ),
            );

      widgets.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: fixa ? 10 : 6),
          child: Opacity(
            opacity: (1.0 - progressoSaida).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, -36 * progressoSaida),
              child: conteudoLinha,
            ),
          ),
        ),
      );
    }
    return widgets;
  }
}

/// Texto em negrito, verde sólido e nítido (sem sombra/glow) — usado nas
/// linhas da [_ConteudoSplashAnimada].
class _TextoNeon extends StatelessWidget {
  const _TextoNeon({
    required this.texto,
    required this.fontSize,
    required this.cor,
  });

  final String texto;
  final double fontSize;
  final Color cor;

  @override
  Widget build(BuildContext context) {
    return Text(
      texto,
      textAlign: TextAlign.center,
      maxLines: 1,
      softWrap: false,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.4,
        height: 1.15,
        color: cor,
      ),
    );
  }
}