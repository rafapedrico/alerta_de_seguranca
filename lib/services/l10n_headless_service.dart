import 'package:flutter/widgets.dart' show Locale;
import 'package:security_check_app/l10n/app_localizations.dart';

import 'locale_service.dart';
import 'localization_service.dart';

/// Ponte para obter um [AppLocalizations] SEM depender de um
/// [BuildContext] — necessário para os serviços "headless" que montam
/// mensagens de SMS/alertas/histórico fora da árvore de widgets (ex:
/// callbacks estáticos do `android_alarm_manager_plus`, disparados com o
/// app fechado ou em segundo plano — ver [EmergencyAlertService] e
/// `rotina_alarme_service.dart`).
///
/// Lê o mesmo idioma persistido em SharedPreferences (chave
/// `idioma_selecionado`, ver [LocalizationService]/[LocaleService]) e
/// carrega o [AppLocalizations] correspondente diretamente via
/// `AppLocalizations.delegate.load(Locale)`, garantindo que qualquer
/// alerta disparado pelo dispositivo (SMS, WhatsApp, log interno no
/// Histórico) saia estritamente no idioma que o usuário escolheu no
/// aplicativo — nunca no idioma do sistema operacional nem hardcoded em
/// português.
class L10nHeadlessService {
  L10nHeadlessService._();

  /// Retorna o [AppLocalizations] do idioma atualmente selecionado pelo
  /// usuário. Cai para o idioma padrão (Português) em caso de qualquer
  /// falha ao carregar (nunca lança exceção, para não travar o fluxo de
  /// disparo de um alerta de emergência).
  static Future<AppLocalizations> obter() async {
    String codigo = LocalizationService.idiomaPadrao;
    try {
      codigo = await LocalizationService().carregarIdioma();
      if (!LocaleService.idiomasComTraducaoCompleta.contains(codigo)) {
        codigo = LocalizationService.idiomaPadrao;
      }
    } catch (_) {
      codigo = LocalizationService.idiomaPadrao;
    }

    try {
      return await AppLocalizations.delegate.load(Locale(codigo));
    } catch (_) {
      return await AppLocalizations.delegate.load(const Locale('pt'));
    }
  }
}
