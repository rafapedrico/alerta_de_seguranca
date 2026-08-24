import {useAuth} from "../contexto/AuthContext";

export function SemAcesso() {
  const {sair} = useAuth();
  return (
    <div className="tela-login">
      <div className="cartao-login">
        <h1>Sem acesso</h1>
        <p>Sua conta está logada, mas não tem permissão pra acessar o Painel Admin.</p>
        <button type="button" onClick={sair}>
          Sair
        </button>
      </div>
    </div>
  );
}
