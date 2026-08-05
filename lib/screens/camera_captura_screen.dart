import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/device_admin_service.dart';
import '../services/emergency_alert_service.dart';
import '../services/plano_limite_service.dart';
import '../services/sos_disparo_service.dart';

enum _EstadoCaptura {
  inicializandoCamera,
  prontaParaFoto,
  processandoEnvio,
  dissuasaoExibida,
}

class CameraCapturaScreen extends StatefulWidget {
  const CameraCapturaScreen({super.key, this.origemUnificada});

  /// Quando informado, esta captura faz parte da sequência UNIFICADA de
  /// SOS (P1->P4, ver [SosDisparoService]) — a foto (P2) é enviada pelo
  /// pipeline híbrido novo (Firebase Storage + Push/WhatsApp) e o gesto
  /// de deslizar (P4) tenta o bloqueio nativo de tela via
  /// [DeviceAdminService] antes de cair no fallback histórico. Quando
  /// `null` (fluxo de timeout do cronômetro de check-in, fora do escopo
  /// desta unificação), mantém o comportamento histórico inalterado: SMS
  /// de texto + `SystemNavigator.pop()` no swipe.
  final String? origemUnificada;

  @override
  State<CameraCapturaScreen> createState() => _CameraCapturaScreenState();
}

class _CameraCapturaScreenState extends State<CameraCapturaScreen> {
  CameraController? _controller;
  _EstadoCaptura _estado = _EstadoCaptura.inicializandoCamera;
  bool _processandoFoto = false;
  final FocusNode _focusNode = FocusNode();

  // Pequena pausa cosmética só para a UI não "piscar" direto para a tela
  // de dissuasão quando o envio (upload/SMS/push) foi extremamente
  // rápido — NÃO é mais usada para simular tempo de envio: o envio real
  // já é aguardado antes desta pausa (ver [_processarEnvioEEnviarSmsResgate]).
  // Mantida curta de propósito: cada milissegundo aqui atrasa o
  // obturador percebido pelo usuário, que deve ficar o mais perto
  // possível dos ~3s do botão físico.
  static const Duration _duracaoSimulacaoEnvio = Duration(milliseconds: 250);

  static const MethodChannel _lockscreenChannel =
      MethodChannel('com.example.security_check_app/lockscreen');

  @override
  void initState() {
    super.initState();
    FocusManager.instance.primaryFocus?.unfocus();

    debugPrint(
        '🟩🟩🟩 [CameraCapturaScreen] >>> initState() ENTROU <<< timestamp=${DateTime.now().toIso8601String()}');

    _forcarShowWhenLocked();
    _inicializarCamera();
  }

  Future<void> _forcarShowWhenLocked() async {
    try {
      await _lockscreenChannel.invokeMethod('forcarShowWhenLocked');
    } catch (e) {
      debugPrint('⚠️ [CameraCapturaScreen] Falha ao reforçar showWhenLocked: $e');
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _descartarCameraSuavemente();
    super.dispose();
  }

  void _descartarCameraSuavemente() {
    final c = _controller;
    _controller = null;
    if (c != null && c.value.isInitialized) {
      c.dispose();
    }
  }

  Future<void> _inicializarCamera() async {
    try {
      final statusAtual = await Permission.camera.status;
      if (!statusAtual.isGranted) {
        final statusSolicitado = await Permission.camera.request();
        if (!statusSolicitado.isGranted) {
          debugPrint('⚠️ [CameraCapturaScreen] Permissão de câmera negada.');
          _avancarSemFoto();
          return;
        }
      }

      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        debugPrint('⚠️ [CameraCapturaScreen] Nenhuma câmera disponível.');
        _avancarSemFoto();
        return;
      }

      final cameraTraseira = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // 📸 RESOLUÇÃO MÁXIMA NATIVA + FORMATO JPEG
      final controller = CameraController(
        cameraTraseira,
        ResolutionPreset.max,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      // Ativa auto-foco contínuo do hardware
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _controller = controller;
          _estado = _EstadoCaptura.prontaParaFoto;
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _focusNode.requestFocus();
        });
      }
    } catch (e) {
      debugPrint('⚠️ [CameraCapturaScreen] Falha ao inicializar a câmera: $e');
      _avancarSemFoto();
    }
  }

  void _avancarSemFoto() {
    if (!mounted) return;
    setState(() => _estado = _EstadoCaptura.processandoEnvio);
    _processarEnvioEEnviarSmsResgate(null);
  }

  Future<void> _tirarFoto() async {
    if (_processandoFoto) return;
    _processandoFoto = true;

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _avancarSemFoto();
      return;
    }

    if (!mounted) return;

    try {
      setState(() => _estado = _EstadoCaptura.processandoEnvio);

      // Trava foco no instante do clique
      try {
        await controller.setFocusMode(FocusMode.locked);
      } catch (_) {}

      final XFile fotoCapturada = await controller.takePicture();
      debugPrint('📸 Foto em Alta Resolução capturada com sucesso: ${fotoCapturada.path}');

      _processarEnvioEEnviarSmsResgate(fotoCapturada);
    } catch (e) {
      debugPrint('⚠️ Erro ao capturar foto real: $e');
      _avancarSemFoto();
    }
  }

  Future<void> _processarEnvioEEnviarSmsResgate(XFile? foto) async {
    final String? origemUnificada = widget.origemUnificada;

    if (origemUnificada != null) {
      // P2 da sequência unificada de SOS: envia a foto de verdade pelo
      // pipeline híbrido (Firebase Storage + Push/WhatsApp), com
      // fallback automático para SMS de texto se não houver sessão
      // autenticada (ver SosDisparoService).
      if (foto != null) {
        await SosDisparoService().dispararFotoCapturada(foto, origem: origemUnificada);
      } else {
        try {
          await PlanoLimiteService().incrementarFotoUsada();
        } catch (e) {
          debugPrint('⚠️ [CameraCapturaScreen] Erro no contador de fotos: $e');
        }
      }
    } else {
      // Fluxo HISTÓRICO (timeout do cronômetro de check-in, fora do
      // escopo da unificação de SOS) — inalterado.
      try {
        await PlanoLimiteService().incrementarFotoUsada();
      } catch (e) {
        debugPrint('⚠️ [CameraCapturaScreen] Erro no contador de fotos: $e');
      }

      try {
        await EmergencyAlertService().enviarSmsResgateFoto(
          login: 'familia_resgate',
          senha:
              'SOS-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
        );
      } catch (e) {
        debugPrint('⚠️ Falha ao enviar SMS de resgate: $e');
      }
    }

    await Future.delayed(_duracaoSimulacaoEnvio);
    if (!mounted) return;

    _descartarCameraSuavemente();
    setState(() => _estado = _EstadoCaptura.dissuasaoExibida);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: RawKeyboardListener(
            focusNode: _focusNode,
            autofocus: true,
            onKey: (event) {
              if (event is RawKeyDownEvent) {
                if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown ||
                    event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
                  _tirarFoto();
                }
              }
            },
            child: _buildConteudoPorEstado(),
          ),
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

  Widget _buildPreviewCamera() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * controller.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Enquadramento de escala para Alta Definição em tela cheia
        ClipRect(
          child: Transform.scale(
            scale: scale,
            child: Center(
              child: CameraPreview(controller),
            ),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          top: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.65),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              AppLocalizations.of(context)!.cameraToqueOuVolume,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 32,
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _tirarFoto,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: Colors.white54, width: 4),
                ),
                child: const Icon(
                  Icons.camera_alt,
                  color: Colors.black87,
                  size: 36,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProcessandoEnvio() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: 24),
          Text(
            AppLocalizations.of(context)!.enviando,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }

  /// P4 da sequência unificada: tenta o bloqueio NATIVO de tela
  /// (`DevicePolicyManager.lockNow()`, ver [DeviceAdminService]) — só
  /// funciona se o usuário já concedeu a permissão de Administrador do
  /// Dispositivo com antecedência (ver tela de consentimento em
  /// Configurações/Segurança). Sem essa permissão (ou fora do fluxo
  /// unificado, [widget.origemUnificada] nulo), cai no comportamento
  /// histórico: apenas fecha/minimiza o app.
  Future<void> _acionarSaidaDeSeguranca() async {
    debugPrint('🛑 Gesto de segurança (Swipe Up) acionado.');

    if (widget.origemUnificada != null) {
      final bool bloqueou = await DeviceAdminService().bloquearTelaAgora();
      if (bloqueou) {
        debugPrint('🔒 [CameraCapturaScreen] Tela bloqueada nativamente (Device Admin).');
      } else {
        debugPrint('⚠️ [CameraCapturaScreen] Bloqueio nativo indisponível (Device Admin não ativo) — usando fallback.');
      }
    }

    SystemNavigator.pop();
  }

  Widget _buildTelaDissuasao() {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.velocity.pixelsPerSecond.dy < -200) {
          _acionarSaidaDeSeguranca();
        }
      },
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: const Color(0xFFB71C1C),
        padding: const EdgeInsets.symmetric(horizontal: 28.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.white, size: 96),
            const SizedBox(height: 24),
            Text(
              AppLocalizations.of(context)!.atencaoMaiuscula,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 38,
                fontWeight: FontWeight.w900,
                letterSpacing: 2.0,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              AppLocalizations.of(context)!.mensagemEnviadaAviso,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 48),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.keyboard_arrow_up,
                    color: Colors.white70, size: 28),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    AppLocalizations.of(context)!.deslizeParaFechar,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.85),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}