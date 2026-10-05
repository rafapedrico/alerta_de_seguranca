# Roteiro do vídeo para a Google Play — localização contínua (Android)

Exigido pelas declarações de **localização em segundo plano** e de
**serviço em primeiro plano do tipo `location`** (ver
[`google-play-localizacao-continua.md`](google-play-localizacao-continua.md)).
Nos moldes do roteiro do iOS.

Duração alvo: **até 2 minutos** (a Google pede vídeo curto), gravação de tela
do Android (Configurações rápidas → Gravador de tela) **sem áudio**, com
legendas em inglês adicionadas depois. Enviar como **link não listado do
YouTube**.

## O que preparar antes

1. **Dois aparelhos**:
   - **Aparelho A (Android)** — conta 1, a pessoa monitorada. É neste que se
     grava.
   - **Aparelho B** (Android ou iPhone) — conta 2, quem monitora. Aparece só
     no fim (mapa).
2. **Duas contas de teste** novas, com e-mail/senha (não use contas pessoais):
   - telefones diferentes em *Meu Perfil*;
   - **as duas Premium** (painel admin → Planos);
   - deixe a conta 2 pedir a localização da conta 1, e **aprove durante a
     gravação** (cena 2).
3. No **aparelho A**, antes de gravar:
   - desinstalar e instalar o app de novo (para o Android pedir as permissões
     de novo), ou em Configurações → Apps → Guardião-X → Permissões →
     Localização deixar "Não permitir";
   - Economia de bateria **desligada**.
4. Anotar as credenciais para *Acesso ao app* no Play Console.

## Cenas

| # | Tela (aparelho A, salvo indicação) | O que mostrar | Legenda sugerida (EN) |
|---|---|---|---|
| 1 | Abertura do app → aba **Monitoramento** | O app não pediu "Permitir o tempo todo" ao abrir | "Background location is not requested at first launch." |
| 2 | Notificação/diálogo do pedido da conta 2 | Tocar em **Permitir** | "The user approves a trusted contact's request." |
| 3 | Quadro **Compartilhamento contínuo** no topo da aba | Texto "Quem pode ver sua localização: …" e o switch desligado | "Continuous sharing is opt-in and lists who can see the location." |
| 4 | Ligar o switch → etapa **1/2** | Ler o texto; **Permitir localização** → diálogo do Android → **Durante o uso do app** | "Step 1: explanation, then 'While using the app'." |
| 5 | Etapa **2/2** (divulgação em destaque) | Mostrar o texto inteiro ("O Guardião-X coleta dados de localização… mesmo quando o app está fechado ou não está em uso"); mostrar que o botão verde só habilita depois de **marcar "Concordo…"**; tocar **Permitir o tempo todo** → tela do Android → **Permitir o tempo todo** → voltar | "Prominent disclosure and explicit consent before 'Allow all the time'." |
| 6 | Aba Monitoramento | Quadro: "Sua localização está sendo compartilhada continuamente com: Conta 2", switch ligado, "Ativo: sua posição é atualizada mesmo com o app fechado" | "The user always sees who receives the location." |
| 7 | Puxar a barra de notificações | Notificação fixa "Guardião-X está compartilhando sua localização com 1 contato" | "A persistent notification is shown while the foreground service runs." |
| 8 | Configurações → Status de Permissões | Card **Rastreamento contínuo: Ativado** e os requisitos marcados | "Status screen shows every requirement." |
| 9 | Fechar o app pelos recentes; caminhar/dirigir ~300 m | (pode cortar a caminhada) — a notificação continua na barra | "App closed; the user moves; the service keeps running." |
| 10 | **Aparelho B** → Monitoramento → card da conta 1 | "Atualizado agora" → **Ver no mapa** abre a posição atual | "The approved contact sees the current position and its time." |
| 11 | Aparelho A → Monitoramento → **desligar o switch** | Texto "Pausado…"; a notificação fixa some | "Sharing can be paused at any time; the service stops." |
| 12 | Aparelho B → card do contato | "Este contato está sem atualização contínua…" | "The contact is informed sharing is paused." |

## Dicas

- Se preferir dispensar legendas, coloque o aparelho A em inglês
  (Configurações → Sistema → Idiomas) antes de gravar.
- Na cena 9, corte a espera; o que importa é a notificação fixa visível com o
  app fechado e a posição nova chegando no aparelho B.
- Não mostre e-mails, telefones ou nomes reais.
