import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/plano_ciclo_service.dart';
import '../services/premium_purchase_service.dart';
import '../services/sos_plano_aviso_service.dart';

/// Faixa discreta no topo da tela inicial enquanto o botão SOS estiver
/// desativado nos dias bloqueados do Plano Free (ver
/// [SosPlanoAvisoService]) — a mesma do app iOS. Some no Premium e fora
/// do período.
class AvisoSosPlanoBanner extends StatefulWidget {
  const AvisoSosPlanoBanner({super.key});

  @override
  State<AvisoSosPlanoBanner> createState() => _AvisoSosPlanoBannerState();
}

class _AvisoSosPlanoBannerState extends State<AvisoSosPlanoBanner> {
  // Um único listener por banner (o build não recria o stream).
  final Stream<PlanoCicloStatus?> _status = PlanoCicloService().statusStream();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlanoCicloStatus?>(
      stream: _status,
      builder: (context, snapshot) {
        final bloqueio = BloqueioSosPlano.vigente(snapshot.data);
        if (bloqueio == null) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context)!;
        return Material(
          color: Colors.red.shade700,
          child: SafeArea(
            bottom: false,
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              child: Row(
                children: [
                  const Icon(Icons.sos_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.sosPlanoDesativadoAte(formatarDiaMes(bloqueio.fim)),
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.3),
                    ),
                  ),
                  TextButton(
                    onPressed: PremiumPurchaseService().comprarPremium,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(l10n.sosPlanoBotaoAssinar),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
