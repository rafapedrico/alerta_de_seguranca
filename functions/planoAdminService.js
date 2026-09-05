/**
 * Gestão de Planos do Painel Web de Admin (M3) — visão administrativa
 * dos níveis de acesso (Free vs. Premium) e dos parâmetros operacionais
 * de cada plano. Exige a custom claim `role == "admin"` (único nível que
 * vê este módulo, ver `admin/src/componentes/Layout.jsx`).
 *
 * DECISÃO DELIBERADA (confirmada com o usuário em 2026-08-26): este
 * módulo NUNCA concede Premium. Ver `planoCicloService.js` — não existe,
 * neste projeto, verificação de recibo de compra (In-App Purchase), então
 * a única forma seria abrir uma porta de fraude no painel; a única
 * concessão continua sendo manual, direto no Console do Firebase. O que
 * este módulo permite é o caminho inverso (revogar/downgrade), que é o
 * mesmo raciocínio "inofensivo do ponto de vista de fraude" já usado em
 * `cancelarPremiumDoProprioUsuario` (self-service) — aqui, o mesmo botão,
 * só que acionado por um admin em nome de outro usuário.
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {getFirestore} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");

const {calcularDiaAtual, DURACAO_CICLO_DIAS, DURACAO_ATIVO_DIAS} = require("./planoCicloService");

const db = getFirestore();

/**
 * @param {import("firebase-functions/v2/https").CallableRequest} request
 * @return {boolean}
 */
function _ehAdmin(request) {
  return !!request.auth && request.auth.token.role === "admin";
}

/**
 * Parâmetros operacionais dos planos — fonte de verdade real
 * (`planoCicloService.js`, aplicada server-side).
 *
 * REGRA ÚNICA DO PLANO FREE (reespecificação do usuário, 2026-09-04):
 * dentro dos `duracaoAtivaDias` dias ativos do ciclo (ou Premium), TODOS
 * os recursos são liberados sem nenhum teto numérico adicional; fora
 * dessa janela, nenhuma mensagem é enviada. O antigo teto separado de 5
 * alertas/2 fotos por mês (`lib/services/plano_limite_service.dart`)
 * contradizia essa regra (bloqueava mesmo DENTRO dos dias ativos) e foi
 * REMOVIDO por completo do app — não existe mais nenhum parâmetro de
 * limite numérico para expor aqui.
 */
exports.obterParametrosPlanos = onCall(async (request) => {
  if (!_ehAdmin(request)) {
    throw new HttpsError("permission-denied", "Apenas admin.");
  }
  return {
    duracaoCicloDias: DURACAO_CICLO_DIAS,
    duracaoAtivaDias: DURACAO_ATIVO_DIAS,
  };
});

/**
 * Calcula o status do ciclo do Plano Free SEM MUTAR o documento — mera
 * leitura para exibição no painel. Deliberadamente diferente de
 * `sincronizarCicloDoUsuario` (que inicializa/renova o ciclo como efeito
 * colateral): uma consulta administrativa nunca deve ter esse efeito.
 * @param {object} dados
 * @return {{cycleStartDateMs: number|null, diaAtual: number|null, ativo: boolean}}
 */
function _statusCicloSomenteLeitura(dados) {
  const isPremium = dados.isPremium === true;
  const cycleStartDate = dados.cycleStartDate;
  if (!cycleStartDate) {
    return {cycleStartDateMs: null, diaAtual: null, ativo: isPremium};
  }
  const inicioMs = cycleStartDate.toMillis();
  const diaAtual = calcularDiaAtual(inicioMs, Date.now());
  const diaEfetivo = diaAtual > DURACAO_CICLO_DIAS ? 1 : diaAtual;
  const ativo = isPremium || diaEfetivo <= DURACAO_ATIVO_DIAS;
  return {cycleStartDateMs: inicioMs, diaAtual: diaEfetivo, ativo};
}

/**
 * Busca um usuário pelo `uid` (id do documento) ou pelo `email` (igualdade
 * exata) — não há busca textual/parcial no Firestore. Devolve o mesmo
 * subconjunto seguro de sempre (nome/email/telefone) mais o status do
 * plano, somente leitura.
 */
exports.buscarUsuarioPlano = onCall(async (request) => {
  if (!_ehAdmin(request)) {
    throw new HttpsError("permission-denied", "Apenas admin.");
  }
  const busca = (request.data && request.data.busca || "").trim();
  if (!busca) {
    throw new HttpsError("invalid-argument", "Informe um uid ou e-mail para buscar.");
  }

  let doc = null;
  if (busca.includes("@")) {
    const snap = await db.collection("usuarios").where("email", "==", busca).limit(1).get();
    doc = snap.empty ? null : snap.docs[0];
  } else {
    const snap = await db.collection("usuarios").doc(busca).get();
    doc = snap.exists ? snap : null;
  }

  if (!doc) {
    return {encontrado: false};
  }

  const dados = doc.data();
  return {
    encontrado: true,
    uid: doc.id,
    nome: dados.nome || null,
    email: dados.email || null,
    telefone: dados.telefone || null,
    isPremium: dados.isPremium === true,
    ..._statusCicloSomenteLeitura(dados),
  };
});

/**
 * Revoga o Premium de um usuário (downgrade administrativo) — nunca
 * concede. Mesmo efeito de `cancelarPremiumDoProprioUsuario`, mas
 * acionado por um admin em nome de outro `uid`.
 */
exports.revogarPremiumAdmin = onCall(async (request) => {
  if (!_ehAdmin(request)) {
    throw new HttpsError("permission-denied", "Apenas admin.");
  }
  const {uid} = request.data || {};
  if (!uid || typeof uid !== "string") {
    throw new HttpsError("invalid-argument", "uid é obrigatório.");
  }

  const ref = db.collection("usuarios").doc(uid);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Usuário não encontrado.");
  }

  await ref.set({isPremium: false}, {merge: true});
  logger.info(`[PlanoAdmin] Premium de ${uid} revogado pelo admin ${request.auth.uid}.`);
  return {ok: true};
});
