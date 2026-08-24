/**
 * Contexto de autenticação do Painel de Admin — expõe o usuário logado
 * (Firebase Auth, e-mail/senha) e a `role` da custom claim (setada
 * exclusivamente via `functions/scripts/definirRoleAdmin.js`). Isso é
 * só pra CONTROLAR A UI (esconder/mostrar telas) — a segurança de
 * verdade é sempre imposta de novo no Firestore Rules/Cloud Functions,
 * que não confiam em nada que vem do cliente.
 */
import {createContext, useContext, useEffect, useState} from "react";
import {onAuthStateChanged, signOut as signOutFirebase} from "firebase/auth";
import {auth} from "../firebase";

const AuthContext = createContext(null);

export function AuthProvider({children}) {
  const [usuario, setUsuario] = useState(null);
  const [role, setRole] = useState(null);
  const [carregando, setCarregando] = useState(true);

  useEffect(() => {
    const unsub = onAuthStateChanged(auth, async (usuarioAtual) => {
      if (!usuarioAtual) {
        setUsuario(null);
        setRole(null);
        setCarregando(false);
        return;
      }
      // `true` força buscar o token de novo (não usar um cache que
      // ainda não tenha a claim, ex: logo depois de
      // definirRoleAdmin.js ser rodado pela primeira vez).
      const resultado = await usuarioAtual.getIdTokenResult(true);
      setUsuario(usuarioAtual);
      setRole(resultado.claims.role || null);
      setCarregando(false);
    });
    return unsub;
  }, []);

  async function sair() {
    await signOutFirebase(auth);
  }

  return (
    <AuthContext.Provider value={{usuario, role, carregando, sair}}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth precisa estar dentro de <AuthProvider>");
  return ctx;
}
