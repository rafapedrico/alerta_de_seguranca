/**
 * Verificação server-side das compras consumíveis da Carteira em USD
 * (recargas de $1/$5/$10) — Google Play apenas, não há projeto iOS neste
 * repositório.
 *
 * FAIL-CLOSED por design: ao contrário do gateway de WhatsApp
 * (`smsGateway.js`), que degrada graciosamente (loga e segue) quando as
 * credenciais não estão configuradas, aqui a ausência de credenciais ou
 * qualquer falha de verificação REJEITA a compra — o erro seguro é "não
 * dar saldo de graça", nunca o oposto. O cliente nunca credita saldo
 * otimisticamente; só `saldoUsd` confirmado por esta function conta (ver
 * `firestore.rules`, que bloqueia escrita direta desse campo).
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const {google} = require("googleapis");
const {creditarSaldo} = require("./walletService");

// Credencial da service account do Google Cloud com acesso à Play
// Developer API habilitado no Play Console ("Ver ordens financeiras e
// gerenciar assinaturas") — configure com:
//   firebase functions:secrets:set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON
const googlePlayServiceAccountJson = defineSecret("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON");

// Mesmo applicationId do app Android (ver android/app/build.gradle) — se
// o app for republicado sob outro id antes de ir para produção, ajuste
// aqui também.
const PACOTE_ANDROID = "com.example.security_check_app";

// productId (Play Console) -> valor em USD creditado na Carteira.
const PRODUTOS_CREDITO = Object.freeze({
  credito_usd_1: 1,
  credito_usd_5: 5,
  credito_usd_10: 10,
});

/**
 * Verifica a compra junto à Google Play Developer API e, se válida,
 * reconhece (`acknowledge`) — obrigatório em até 3 dias, senão a Play
 * reembolsa automaticamente. Nunca lança exceção: sempre retorna
 * `{valida: boolean, motivo?: string}`.
 *
 * @param {string} produtoId
 * @param {string} purchaseToken
 * @return {Promise<{valida: boolean, motivo?: string}>}
 */
async function verificarCompraNoPlayStore(produtoId, purchaseToken) {
  const credenciaisJson = googlePlayServiceAccountJson.value();
  if (!credenciaisJson) {
    logger.warn(
        "[comprasService] GOOGLE_PLAY_SERVICE_ACCOUNT_JSON não configurado no " +
        "Secret Manager — REJEITANDO a compra (fail-closed). Configure com " +
        "'firebase functions:secrets:set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON'.",
    );
    return {valida: false, motivo: "secret_nao_configurado"};
  }

  let credenciais;
  try {
    credenciais = JSON.parse(credenciaisJson);
  } catch (e) {
    logger.error("[comprasService] GOOGLE_PLAY_SERVICE_ACCOUNT_JSON malformado", e);
    return {valida: false, motivo: "secret_malformado"};
  }

  try {
    const auth = new google.auth.GoogleAuth({
      credentials: credenciais,
      scopes: ["https://www.googleapis.com/auth/androidpublisher"],
    });
    const androidpublisher = google.androidpublisher({version: "v3", auth});

    const resposta = await androidpublisher.purchases.products.get({
      packageName: PACOTE_ANDROID,
      productId: produtoId,
      token: purchaseToken,
    });

    // purchaseState: 0 = comprado, 1 = cancelado, 2 = pendente.
    const purchaseState = resposta.data.purchaseState;
    if (purchaseState !== 0) {
      return {valida: false, motivo: `purchaseState_${purchaseState}`};
    }

    if (resposta.data.acknowledgementState === 0) {
      try {
        await androidpublisher.purchases.products.acknowledge({
          packageName: PACOTE_ANDROID,
          productId: produtoId,
          token: purchaseToken,
          requestBody: {},
        });
      } catch (e) {
        // Não bloqueante: a compra já foi validada como legítima acima;
        // uma falha isolada no acknowledge (ex: chamada duplicada) não
        // deve impedir o crédito do saldo.
        logger.warn("[comprasService] Falha ao reconhecer compra na Play (não bloqueante)", e);
      }
    }

    return {valida: true};
  } catch (e) {
    logger.error(
        `[comprasService] Falha ao verificar compra ${produtoId} na Play Developer API`, e,
    );
    return {valida: false, motivo: "erro_verificacao"};
  }
}

/**
 * Callable `onCall` chamada pelo app (ver `lib/services/wallet_service.dart`)
 * após o `in_app_purchase` reportar uma compra como concluída no
 * dispositivo. Só credita o saldo depois de verificar a compra
 * server-side — nunca confia no relato do cliente.
 */
exports.confirmarCompraCredito = onCall(
    {secrets: [googlePlayServiceAccountJson]},
    async (request) => {
      const uid = request.auth && request.auth.uid;
      if (!uid) {
        throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
      }

      const {produtoId, purchaseToken} = request.data || {};
      const valorUsd = PRODUTOS_CREDITO[produtoId];

      if (!valorUsd || !purchaseToken) {
        throw new HttpsError("invalid-argument", "produtoId ou purchaseToken inválidos.");
      }

      const verificacao = await verificarCompraNoPlayStore(produtoId, purchaseToken);
      if (!verificacao.valida) {
        logger.warn(
            `[comprasService] Compra REJEITADA para o usuário ${uid} ` +
            `(produto: ${produtoId}, motivo: ${verificacao.motivo}) — nenhum saldo creditado.`,
        );
        throw new HttpsError(
            "failed-precondition", `Compra não pôde ser verificada (${verificacao.motivo}).`,
        );
      }

      const resultado = await creditarSaldo(uid, valorUsd, produtoId, purchaseToken);
      if (!resultado.sucesso) {
        throw new HttpsError(
            "already-exists", `Não foi possível creditar o saldo (${resultado.motivo}).`,
        );
      }

      logger.info(
          `[comprasService] $${valorUsd} USD creditado(s) para o usuário ${uid} ` +
          `(produto: ${produtoId}).`,
      );
      return {sucesso: true, valorUsd};
    },
);
