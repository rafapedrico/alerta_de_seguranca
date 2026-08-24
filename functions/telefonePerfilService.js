/**
 * Unicidade ESTRITA de telefone, sem prova de posse por SMS (decisão de
 * arquitetura 2026-08-23: remoção do Firebase Phone Auth/OTP para zerar
 * custo de SMS e simplificar o onboarding, com diretriz mandatória de
 * NÃO regredir o motor de segurança).
 *
 * CONTEXTO: até aqui, o telefone só podia ser gravado em `usuarios/{uid}`
 * depois de comprovado por SMS OTP (ver histórico de
 * `verificacao_telefone_screen.dart`, removida) — a garantia contra
 * sequestro de alerta de emergência (alguém digitar o número de OUTRA
 * pessoa e roubar os alertas endereçados a ela) vinha da PROVA DE POSSE,
 * não de uma checagem no banco. Sem OTP, essa prova deixa de existir — a
 * unicidade aqui é a ÚNICA rede de segurança que sobra: impede que dois
 * `uid`s tenham o MESMO `telefone` gravado ao mesmo tempo (quem chega
 * primeiro "reserva" o número; qualquer tentativa seguinte de outra
 * conta é rejeitada). NÃO prova que quem está gravando é o dono de
 * verdade daquele número — só impede o reuso silencioso de um número já
 * reivindicado por outra conta.
 *
 * Modelo de dados: `telefones_reservados/{telefoneE164}` = `{uid}` —
 * padrão idiomático do Firestore para unicidade (mesmo usado para
 * "username único" na documentação oficial), porque as regras de
 * segurança não conseguem fazer uma query "existe algum doc com este
 * campo?" — só `exists()`/`get()` num caminho conhecido. `firestore.rules`
 * nega QUALQUER acesso do cliente a esta coleção e ao campo `telefone` em
 * `usuarios/{uid}` — esta Cloud Function (Admin SDK) é o ÚNICO escritor
 * dos dois.
 *
 * Limpeza no fim de vida da conta: `exclusaoContaService.js` libera a
 * reserva (`telefones_reservados/{telefone}`) como parte do MESMO
 * Promise.all que já apaga `usuarios/{uid}` — lição aprendida do bug de
 * 2026-08-23 (conta fantasma no Firebase Auth prendendo um número após
 * exclusão parcial): aqui a liberação é só Firestore, sem o problema de
 * "dois sistemas, uma etapa cai" que causou aquele bug.
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {normalizarTelefoneE164} = require("./telefoneUtils");
const logger = require("firebase-functions/logger");

const db = getFirestore();

/**
 * Callable `onCall` — chamada por [FirebaseSyncService.salvarTelefonePerfil]
 * em 3 pontos do app: cadastro por e-mail/senha ([CadastroScreen]),
 * primeiro login social sem telefone ([CompletarPerfilScreen], substituiu
 * a antiga tela de OTP) e edição manual em Configurações > Meu Perfil.
 *
 * @param {{telefone: string}} request.data — em E.164 (ex: "+5511999999999").
 * @return {{sucesso: true}}
 */
exports.atualizarTelefonePerfil = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }
  const uid = request.auth.uid;
  const bruto = request.data && request.data.telefone;

  if (typeof bruto !== "string" || bruto.trim().length === 0) {
    throw new HttpsError("invalid-argument", "Telefone é obrigatório.");
  }

  // Nunca confia na normalização E.164 já feita no cliente (TelefoneUtils,
  // Dart) — revalida aqui com o mesmo utilitário (`telefoneUtils.js`) já
  // usado pelo restante das Cloud Functions deste projeto.
  const telefone = normalizarTelefoneE164(bruto);
  if (!telefone) {
    throw new HttpsError("invalid-argument", "Telefone inválido.");
  }

  const refReservaNova = db.collection("telefones_reservados").doc(telefone);
  const refUsuario = db.collection("usuarios").doc(uid);

  try {
    await db.runTransaction(async (tx) => {
      const [reservaNovaSnap, usuarioSnap] = await Promise.all([
        tx.get(refReservaNova),
        tx.get(refUsuario),
      ]);

      if (reservaNovaSnap.exists && reservaNovaSnap.data().uid !== uid) {
        // Número já reivindicado por OUTRA conta — bloqueia. Lançar
        // DENTRO da transação também funciona (aborta antes de qualquer
        // escrita), mas lançar HttpsError aqui é capturado pelo SDK do
        // Firestore e reembrulhado — por isso a checagem é repetida FORA
        // da transação logo abaixo, onde o `HttpsError` original chega
        // intacto ao cliente.
        throw new Error("TELEFONE_EM_USO");
      }

      const telefoneAntigo = usuarioSnap.exists ? usuarioSnap.data().telefone : null;
      if (telefoneAntigo && telefoneAntigo !== telefone) {
        // Troca de número: libera a reserva antiga (só se for realmente
        // deste uid — defensivo, nunca deveria ser de outro).
        const refReservaAntiga = db.collection("telefones_reservados").doc(telefoneAntigo);
        const reservaAntigaSnap = await tx.get(refReservaAntiga);
        if (reservaAntigaSnap.exists && reservaAntigaSnap.data().uid === uid) {
          tx.delete(refReservaAntiga);
        }
      }

      tx.set(refReservaNova, {uid, atualizadoEm: FieldValue.serverTimestamp()});
      tx.set(refUsuario, {telefone}, {merge: true});
    });
  } catch (e) {
    if (e.message === "TELEFONE_EM_USO") {
      throw new HttpsError("already-exists", "TELEFONE_EM_USO");
    }
    logger.error(`[atualizarTelefonePerfil] Falha ao gravar telefone de ${uid}:`, e);
    throw new HttpsError("internal", "Falha ao salvar o telefone.");
  }

  logger.info(`[atualizarTelefonePerfil] Telefone atualizado para uid ${uid}.`);
  return {sucesso: true};
});
