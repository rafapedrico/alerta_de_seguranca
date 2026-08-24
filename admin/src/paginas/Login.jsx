import {useState} from "react";
import {Navigate} from "react-router-dom";
import {signInWithEmailAndPassword} from "firebase/auth";
import {auth} from "../firebase";
import {useAuth} from "../contexto/AuthContext";

export function Login() {
  const {usuario, carregando} = useAuth();
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [erro, setErro] = useState(null);
  const [enviando, setEnviando] = useState(false);

  if (!carregando && usuario) {
    return <Navigate to="/" replace />;
  }

  async function aoEnviar(ev) {
    ev.preventDefault();
    setErro(null);
    setEnviando(true);
    try {
      await signInWithEmailAndPassword(auth, email, senha);
    } catch (e) {
      setErro("E-mail ou senha inválidos.");
      console.error("[Login]", e);
    } finally {
      setEnviando(false);
    }
  }

  return (
    <div className="tela-login">
      <form onSubmit={aoEnviar} className="cartao-login">
        <h1>Painel Admin — Guardião X</h1>
        <label>
          E-mail
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
            autoFocus
          />
        </label>
        <label>
          Senha
          <input
            type="password"
            value={senha}
            onChange={(e) => setSenha(e.target.value)}
            required
          />
        </label>
        {erro && <p className="erro">{erro}</p>}
        <button type="submit" disabled={enviando}>
          {enviando ? "Entrando..." : "Entrar"}
        </button>
      </form>
    </div>
  );
}
