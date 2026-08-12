/**
 * Utilitário de normalização de telefone — extraído de `smsGateway.js`
 * (removido em 2026-08-11 junto com toda a integração de WhatsApp/Twilio,
 * ver `alertaHibridoService.js`) porque `normalizarTelefoneE164` é
 * genérico (não tem nada de WhatsApp) e continua sendo usado por
 * `alertaHibridoService.js` (resolver conta por telefone) e
 * `monitoramentoService.js` (resolver o uid-alvo pelo telefone informado
 * na solicitação de monitoramento).
 */

const {parsePhoneNumberFromString} = require("libphonenumber-js");

/**
 * Região usada como fallback SOMENTE quando [telefone] não contém
 * nenhum indício de DDI e o chamador não informou uma região mais
 * específica — o Guardião X é um produto GLOBAL, então isto não é uma
 * regra fixa de negócio (não existe nenhum `if (pais === 'BR')` daqui
 * pra baixo), é só o valor inicial do produto antes de existir
 * preferência de região por usuário/conta.
 */
const REGIAO_FALLBACK_PADRAO = "BR";

/**
 * Normaliza um telefone para o formato E.164 (`+<DDI><número>`), usando
 * um parser internacional de verdade (`libphonenumber-js`, mesma base do
 * libphonenumber do Google) em vez de concatenação ingênua de string —
 * funciona para qualquer país, detecta e remove DDI duplicado e
 * prefixos de acesso nacional (ex: o "0" local) automaticamente, e
 * remove toda formatação (espaços, traços, parênteses).
 *
 * Retorna `null` (em vez de um número corrompido) quando não é possível
 * validar o telefone em nenhuma interpretação razoável.
 *
 * @param {string} telefone
 * @param {string} [regiaoPadrao] Região ISO-3166 alpha-2 (ex: "US", "PT")
 *     usada como referência apenas quando o número não contém DDI.
 * @return {string|null}
 */
function normalizarTelefoneE164(telefone, regiaoPadrao = REGIAO_FALLBACK_PADRAO) {
  if (!telefone) return null;
  const bruto = String(telefone).trim();
  if (!bruto) return null;

  try {
    const numero = parsePhoneNumberFromString(bruto, regiaoPadrao);
    return numero && numero.isValid() ? numero.number : null;
  } catch (e) {
    return null;
  }
}

module.exports = {normalizarTelefoneE164};
