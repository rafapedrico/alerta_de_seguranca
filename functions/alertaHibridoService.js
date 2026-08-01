/**
 * Pipeline híbrido de disparo de alerta — módulo compartilhado pelas duas
 * origens de alerta já existentes (`aoReceberAlertaTentativaDesarme` em
 * `index.js` e `monitorarAlarmesAgendados` em `scheduledAlarmMonitor.js`).
 *
 * Substitui o antigo envio DIRETO e sempre-pago via WhatsApp/Twilio por:
 * 1. Resolver, por telefone, quais dos contatos de emergência têm conta
 *    no app (Push FCM gratuito, App-para-App).
 * 2. Enviar o Push (alta prioridade) a quem foi encontrado — em paralelo,
 *    se a chave GLOBAL "Enviar também via WhatsApp" (ver
 *    `usuarios/{uid}.enviarWhatsappSimultaneo`, ConfiguracoesTab) estiver
 *    ligada, também tenta debitar a Carteira e enviar WhatsApp
 *    IMEDIATAMENTE (sem aguardar transbordo) para cada contato com
 *    "Notificar via WhatsApp" ligado e saldo suficiente.
 * 3. Criar um documento em `entregas_alerta` com prazo de 60s — é o job
 *    agendado `processarTransbordoAlertas` (ver
 *    `transbordoWhatsappMonitor.js`) quem decide, depois desse prazo,
 *    quem AINDA precisa do WhatsApp de contingência (pulando quem já foi
 *    atendido pelo envio simultâneo do passo 2, ver `whatsappJaEnviado`
 *    abaixo).
 */

const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");
const {normalizarTelefoneE164, enviarSmsParaTelefones} = require("./smsGateway");
const {debitarSaldo} = require("./walletService");
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
 * Envia o WhatsApp de contingência de forma IMEDIATA — em paralelo ao
 * Push FCM, sem aguardar os 60s normais de transbordo (ver
 * `transbordoWhatsappMonitor.js`) — para cada contato com "Notificar via
 * WhatsApp" ligado. Usado somente quando a chave GLOBAL "Enviar também
 * via WhatsApp" (`usuarios/{uid}.enviarWhatsappSimultaneo`, ver
 * ConfiguracoesTab) está ativa. Debita a Carteira ANTES de cada envio,
 * exatamente com a mesma regra do transbordo (`debitarSaldo` — nunca
 * deixa o saldo negativo); um contato sem saldo suficiente simplesmente
 * não é enviado aqui e permanece elegível para a tentativa normal de
 * transbordo 60s depois. Nunca lança exceção — cada contato é isolado em
 * seu próprio try/catch.
 *
 * @param {string} usuarioId
 * @param {Array<{telefone: string, nome: string, whatsappHabilitado: boolean}>} contatosResolvidos
 * @param {string} mensagem
 * @param {string} idEntrega
 * @return {Promise<Set<string>>} telefones que TIVERAM uma tentativa
 *     bem-sucedida (debitado + enviado) — usado para o transbordo nunca
 *     cobrar esses mesmos contatos de novo.
 */
async function enviarWhatsappSimultaneoParaContatos(usuarioId, contatosResolvidos, mensagem, idEntrega) {
  const elegiveis = (contatosResolvidos || []).filter((c) => c.whatsappHabilitado);
  const enviados = new Set();

  await Promise.all(elegiveis.map(async (contato) => {
    try {
      const resultadoDebito = await debitarSaldo(usuarioId, contato, idEntrega);
      if (!resultadoDebito.sucesso) {
        logger.info(
            `[WhatsApp Simultâneo] entregas_alerta/${idEntrega} — não foi possível debitar ` +
            `o saldo do usuário ${usuarioId} para o contato ${contato.telefone} ` +
            `(motivo: ${resultadoDebito.motivo}); contato segue elegível para o transbordo padrão.`,
        );
        return;
      }

      await enviarSmsParaTelefones([contato.telefone], mensagem);
      enviados.add(contato.telefone);
      logger.info(
          `[WhatsApp Simultâneo] entregas_alerta/${idEntrega} — $0.10 USD debitado do ` +
          `usuário ${usuarioId}; WhatsApp enviado IMEDIATAMENTE (junto com o Push, sem ` +
          `aguardar os 60s de transbordo) para ${contato.telefone}.`,
      );
    } catch (e) {
      logger.error(
          `[WhatsApp Simultâneo] Falha ao processar contato ${contato.telefone} de entregas_alerta/${idEntrega}`, e,
      );
    }
  }));

  return enviados;
}

/**
 * Orquestra o disparo híbrido de um alerta de emergência: resolve contas,
 * envia o Push gratuito (em paralelo, se [enviarWhatsappSimultaneo] for
 * `true`, também tenta o WhatsApp imediato — ver
 * [enviarWhatsappSimultaneoParaContatos]) e registra
 * `entregas_alerta/{idEntrega}` com o prazo de transbordo de 60s para os
 * contatos que ainda precisarem dele. Retorna o id do documento criado
 * (ou `null` se não havia contatos de emergência para notificar).
 *
 * @param {{usuarioId: string, contatos: Array<Object>, mensagem: string, origem: string, enviarWhatsappSimultaneo?: boolean, fotoUrl?: string, latitude?: number, longitude?: number}} params
 * @return {Promise<string|null>}
 */
async function dispararAlertaHibrido({usuarioId, contatos, mensagem, origem, enviarWhatsappSimultaneo, fotoUrl, latitude, longitude}) {
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

  const [, telefonesJaEnviados] = await Promise.all([
    enviarFcmParaContatos(contatosResolvidos, TITULO_PUSH, mensagem, {
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
    }),
    enviarWhatsappSimultaneo ?
      enviarWhatsappSimultaneoParaContatos(usuarioId, contatosResolvidos, mensagem, idEntrega) :
      Promise.resolve(new Set()),
  ]);

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
      // `true` quando este contato já recebeu o WhatsApp de forma
      // IMEDIATA (ver [enviarWhatsappSimultaneoParaContatos] acima) — o
      // job de transbordo (`transbordoWhatsappMonitor.js`) pula qualquer
      // contato com esta flag, evitando cobrança/envio em duplicidade.
      whatsappJaEnviado: telefonesJaEnviados.has(c.telefone),
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
  enviarWhatsappSimultaneoParaContatos,
  dispararAlertaHibrido,
  COLECAO_ENTREGAS,
  STATUS_AGUARDANDO_TRANSBORDO,
};
