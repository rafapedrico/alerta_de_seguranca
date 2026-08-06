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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final bool coldStartViaSosFisico =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
          _rotaInicialSosFisico;

  final bool coldStartViaRotinaAlarme =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
          _rotaInicialRotinaAlarme;

  EncryptionService().initialize();

  // Camada extra de resiliência na nuvem (Firebase/Firestore): protegida
  // por try/catch e NUNCA bloqueia o cold start do app — se o Firebase
  // falhar ao inicializar (sem rede, projeto mal configurado, etc.), o
  // app continua 100% funcional com SQLite local, alarmes nativos e SMS
  // direto do aparelho, que não dependem do Firebase.
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
    // (`coldStartViaSosFisico`, ver `LockscreenCameraActivity`) NUNCA
    // exibe nenhuma tela de login/conta — a UI vai direto para
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

    // Registra o handler de background do FCM e pede a permissão de
    // notificação — CORREÇÃO: isso não depende de sessão autenticada
    // (diferente da sincronização do token, que precisa de `uid` e roda
    // em `FcmService().inicializar()` após cada login, ver
    // `login_screen.dart`), então deve armar aqui, incondicionalmente a
    // cada cold start, e não ficar refém do usuário completar o login
    // primeiro. Fire-and-forget: nunca atrasa o cold start.
    FcmService().registrarInfraestrutura();

    // Camada A MAIS de resiliência na nuvem (monitoramento agendado, ver
    // `BackgroundLocationHeartbeatService`): inicia o ciclo de heartbeat
    // de localização (a cada 5 min, só quando faltar ≤2h para algum
    // alarme de rotina ativo). Síncrono e não-bloqueante — nunca atrasa
    // o cold start nem interfere no alarme local. Sem sessão ativa logo
    // após o logout forçado acima, o serviço aguarda o próximo login
    // real para voltar a sincronizar com a nuvem.
    BackgroundLocationHeartbeatService().iniciar();

    // Escuta o stream de compras (in_app_purchase) desde o cold start —
    // necessário para não perder a confirmação de uma recarga que
    // terminou de processar enquanto o app estava fechado/em segundo
    // plano (ver WalletService).
    WalletService();
  } catch (e) {
    debugPrint('⚠️ [Firebase] Falha ao inicializar (app segue 100% funcional '
        'apenas com os recursos locais): $e');
  }

  await WallpaperService.inicializar();
  await FontScaleService.inicializar();
  await LocaleService.inicializar();
  await DatabaseHelper().resetarSessaoAuditoria();
  await AlarmeService.inicializar();
  await NotificacaoService.inicializar();
  await VolumeSosService().iniciarMonitoramento();
  await PlanoLimiteService().inicializar();

  // Resiliência offline do P2 do SOS (ver RetryUploadService): reagenda
  // o alarme periódico de retry (precisa do AndroidAlarmManager já
  // inicializado por AlarmeService.inicializar() acima) e tenta drenar a
  // fila imediatamente — cobre o caso comum de o app ser reaberto depois
  // que a conectividade voltou. Fire-and-forget: nunca atrasa o cold
  // start.
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

  final bool aguardandoConfirmacaoPin =
      await DatabaseHelper().isAguardandoConfirmacaoPin();

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final bool alarmeDisparandoNoDisco =
      prefs.getBool('alarme_disparando_no_momento') ?? false;

  final bool abertoViaAlarmeRotinaFinal =
      coldStartViaRotinaAlarme || alarmeDisparandoNoDisco;

  debugPrint(
      '✈️ [main] Alarme tocando verificado via Disco: $alarmeDisparandoNoDisco');

  runApp(SecurityCheckApp(
    aguardandoConfirmacaoPin: aguardandoConfirmacaoPin,
    abertoViaAlarmeRotina: abertoViaAlarmeRotinaFinal,
    abertoViaSosFisico: coldStartViaSosFisico,
  ));

  if (coldStartViaSosFisico) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint(
          '🚨 [main] SOS Físico via Lockscreen: disparando sequência unificada P1->P2.');
      _dispararSequenciaUnificadaDeSos(origem: 'sos_fisico');
    });
  }

  if (coldStartViaRotinaAlarme) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint(
          '🚨 [main] PRIORIDADE MÁXIMA: Forçando abertura da AlarmeDisparadoScreen.');
      navigateToAlarmeDisparado();
    });
  }
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
  final bool aguardandoConfirmacaoPin;
  final bool abertoViaAlarmeRotina;
  final bool abertoViaSosFisico;

  const SecurityCheckApp({
    super.key,
    required this.aguardandoConfirmacaoPin,
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
  Widget _telaInicial() {
    if (widget.abertoViaAlarmeRotina) return const AlarmeDisparadoScreen();
    if (widget.abertoViaSosFisico) return const _TelaPretaAguardandoSos();
    return const LoginScreen();
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