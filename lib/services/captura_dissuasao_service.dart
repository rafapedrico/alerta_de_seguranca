import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_navigator.dart';
import '../screens/camera_captura_screen.dart';
import 'plano_limite_service.dart';

/// Orquestra a abertura do recurso de Captura e Dissuasão
/// ([CameraCapturaScreen]) a partir de qualquer ponto de disparo de
/// emergência da UI.
class CapturaDissuasaoService {
  CapturaDissuasaoService._internal();
  static final CapturaDissuasaoService _instance =
      CapturaDissuasaoService._internal();
  factory CapturaDissuasaoService() => _instance;

  Future<void> abrirCapturaSePermitido() async {
    try {
      // 1. Verifica se o plano permite tirar fotos
      final bool permitido = await PlanoLimiteService().podeTirarFoto();
      debugPrint('📷 [CapturaDissuasaoService] podeTirarFoto() retornou: $permitido');
      if (!permitido) {
        debugPrint(
            '📷 [CapturaDissuasaoService] Limite mensal de fotos do Plano Gratuito atingido — captura não será aberta.');
        return;
      }

      // 2. Apenas verifica o status da permissão de CÂMERA, sem solicitar.
      // A solicitação real (Permission.camera.request()) acontece uma
      // única vez, dentro de CameraCapturaScreen._inicializarCamera().
      // Chamar request() também aqui causava uma corrida entre as duas
      // telas — o permission_handler não permite duas solicitações
      // simultâneas e uma delas falhava com PlatformException
      // ("A request for permissions is already running"), deixando a
      // permissão presa em "denied".
      try {
        final status = await Permission.camera.status;
        debugPrint('📷 [CapturaDissuasaoService] Status atual da permissão de câmera: $status');
      } catch (e) {
        debugPrint('⚠️ [CapturaDissuasaoService] Falha ao verificar permissão de câmera: $e');
      }

      // 3. RETRY LOOP: Aguarda até 3s usando appNavigatorKey
      NavigatorState? navigatorState = appNavigatorKey.currentState;
      int tentativas = 0;
      while (navigatorState == null && tentativas < 10) {
        debugPrint(
            '⏳ [CapturaDissuasaoService] NavigatorState ainda nulo. Aguardando montagem da UI (tentativa ${tentativas + 1}/10)...');
        await Future.delayed(const Duration(milliseconds: 300));
        navigatorState = appNavigatorKey.currentState;
        tentativas++;
      }

      if (navigatorState == null) {
        debugPrint(
            '⚠️ [CapturaDissuasaoService] NavigatorState indisponível após aguardar — captura não pôde ser aberta.');
        return;
      }

      // 4. Navega para a CameraCapturaScreen
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