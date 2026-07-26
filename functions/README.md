# Cloud Functions — Guardião X (projeto Firebase "guardiaox")

Camada de resiliência na nuvem: quando o app detecta 2 PINs incorretos
consecutivos no desarme antecipado (abas Família ou Segurança), ele grava
um alerta minimalista no Firestore (`usuarios/{usuarioId}/alertas`). Esta
função é disparada automaticamente por esse evento, busca a última
localização conhecida do usuário (atualizada a cada 1 minuto pelo app
enquanto o monitoramento estiver ativo) e os contatos de emergência
sincronizados, monta a mensagem de alerta e aciona o envio.

## Pendência conhecida: gateway de SMS

`enviarSmsParaContatos` em `index.js` **ainda não envia SMS de verdade** —
apenas registra (`logger.warn`) o que seria enviado e marca o alerta como
`processado`. Isso permite testar todo o pipeline (Firestore → trigger →
montagem da mensagem) sem custo e sem exigir o plano Blaze para chamadas
externas.

Para ativar o envio real, escolha um gateway de SMS (Twilio, AWS SNS,
Zenvia, Infobip, etc.), adicione a dependência correspondente ao
`package.json` e implemente a chamada dentro de `enviarSmsParaContatos`
(há um exemplo comentado com Twilio no próprio arquivo).

## Pré-requisitos para deploy

1. **Plano Blaze (pay-as-you-go)** no projeto `guardiaox` — necessário
   para que a função consiga fazer chamadas de rede a APIs externas (o
   gateway de SMS). Sem isso, o deploy funciona, mas qualquer chamada de
   saída para fora do Google será bloqueada.
   - Console do Firebase → Configurações do projeto → Uso e faturamento
     → Detalhes e configurações → Alterar plano.
2. Firebase CLI instalado e autenticado: `npm install -g firebase-tools`
   seguido de `firebase login`.
3. Dentro de `functions/`: `npm install`.

## Deploy

```bash
# Da raiz do projeto (onde está firebase.json):
firebase deploy --only functions
firebase deploy --only firestore:rules
```

## Regras do Firestore (`firestore.rules`)

Estão **temporariamente abertas** (sem exigir autenticação), pois o app
ainda não tem Firebase Auth real — mesma situação do backend FastAPI
local, que também não tem autenticação. Há um `TODO` explícito no arquivo
descrevendo como travá-las assim que o login real for implementado.

## Testando localmente (emulador)

```bash
firebase emulators:start --only functions,firestore
```
