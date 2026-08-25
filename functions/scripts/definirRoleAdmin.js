/**
 * Script de uso ÚNICO/LOCAL pra conceder acesso ao Painel Web de Admin
 * (decisão de arquitetura 2026-08-24) — define a custom claim `role` no
 * token de um usuário do Firebase Auth. NUNCA vira uma Cloud Function
 * deployada/exposta: fica só aqui, pra ser rodado manualmente com
 * `node` por quem já tem acesso ao projeto no Firebase Console/CLI —
 * expor isso como endpoint seria abrir uma porta de escalação de
 * privilégio (qualquer chamador viraria admin).
 *
 * `role` é uma string, não mais o boolean `admin: true` que as
 * callables `responderComoAtendente`/`encerrarTicketSuporte` (ver
 * suporteChatService.js) checavam originalmente — substituído por 3
 * níveis, do menos ao mais sensível:
 *   - "atendente":  só a área de Tickets/Suporte do painel.
 *   - "supervisor": Tickets + Monitoramento de Alertas (leitura).
 *   - "admin":      tudo, incluindo Gestão de Planos (escrita sensível).
 *
 * USO:
 *   cd functions
 *   node scripts/definirRoleAdmin.js <email-do-usuario> <role>
 *
 * Exemplo:
 *   node scripts/definirRoleAdmin.js atendente1@rmfglobal.com atendente
 *
 * Pré-requisito (confirmado nesta máquina — sem `gcloud` instalado, o
 * Admin SDK não acha credencial automática): baixe uma chave de conta
 * de serviço do projeto e aponte a variável de ambiente
 * GOOGLE_APPLICATION_CREDENTIALS pra ela antes de rodar:
 *
 *   1. Firebase Console → guardiaox → ⚙ Configurações do projeto →
 *      aba "Contas de serviço" → "Gerar nova chave privada" (baixa um
 *      .json).
 *   2. Salve esse arquivo FORA do repositório (ex: na sua pasta de
 *      usuário) — nunca commitar essa chave.
 *   3a. PowerShell:
 *       $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\caminho\chave.json"
 *       node scripts/definirRoleAdmin.js <email> <role>
 *   3b. Git Bash:
 *       GOOGLE_APPLICATION_CREDENTIALS="/c/caminho/chave.json" node scripts/definirRoleAdmin.js <email> <role>
 */

const admin = require("firebase-admin");

const ROLES_VALIDAS = ["atendente", "supervisor", "admin"];

async function main() {
  const [email, role] = process.argv.slice(2);

  if (!email || !role) {
    console.error("Uso: node scripts/definirRoleAdmin.js <email> <atendente|supervisor|admin>");
    process.exit(1);
  }
  if (!ROLES_VALIDAS.includes(role)) {
    console.error(`Role inválida: "${role}". Use uma de: ${ROLES_VALIDAS.join(", ")}`);
    process.exit(1);
  }
  if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    console.error(
        "GOOGLE_APPLICATION_CREDENTIALS não definida — veja o cabeçalho " +
        "deste arquivo pra como baixar a chave de conta de serviço.");
    process.exit(1);
  }

  admin.initializeApp({projectId: "guardiaox"});

  const usuario = await admin.auth().getUserByEmail(email);
  await admin.auth().setCustomUserClaims(usuario.uid, {role});

  console.log(`OK: ${email} (uid ${usuario.uid}) agora tem role "${role}".`);
  console.log("O usuário precisa deslogar/logar de novo (ou forçar refresh do token) pra a claim valer.");
  process.exit(0);
}

main().catch((e) => {
  console.error("Falha:", e);
  process.exit(1);
});
