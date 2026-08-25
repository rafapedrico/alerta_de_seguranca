import {Link, useLocation} from "react-router-dom";
import {useAuth} from "../contexto/AuthContext";

/**
 * Casca (sidebar + área de conteúdo) compartilhada por todas as telas
 * logadas do painel — extraída do antigo `Dashboard.jsx` (M0+M1) pra ser
 * reaproveitada pelo módulo de Tickets (M2) e pelos próximos
 * (Monitoramento de Alertas, Gestão de Planos), cada um ainda como
 * placeholder desabilitado até ganhar sua própria rota.
 */
const ITENS_NAV = [
  {rota: "/tickets", rotulo: "Tickets de Suporte", roles: ["atendente", "supervisor", "admin"]},
  {rota: null, rotulo: "Monitoramento de Alertas", roles: ["supervisor", "admin"]},
  {rota: null, rotulo: "Gestão de Planos", roles: ["admin"]},
];

export function Layout({children}) {
  const {usuario, role, sair} = useAuth();
  const location = useLocation();

  return (
    <div className="layout-admin">
      <aside className="sidebar">
        <h2>Guardião X</h2>
        <nav>
          {ITENS_NAV.filter((item) => item.roles.includes(role)).map((item) =>
            item.rota ? (
              <Link
                key={item.rotulo}
                to={item.rota}
                className={location.pathname.startsWith(item.rota) ? "link-ativo" : ""}
              >
                {item.rotulo}
              </Link>
            ) : (
              <span key={item.rotulo} className="link-desabilitado" title="Em breve">
                {item.rotulo}
              </span>
            ),
          )}
        </nav>
        <div className="sidebar-rodape">
          <span>{usuario?.email}</span>
          <span className="badge-role">{role}</span>
          <button type="button" onClick={sair}>
            Sair
          </button>
        </div>
      </aside>
      <main className="conteudo-principal">{children}</main>
    </div>
  );
}
