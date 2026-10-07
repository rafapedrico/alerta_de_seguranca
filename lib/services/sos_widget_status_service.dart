import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/sos_widget_tutorial_screen.dart';

/// Status do Widget SOS ("Botão de Pânico" na tela de início, ver
/// `SosWidgetProvider.kt`), pelo canal nativo "guardiaox/sos_widget"
/// (MainActivity) — o mesmo canal do app iOS.
///
/// O status é REAL (`AppWidgetManager.getAppWidgetIds`). Diferente do iOS,
/// o Android deixa o app pedir ao launcher para adicionar o widget
/// ([fixarWidget], `requestPinAppWidget`); sem suporte do launcher, fica o
/// passo a passo ([SosWidgetTutorialScreen]).
class SosWidgetStatusService {
  SosWidgetStatusService._();

  static const MethodChannel _canal = MethodChannel('guardiaox/sos_widget');
  static const String _chaveTutorialExibido = 'sos_widget_tutorial_exibido';

  /// `true`/`false` = widget na tela de início ou não; `null` = o canal
  /// não respondeu.
  static Future<bool?> widgetInstalado() async {
    try {
      return await _canal.invokeMethod<bool>('widgetInstalado');
    } catch (e) {
      debugPrint('⚠️ [SosWidgetStatusService] Falha ao consultar os widgets: $e');
      return null;
    }
  }

  /// Pede ao launcher para adicionar o widget (ele mostra a própria
  /// confirmação). `false` = launcher sem suporte — use o passo a passo.
  static Future<bool> fixarWidget() async {
    try {
      return await _canal.invokeMethod<bool>('fixarWidget') ?? false;
    } catch (e) {
      debugPrint('⚠️ [SosWidgetStatusService] Falha ao pedir o widget ao launcher: $e');
      return false;
    }
  }

  static Future<void> abrirTutorial(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SosWidgetTutorialScreen()),
    );
  }

  /// Mostra o passo a passo UMA única vez, na primeira entrada na Home
  /// depois do login, e só se o widget ainda não estiver na tela de início.
  static Future<void> exibirTutorialNoPrimeiroLoginSeNecessario(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_chaveTutorialExibido) ?? false) return;

      final instalado = await widgetInstalado();
      if (instalado == null) return; // Sem resposta agora — tenta no próximo login.
      await prefs.setBool(_chaveTutorialExibido, true);
      if (instalado || !context.mounted) return;
      await abrirTutorial(context);
    } catch (e) {
      debugPrint('⚠️ [SosWidgetStatusService] Falha ao exibir o passo a passo do widget: $e');
    }
  }
}
