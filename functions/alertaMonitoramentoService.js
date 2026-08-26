/**
 * Monitoramento de Alertas do Painel Web de Admin (M3) — visão agregada,
 * entre TODOS os usuários, dos alertas de emergência gravados em
 * `usuarios/{usuarioId}/alertas/{alertaId}` (ver `functions/index.js` →
 * `aoReceberAlertaTentativaDesarme` para o schema completo do documento
 * e o pipeline de disparo).
 *
 * Por que uma callable via Admin SDK, e não leitura direta do Firestore
 * pelo painel (como o módulo de Tickets faz): `firestore.rules` restringe
 * `usuarios/{usuarioId}/alertas` estritamente ao próprio dono
 * (`request.auth.uid == usuarioId`) — não existe, nem deveria existir,
 * uma regra que abra essa subcoleção pra leitura cross-usuário via
 * `collectionGroup`, porque ela mora dentro do documento de cada usuário
 * e uma regra assim vazaria justamente o padrão de dados sensíveis
 * (localização, fotos de emergência) que essas regras existem pra
 * proteger. Esta callable, como `obterResumoUsuarioSuporte`, filtra o
 * que é devolvido em vez de abrir a coleção.
 *
 * Exige a custom claim `role` em "supervisor"/"admin" (mesma whitelist
 * do item "Monitoramento de Alertas" em `admin/src/componentes/Layout.jsx`
 * — Tickets é a única tela liberada também pra "atendente").
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");

const db = getFirestore();

const ROLES_COM_ACESSO_ALERTAS = ["supervisor", "admin"];

/**
 * @param {import("firebase-functions/v2/https").CallableRequest} request
 * @return {boolean}
 */
function _temAcessoPainelAlertas(request) {
  return !!request.auth && ROLES_COM_ACESSO_ALERTAS.includes(request.auth.token.role);
}

const LIMITE_PADRAO = 50;
const LIMITE_MAXIMO = 100;

/**
 * Lista os alertas mais recentes de TODOS os usuários (via `collectionGroup`,
 * ver os índices dedicados em `firestore.indexes.json`), com um resumo
 * seguro (nome/telefone, nunca o documento completo de `usuarios/{uid}`)
 * de quem disparou cada um — mesmo cuidado de
 * `suporteChatService.js` → `obterResumoUsuarioSuporte`.
 */
exports.listarAlertasMonitoramento = onCall(async (request) => {
  if (!_temAcessoPainelAlertas(request)) {
    throw new HttpsError("permission-denied", "Apenas supervisor/admin.");
  }
  const {apenasPendentes, limite} = request.data || {};
  const limiteFinal = Math.min(
      Math.max(1, Number(limite) || LIMITE_PADRAO),
      LIMITE_MAXIMO,
  );

  // Filtra "pendentes" (revisadoPeloPainel !== true) em memória, não via
  // `where` no Firestore: alertas gravados ANTES desta feature nunca têm
  // o campo `revisadoPeloPainel` — uma igualdade `== false` no Firestore
  // não casa com "campo ausente", então excluiria justamente o histórico
  // antigo da aba "Pendentes". Por isso busca uma janela maior (só quando
  // filtrando) e recorta pro limite depois de filtrar.
  const janela = apenasPendentes ? Math.min(limiteFinal * 4, 400) : limiteFinal;
  const snap = await db.collectionGroup("alertas")
      .orderBy("criadoEm", "desc")
      .limit(janela)
      .get();

  const alertasBrutos = apenasPendentes ?
    snap.docs.filter((doc) => doc.data().revisadoPeloPainel !== true).slice(0, limiteFinal) :
    snap.docs;

  const alertas = alertasBrutos.map((doc) => {
    const dados = doc.data();
    // `usuarios/{usuarioId}/alertas/{alertaId}` — o uid do dono é sempre
    // o segmento imediatamente anterior a `alertas` no caminho do doc.
    const usuarioId = doc.ref.parent.parent ? doc.ref.parent.parent.id : null;
    return {
      id: doc.id,
      usuarioId,
      tipo: dados.tipo || null,
      origem: dados.origem || null,
      criadoEm: dados.criadoEm || null,
      processado: dados.processado === true,
      revisadoPeloPainel: dados.revisadoPeloPainel === true,
      revisadoPor: dados.revisadoPor || null,
      revisadoEm: dados.revisadoEm || null,
      latitude: typeof dados.latitude === "number" ? dados.latitude : null,
      longitude: typeof dados.longitude === "number" ? dados.longitude : null,
      localizacaoUsadaNoAlerta: dados.localizacaoUsadaNoAlerta || null,
      totalContatosNotificados: typeof dados.totalContatosNotificados === "number" ?
        dados.totalContatosNotificados : null,
      fotoUrl: dados.tipo === "sos_fisico_foto" ? (dados.fotoUrl || null) : null,
    };
  });

  // Resolve nome/telefone dos usuários únicos envolvidos, em paralelo —
  // mesmo subconjunto seguro de `obterResumoUsuarioSuporte`.
  const uidsUnicos = [...new Set(alertas.map((a) => a.usuarioId).filter(Boolean))];
  const resumos = await Promise.all(
      uidsUnicos.map((uid) => db.collection("usuarios").doc(uid).get()),
  );
  const resumoPorUid = {};
  resumos.forEach((snapUsuario, i) => {
    const dados = snapUsuario.exists ? snapUsuario.data() : null;
    resumoPorUid[uidsUnicos[i]] = {
      nome: dados?.nome || null,
      telefone: dados?.telefone || null,
    };
  });

  return {
    alertas: alertas.map((a) => ({
      ...a,
      nomeUsuario: a.usuarioId ? resumoPorUid[a.usuarioId]?.nome : null,
      telefoneUsuario: a.usuarioId ? resumoPorUid[a.usuarioId]?.telefone : null,
    })),
  };
});

/**
 * Marca um alerta como revisado/encerrado pelo painel — campo
 * INDEPENDENTE de `processado` (que é bookkeeping automático do próprio
 * pipeline de disparo em `functions/index.js`, não deve ser tocado por
 * uma ação manual do painel).
 */
exports.encerrarAlertaMonitoramento = onCall(async (request) => {
  if (!_temAcessoPainelAlertas(request)) {
    throw new HttpsError("permission-denied", "Apenas supervisor/admin.");
  }
  const {usuarioId, alertaId} = request.data || {};
  if (!usuarioId || !alertaId) {
    throw new HttpsError("invalid-argument", "usuarioId e alertaId são obrigatórios.");
  }

  const alertaRef = db
      .collection("usuarios")
      .doc(usuarioId)
      .collection("alertas")
      .doc(alertaId);
  const snap = await alertaRef.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Alerta não encontrado.");
  }

  await alertaRef.update({
    revisadoPeloPainel: true,
    revisadoPor: request.auth.uid,
    revisadoEm: Timestamp.now(),
  });
  logger.info(`[AlertaMonitoramento] Alerta ${alertaId} (usuário ${usuarioId}) encerrado por ${request.auth.uid}.`);
  return {ok: true};
});
