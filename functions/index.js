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
 * 5. Aciona o PIPELINE HÍBRIDO de entrega (ver `alertaHibridoService.js`):
 *    Push FCM gratuito para os contatos que têm o app instalado, com
 *    WhatsApp/Twilio como contingência paga só depois de 60s sem
 *    confirmação de entrega (ver `transbordoWhatsappMonitor.js`) — e só
 *    para contatos com a chave "Notificar via WhatsApp" ligada e saldo
 *    suficiente na Carteira do usuário.
 */

const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");

// IMPORTANTE: initializeApp() precisa rodar ANTES de qualquer módulo que
// chame getFirestore()/getMessaging() em seu próprio escopo top-level
// (ver alertaHibridoService.js, walletService.js, comprasService.js,
// scheduledAlarmMonitor.js, transbordoWhatsappMonitor.js) — por isso
// esses `require`s só acontecem DEPOIS da linha abaixo, nunca antes.
initializeApp();
const db = getFirestore();

const {dispararAlertaHibrido} = require("./alertaHibridoService");

const TIPO_TENTATIVA_DESARME_INCORRETO = "tentativa_desarme_incorreto";

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
            "sincronizados no Firestore — nenhum alerta será disparado.",
        );
      } else {
        await dispararAlertaHibrido({
          usuarioId,
          contatos,
          mensagem,
          origem: "tentativa_desarme",
        });
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

// Job agendado do "transbordo" WhatsApp (ver transbordoWhatsappMonitor.js)
// — decide, 60s após cada Push FCM, quem realmente precisa (e pode ser
// cobrado por) da contingência via WhatsApp/Twilio.
exports.processarTransbordoAlertas =
  require("./transbordoWhatsappMonitor").processarTransbordoAlertas;

// Callable de verificação de compra de créditos (ver comprasService.js)
// — recarga da Carteira em USD via Google Play, com verificação
// server-side antes de creditar qualquer saldo.
exports.confirmarCompraCredito =
  require("./comprasService").confirmarCompraCredito;

// Aba Monitoramento (ver monitoramentoService.js): permissão bilateral e
// explícita de compartilhamento de localização GPS em tempo real,
// totalmente independente do pipeline de alerta de emergência acima.
// - Callable acionada pelo botão "Solicitar Localização" no app.
const monitoramentoService = require("./monitoramentoService");
exports.solicitarMonitoramento = monitoramentoService.solicitarMonitoramento;
// - Trigger que notifica o solicitante quando o alvo aprova/nega/bloqueia.
exports.aoAtualizarPermissaoMonitoramento =
  monitoramentoService.aoAtualizarPermissaoMonitoramento;
// - Callable acionada pelo Switch de pré-autorização em cada card da
// lista "Localização de familiares" (concede/bloqueia diretamente, sem
// esperar uma solicitação prévia do contato).
exports.definirPermissaoCompartilhamento =
  monitoramentoService.definirPermissaoCompartilhamento;
// - Job agendado (regra das 24h) que expira solicitações pendentes sem
// resposta (ver monitoramentoExpiracaoMonitor.js).
exports.monitorarExpiracaoMonitoramento =
  require("./monitoramentoExpiracaoMonitor").monitorarExpiracaoMonitoramento;
