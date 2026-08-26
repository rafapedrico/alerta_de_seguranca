import {useCallback, useEffect, useState} from "react";
import {httpsCallable} from "firebase/functions";
import {functions} from "../firebase";
import {Layout} from "../componentes/Layout";

/**
 * Monitoramento de Alertas (M3) — visão agregada, entre todos os
 * usuários, dos disparos de emergência (`usuarios/{uid}/alertas`, ver
 * `functions/alertaMonitoramentoService.js`). Diferente de Tickets, não
 * há leitura direta do Firestore aqui: as regras restringem essa
 * subcoleção ao próprio dono, então a listagem cross-usuário só existe
 * via a callable `listarAlertasMonitoramento` (Admin SDK). Por isso a
 * lista é atualizada por polling manual/botão "Atualizar", não por
 * `onSnapshot` em tempo real.
 */
const ROTULOS_TIPO = {
  sos_fisico: "SOS físico/manual",
  sos_fisico_foto: "Evidência fotográfica",
  tentativa_desarme_incorreto: "Tentativa de desarme incorreto",
};

function formatarData(timestampSegundos) {
  if (!timestampSegundos) return "—";
  return new Date(timestampSegundos._seconds * 1000).toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    year: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function Alertas() {
  const [apenasPendentes, setApenasPendentes] = useState(true);
  const [alertas, setAlertas] = useState([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState(null);
  const [encerrandoId, setEncerrandoId] = useState(null);

  const carregar = useCallback(async () => {
    setCarregando(true);
    setErro(null);
    try {
      const listar = httpsCallable(functions, "listarAlertasMonitoramento");
      const res = await listar({apenasPendentes});
      setAlertas(res.data.alertas || []);
    } catch (e) {
      console.error("[Alertas] listar", e);
      setErro("Não foi possível carregar os alertas.");
    } finally {
      setCarregando(false);
    }
  }, [apenasPendentes]);

  useEffect(() => {
    carregar();
  }, [carregar]);

  async function aoEncerrar(alerta) {
    setEncerrandoId(alerta.id);
    try {
      const encerrar = httpsCallable(functions, "encerrarAlertaMonitoramento");
      await encerrar({usuarioId: alerta.usuarioId, alertaId: alerta.id});
      setAlertas((atuais) =>
        apenasPendentes ?
          atuais.filter((a) => a.id !== alerta.id) :
          atuais.map((a) => (a.id === alerta.id ? {...a, revisadoPeloPainel: true} : a)),
      );
    } catch (e) {
      console.error("[Alertas] encerrar", e);
      setErro("Não foi possível encerrar este alerta.");
    } finally {
      setEncerrandoId(null);
    }
  }

  return (
    <Layout>
      <h1>Monitoramento de Alertas</h1>

      <div className="abas">
        <button
          type="button"
          className={apenasPendentes ? "aba aba-ativa" : "aba"}
          onClick={() => setApenasPendentes(true)}
        >
          Pendentes de revisão
        </button>
        <button
          type="button"
          className={!apenasPendentes ? "aba aba-ativa" : "aba"}
          onClick={() => setApenasPendentes(false)}
        >
          Todos (mais recentes)
        </button>
        <button type="button" className="aba" onClick={carregar} disabled={carregando}>
          {carregando ? "Atualizando..." : "Atualizar"}
        </button>
      </div>

      {erro && <p className="erro">{erro}</p>}
      {carregando && <p className="texto-secundario">Carregando...</p>}

      {!carregando && alertas.length === 0 && (
        <p className="texto-secundario">Nenhum alerta nessa categoria.</p>
      )}

      {!carregando && alertas.length > 0 && (
        <ul className="lista-alertas">
          {alertas.map((alerta) => (
            <li key={alerta.id} className="cartao-alerta">
              <div className="cartao-alerta-topo">
                <span className="badge-status">{ROTULOS_TIPO[alerta.tipo] || alerta.tipo}</span>
                <span className="texto-muted">{formatarData(alerta.criadoEm)}</span>
              </div>
              <p className="cartao-alerta-usuario">
                <strong>{alerta.nomeUsuario || "Usuário sem nome"}</strong>
                {alerta.telefoneUsuario ? ` · ${alerta.telefoneUsuario}` : ""}
                <span className="texto-muted"> (uid: {alerta.usuarioId})</span>
              </p>
              <p className="texto-secundario">
                {alerta.localizacaoUsadaNoAlerta || "Localização ainda não processada."}
              </p>
              {alerta.latitude != null && alerta.longitude != null && (
                <a
                  className="link-mapa"
                  href={`https://maps.google.com/?q=${alerta.latitude},${alerta.longitude}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  Ver no mapa
                </a>
              )}
              {alerta.fotoUrl && (
                <a className="link-mapa" href={alerta.fotoUrl} target="_blank" rel="noreferrer">
                  Ver foto
                </a>
              )}
              <p className="texto-muted">
                Contatos notificados: {alerta.totalContatosNotificados ?? "—"} ·{" "}
                {alerta.processado ? "Pipeline processado" : "Pipeline em andamento"}
              </p>

              {alerta.revisadoPeloPainel ? (
                <span className="texto-muted">Revisado pelo painel</span>
              ) : (
                <button
                  type="button"
                  onClick={() => aoEncerrar(alerta)}
                  disabled={encerrandoId === alerta.id}
                >
                  {encerrandoId === alerta.id ? "Encerrando..." : "Marcar como revisado"}
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </Layout>
  );
}
