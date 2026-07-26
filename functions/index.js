/**
 * Cloud Functions do projeto Firebase "guardiaox" — camada de resiliência
 * na nuvem do Guardião X (security_check_app).
 *
 * FLUXO IMPLEMENTADO (tentativa de desarme com PIN incorreto):
 * 1. O app Flutter escreve, de forma minimalista e o mais rápido possível,
 *    um documento em `usuarios/{usuarioId}/alertas/{alertaId}` assim que
 *    detecta 2 PINs incorretos consecutivos no desarme antecipado (ver
 *    FirebaseSyncService.dispararAlertaTentativaDesarmeIncorreto no app).
 * 2. Esta função é acionada automaticamente por esse `onDocumentCreated`.
 * 3. Ela resgata a ÚLTIMA localização conhecida (gravada periodicamente a
 *    cada 1 minuto pelo app, ver FirebaseSyncService.atualizarLocalizacaoAtual)
 *    e a lista de contatos de emergência (sincronizada a partir do SQLite
 *    local do usuário) do documento `usuarios/{usuarioId}`.
 * 4. Monta a mensagem de alerta com o link do Google Maps.
 * 5. Aciona o envio do SMS/notificação aos contatos — ver TODO explícito
 *    em `enviarSmsParaContatos` abaixo: o gateway de SMS (Twilio, AWS SNS,
 *    etc.) ainda NÃO foi conectado. Enquanto isso, a função apenas
 *    registra a mensagem que SERIA enviada e marca o alerta como
 *    "processado", para que o pipeline completo possa ser testado de
 *    ponta a ponta (Firestore -> trigger -> montagem da mensagem) mesmo
 *    sem custo de SMS real e sem exigir o plano Blaze para chamadas
 *    externas.
 */

const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");

initializeApp();
const db = getFirestore();

const TIPO_TENTATIVA_DESARME_INCORRETO = "tentativa_desarme_incorreto";

/**
 * TODO (gateway de SMS): ainda NÃO envia SMS de verdade — apenas loga o
 * que seria enviado. Quando o provedor for escolhido (Twilio, AWS SNS,
 * Zenvia, etc.), implemente a chamada real aqui e mantenha os try/catch
 * por contato, para que a falha de UM destinatário nunca impeça o envio
 * aos demais.
 *
 * IMPORTANTE: chamadas de rede para APIs externas (Twilio, etc.) só
 * funcionam com o projeto no plano Blaze (pay-as-you-go) do Firebase. No
 * plano gratuito (Spark), esta função roda normalmente até aqui, mas uma
 * chamada HTTP de saída seria bloqueada.
 *
 * Exemplo de integração futura com Twilio (pseudo-código):
 *   const accountSid = process.env.TWILIO_ACCOUNT_SID;
 *   const authToken = process.env.TWILIO_AUTH_TOKEN;
 *   const numeroRemetente = process.env.TWILIO_FROM_NUMBER;
 *   const twilio = require("twilio")(accountSid, authToken);
 *   for (const contato of contatos) {
 *     await twilio.messages.create({
 *       to: contato.telefone,
 *       from: numeroRemetente,
 *       body: mensagem,
 *     });
 *   }
 *
 * @param {Array<{nome: string, telefone: string}>} contatos
 * @param {string} mensagem
 */
async function enviarSmsParaContatos(contatos, mensagem) {
  logger.warn(
      "[enviarSmsParaContatos] Gateway de SMS ainda NAO configurado " +
      "(TODO) - mensagem NAO foi enviada de verdade. " +
      `Destinatarios: ${JSON.stringify(contatos)}. Mensagem: ${mensagem}`,
  );
}

/**
 * @param {number} latitude
 * @param {number} longitude
 * @return {string}
 */
function montarLinkGoogleMaps(latitude, longitude) {
  return `https://maps.google.com/?q=${latitude},${longitude}`;
}

/**
 * @param {number|undefined} latitude
 * @param {number|undefined} longitude
 * @return {string}
 */
function montarTextoLocalizacao(latitude, longitude) {
  if (typeof latitude === "number" && typeof longitude === "number") {
    return `Latitude: ${latitude}, Longitude: ${longitude} ` +
        `(${montarLinkGoogleMaps(latitude, longitude)})`;
  }
  return "Localização indisponível (nenhuma posição registrada na nuvem " +
      "para este usuário).";
}

exports.aoReceberAlertaTentativaDesarme = onDocumentCreated(
    "usuarios/{usuarioId}/alertas/{alertaId}",
    async (event) => {
      const snap = event.data;
      if (!snap) {
        logger.warn("Evento sem dados (snap ausente) — ignorado.");
        return;
      }

      const alerta = snap.data();
      const {usuarioId} = event.params;

      if (alerta.tipo !== TIPO_TENTATIVA_DESARME_INCORRETO) {
        logger.info(
            `Alerta tipo "${alerta.tipo}" ainda não tratado por esta ` +
            "função — ignorado.",
        );
        return;
      }

      const usuarioRef = db.collection("usuarios").doc(usuarioId);
      const usuarioSnap = await usuarioRef.get();
      const usuario = usuarioSnap.exists ? usuarioSnap.data() : {};

      const localizacaoTexto = montarTextoLocalizacao(
          usuario && usuario.latitude,
          usuario && usuario.longitude,
      );
      const contatos = (usuario && usuario.contatosEmergencia) || [];

      // `motivo` descreve exatamente o que aconteceu (ver
      // FirebaseSyncService.dispararAlertaTentativaDesarmeIncorreto no
      // app) — cai no texto histórico apenas se o documento não o
      // informar (compatibilidade com alertas antigos/de teste).
      const motivo = alerta.motivo ||
          "O PIN foi digitado incorretamente 2 vezes seguidas ao tentar " +
          "desarmar antecipadamente o sistema de segurança.";

      const mensagem =
          "⚠️ ALERTA DE SEGURANÇA (via nuvem): TENTATIVA DE DESARME COM " +
          "SENHA INCORRETA!\n" +
          `${motivo}\n` +
          `Localização: ${localizacaoTexto}`;

      if (contatos.length === 0) {
        logger.warn(
            `Usuário ${usuarioId} não possui contatos de emergência ` +
            "sincronizados no Firestore — nenhum SMS será enviado.",
        );
      } else {
        await enviarSmsParaContatos(contatos, mensagem);
      }

      await snap.ref.update({
        processado: true,
        processadoEm: new Date().toISOString(),
        localizacaoUsadaNoAlerta: localizacaoTexto,
        totalContatosNotificados: contatos.length,
      });
    },
);
