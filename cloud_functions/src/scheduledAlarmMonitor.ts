/**
 * ESBOÇO (draft) — monitoramento agendado dos alarmes de rotina via
 * Firestore, camada de resiliência PARALELA ao alarme local
 * (`android_alarm_manager_plus` + `RotinaAlarmeService` no app Flutter).
 *
 * Diferente de `functions/index.js` (que REAGE a um evento já gravado
 * pelo app, `onDocumentCreated`), esta função roda em HORÁRIO FIXO
 * (`onSchedule`) e ela mesma decide, a cada execução, se algum alarme
 * passou do prazo sem confirmação — cobrindo o cenário em que o aparelho
 * é destruído/desligado/perde sinal antes do fluxo local conseguir agir.
 *
 * Ver `cloud_functions/README.md` para o modelo de dados completo e como
 * sair do estado de esboço (esta pasta NÃO é implantada hoje — o
 * `firebase.json` da raiz só aponta para `functions/`).
 */

import {onSchedule} from "firebase-functions/v2/scheduler";
import {initializeApp, getApps} from "firebase-admin/app";
import {getFirestore, Timestamp} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";
import * as logger from "firebase-functions/logger";

if (getApps().length === 0) {
  initializeApp();
}
const db = getFirestore();

const COLECAO_ALARMES_AGENDADOS = "alarmes_agendados";

const STATUS_PENDENTE = "PENDENTE";
const STATUS_CONFIRMADO_SEGURA = "CONFIRMADO_SEGURA";
const STATUS_ALERTA_DISPARADO = "ALERTA_DISPARADO";

interface UltimaLocalizacao {
  lat?: number;
  lng?: number;
  timestamp?: Timestamp;
}

interface AlarmeAgendadoDoc {
  idAlarme: string;
  dataHoraDisparo: Timestamp;
  status: string;
  ultimaLocalizacao?: UltimaLocalizacao;
  telefonesEmergencia?: string[];
  tokensGuardioes?: string[];
}

/**
 * TODO (gateway de SMS): mesmo TODO explícito já documentado em
 * `functions/index.js` — ainda NÃO envia SMS de verdade, apenas loga o
 * que seria enviado. Requer plano Blaze + credenciais Twilio (ou outro
 * gateway) nas variáveis de ambiente da função. Nunca deixe a falha de
 * UM contato interromper o envio aos demais (try/catch por contato).
 *
 * Exemplo de integração futura com Twilio (pseudo-código):
 *   const accountSid = process.env.TWILIO_ACCOUNT_SID;
 *   const authToken = process.env.TWILIO_AUTH_TOKEN;
 *   const numeroRemetente = process.env.TWILIO_FROM_NUMBER;
 *   const twilio = require("twilio")(accountSid, authToken);
 *   for (const telefone of telefones) {
 *     try {
 *       await twilio.messages.create({to: telefone, from: numeroRemetente, body: mensagem});
 *     } catch (e) {
 *       logger.error(`Falha ao enviar SMS para ${telefone}`, e);
 *     }
 *   }
 */
async function enviarSmsParaTelefones(
    telefones: string[],
    mensagem: string,
): Promise<void> {
  if (telefones.length === 0) return;
  logger.warn(
      "[enviarSmsParaTelefones] Gateway de SMS ainda NAO configurado " +
      "(TODO) - mensagem NAO foi enviada de verdade. " +
      `Destinatarios: ${JSON.stringify(telefones)}. Mensagem: ${mensagem}`,
  );
}

/**
 * Notificação App-para-App aos "guardiões" (contatos com o app
 * instalado) via FCM multicast. Best-effort: um token inválido/expirado
 * nunca deve derrubar o processamento do alarme inteiro.
 */
async function notificarGuardioesPorFcm(
    tokens: string[],
    titulo: string,
    corpo: string,
): Promise<void> {
  if (tokens.length === 0) return;
  try {
    const resposta = await getMessaging().sendEachForMulticast({
      tokens,
      notification: {title: titulo, body: corpo},
    });
    logger.info(
        `[notificarGuardioesPorFcm] ${resposta.successCount} enviado(s), ` +
        `${resposta.failureCount} falha(s) de ${tokens.length} token(s).`,
    );
  } catch (e) {
    logger.error("[notificarGuardioesPorFcm] Falha ao enviar multicast FCM", e);
  }
}

function montarLinkGoogleMaps(lat: number, lng: number): string {
  return `https://maps.google.com/?q=${lat},${lng}`;
}

function montarTextoLocalizacao(localizacao?: UltimaLocalizacao): string {
  if (typeof localizacao?.lat === "number" && typeof localizacao?.lng === "number") {
    return `Latitude: ${localizacao.lat}, Longitude: ${localizacao.lng} ` +
        `(${montarLinkGoogleMaps(localizacao.lat, localizacao.lng)})`;
  }
  return "Localização indisponível (nenhum heartbeat registrado para este alarme).";
}

/**
 * Roda a cada 5 minutos (mesmo intervalo do heartbeat do app, ver
 * `BackgroundLocationHeartbeatService`): busca todo documento
 * `alarmes_agendados` ainda PENDENTE cujo `dataHoraDisparo` já passou —
 * ou seja, o usuário não confirmou o check-in ("Cheguei bem") a tempo,
 * segundo a nuvem — e dispara o alerta de emergência via nuvem
 * (FCM + SMS), independente do que o fluxo local no aparelho conseguiu
 * ou não fazer.
 */
export const monitorarAlarmesAgendados = onSchedule(
    {schedule: "every 5 minutes", timeZone: "America/Sao_Paulo"},
    async () => {
      const agora = Timestamp.now();

      const pendentesVencidos = await db
          .collection(COLECAO_ALARMES_AGENDADOS)
          .where("status", "==", STATUS_PENDENTE)
          .where("dataHoraDisparo", "<=", agora)
          .get();

      if (pendentesVencidos.empty) {
        logger.info("Nenhum alarme agendado vencido sem confirmação.");
        return;
      }

      logger.info(
          `${pendentesVencidos.size} alarme(s) agendado(s) vencido(s) sem ` +
          "confirmação — disparando alerta.",
      );

      for (const doc of pendentesVencidos.docs) {
        const dados = doc.data() as AlarmeAgendadoDoc;

        try {
          // Reconfirma o status DENTRO de uma transação antes de agir —
          // evita corrida com o app gravando CONFIRMADO_SEGURA quase no
          // mesmo instante desta execução agendada.
          const disparouAgora = await db.runTransaction(async (tx) => {
            const snapAtual = await tx.get(doc.ref);
            const statusAtual = snapAtual.data()?.status;
            if (statusAtual !== STATUS_PENDENTE) return false;

            tx.update(doc.ref, {
              status: STATUS_ALERTA_DISPARADO,
              alertaDisparadoEm: Timestamp.now(),
            });
            return true;
          });

          if (!disparouAgora) {
            logger.info(
                `Alarme #${dados.idAlarme} já não estava mais PENDENTE ` +
                "no momento da checagem — ignorado (corrida evitada).",
            );
            continue;
          }

          const localizacaoTexto = montarTextoLocalizacao(dados.ultimaLocalizacao);
          const mensagem =
              "🚨 ALERTA DE SEGURANÇA (monitoramento agendado): o check-in " +
              `do alarme de rotina #${dados.idAlarme} não foi confirmado a ` +
              `tempo.\nLocalização: ${localizacaoTexto}`;

          await Promise.allSettled([
            enviarSmsParaTelefones(dados.telefonesEmergencia ?? [], mensagem),
            notificarGuardioesPorFcm(
                dados.tokensGuardioes ?? [],
                "Alerta de segurança",
                mensagem,
            ),
          ]);
        } catch (e) {
          // Nunca deixa a falha de UM alarme interromper o processamento
          // dos demais nesta execução.
          logger.error(`Falha ao processar alarme agendado #${dados.idAlarme}`, e);
        }
      }
    },
);

/**
 * Fica registrado aqui apenas como documentação de referência cruzada —
 * quando o app grava `CONFIRMADO_SEGURA` (ver
 * `RotinaAlarmeService.confirmarCheckinRotina`), esta função agendada
 * simplesmente vai IGNORAR o documento na próxima execução (o filtro
 * `where("status", "==", STATUS_PENDENTE)` já exclui), sem precisar de
 * nenhum trigger adicional.
 */
export const _STATUS_REFERENCIA = {
  STATUS_PENDENTE,
  STATUS_CONFIRMADO_SEGURA,
  STATUS_ALERTA_DISPARADO,
};
