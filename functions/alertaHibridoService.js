/**
 * Pipeline híbrido de disparo de alerta — módulo compartilhado pelas duas
 * origens de alerta já existentes (`aoReceberAlertaTentativaDesarme` em
 * `index.js` e `monitorarAlarmesAgendados` em `scheduledAlarmMonitor.js`).
 *
 * Substitui o antigo envio DIRETO e sempre-pago via WhatsApp/Twilio por:
 * 1. Resolver, por telefone, quais dos contatos de emergência têm conta
 *    no app (Push FCM gratuito, App-para-App).
 * 2. Enviar o Push (alta prioridade) a quem foi encontrado.
 * 3. Criar um documento em `entregas_alerta` com prazo de 60s — é o job
 *    agendado `processarTransbordoAlertas` (ver
 *    `transbordoWhatsappMonitor.js`) quem decide, depois desse prazo,
 *    quem realmente precisa do WhatsApp de contingência (pago).
 */

const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");
const {normalizarTelefoneE164} = require("./smsGateway");
const {JANELA_TRANSBORDO_MS} = require("./constantes");

const db = getFirestore();

const COLECAO_ENTREGAS = "entregas_alerta";
const STATUS_AGUARDANDO_TRANSBORDO = "AGUARDANDO_TRANSBORDO";
const TITULO_PUSH = "🚨 Alerta de segurança";

/**
 * Para cada contato `{nome, telefone, whatsappHabilitado}`, normaliza o
 * telefone e busca em `usuarios` por uma conta com esse mesmo telefone —
 * é assim que o app resolve, EM TEMPO DE ALERTA, quais dos 3 contatos de
 * emergência possuem o Guardião X instalado (sem depender de o usuário
 * "vincular guardiões" manualmente).
 *
 * @param {Array<{nome?: string, telefone?: string, whatsappHabilitado?: boolean}>} contatos
 * @return {Promise<Array<{nome: string, telefone: string, whatsappHabilitado: boolean, uidDestino: string|null, fcmToken: string|null}>>}
 */
async function resolverContasPorTelefone(contatos) {
  return Promise.all(
      (contatos || []).map(async (contato) => {
        const telefoneNormalizado = normalizarTelefoneE164(contato.telefone);
        const base = {
          nome: contato.nome || "",
          telefone: telefoneNormalizado || contato.telefone || "",
          whatsappHabilitado: !!contato.whatsappHabilitado,
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
 * Orquestra o disparo híbrido de um alerta de emergência: resolve contas,
 * envia o Push gratuito e registra `entregas_alerta/{idEntrega}` com o
 * prazo de transbordo de 60s. Retorna o id do documento criado (ou
 * `null` se não havia contatos de emergência para notificar).
 *
 * @param {{usuarioId: string, contatos: Array<Object>, mensagem: string, origem: string}} params
 * @return {Promise<string|null>}
 */
async function dispararAlertaHibrido({usuarioId, contatos, mensagem, origem}) {
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
  });

  const prazoTransbordoEpochMs = Date.now() + JANELA_TRANSBORDO_MS;

  await entregaRef.set({
    usuarioId,
    origem,
    mensagem,
    status: STATUS_AGUARDANDO_TRANSBORDO,
    criadoEm: Timestamp.now(),
    prazoTransbordoEpochMs,
    contatos: contatosResolvidos.map((c) => ({
      nome: c.nome,
      telefone: c.telefone,
      whatsappHabilitado: c.whatsappHabilitado,
      uidDestino: c.uidDestino,
    })),
  });

  logger.info(
      `[Aguardando 60s] entregas_alerta/${idEntrega} criado para o usuário ` +
      `${usuarioId} (origem: ${origem}) — ${contatosResolvidos.length} contato(s), ` +
      `transbordo às ${new Date(prazoTransbordoEpochMs).toISOString()}.`,
  );

  return idEntrega;
}

module.exports = {
  resolverContasPorTelefone,
  enviarFcmParaContatos,
  dispararAlertaHibrido,
  COLECAO_ENTREGAS,
  STATUS_AGUARDANDO_TRANSBORDO,
};
