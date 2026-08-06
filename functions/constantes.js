/**
 * Constantes compartilhadas da arquitetura híbrida de alertas (Push
 * FCM gratuito + WhatsApp de contingência pago) e da Carteira de
 * Créditos (unidades de disparo, NÃO moeda financeira — ver
 * `walletService.js`).
 */

// Custo, em CRÉDITOS (unidades de disparo — nunca moeda financeira),
// de cada mensagem de WhatsApp enviada via Twilio como contingência
// (ver `alertaHibridoService.js`/`transbordoWhatsappMonitor.js`).
// Exatamente 1 crédito por envio — nunca varia por região/operadora.
const CUSTO_WHATSAPP_CREDITOS = 1;

// Janela de espera, em milissegundos, entre o envio do Push FCM e a
// decisão de contingência via WhatsApp — 60 segundos.
const JANELA_TRANSBORDO_MS = 60 * 1000;

// Prazo, em milissegundos, para uma solicitação de monitoramento de
// localização (`permissoes_monitoramento`, status "pendente") ser
// respondida antes de expirar automaticamente — 24 horas (ver
// `monitoramentoService.js`/`monitoramentoExpiracaoMonitor.js`).
const JANELA_EXPIRACAO_MONITORAMENTO_MS = 24 * 60 * 60 * 1000;

module.exports = {
  CUSTO_WHATSAPP_CREDITOS,
  JANELA_TRANSBORDO_MS,
  JANELA_EXPIRACAO_MONITORAMENTO_MS,
};
