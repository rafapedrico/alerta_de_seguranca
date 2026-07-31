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
const logger = require("firebase-functions/logger");

const twilioAccountSid = defineSecret("TWILIO_ACCOUNT_SID");
const twilioAuthToken = defineSecret("TWILIO_AUTH_TOKEN");
const twilioFromNumber = defineSecret("TWILIO_FROM_NUMBER");

// Lista pronta para ser espalhada em `secrets: [...TWILIO_SECRETS]` (ou
// passada diretamente) nas opções de qualquer função que chame
// [enviarSmsParaTelefones].
const TWILIO_SECRETS = [twilioAccountSid, twilioAuthToken, twilioFromNumber];

// Content SID do template "alerta_guardiao" ("Alerta Guardião-X: {{1}}"),
// aprovado pela Meta/Twilio para envio de mensagens de negócio fora da
// janela de 24h. Não é credencial (não precisa de Secret Manager), mas
// fica isolado aqui — junto do restante da configuração Twilio — para
// que uma eventual troca de template não exija mexer nos chamadores.
const CONTENT_SID_ALERTA = "HXccd14dd3758f94be24ab3ea1c162362b";

/**
 * Normaliza um telefone para o formato E.164 exigido pelo Twilio (ex:
 * "+5515981548638"). Números já cadastrados no app SEM o código do país
 * (padrão brasileiro, ex: "15981548638") recebem o prefixo "+55"
 * automaticamente — mesmo público-alvo do restante do projeto (textos,
 * comentários e contexto 100% em português/Brasil).
 *
 * @param {string} telefone
 * @return {string|null}
 */
function normalizarTelefoneE164(telefone) {
  if (!telefone) return null;
  const limpo = telefone.replace(/[^\d+]/g, "");
  if (!limpo) return null;
  if (limpo.startsWith("+")) return limpo;
  return `+55${limpo}`;
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
};
