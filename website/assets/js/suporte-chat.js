/**
 * Guardião X — Chat de Suporte (widget flutuante do site institucional).
 *
 * Reaproveita EXATAMENTE o mesmo backend do chat de suporte do app
 * (coleção `suporte_tickets`/`mensagens`, mesma Cloud Function
 * `aoReceberMensagemSuporte`, mesmas regras do Firestore) — a única
 * diferença é que aqui o visitante não tem login: usa Firebase
 * Anonymous Auth (precisa estar habilitado no Console — Authentication
 * → Sign-in method → Anonymous) pra virar um `uid` de verdade, que as
 * regras existentes já aceitam sem nenhuma mudança de backend.
 *
 * `idioma` fixo em "pt" (site é só português) e `planoNoMomento: "site"`
 * (sinaliza que não é uma conta do app, útil pro futuro Painel Admin).
 *
 * Módulo ES nativo (sem bundler/npm, mesmo espírito "zero build" do
 * resto do site) — importa o SDK do Firebase direto do CDN.
 */
import {initializeApp} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js";
import {
  getAuth,
  signInAnonymously,
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";
import {
  getFirestore,
  collection,
  doc,
  addDoc,
  getDoc,
  setDoc,
  onSnapshot,
  orderBy,
  query,
  serverTimestamp,
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js";
import {
  getFunctions,
  httpsCallable,
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

// Mesma região onde as Cloud Functions estão deployadas
// (southamerica-east1) — sem isso o SDK chama us-central1 por padrão e
// a callable `solicitarAtendenteHumano` daria "not-found".
const FUNCTIONS_REGION = "southamerica-east1";

const CHAVE_TICKET_LOCALSTORAGE = "guardiaoXSuporteTicketId";

const app = initializeApp(FIREBASE_CONFIG);
const auth = getAuth(app);
const db = getFirestore(app);
const functions = getFunctions(app, FUNCTIONS_REGION);

let ticketIdAtual = null;
let unsubMensagens = null;
let unsubTicket = null;
let inicializando = false;

/**
 * Garante uma sessão anônima autenticada. Idempotente: se já tem um
 * `currentUser` (persistido pelo próprio Firebase Auth no navegador),
 * reaproveita sem criar sessão nova.
 */
async function garantirAuth() {
  if (auth.currentUser) return auth.currentUser;
  const credencial = await signInAnonymously(auth);
  return credencial.user;
}

/**
 * Reaproveita o ticket salvo no localStorage deste navegador (se ainda
 * existir, pertencer ao uid atual e não estiver resolvido) ou cria um
 * novo. Mesma lógica de "um ticket em aberto por vez" do app.
 */
async function obterOuCriarTicket(uid) {
  const ticketSalvo = localStorage.getItem(CHAVE_TICKET_LOCALSTORAGE);
  if (ticketSalvo) {
    const snap = await getDoc(doc(db, "suporte_tickets", ticketSalvo));
    if (snap.exists()) {
      const dados = snap.data();
      if (dados.uid === uid && dados.status !== "resolvido") {
        return ticketSalvo;
      }
    }
  }

  const novoTicketRef = await addDoc(collection(db, "suporte_tickets"), {
    uid,
    status: "ia_ativa",
    idioma: "pt",
    planoNoMomento: "site",
    criadoEm: serverTimestamp(),
  });
  localStorage.setItem(CHAVE_TICKET_LOCALSTORAGE, novoTicketRef.id);
  return novoTicketRef.id;
}

function escaparHtml(texto) {
  const div = document.createElement("div");
  div.textContent = texto;
  return div.innerHTML;
}

function renderizarMensagens(container, docs) {
  if (docs.length === 0) {
    container.innerHTML = '<p class="suporte-chat-vazio">Como podemos ajudar? Envie sua primeira mensagem.</p>';
    return;
  }
  container.innerHTML = docs
      .map((d) => {
        const m = d.data();
        const autor = m.autor || "sistema";
        return `<div class="suporte-chat-bolha ${autor}">${escaparHtml(m.texto || "")}</div>`;
      })
      .join("");
  container.scrollTop = container.scrollHeight;
}

const TEXTOS_STATUS = {
  aguardando_humano: "Aguardando atendimento humano...",
  em_atendimento_humano: "Você está sendo atendido por um atendente humano.",
  resolvido: "Este atendimento foi encerrado.",
};

function renderizarBanner(bannerEl, status) {
  const texto = TEXTOS_STATUS[status];
  if (!texto) {
    bannerEl.classList.remove("visivel");
    return;
  }
  bannerEl.textContent = texto;
  bannerEl.classList.add("visivel");
}

/**
 * Constrói o markup do widget e injeta no final do <body> — assim
 * qualquer página que só inclua este script (`<script type="module"
 * src="assets/js/suporte-chat.js">`) ganha o widget completo, sem
 * precisar duplicar HTML.
 */
function montarWidget() {
  const wrapper = document.createElement("div");
  wrapper.innerHTML = `
    <button class="suporte-chat-fab" type="button" aria-label="Abrir chat de suporte" data-suporte-chat-fab>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/></svg>
    </button>
    <div class="suporte-chat-panel" data-suporte-chat-panel>
      <div class="suporte-chat-header">
        <h3>Chat de Suporte</h3>
        <div class="suporte-chat-header-actions">
          <button type="button" title="Falar com atendente" data-suporte-chat-atendente>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M17 21v-2a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v2"/><circle cx="10" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>
          </button>
          <button type="button" title="Fechar" data-suporte-chat-fechar>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M18 6 6 18M6 6l12 12"/></svg>
          </button>
        </div>
      </div>
      <div class="suporte-chat-banner" data-suporte-chat-banner></div>
      <div class="suporte-chat-mensagens" data-suporte-chat-mensagens></div>
      <form class="suporte-chat-form" data-suporte-chat-form>
        <input type="text" placeholder="Digite sua mensagem..." autocomplete="off" data-suporte-chat-input />
        <button type="submit" aria-label="Enviar" data-suporte-chat-enviar>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/></svg>
        </button>
      </form>
    </div>
  `;
  document.body.appendChild(wrapper);
  return wrapper;
}

async function inicializarChat(widget) {
  if (inicializando || ticketIdAtual) return;
  inicializando = true;

  const painel = widget.querySelector("[data-suporte-chat-panel]");
  const mensagensEl = widget.querySelector("[data-suporte-chat-mensagens]");
  const bannerEl = widget.querySelector("[data-suporte-chat-banner]");
  const formEl = widget.querySelector("[data-suporte-chat-form]");
  const inputEl = widget.querySelector("[data-suporte-chat-input]");
  const enviarBtn = widget.querySelector("[data-suporte-chat-enviar]");
  const atendenteBtn = widget.querySelector("[data-suporte-chat-atendente]");

  mensagensEl.innerHTML = '<p class="suporte-chat-vazio">Conectando...</p>';

  try {
    const usuario = await garantirAuth();
    ticketIdAtual = await obterOuCriarTicket(usuario.uid);
  } catch (e) {
    mensagensEl.innerHTML = '<p class="suporte-chat-vazio">Não foi possível conectar ao suporte agora. Tente novamente em instantes.</p>';
    console.error("[SuporteChat] Falha ao inicializar:", e);
    inicializando = false;
    return;
  }

  const ticketRef = doc(db, "suporte_tickets", ticketIdAtual);
  const mensagensRef = collection(ticketRef, "mensagens");

  unsubMensagens = onSnapshot(
      query(mensagensRef, orderBy("criadoEm")),
      (snap) => renderizarMensagens(mensagensEl, snap.docs),
  );
  unsubTicket = onSnapshot(ticketRef, (snap) => {
    if (snap.exists()) renderizarBanner(bannerEl, snap.data().status);
  });

  formEl.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const texto = inputEl.value.trim();
    if (!texto) return;
    inputEl.value = "";
    enviarBtn.disabled = true;
    try {
      await addDoc(mensagensRef, {
        autor: "usuario",
        texto,
        criadoEm: serverTimestamp(),
      });
    } catch (e) {
      console.error("[SuporteChat] Falha ao enviar mensagem:", e);
    } finally {
      enviarBtn.disabled = false;
      inputEl.focus();
    }
  });

  atendenteBtn.addEventListener("click", async () => {
    try {
      await httpsCallable(functions, "solicitarAtendenteHumano")({ticketId: ticketIdAtual});
    } catch (e) {
      console.error("[SuporteChat] Falha ao solicitar atendente:", e);
    }
  });

  inicializando = false;
}

function iniciar() {
  const widget = montarWidget();
  const painel = widget.querySelector("[data-suporte-chat-panel]");
  const fab = widget.querySelector("[data-suporte-chat-fab]");
  const fechar = widget.querySelector("[data-suporte-chat-fechar]");

  const abrir = () => {
    painel.classList.add("aberto");
    inicializarChat(widget);
  };

  fab.addEventListener("click", abrir);
  fechar.addEventListener("click", () => painel.classList.remove("aberto"));

  // Qualquer link/botão existente na página com este atributo também
  // abre o widget (ex: os CTAs "Iniciar conversa"/"Abrir o chat" em
  // suporte.html) — evita duplicar lógica de abertura.
  document.querySelectorAll("[data-abrir-chat-suporte]").forEach((el) => {
    el.addEventListener("click", (ev) => {
      ev.preventDefault();
      abrir();
    });
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", iniciar);
} else {
  iniciar();
}
