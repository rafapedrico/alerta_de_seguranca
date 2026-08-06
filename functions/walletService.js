/**
 * Camada de acesso à Carteira de Créditos (`usuarios/{uid}.creditosDisponiveis`
 * + subcoleção `usuarios/{uid}/historicoCreditos`) — ÚNICO ponto do backend
 * autorizado a alterar `creditosDisponiveis` (as regras do Firestore
 * bloqueiam qualquer escrita desse campo vinda do app cliente, ver
 * `firestore.rules`).
 *
 * IMPORTANTE: `creditosDisponiveis` é uma contagem de UNIDADES DE
 * DISPARO (1 crédito = 1 envio de WhatsApp de contingência) — NUNCA
 * moeda financeira. Não há conversão de câmbio, símbolo de moeda nem
 * casas decimais aqui; sempre um número inteiro de créditos.
 *
 * Usada tanto pelo job de transbordo (`transbordoWhatsappMonitor.js`,
 * débito de 1 crédito por WhatsApp) quanto pela verificação de compra
 * (`comprasService.js`, crédito do pacote comprado).
 */

const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const {CUSTO_WHATSAPP_CREDITOS} = require("./constantes");

const db = getFirestore();

/**
 * Debita [CUSTO_WHATSAPP_CREDITOS] créditos de [usuarioId] e registra o
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
      const creditosAtuais =
          (usuarioSnap.exists && usuarioSnap.data().creditosDisponiveis) || 0;

      if (creditosAtuais < CUSTO_WHATSAPP_CREDITOS) {
        return {sucesso: false, motivo: "creditos_insuficientes"};
      }

      tx.update(usuarioRef, {
        creditosDisponiveis: FieldValue.increment(-CUSTO_WHATSAPP_CREDITOS),
      });
      tx.set(historicoRef, {
        tipo: "desconto",
        quantidadeCreditos: -CUSTO_WHATSAPP_CREDITOS,
        descricao: `Envio de WhatsApp de contingência para ${contato.nome || contato.telefone || "contato"}`,
        contato: {nome: contato.nome || "", telefone: contato.telefone || ""},
        idEntregaAlerta,
        criadoEm: FieldValue.serverTimestamp(),
      });

      return {sucesso: true};
    });
  } catch (e) {
    logger.error(`[walletService] Falha ao debitar créditos de ${usuarioId}`, e);
    return {sucesso: false, motivo: "erro_interno"};
  }
}

/**
 * Credita [quantidadeCreditos] créditos a [usuarioId], de forma
 * IDEMPOTENTE por [purchaseToken]: usa o próprio token da compra como
 * id determinístico do documento em `historicoCreditos`, então uma
 * segunda tentativa de confirmar a MESMA compra (ex: retry de rede do
 * app) nunca credita duas vezes. Retorna `{sucesso: true}` ou
 * `{sucesso: false, motivo}`.
 *
 * @param {string} usuarioId
 * @param {number} quantidadeCreditos
 * @param {string} produtoId
 * @param {string} purchaseToken
 * @return {Promise<{sucesso: boolean, motivo?: string}>}
 */
async function creditarSaldo(usuarioId, quantidadeCreditos, produtoId, purchaseToken) {
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
        quantidadeCreditos,
        descricao: `Recarga de ${quantidadeCreditos} créditos (${produtoId})`,
        produtoId,
        purchaseToken,
        criadoEm: FieldValue.serverTimestamp(),
      });
      tx.set(usuarioRef, {
        creditosDisponiveis: FieldValue.increment(quantidadeCreditos),
      }, {merge: true});

      return {sucesso: true};
    });
  } catch (e) {
    logger.error(`[walletService] Falha ao creditar créditos de ${usuarioId}`, e);
    return {sucesso: false, motivo: "erro_interno"};
  }
}

module.exports = {
  debitarSaldo,
  creditarSaldo,
};
