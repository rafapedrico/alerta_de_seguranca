/**
 * Purga DEFINITIVA do histórico de alertas de emergência (localizações e
 * fotografias associadas) retido após a exclusão de uma conta.
 *
 * RETENÇÃO DELIBERADA DE 30 DIAS (reespecificação do usuário, 2026-09-04
 * — ver `website/exclusao-dados.html`/`privacidade.html` e
 * `excluirContaItemHistorico` no app Flutter): quando o usuário exclui a
 * própria conta, `usuarios/{uid}/alertas/*` e as fotos do SOS em
 * `sos_fotos/{uid}/` no Storage NÃO são apagados na hora (ver
 * `exclusaoContaService.js::excluirDadosFirestore` — decisão explícita,
 * mesma lógica de proteção já usada para o chat de Suporte/auditoria:
 * impedir que um agressor apague evidências ao excluir a conta). Este
 * histórico só é apagado de verdade aqui, 30 dias depois, servindo de
 * prova em caso de incidentes durante esse período.
 *
 * Roda em horário fixo (mesmo padrão de `monitoramentoExpiracaoMonitor.js`/
 * `scheduledAlarmMonitor.js`) e decide, ela mesma, quais contas já
 * passaram do prazo — consulta `contas_excluidas` (gravado por
 * `exclusaoContaService.js::registrarRevogacao` no momento da exclusão)
 * em vez de depender de qualquer timer/callback disparado no instante
 * exato da exclusão, que poderia se perder se a function não estivesse
 * disponível naquele momento.
 */

const {onSchedule} = require("firebase-functions/v2/scheduler");
const {getFirestore} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const {
  excluirHistoricoAlertas,
  excluirArquivosStorage,
} = require("./exclusaoContaService");

const db = getFirestore();

const DIAS_DE_RETENCAO = 30;
const MS_POR_DIA = 24 * 60 * 60 * 1000;

/**
 * Roda uma vez por dia: busca toda conta excluída (`contas_excluidas`)
 * cujo prazo de retenção de 30 dias já tenha vencido e cuja purga ainda
 * não tenha sido processada, apaga o histórico de alertas (Firestore) e
 * as fotos do SOS (Storage) daquele uid, e marca `retencaoProcessada:
 * true` — nunca reprocessa a mesma conta duas vezes.
 */
exports.purgarHistoricoRetidoAposExclusao = onSchedule(
    {
      schedule: "every 24 hours",
      timeZone: "America/Sao_Paulo",
    },
    async () => {
      const corteMs = Date.now() - DIAS_DE_RETENCAO * MS_POR_DIA;

      const vencidas = await db
          .collection("contas_excluidas")
          .where("retencaoProcessada", "==", false)
          .where("excluidoEmMs", "<=", corteMs)
          .get();

      if (vencidas.empty) {
        logger.info("[RetencaoAlertas] Nenhuma conta com retenção de 30 dias vencida hoje.");
        return;
      }

      logger.info(
          `[RetencaoAlertas] ${vencidas.size} conta(s) com retenção vencida — ` +
          "purgando histórico de alertas/fotos definitivamente.",
      );

      for (const doc of vencidas.docs) {
        const uid = doc.id;
        try {
          await excluirHistoricoAlertas(uid);
        } catch (e) {
          logger.error(`[RetencaoAlertas] Falha ao apagar histórico de alertas de ${uid} (Firestore):`, e);
          // Não marca como processado — tenta de novo na próxima execução
          // diária, em vez de deixar o histórico retido para sempre.
          continue;
        }

        try {
          await excluirArquivosStorage(uid);
        } catch (e) {
          // Best-effort: uma falha aqui não deve impedir a marcação de
          // "processado" — o Firestore (a parte mais sensível/estruturada
          // do histórico) já foi apagado com sucesso acima; mídias órfãs
          // no Storage são um problema bem menor, registrado no log para
          // limpeza manual se necessário.
          logger.error(`[RetencaoAlertas] Falha ao apagar fotos do SOS de ${uid} (Storage):`, e);
        }

        try {
          await doc.ref.set({
            retencaoProcessada: true,
            retencaoProcessadaEm: new Date().toISOString(),
          }, {merge: true});
        } catch (e) {
          logger.error(`[RetencaoAlertas] Falha ao marcar retenção de ${uid} como processada:`, e);
        }

        logger.info(`[RetencaoAlertas] Histórico de alertas/fotos de ${uid} purgado definitivamente (30 dias de retenção concluídos).`);
      }
    },
);
