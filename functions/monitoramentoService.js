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

      // Auditoria: toda vez que o ALVO nega ou bloqueia o compartilhamento
      // da própria localização com um solicitante específico, registra no
      // log — é o ponto server-side onde essa decisão de negação
      // individual fica rastreável (a leitura em si, quando negada pela
      // regra do Firestore em `usuarios/{uid}/monitoramento/atual`,
      // acontece inteiramente dentro do motor de regras, sem passar por
      // nenhuma Cloud Function, logo não pode ser logada aqui).
      if (depois.status === STATUS_NEGADO || depois.status === STATUS_BLOQUEADO) {
        logger.warn(
            `[permissaoMonitoramento] NEGADA: ${depois.uidAlvo} ` +
            `(${depois.telefoneAlvo || "sem telefone"}) definiu status ` +
            `"${depois.status}" para ${depois.uidSolicitante} ` +
            `(${depois.telefoneSolicitante || "sem telefone"}) — ` +
            `permissaoId=${event.params.permissaoId}. Solicitações futuras ` +
            "deste número para ver a localização serão negadas pela regra " +
            "de leitura em usuarios/{uid}/monitoramento/atual.",
        );
      }

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

/**
 * Callable `onCall` chamada pelo app (ver
 * `lib/services/monitoramento_service.dart`,
 * `definirPermissaoCompartilhamento`) ao alternar o Switch de
 * pré-autorização exibido em CADA card da lista "Localização de
 * familiares" — permite ao dono da localização CONCEDER ou BLOQUEAR
 * preventivamente o acesso de um contato específico, mesmo que ele nunca
 * tenha solicitado antes (pula o ciclo `pendente` -> aprovar/negar, pois
 * quem está decidindo aqui é o próprio dono, não quem solicita).
 *
 * Resolve o uid do contato pelo telefone SERVER-SIDE, no mesmo padrão de
 * `solicitarMonitoramento` — o cliente nunca consulta `usuarios` por
 * telefone diretamente (ver `firestore.rules`).
 *
 * data: {telefoneContato: string, permitir: boolean}
 * return: {sucesso: true, uidContato: string, status: string, permissaoId: string}
 */
exports.definirPermissaoCompartilhamento = onCall(async (request) => {
  const uidAlvo = request.auth && request.auth.uid;
  if (!uidAlvo) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }

  const {telefoneContato, permitir} = request.data || {};
  const telefoneNormalizado = normalizarTelefoneE164(telefoneContato);
  if (!telefoneNormalizado) {
    throw new HttpsError("invalid-argument", "Telefone inválido.");
  }
  if (typeof permitir !== "boolean") {
    throw new HttpsError("invalid-argument", "Parâmetro 'permitir' inválido.");
  }

  const alvoSnap = await db.collection("usuarios").doc(uidAlvo).get();
  const alvo = alvoSnap.exists ? alvoSnap.data() : {};

  const contatoQuery = await db.collection("usuarios")
      .where("telefone", "==", telefoneNormalizado)
      .limit(1)
      .get();
  if (contatoQuery.empty) {
    throw new HttpsError(
        "not-found", "Este número ainda não possui conta no Guardião X.",
    );
  }

  const contatoDoc = contatoQuery.docs[0];
  const uidSolicitante = contatoDoc.id;
  const contato = contatoDoc.data();

  if (uidSolicitante === uidAlvo) {
    throw new HttpsError(
        "invalid-argument",
        "Não é possível definir permissão para o próprio número.",
    );
  }

  const novoStatus = permitir ? STATUS_APROVADO : STATUS_BLOQUEADO;
  const permissaoId = montarIdPermissao(uidAlvo, uidSolicitante);
  const permissaoRef = db.collection(COLECAO_PERMISSOES).doc(permissaoId);

  await db.runTransaction(async (tx) => {
    const snapAtual = await tx.get(permissaoRef);
    const dadosAtuais = snapAtual.exists ? snapAtual.data() : null;
    const agora = Timestamp.now();

    tx.set(permissaoRef, {
      uidAlvo,
      uidSolicitante,
      telefoneAlvo: alvo.telefone || telefoneNormalizado,
      telefoneSolicitante: contato.telefone || telefoneNormalizado,
      nomeAlvo: alvo.nome || "",
      nomeSolicitante: contato.nome || "",
      status: novoStatus,
      criadoEm: dadosAtuais ? dadosAtuais.criadoEm || agora : agora,
      atualizadoEm: agora,
      respondidoEm: agora,
      expiraEm: null,
    }, {merge: true});
  });

  // Auditoria da pré-autorização direta — mesmo critério de log do
  // trigger `aoAtualizarPermissaoMonitoramento` acima, mas aqui cobre
  // também o caso de PRIMEIRA definição (documento inexistente antes),
  // que não passa por aquele trigger de `onDocumentUpdated`.
  if (novoStatus === STATUS_BLOQUEADO) {
    logger.warn(
        `[definirPermissaoCompartilhamento] NEGADA (pré-autorização): ` +
        `${uidAlvo} bloqueou preventivamente ${uidSolicitante} ` +
        `(${telefoneNormalizado}) — permissaoId=${permissaoId}.`,
    );
  } else {
    logger.info(
        `[definirPermissaoCompartilhamento] ${uidAlvo} concedeu ` +
        `pré-autorização a ${uidSolicitante} (${telefoneNormalizado}) — ` +
        `permissaoId=${permissaoId}.`,
    );
  }

  return {
    sucesso: true,
    uidContato: uidSolicitante,
    status: novoStatus,
    permissaoId,
  };
});

module.exports.COLECAO_PERMISSOES = COLECAO_PERMISSOES;
module.exports.STATUS_PENDENTE = STATUS_PENDENTE;
module.exports.STATUS_APROVADO = STATUS_APROVADO;
module.exports.STATUS_NEGADO = STATUS_NEGADO;
module.exports.STATUS_BLOQUEADO = STATUS_BLOQUEADO;
module.exports.STATUS_EXPIRADO = STATUS_EXPIRADO;
module.exports.enviarFcmMonitoramento = enviarFcmMonitoramento;
