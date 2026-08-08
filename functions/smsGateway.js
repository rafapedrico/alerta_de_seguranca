/**
 * Gateway de mensagens real (Twilio, WhatsApp Business API) — módulo
 * compartilhado usado tanto pela Cloud Function reativa
 * (`aoReceberAlertaTentativaDesarme`, ver `index.js`) quanto pela
 * agendada (`monitorarAlarmesAgendados`, ver `scheduledAlarmMonitor.js`),
 * para nunca duplicar a lógica de envio.
 *
 * Envia via WhatsApp usando o número comercial aprovado pela Meta (NÃO
 * mais o Sandbox da Twilio) e um Content Template pré-aprovado
 * ("alerta_guardiao", Content SID [CONTENT_SID_ALERTA] abaixo) — fora da
 * janela de 24h de conversa ativa, a API oficial do WhatsApp só aceita
 * mensagens de negócio (business-initiated) nesse formato de template;
 * enviar texto livre (`body`) fora da janela falha com o erro Twilio
 * 63016 ("outside messaging window"). O texto dinâmico do alerta entra
 * como variável `{{1}}` do template (ver `contentVariables` abaixo).
 *
 * Credenciais (Account SID, Auth Token, número de origem) NUNCA ficam no
 * código nem em variáveis de ambiente comuns — são declaradas como
 * SECRETS do Firebase Functions v2 (Secret Manager), configuradas com:
 *
 *   firebase functions:secrets:set TWILIO_ACCOUNT_SID
 *   firebase functions:secrets:set TWILIO_AUTH_TOKEN
 *   firebase functions:secrets:set TWILIO_FROM_NUMBER   (ex: whatsapp:+15817095728)
 *
 * Cada função que precisar enviar mensagens deve declarar
 * `secrets: TWILIO_SECRETS` nas suas opções (ver uso em
 * `index.js`/`scheduledAlarmMonitor.js`) para que o Firebase injete os
 * valores em tempo de execução.
 */

const {defineSecret} = require("firebase-functions/params");
const {parsePhoneNumberFromString} = require("libphonenumber-js");
const logger = require("firebase-functions/logger");
const {TEMPLATES_WHATSAPP} = require("./whatsappTemplates");

const twilioAccountSid = defineSecret("TWILIO_ACCOUNT_SID");
// Exportado individualmente (além de dentro de [TWILIO_SECRETS]) porque
// `whatsappWebhook.js` precisa dele sozinho para validar a assinatura das
// requisições inbound da Twilio — `defineSecret` é idempotente por nome,
// mas reaproveitar a mesma instância evita declarar o mesmo secret duas
// vezes em módulos diferentes.
const twilioAuthToken = defineSecret("TWILIO_AUTH_TOKEN");
const twilioFromNumber = defineSecret("TWILIO_FROM_NUMBER");

// Lista pronta para ser espalhada em `secrets: [...TWILIO_SECRETS]` (ou
// passada diretamente) nas opções de qualquer função que chame
// [enviarSmsParaTelefones].
const TWILIO_SECRETS = [twilioAccountSid, twilioAuthToken, twilioFromNumber];

// Content SID do template "alerta_guardiao" ("Alerta Guardião-X: {{1}}"),
// aprovado pela Meta/Twilio para envio de mensagens de negócio fora da
// janela de 24h — ver `whatsappTemplates.js` para o registro completo de
// templates (inclusive os ainda pendentes de aprovação).
const CONTENT_SID_ALERTA = TEMPLATES_WHATSAPP.ALERTA_EMERGENCIA;

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
 * Normaliza um telefone para o formato E.164 (`+<DDI><número>`) exigido
 * pelo Twilio, usando um parser internacional de verdade
 * (`libphonenumber-js`, mesma base do libphonenumber do Google) em vez
 * de concatenação ingênua de string — funciona para qualquer país,
 * detecta e remove DDI duplicado e prefixos de acesso nacional (ex: o
 * "0" local) automaticamente, e remove toda formatação (espaços,
 * traços, parênteses).
 *
 * CORREÇÃO DE BUG REAL: a implementação antiga só prefixava "+55" quando
 * o texto não começava com "+", sem checar se o DDI já estava embutido
 * nos dígitos — um contato salvo como "5515981343706" (DDI já incluso,
 * sem o "+", comum em números importados da agenda do celular) virava
 * "+555515981343706" (DDI duplicado, E.164 inválido). A Twilio aceitava
 * o envio mesmo assim ("status: queued"), debitando a Carteira do
 * usuário por uma mensagem que nunca chegava a lugar nenhum de verdade.
 *
 * Retorna `null` (em vez de um número corrompido) quando não é possível
 * validar o telefone em nenhuma interpretação razoável — mais seguro do
 * que gastar saldo/crédito Twilio tentando enviar para um número que não
 * existe.
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

/**
 * Envia [mensagem] de verdade via WhatsApp (Twilio) para cada telefone
 * em [telefones]. Nunca lança exceção nem deixa a falha de UM contato
 * interromper o envio aos demais — cada tentativa é isolada em seu
 * próprio try/catch.
 *
 * Se as credenciais Twilio ainda não tiverem sido configuradas (Secret
 * Manager vazio), degrada graciosamente: loga um aviso claro e NÃO
 * envia nada — o resto do pipeline (Firestore, localização, etc.)
 * continua funcionando normalmente, exatamente como antes desta
 * integração.
 *
 * @param {Array<string>} telefones
 * @param {string} mensagem
 */
async function enviarSmsParaTelefones(telefones, mensagem) {
  if (!telefones || telefones.length === 0) return;

  const accountSid = twilioAccountSid.value();
  const authToken = twilioAuthToken.value();
  const fromNumber = twilioFromNumber.value();

  if (!accountSid || !authToken || !fromNumber) {
    logger.warn(
        "[enviarSmsParaTelefones] Credenciais Twilio ausentes no Secret " +
        "Manager (TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN/TWILIO_FROM_NUMBER) " +
        "- mensagem NAO enviada de verdade. Configure com " +
        "'firebase functions:secrets:set <NOME>'. " +
        `Destinatarios: ${JSON.stringify(telefones)}. Mensagem: ${mensagem}`,
    );
    return;
  }

  // Lazy require: evita custo de inicializar o client Twilio em funções
  // que importam este módulo mas nunca chegam a enviar mensagem de
  // verdade.
  const twilio = require("twilio");
  const client = twilio(accountSid, authToken);

  for (const telefoneOriginal of telefones) {
    const telefone = normalizarTelefoneE164(telefoneOriginal);
    if (!telefone) continue;

    try {
      const resultado = await client.messages.create({
        to: `whatsapp:${telefone}`,
        from: fromNumber,
        contentSid: CONTENT_SID_ALERTA,
        // A API de Content da Twilio exige as variáveis como uma STRING
        // JSON (não um objeto), com chaves numéricas em string
        // correspondendo aos placeholders `{{1}}`, `{{2}}` etc. do
        // template aprovado.
        contentVariables: JSON.stringify({"1": mensagem}),
      });
      logger.info(
          `[enviarSmsParaTelefones] Mensagem WhatsApp (template ` +
          `${CONTENT_SID_ALERTA}) enviada para ${telefone} ` +
          `(sid: ${resultado.sid}, status: ${resultado.status}).`,
      );
    } catch (e) {
      logger.error(
          `[enviarSmsParaTelefones] Falha ao enviar WhatsApp para ${telefone} ` +
          "(verifique o status do template/sender no Console da Twilio)", e,
      );
    }
  }
}

module.exports = {
  enviarSmsParaTelefones,
  normalizarTelefoneE164,
  TWILIO_SECRETS,
  twilioAuthToken,
};
