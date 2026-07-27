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
import 'screens/camera_captura_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/alarme_service.dart';
import 'services/api_service.dart';
import 'services/background_location_heartbeat_service.dart';
import 'services/captura_dissuasao_service.dart';
import 'services/contatos_emergencia_service.dart';
import 'services/database_helper.dart';
import 'services/emergency_alert_service.dart';
import 'services/encryption_service.dart';
import 'services/firebase_sync_service.dart';
import 'services/font_scale_service.dart';
import 'services/locale_service.dart';
import 'services/notificacao_service.dart';
import 'services/plano_limite_service.dart';
import 'services/rotina_alarme_service.dart';
import 'services/volume_sos_service.dart';
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
    // Sincroniza os contatos de emergência já cadastrados (mesmo que
    // tenham sido criados antes desta funcionalidade existir) para que a
    // nuvem já saiba a quem notificar, sem depender de o usuário editar
    // algo primeiro. Fire-and-forget: nunca atrasa o cold start.
    ContatosEmergenciaService.sincronizarAgora();

    // Camada A MAIS de resiliência na nuvem (monitoramento agendado, ver
    // `BackgroundLocationHeartbeatService`): inicia o ciclo de heartbeat
    // de localização (a cada 5 min, só quando faltar ≤2h para algum
    // alarme de rotina ativo). Síncrono e não-bloqueante — nunca atrasa
    // o cold start nem interfere no alarme local.
    BackgroundLocationHeartbeatService().iniciar();
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

  VolumeSosService().aoDispararSos.listen((_) {
    _dispararFluxoCompletoDeSos(
      origem: 'EventChannel (app em primeiro/segundo plano)',
    );
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
          '🚨 [main] SOS Físico via Lockscreen: iniciando envio de SOS e abrindo câmera.');
      EmergencyAlertService().dispararSosComDuplaLocalizacao();
      navigateToCameraCaptura();
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

/// Redireciona a navegação para a CameraCapturaScreen no cold start do SOS Físico
void navigateToCameraCaptura() {
  try {
    final state = appNavigatorKey.currentState;
    if (state != null) {
      state.push(
        MaterialPageRoute(
          builder: (context) => const CameraCapturaScreen(),
          fullscreenDialog: true,
        ),
      );
    }
  } catch (e) {
    debugPrint('⚠️ Falha ao navegar para CameraCapturaScreen: $e');
  }
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
  EmergencyAlertService().dispararSosComDuplaLocalizacao().then((_) {
    CapturaDissuasaoService().abrirCapturaSePermitido();
  }).catchError((e) {
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