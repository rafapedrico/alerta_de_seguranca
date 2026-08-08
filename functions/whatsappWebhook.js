/**
 * Webhook de mensagens INBOUND do WhatsApp de suporte (Twilio) — ponto de
 * entrada do atendimento automático via IA. Configurar no Console da
 * Twilio (Messaging → Senders → [seu remetente WhatsApp] → "When a
 * message comes in") com a URL pública desta função, método HTTP POST,
 * formato "Webhook".
 *
 * FLUXO:
 * 1. Valida a assinatura da requisição (`X-Twilio-Signature`) contra
 *    `TWILIO_AUTH_TOKEN` — recusa (403) qualquer POST que não tenha
 *    partido de verdade da Twilio, ANTES de tocar em Firestore ou gastar
 *    uma chamada de IA. Ver [montarUrlPublica] para o porquê de montar a
 *    URL manualmente em vez de confiar em `req.protocol`.
 * 2. Normaliza o telefone (`normalizarTelefoneE164`, mesma função usada
 *    pelo pipeline de alertas em `smsGateway.js`, para nunca ter duas
 *    representações do mesmo número) e resolve se corresponde a uma
 *    conta cadastrada em `usuarios` — só para personalizar o
 *    atendimento; nunca é exigido ter conta para falar com o suporte.
 * 3. Carrega o histórico recente da conversa
 *    (`suporte_whatsapp/{telefone}/mensagens`, últimas
 *    [LIMITE_HISTORICO_CONTEXTO]) e grava a mensagem recebida.
 * 4. Chama `gerarRespostaSuporte` (ver `whatsappSuporteIA.js`) com esse
 *    contexto.
 * 5. Responde por TwiML (`<Message>`) — texto livre funciona aqui porque
 *    esta é, por definição, uma resposta DENTRO da janela de 24h (é uma
 *    reação a uma mensagem que o próprio usuário acabou de mandar); só o
 *    envio ATIVO (fora da janela, iniciado pelo negócio) exige um
 *    template pré-aprovado — ver `whatsappTemplates.js`.
 * 6. Se a IA não gerar resposta (secret ausente ou erro na chamada), cai
 *    no texto de fallback fixo — nunca deixa o usuário sem nenhuma
 *    resposta.
 *
 * Em paralelo, se a mensagem tiver indício de emergência real (ver
 * `pareceEmergenciaReal`), marca a conversa com `precisaAtencaoHumana:
 * true` para uma futura tela/alerta interno da equipe revisar — este
 * webhook, sozinho, não substitui o pipeline real de SOS
 * (`aoReceberAlertaTentativaDesarme`/`SosDisparoService` no app).
 */

const {onRequest} = require("firebase-functions/v2/https");
const {getFirestore, FieldValue, Timestamp} = require("firebase-admin/firestore");
const twilio = require("twilio");
const logger = require("firebase-functions/logger");
const {normalizarTelefoneE164, twilioAuthToken} = require("./smsGateway");
const {gerarRespostaSuporte, pareceEmergenciaReal, SUPORTE_SECRETS} = require("./whatsappSuporteIA");

const db = getFirestore();

const COLECAO_CONVERSAS = "suporte_whatsapp";
const SUBCOLECAO_MENSAGENS = "mensagens";
// Quantas mensagens anteriores (usuário + assistente, intercaladas) são
// enviadas como contexto de continuidade a cada chamada de IA — limite
// para manter latência/custo baixos numa conversa de suporte, que raro
// precisa de memória muito longa.
const LIMITE_HISTORICO_CONTEXTO = 10;
const JANELA_24H_MS = 24 * 60 * 60 * 1000;

const MENSAGEM_FALLBACK =
    "Recebemos sua mensagem! No momento não conseguimos gerar uma resposta " +
    "automática — nossa equipe vai continuar o atendimento por aqui em breve.";

/**
 * Monta a URL EXATA (protocolo + host + path original) usada pela Twilio
 * para assinar a requisição — precisa bater com a URL cadastrada no
 * Console, incluindo o `https`. O Cloud Functions v2/Cloud Run fica atrás
 * de um proxy que já entrega TLS terminado (a requisição real chega em
 * HTTP internamente), então `req.protocol` sozinho não é confiável sem
 * configurar `trust proxy` no Express interno — mais simples e explícito
 * fixar `https` aqui, já que Functions v2 nunca serve tráfego HTTP puro.
 *
 * @param {import("express").Request} req
 * @return {string}
 */
function montarUrlPublica(req) {
  const host = req.get("host");
  return `https://${host}${req.originalUrl}`;
}

/**
 * @param {string} texto
 * @return {string} XML TwiML pronto para a resposta HTTP do webhook.
 */
function construirTwiml(texto) {
  const {MessagingResponse} = twilio.twiml;
  const resposta = new MessagingResponse();
  if (texto) resposta.message(texto);
  return resposta.toString();
}

/**
 * @param {FirebaseFirestore.QuerySnapshot} snap Resultado ordenado do
 *     mais recente para o mais antigo (`orderBy("criadoEm", "desc")`).
 * @return {Array<{papel: string, texto: string}>} Mesmas mensagens, na
 *     ordem cronológica (mais antiga primeiro) exigida pela API de
 *     mensagens da IA.
 */
function mapearHistorico(snap) {
  return snap.docs
      .map((doc) => doc.data())
      .reverse()
      .map((m) => ({papel: m.papel, texto: m.texto}));
}

exports.whatsappWebhook = onRequest(
    {
      // Só precisa do auth token (validação de assinatura) — não do
      // account SID nem do from number, que só o ENVIO ativo usa (ver
      // `smsGateway.js`); manter os secrets injetados no mínimo
      // necessário para esta função.
      secrets: [twilioAuthToken, ...SUPORTE_SECRETS],
      // A chamada à IA pode levar alguns segundos — a Twilio espera até
      // 15s pela resposta do webhook antes de desistir e considerar a
      // entrega falha; folga para nunca cortar a chamada no meio.
      timeoutSeconds: 30,
    },
    async (req, res) => {
      if (req.method !== "POST") {
        res.status(405).send("Method Not Allowed");
        return;
      }

      const assinatura = req.get("X-Twilio-Signature") || "";
      const urlPublica = montarUrlPublica(req);
      const assinaturaValida = twilio.validateRequest(
          twilioAuthToken.value(), assinatura, urlPublica, req.body || {},
      );

      if (!assinaturaValida) {
        logger.warn(
            `[whatsappWebhook] Assinatura Twilio inválida para ${urlPublica} ` +
            "— requisição recusada (possível remetente forjado).",
        );
        res.status(403).send("Assinatura inválida");
        return;
      }

      const corpo = req.body || {};
      // Formato "whatsapp:+5511999999999" — remove o prefixo antes de
      // normalizar, senão o parser de telefone tenta interpretá-lo como
      // parte do número.
      const telefoneOriginal = String(corpo.From || "").replace(/^whatsapp:/, "");
      const textoRecebido = String(corpo.Body || "").trim();
      const messageSid = corpo.MessageSid || "";

      const telefone = normalizarTelefoneE164(telefoneOriginal) || telefoneOriginal;
      if (!telefone || !textoRecebido) {
        logger.warn(
            "[whatsappWebhook] Requisição sem From/Body válidos — ignorada " +
            `(From: ${corpo.From || "-"}).`,
        );
        res.status(200).set("Content-Type", "text/xml").send(construirTwiml(""));
        return;
      }

      const conversaRef = db.collection(COLECAO_CONVERSAS).doc(telefone);
      const mensagensRef = conversaRef.collection(SUBCOLECAO_MENSAGENS);

      // Resolve se o telefone corresponde a uma conta cadastrada — só
      // para personalizar o prompt de sistema da IA (nome, saldo); uma
      // falha aqui nunca deve impedir o atendimento, só o deixa genérico.
      let contextoUsuario = {temConta: false};
      try {
        const usuarioSnap = await db.collection("usuarios")
            .where("telefone", "==", telefone)
            .limit(1)
            .get();
        if (!usuarioSnap.empty) {
          const dados = usuarioSnap.docs[0].data();
          contextoUsuario = {
            temConta: true,
            nome: dados.nome || "",
            creditosDisponiveis: dados.creditosDisponiveis,
          };
        }
      } catch (e) {
        logger.error(`[whatsappWebhook] Falha ao resolver conta para ${telefone}`, e);
      }

      let historico = [];
      try {
        const historicoSnap = await mensagensRef
            .orderBy("criadoEm", "desc")
            .limit(LIMITE_HISTORICO_CONTEXTO)
            .get();
        historico = mapearHistorico(historicoSnap);
      } catch (e) {
        logger.error(`[whatsappWebhook] Falha ao carregar histórico de ${telefone}`, e);
      }

      await mensagensRef.add({
        papel: "usuario",
        texto: textoRecebido,
        messageSid,
        criadoEm: Timestamp.now(),
      });

      const emergenciaReal = pareceEmergenciaReal(textoRecebido);

      let respostaTexto = await gerarRespostaSuporte(contextoUsuario, historico, textoRecebido);
      if (!respostaTexto) {
        respostaTexto = MENSAGEM_FALLBACK;
      }

      await mensagensRef.add({
        papel: "assistente",
        texto: respostaTexto,
        criadoEm: Timestamp.now(),
      });

      await conversaRef.set({
        telefone,
        ultimaMensagemEm: Timestamp.now(),
        // Marca até quando dá para responder em texto livre a partir
        // desta mensagem — usada por um eventual envio proativo futuro
        // (ex: acompanhamento do suporte) para decidir se ainda pode
        // usar texto livre ou já precisa de um template pré-aprovado
        // (ver `whatsappTemplates.js`, `SUPORTE_REABERTURA_JANELA`).
        janela24hAbertaAte: Timestamp.fromMillis(Date.now() + JANELA_24H_MS),
        ...(contextoUsuario.temConta ? {usuarioVinculado: true} : {}),
        ...(emergenciaReal ? {
          precisaAtencaoHumana: true,
          motivoAtencaoHumana: FieldValue.arrayUnion(
              `Indício de emergência real em ${new Date().toISOString()}: "${textoRecebido}"`,
          ),
        } : {}),
      }, {merge: true});

      if (emergenciaReal) {
        logger.warn(
            `[whatsappWebhook] Mensagem de ${telefone} contém indício de ` +
            "emergência real — conversa marcada para atenção humana.",
        );
      }

      res.status(200)
          .set("Content-Type", "text/xml")
          .send(construirTwiml(respostaTexto));
    },
);
