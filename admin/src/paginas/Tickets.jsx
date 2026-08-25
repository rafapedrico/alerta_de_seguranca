import {useEffect, useState} from "react";
import {Link} from "react-router-dom";
import {collection, onSnapshot, orderBy, query, where} from "firebase/firestore";
import {db} from "../firebase";
import {Layout} from "../componentes/Layout";

/**
 * Lista de tickets do Chat de Suporte (ver `functions/suporteChatService.js`)
 * em tempo real, uma aba por `status`. Cada aba usa o índice composto
 * `status ASC, atualizadoEm DESC` (ver `firestore.indexes.json`) — a
 * leitura em si já é permitida pelo Firestore Rules pra quem tem
 * `role` em atendente/supervisor/admin (`temRolePainel`), sem precisar
 * de nenhuma callable.
 */
const ABAS = [
  {status: "aguardando_humano", rotulo: "Aguardando atendimento"},
  {status: "em_atendimento_humano", rotulo: "Em atendimento"},
  {status: "ia_ativa", rotulo: "Com a IA"},
  {status: "resolvido", rotulo: "Resolvidos"},
];

const ROTULOS_PLANO = {
  free: "Free",
  premium: "Premium",
  site: "Site",
};

function formatarData(timestamp) {
  if (!timestamp) return "—";
  return timestamp.toDate().toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function Tickets() {
  const [abaAtiva, setAbaAtiva] = useState(ABAS[0].status);
  const [tickets, setTickets] = useState([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState(null);

  useEffect(() => {
    setCarregando(true);
    setErro(null);
    const q = query(
      collection(db, "suporte_tickets"),
      where("status", "==", abaAtiva),
      orderBy("atualizadoEm", "desc"),
    );
    const unsub = onSnapshot(
      q,
      (snap) => {
        setTickets(snap.docs.map((d) => ({id: d.id, ...d.data()})));
        setCarregando(false);
      },
      (e) => {
        console.error("[Tickets]", e);
        setErro("Não foi possível carregar os tickets.");
        setCarregando(false);
      },
    );
    return unsub;
  }, [abaAtiva]);

  return (
    <Layout>
      <h1>Tickets de Suporte</h1>

      <div className="abas">
        {ABAS.map((aba) => (
          <button
            key={aba.status}
            type="button"
            className={aba.status === abaAtiva ? "aba aba-ativa" : "aba"}
            onClick={() => setAbaAtiva(aba.status)}
          >
            {aba.rotulo}
          </button>
        ))}
      </div>

      {carregando && <p className="texto-secundario">Carregando...</p>}
      {erro && <p className="erro">{erro}</p>}

      {!carregando && !erro && tickets.length === 0 && (
        <p className="texto-secundario">Nenhum ticket nessa categoria.</p>
      )}

      {!carregando && tickets.length > 0 && (
        <ul className="lista-tickets">
          {tickets.map((ticket) => (
            <li key={ticket.id}>
              <Link to={`/tickets/${ticket.id}`} className="cartao-ticket">
                <div className="cartao-ticket-topo">
                  <span className={`badge-plano badge-plano-${ticket.planoNoMomento}`}>
                    {ROTULOS_PLANO[ticket.planoNoMomento] || ticket.planoNoMomento}
                  </span>
                  <span className="texto-muted">{formatarData(ticket.atualizadoEm)}</span>
                </div>
                <p className="cartao-ticket-preview">
                  {ticket.ultimaMensagemPreview || "(sem mensagens ainda)"}
                </p>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </Layout>
  );
}
