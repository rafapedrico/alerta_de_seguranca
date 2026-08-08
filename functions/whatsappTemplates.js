/**
 * Registro único dos Content SIDs de templates do WhatsApp Business
 * aprovados pela Meta/Twilio — a API oficial do WhatsApp só aceita
 * mensagens de negócio (business-initiated) FORA da janela de 24h de
 * conversa ativa através de um desses templates pré-aprovados; texto
 * livre (`body`) fora da janela falha com o erro Twilio 63016
 * ("outside messaging window"). DENTRO da janela de 24h — ex: a resposta
 * do bot de suporte a uma mensagem que o próprio usuário acabou de
 * mandar, ver `whatsappWebhook.js` — texto livre funciona normalmente e
 * NÃO precisa de template.
 *
 * Cada chave abaixo corresponde a um Content Template cadastrado e
 * aprovado no Twilio Content Template Builder
 * (console.twilio.com → Messaging → Content Template Builder). O
 * texto/variáveis do template só podem ser alterados por lá — o Content
 * SID aqui só IDENTIFICA o template já aprovado, o texto em si nunca é
 * montado por este backend nesse tipo de envio.
 *
 * Módulo isolado (em vez de constantes soltas em `smsGateway.js`) para
 * que qualquer novo template pré-aprovado (ou troca de um existente)
 * tenha um único lugar para ser mapeado, sem precisar mexer nos
 * chamadores.
 */

const TEMPLATES_WHATSAPP = {
  // "Alerta Guardião-X: {{1}}" — usado por `enviarSmsParaTelefones`
  // (`smsGateway.js`), chamado a partir de `dispararAlertaHibrido`
  // (`alertaHibridoService.js`) para todo alerta de emergência (SOS,
  // tentativa de desarme, alarme de rotina vencido). {{1}} recebe o
  // texto completo da mensagem de alerta já montada pelo chamador.
  ALERTA_EMERGENCIA: "HXccd14dd3758f94be24ab3ea1c162362b",

  // TODO: criar e aprovar no Content Template Builder, depois colar aqui
  // o Content SID real (formato "HXxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx").
  // Mensagem de boas-vindas/opt-in — pensada para abrir a janela de 24h
  // com um novo usuário ou um contato de emergência recém-cadastrado,
  // ANTES de ele escrever primeiro (ex: "Olá {{1}}! Você foi cadastrado
  // como contato de emergência de {{2}} no Guardião X. Responda esta
  // mensagem para ativar os alertas via WhatsApp.").
  BOAS_VINDAS: "",

  // TODO: template de reabertura do suporte — necessário porque, se o
  // usuário escrever para o número de suporte e a conversa ficar mais de
  // 24h sem nenhuma resposta nossa, não é mais possível responder em
  // texto livre (mesma regra dos alertas acima); só um template
  // aprovado pode reabrir essa janela. Sugestão de conteúdo: "Olá!
  // Recebemos sua mensagem no suporte do Guardião X — responda esta
  // mensagem para continuarmos o atendimento."
  SUPORTE_REABERTURA_JANELA: "",
};

module.exports = {TEMPLATES_WHATSAPP};
