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
 * 5. Aciona o envio do SMS real aos contatos via Twilio — ver
 *    `smsGateway.js` (módulo compartilhado com `scheduledAlarmMonitor.js`).
 *    Requer as credenciais Twilio configuradas no Secret Manager
 *    (`firebase functions:secrets:set TWILIO_ACCOUNT_SID`, etc.) e o
 *    projeto no plano Blaze (já ativado) — sem as credenciais, degrada
 *    graciosamente para um aviso de log, sem quebrar o resto do fluxo.
 */

const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const {enviarSmsParaTelefones, TWILIO_SECRETS} = require("./smsGateway");

initializeApp();
const db = getFirestore();

const TIPO_TENTATIVA_DESARME_INCORRETO = "tentativa_desarme_incorreto";

/**
 * Extrai só os telefones de [contatos] (`{nome, telefone}[]`, formato
 * sincronizado pelo app em `usuarios/{usuarioId}.contatosEmergencia`) e
 * delega o envio real ao gateway compartilhado (ver `smsGateway.js`).
 *
 * @param {Array<{nome: string, telefone: string}>} contatos
 * @param {string} mensagem
 */
async function enviarSmsParaContatos(contatos, mensagem) {
  const telefones = contatos
      .map((contato) => contato && contato.telefone)
      .filter(Boolean);
  await enviarSmsParaTelefones(telefones, mensagem);
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
    {
      document: "usuarios/{usuarioId}/alertas/{alertaId}",
      secrets: TWILIO_SECRETS,
    },
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

// Monitoramento agendado (heartbeat & cloud alert) — ver
// scheduledAlarmMonitor.js para o fluxo completo e o modelo de dados da
// coleção `alarmes_agendados`. Reaproveita o mesmo `initializeApp()`
// já chamado acima nesta mesma inicialização do processo.
exports.monitorarAlarmesAgendados =
  require("./scheduledAlarmMonitor").monitorarAlarmesAgendados;
