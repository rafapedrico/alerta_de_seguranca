import {Layout} from "../componentes/Layout";

/**
 * Home do painel — resumo de boas-vindas. Ver `Layout.jsx` pra
 * sidebar/navegação (extraída daqui na milestone M2).
 */
export function Dashboard() {
  return (
    <Layout>
      <h1>Bem-vindo(a)</h1>
      <p>
        Os módulos de Monitoramento de Alertas e Gestão de Planos chegam nas
        próximas etapas de implementação.
      </p>
    </Layout>
  );
}
