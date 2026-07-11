import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_navigator.dart';
import '../screens/camera_captura_screen.dart';
import 'plano_limite_service.dart';


/// Orquestra a abertura do recurso de Captura e Dissuasão
/// ([CameraCapturaScreen]) a partir de qualquer ponto de disparo de
/// emergência da UI (SegurancaTab, listener de SOS físico em main.dart),
/// verificando antes o limite mensal de fotos do Plano Gratuito (ver
/// [PlanoLimiteService]).
///
/// Usa o [appNavigatorKey] global em vez de exigir um [BuildContext]
/// local, permitindo ser chamado inclusive a partir de código que não
/// pertence a nenhuma árvore de widgets (ex: o listener de eventos do
/// [VolumeSosService] registrado diretamente em `main.dart`).
///
/// IMPORTANTE: este serviço é chamado explicitamente por cada ponto de
/// disparo — o [EmergencyAlertService] em si permanece 100% desacoplado
/// de UI e NUNCA invoca este serviço diretamente, preservando sua
/// reutilização segura tanto no fluxo com o app aberto quanto no
/// callback headless (onde não há Activity/UI disponível para exibir a
/// câmera).
class CapturaDissuasaoService {
  CapturaDissuasaoService._internal();
  static final CapturaDissuasaoService _instance =
      CapturaDissuasaoService._internal();
  factory CapturaDissuasaoService() => _instance;

  /// Verifica se o Plano Gratuito ainda permite tirar mais uma foto neste
  /// mês e, se sim, solicita a permissão de CÂMERA (caso ainda não tenha
  /// sido concedida) e navega em tela cheia para [CameraCapturaScreen]
  /// via [appNavigatorKey]. Caso o limite já tenha sido atingido, ou não
  /// haja um [NavigatorState] disponível no momento da chamada, não faz
  /// nada (apenas registra via [debugPrint] — nunca lança exceção nem
  /// bloqueia o fluxo de emergência que já foi disparado antes desta
  /// chamada).
  ///
  /// IMPORTANTE (correção de bug em teste físico): mesmo que a permissão
  /// de câmera seja definitivamente negada pelo usuário, a tela AINDA
  /// assim é aberta — a própria [CameraCapturaScreen] já está preparada
  /// para lidar com a ausência de uma câmera funcional (ver
  /// `_inicializarCamera`/`_avancarSemFoto`), avançando automaticamente
  /// para a simulação de envio e a tela de dissuasão. Isso garante que o
  /// recurso de dissuasão NUNCA deixe de aparecer só porque a permissão
  /// de câmera não foi concedida.
  Future<void> abrirCapturaSePermitido() async {
    try {
      final bool permitido = await PlanoLimiteService().podeTirarFoto();
      debugPrint('📷 [CapturaDissuasaoService] podeTirarFoto() retornou: $permitido');
      if (!permitido) {
        debugPrint(
            '📷 [CapturaDissuasaoService] Limite mensal de fotos do Plano Gratuito atingido — captura não será aberta.');
        return;
      }

      // Solicita explicitamente a permissão de CÂMERA antes de navegar,
      // eliminando a hipótese de o CameraController.initialize() falhar
      // silenciosamente por falta de permissão em tempo de execução.
      // O resultado NÃO bloqueia a abertura da tela — apenas garante que
      // a permissão já tenha sido pedida ao sistema operacional.
      try {
        final status = await Permission.camera.status;
        debugPrint('📷 [CapturaDissuasaoService] Status atual da permissão de câmera: $status');
        if (!status.isGranted) {
          final novoStatus = await Permission.camera.request();
          debugPrint('📷 [CapturaDissuasaoService] Permissão de câmera solicitada, resultado: $novoStatus');
        }
      } catch (e) {
        debugPrint('⚠️ [CapturaDissuasaoService] Falha ao solicitar permissão de câmera: $e');
      }

      final navigatorState = appNavigatorKey.currentState;
      if (navigatorState == null) {
        debugPrint(
            '⚠️ [CapturaDissuasaoService] NavigatorState indisponível no momento da chamada — captura não pôde ser aberta.');
        return;
      }

      debugPrint('📷 [CapturaDissuasaoService] Navegando para CameraCapturaScreen...');
      navigatorState.push(
        MaterialPageRoute(
          builder: (_) => const CameraCapturaScreen(),
          fullscreenDialog: true,
        ),
      );
    } catch (e) {
      debugPrint('⚠️ [CapturaDissuasaoService] Falha ao tentar abrir a tela de captura: $e');
    }
  }
}


