/**
 * Chat de Suporte Interno com IA (ver `suporteConhecimentoBase.js`) —
 * decisão de arquitetura 2026-08-24, substitui a Central de Atendimento
 * via WhatsApp (elimina custo de mensagem e integra o suporte dentro do
 * próprio app/site).
 *
 * FLUXO:
 * 1. App/site cria `suporte_tickets/{ticketId}` (status inicial
 *    "ia_ativa") e escreve a primeira pergunta em
 *    `suporte_tickets/{ticketId}/mensagens/{mensagemId}` com
 *    `autor: "usuario"`.
 * 2. `aoReceberMensagemSuporte` (abaixo) dispara nessa criação, monta o
 *    histórico (últimas `SUPORTE_HISTORICO_MAX_MENSAGENS`, ver
 *    `constantes.js` — pedido explícito do usuário pra economizar
 *    tokens de entrada) + a mensagem atual, chama o Claude com prompt
 *    caching na base de conhecimento (ver `suporteConhecimentoBase.js`)
 *    e grava a resposta como nova mensagem `autor: "ia"`.
 * 3. Handoff pra humano (pedido explícito do usuário, 2026-08-24):
 *    - Se a IA achar que não sabe resolver com segurança, ela mesma
 *      inicia a resposta com `SUPORTE_MARCA_ESCALONAMENTO` — o código
 *      detecta a marca, tira ela do texto exibido e muda o ticket pra
 *      "aguardando_humano".
 *    - Se o usuário clicar em "Falar com atendente" na UI, o app chama a
 *      callable `solicitarAtendenteHumano` (caminho determinístico, não
 *      depende da IA reconhecer a intenção em linguagem natural).
 *    - Nos dois casos, uma vez que o ticket sai de "ia_ativa" a própria
 *      trigger para de chamar a IA pra esse ticket (guarda logo no
 *      início da função) — é assim que a IA "para de responder", como
 *      pedido.
 *    - Um atendente humano (painel web administrativo — ver plano no
 *      histórico da conversa, ainda não implementado) responde via
 *      `responderComoAtendente`, que move o ticket pra
 *      "em_atendimento_humano" e grava `atendenteId`.
 *    - `encerrarTicketSuporte` fecha o ticket ("resolvido").
 *
 * Nenhuma dessas 3 callables abaixo é usada pelo usuário comum, exceto
 * `solicitarAtendenteHumano` — as outras duas exigem a custom claim
 * `admin: true` no token do Firebase Auth (setada manualmente via Admin
 * SDK/console pra cada atendente autorizado da RMF Global; não existe
 * fluxo de autopromoção a admin em lugar nenhum do app).
 */

const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const Anthropic = require("@anthropic-ai/sdk");

const {BASE_CONHECIMENTO} = require("./suporteConhecimentoBase");
const {
  SUPORTE_MODELO_IA,
  SUPORTE_HISTORICO_MAX_MENSAGENS,
  SUPORTE_MAX_TOKENS_RESPOSTA,
  SUPORTE_MARCA_ESCALONAMENTO,
} = require("./constantes");

const db = getFirestore();

// Secret do Firebase Functions v2 (`firebase functions:secrets:set
// ANTHROPIC_API_KEY`) — NUNCA hardcoded nem em variável de ambiente
// comum. Precisa ser declarado em `secrets: [anthropicApiKey]` em toda
// função abaixo que chama a API da Anthropic.
const anthropicApiKey = defineSecret("ANTHROPIC_API_KEY");

// Mensagem de fallback (curta, poucos idiomas) pro raro caso da própria
// chamada à IA falhar (rede, rate limit, etc.) — fica só num punhado de
// idiomas porque é caminho de erro, não a resposta normal da IA (essa
// sim responde em qualquer um dos 11 via `_instrucoesResposta`).
const TEXTOS_ERRO_IA = {
  pt: "Estamos com uma instabilidade momentânea no suporte automático. Tente novamente em alguns instantes, ou toque em \"Falar com atendente\".",
  en: "Automated support is temporarily unavailable. Please try again in a moment, or tap \"Talk to a human\".",
  es: "El soporte automático está temporalmente inestable. Intenta de nuevo en unos instantes, o toca \"Hablar con un agente\".",
};

/**
 * @param {string} idioma
 * @return {string}
 */
function _textoErroIA(idioma) {
  return TEXTOS_ERRO_IA[idioma] || TEXTOS_ERRO_IA.pt;
}

/**
 * Instruções de resposta — bloco PEQUENO e variável por idioma, mantido
 * FORA do bloco com `cache_control` (ver `_montarSystemBlocks`) pra não
 * fragmentar o cache da base de conhecimento entre os 11 idiomas.
 * @param {string} idioma
 * @return {string}
 */
function _instrucoesResposta(idioma) {
  return `# Instruções de resposta
- Responda SEMPRE no idioma de código ISO 639-1 "${idioma}", mesmo que o usuário escreva em outro idioma ou que a base de conhecimento acima esteja em português. Nunca mencione que está traduzindo.
- Respostas curtas e diretas — é um chat de suporte, não um artigo.
- Se o usuário descrever uma emergência acontecendo AGORA, oriente a usar o botão de SOS do app imediatamente. O chat de suporte não é um canal de emergência e não deve tentar geri-la.
- Se você não tiver certeza de como resolver com segurança, ou o usuário pedir explicitamente para falar com uma pessoa/atendente humano, comece a resposta EXATAMENTE com a marca "${SUPORTE_MARCA_ESCALONAMENTO}" (sem nada antes, nem espaço) seguida de uma frase curta avisando que vai encaminhar para um atendente humano. Use isso só quando necessário — não abuse do encaminhamento para perguntas que você sabe responder.`;
}

/**
 * Monta o array `system` da Messages API: bloco 1 = base de conhecimento
 * ESTÁTICA (idêntica pra qualquer usuário/idioma) com `cache_control`,
 * bloco 2 = instruções pequenas e variáveis por idioma, sem cache — é
 * assim que o mesmo cache da base de conhecimento é reaproveitado entre
 * TODOS os idiomas em vez de um cache por idioma.
 * @param {string} idioma
 */
function _montarSystemBlocks(idioma) {
  return [
    {
      type: "text",
      text: BASE_CONHECIMENTO,
      cache_control: {type: "ephemeral"},
    },
    {
      type: "text",
      text: _instrucoesResposta(idioma),
    },
  ];
}

exports.aoReceberMensagemSuporte = onDocumentCreated(
    {
      document: "suporte_tickets/{ticketId}/mensagens/{mensagemId}",
      secrets: [anthropicApiKey],
    },
    async (event) => {
      const snap = event.data;
      if (!snap) {
        logger.warn("[Suporte] Evento sem dados (snap ausente) — ignorado.");
        return;
      }
      const mensagem = snap.data();
      const {ticketId, mensagemId} = event.params;

      // Só reage à PERGUNTA do usuário — nunca à própria resposta da IA
      // nem a uma mensagem de atendente/sistema (evita loop).
      if (mensagem.autor !== "usuario") return;

      const ticketRef = db.collection("suporte_tickets").doc(ticketId);
      const ticketSnap = await ticketRef.get();
      if (!ticketSnap.exists) {
        logger.warn(`[Suporte] Ticket ${ticketId} não encontrado — ignorado.`);
        return;
      }
      const ticket = ticketSnap.data();

      // Guarda do handoff: ticket escalado, em atendimento humano ou
      // resolvido — a IA PARA de responder esse ticket (pedido explícito
      // do usuário).
      if (ticket.status !== "ia_ativa") {
        logger.info(
            `[Suporte] Ticket ${ticketId} está em status "${ticket.status}" ` +
            "— IA não responde.");
        return;
      }

      const mensagensRef = ticketRef.collection("mensagens");

      // Histórico: últimas SUPORTE_HISTORICO_MAX_MENSAGENS mensagens
      // ANTERIORES à atual (economia de tokens de entrada, pedido
      // explícito do usuário) — busca uma a mais e filtra a própria
      // mensagem que disparou a function pelo id do documento (mais
      // confiável que comparar Timestamp).
      const historicoSnap = await mensagensRef
          .orderBy("criadoEm", "desc")
          .limit(SUPORTE_HISTORICO_MAX_MENSAGENS + 1)
          .get();

      const historico = historicoSnap.docs
          .filter((d) => d.id !== mensagemId)
          .slice(0, SUPORTE_HISTORICO_MAX_MENSAGENS)
          .map((d) => d.data())
          .reverse(); // mais antiga -> mais nova, ordem que a API espera

      const messages = historico
          .map((m) => ({
            role: m.autor === "usuario" ? "user" : "assistant",
            content: m.texto,
          }))
          .concat([{role: "user", content: mensagem.texto}]);

      const idioma = ticket.idioma || "pt";
      const client = new Anthropic({apiKey: anthropicApiKey.value()});

      let respostaBruta;
      try {
        const response = await client.messages.create({
          model: SUPORTE_MODELO_IA,
          max_tokens: SUPORTE_MAX_TOKENS_RESPOSTA,
          system: _montarSystemBlocks(idioma),
          messages,
        });

        logger.info(
            `[Suporte] Ticket ${ticketId} — cache_read=` +
            `${response.usage.cache_read_input_tokens} cache_write=` +
            `${response.usage.cache_creation_input_tokens} input=` +
            `${response.usage.input_tokens} output=` +
            `${response.usage.output_tokens}`);

        const textBlock = response.content.find((b) => b.type === "text");
        respostaBruta = textBlock ? textBlock.text : "";
      } catch (e) {
        if (e instanceof Anthropic.RateLimitError) {
          logger.warn(`[Suporte] Rate limit da IA no ticket ${ticketId}: ${e}`);
        } else {
          logger.error(`[Suporte] Falha ao chamar a IA no ticket ${ticketId}: ${e}`);
        }
        // Mantém o ticket em "ia_ativa" — o usuário pode tentar de novo
        // (nova mensagem) ou pedir atendente manualmente.
        await mensagensRef.add({
          autor: "sistema",
          texto: _textoErroIA(idioma),
          criadoEm: Timestamp.now(),
        });
        return;
      }

      if (!respostaBruta.trim()) {
        logger.warn(`[Suporte] Resposta vazia da IA no ticket ${ticketId}.`);
        return;
      }

      const escalar = respostaBruta.trimStart().startsWith(SUPORTE_MARCA_ESCALONAMENTO);
      const textoFinal = escalar ?
        respostaBruta.trimStart().slice(SUPORTE_MARCA_ESCALONAMENTO.length).trim() :
        respostaBruta.trim();

      await mensagensRef.add({
        autor: "ia",
        texto: textoFinal,
        criadoEm: Timestamp.now(),
      });

      await ticketRef.update({
        status: escalar ? "aguardando_humano" : "ia_ativa",
        atualizadoEm: Timestamp.now(),
        ultimaMensagemPreview: textoFinal.slice(0, 140),
      });

      if (escalar) {
        logger.info(`[Suporte] Ticket ${ticketId} escalado pela própria IA.`);
      }
    },
);

/**
 * Callable chamada pelo botão "Falar com atendente" da UI — caminho
 * DETERMINÍSTICO de escalonamento (não depende da IA reconhecer a
 * intenção em linguagem natural, ver cabeçalho do arquivo).
 */
exports.solicitarAtendenteHumano = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Login necessário.");
  }
  const {ticketId} = request.data || {};
  if (!ticketId || typeof ticketId !== "string") {
    throw new HttpsError("invalid-argument", "ticketId é obrigatório.");
  }

  const ticketRef = db.collection("suporte_tickets").doc(ticketId);
  const ticketSnap = await ticketRef.get();
  if (!ticketSnap.exists) {
    throw new HttpsError("not-found", "Ticket não encontrado.");
  }
  const ticket = ticketSnap.data();
  if (ticket.uid !== request.auth.uid) {
    throw new HttpsError("permission-denied", "Este ticket não pertence a você.");
  }
  if (ticket.status === "resolvido") {
    throw new HttpsError("failed-precondition", "Este ticket já foi encerrado.");
  }

  await ticketRef.update({
    status: "aguardando_humano",
    atualizadoEm: Timestamp.now(),
  });
  logger.info(`[Suporte] Ticket ${ticketId} escalado manualmente pelo usuário.`);
  return {ok: true};
});

/**
 * Callable usada pelo futuro Painel de Atendimento (Admin) — exige a
 * custom claim `admin: true`. Grava a resposta do atendente e move o
 * ticket pra "em_atendimento_humano".
 */
exports.responderComoAtendente = onCall(async (request) => {
  if (!request.auth || request.auth.token.admin !== true) {
    throw new HttpsError("permission-denied", "Apenas atendentes autorizados.");
  }
  const {ticketId, texto} = request.data || {};
  if (!ticketId || typeof texto !== "string" || !texto.trim()) {
    throw new HttpsError("invalid-argument", "ticketId e texto são obrigatórios.");
  }

  const ticketRef = db.collection("suporte_tickets").doc(ticketId);
  const ticketSnap = await ticketRef.get();
  if (!ticketSnap.exists) {
    throw new HttpsError("not-found", "Ticket não encontrado.");
  }
  if (ticketSnap.data().status === "resolvido") {
    throw new HttpsError("failed-precondition", "Este ticket já foi encerrado.");
  }

  const textoFinal = texto.trim();
  await ticketRef.collection("mensagens").add({
    autor: "atendente",
    texto: textoFinal,
    criadoEm: Timestamp.now(),
  });
  await ticketRef.update({
    status: "em_atendimento_humano",
    atendenteId: request.auth.uid,
    atualizadoEm: Timestamp.now(),
    ultimaMensagemPreview: textoFinal.slice(0, 140),
  });

  return {ok: true};
});

/**
 * Callable usada pelo futuro Painel de Atendimento (Admin) pra encerrar
 * um ticket — exige a custom claim `admin: true`.
 */
exports.encerrarTicketSuporte = onCall(async (request) => {
  if (!request.auth || request.auth.token.admin !== true) {
    throw new HttpsError("permission-denied", "Apenas atendentes autorizados.");
  }
  const {ticketId} = request.data || {};
  if (!ticketId || typeof ticketId !== "string") {
    throw new HttpsError("invalid-argument", "ticketId é obrigatório.");
  }

  await db.collection("suporte_tickets").doc(ticketId).update({
    status: "resolvido",
    atualizadoEm: Timestamp.now(),
  });
  return {ok: true};
});
