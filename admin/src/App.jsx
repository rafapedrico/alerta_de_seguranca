import {BrowserRouter, Routes, Route} from "react-router-dom";
import {AuthProvider} from "./contexto/AuthContext";
import {RotaProtegida} from "./componentes/RotaProtegida";
import {Login} from "./paginas/Login";
import {Dashboard} from "./paginas/Dashboard";
import {SemAcesso} from "./paginas/SemAcesso";
import {Tickets} from "./paginas/Tickets";
import {TicketDetalhe} from "./paginas/TicketDetalhe";
import {Alertas} from "./paginas/Alertas";
import {Planos} from "./paginas/Planos";

const TODAS_AS_ROLES = ["atendente", "supervisor", "admin"];
// Mesma whitelist de `ROLES_COM_ACESSO_TICKETS` em
// functions/suporteChatService.js e `temRolePainel(['atendente', ...])`
// em firestore.rules — só controla a UI, a segurança real é imposta de
// novo no backend (ver AuthContext.jsx).
const ROLES_TICKETS = ["atendente", "supervisor", "admin"];
// Mesma whitelist de `ROLES_COM_ACESSO_ALERTAS` em
// functions/alertaMonitoramentoService.js.
const ROLES_ALERTAS = ["supervisor", "admin"];
// Mesma checagem `role === "admin"` de functions/planoAdminService.js.
const ROLES_PLANOS = ["admin"];

export function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="/sem-acesso" element={<SemAcesso />} />
          <Route
            path="/"
            element={
              <RotaProtegida rolesPermitidas={TODAS_AS_ROLES}>
                <Dashboard />
              </RotaProtegida>
            }
          />
          <Route
            path="/tickets"
            element={
              <RotaProtegida rolesPermitidas={ROLES_TICKETS}>
                <Tickets />
              </RotaProtegida>
            }
          />
          <Route
            path="/tickets/:ticketId"
            element={
              <RotaProtegida rolesPermitidas={ROLES_TICKETS}>
                <TicketDetalhe />
              </RotaProtegida>
            }
          />
          <Route
            path="/alertas"
            element={
              <RotaProtegida rolesPermitidas={ROLES_ALERTAS}>
                <Alertas />
              </RotaProtegida>
            }
          />
          <Route
            path="/planos"
            element={
              <RotaProtegida rolesPermitidas={ROLES_PLANOS}>
                <Planos />
              </RotaProtegida>
            }
          />
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  );
}
