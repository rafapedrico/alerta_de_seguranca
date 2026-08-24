import {BrowserRouter, Routes, Route} from "react-router-dom";
import {AuthProvider} from "./contexto/AuthContext";
import {RotaProtegida} from "./componentes/RotaProtegida";
import {Login} from "./paginas/Login";
import {Dashboard} from "./paginas/Dashboard";
import {SemAcesso} from "./paginas/SemAcesso";

const TODAS_AS_ROLES = ["atendente", "supervisor", "admin"];

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
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  );
}
