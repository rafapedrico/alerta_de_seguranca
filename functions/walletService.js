/**
 * Camada de acesso à Carteira em USD (`usuarios/{uid}.saldoUsd` +
 * subcoleção `usuarios/{uid}/historicoCreditos`) — ÚNICO ponto do backend
 * autorizado a alterar `saldoUsd` (as regras do Firestore bloqueiam
 * qualquer escrita desse campo vinda do app cliente, ver
 * `firestore.rules`). Usada tanto pelo job de transbordo
 * (`transbordoWhatsappMonitor.js`, débito de $0.10 por WhatsApp) quanto
 * pela verificação de compra (`comprasService.js`, crédito de recarga).
 */

const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const {CUSTO_WHATSAPP_USD} = require("./constantes");

const db = getFirestore();

/**
 * Debita [CUSTO_WHATSAPP_USD] do saldo de [usuarioId] e registra o
 * desconto em `historicoCreditos`, de forma atômica (transação): nunca
 * deixa o saldo ficar negativo, mesmo sob concorrência (vários contatos
 * de um mesmo alerta sendo processados em paralelo). Retorna
 * `{sucesso: true}` ou `{sucesso: false, motivo}` — nunca lança exceção.
 *
 * @param {string} usuarioId
 * @param {{nome?: string, telefone?: string}} contato
 * @param {string} idEntregaAlerta
 * @return {Promise<{sucesso: boolean, motivo?: string}>}
 */
async function debitarSaldo(usuarioId, contato, idEntregaAlerta) {
  const usuarioRef = db.collection("usuarios").doc(usuarioId);
  const historicoRef = usuarioRef.collection("historicoCreditos").doc();

  try {
    return await db.runTransaction(async (tx) => {
      const usuarioSnap = await tx.get(usuarioRef);
      const saldoAtual = (usuarioSnap.exists && usuarioSnap.data().saldoUsd) || 0;

      if (saldoAtual < CUSTO_WHATSAPP_USD) {
        return {sucesso: false, motivo: "saldo_insuficiente"};
      }

      tx.update(usuarioRef, {
        saldoUsd: FieldValue.increment(-CUSTO_WHATSAPP_USD),
      });
      tx.set(historicoRef, {
        tipo: "desconto",
        valorUsd: -CUSTO_WHATSAPP_USD,
        descricao: `Envio de WhatsApp de contingência para ${contato.nome || contato.telefone || "contato"}`,
        contato: {nome: contato.nome || "", telefone: contato.telefone || ""},
        idEntregaAlerta,
        criadoEm: FieldValue.serverTimestamp(),
      });

      return {sucesso: true};
    });
  } catch (e) {
    logger.error(`[walletService] Falha ao debitar saldo de ${usuarioId}`, e);
    return {sucesso: false, motivo: "erro_interno"};
  }
}

/**
 * Credita [valorUsd] ao saldo de [usuarioId], de forma IDEMPOTENTE por
 * [purchaseToken]: usa o próprio token da compra como id determinístico
 * do documento em `historicoCreditos`, então uma segunda tentativa de
 * confirmar a MESMA compra (ex: retry de rede do app) nunca credita duas
 * vezes. Retorna `{sucesso: true}` ou `{sucesso: false, motivo}`.
 *
 * @param {string} usuarioId
 * @param {number} valorUsd
 * @param {string} produtoId
 * @param {string} purchaseToken
 * @return {Promise<{sucesso: boolean, motivo?: string}>}
 */
async function creditarSaldo(usuarioId, valorUsd, produtoId, purchaseToken) {
  const usuarioRef = db.collection("usuarios").doc(usuarioId);
  // Ids de documento no Firestore não podem conter "/" — sanitiza o
  // purchaseToken (que pode conter caracteres especiais) preservando a
  // unicidade.
  const idHistorico = `compra_${purchaseToken.replace(/[/]/g, "_")}`;
  const historicoRef = usuarioRef.collection("historicoCreditos").doc(idHistorico);

  try {
    return await db.runTransaction(async (tx) => {
      const historicoSnap = await tx.get(historicoRef);
      if (historicoSnap.exists) {
        return {sucesso: false, motivo: "compra_ja_processada"};
      }

      tx.set(historicoRef, {
        tipo: "recarga",
        valorUsd,
        descricao: `Recarga de créditos (${produtoId})`,
        produtoId,
        purchaseToken,
        criadoEm: FieldValue.serverTimestamp(),
      });
      tx.set(usuarioRef, {
        saldoUsd: FieldValue.increment(valorUsd),
      }, {merge: true});

      return {sucesso: true};
    });
  } catch (e) {
    logger.error(`[walletService] Falha ao creditar saldo de ${usuarioId}`, e);
    return {sucesso: false, motivo: "erro_interno"};
  }
}

module.exports = {
  debitarSaldo,
  creditarSaldo,
};
