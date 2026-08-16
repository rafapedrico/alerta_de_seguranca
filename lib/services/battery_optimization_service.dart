import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Centraliza a solicitação da isenção de otimização de bateria
/// (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) — camada extra de
/// resiliência para o [VolumeSosService] (botão físico de pânico em
/// segundo plano) em aparelhos com gerenciamento de energia mais
/// agressivo que o AOSP padrão (comum em fabricantes como Xiaomi,
/// Samsung, Huawei), onde mesmo um Foreground Service com WakeLock pode
/// ser encerrado pelo próprio "gerenciador de bateria" do fabricante.
///
/// Diferente de SEND_SMS/READ_PHONE_STATE ([SmsPermissionService]), esta
/// não é uma permissão "dangerous" comum — é uma permissão especial que
/// abre a tela nativa `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`,
/// onde o usuário confirma explicitamente. `permission_handler` trata
/// isso de forma transparente via `Permission.ignoreBatteryOptimizations`.
///
/// Dois pontos de solicitação/visibilidade:
/// 1. [verificarNoOnboarding] — uma vez por instalação, encadeado logo
///    após o diálogo de SMS na primeira entrada na Home (ver
///    `HomeScreen.initState`).
/// 2. Um cartão permanente em Configurações/Segurança (ver
///    `ConfiguracoesTab._buildCartaoOtimizacaoBateria`), no mesmo padrão
///    visual do cartão de Administrador do Dispositivo — para quem
///    pulou o onboarding poder ativar depois.
class BatteryOptimizationService {
  BatteryOptimizationService._internal();
  static final BatteryOptimizationService _instance =
      BatteryOptimizationService._internal();
  factory BatteryOptimizationService() => _instance;

  static const String _chaveJaPerguntadoOnboarding =
      'bateria_otimizacao_perguntada_onboarding';

  /// `true` quando o app já está isento da otimização de bateria do
  /// sistema.
  Future<bool> estaIsento() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    return status.isGranted;
  }

  /// Chamado uma única vez por instalação (flag em SharedPreferences),
  /// encadeado após [SmsPermissionService.verificarNoOnboarding] — só
  /// pergunta se ainda não estava isento.
  Future<void> verificarNoOnboarding(BuildContext context) async {
    if (await estaIsento()) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_chaveJaPerguntadoOnboarding) == true) return;
      await prefs.setBool(_chaveJaPerguntadoOnboarding, true);
    } catch (e) {
      debugPrint('⚠️ [BatteryOptimizationService] Falha ao ler/gravar flag de onboarding: $e');
    }

    if (!context.mounted) return;
    await solicitarComExplicacao(context);
  }

  /// Mostra a explicação (ANTES da tela nativa do Android) e, se
  /// aceito, solicita a isenção — usado tanto pelo onboarding quanto
  /// pelo botão "Ativar" do cartão em Configurações/Segurança.
  Future<void> solicitarComExplicacao(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final bool? prosseguir = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.permissaoBateriaTitulo),
        content: Text(l10n.permissaoBateriaConteudo),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.permissaoSmsAgoraNao),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.permissaoSmsPermitir),
          ),
        ],
      ),
    );

    if (prosseguir != true) return;

    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (e) {
      debugPrint('⚠️ [BatteryOptimizationService] Falha ao solicitar isenção de bateria: $e');
    }
  }
}
