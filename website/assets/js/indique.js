/**
 * Guardião X — página /indique (Programa de Indicação, lado do afiliado).
 *
 * Login pelo Firebase Auth do projeto `guardiaox` (Google ou e-mail/senha)
 * e as callables do servidor (contrato no README do ramo
 * `feat/programa-indicacao` do repositório guardiao-x_servidor):
 * - `meuPainelAfiliado` (sem entrada) → painel; `not-found`/`nao_cadastrado`
 *   → formulário de cadastro;
 * - `cadastrarAfiliado({nome, cpf, chavePix, tipoChavePix, regulamentoVersao})`.
 *
 * Mesma config pública do app Web já usada pelo chat de suporte
 * (`suporte-chat.js`). Região das callables: us-central1.
 */
import {initializeApp} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js";
import {
  getAuth,
  onAuthStateChanged,
  GoogleAuthProvider,
  signInWithPopup,
  signInWithRedirect,
  signInWithEmailAndPassword,
  createUserWithEmailAndPassword,
  sendEmailVerification,
  sendPasswordResetEmail,
  signOut,
  connectAuthEmulator,
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";
import {
  getFunctions,
  httpsCallable,
  connectFunctionsEmulator,
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-functions.js";

const FIREBASE_CONFIG = {
  projectId: "guardiaox",
  appId: "1:555863351772:web:b5766677997ffa434def19",
  storageBucket: "guardiaox.firebasestorage.app",
  apiKey: "AIzaSyA8_SqCjxlB0lhEhbF0pBf-gsJlQJ4gXgE",
  authDomain: "guardiaox.firebaseapp.com",
  messagingSenderId: "555863351772",
  measurementId: "G-7TD2NW0S3T",
};
const FUNCTIONS_REGION = "us-central1";

/** Versão do regulamento aceita (vai para `regulamentoVersao`, até 40
 * caracteres). Mudar junto com /regulamento-indicacao a cada revisão. */
const REGULAMENTO_VERSAO = "2026-10-04-rascunho";

const app = initializeApp(FIREBASE_CONFIG);
const auth = getAuth(app);
auth.languageCode = "pt";
const functions = getFunctions(app, FUNCTIONS_REGION);

// Teste local contra os emuladores do repositório do servidor
// (`localhost/indique?emulador=1`). Nunca vale no site publicado.
if (location.hostname === "localhost" && new URLSearchParams(location.search).has("emulador")) {
  connectAuthEmulator(auth, "http://127.0.0.1:9099", {disableWarnings: true});
  connectFunctionsEmulator(functions, "127.0.0.1", 5001);
}

const $ = (id) => document.getElementById(id);
const telas = ["tela-carregando", "tela-login", "tela-cadastro", "tela-painel"];

function mostrar(tela) {
  telas.forEach((id) => $(id).classList.toggle("ind-oculto", id !== tela));
  $("erro-geral").classList.add("ind-oculto");
}

function aviso(el, texto, tipo) {
  if (!texto) {
    el.classList.add("ind-oculto");
    return;
  }
  el.textContent = texto;
  el.classList.remove("ind-oculto", "erro", "ok");
  el.classList.add(tipo || "erro");
}

function erroGeral(texto) {
  aviso($("erro-geral"), texto, "erro");
}

// ---------------------------------------------------------------- Login

const MENSAGENS_AUTH = {
  "auth/invalid-email": "E-mail inválido.",
  "auth/missing-password": "Digite sua senha.",
  "auth/weak-password": "A senha precisa ter pelo menos 6 caracteres.",
  "auth/email-already-in-use": "Já existe uma conta com este e-mail. Use “Entrar”.",
  "auth/invalid-credential": "E-mail ou senha incorretos.",
  "auth/wrong-password": "E-mail ou senha incorretos.",
  "auth/user-not-found": "E-mail ou senha incorretos.",
  "auth/too-many-requests": "Muitas tentativas. Aguarde alguns minutos e tente de novo.",
  "auth/network-request-failed": "Sem conexão. Verifique sua internet.",
  "auth/popup-closed-by-user": "Login cancelado.",
  "auth/cancelled-popup-request": "Login cancelado.",
  "auth/unauthorized-domain":
    "O login com Google ainda não está liberado neste endereço. Tente com e-mail ou fale com o suporte.",
  "auth/user-disabled": "Esta conta está desativada.",
};

function mensagemAuth(e) {
  return MENSAGENS_AUTH[e && e.code] || "Não foi possível entrar agora. Tente de novo.";
}

$("login-google").addEventListener("click", async () => {
  aviso($("login-mensagem"), "");
  const provedor = new GoogleAuthProvider();
  try {
    await signInWithPopup(auth, provedor);
  } catch (e) {
    // Navegadores que bloqueiam pop-up (alguns celulares): redireciona.
    if (e.code === "auth/popup-blocked" || e.code === "auth/operation-not-supported-in-environment") {
      await signInWithRedirect(auth, provedor);
      return;
    }
    aviso($("login-mensagem"), mensagemAuth(e));
  }
});

function dadosLogin() {
  return {email: $("login-email").value.trim(), senha: $("login-senha").value};
}

$("form-login").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const {email, senha} = dadosLogin();
  aviso($("login-mensagem"), "");
  try {
    await signInWithEmailAndPassword(auth, email, senha);
  } catch (e) {
    aviso($("login-mensagem"), mensagemAuth(e));
  }
});

$("login-criar").addEventListener("click", async () => {
  const {email, senha} = dadosLogin();
  aviso($("login-mensagem"), "");
  try {
    const credencial = await createUserWithEmailAndPassword(auth, email, senha);
    sendEmailVerification(credencial.user).catch(() => {});
  } catch (e) {
    aviso($("login-mensagem"), mensagemAuth(e));
  }
});

$("login-esqueci").addEventListener("click", async () => {
  const {email} = dadosLogin();
  if (!email) {
    aviso($("login-mensagem"), "Digite seu e-mail acima e toque de novo em “Esqueci minha senha”.");
    return;
  }
  try {
    await sendPasswordResetEmail(auth, email);
    aviso($("login-mensagem"), "Se houver uma conta com este e-mail, enviamos o link para criar uma nova senha.", "ok");
  } catch (e) {
    aviso($("login-mensagem"), mensagemAuth(e));
  }
});

document.querySelectorAll("[data-sair]").forEach((botao) =>
  botao.addEventListener("click", () => signOut(auth)));

// ------------------------------------------------------------- Cadastro

const MENSAGENS_CADASTRO = {
  nome_invalido: "Digite seu nome completo (de 3 a 100 caracteres).",
  cpf_invalido: "CPF inválido. Confira os números.",
  tipo_chave_pix_invalido: "Escolha o tipo da chave Pix.",
  chave_pix_invalida: "Chave Pix inválida para o tipo escolhido. Confira e tente de novo.",
  regulamento_nao_aceito: "Para participar, aceite o regulamento do programa.",
};

const DICAS_CHAVE = {
  cpf: "Só os números do CPF (pode ser com pontos e traço).",
  cnpj: "Os 14 números do CNPJ.",
  email: "O e-mail cadastrado como chave Pix.",
  telefone: "Celular com DDD, ex.: (31) 99999-9999.",
  aleatoria: "A chave aleatória completa, com os traços.",
};

function atualizarDicaChave() {
  $("cad-chave-dica").textContent = DICAS_CHAVE[$("cad-tipo").value] || "";
}
$("cad-tipo").addEventListener("change", atualizarDicaChave);
atualizarDicaChave();

// Máscara simples de CPF enquanto digita.
$("cad-cpf").addEventListener("input", () => {
  const d = $("cad-cpf").value.replace(/\D/g, "").slice(0, 11);
  let v = d;
  if (d.length > 9) v = `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}`;
  else if (d.length > 6) v = `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6)}`;
  else if (d.length > 3) v = `${d.slice(0, 3)}.${d.slice(3)}`;
  $("cad-cpf").value = v;
});

let editandoCadastro = false;

function abrirCadastro(editando) {
  editandoCadastro = editando;
  $("cadastro-titulo").textContent = editando ? "Atualizar dados de pagamento" : "Seus dados para receber";
  $("cad-salvar").textContent = editando ? "Salvar dados" : "Salvar e gerar meu link";
  $("cad-cancelar").classList.toggle("ind-oculto", !editando);
  aviso($("cadastro-mensagem"), "");
  mostrar("tela-cadastro");
}

$("cad-cancelar").addEventListener("click", () => mostrar("tela-painel"));
$("painel-editar").addEventListener("click", () => abrirCadastro(true));

$("form-cadastro").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  if (!$("cad-aceite").checked) {
    aviso($("cadastro-mensagem"), MENSAGENS_CADASTRO.regulamento_nao_aceito);
    return;
  }
  const botao = $("cad-salvar");
  botao.disabled = true;
  aviso($("cadastro-mensagem"), "");
  try {
    await httpsCallable(functions, "cadastrarAfiliado")({
      nome: $("cad-nome").value.trim(),
      cpf: $("cad-cpf").value.trim(),
      chavePix: $("cad-chave").value.trim(),
      tipoChavePix: $("cad-tipo").value,
      regulamentoVersao: REGULAMENTO_VERSAO,
    });
    await carregarPainel();
  } catch (e) {
    const codigo = e && e.message;
    aviso($("cadastro-mensagem"), MENSAGENS_CADASTRO[codigo] ||
      (e && e.code === "functions/unauthenticated"
        ? "Sua sessão expirou. Entre de novo."
        : "Não foi possível salvar agora. Tente de novo em instantes."));
  } finally {
    botao.disabled = false;
  }
});

// ---------------------------------------------------------------- Painel

const ROTULOS_STATUS = {
  aguardando: "Aguardando mensalidades",
  em_carencia: "Em carência (7 dias)",
  a_pagar: "A pagar",
  em_revisao: "Em revisão",
  paga: "Paga",
  cancelada: "Cancelada",
};

const reais = new Intl.NumberFormat("pt-BR", {style: "currency", currency: "BRL"});
const data = (ms) => (ms ? new Date(ms).toLocaleDateString("pt-BR") : null);

function preencherCompartilhar(link) {
  const texto = `Eu uso o Guardião X para a minha segurança e de quem eu amo. Baixe pelo meu link: ${link}`;
  const t = encodeURIComponent(texto);
  const u = encodeURIComponent(link);
  $("compartilhar-whatsapp").href = `https://wa.me/?text=${t}`;
  $("compartilhar-facebook").href = `https://www.facebook.com/sharer/sharer.php?u=${u}`;
  $("compartilhar-x").href = `https://twitter.com/intent/tweet?text=${t}`;
  $("compartilhar-telegram").href = `https://t.me/share/url?url=${u}&text=${encodeURIComponent("Eu uso o Guardião X para a minha segurança. Baixe pelo meu link:")}`;
  const nativo = $("compartilhar-nativo");
  if (navigator.share) {
    nativo.classList.remove("ind-oculto");
    nativo.onclick = () => navigator.share({title: "Guardião X", text: texto, url: link}).catch(() => {});
  }
}

function montarTotais(totais) {
  const caixa = $("painel-totais");
  caixa.replaceChildren();
  Object.keys(ROTULOS_STATUS).forEach((status) => {
    const t = (totais && totais[status]) || {quantidade: 0, valor: 0};
    const div = document.createElement("div");
    div.className = "ind-total";
    const rotulo = document.createElement("small");
    rotulo.textContent = ROTULOS_STATUS[status];
    const qtd = document.createElement("strong");
    qtd.textContent = String(t.quantidade || 0);
    const valor = document.createElement("span");
    valor.textContent = reais.format(t.valor || 0);
    div.append(rotulo, qtd, valor);
    caixa.append(div);
  });
}

function montarLista(indicacoes) {
  const lista = $("painel-lista");
  lista.replaceChildren();
  $("painel-vazio").classList.toggle("ind-oculto", indicacoes.length > 0);
  indicacoes.forEach((ind) => {
    const li = document.createElement("li");
    const linha = document.createElement("div");
    linha.className = "ind-linha";
    const descricao = document.createElement("strong");
    const pagas = ind.mensalidadesPagas || 0;
    const necessarias = ind.mensalidadesNecessarias || 12;
    descricao.textContent = ind.descricao || `Indicação ${ind.numero}: ${pagas} de ${necessarias} mensalidades`;
    const status = document.createElement("span");
    status.className = `ind-status ${ind.status}`;
    status.textContent = ROTULOS_STATUS[ind.status] || ind.status;
    linha.append(descricao, status);

    const barra = document.createElement("div");
    barra.className = "ind-progresso";
    barra.setAttribute("role", "progressbar");
    barra.setAttribute("aria-valuemin", "0");
    barra.setAttribute("aria-valuemax", String(necessarias));
    barra.setAttribute("aria-valuenow", String(pagas));
    const preenchido = document.createElement("div");
    preenchido.style.width = `${Math.min(100, Math.round((pagas / necessarias) * 100))}%`;
    barra.append(preenchido);

    const detalhes = [];
    if (data(ind.vinculadaEmMs)) detalhes.push(`Vinculada em ${data(ind.vinculadaEmMs)}`);
    if (ind.status === "em_carencia" && data(ind.liberarEmMs)) detalhes.push(`Liberação prevista em ${data(ind.liberarEmMs)}`);
    if (data(ind.pagaEmMs)) detalhes.push(`Paga em ${data(ind.pagaEmMs)}`);
    detalhes.push(`Comissão: ${reais.format(ind.valor || 0)}`);
    const rodape = document.createElement("p");
    rodape.className = "ind-dica";
    rodape.style.margin = "10px 0 0";
    rodape.textContent = detalhes.join(" · ");

    li.append(linha, barra, rodape);
    lista.append(li);
  });
}

async function carregarPainel() {
  let painel;
  try {
    painel = (await httpsCallable(functions, "meuPainelAfiliado")()).data;
  } catch (e) {
    if (e && e.code === "functions/not-found") {
      abrirCadastro(false);
      return;
    }
    mostrar("tela-carregando");
    erroGeral("Não foi possível carregar seu painel agora. Atualize a página em instantes.");
    return;
  }
  $("painel-codigo").textContent = painel.codigo;
  $("painel-link").value = painel.link;
  $("painel-inativo").classList.toggle("ind-oculto", painel.ativo !== false);
  preencherCompartilhar(painel.link);
  montarTotais(painel.totais);
  montarLista(painel.indicacoes || []);
  mostrar("tela-painel");
}

$("painel-copiar").addEventListener("click", async () => {
  const botao = $("painel-copiar");
  const link = $("painel-link").value;
  try {
    await navigator.clipboard.writeText(link);
  } catch (_) {
    $("painel-link").select();
    try { document.execCommand("copy"); } catch (__) { /* sem cópia */ }
  }
  botao.textContent = "Link copiado!";
  setTimeout(() => { botao.textContent = "Copiar link"; }, 2500);
});

// ---------------------------------------------------------------- Sessão

onAuthStateChanged(auth, (usuario) => {
  // A sessão anônima do chat de suporte (mesmo site) não conta como login.
  if (!usuario || usuario.isAnonymous) {
    mostrar("tela-login");
    return;
  }
  mostrar("tela-carregando");
  carregarPainel();
});
