import 'package:flutter/material.dart';
import 'services/encryption_service.dart';
import 'services/wallpaper_service.dart';
import 'services/font_scale_service.dart';
import 'services/database_helper.dart';
import 'services/alarme_service.dart';
import 'services/notificacao_service.dart';
import 'screens/home_screen.dart';
import 'widgets/pin_dialog.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
          home: _TelaInicialComPossivelDialogoPin(
            aguardandoConfirmacaoPin: aguardandoConfirmacaoPin,
          ),
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
class _TelaInicialComPossivelDialogoPin extends StatefulWidget {
  const _TelaInicialComPossivelDialogoPin({
    required this.aguardandoConfirmacaoPin,
  });

  final bool aguardandoConfirmacaoPin;

  @override
  State<_TelaInicialComPossivelDialogoPin> createState() =>
      _TelaInicialComPossivelDialogoPinState();
}

class _TelaInicialComPossivelDialogoPinState
    extends State<_TelaInicialComPossivelDialogoPin> {
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
