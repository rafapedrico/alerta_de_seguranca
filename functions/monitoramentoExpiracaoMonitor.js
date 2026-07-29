/**
 * Expiração automática das solicitações de monitoramento de localização
 * não respondidas — regra das 24h (ver `monitoramentoService.js`).
 *
 * Cobre exatamente o cenário de resiliência pedido: se o aparelho do
 * destinatário estiver offline/inacessível no momento da solicitação, o
 * documento `permissoes_monitoramento` permanece "pendente" na nuvem —
 * quando o destinatário reconectar (e o app reabrir/sincronizar), a
 * solicitação ainda está lá para ser respondida, DESDE QUE dentro da
 * janela de 24h. Esta função roda em horário fixo e decide, ela mesma, se
 * algum pedido passou do prazo, independente de o app do destinatário
 * jamais ter processado o Push (mesmo padrão de
 * `scheduledAlarmMonitor.js`: reage a estado, não a evento).
 */

const {onSchedule} = require("firebase-functions/v2/scheduler");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const {
  COLECAO_PERMISSOES,
  STATUS_PENDENTE,
  STATUS_EXPIRADO,
  enviarFcmMonitoramento,
} = require("./monitoramentoService");

const db = getFirestore();

/**
 * Roda a cada 15 minutos: busca toda permissão ainda "pendente" cujo
 * `expiraEm` já passou e marca "expirado", notificando o solicitante.
 * Reconfirma o status DENTRO de uma transação antes de agir — evita
 * corrida com o alvo aprovando/negando quase no mesmo instante desta
 * execução.
 */
exports.monitorarExpiracaoMonitoramento = onSchedule(
    {
      schedule: "every 15 minutes",
      timeZone: "America/Sao_Paulo",
    },
    async () => {
      const agora = Timestamp.now();

      const pendentesVencidas = await db
          .collection(COLECAO_PERMISSOES)
          .where("status", "==", STATUS_PENDENTE)
          .where("expiraEm", "<=", agora)
          .get();

      if (pendentesVencidas.empty) {
        logger.info("Nenhuma solicitação de monitoramento pendente vencida.");
        return;
      }

      logger.info(
          `${pendentesVencidas.size} solicitação(ões) de monitoramento ` +
          "vencida(s) sem resposta — expirando.",
      );

      for (const doc of pendentesVencidas.docs) {
        const dados = doc.data();

        try {
          const expirouAgora = await db.runTransaction(async (tx) => {
            const snapAtual = await tx.get(doc.ref);
            const statusAtual = snapAtual.data() && snapAtual.data().status;
            if (statusAtual !== STATUS_PENDENTE) return false;

            tx.update(doc.ref, {
              status: STATUS_EXPIRADO,
              atualizadoEm: Timestamp.now(),
            });
            return true;
          });

          if (!expirouAgora) {
            logger.info(
                `Permissão ${doc.id} já não estava mais pendente no momento ` +
                "da checagem — ignorada (corrida evitada).",
            );
            continue;
          }

          await enviarFcmMonitoramento(dados.uidSolicitante, "monitoramento_expirado", {
            idPermissao: doc.id,
            uidAlvo: dados.uidAlvo,
            nomeAlvo: dados.nomeAlvo || "",
          });
        } catch (e) {
          logger.error(`Falha ao expirar a permissão de monitoramento ${doc.id}`, e);
        }
      }
    },
);
