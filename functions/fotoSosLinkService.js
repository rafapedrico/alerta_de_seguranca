/**
 * Encurtador de link PRÓPRIO (sem depender de nenhum serviço de
 * terceiros) para a foto do SOS enviada por SMS.
 *
 * CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-09-06, 2 rodadas
 * de teste em aparelho real — Moto G7 Play): o SMS com o link da foto
 * (P2 da sequência unificada de SOS, ver `SosDisparoService` no app)
 * usava até então a URL COMPLETA do Firebase Storage (~200+ caracteres,
 * com token), o que obrigava o Android a dividir a mensagem em várias
 * partes concatenadas (SMS multi-parte via cabeçalho UDH). O rádio do
 * aparelho de teste confirmou (`RESULT_OK`, ver `adb logcat -s
 * SmsSender`) a entrega de TODAS as partes, para TODOS os contatos, nas
 * duas rodadas — mas a mensagem da foto simplesmente não chegava aos
 * destinatários (1ª rodada: só no iPhone; 2ª rodada, já com a mensagem
 * reduzida de 3 para 2 partes: em NENHUM dos dois celulares). Ou seja: a
 * perda acontecia inteiramente na REMONTAGEM das partes do lado de quem
 * recebe, não no envio — sintoma clássico de colisão do número de
 * referência de concatenação entre DOIS SMS multi-parte enviados ao
 * mesmo número em sequência rápida (o SMS de localização, P1, sai
 * segundos antes), um problema real e conhecido de algumas pilhas de
 * telefonia Android (comum em chips MediaTek, presentes neste mesmo
 * aparelho de teste).
 *
 * A única correção que elimina o problema pela raiz é fazer o SMS da
 * foto caber em UMA ÚNICA parte (≤153 caracteres GSM-7) — aí o Android
 * nem usa o cabeçalho de concatenação, removendo o risco de colisão por
 * completo. A URL crua do Storage jamais cabe nesse limite sozinha; daí
 * este encurtador: gera um código curto (`links_foto_sos/{shortId}`,
 * Firestore) e expõe uma rota curta no domínio já hospedado do site
 * institucional (`/f/{shortId}`, ver rewrite em `firebase.json`) que
 * redireciona (302) para a URL real do Storage. Optado por implementação
 * PRÓPRIA em vez de um encurtador de terceiros — evita expor, a um
 * serviço externo, o padrão de URL de uma foto sensível capturada
 * durante uma emergência real.
 */

const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {randomBytes} = require("crypto");
const logger = require("firebase-functions/logger");

const db = getFirestore();

const COLECAO = "links_foto_sos";

/** Bucket oficial do projeto (ver `storageBucket` em `firebase_options.dart`). */
const BUCKET_STORAGE = "guardiaox.firebasestorage.app";
const PREFIXO_URL_FOTO_SOS =
    `https://firebasestorage.googleapis.com/v0/b/${BUCKET_STORAGE}/o/sos_fotos%2F`;

/** 6 bytes = 8 caracteres base64url — ~48 bits de aleatoriedade, mais
 * que suficiente para o volume deste app (colisão praticamente
 * impossível; ainda assim [criarLinkCurtoFoto] confere antes de gravar). */
function gerarShortId() {
  return randomBytes(6).toString("base64url");
}

/**
 * Callable `onCall` chamada pelo app (ver
 * `SosDisparoService._encurtarLinkDaFotoParaSms`) logo após o upload da
 * foto do SOS ao Storage, ANTES de montar o SMS com o link.
 *
 * Só aceita URLs que apontem para uma foto de SOS do PRÓPRIO uid
 * autenticado, dentro do bucket oficial do projeto — nunca uma URL
 * arbitrária, o que transformaria esta function num redirecionador
 * público genérico (open redirect) para qualquer destino.
 *
 * @param {{fotoUrl: string}} request.data
 * @return {{shortId: string}}
 */
exports.criarLinkCurtoFoto = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }
  const uid = request.auth.uid;
  const fotoUrl = request.data && request.data.fotoUrl;

  if (typeof fotoUrl !== "string" || fotoUrl.trim().length === 0) {
    throw new HttpsError("invalid-argument", "fotoUrl é obrigatório.");
  }

  const prefixoEsperado = `${PREFIXO_URL_FOTO_SOS}${encodeURIComponent(uid)}%2F`;
  if (!fotoUrl.startsWith(prefixoEsperado)) {
    throw new HttpsError("permission-denied", "URL de foto inválida para este usuário.");
  }

  let shortId = gerarShortId();
  let tentativas = 0;
  // Confere antes de gravar (nunca sobrescreve o link curto de outra
  // foto por azar estatístico) — na prática, a 1ª tentativa já basta
  // quase sempre, dado o espaço de ~48 bits por código.
  while (tentativas < 5) {
    // eslint-disable-next-line no-await-in-loop
    const existente = await db.collection(COLECAO).doc(shortId).get();
    if (!existente.exists) break;
    shortId = gerarShortId();
    tentativas++;
  }

  await db.collection(COLECAO).doc(shortId).set({
    uid,
    fotoUrl,
    criadoEm: FieldValue.serverTimestamp(),
  });

  logger.info(`[criarLinkCurtoFoto] Link curto ${shortId} criado para uid ${uid}.`);
  return {shortId};
});

/**
 * `onRequest` PÚBLICA (sem autenticação — quem abre o link é um contato
 * de emergência, geralmente sem o app instalado) — servida via o
 * rewrite `/f/**` do Firebase Hosting (ver `firebase.json`), então
 * chega no domínio institucional já conhecido (`meuguardiaox.com.br`),
 * nunca diretamente na URL da Cloud Function.
 *
 * Resolve o `shortId` (último segmento do path) em `links_foto_sos` e
 * redireciona (302) para a URL real da foto no Storage. Nunca lança —
 * qualquer falha (código inválido, doc inexistente, erro do Firestore)
 * cai numa página HTML simples de aviso, nunca um 500 cru.
 */
exports.abrirFotoSos = onRequest({invoker: "public"}, async (req, res) => {
  const segmentos = req.path.split("/").filter(Boolean);
  const shortId = segmentos[segmentos.length - 1] || "";

  if (!/^[A-Za-z0-9_-]{6,16}$/.test(shortId)) {
    res.status(404).send(paginaLinkInvalido());
    return;
  }

  try {
    const snap = await db.collection(COLECAO).doc(shortId).get();
    if (!snap.exists) {
      res.status(404).send(paginaLinkInvalido());
      return;
    }
    const fotoUrl = snap.data().fotoUrl;
    res.redirect(302, fotoUrl);
  } catch (e) {
    logger.error(`[abrirFotoSos] Falha ao resolver link curto ${shortId}:`, e);
    res.status(500).send(paginaLinkInvalido());
  }
});

/** @return {string} */
function paginaLinkInvalido() {
  return `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Link inválido — Guardião X</title>
</head>
<body style="font-family: -apple-system, sans-serif; text-align:center; padding: 64px 24px; color:#333;">
  <h1 style="font-size:20px;">Link inválido ou expirado</h1>
  <p>Este link de foto de emergência do Guardião X não é válido.</p>
</body>
</html>`;
}
