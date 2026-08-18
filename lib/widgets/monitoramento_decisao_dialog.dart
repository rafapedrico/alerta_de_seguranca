import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/monitoramento_service.dart';
import 'plano_bloqueado_dialog.dart';

const Color _corDestaque = Color(0xFF4C7040);

/// Modal "Aceitar ou Recusar" de uma solicitação de compartilhamento de
/// localização recebida na aba Monitoramento — COMPARTILHADO entre o
/// listener em tempo real da própria aba ([MonitoramentoTabState], quando o
/// usuário já está com a tela aberta) e a abertura direta a partir do toque
/// na notificação push (ver `NotificacaoService`), garantindo exatamente o
/// mesmo comportamento nos dois casos.
///
/// [barrierDismissible] mantém o padrão do `showDialog` (toque fora do
/// diálogo fecha) e o botão físico/gesto de voltar do Android também fecha
/// a rota por padrão — em AMBOS os casos o resultado é `null`, tratado
/// abaixo como uma RECUSA explícita: a solicitação nunca fica presa em
/// "pendente" silenciosamente só porque o usuário dispensou o modal sem
/// tocar em um dos dois botões.
///
/// Bloquear um contato é feito EXCLUSIVAMENTE pelo slider deslizante de
/// cada card na aba Monitoramento (ver `monitoramento_tab.dart`) — sempre
/// visível na lista, ao contrário de uma ação escondida neste modal.
Future<void> exibirDialogoDecisaoMonitoramento({
  required BuildContext context,
  required String idPermissao,
  required String uidSolicitante,
  required String nomeSolicitante,
  required String telefoneSolicitante,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final nomeExibido =
      nomeSolicitante.trim().isNotEmpty ? nomeSolicitante.trim() : telefoneSolicitante;

  final aprovou = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.monitoramentoSolicitacaoRecebidaTitulo),
      content: Text(l10n.monitoramentoSolicitacaoRecebidaConteudo(nomeExibido)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.monitoramentoBloquearRecusar),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _corDestaque),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.monitoramentoPermitir),
        ),
      ],
    ),
  );

  // BLOQUEIO BIDIRECIONAL de localização do ciclo do Plano Free (ver
  // PlanoCicloService): só checado quando o usuário de fato tocou em
  // "Permitir" — recusar/dispensar o modal nunca é bloqueado, é sempre
  // uma ação segurança-positiva. Fora dos 10 dias ativos do mês, exibe o
  // modal de upsell e trata como recusa (mesmo comportamento já usado
  // acima para "dispensado sem escolha explícita").
  bool aprovarDeFato = aprovou ?? false;
  if (aprovarDeFato && context.mounted) {
    aprovarDeFato = await garantirRecursoLiberadoOuExibirUpsell(context);
  }

  await MonitoramentoService().responderSolicitacao(
    permissaoId: idPermissao,
    aprovar: aprovarDeFato,
    uidSolicitante: uidSolicitante,
    nomeSolicitante: nomeSolicitante,
    telefoneSolicitante: telefoneSolicitante,
  );
}
