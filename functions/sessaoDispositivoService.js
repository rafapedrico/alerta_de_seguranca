/**
 * Revogação de sessões em outros aparelhos — pedido explícito do usuário
 * (2026-09-06): quando alguém perde o celular (ou troca de aparelho) e
 * loga de novo na MESMA conta em um aparelho novo, a sessão que ainda
 * estiver aberta no aparelho antigo deve parar de funcionar por segurança.
 *
 * DELIBERADAMENTE não tem nada a ver com número de telefone/duplicidade —
 * a única credencial que importa aqui é o próprio UID autenticado de quem
 * está chamando (`request.auth.uid`), o mesmo UID que o Firebase Auth já
 * resolve automaticamente para a MESMA conta Google/e-mail em qualquer
 * aparelho. Um número de telefone NUNCA é usado como prova de identidade
 * neste fluxo — ver decisão registrada em `telefonePerfilService.js`
 * (auditoria 2026-09-06: "transferência automática via duplicidade de
 * número" foi recusada por risco de sequestro de conta).
 *
 * Como funciona: `getAuth().revokeRefreshTokens(uid)` marca um timestamp
 * "tokens válidos a partir de agora" na conta — qualquer refresh token
 * (e, por extensão, qualquer sessão) emitido ANTES desse instante para de
 * funcionar na próxima vez que precisar renovar o ID token (até ~1h de
 * tolerância, tempo de vida padrão de um ID token do Firebase — nunca
 * instantâneo, mas limitado). Só afeta o PRÓPRIO uid do chamador — nunca
 * é possível revogar a sessão de outra pessoa por aqui.
 *
 * ARMADILHA EVITADA DE PROPÓSITO: chamar isto DEPOIS que o app já tem uma
 * sessão ativa faria o dispositivo ATUAL também ser invalidado na próxima
 * renovação de token (o token recém-emitido no login também é "anterior"
 * ao timestamp de revogação, por poucos milissegundos) — por isso
 * [FirebaseAuthService] força um `getIdToken(true)` (renovação explícita)
 * logo depois de chamar esta callable, garantindo que o PRÓPRIO aparelho
 * que acabou de logar sempre saia com um token novo, emitido DEPOIS da
 * revogação.
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {getAuth} = require("firebase-admin/auth");
const logger = require("firebase-functions/logger");

exports.revogarSessoesEmOutrosDispositivos = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }
  const uid = request.auth.uid;

  try {
    await getAuth().revokeRefreshTokens(uid);
    logger.info(`[SessaoDispositivo] Sessões de outros aparelhos revogadas para ${uid}.`);
    return {sucesso: true};
  } catch (e) {
    // Best-effort: uma falha aqui nunca deve impedir o login em si no
    // aparelho atual (já concluído antes desta chamada) — só significa
    // que uma sessão antiga eventualmente órfã continua válida por mais
    // tempo. Log para acompanhamento, sem propagar erro pro app.
    logger.error(`[SessaoDispositivo] Falha ao revogar sessões de ${uid}:`, e);
    return {sucesso: false};
  }
});
