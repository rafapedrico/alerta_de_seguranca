import {useAuth} from "../contexto/AuthContext";

/**
 * Home do painel — por enquanto só o layout com sidebar e um resumo de
 * boas-vindas. Os módulos reais (Tickets, Alertas, Planos) entram nas
 * próximas milestones, cada um como sua própria rota protegida por
 * `rolesPermitidas` específica.
 */
export function Dashboard() {
  const {usuario, role, sair} = useAuth();

  return (
    <div className="layout-admin">
      <aside className="sidebar">
        <h2>Guardião X</h2>
        <nav>
          {["atendente", "supervisor", "admin"].includes(role) && (
            <span className="link-desabilitado" title="Em breve">
              Tickets de Suporte
            </span>
          )}
          {["supervisor", "admin"].includes(role) && (
            <span className="link-desabilitado" title="Em breve">
              Monitoramento de Alertas
            </span>
          )}
          {role === "admin" && (
            <span className="link-desabilitado" title="Em breve">
              Gestão de Planos
            </span>
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
      <main className="conteudo-principal">
        <h1>Bem-vindo(a)</h1>
        <p>
          Os módulos de Tickets, Monitoramento de Alertas e Gestão de Planos
          chegam nas próximas etapas de implementação.
        </p>
      </main>
    </div>
  );
}
