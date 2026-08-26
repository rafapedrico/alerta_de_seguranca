import {useEffect, useRef, useState} from "react";
import {useNavigate, useParams} from "react-router-dom";
import {collection, doc, onSnapshot, orderBy, query} from "firebase/firestore";
import {httpsCallable} from "firebase/functions";
import {db, functions} from "../firebase";
import {Layout} from "../componentes/Layout";

/**
 * Thread de um ticket: mensagens em tempo real (ticket doc + subcoleção
 * `mensagens`, ambos lidos direto via Firestore Rules — ver
 * `Tickets.jsx`) e as 3 ações do atendente, todas via callable (Admin
 * SDK, ver `functions/suporteChatService.js`): responder
 * (`responderComoAtendente`), encerrar (`encerrarTicketSuporte`) e
 * identificar quem abriu o ticket (`obterResumoUsuarioSuporte` — devolve
 * só nome/email/telefone, nunca o documento completo de `usuarios/{uid}`).
 */
const ROTULOS_STATUS = {
  ia_ativa: "Com a IA",
  aguardando_humano: "Aguardando atendimento",
  em_atendimento_humano: "Em atendimento",
  resolvido: "Resolvido",
};

const ROTULOS_AUTOR = {
  usuario: "Usuário",
  ia: "IA",
  atendente: "Atendente",
  sistema: "Sistema",
};

function formatarHora(timestamp) {
  if (!timestamp) return "";
  return timestamp.toDate().toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function TicketDetalhe() {
  const {ticketId} = useParams();
  const navigate = useNavigate();
  const [ticket, setTicket] = useState(null);
  const [mensagens, setMensagens] = useState([]);
  const [usuarioResumo, setUsuarioResumo] = useState(null);
  const [resposta, setResposta] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [encerrando, setEncerrando] = useState(false);
  const [erro, setErro] = useState(null);
  const fimDaListaRef = useRef(null);

  useEffect(() => {
    const unsub = onSnapshot(
      doc(db, "suporte_tickets", ticketId),
      (snap) => {
        if (!snap.exists()) {
          setErro("Ticket não encontrado.");
          return;
        }
        setTicket({id: snap.id, ...snap.data()});
      },
      (e) => {
        console.error("[TicketDetalhe] ticket", e);
        setErro("Não foi possível carregar este ticket.");
      },
    );
    return unsub;
  }, [ticketId]);

  useEffect(() => {
    const q = query(
      collection(db, "suporte_tickets", ticketId, "mensagens"),
      orderBy("criadoEm", "asc"),
    );
    const unsub = onSnapshot(
      q,
      (snap) => {
        setMensagens(snap.docs.map((d) => ({id: d.id, ...d.data()})));
      },
      (e) => console.error("[TicketDetalhe] mensagens", e),
    );
    return unsub;
  }, [ticketId]);

  useEffect(() => {
    fimDaListaRef.current?.scrollIntoView({block: "nearest"});
  }, [mensagens]);

  useEffect(() => {
    if (!ticket?.uid) return;
    const obterResumo = httpsCallable(functions, "obterResumoUsuarioSuporte");
    obterResumo({uid: ticket.uid})
      .then((res) => setUsuarioResumo(res.data))
      .catch((e) => console.error("[TicketDetalhe] resumo do usuário", e));
  }, [ticket?.uid]);

  async function aoResponder(ev) {
    ev.preventDefault();
    if (!resposta.trim()) return;
    setErro(null);
    setEnviando(true);
    try {
      const responder = httpsCallable(functions, "responderComoAtendente");
      await responder({ticketId, texto: resposta.trim()});
      setResposta("");
    } catch (e) {
      console.error("[TicketDetalhe] responder", e);
      setErro("Não foi possível enviar a resposta.");
    } finally {
      setEnviando(false);
    }
  }

  async function aoEncerrar() {
    setErro(null);
    setEncerrando(true);
    try {
      const encerrar = httpsCallable(functions, "encerrarTicketSuporte");
      await encerrar({ticketId});
    } catch (e) {
      console.error("[TicketDetalhe] encerrar", e);
      setErro("Não foi possível encerrar o ticket.");
    } finally {
      setEncerrando(false);
    }
  }

  const ticketResolvido = ticket?.status === "resolvido";

  return (
    <Layout>
      <button type="button" className="botao-voltar" onClick={() => navigate("/tickets")}>
        ← Voltar para a lista
      </button>

      {!ticket && !erro && <p className="texto-secundario">Carregando...</p>}
      {erro && <p className="erro">{erro}</p>}

      {ticket && (
        <div className="ticket-detalhe">
          <header className="ticket-detalhe-cabecalho">
            <div>
              <h1>{usuarioResumo?.nome || "Visitante"}</h1>
              <p className="texto-secundario">
                {usuarioResumo?.email || usuarioResumo?.telefone || `uid: ${ticket.uid}`}
              </p>
            </div>
            <div className="ticket-detalhe-acoes">
              <span className={`badge-status badge-status-${ticket.status}`}>
                {ROTULOS_STATUS[ticket.status] || ticket.status}
              </span>
              {!ticketResolvido && (
                <button type="button" onClick={aoEncerrar} disabled={encerrando}>
                  {encerrando ? "Encerrando..." : "Encerrar atendimento"}
                </button>
              )}
            </div>
          </header>

          <div className="thread-mensagens">
            {mensagens.map((msg) => (
              <div key={msg.id} className={`mensagem mensagem-${msg.autor}`}>
                <span className="mensagem-autor">{ROTULOS_AUTOR[msg.autor] || msg.autor}</span>
                <p>{msg.texto}</p>
                <span className="mensagem-hora">{formatarHora(msg.criadoEm)}</span>
              </div>
            ))}
            <div ref={fimDaListaRef} />
          </div>

          {ticketResolvido ? (
            <p className="texto-secundario">Este ticket já foi encerrado.</p>
          ) : (
            <form className="form-resposta" onSubmit={aoResponder}>
              <textarea
                value={resposta}
                onChange={(e) => setResposta(e.target.value)}
                placeholder="Escreva sua resposta..."
                rows={3}
                required
              />
              <button type="submit" disabled={enviando}>
                {enviando ? "Enviando..." : "Enviar resposta"}
              </button>
            </form>
          )}
        </div>
      )}
    </Layout>
  );
}
