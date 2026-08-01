/**
 * Job agendado (polling a cada 1 minuto) responsável pelo "transbordo" do
 * pipeline híbrido de alerta: 60s depois de um Push FCM ter sido
 * disparado (ver `alertaHibridoService.js`), decide — contato por
 * contato — se vale a pena (e é seguro) cobrar do usuário o envio de
 * WhatsApp de contingência via Twilio.
 *
 * Escolhido em vez de um `await sleep(60s)` dentro da própria function
 * reativa por decisão explícita do usuário: reaproveita o mesmo padrão
 * de resiliência já usado por `monitorarAlarmesAgendados`
 * (`scheduledAlarmMonitor.js`) — sobrevive a quedas/reinícios da função e
 * evita manter uma instância viva (e sendo cobrada) por 60s a cada
 * alerta.
 */

const {onSchedule} = require("firebase-functions/v2/scheduler");
const {getFirestore} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const {enviarSmsParaTelefones, TWILIO_SECRETS} = require("./smsGateway");
const {debitarSaldo} = require("./walletService");
const {COLECAO_ENTREGAS, STATUS_AGUARDANDO_TRANSBORDO} = require("./alertaHibridoService");

const db = getFirestore();

const STATUS_PROCESSANDO = "PROCESSANDO";
const STATUS_FINALIZADO = "FINALIZADO";

// Valor de `status` gravado em `confirmacoes/{uid}` (ver
// FirebaseSyncService.confirmarEntregaAlerta no Flutter) quando o Push é
// entregue ao dispositivo — nome explícito de propósito, para deixar
// claro no próprio schema que o critério é ENTREGA, não abertura/leitura
// do app.
const STATUS_ENTREGUE_DISPOSITIVO = "entregue_dispositivo";

/**
 * CRITÉRIO DE CANCELAMENTO DO WHATSAPP DE CONTINGÊNCIA: um contato só
 * conta como "confirmado" — e portanto NUNCA gera cobrança — quando o
 * Push FCM foi CONFIRMADAMENTE ENTREGUE AO DISPOSITIVO de destino
 * (`entregueApp === true` e/ou `status === 'entregue_dispositivo'`, ver
 * `entregas_alerta/{idEntrega}/confirmacoes/{uidDestino}`). Este sinal é
 * gravado pelo app assim que o SO entrega a mensagem — mesmo com a tela
 * bloqueada e o app completamente fechado (ver
 * `FcmService._tratarDadosDoAlerta` no Flutter) — e NUNCA depende do
 * familiar efetivamente abrir o app, tocar na notificação ou ler o
 * alerta. Checar os dois campos (em vez de só um) torna o critério
 * robusto a qual dos dois nomes um cliente específico gravou.
 *
 * @param {FirebaseFirestore.DocumentReference} entregaRef
 * @return {Promise<Set<string>>}
 */
async function buscarUidsConfirmados(entregaRef) {
  const snap = await entregaRef.collection("confirmacoes").get();
  const uids = new Set();
  snap.forEach((doc) => {
    const dados = doc.data();
    const entregueNoDispositivo =
        dados.entregueApp === true || dados.status === STATUS_ENTREGUE_DISPOSITIVO;
    if (entregueNoDispositivo) uids.add(doc.id);
  });
  return uids;
}

/**
 * Decide e (se aplicável) executa a contingência via WhatsApp para UM
 * contato cujo dispositivo não confirmou a ENTREGA do Push a tempo
 * (nunca por falta de abertura/leitura do app — ver
 * [buscarUidsConfirmados]). Nunca lança exceção — cada contato é isolado
 * em seu próprio try/catch para não derrubar o processamento dos demais.
 *
 * @param {string} usuarioId
 * @param {{nome: string, telefone: string, whatsappHabilitado: boolean}} contato
 * @param {string} idEntrega
 * @param {string} mensagem
 */
async function processarContingenciaContato(usuarioId, contato, idEntrega, mensagem) {
  logger.info(
      `[Verificando Chave/Saldo USD] entregas_alerta/${idEntrega} — ` +
      `contato ${contato.telefone} (whatsappHabilitado=${contato.whatsappHabilitado}).`,
  );

  if (!contato.whatsappHabilitado) {
    logger.info(
        `[Operação Cancelada] entregas_alerta/${idEntrega} — WhatsApp desligado ` +
        `para o contato ${contato.telefone}; nenhuma cobrança realizada.`,
    );
    return;
  }

  const resultadoDebito = await debitarSaldo(usuarioId, contato, idEntrega);
  if (!resultadoDebito.sucesso) {
    logger.info(
        `[Operação Cancelada] entregas_alerta/${idEntrega} — não foi possível debitar ` +
        `o saldo do usuário ${usuarioId} para o contato ${contato.telefone} ` +
        `(motivo: ${resultadoDebito.motivo}).`,
    );
    return;
  }

  await enviarSmsParaTelefones([contato.telefone], mensagem);
  logger.info(
      `[Desconto Aplicado] entregas_alerta/${idEntrega} — $0.10 USD debitado do ` +
      `usuário ${usuarioId}; WhatsApp de contingência enviado para ${contato.telefone}.`,
  );
}

/**
 * Roda a cada 1 minuto: busca `entregas_alerta` com prazo de transbordo
 * vencido, reivindica cada documento (transação, evitando corrida com
 * outra execução concorrente) e aplica a regra de contingência para cada
 * contato cujo DISPOSITIVO ainda não confirmou a entrega do Push (ver
 * critério em [buscarUidsConfirmados] — entrega, não abertura do app).
 */
exports.processarTransbordoAlertas = onSchedule(
    {
      schedule: "every 1 minutes",
      timeZone: "America/Sao_Paulo",
      secrets: TWILIO_SECRETS,
    },
    async () => {
      const agoraEpochMs = Date.now();

      const vencidos = await db.collection(COLECAO_ENTREGAS)
          .where("status", "==", STATUS_AGUARDANDO_TRANSBORDO)
          .where("prazoTransbordoEpochMs", "<=", agoraEpochMs)
          .get();

      if (vencidos.empty) {
        logger.info("[Aguardando 60s] Nenhuma entrega de alerta vencida no momento.");
        return;
      }

      logger.info(
          `[Aguardando 60s] ${vencidos.size} entrega(s) de alerta vencida(s) — ` +
          "iniciando avaliação de transbordo.",
      );

      for (const doc of vencidos.docs) {
        try {
          const reivindicado = await db.runTransaction(async (tx) => {
            const snapAtual = await tx.get(doc.ref);
            if (!snapAtual.exists || snapAtual.data().status !== STATUS_AGUARDANDO_TRANSBORDO) {
              return false;
            }
            tx.update(doc.ref, {status: STATUS_PROCESSANDO});
            return true;
          });

          if (!reivindicado) {
            logger.info(
                `entregas_alerta/${doc.id} já não estava mais AGUARDANDO_TRANSBORDO — ignorado.`,
            );
            continue;
          }

          const dados = doc.data();
          const uidsConfirmados = await buscarUidsConfirmados(doc.ref);
          const contatos = dados.contatos || [];

          // Pula contatos que já receberam o WhatsApp de forma IMEDIATA
          // (chave global "Enviar também via WhatsApp" ligada, ver
          // `enviarWhatsappSimultaneoParaContatos` em
          // `alertaHibridoService.js`) — evita cobrança/envio em
          // duplicidade 60s depois.
          const contatosPendentes = contatos.filter((contato) =>
            !contato.whatsappJaEnviado &&
            (!contato.uidDestino || !uidsConfirmados.has(contato.uidDestino)),
          );

          for (const contato of contatosPendentes) {
            await processarContingenciaContato(
                dados.usuarioId, contato, doc.id, dados.mensagem,
            );
          }

          await doc.ref.update({
            status: STATUS_FINALIZADO,
            finalizadoEm: new Date().toISOString(),
            totalContatosPendentes: contatosPendentes.length,
          });
        } catch (e) {
          logger.error(`Falha ao processar transbordo de entregas_alerta/${doc.id}`, e);
        }
      }
    },
);
