/**
 * Motor de atendimento automático via IA do WhatsApp de suporte do
 * Guardião X — usado por `whatsappWebhook.js` (inbound de mensagens dos
 * usuários) para gerar a resposta de texto livre dentro da janela de 24h
 * de conversa ativa.
 *
 * Chama a Claude Messages API (Anthropic) diretamente via `fetch`
 * (nativo do runtime Node 20 das Cloud Functions, sem precisar do SDK
 * `@anthropic-ai/sdk` como dependência só para este único uso).
 * Credencial via Secret Manager:
 *
 *   firebase functions:secrets:set ANTHROPIC_API_KEY
 *
 * Sem o secret configurado, degrada graciosamente: loga um aviso e
 * devolve `null` — o chamador decide o fallback (ver `whatsappWebhook.js`)
 * — igual ao padrão já usado em `smsGateway.js` para credenciais Twilio
 * ausentes. Nunca lança exceção.
 */

const {defineSecret} = require("firebase-functions/params");
const logger = require("firebase-functions/logger");

const anthropicApiKey = defineSecret("ANTHROPIC_API_KEY");

// Lista pronta para ser espalhada em `secrets: [...SUPORTE_SECRETS]` nas
// opções de qualquer função que chame [gerarRespostaSuporte].
const SUPORTE_SECRETS = [anthropicApiKey];

const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_API_VERSION = "2023-06-01";
// Haiku: latência baixa é crítica aqui — a resposta precisa voltar ANTES
// do timeout do webhook da Twilio (ver `timeoutSeconds` em
// `whatsappWebhook.js`), então prioriza velocidade sobre profundidade de
// raciocínio para este caso de uso (FAQ/suporte de primeiro nível).
const MODELO_SUPORTE = "claude-haiku-4-5-20251001";
const MAX_TOKENS_RESPOSTA = 500;

/**
 * Palavras-chave (best-effort, case-insensitive) que indicam uma
 * emergência REAL acontecendo agora — quando presentes na mensagem,
 * `whatsappWebhook.js` marca a conversa para revisão humana
 * (`precisaAtencaoHumana: true`) além de responder normalmente. Isto é
 * uma REDE DE SEGURANÇA ADICIONAL: a instrução #4 do prompt de sistema
 * (ver [montarPromptSistema]) já pede à própria IA que reconheça e
 * responda a esses casos primeiro — este filtro não depende da IA ter
 * acertado.
 *
 * @type {Array<string>}
 */
const PALAVRAS_CHAVE_EMERGENCIA = [
  "socorro", "help me", "me ajuda", "preciso de ajuda urgente",
  "estou em perigo", "sendo seguid", "sendo atacad", "assalto",
  "sequestr", "emergência real", "emergencia real", "chama a policia",
  "chama a polícia", "call the police", "i'm in danger", "im in danger",
];

/**
 * @param {string} texto
 * @return {boolean}
 */
function pareceEmergenciaReal(texto) {
  const normalizado = (texto || "").toLowerCase();
  return PALAVRAS_CHAVE_EMERGENCIA.some((chave) => normalizado.includes(chave));
}

/**
 * Monta o prompt de sistema do assistente de suporte: identidade, regras
 * de negócio, limites de escopo e FAQ do Guardião X. Devolvido como texto
 * único (não fragmentado por idioma) porque a própria instrução #1 pede
 * à IA que responda no MESMO idioma da mensagem do usuário — não depende
 * do pipeline de i18n do app (ver memória `i18n_headless_pattern`, que
 * cobre apenas textos ESTÁTICOS gerados pelo backend, não conversas).
 *
 * @param {{nome?: string, temConta: boolean, creditosDisponiveis?: number}} contextoUsuario
 * @return {string}
 */
function montarPromptSistema(contextoUsuario) {
  const identificacao = contextoUsuario.temConta ?
    `Você está falando com ${contextoUsuario.nome || "um usuário"} cadastrado ` +
      "no Guardião X, com saldo atual de " +
      `${typeof contextoUsuario.creditosDisponiveis === "number" ?
        contextoUsuario.creditosDisponiveis : "desconhecido"} créditos na Carteira.` :
    "Este telefone não corresponde a nenhuma conta cadastrada no Guardião X " +
      "(pode ser um contato de emergência de alguém, um usuário novo ainda " +
      "sem conta, ou só um número errado).";

  return `Você é o assistente de suporte oficial do Guardião X, um app de segurança
pessoal (SOS de emergência, monitoramento de localização entre
familiares/guardiões com aprovação bilateral, alarme de rotina "dead man's
switch", e uma Carteira de créditos para o WhatsApp de contingência). Você
atende pelo número oficial de suporte no WhatsApp.

${identificacao}

REGRAS:
1. Responda SEMPRE no mesmo idioma em que o usuário escreveu — a base de
   usuários é global (português, inglês, espanhol e outros); nunca assuma
   português por padrão.
2. Seja objetivo, empático e use frases curtas — isto é uma conversa de
   WhatsApp, não um e-mail formal.
3. Você NÃO pode, e nunca deve fingir que pode: alterar dados de conta,
   cancelar cobranças, reembolsar créditos, nem acessar localização,
   histórico ou qualquer dado de ninguém. Para esses casos, oriente o
   usuário a usar a aba correspondente dentro do próprio app, ou avise que
   um humano da equipe vai continuar o atendimento.
4. Se o usuário relatar uma EMERGÊNCIA REAL acontecendo agora (perigo
   físico imediato, estar sendo seguido/atacado, precisar de socorro),
   NÃO tente resolver só por texto: primeiro oriente-o a apertar o botão
   físico (Volume+ 3x) ou o botão de SOS manual na aba Segurança do app, e
   avise para ligar também para a emergência local (ex.: 190/191 no
   Brasil, 911 nos EUA) sempre que possível — só depois disso continue o
   suporte normal.
5. FAQ (dúvidas mais comuns):
   - "Como funciona o SOS?": botão físico (Volume+ 3x) ou manual na aba
     Segurança dispara localização + foto para os contatos de emergência,
     via notificação push (grátis, se o contato tiver o app) e, se
     configurado, WhatsApp de contingência.
   - "O que é a Carteira/créditos?": cada envio de WhatsApp de
     contingência (quando o contato de emergência não tem o app
     instalado) custa 1 crédito; créditos são comprados dentro do app.
   - "Como funciona o Alarme de Rotina?": o usuário agenda um check-in;
     se não confirmar com o PIN a tempo, o app dispara alerta automático
     aos contatos de emergência, com localização.
   - "Como funciona o Monitoramento?": compartilhamento de localização em
     tempo real entre familiares/guardiões, sempre com aprovação
     explícita e bilateral do outro lado — nenhum dos dois vê a
     localização do outro sem consentimento ativo.
6. Se não souber responder algo com confiança, diga isso claramente e
   informe que um humano da equipe vai continuar o atendimento — nunca
   invente política, preço ou comportamento do app que você não tem
   certeza que existe.
7. Nunca peça (nem aceite sem alertar) senha, PIN do app, código de
   verificação ou dado de cartão pelo WhatsApp — o suporte oficial NUNCA
   pede isso; se o usuário mandar algo assim, avise-o do risco e ignore o
   dado recebido.

Responda apenas com o texto puro da mensagem a enviar ao usuário — sem
markdown pesado (o WhatsApp só renderiza *negrito*, _itálico_ e
~tachado~), sem preâmbulo do tipo "Claro, aqui está", sem assinatura.`;
}

/**
 * Gera a resposta de suporte para [mensagemUsuario], usando [historico]
 * (mensagens anteriores da mesma conversa, da mais antiga para a mais
 * recente) como contexto de continuidade. Retorna `null` (nunca lança
 * exceção) se o secret não estiver configurado ou se a chamada à API
 * falhar por qualquer motivo — o chamador decide o texto de fallback.
 *
 * @param {{nome?: string, temConta: boolean, creditosDisponiveis?: number}} contextoUsuario
 * @param {Array<{papel: "usuario"|"assistente", texto: string}>} historico
 * @param {string} mensagemUsuario
 * @return {Promise<string|null>}
 */
async function gerarRespostaSuporte(contextoUsuario, historico, mensagemUsuario) {
  const apiKey = anthropicApiKey.value();
  if (!apiKey) {
    logger.warn(
        "[gerarRespostaSuporte] ANTHROPIC_API_KEY ausente no Secret Manager " +
        "- resposta de IA não gerada. Configure com " +
        "'firebase functions:secrets:set ANTHROPIC_API_KEY'.",
    );
    return null;
  }

  const mensagens = [
    ...(historico || []).map((m) => ({
      role: m.papel === "assistente" ? "assistant" : "user",
      content: m.texto,
    })),
    {role: "user", content: mensagemUsuario},
  ];

  try {
    const resposta = await fetch(ANTHROPIC_API_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_API_VERSION,
      },
      body: JSON.stringify({
        model: MODELO_SUPORTE,
        max_tokens: MAX_TOKENS_RESPOSTA,
        system: montarPromptSistema(contextoUsuario),
        messages: mensagens,
      }),
    });

    if (!resposta.ok) {
      const corpoErro = await resposta.text();
      logger.error(
          `[gerarRespostaSuporte] Anthropic API respondeu ${resposta.status}: ${corpoErro}`,
      );
      return null;
    }

    const dados = await resposta.json();
    const texto = (dados.content || [])
        .filter((bloco) => bloco.type === "text")
        .map((bloco) => bloco.text)
        .join("\n")
        .trim();

    return texto || null;
  } catch (e) {
    logger.error("[gerarRespostaSuporte] Falha ao chamar a Anthropic API", e);
    return null;
  }
}

module.exports = {
  gerarRespostaSuporte,
  pareceEmergenciaReal,
  montarPromptSistema,
  SUPORTE_SECRETS,
};
