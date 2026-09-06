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
const {getAuth} = require("firebase-admin/auth");
const {normalizarTelefoneE164} = require("./telefoneUtils");
const logger = require("firebase-functions/logger");

const db = getFirestore();

/**
 * Recuperação SEGURA de número (e, por extensão, de acesso) — pedido
 * explícito do usuário, 2026-09-06: "recuperação de número/e-mail ao
 * trocar de conta, bloqueando o acesso da conta anterior".
 *
 * A ÚNICA credencial aceita como prova de identidade aqui é o E-MAIL
 * VERIFICADO do chamador (`request.auth.token.email_verified`), NUNCA o
 * telefone em si (ver decisão registrada em [atualizarTelefonePerfil] —
 * "transferência automática via duplicidade de número" foi recusada por
 * risco de sequestro de conta). Só entra em jogo quando o e-mail
 * verificado de QUEM ESTÁ PEDINDO AGORA é EXATAMENTE o mesmo e-mail já
 * salvo na conta ANTIGA dona do número — ou seja, só dispara quando o
 * chamador já provou (perante o próprio Firebase, via Google Sign-In ou
 * confirmação de e-mail) controlar a MESMA caixa de entrada da conta
 * antiga. Isso não abre brecha nova: quem controla de verdade o e-mail
 * de alguém já consegue recuperar a conta dessa pessoa por qualquer outro
 * caminho padrão (ex: "esqueci minha senha") — mesmo modelo de confiança
 * usado pelo próprio Firebase/Google em todo o ecossistema.
 *
 * Ao confirmar, a conta ANTIGA é BLOQUEADA por completo (nunca apagada —
 * preserva histórico/dados para suporte e auditoria):
 * - `disabled: true` no Firebase Auth — impede QUALQUER novo login nela,
 *   de qualquer provedor (Google, e-mail/senha), a partir de agora.
 * - `revokeRefreshTokens` — encerra IMEDIATAMENTE qualquer sessão já
 *   ativa nela (mesmo mecanismo de `sessaoDispositivoService.js`).
 * - Marcador em `usuarios/{uidAntigo}.contaBloqueadaPorRecuperacao` —
 *   rastreável por suporte/auditoria, nunca removido silenciosamente.
 *
 * @param {string} telefone
 * @param {string} uidAntigo
 * @param {string} uidNovo
 * @param {string} email
 */
async function recuperarNumeroEBloquearContaAntiga(telefone, uidAntigo, uidNovo, email) {
  await db.collection("telefones_reservados").doc(telefone).delete();

  await getAuth().updateUser(uidAntigo, {disabled: true});
  await getAuth().revokeRefreshTokens(uidAntigo);

  await db.collection("usuarios").doc(uidAntigo).set({
    contaBloqueadaPorRecuperacao: {
      novoUid: uidNovo,
      email,
      em: FieldValue.serverTimestamp(),
    },
  }, {merge: true});

  logger.info(
      `[atualizarTelefonePerfil] Recuperação segura: telefone ${telefone} ` +
      `transferido de ${uidAntigo} para ${uidNovo} (mesmo e-mail verificado ` +
      `${email}) — conta antiga bloqueada (disabled + sessões revogadas).`);
}

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

  // CORREÇÃO DE BUG REAL (2026-09-05, pedido explícito do usuário —
  // "Este número já está cadastrado em..." mesmo o número não existindo de
  // verdade): uma reserva em `telefones_reservados` pode ficar ÓRFÃ se a
  // conta dona dela for excluída do Firebase Auth por um caminho que não
  // passe por `excluirContaCompleta` (que já libera a reserva no MESMO
  // Promise.all que apaga `usuarios/{uid}`, ver `exclusaoContaService.js`)
  // — ex: exclusão manual do usuário direto no Console do Firebase durante
  // testes/suporte. O documento sobrevive apontando para um uid que não
  // existe mais no Auth, bloqueando para sempre uma tentativa legítima
  // (de outra pessoa, ou da mesma pessoa numa conta nova) de usar aquele
  // número. Antes de bloquear, confirma que a conta dona da reserva
  // REALMENTE ainda existe no Auth — só então trata como conflito de
  // verdade; senão, libera a reserva órfã e segue.
  const reservaPreCheckSnap = await refReservaNova.get();
  if (reservaPreCheckSnap.exists && reservaPreCheckSnap.data().uid !== uid) {
    const outroUid = reservaPreCheckSnap.data().uid;
    let outraContaExiste = true;
    try {
      await getAuth().getUser(outroUid);
    } catch (e) {
      if (e.code === "auth/user-not-found") {
        outraContaExiste = false;
      } else {
        // Falha de rede/serviço ao verificar (não "usuário não existe") —
        // nunca libera por engano nesse caso: trata como se a conta ainda
        // existisse, mesma blindagem permissiva do resto do projeto (uma
        // falha técnica nunca deve, por si só, relaxar uma trava de
        // segurança).
        logger.error(
            `[atualizarTelefonePerfil] Falha ao verificar se ${outroUid} ` +
            "ainda existe no Auth (mantendo a reserva por precaução):", e);
      }
    }
    if (!outraContaExiste) {
      logger.info(
          `[atualizarTelefonePerfil] Reserva órfã de ${telefone} (uid ` +
          `${outroUid} não existe mais no Auth) — liberando.`);
      await refReservaNova.delete().catch((e) => {
        logger.error(`[atualizarTelefonePerfil] Falha ao liberar reserva órfã de ${telefone}:`, e);
      });
    } else {
      // RECUPERAÇÃO SEGURA (pedido explícito do usuário, 2026-09-06): a
      // conta dona do número realmente existe — mas se o e-mail VERIFICADO
      // de quem está pedindo agora for exatamente o mesmo já salvo nela,
      // é prova real de que é a mesma pessoa (nunca o telefone sozinho,
      // ver documentação completa em [recuperarNumeroEBloquearContaAntiga]).
      const emailAtual = request.auth.token && request.auth.token.email;
      const emailVerificado = request.auth.token && request.auth.token.email_verified === true;
      if (emailVerificado && emailAtual) {
        const donoSnap = await db.collection("usuarios").doc(outroUid).get();
        const emailDono = donoSnap.exists ? donoSnap.data().email : null;
        if (emailDono && emailDono.toLowerCase() === emailAtual.toLowerCase()) {
          await recuperarNumeroEBloquearContaAntiga(telefone, outroUid, uid, emailAtual);
        }
      }
    }
  }

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
