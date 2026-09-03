/**
 * Validação real de compra do Plano Premium via Google Play Billing —
 * fecha a lacuna documentada em `planoCicloService.js`/
 * `lib/services/premium_price_service.dart` (não existia, neste projeto,
 * nenhuma verificação de recibo de compra; `isPremium` só podia ser
 * concedido manualmente pelo Console do Firebase).
 *
 * Fluxo completo:
 * 1. App compra a assinatura via Play Billing (`InAppPurchase.buyNonConsumable`,
 *    ver `lib/services/premium_purchase_service.dart`).
 * 2. O `purchaseStream` do app recebe o `PurchaseDetails` com o
 *    `purchaseToken` e chama [validarCompraPremium] aqui.
 * 3. Esta função consulta a Play Developer API (Android Publisher,
 *    endpoint `purchases.subscriptionsv2`) para confirmar que o token é
 *    genuíno e que a assinatura está de fato ativa — NUNCA confia em
 *    nada que o cliente diga sobre o estado da compra.
 * 4. Só então grava `isPremium: true` em `usuarios/{uid}` (Admin SDK —
 *    única forma permitida, ver `firestore.rules`).
 *
 * PRÉ-REQUISITO DE INFRAESTRUTURA (fora do alcance do código — precisa
 * ser feito manualmente no Google Cloud/Play Console antes de funcionar
 * em produção):
 * 1. Ativar a "Google Play Android Developer API" (androidpublisher.
 *    googleapis.com) no projeto GCP do Firebase (mesmo projeto do
 *    `guardiaox`, número 555863351772).
 * 2. Play Console > Configurar > Acesso à API > vincular esse projeto
 *    GCP (se ainda não estiver vinculado).
 * 3. Na mesma tela, conceder acesso à conta de serviço que esta function
 *    (Cloud Functions Gen 2) efetivamente usa por padrão —
 *    `555863351772-compute@developer.gserviceaccount.com` (conta padrão
 *    do Compute Engine; NÃO é a `<project-id>@appspot.gserviceaccount.com`
 *    do Gen 1) — com a permissão "Ver dados financeiros" + "Gerenciar
 *    pedidos e assinaturas" (Financial data / Orders & subscriptions).
 * Sem isso, toda chamada a [validarCompraPremium] falha com 403
 * `accessNotConfigured` (a API do Google recusa a consulta por permissão)
 * — confirmado nos logs de produção em 2026-09-02/03.
 *
 * LIMITE HONESTO (documentado para nunca ser esquecido): cobre a
 * CONCESSÃO inicial e a reverificação periódica (ver
 * [reverificarAssinaturasPremium] abaixo), mas não usa Real-time
 * Developer Notifications (RTDN/Pub-Sub) — uma renovação com falha de
 * pagamento ou um cancelamento só é refletido em `isPremium` na próxima
 * execução da reverificação diária, nunca instantaneamente.
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {GoogleAuth} = require("google-auth-library");
const logger = require("firebase-functions/logger");

const db = getFirestore();

// Mesmo pacote Android usado em `android/app/build.gradle`
// (`applicationId`) e nos links da Play Store espalhados pelo app/site.
const ANDROID_PACKAGE_NAME = "com.rmfglobal.guardiaox";

// Id do produto de assinatura mensal cadastrado no Play Console
// (Monetise > Products > Subscriptions) — precisa ser EXATAMENTE este
// id no Play Console, e é o mesmo usado em
// `lib/services/premium_price_service.dart`/`premium_purchase_service.dart`.
const PRODUTO_PREMIUM_ID = "assinatura_mensal";

// Estados da Play Developer API (`subscriptionState`) em que o usuário
// AINDA tem direito ao Premium. `SUBSCRIPTION_STATE_CANCELED` é tratado
// à parte abaixo (tem direito só até `expiryTime`, mesmo com auto-renew
// desligado). Todos os demais (ON_HOLD, PAUSED, EXPIRED, PENDING) NÃO
// dão direito.
const ESTADOS_COM_DIREITO_A_PREMIUM = new Set([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
]);

/**
 * @param {import("firebase-functions/v2/https").CallableRequest} request
 * @return {boolean}
 */
function _ehAdmin(request) {
  return !!request.auth && request.auth.token.role === "admin";
}

let _clienteAndroidPublisherPromise = null;

/**
 * Cliente HTTP autenticado (via Application Default Credentials — a
 * própria identidade da Cloud Function) com escopo da Play Developer
 * API. Reaproveitado entre invocações (mesma instância da function),
 * nunca recriado a cada chamada.
 */
function _obterClienteAndroidPublisher() {
  if (!_clienteAndroidPublisherPromise) {
    const auth = new GoogleAuth({
      scopes: ["https://www.googleapis.com/auth/androidpublisher"],
    });
    _clienteAndroidPublisherPromise = auth.getClient();
  }
  return _clienteAndroidPublisherPromise;
}

/**
 * Consulta o estado REAL e atual de uma assinatura na Play Store a
 * partir do `purchaseToken` — nunca do que o app envia sobre si mesmo.
 * @param {string} purchaseToken
 * @return {Promise<object>} corpo de `SubscriptionPurchaseV2`.
 */
async function _consultarAssinaturaNaPlayStore(purchaseToken) {
  const client = await _obterClienteAndroidPublisher();
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/` +
    `${ANDROID_PACKAGE_NAME}/purchases/subscriptionsv2/tokens/` +
    `${encodeURIComponent(purchaseToken)}`;
  const resposta = await client.request({url});
  return resposta.data;
}

/**
 * Decide, a partir da resposta da Play Store, se a assinatura dá direito
 * ao Premium AGORA e até quando.
 * @param {object} assinatura resposta de [_consultarAssinaturaNaPlayStore].
 * @param {string} productIdEsperado
 * @return {{temDireito: boolean, expiryTimeMs: (number|null), motivo: (string|undefined)}}
 */
function _calcularDireitoPremium(assinatura, productIdEsperado) {
  const estado = assinatura.subscriptionState;
  const itemLinha = (assinatura.lineItems || [])
      .find((item) => item.productId === productIdEsperado);

  if (!itemLinha) {
    return {temDireito: false, expiryTimeMs: null, motivo: "produto_nao_encontrado"};
  }

  const expiryTimeMs = Date.parse(itemLinha.expiryTime);
  const expiryValido = !Number.isNaN(expiryTimeMs);

  if (ESTADOS_COM_DIREITO_A_PREMIUM.has(estado)) {
    return {temDireito: true, expiryTimeMs: expiryValido ? expiryTimeMs : null};
  }

  // Cancelada (auto-renovação desligada) mas ainda dentro do período já
  // pago — mantém acesso até a data de expiração, igual qualquer
  // assinatura cancelada em qualquer loja.
  if (estado === "SUBSCRIPTION_STATE_CANCELED" && expiryValido && expiryTimeMs > Date.now()) {
    return {temDireito: true, expiryTimeMs};
  }

  return {temDireito: false, expiryTimeMs: expiryValido ? expiryTimeMs : null, motivo: estado};
}

/**
 * Núcleo compartilhado entre [validarCompraPremium] (self-service, chamada
 * pelo próprio app) e [reconciliarCompraPremiumAdmin] (suporte manual, ver
 * documentação daquela function) — consulta a Play Store, aplica a MESMA
 * checagem antifraude (o token precisa pertencer ao `uid` informado) e só
 * então grava `isPremium`. Essa checagem NUNCA é pulada, nem para o admin:
 * o objetivo da rota administrativa é REPETIR esta verificação real quando
 * ela falhou por um problema de infraestrutura (ex: API do Google ainda
 * propagando após ser habilitada), nunca abrir um atalho sem ela — mantém
 * a mesma garantia antifraude documentada abaixo.
 * @param {{uid: string, purchaseToken: string, productId: string, origem: string}} params
 *   `origem` é só para os logs/mensagens de erro distinguirem quem chamou
 *   (`"self"` = o próprio usuário via app, `"admin"` = reconciliação manual).
 * @return {Promise<{isPremium: boolean, subscriptionState: string, expiryTimeMs: (number|null|undefined)}>}
 */
async function _validarEGravarPremium({uid, purchaseToken, productId, origem}) {
  let assinatura;
  try {
    assinatura = await _consultarAssinaturaNaPlayStore(purchaseToken);
  } catch (e) {
    logger.error(
        `[PremiumPurchase] (${origem}) Falha ao consultar a Play Developer API (uid=${uid}) — ` +
        "verifique se a API está ativada e a conta de serviço tem acesso no Play Console.",
        e,
    );
    throw new HttpsError(
        "unavailable",
        origem === "admin" ?
          // Rota admin: quem chama já está debugando o próprio problema de
          // infraestrutura, então o erro real (ex: "ainda propagando") é
          // mais útil do que a mensagem genérica abaixo.
          `Falha ao consultar a Play Developer API: ${e.message || e}` :
          "Não foi possível validar a compra na Play Store agora. Tente novamente em instantes.",
    );
  }

  // ANTI-FRAUDE: o purchaseToken sozinho prova que ALGUÉM comprou a
  // assinatura, mas não prova que foi ESTE usuário chamando agora — sem
  // esta checagem, um único purchaseToken válido (reaproveitado,
  // vazado ou compartilhado entre contas) poderia ser reenviado por N
  // uids Firebase diferentes, concedendo Premium de graça pra todos
  // eles. O app envia `accountId: uid` como `obfuscatedAccountId` no
  // momento da compra (ver [PurchaseParam] em
  // `premium_purchase_service.dart`) — a Play Store ecoa esse mesmo
  // valor aqui em `externalAccountIdentifiers`, e só seguimos adiante se
  // bater exatamente com o `uid` informado (o autenticado, na rota
  // self-service; o informado pelo admin, na rota de reconciliação).
  const idExternoDaCompra = assinatura.externalAccountIdentifiers &&
    assinatura.externalAccountIdentifiers.obfuscatedExternalAccountId;
  if (idExternoDaCompra !== uid) {
    logger.warn(
        `[PremiumPurchase] (${origem}) Recusada: obfuscatedAccountId da compra ("${idExternoDaCompra}") ` +
        `não bate com o uid esperado ("${uid}").`,
    );
    throw new HttpsError("permission-denied", "Esta compra não pertence a este usuário.");
  }

  const {temDireito, expiryTimeMs, motivo} = _calcularDireitoPremium(assinatura, productId);

  if (!temDireito) {
    logger.info(
        `[PremiumPurchase] (${origem}) Compra de ${uid} validada, mas sem direito a Premium agora ` +
        `(estado=${motivo || assinatura.subscriptionState}).`,
    );
    return {isPremium: false, subscriptionState: assinatura.subscriptionState};
  }

  const camposGravados = {
    isPremium: true,
    premiumProductId: productId,
    premiumPurchaseToken: purchaseToken,
    premiumSubscriptionState: assinatura.subscriptionState,
    premiumExpiryTimeMs: expiryTimeMs,
    premiumValidadoEm: FieldValue.serverTimestamp(),
  };
  // Marcador só informativo (auditoria) — não muda em nada o direito ao
  // Premium, que já foi verificado igual acima; só registra que desta vez
  // a concessão passou pela rota manual, não pelo purchaseStream do app.
  if (origem === "admin") {
    camposGravados.premiumReconciliadoManualmenteEm = FieldValue.serverTimestamp();
  }

  await db.collection("usuarios").doc(uid).set(camposGravados, {merge: true});

  logger.info(
      `[PremiumPurchase] (${origem}) Premium concedido a ${uid} (estado=${assinatura.subscriptionState}, ` +
      `expira em ${expiryTimeMs ? new Date(expiryTimeMs).toISOString() : "?"}).`,
  );

  return {
    isPremium: true,
    subscriptionState: assinatura.subscriptionState,
    expiryTimeMs,
  };
}

/**
 * Callable chamada pelo app assim que o `purchaseStream` entrega uma
 * compra em estado `purchased`/`restored` (ver
 * `PremiumPurchaseService._processarCompra` no Flutter). Valida o
 * `purchaseToken` direto na Play Store e só então concede `isPremium`.
 */
exports.validarCompraPremium = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Requer autenticação.");
  }
  const uid = request.auth.uid;
  const {purchaseToken, productId} = request.data || {};

  if (!purchaseToken || typeof purchaseToken !== "string") {
    throw new HttpsError("invalid-argument", "purchaseToken é obrigatório.");
  }
  if (productId !== PRODUTO_PREMIUM_ID) {
    throw new HttpsError(
        "invalid-argument",
        `productId inválido — esperado "${PRODUTO_PREMIUM_ID}".`,
    );
  }

  return _validarEGravarPremium({uid, purchaseToken, productId, origem: "self"});
});

/**
 * Reconciliação MANUAL de uma compra Premium — rota de suporte/admin para
 * os casos em que [validarCompraPremium] falhou por um problema de
 * INFRAESTRUTURA (não de fraude/direito): o exemplo real que motivou esta
 * function foi a Play Developer API ainda propagando logo após ser
 * habilitada no Cloud Console (ver comentário no topo do arquivo), que fez
 * o app receber "Não foi possível confirmar sua assinatura agora" mesmo
 * com a compra genuína e já paga do lado da Play Store.
 *
 * NÃO é uma forma de conceder Premium sem verificação — roda exatamente a
 * mesma consulta real à Play Store e a mesma checagem antifraude de
 * [validarCompraPremium] (ver [_validarEGravarPremium]), só que acionada
 * por um admin informando `uid` + `purchaseToken` em vez de pelo próprio
 * app. Mantém a DECISÃO DELIBERADA de `planoAdminService.js` (aquele
 * módulo nunca concede Premium sem verificação) — esta function não é
 * parte dele, propositalmente: aqui SEMPRE há uma verificação real contra
 * a Play Store antes de qualquer gravação.
 *
 * O `purchaseToken` não fica salvo em lugar nenhum quando a validação
 * falha (só é gravado em `usuarios/{uid}` em caso de sucesso) — quem for
 * reconciliar precisa obter o token de outra forma (ex: logs do
 * dispositivo do próprio usuário, `adb logcat` durante uma nova tentativa
 * de compra/restore, ou pedir para o usuário reabrir o app, que já
 * reenvia o mesmo token automaticamente via `restorePurchases()` a cada
 * boot — ver `PremiumPurchaseService.iniciar()` no Flutter).
 */
exports.reconciliarCompraPremiumAdmin = onCall(async (request) => {
  if (!_ehAdmin(request)) {
    throw new HttpsError("permission-denied", "Apenas admin.");
  }

  const {uid, purchaseToken, productId} = request.data || {};
  if (!uid || typeof uid !== "string") {
    throw new HttpsError("invalid-argument", "uid é obrigatório.");
  }
  if (!purchaseToken || typeof purchaseToken !== "string") {
    throw new HttpsError("invalid-argument", "purchaseToken é obrigatório.");
  }
  const productIdFinal = typeof productId === "string" && productId ?
    productId : PRODUTO_PREMIUM_ID;

  const usuarioSnap = await db.collection("usuarios").doc(uid).get();
  if (!usuarioSnap.exists) {
    throw new HttpsError("not-found", "Usuário não encontrado.");
  }

  const resultado = await _validarEGravarPremium({
    uid,
    purchaseToken,
    productId: productIdFinal,
    origem: "admin",
  });

  logger.info(
      `[PremiumPurchase] (admin) Reconciliação manual disparada por ${request.auth.uid} ` +
      `para uid=${uid} — resultado: isPremium=${resultado.isPremium}.`,
  );

  return resultado;
});

/**
 * Rede de segurança contra o LIMITE HONESTO documentado no topo do
 * arquivo (sem RTDN): reverifica, uma vez por dia, todo usuário
 * atualmente `isPremium: true` que tenha um `premiumPurchaseToken`
 * registrado (ou seja, concedido por [validarCompraPremium] — Premium
 * concedido manualmente pelo Console do Firebase não tem token e é
 * ignorado aqui, de propósito, para nunca revogar uma concessão manual).
 * Uma assinatura que expirou, foi cancelada (após o fim do período pago)
 * ou entrou em pagamento recusado sem grace period tem `isPremium`
 * revertido para `false` automaticamente.
 */
exports.reverificarAssinaturasPremium = onSchedule(
    {
      schedule: "every 24 hours",
      timeZone: "America/Sao_Paulo",
    },
    async () => {
      const premiumComToken = await db.collection("usuarios")
          .where("isPremium", "==", true)
          .get();

      if (premiumComToken.empty) {
        logger.info("[PremiumPurchase] Nenhum usuário Premium para reverificar.");
        return;
      }

      let revogados = 0;
      let mantidos = 0;
      let ignorados = 0;

      for (const doc of premiumComToken.docs) {
        const dados = doc.data();
        const token = dados.premiumPurchaseToken;
        if (!token) {
          // Premium sem purchaseToken registrado = concedido manualmente
          // pelo Console do Firebase (ver planoAdminService.js) — este
          // job só reverifica compras reais feitas via Play Billing.
          ignorados++;
          continue;
        }

        const productId = dados.premiumProductId || PRODUTO_PREMIUM_ID;
        try {
          const assinatura = await _consultarAssinaturaNaPlayStore(token);
          const {temDireito, expiryTimeMs} = _calcularDireitoPremium(assinatura, productId);

          if (!temDireito) {
            await doc.ref.set({
              isPremium: false,
              premiumSubscriptionState: assinatura.subscriptionState,
              premiumRevogadoEm: FieldValue.serverTimestamp(),
            }, {merge: true});
            logger.info(
                `[PremiumPurchase] Premium revogado de ${doc.id} na reverificação ` +
                `diária (estado=${assinatura.subscriptionState}).`,
            );
            revogados++;
          } else {
            await doc.ref.set({
              premiumSubscriptionState: assinatura.subscriptionState,
              premiumExpiryTimeMs: expiryTimeMs,
            }, {merge: true});
            mantidos++;
          }
        } catch (e) {
          // Falha de rede/API não deve derrubar o Premium de ninguém —
          // mesma filosofia permissiva do resto do app: uma falha
          // técnica na reverificação nunca, por si só, tira o acesso de
          // quem pagou. Só loga e tenta de novo amanhã.
          logger.error(
              `[PremiumPurchase] Falha ao reverificar a assinatura de ${doc.id} — mantido como estava.`,
              e,
          );
        }
      }

      logger.info(
          `[PremiumPurchase] Reverificação diária concluída: ${mantidos} mantido(s), ` +
          `${revogados} revogado(s), ${ignorados} ignorado(s) (Premium manual/sem token).`,
      );
    },
);
