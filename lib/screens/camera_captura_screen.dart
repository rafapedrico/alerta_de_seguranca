import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/plano_limite_service.dart';



/// Estados internos do fluxo de Captura e Dissuasão, exibidos em
/// sequência dentro de uma ÚNICA tela ([CameraCapturaScreen]):
///
/// 1. [inicializandoCamera] — abrindo a câmera traseira.
/// 2. [prontaParaFoto] — preview em tela cheia, aguardando o toque no
///    obturador.
/// 3. [processandoEnvio] — simula o "upload" da foto e o disparo do
///    segundo SMS com link/senha (nenhuma foto é de fato persistida ou
///    enviada — é 100% teatro/dissuasão).
/// 4. [dissuasaoExibida] — tela final, fundo escuro com o aviso em
///    vermelho, sem qualquer botão de saída manual.
enum _EstadoCaptura {
  inicializandoCamera,
  prontaParaFoto,
  processandoEnvio,
  dissuasaoExibida,
}

/// Tela full-screen do recurso de Captura e Dissuasão: abre a câmera
/// traseira do aparelho instantaneamente, permite que a vítima (ou o
/// agressor, sem saber) tire uma foto, e em seguida transiciona
/// automaticamente para uma tela de aviso ameaçador, reforçando ao
/// agressor que a situação já foi denunciada — mesmo que, nesta fase,
/// nenhuma foto seja de fato enviada a lugar nenhum.
///
/// Nunca deve ser aberta diretamente por serviços de negócio "puros"
/// (ex: EmergencyAlertService) — apenas por pontos de UI que já possuam
/// (ou tenham acesso via [appNavigatorKey]) um [BuildContext]/Navigator
/// válido, sempre APÓS um disparo de emergência bem-sucedido. Ver
/// `CapturaDissuasaoService.abrirCapturaSePermitido()`.
class CameraCapturaScreen extends StatefulWidget {
  const CameraCapturaScreen({super.key});

  @override
  State<CameraCapturaScreen> createState() => _CameraCapturaScreenState();
}

class _CameraCapturaScreenState extends State<CameraCapturaScreen> {
  CameraController? _controller;
  _EstadoCaptura _estado = _EstadoCaptura.inicializandoCamera;

  /// Duração da simulação de "upload da foto + envio do segundo SMS",
  /// exibida com um spinner simples antes da transição para a tela de
  /// dissuasão.
  static const Duration _duracaoSimulacaoEnvio = Duration(milliseconds: 1800);

  /// MethodChannel correspondente ao `LockscreenPlugin` nativo (ver
  /// `LockscreenPlugin.kt`), usado para reforçar, em tempo de execução,
  /// as flags `setShowWhenLocked`/`setTurnScreenOn`/`requestDismissKeyguard`
  /// diretamente na Activity que está de fato visível no momento em que
  /// esta tela é desenhada — e não apenas na instância original criada em
  /// `MainActivity.onCreate()`.
  static const MethodChannel _lockscreenChannel =
      MethodChannel('com.example.security_check_app/lockscreen');

  @override
  void initState() {
    super.initState();
    // Garante que nenhum campo de texto/teclado de outra tela permaneça
    // com foco ao entrar neste fluxo em tela cheia — evita que o teclado
    // virtual suba e sobreponha o preview da câmera logo na abertura.
    FocusManager.instance.primaryFocus?.unfocus();
    // ==========================================================
    // LOGS EXTRAS DE RASTREAMENTO (diagnóstico temporário):
    // impressos ANTES de qualquer outra linha do initState(), com
    // timestamp explícito, para eliminar qualquer dúvida sobre a
    // ordem real de execução observada no terminal/logcat. Devem
    // ser as PRIMEIRÍSSIMAS linhas emitidas por esta tela.
    // ==========================================================
    debugPrint(
        '🟩🟩🟩 [CameraCapturaScreen] >>> initState() ENTROU <<< timestamp=${DateTime.now().toIso8601String()}');

    debugPrint(
        '🟩🟩🟩 [CameraCapturaScreen] >>> initState() ordem de execução: PASSO 0 (antes de super.initState() já concluído) <<<');
    // LOG DE RASTREAMENTO (diagnóstico): confirma, sem qualquer dúvida,
    // que o initState() desta tela foi de fato executado e em que ordem
    // as chamadas seguintes ocorrem. Deve SEMPRE ser a primeira linha
    // impressa por esta tela, antes de qualquer tentativa de reforçar o
    // showWhenLocked ou inicializar a câmera.
    debugPrint(
        '🟦 [CameraCapturaScreen] initState() iniciado — prestes a chamar _forcarShowWhenLocked().');
    _forcarShowWhenLocked();

    debugPrint(
        '🟦 [CameraCapturaScreen] _forcarShowWhenLocked() disparado (async, não aguardado) — prestes a chamar _inicializarCamera().');
    _inicializarCamera();
  }

  /// Chama o plugin nativo local para reaplicar as flags de sobreposição
  /// ao Keyguard na Activity atualmente visível. Essencial no cenário de
  /// SOS disparado pelo botão físico com o aparelho bloqueado: em
  /// Android recente, o sistema pode redesenhar o lockscreen por cima da
  /// Activity entre o `onCreate()` original e o momento em que esta tela
  /// é de fato navegada/desenhada (engine já "quente", em cache). Falhas
  /// aqui (plugin indisponível, plataforma não suportada, etc.) NUNCA
  /// devem travar o fluxo — são apenas logadas.
  Future<void> _forcarShowWhenLocked() async {
    debugPrint(
        '🔧 [CameraCapturaScreen] _forcarShowWhenLocked() chamado — invocando MethodChannel "${_lockscreenChannel.name}" com o método "forcarShowWhenLocked"...');
    try {
      await _lockscreenChannel.invokeMethod('forcarShowWhenLocked');
      debugPrint(
          '🔓 [CameraCapturaScreen] Flags de showWhenLocked/turnScreenOn reaplicadas com sucesso.');
    } on MissingPluginException catch (e) {
      // Erro específico e muito comum quando o binário instalado no
      // aparelho ainda é uma build ANTIGA (anterior à criação/registro do
      // LockscreenPlugin no MainActivity.configureFlutterEngine): o
      // MethodChannel simplesmente não existe do lado nativo. Logado de
      // forma explícita e diferenciada para facilitar o diagnóstico em
      // campo — se este log aparecer, o app PRECISA ser reinstalado do
      // zero (uninstall + flutter run), não basta um hot restart.
      debugPrint(
          '❌ [CameraCapturaScreen] MissingPluginException ao chamar "forcarShowWhenLocked": $e — '
          'isso indica que o binário instalado no aparelho é uma build ANTIGA, sem o LockscreenPlugin registrado. '
          'É necessário desinstalar o app e rodar "flutter run" novamente (rebuild completo).');
    } on PlatformException catch (e) {
      debugPrint(
          '⚠️ [CameraCapturaScreen] PlatformException ao chamar "forcarShowWhenLocked": ${e.code} / ${e.message}');
    } catch (e) {
      debugPrint(
          '⚠️ [CameraCapturaScreen] Falha inesperada ao reforçar showWhenLocked via MethodChannel: $e');
    }
  }



  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }


  /// Inicializa a câmera TRASEIRA do aparelho. Protegido em múltiplas
  /// camadas: se não houver câmera disponível, permissão negada, ou
  /// qualquer outra falha (comum em emuladores), o fluxo NUNCA trava —
  /// avança diretamente para a etapa de "processando envio" como se a
  /// foto já tivesse sido tirada, preservando o efeito de dissuasão mesmo
  /// sem uma câmera funcional.
  ///
  /// IMPORTANTE: antes de tocar no plugin de câmera, verificamos o
  /// status da permissão explicitamente. Se ela já estiver concedida
  /// (`granted`) — cenário comum em produção, já que o usuário
  /// provavelmente já usou este recurso antes — pulamos DIRETO para a
  /// inicialização, sem qualquer chance de o Android tentar exibir um
  /// diálogo de permissão do sistema. Isso é crítico no cenário de SOS
  /// disparado pelo botão físico com a tela ainda bloqueada: um diálogo
  /// de permissão nessas condições pode travar/falhar silenciosamente
  /// por cima do Keyguard. Apenas se a permissão NUNCA tiver sido
  /// concedida é que solicitamos uma única vez; se for negada, o fluxo
  /// segue para [_avancarSemFoto] normalmente, sem travar.
  Future<void> _inicializarCamera() async {
    try {
      final statusAtual = await Permission.camera.status;
      if (!statusAtual.isGranted) {
        final statusSolicitado = await Permission.camera.request();
        if (!statusSolicitado.isGranted) {
          debugPrint(
              '⚠️ [CameraCapturaScreen] Permissão de câmera negada pelo usuário.');
          _avancarSemFoto();
          return;
        }
      }

      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        debugPrint('⚠️ [CameraCapturaScreen] Nenhuma câmera disponível no aparelho.');
        _avancarSemFoto();
        return;
      }

      final cameraTraseira = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        cameraTraseira,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _estado = _EstadoCaptura.prontaParaFoto;
      });
    } catch (e) {
      debugPrint('⚠️ [CameraCapturaScreen] Falha ao inicializar a câmera: $e');
      _avancarSemFoto();
    }
  }

  /// Usado quando a câmera não pôde ser inicializada por qualquer
  /// motivo: pula diretamente para a simulação de envio, sem nunca
  /// deixar a vítima presa numa tela de erro.
  void _avancarSemFoto() {
    if (!mounted) return;
    setState(() => _estado = _EstadoCaptura.processandoEnvio);
    _processarEnvioSimulado();
  }

  /// Chamado ao tocar no botão de obturador: NÃO tira uma foto real —
  /// este recurso é 100% TEATRO/SIMULADO para fins de dissuasão visual.
  ///
  /// IMPORTANTE (correção de bug de concorrência): anteriormente esta
  /// função chamava `controller.takePicture()` de fato. Como o
  /// `CameraController` já está com o preview ativo em tempo real,
  /// chamadas consecutivas/rápidas ao obturador (ou qualquer resquício
  /// de captura anterior ainda em andamento) disparavam a exceção nativa
  /// `CameraException(Previous capture has not returned yet)` — que por
  /// sua vez derrubava esta tela (efetivamente um `Navigator.pop`
  /// indevido) e expunha o PIN/lockscreen do Android por trás dela,
  /// quebrando todo o efeito de dissuasão. Como a foto nunca foi de fato
  /// persistida ou enviada a lugar nenhum (sempre foi só teatro), a
  /// captura real de hardware foi REMOVIDA por completo: o preview
  /// continua rodando ao vivo (a vítima se vê na tela) até o instante em
  /// que trocamos para a tela de "processando envio" e, em seguida, para
  /// a tela vermelha fixa de dissuasão.
  Future<void> _tirarFoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _avancarSemFoto();
      return;
    }

    if (!mounted) return;
    setState(() => _estado = _EstadoCaptura.processandoEnvio);

    // Libera a câmera assim que avançamos de estado — não é mais
    // necessária a partir daqui. Nenhuma captura de hardware real
    // (takePicture) é realizada neste fluxo.
    await controller.dispose();
    _controller = null;

    _processarEnvioSimulado();
  }


  /// Simula visualmente o "upload da foto + disparo do segundo SMS com
  /// link/senha" por um breve período, incrementa o contador mensal de
  /// fotos do Plano Gratuito, e então transiciona para a tela final de
  /// dissuasão.
  Future<void> _processarEnvioSimulado() async {
    try {
      await PlanoLimiteService().incrementarFotoUsada();
    } catch (e) {
      debugPrint('⚠️ [CameraCapturaScreen] Falha ao incrementar contador de fotos: $e');
    }

    await Future.delayed(_duracaoSimulacaoEnvio);
    if (!mounted) return;

    // A tela de dissuasão agora é PERMANENTE: não há mais retorno
    // automático. Apenas a própria vítima, através do botão discreto
    // "X" no canto superior direito (ver [_buildTelaDissuasao]), decide
    // quando fechar esta tela.
    setState(() => _estado = _EstadoCaptura.dissuasaoExibida);
  }


  @override
  Widget build(BuildContext context) {
    // Bloqueia o botão físico/gesto de voltar em TODOS os estados deste
    // fluxo — uma vez iniciado, a sequência de captura/dissuasão precisa
    // seguir até o fim, sem permitir que o usuário (ou o agressor)
    // simplesmente volte e "cancele" o processo.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _buildConteudoPorEstado(),
        ),
      ),
    );
  }

  Widget _buildConteudoPorEstado() {
    switch (_estado) {
      case _EstadoCaptura.inicializandoCamera:
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      case _EstadoCaptura.prontaParaFoto:
        return _buildPreviewCamera();
      case _EstadoCaptura.processandoEnvio:
        return _buildProcessandoEnvio();
      case _EstadoCaptura.dissuasaoExibida:
        return _buildTelaDissuasao();
    }
  }

  /// Preview da câmera traseira em tela cheia, com um botão de obturador
  /// circular simples centralizado na parte inferior.
  Widget _buildPreviewCamera() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(controller),
        Positioned(
          left: 0,
          right: 0,
          bottom: 32,
          child: Center(
            child: GestureDetector(
              onTap: _tirarFoto,
              child: Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: Colors.white54, width: 4),
                ),
                child: const Icon(Icons.camera_alt, color: Colors.black87, size: 32),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Tela intermediária simples exibida durante a simulação de
  /// "upload da foto + envio do segundo SMS".
  Widget _buildProcessandoEnvio() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 24),
          Text(
            'Enviando...',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }

  /// Tela final de dissuasão: fundo escuro com o aviso em letras
  /// garrafais vermelhas, PERMANENTE (sem auto-retorno). Um botão
  /// discreto "X" no canto superior direito é o ÚNICO meio de fechar
  /// esta tela, garantindo que apenas a própria vítima decida o momento
  /// de sair — nunca um timeout automático.
  Widget _buildTelaDissuasao() {
    return Stack(
      children: [
        Container(
          width: double.infinity,
          height: double.infinity,
          color: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 84),
                const SizedBox(height: 24),
                const Text(
                  'ATENÇÃO',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.red,
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'UMA MENSAGEM FOI ENVIADA AOS FAMILIARES COM A FOTO E LOCALIZAÇÃO.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.red,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'ESTA OPERAÇÃO NÃO PODE SER DESFEITA.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.red,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Botão discreto de fechar: único ponto de saída manual desta
        // tela, controlado exclusivamente pela vítima.
        Positioned(
          top: 12,
          right: 12,
          child: SafeArea(
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: Colors.white70, size: 28),
              tooltip: 'Fechar',
            ),
          ),
        ),
      ],
    );
  }
}


