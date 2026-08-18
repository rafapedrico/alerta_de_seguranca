import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/plano_ciclo_service.dart';

const Color _corDestaquePremium = Color(0xFF9C6BFF);

// Mesmo pacote Android usado em `InicioDashboard._androidPackageId` — só
// para montar o link de assinatura da Play Store.
const String _androidPackageId = 'com.rmfglobal.guardiaox';

/// Verifica, NA HORA (sempre uma leitura fresca, nunca cacheada — ver
/// [PlanoCicloService.podeUsarRecursosAvancados]), se o usuário pode usar
/// mensagens/alertas em tempo real ou localização em tempo real agora. Se
/// puder, retorna `true` imediatamente sem exibir nada — o chamador
/// prossegue normalmente. Se NÃO puder (Plano Free fora da janela de 10
/// dias ativos do mês), exibe o modal explicativo de upsell do Plano
/// Premium e retorna `false` — o chamador DEVE interromper o fluxo
/// (nenhum SMS/Push é disparado nem nenhuma localização é
/// solicitada/compartilhada a partir daqui).
///
/// Usada exclusivamente nos pontos onde o usuário toca em algo NA TELA
/// (botão de SOS manual, solicitar/compartilhar localização) — fluxos
/// automáticos/headless (alarme de rotina disparando com o app fechado,
/// botão físico) são bloqueados diretamente dentro de
/// [EmergencyAlertService]/[FirebaseSyncService]/[MonitoramentoService],
/// que não têm um [BuildContext] disponível para exibir este modal.
Future<bool> garantirRecursoLiberadoOuExibirUpsell(BuildContext context) async {
  final bool liberado = await PlanoCicloService().podeUsarRecursosAvancados();
  if (liberado) return true;
  if (!context.mounted) return false;
  await _exibirModalPlanoBloqueado(context);
  return false;
}

Future<void> _exibirModalPlanoBloqueado(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  // Reaproveita a MESMA leitura fresca acima (não uma nova consulta) só
  // para extrair a data de renovação a exibir — best-effort: sem ela,
  // mostra o modal com um placeholder neutro em vez de travar o fluxo.
  final status = await PlanoCicloService().obterStatusAtualizado();
  final String dataFormatada = status != null
      ? _formatarData(status.dataRenovacao)
      : '—';

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.lock_clock, color: _corDestaquePremium, size: 32),
      title: Text(l10n.planoBloqueadoModalTitulo),
      content: Text(l10n.planoBloqueadoModalConteudo(dataFormatada)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.agoraNao),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _corDestaquePremium),
          onPressed: () {
            Navigator.of(ctx).pop();
            _abrirPlayStore();
          },
          child: Text(l10n.planoBloqueadoModalBotaoAssinar),
        ),
      ],
    ),
  );
}

String _formatarData(DateTime data) {
  final dia = data.day.toString().padLeft(2, '0');
  final mes = data.month.toString().padLeft(2, '0');
  return '$dia/$mes/${data.year}';
}

/// Mesma estratégia de [InicioDashboard._abrirPlayStore]: tenta o app
/// nativo da Play Store primeiro, cai para o link web se indisponível.
Future<void> _abrirPlayStore() async {
  final uriApp = Uri.parse('market://details?id=$_androidPackageId');
  try {
    if (await canLaunchUrl(uriApp)) {
      await launchUrl(uriApp, mode: LaunchMode.externalApplication);
      return;
    }
  } catch (_) {
    // Cai para o link web abaixo.
  }
  try {
    await launchUrl(
      Uri.parse('https://play.google.com/store/apps/details?id=$_androidPackageId'),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // Best-effort — se nenhum dos dois funcionar, apenas não abre nada.
  }
}
