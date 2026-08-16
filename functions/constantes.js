/**
 * Constantes compartilhadas entre módulos das Cloud Functions.
 */

// Prazo, em milissegundos, para uma solicitação de monitoramento de
// localização (`permissoes_monitoramento`, status "pendente") ser
// respondida antes de expirar automaticamente — 24 horas (ver
// `monitoramentoService.js`/`monitoramentoExpiracaoMonitor.js`).
const JANELA_EXPIRACAO_MONITORAMENTO_MS = 24 * 60 * 60 * 1000;

module.exports = {
  JANELA_EXPIRACAO_MONITORAMENTO_MS,
};
