/**
 * Exclusão definitiva de conta (Configurações > Minha Conta > Excluir
 * Conta e Dados no app) — requisito de conformidade da Google Play Store
 * e da Apple App Store para apps que oferecem cadastro de conta.
 *
 * Roda inteiramente com o Admin SDK, por dois motivos:
 * 1. `firestore.rules` nega `delete` ao cliente de propósito em TODAS as
 *    coleções (usuarios, alarmes_agendados, permissoes_monitoramento —
 *    ver comentários lá) — o cliente jamais conseguiria apagar esses
 *    documentos sozinho, mesmo sendo o dono.
 * 2. Apagar o registro do Firebase Authentication a partir do cliente
 *    (`user.delete()`) exige reautenticação recente
 *    (`requires-recent-login`) — inviável de tratar de forma uniforme
 *    aqui, já que o login pode ter sido por e-mail/senha OU por um
 *    provider social (Google/Facebook/Apple), cada um com seu próprio
 *    fluxo de reautenticação. `admin.auth().deleteUser()` ignora essa
 *    exigência por completo.
 *
 * A confirmação de identidade de quem está pedindo a exclusão continua
 * sendo feita no PRÓPRIO APARELHO, pelo PIN de segurança já usado em
 * todas as demais ações sensíveis do Guardião X (ver `ExcluirContaScreen`
 * / `pin_dialog.dart`) — esta função só executa depois que o PIN correto
 * já foi confirmado localmente e o app chama esta callable autenticado
 * como o próprio usuário (`request.auth.uid`).
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {getStorage} = require("firebase-admin/storage");
const logger = require("firebase-functions/logger");

const db = getFirestore();

/**
 * Apaga todos os documentos do Firestore associados a [uid]:
 * - `usuarios/{uid}` (documento principal) e suas subcoleções
 *   `alertas/*` e `monitoramento/atual`.
 * - `alarmes_agendados/*` cujo campo `usuarioId` seja [uid].
 * - `permissoes_monitoramento/*` em que [uid] seja `uidAlvo` OU
 *   `uidSolicitante` (compartilhamento bilateral de localização).
 *
 * NÃO tenta limpar `entregas_alerta/*\/confirmacoes/{uid}` — coleção
 * interna e opaca do pipeline de Push (sem índice viável por uid a partir
 * daqui) que não contém, por si só, nenhum dado pessoal identificável
 * além da própria referência de uid, já órfã depois deste processo.
 *
 * Também libera `telefones_reservados/{telefone}` (ver
 * `telefonePerfilService.js` — unicidade estrita sem OTP, decisão de
 * arquitetura 2026-08-23) SE o usuário tiver um telefone gravado — sem
 * isso, o número ficaria permanentemente preso e ninguém mais (nem o
 * próprio dono, numa conta nova) conseguiria cadastrá-lo de novo. Lição
 * do bug da "conta fantasma" do Auth (mesmo dia): a liberação acontece
 * no MESMO Promise.all que apaga `usuarios/{uid}`, nunca numa etapa
 * separada que possa ficar pra trás se algo falhar no meio do caminho.
 *
 * @param {string} uid
 */
async function excluirDadosFirestore(uid) {
  const operacoes = [];

  const alertasSnap = await db
      .collection("usuarios").doc(uid).collection("alertas").get();
  for (const doc of alertasSnap.docs) operacoes.push(doc.ref.delete());

  operacoes.push(
      db.collection("usuarios").doc(uid)
          .collection("monitoramento").doc("atual")
          .delete().catch(() => {}),
  );

  const usuarioSnap = await db.collection("usuarios").doc(uid).get();
  const telefone = usuarioSnap.exists ? usuarioSnap.data().telefone : null;
  if (telefone) {
    const refReserva = db.collection("telefones_reservados").doc(telefone);
    const reservaSnap = await refReserva.get();
    // Defensivo: só apaga se a reserva for realmente deste uid.
    if (reservaSnap.exists && reservaSnap.data().uid === uid) {
      operacoes.push(refReserva.delete());
    }
  }

  operacoes.push(db.collection("usuarios").doc(uid).delete());

  const alarmesSnap = await db.collection("alarmes_agendados")
      .where("usuarioId", "==", uid).get();
  for (const doc of alarmesSnap.docs) operacoes.push(doc.ref.delete());

  const [comoAlvo, comoSolicitante] = await Promise.all([
    db.collection("permissoes_monitoramento")
        .where("uidAlvo", "==", uid).get(),
    db.collection("permissoes_monitoramento")
        .where("uidSolicitante", "==", uid).get(),
  ]);
  for (const doc of comoAlvo.docs) operacoes.push(doc.ref.delete());
  for (const doc of comoSolicitante.docs) operacoes.push(doc.ref.delete());

  await Promise.all(operacoes);
}

/**
 * Apaga todas as fotos do SOS enviadas por [uid] (`sos_fotos/{uid}/*` no
 * Storage — ver `storage.rules`).
 * @param {string} uid
 */
async function excluirArquivosStorage(uid) {
  const bucket = getStorage().bucket();
  await bucket.deleteFiles({prefix: `sos_fotos/${uid}/`});
}

/**
 * Registra um marcador PERMANENTE de revogação em `contas_excluidas/{uid}`
 * — sobrevive à exclusão do documento `usuarios/{uid}` (apagado logo
 * depois, ver [excluirDadosFirestore]) e existe justamente para não
 * depender só da memória do processo.
 *
 * IMPORTANTE — por que isto NÃO chama nenhum gateway de pagamento: o
 * Guardião X não processa cobranças diretamente e NUNCA integrou nenhum
 * gateway (Stripe ou similar) — as assinaturas do Plano Premium são
 * feitas 100% pela Google Play Billing / Apple StoreKit, sem nenhuma
 * Cloud Function neste projeto recebendo webhooks/RTDN dessas lojas (ver
 * `PremiumPriceService`/Termos de Uso, Seção 7: "a RMF Global não recebe
 * nem processa pagamentos diretamente"). Isso significa que a RMF Global
 * NUNCA teve, em nenhum momento, um meio de cobrar o usuário por conta
 * própria — não existe "assinatura" para revogar do lado do servidor
 * porque o servidor nunca teve controle sobre ela. A renovação automática
 * de uma assinatura ativa é decidida inteiramente pela conta
 * Google/Apple do próprio usuário, por isso a tela de exclusão orienta
 * explicitamente o cancelamento na loja (ver
 * `excluirContaAvisoAssinatura` nos arquivos de tradução).
 *
 * Este documento existe para o cenário em que uma futura integração
 * server-side com a Google Play Developer API (Real-time Developer
 * Notifications) for implementada: bastaria consultar esta coleção antes
 * de processar uma notificação de renovação, para reconhecer contas já
 * excluídas e tratar cobranças pós-exclusão como reembolso automático.
 *
 * @param {string} uid
 */
async function registrarRevogacao(uid) {
  await db.collection("contas_excluidas").doc(uid).set({
    excluidoEm: new Date().toISOString(),
    motivo: "exclusao_de_conta_pelo_usuario",
  });
}

/**
 * Callable `onCall` acionada pelo app (ver `ExclusaoContaService` no
 * Flutter) depois da confirmação do PIN de segurança na
 * `ExcluirContaScreen`. Ordem deliberada: registro de revogação ->
 * Firestore -> Storage -> Auth por último — se algo falhar antes de
 * chegar no Auth, o usuário ainda consegue logar de novo e tentar a
 * exclusão outra vez; apagar o Auth primeiro removeria essa chance de
 * nova tentativa.
 */
// Reexportadas para reuso por `liberarTelefoneOrfaoService.js` (auto-cura
// de conta fantasma no fluxo de verificação de telefone) — mesma lógica
// de limpeza, sem duplicar código.
exports.excluirDadosFirestore = excluirDadosFirestore;
exports.excluirArquivosStorage = excluirArquivosStorage;

exports.excluirContaCompleta = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }
  const uid = request.auth.uid;

  try {
    await registrarRevogacao(uid);
  } catch (e) {
    // Best-effort: a ausência deste marcador nunca deve impedir a
    // exclusão real da conta em si, que é o que o usuário pediu.
    logger.error(`[excluirContaCompleta] Falha ao registrar revogação de ${uid}:`, e);
  }

  try {
    await excluirDadosFirestore(uid);
  } catch (e) {
    logger.error(`[excluirContaCompleta] Falha ao excluir Firestore de ${uid}:`, e);
    throw new HttpsError("internal", "Falha ao excluir os dados salvos na nuvem.");
  }

  try {
    await excluirArquivosStorage(uid);
  } catch (e) {
    // Best-effort: mídias órfãs no Storage são um problema bem menor do
    // que travar a exclusão da conta por completo — não interrompe.
    logger.error(`[excluirContaCompleta] Falha ao excluir Storage de ${uid}:`, e);
  }

  try {
    await getAuth().deleteUser(uid);
  } catch (e) {
    logger.error(`[excluirContaCompleta] Falha ao excluir usuário do Auth ${uid}:`, e);
    throw new HttpsError("internal", "Falha ao excluir o cadastro de autenticação.");
  }

  logger.info(`[excluirContaCompleta] Conta ${uid} excluída com sucesso.`);
  return {sucesso: true};
});
