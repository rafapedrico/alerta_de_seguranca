/**
 * Guarda de rota: exige login E uma `role` dentro de `rolesPermitidas`.
 * Só controla a UI — a segurança real é imposta de novo no backend
 * (ver cabeçalho de AuthContext.jsx).
 */
import {Navigate} from "react-router-dom";
import {useAuth} from "../contexto/AuthContext";

export function RotaProtegida({rolesPermitidas, children}) {
  const {usuario, role, carregando} = useAuth();

  if (carregando) {
    return <div className="tela-carregando">Carregando...</div>;
  }
  if (!usuario) {
    return <Navigate to="/login" replace />;
  }
  if (!rolesPermitidas.includes(role)) {
    return <Navigate to="/sem-acesso" replace />;
  }
  return children;
}
