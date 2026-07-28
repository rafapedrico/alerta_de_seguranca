/**
 * Constantes compartilhadas da arquitetura híbrida de alertas (Push
 * FCM gratuito + WhatsApp de contingência pago) e da Carteira em USD.
 */

// Custo fixo, em USD, de cada mensagem de WhatsApp enviada via Twilio
// como contingência (ver `alertaHibridoService.js`/
// `transbordoWhatsappMonitor.js`). Exatamente $0.10, conforme
// especificação — nunca varia por região/operadora.
const CUSTO_WHATSAPP_USD = 0.10;

// Janela de espera, em milissegundos, entre o envio do Push FCM e a
// decisão de contingência via WhatsApp — 60 segundos.
const JANELA_TRANSBORDO_MS = 60 * 1000;

module.exports = {
  CUSTO_WHATSAPP_USD,
  JANELA_TRANSBORDO_MS,
};
