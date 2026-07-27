/**
 * Monitoramento agendado dos alarmes de rotina via Firestore — camada de
 * resiliência PARALELA ao alarme local (`android_alarm_manager_plus` +
 * `RotinaAlarmeService` no app Flutter).
 *
 * Diferente de `aoReceberAlertaTentativaDesarme` em `index.js` (que REAGE
 * a um evento já gravado pelo app, `onDocumentCreated`), esta função roda
 * em HORÁRIO FIXO (`onSchedule`) e ela mesma decide, a cada execução, se
 * algum alarme passou do prazo sem confirmação — cobrindo o cenário em
 * que o aparelho é destruído/desligado/perde sinal antes do fluxo local
 * conseguir agir.
 *
 * Modelo de dados (coleção `alarmes_agendados/{idAlarme}`, ver
 * `AlarmeAgendadoModel` no app Flutter,
 * `lib/models/alarme_agendado_model.dart`):
 *   idAlarme: string
 *   dataHoraDisparo: Timestamp
 *   prazoFinalEpochMs: number (dataHoraDisparo + tolerância + janela final)
 *   status: "PENDENTE" | "CONFIRMADO_SEGURA" | "ALERTA_DISPARADO"
 *   ultimaLocalizacao: { lat, lng, timestamp }
 *   telefonesEmergencia: string[]
 *   tokensGuardioes: string[]
 *   etiqueta: string
 *   contextoPersonalizado: string
 *
 * Ciclo de vida do `status` (escrito por três atores diferentes):
 * 1. App (heartbeat) — `BackgroundLocationHeartbeatService` cria/atualiza
 *    o documento como PENDENTE a cada 2 min, sempre que faltar ≤48h para
 *    o próximo disparo de um alarme de rotina ativo (só anexa
 *    `ultimaLocalizacao` quando faltar ≤2h — dead man's switch com
 *    registro antecipado, localização só quando realmente relevante).
 * 2. App (PIN correto) — `RotinaAlarmeService.confirmarCheckinRotina`
 *    marca CONFIRMADO_SEGURA imediatamente ao digitar o PIN certo.
 * 3. Esta função — se encontrar um documento PENDENTE cujo
 *    `prazoFinalEpochMs` já passou (o MESMO instante em que o alerta
 *    real dispararia localmente — dataHoraDisparo + tolerância + janela
 *    final, não o horário bruto do alarme), marca ALERTA_DISPARADO e
 *    dispara o alerta (FCM para `tokensGuardioes` + WhatsApp/Twilio para
 *    `telefonesEmergencia`).
 */

const {onSchedule} = require("firebase-functions/v2/scheduler");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");
const {enviarSmsParaTelefones, TWILIO_SECRETS} = require("./smsGateway");

const db = getFirestore();

const COLECAO_ALARMES_AGENDADOS = "alarmes_agendados";
const STATUS_PENDENTE = "PENDENTE";
const STATUS_ALERTA_DISPARADO = "ALERTA_DISPARADO";

/**
 * Notificação App-para-App aos "guardiões" (contatos com o app
 * instalado) via FCM multicast. Best-effort: um token inválido/expirado
 * nunca deve derrubar o processamento do alarme inteiro.
 *
 * @param {Array<string>} tokens
 * @param {string} titulo
 * @param {string} corpo
 */
async function notificarGuardioesPorFcm(tokens, titulo, corpo) {
  if (!tokens || tokens.length === 0) return;
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

/**
 * Janela de frescor da localização: uma `ultimaLocalizacao` só é
 * considerada válida para o alerta se tiver sido gravada dentro deste
 * período antes de AGORA — mesma janela de 2h usada pelo app
 * (`janelaLocalizacao2h`, ver `BackgroundLocationHeartbeatService`) para
 * decidir quando anexar GPS ao documento.
 */
const JANELA_LOCALIZACAO_MS = 2 * 60 * 60 * 1000;

/**
 * @param {number} lat
 * @param {number} lng
 * @return {string}
 */
function montarLinkGoogleMaps(lat, lng) {
  return `https://maps.google.com/?q=${lat},${lng}`;
}

/**
 * Monta o trecho de localização da mensagem de alerta. Se não houver
 * `ultimaLocalizacao` registrada, OU se ela estiver mais velha que
 * [JANELA_LOCALIZACAO_MS] (aparelho sem sinal/destruído antes mesmo do
 * heartbeat conseguir gravar uma leitura recente), usa o aviso explícito
 * pedido na especificação em vez de um link de mapa desatualizado ou
 * ausente.
 *
 * @param {{lat?: number, lng?: number, timestamp?: FirebaseFirestore.Timestamp}|undefined} localizacao
 * @return {string}
 */
function montarTextoLocalizacao(localizacao) {
  const temCoordenadas = localizacao &&
      typeof localizacao.lat === "number" &&
      typeof localizacao.lng === "number";

  if (!temCoordenadas) {
    return "Não foi possível obter a localização em tempo real devido à " +
        "ausência de sinal ou comunicação do aparelho nas 2 horas " +
        "anteriores ao horário programado.";
  }

  const idadeMs = localizacao.timestamp ?
    Date.now() - localizacao.timestamp.toDate().getTime() :
    null;
  if (idadeMs !== null && idadeMs > JANELA_LOCALIZACAO_MS) {
    return "Não foi possível obter a localização em tempo real devido à " +
        "ausência de sinal ou comunicação do aparelho nas 2 horas " +
        "anteriores ao horário programado.";
  }

  return `Latitude: ${localizacao.lat}, Longitude: ${localizacao.lng} ` +
      `(${montarLinkGoogleMaps(localizacao.lat, localizacao.lng)})`;
}

/**
 * Roda a cada 2 minutos (mesmo intervalo do heartbeat do app, ver
 * `BackgroundLocationHeartbeatService`): busca todo documento
 * `alarmes_agendados` ainda PENDENTE cujo `prazoFinalEpochMs` (horário +
 * tolerância + janela final) já passou — ou seja, o check-in não foi
 * confirmado a tempo, segundo a nuvem — e dispara o alerta de emergência
 * via nuvem (FCM + WhatsApp/Twilio), independente do que o fluxo local
 * no aparelho conseguiu ou não fazer.
 */
exports.monitorarAlarmesAgendados = onSchedule(
    {
      schedule: "every 2 minutes",
      timeZone: "America/Sao_Paulo",
      secrets: TWILIO_SECRETS,
    },
    async () => {
      const agoraEpochMs = Date.now();

      const pendentesVencidos = await db
          .collection(COLECAO_ALARMES_AGENDADOS)
          .where("status", "==", STATUS_PENDENTE)
          .where("prazoFinalEpochMs", "<=", agoraEpochMs)
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
        const dados = doc.data();

        try {
          // Reconfirma o status DENTRO de uma transação antes de agir —
          // evita corrida com o app gravando CONFIRMADO_SEGURA quase no
          // mesmo instante desta execução agendada.
          const disparouAgora = await db.runTransaction(async (tx) => {
            const snapAtual = await tx.get(doc.ref);
            const statusAtual = snapAtual.data() && snapAtual.data().status;
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
          const etiqueta = dados.etiqueta || "Alarme de rotina";
          const contexto = dados.contextoPersonalizado || "";

          const mensagem =
              "🚨 ALERTA DE SEGURANÇA (monitoramento agendado): o check-in " +
              `do alarme de rotina #${dados.idAlarme} não foi confirmado a ` +
              `tempo.\nEtiqueta: ${etiqueta}` +
              (contexto ? `\nContexto: ${contexto}` : "") +
              `\nLocalização: ${localizacaoTexto}`;

          await Promise.allSettled([
            enviarSmsParaTelefones(dados.telefonesEmergencia || [], mensagem),
            notificarGuardioesPorFcm(
                dados.tokensGuardioes || [],
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
