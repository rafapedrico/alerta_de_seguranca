/**
 * Pipeline de disparo de alerta via Push FCM — módulo compartilhado pelas
 * duas origens de alerta já existentes (`aoReceberAlertaTentativaDesarme`
 * em `index.js` e `monitorarAlarmesAgendados` em
 * `scheduledAlarmMonitor.js`).
 *
 * REMOÇÃO DO WHATSAPP (2026-08-11): este módulo enviava também WhatsApp
 * de contingência via Twilio (transbordo 60s após o Push, ou imediato com
 * a chave global "Enviar também via WhatsApp"), debitando a Carteira de
 * Créditos do usuário a cada envio — removido por completo a pedido do
 * usuário, junto com `smsGateway.js`, `transbordoWhatsappMonitor.js`,
 * `walletService.js` e `comprasService.js`. O único canal de nuvem
 * restante é o Push FCM App-para-App, gratuito, para contatos de
 * emergência que também têm o Guardião X instalado.
 *
 * 1. Resolve, por telefone, quais dos contatos de emergência têm conta
 *    no app (Push FCM gratuito, App-para-App).
 * 2. Envia o Push (alta prioridade) a quem foi encontrado.
 * 3. Registra `entregas_alerta/{idEntrega}` — mantido como bookkeeping de
 *    entrega (ver `FirebaseSyncService.confirmarEntregaAlerta`/
 *    `FcmService` no app), mesmo sem nenhum job de transbordo consumindo
 *    mais essa confirmação.
 */

const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");
const {normalizarTelefoneE164} = require("./telefoneUtils");

const db = getFirestore();

const COLECAO_ENTREGAS = "entregas_alerta";
const TITULO_PUSH = "🚨 Alerta de segurança";

/**
 * Para cada contato `{nome, telefone}`, normaliza o telefone e busca em
 * `usuarios` por uma conta com esse mesmo telefone — é assim que o app
 * resolve, EM TEMPO DE ALERTA, quais dos contatos de emergência possuem
 * o Guardião X instalado (sem depender de o usuário "vincular guardiões"
 * manualmente).
 *
 * @param {Array<{nome?: string, telefone?: string}>} contatos
 * @return {Promise<Array<{nome: string, telefone: string, uidDestino: string|null, fcmToken: string|null}>>}
 */
async function resolverContasPorTelefone(contatos) {
  return Promise.all(
      (contatos || []).map(async (contato) => {
        const telefoneNormalizado = normalizarTelefoneE164(contato.telefone);
        const base = {
          nome: contato.nome || "",
          telefone: telefoneNormalizado || contato.telefone || "",
          uidDestino: null,
          fcmToken: null,
        };

        if (!telefoneNormalizado) return base;

        try {
          const snap = await db.collection("usuarios")
              .where("telefone", "==", telefoneNormalizado)
              .limit(1)
              .get();
          if (snap.empty) return base;

          const doc = snap.docs[0];
          const dados = doc.data();
          return {...base, uidDestino: doc.id, fcmToken: dados.fcmToken || null};
        } catch (e) {
          logger.error(
              `[resolverContasPorTelefone] Falha ao resolver conta para ${telefoneNormalizado}`, e,
          );
          return base;
        }
      }),
  );
}

/**
 * Envia o Push App-para-App só para quem tem `fcmToken` resolvido, como
 * mensagem DATA-ONLY (sem o campo `notification`) — de propósito: com
 * `notification` presente, o Android exibiria automaticamente uma
 * notificação padrão do sistema em segundo plano/terminado, duplicando a
 * notificação de tela cheia customizada que o próprio app monta (ver
 * `NotificacaoService.exibirNotificacaoAlertaRecebido` no Flutter). Alta
 * prioridade (`android.priority: 'high'`) garante entrega imediata mesmo
 * com o aparelho em Doze/economia de bateria. Best-effort: nunca lança
 * exceção — um token inválido/expirado não deve interromper o restante
 * do fluxo do alerta.
 *
 * @param {Array<{fcmToken: string|null}>} contatosResolvidos
 * @param {string} titulo
 * @param {string} corpo
 * @param {Object<string, string>} dadosExtras
 */
async function enviarFcmParaContatos(contatosResolvidos, titulo, corpo, dadosExtras) {
  const comToken = (contatosResolvidos || []).filter((c) => c.fcmToken);

  if (comToken.length === 0) {
    logger.info(
        "[FCM Enviado] Nenhum contato com conta no app/token válido — nenhum Push enviado.",
    );
    return;
  }

  try {
    const resposta = await getMessaging().sendEachForMulticast({
      tokens: comToken.map((c) => c.fcmToken),
      data: {...dadosExtras, titulo, corpo},
      android: {priority: "high"},
    });
    logger.info(
        `[FCM Enviado] ${resposta.successCount} enviado(s), ` +
        `${resposta.failureCount} falha(s) de ${comToken.length} token(s).`,
    );
  } catch (e) {
    logger.error("[FCM Enviado] Falha ao enviar multicast FCM", e);
  }
}

/**
 * Orquestra o disparo do alerta de emergência: resolve contas, envia o
 * Push gratuito e registra `entregas_alerta/{idEntrega}`. Retorna o id do
 * documento criado (ou `null` se não havia contatos de emergência para
 * notificar).
 *
 * @param {{usuarioId: string, contatos: Array<Object>, mensagem: string, origem: string, fotoUrl?: string, latitude?: number, longitude?: number}} params
 * @return {Promise<string|null>}
 */
async function dispararAlertaHibrido({usuarioId, contatos, mensagem, origem, fotoUrl, latitude, longitude}) {
  if (!contatos || contatos.length === 0) {
    logger.warn(
        `[dispararAlertaHibrido] Usuário ${usuarioId} não possui contatos de ` +
        "emergência — nenhum alerta será disparado.",
    );
    return null;
  }

  const contatosResolvidos = await resolverContasPorTelefone(contatos);
  const entregaRef = db.collection(COLECAO_ENTREGAS).doc();
  const idEntrega = entregaRef.id;

  let nomeRemetente = "";
  try {
    const remetenteSnap = await db.collection("usuarios").doc(usuarioId).get();
    nomeRemetente = (remetenteSnap.exists && remetenteSnap.data().nome) || "";
  } catch (e) {
    logger.error(`[dispararAlertaHibrido] Falha ao buscar nome do remetente ${usuarioId}`, e);
  }

  await enviarFcmParaContatos(contatosResolvidos, TITULO_PUSH, mensagem, {
    tipo: "alerta_emergencia",
    idEntrega,
    origem,
    mensagem,
    nomeRemetente,
    // Presente somente para alertas do tipo `sos_fisico_foto` — o app
    // do guardião usa este link (Firebase Storage, com token de
    // acesso embutido) para baixar e exibir a foto na notificação
    // (ver NotificacaoService.exibirNotificacaoAlertaRecebido).
    ...(fotoUrl ? {fotoUrl} : {}),
    // Coordenadas ESTRUTURADAS (habilita o botão "Ver no Mapa" no app
    // do guardião sem depender de parsing de texto livre) — os valores
    // de `data` do FCM só aceitam string, por isso o `.toString()`; o
    // Flutter faz o parse de volta para double (ver FcmService).
    ...(typeof latitude === "number" ? {latitude: latitude.toString()} : {}),
    ...(typeof longitude === "number" ? {longitude: longitude.toString()} : {}),
  });

  await entregaRef.set({
    usuarioId,
    origem,
    mensagem,
    criadoEm: Timestamp.now(),
    contatos: contatosResolvidos.map((c) => ({
      nome: c.nome,
      telefone: c.telefone,
      uidDestino: c.uidDestino,
    })),
  });

  logger.info(
      `[dispararAlertaHibrido] entregas_alerta/${idEntrega} criado para o usuário ` +
      `${usuarioId} (origem: ${origem}) — ${contatosResolvidos.length} contato(s).`,
  );

  return idEntrega;
}

module.exports = {
  resolverContasPorTelefone,
  enviarFcmParaContatos,
  dispararAlertaHibrido,
  COLECAO_ENTREGAS,
};
