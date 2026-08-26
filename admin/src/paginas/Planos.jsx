import {useEffect, useState} from "react";
import {httpsCallable} from "firebase/functions";
import {functions} from "../firebase";
import {Layout} from "../componentes/Layout";

/**
 * Gestão de Planos (M3) — parâmetros operacionais do ciclo do Plano Free
 * e busca/visualização do status de plano de um usuário específico (ver
 * `functions/planoAdminService.js`).
 *
 * DECISÃO DELIBERADA: este módulo nunca concede Premium, só revoga —
 * conceder continua exclusivo do Console do Firebase (ver comentário no
 * topo de `planoAdminService.js`).
 */
export function Planos() {
  const [parametros, setParametros] = useState(null);
  const [erroParametros, setErroParametros] = useState(null);

  const [busca, setBusca] = useState("");
  const [resultado, setResultado] = useState(null);
  const [buscando, setBuscando] = useState(false);
  const [erroBusca, setErroBusca] = useState(null);
  const [revogando, setRevogando] = useState(false);

  useEffect(() => {
    const obterParametros = httpsCallable(functions, "obterParametrosPlanos");
    obterParametros()
      .then((res) => setParametros(res.data))
      .catch((e) => {
        console.error("[Planos] parametros", e);
        setErroParametros("Não foi possível carregar os parâmetros dos planos.");
      });
  }, []);

  async function aoBuscar(ev) {
    ev.preventDefault();
    if (!busca.trim()) return;
    setBuscando(true);
    setErroBusca(null);
    setResultado(null);
    try {
      const buscar = httpsCallable(functions, "buscarUsuarioPlano");
      const res = await buscar({busca: busca.trim()});
      setResultado(res.data);
    } catch (e) {
      console.error("[Planos] buscar", e);
      setErroBusca("Não foi possível buscar este usuário.");
    } finally {
      setBuscando(false);
    }
  }

  async function aoRevogarPremium() {
    if (!resultado?.uid) return;
    setRevogando(true);
    try {
      const revogar = httpsCallable(functions, "revogarPremiumAdmin");
      await revogar({uid: resultado.uid});
      setResultado((atual) => ({...atual, isPremium: false}));
    } catch (e) {
      console.error("[Planos] revogar", e);
      setErroBusca("Não foi possível revogar o Premium deste usuário.");
    } finally {
      setRevogando(false);
    }
  }

  return (
    <Layout>
      <h1>Gestão de Planos</h1>

      <section className="cartao-secao">
        <h2>Parâmetros operacionais</h2>
        {erroParametros && <p className="erro">{erroParametros}</p>}
        {!parametros && !erroParametros && <p className="texto-secundario">Carregando...</p>}
        {parametros && (
          <ul className="lista-parametros">
            <li>
              Ciclo do Plano Free: <strong>{parametros.duracaoCicloDias} dias</strong>, sendo{" "}
              <strong>{parametros.duracaoAtivaDias} dias ativos</strong> por ciclo.
            </li>
            <li>
              Limite mensal de produção: <strong>{parametros.limiteAlertasGratuitoProducao} alertas</strong> /{" "}
              <strong>{parametros.limiteFotosGratuitoProducao} fotos</strong> (Plano Free).
            </li>
            {parametros.limitesAtuaisSaoDeTeste && (
              <li className="texto-aviso">
                Atenção: no código-fonte esses limites estão temporariamente elevados para{" "}
                {parametros.limiteAlertasGratuitoAtual} / {parametros.limiteFotosGratuitoAtual}{" "}
                (TODO de teste ainda não revertido em <code>plano_limite_service.dart</code>).
              </li>
            )}
          </ul>
        )}
      </section>

      <section className="cartao-secao">
        <h2>Buscar usuário</h2>
        <form className="form-busca" onSubmit={aoBuscar}>
          <input
            type="text"
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
            placeholder="uid ou e-mail"
          />
          <button type="submit" disabled={buscando}>
            {buscando ? "Buscando..." : "Buscar"}
          </button>
        </form>
        {erroBusca && <p className="erro">{erroBusca}</p>}

        {resultado && !resultado.encontrado && (
          <p className="texto-secundario">Nenhum usuário encontrado.</p>
        )}

        {resultado && resultado.encontrado && (
          <div className="cartao-usuario-plano">
            <p>
              <strong>{resultado.nome || "(sem nome)"}</strong>
              <span className="texto-muted"> — uid: {resultado.uid}</span>
            </p>
            <p className="texto-secundario">
              {resultado.email || "—"} {resultado.telefone ? `· ${resultado.telefone}` : ""}
            </p>
            <p>
              <span className={`badge-plano badge-plano-${resultado.isPremium ? "premium" : "free"}`}>
                {resultado.isPremium ? "Premium" : "Free"}
              </span>
            </p>
            {!resultado.isPremium && (
              <p className="texto-secundario">
                {resultado.diaAtual == null ?
                  "Ciclo ainda não iniciado (usuário nunca abriu o app logado)." :
                  `Dia ${resultado.diaAtual} do ciclo — ${resultado.ativo ? "ativo" : "bloqueado"}.`}
              </p>
            )}
            {resultado.isPremium && (
              <button type="button" onClick={aoRevogarPremium} disabled={revogando}>
                {revogando ? "Revogando..." : "Revogar Premium"}
              </button>
            )}
          </div>
        )}
      </section>
    </Layout>
  );
}
