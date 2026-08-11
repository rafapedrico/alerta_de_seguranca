import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/monitoramento_service.dart';

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

  await MonitoramentoService().responderSolicitacao(
    permissaoId: idPermissao,
    // Dispensado sem escolha explícita (toque fora / voltar) => `null` =>
    // tratado como recusa.
    aprovar: aprovou ?? false,
    uidSolicitante: uidSolicitante,
    nomeSolicitante: nomeSolicitante,
    telefoneSolicitante: telefoneSolicitante,
  );
}
