/**
 * Regra oficial de monetização/limitação do Plano Free (ciclo recorrente de
 * 30 dias) — ver `lib/services/plano_ciclo_service.dart` no app para o
 * espelho client-side (leitura/gating) e `firestore.rules` para a trava
 * que impede o cliente de escrever `isPremium`/`cycleStartDate`/
 * `blockedAt` diretamente: SÓ este módulo (Admin SDK, roda com privilégio
 * total e ignora as regras) tem permissão de gravar esses 3 campos em
 * `usuarios/{uid}` — fecha a brecha citada explicitamente pelo usuário
 * ("desinstalar e reinstalar o app NÃO reinicia o ciclo").
 *
 * Campos em `usuarios/{uid}`:
 * - `isPremium` (bool): `true` = sem nenhum bloqueio, sempre. Nunca é
 *   setado como `true` por nenhuma função aqui — não existe, neste
 *   projeto, uma integração de compra In-App Purchase com verificação de
 *   recibo (ver TODO em `lib/services/premium_price_service.dart`, que já
 *   documenta a mesma lacuna: o botão "Assinar Premium" só abre a Play
 *   Store, sem confirmar a compra de volta ao app). Até essa integração
 *   existir, a ÚNICA forma de conceder Premium é manual, direto no
 *   Console do Firebase (Admin) ou por um futuro webhook de compra — o
 *   [cancelarPremiumDoProprioUsuario] abaixo só permite o caminho inverso
 *   (self-service DOWNGRADE, inofensivo do ponto de vista de fraude).
 * - `cycleStartDate` (Timestamp): início do ciclo gratuito atual.
 * - `blockedAt` (Timestamp, opcional): quando o ciclo atual entrou na
 *   janela de 20 dias inativos — só informativo/auditoria, não é lido por
 *   nenhuma regra de negócio.
 *
 * Regra (replicada em Dart, ver `PlanoCicloStatus.fromDoc`):
 * - `isPremium == true`: sempre ativo.
 * - Dias 1-10 do ciclo (contando o dia de início como dia 1): ativo.
 * - Dias 11-30: inativo (bloqueado).
 * - Ao completar 30 dias: o ciclo se autorrenova para a data atual.
 */

const {getFirestore, Timestamp, FieldValue} = require("firebase-admin/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");

const db = getFirestore();

const DURACAO_CICLO_DIAS = 30;
const DURACAO_ATIVO_DIAS = 10;
const MS_POR_DIA = 24 * 60 * 60 * 1000;

/**
 * Calcula o "dia atual" do ciclo (1-based: o próprio dia de início já é o
 * dia 1) a partir de [inicioMs] até [agoraMs].
 * @param {number} inicioMs
 * @param {number} agoraMs
 * @return {number}
 */
function calcularDiaAtual(inicioMs, agoraMs) {
  const diasDecorridos = Math.floor((agoraMs - inicioMs) / MS_POR_DIA);
  return diasDecorridos + 1;
}

/**
 * Lê (ou inicializa/renova) o ciclo do Plano Free do usuário [uid] dentro
 * de uma transação — chamada tanto pela callable [sincronizarCicloPlano]
 * (disparada pelo app a cada início de sessão) quanto, futuramente, por
 * qualquer outro gatilho server-side que precise do status mais
 * atualizado possível (ex: resolução de destinatários de Push, ver
 * `alertaHibridoService.js`).
 *
 * @param {string} uid
 * @return {Promise<{isPremium: boolean, cycleStartDateMs: number, diaAtual: number, ativo: boolean}>}
 */
async function sincronizarCicloDoUsuario(uid) {
  const ref = db.collection("usuarios").doc(uid);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const dados = snap.exists ? snap.data() : {};
    const agora = Timestamp.now();
    const agoraMs = agora.toMillis();

    const isPremium = dados.isPremium === true;
    const cycleStartDate = dados.cycleStartDate;

    // Primeiro acesso deste usuário ao ciclo (documento novo ou campo
    // nunca gravado antes) — inicia o ciclo agora mesmo, liberando os 10
    // primeiros dias.
    if (!cycleStartDate) {
      tx.set(ref, {
        isPremium,
        cycleStartDate: agora,
        blockedAt: FieldValue.delete(),
      }, {merge: true});
      logger.info(`[PlanoCiclo] Ciclo iniciado agora para ${uid}.`);
      return {isPremium, cycleStartDateMs: agoraMs, diaAtual: 1, ativo: true};
    }

    const inicioMs = cycleStartDate.toMillis();
    const diaAtual = calcularDiaAtual(inicioMs, agoraMs);

    // Ciclo completou 30 dias (ou mais, ex: app ficou muito tempo sem
    // abrir) — renova automaticamente para a data de hoje, liberando
    // novos 10 dias ativos. Usuários Premium também têm o campo mantido
    // em dia (irrelevante para eles, já que `isPremium` sozinho já libera
    // tudo, mas evita que `cycleStartDate` fique arbitrariamente antigo
    // caso o Premium seja cancelado no futuro).
    if (diaAtual > DURACAO_CICLO_DIAS) {
      tx.set(ref, {
        isPremium,
        cycleStartDate: agora,
        blockedAt: FieldValue.delete(),
      }, {merge: true});
      logger.info(`[PlanoCiclo] Ciclo de ${uid} renovado automaticamente (dia ${diaAtual} > ${DURACAO_CICLO_DIAS}).`);
      return {isPremium, cycleStartDateMs: agoraMs, diaAtual: 1, ativo: true};
    }

    const ativo = isPremium || diaAtual <= DURACAO_ATIVO_DIAS;

    // Marca (só informativo) o instante em que este ciclo especificamente
    // entrou na janela inativa — só grava na PRIMEIRA vez detectada dentro
    // deste ciclo (blockedAt ausente ou de um ciclo anterior).
    if (!isPremium && !ativo) {
      const blockedAt = dados.blockedAt;
      const precisaMarcar = !blockedAt || blockedAt.toMillis() < inicioMs;
      if (precisaMarcar) {
        tx.set(ref, {blockedAt: agora}, {merge: true});
      }
    }

    return {isPremium, cycleStartDateMs: inicioMs, diaAtual, ativo};
  });
}

/**
 * Callable acionada pelo app (ver `PlanoCicloService.iniciar`) uma vez por
 * sessão, logo após o login/chegada ao dashboard — único ponto de escrita
 * de `cycleStartDate`/renovação automática. Retorna o status já calculado
 * para o app poder exibir o indicador imediatamente, sem uma segunda
 * leitura.
 */
exports.sincronizarCicloPlano = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Requer autenticação.");
  }
  const status = await sincronizarCicloDoUsuario(request.auth.uid);
  return status;
});

/**
 * Callable de auto-downgrade: permite que o próprio usuário abra mão do
 * Premium (ver botão "Cancelar Plano Premium" em `InicioDashboard`) —
 * sempre seguro do ponto de vista de fraude (só reduz privilégio do
 * próprio chamador, nunca concede). NÃO existe o caminho inverso
 * client-callable (ver documentação do módulo acima).
 */
exports.cancelarPremiumDoProprioUsuario = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Requer autenticação.");
  }
  const uid = request.auth.uid;
  await db.collection("usuarios").doc(uid).set({isPremium: false}, {merge: true});
  logger.info(`[PlanoCiclo] Usuário ${uid} cancelou o Plano Premium (self-service).`);
  return {sucesso: true};
});

module.exports = {
  sincronizarCicloDoUsuario,
  DURACAO_CICLO_DIAS,
  DURACAO_ATIVO_DIAS,
  calcularDiaAtual,
  sincronizarCicloPlano: exports.sincronizarCicloPlano,
  cancelarPremiumDoProprioUsuario: exports.cancelarPremiumDoProprioUsuario,
};
