/**
 * Backend da aba Monitoramento: permissão bilateral e explícita de
 * compartilhamento de localização GPS em tempo real entre usuários do
 * Guardião X, TOTALMENTE independente do pipeline de alerta de emergência
 * (`alertaHibridoService.js`) — aqui não há disparo de SMS/sirene, apenas
 * consentimento e leitura de posição.
 *
 * Modelo de dados (coleção `permissoes_monitoramento/{permissaoId}`, ver
 * `MonitoramentoService` no app Flutter):
 *   permissaoId: string, determinístico = `${uidAlvo}__${uidSolicitante}`
 *   uidAlvo: string (uid de quem COMPARTILHA a localização)
 *   uidSolicitante: string (uid de quem VÊ a localização)
 *   telefoneAlvo, telefoneSolicitante: string (E.164)
 *   nomeAlvo, nomeSolicitante: string (denormalizado)
 *   status: "pendente" | "aprovado" | "negado" | "bloqueado" | "expirado"
 *   criadoEm, atualizadoEm, respondidoEm: Timestamp
 *   expiraEm: Timestamp (só relevante em "pendente" — ver
 *     `monitoramentoExpiracaoMonitor.js`, regra das 24h)
 *
 * Cada PAR de usuários pode ter até DOIS documentos independentes — um
 * para cada direção de "quem vê a localização de quem" — cada um com seu
 * próprio ciclo de vida. O cliente NUNCA cria este documento diretamente
 * (ver `firestore.rules`): só esta Cloud Function callable cria/reabre uma
 * solicitação; o cliente só pode ATUALIZAR o status, e só quando for o
 * `uidAlvo` do documento (aprovar/negar/bloquear/desbloquear).
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");
const {normalizarTelefoneE164} = require("./smsGateway");
const {JANELA_EXPIRACAO_MONITORAMENTO_MS} = require("./constantes");

const db = getFirestore();

const COLECAO_PERMISSOES = "permissoes_monitoramento";
const STATUS_PENDENTE = "pendente";
const STATUS_APROVADO = "aprovado";
const STATUS_NEGADO = "negado";
const STATUS_BLOQUEADO = "bloqueado";
const STATUS_EXPIRADO = "expirado";

/**
 * @param {string} uidAlvo
 * @param {string} uidSolicitante
 * @return {string}
 */
function montarIdPermissao(uidAlvo, uidSolicitante) {
  return `${uidAlvo}__${uidSolicitante}`;
}

/**
 * Envia um Push data-only (mesmo padrão de `enviarFcmParaContatos` em
 * `alertaHibridoService.js`) para um único usuário, buscando seu
 * `fcmToken` em `usuarios/{uidDestino}`. Best-effort: nunca lança
 * exceção — a ausência de token/falha de envio não deve interromper o
 * fluxo de permissão, que já está persistido no Firestore.
 *
 * @param {string} uidDestino
 * @param {string} tipo
 * @param {Object<string, string>} dadosExtras
 */
async function enviarFcmMonitoramento(uidDestino, tipo, dadosExtras) {
  try {
    const snap = await db.collection("usuarios").doc(uidDestino).get();
    const fcmToken = snap.exists && snap.data().fcmToken;
    if (!fcmToken) {
      logger.info(
          `[enviarFcmMonitoramento] Usuário ${uidDestino} sem fcmToken — ` +
          `Push "${tipo}" não enviado.`,
      );
      return;
    }

    await getMessaging().send({
      token: fcmToken,
      data: {tipo, ...dadosExtras},
      android: {priority: "high"},
    });
    logger.info(`[enviarFcmMonitoramento] Push "${tipo}" enviado para ${uidDestino}.`);
  } catch (e) {
    logger.error(
        `[enviarFcmMonitoramento] Falha ao enviar Push "${tipo}" para ${uidDestino}`, e,
    );
  }
}

/**
 * Callable `onCall` chamada pelo app (ver
 * `lib/services/monitoramento_service.dart`, `solicitarLocalizacao`) ao
 * tocar em "Solicitar Localização" para um contato da aba Monitoramento.
 * Resolve o uid pelo telefone SERVER-SIDE (o cliente nunca consulta
 * `usuarios` por telefone diretamente — ver `firestore.rules`).
 *
 * data: {telefoneAlvo: string}
 * return: {sucesso: true, uidAlvo: string, status: string, permissaoId: string}
 */
exports.solicitarMonitoramento = onCall(async (request) => {
  const uidSolicitante = request.auth && request.auth.uid;
  if (!uidSolicitante) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }

  const {telefoneAlvo} = request.data || {};
  const telefoneNormalizado = normalizarTelefoneE164(telefoneAlvo);
  if (!telefoneNormalizado) {
    throw new HttpsError("invalid-argument", "Telefone inválido.");
  }

  const solicitanteSnap = await db.collection("usuarios").doc(uidSolicitante).get();
  const solicitante = solicitanteSnap.exists ? solicitanteSnap.data() : {};

  const alvoQuery = await db.collection("usuarios")
      .where("telefone", "==", telefoneNormalizado)
      .limit(1)
      .get();
  if (alvoQuery.empty) {
    throw new HttpsError(
        "not-found", "Este número ainda não possui conta no Guardião X.",
    );
  }

  const alvoDoc = alvoQuery.docs[0];
  const uidAlvo = alvoDoc.id;
  const alvo = alvoDoc.data();

  if (uidAlvo === uidSolicitante) {
    throw new HttpsError(
        "invalid-argument", "Não é possível solicitar a própria localização.",
    );
  }

  const permissaoId = montarIdPermissao(uidAlvo, uidSolicitante);
  const permissaoRef = db.collection(COLECAO_PERMISSOES).doc(permissaoId);

  const statusResultante = await db.runTransaction(async (tx) => {
    const snapAtual = await tx.get(permissaoRef);
    const dadosAtuais = snapAtual.exists ? snapAtual.data() : null;

    // Já aprovado: nada a fazer, devolve o status atual sem reabrir o
    // ciclo nem reenviar Push.
    if (dadosAtuais && dadosAtuais.status === STATUS_APROVADO) {
      return STATUS_APROVADO;
    }

    // Já pendente: evita resetar o prazo de 24h a cada toque repetido no
    // botão — apenas devolve o status atual.
    if (dadosAtuais && dadosAtuais.status === STATUS_PENDENTE) {
      return STATUS_PENDENTE;
    }

    // Sem documento, ou existente com negado/bloqueado/expirado: cria ou
    // REABRE uma nova solicitação pendente com prazo renovado de 24h.
    const agora = Timestamp.now();
    tx.set(permissaoRef, {
      uidAlvo,
      uidSolicitante,
      telefoneAlvo: telefoneNormalizado,
      telefoneSolicitante: solicitante.telefone || "",
      nomeAlvo: alvo.nome || "",
      nomeSolicitante: solicitante.nome || "",
      status: STATUS_PENDENTE,
      criadoEm: dadosAtuais ? dadosAtuais.criadoEm || agora : agora,
      atualizadoEm: agora,
      respondidoEm: null,
      expiraEm: Timestamp.fromMillis(
          Date.now() + JANELA_EXPIRACAO_MONITORAMENTO_MS,
      ),
    }, {merge: true});
    return STATUS_PENDENTE;
  });

  if (statusResultante === STATUS_PENDENTE) {
    await enviarFcmMonitoramento(uidAlvo, "solicitacao_monitoramento", {
      idPermissao: permissaoId,
      uidSolicitante,
      nomeSolicitante: solicitante.nome || "",
      telefoneSolicitante: solicitante.telefone || "",
    });
  }

  logger.info(
      `[solicitarMonitoramento] ${uidSolicitante} -> ${uidAlvo}: status resultante ${statusResultante}.`,
  );

  return {
    sucesso: true,
    uidAlvo,
    status: statusResultante,
    permissaoId,
  };
});

/**
 * Trigger `onDocumentUpdated`: sempre que o `status` de uma permissão
 * mudar por resposta do alvo (aprovado/negado/bloqueado, escrito
 * diretamente pelo cliente — ver `firestore.rules`), notifica o
 * SOLICITANTE via Push. A transição para "expirado" é tratada à parte
 * pela função agendada (`monitoramentoExpiracaoMonitor.js`), que já
 * dispara seu próprio Push — por isso é ignorada aqui.
 */
exports.aoAtualizarPermissaoMonitoramento = onDocumentUpdated(
    `${COLECAO_PERMISSOES}/{permissaoId}`,
    async (event) => {
      const antes = event.data.before.data();
      const depois = event.data.after.data();

      if (!antes || !depois) return;
      if (antes.status === depois.status) return;
      if (depois.status === STATUS_EXPIRADO) return;

      const tiposPorStatus = {
        [STATUS_APROVADO]: "monitoramento_aprovado",
        [STATUS_NEGADO]: "monitoramento_negado",
        [STATUS_BLOQUEADO]: "monitoramento_bloqueado",
      };
      const tipo = tiposPorStatus[depois.status];
      if (!tipo) return;

      await enviarFcmMonitoramento(depois.uidSolicitante, tipo, {
        idPermissao: event.params.permissaoId,
        uidAlvo: depois.uidAlvo,
        nomeAlvo: depois.nomeAlvo || "",
      });
    },
);

module.exports.COLECAO_PERMISSOES = COLECAO_PERMISSOES;
module.exports.STATUS_PENDENTE = STATUS_PENDENTE;
module.exports.STATUS_APROVADO = STATUS_APROVADO;
module.exports.STATUS_NEGADO = STATUS_NEGADO;
module.exports.STATUS_BLOQUEADO = STATUS_BLOQUEADO;
module.exports.STATUS_EXPIRADO = STATUS_EXPIRADO;
module.exports.enviarFcmMonitoramento = enviarFcmMonitoramento;
