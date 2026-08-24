/**
 * Constantes compartilhadas entre módulos das Cloud Functions.
 */

// Prazo, em milissegundos, para uma solicitação de monitoramento de
// localização (`permissoes_monitoramento`, status "pendente") ser
// respondida antes de expirar automaticamente — 24 horas (ver
// `monitoramentoService.js`/`monitoramentoExpiracaoMonitor.js`).
const JANELA_EXPIRACAO_MONITORAMENTO_MS = 24 * 60 * 60 * 1000;

// Chat de Suporte Interno com IA (ver `suporteChatService.js`) — decisão
// de arquitetura 2026-08-24 (substitui a Central de Atendimento via
// WhatsApp).
//
// Modelo: Sonnet 5, escolhido pelo usuário por custo-benefício frente ao
// Opus 5 para um caso de uso de suporte conversacional.
const SUPORTE_MODELO_IA = "claude-sonnet-5";

// Quantas mensagens ANTERIORES da conversa (já persistidas antes da que
// acabou de chegar) são enviadas como histórico pra IA — pedido
// explícito do usuário pra economizar tokens de entrada. A mensagem que
// disparou a function é sempre incluída à parte, além dessas 5.
const SUPORTE_HISTORICO_MAX_MENSAGENS = 5;

// Teto de tokens de SAÍDA por resposta da IA — pedido explícito do
// usuário; respostas de suporte devem ser curtas e diretas, nunca um
// ensaio. 400 é generoso o bastante pra uma resposta completa em
// qualquer um dos 11 idiomas suportados (alguns, como árabe/hindi, gastam
// mais tokens por caractere que o português).
const SUPORTE_MAX_TOKENS_RESPOSTA = 400;

// Marca especial que a IA deve colocar no INÍCIO da resposta quando
// julgar que o caso precisa de um atendente humano (pedido do usuário
// não souber resolver, ou o usuário pedir explicitamente por um humano
// em linguagem natural — o botão "Falar com atendente" da UI cobre o
// mesmo pedido de forma determinística, sem depender da IA reconhecer a
// intenção). Ver `suporteChatService.js` → `_extrairEscalonamento`.
const SUPORTE_MARCA_ESCALONAMENTO = "[[ESCALAR_ATENDENTE]]";

module.exports = {
  JANELA_EXPIRACAO_MONITORAMENTO_MS,
  SUPORTE_MODELO_IA,
  SUPORTE_HISTORICO_MAX_MENSAGENS,
  SUPORTE_MAX_TOKENS_RESPOSTA,
  SUPORTE_MARCA_ESCALONAMENTO,
};
