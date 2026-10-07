import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/sos_plano_aviso_service.dart';
import '../services/sos_widget_fluxo_service.dart';

/// Tela preta do Widget SOS: a única coisa visível do toque até a
/// `SosEmAndamentoScreen` abrir (ver [SosWidgetFluxoService]). Fica em
/// `MaterialApp.builder` por cima do Navigator e da [CamadaBloqueioApp];
/// some sozinha quando [SosWidgetFluxoService.etapa] volta a `null`.
class CamadaTelaSosWidget extends StatelessWidget {
  const CamadaTelaSosWidget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EtapaTelaSosWidget?>(
      valueListenable: SosWidgetFluxoService().etapa,
      child: child,
      builder: (context, etapa, conteudo) {
        return Stack(
          children: [
            ExcludeSemantics(excluding: etapa != null, child: conteudo!),
            if (etapa != null) Positioned.fill(child: TelaSosWidget(etapa: etapa)),
          ],
        );
      },
    );
  }
}

/// Mesmo visual da `SosEmAndamentoScreen` (fundo preto, letras vermelhas):
/// a troca entre as duas não aparece.
class TelaSosWidget extends StatelessWidget {
  const TelaSosWidget({super.key, required this.etapa});

  final EtapaTelaSosWidget etapa;

  String _texto(AppLocalizations? l10n) {
    switch (etapa) {
      case EtapaTelaSosWidget.enviandoLocalizacao:
        return l10n?.sosEnviandoLocalizacao ?? 'Alerta acionado. Enviando sua localização…';
      case EtapaTelaSosWidget.desativadoPlanoFree:
        final fim = SosWidgetFluxoService().fimBloqueioPlano;
        final data = fim == null ? '—' : formatarDiaMes(fim);
        return l10n?.sosPlanoWidgetDesativado(data) ??
            'Botão SOS desativado no Plano Free até $data';
    }
  }

  List<Widget> _botoesPlano(AppLocalizations? l10n) => [
        const SizedBox(height: 36),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: SosWidgetFluxoService().assinarPremium,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            child: Text(l10n?.sosPlanoBotaoAssinar ?? 'Assinar Premium'),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: SosWidgetFluxoService().fecharAvisoPlano,
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
          child: Text(l10n?.agoraNao ?? 'Agora não'),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final plano = etapa == EtapaTelaSosWidget.desativadoPlanoFree;
    // Material próprio: absorve os toques e não depende de nenhuma rota.
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!plano)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 28),
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  ),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _texto(l10n),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      height: 1.35,
                    ),
                  ),
                ),
                if (plano) ..._botoesPlano(l10n),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
