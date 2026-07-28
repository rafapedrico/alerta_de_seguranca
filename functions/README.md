# Cloud Functions — Guardião X (projeto Firebase "guardiaox")

Camada de resiliência na nuvem, com dois gatilhos de alerta e um pipeline
híbrido de entrega compartilhado por ambos:

- **Reativo** (`aoReceberAlertaTentativaDesarme`, `index.js`): dispara
  quando o app grava um alerta minimalista em
  `usuarios/{usuarioId}/alertas` (2 PINs incorretos consecutivos no
  desarme antecipado).
- **Agendado** (`monitorarAlarmesAgendados`, `scheduledAlarmMonitor.js`):
  roda a cada 2 minutos e verifica `alarmes_agendados` em busca de
  check-ins de rotina vencidos sem confirmação (dead man's switch de 48h).

## Pipeline híbrido de entrega (`alertaHibridoService.js`)

Ambos os gatilhos acima terminam chamando `dispararAlertaHibrido`:

1. Resolve, por telefone, quais dos contatos de emergência têm conta no
   app (`usuarios` com `telefone` igual) e envia um Push FCM gratuito
   (alta prioridade) para quem foi encontrado.
2. Cria `entregas_alerta/{id}` com prazo de 60s (`prazoTransbordoEpochMs`).
3. O job agendado `processarTransbordoAlertas`
   (`transbordoWhatsappMonitor.js`, roda a cada 1 min) verifica, depois
   desse prazo, quem NÃO confirmou a entrega no app
   (`entregas_alerta/{id}/confirmacoes/{uid}`) e, só para esses contatos:
   - Se `whatsappHabilitado` estiver desligado no contato → cancela.
   - Se o saldo (`usuarios/{uid}.saldoUsd`) for menor que $0.10 → cancela.
   - Caso contrário, debita $0.10 (via `walletService.js`, transação
     atômica) e envia o WhatsApp de contingência via Twilio
     (`smsGateway.js`).

Logs em cada etapa: `[FCM Enviado]`, `[Aguardando 60s]`,
`[Verificando Chave/Saldo USD]`, `[Desconto Aplicado]` /
`[Operação Cancelada]`.

## Carteira em USD (`walletService.js` + `comprasService.js`)

`saldoUsd` e a subcoleção `historicoCreditos` só podem ser alterados pelo
Admin SDK (ver `firestore.rules`) — nunca pelo cliente. Créditos entram
por `confirmarCompraCredito` (callable `onCall`), que verifica a compra
via Google Play Developer API antes de creditar (fail-closed: sem
verificação bem-sucedida, nenhum saldo é dado). Requer:

1. Os produtos consumíveis criados no Play Console
   (`credito_usd_1`, `credito_usd_5`, `credito_usd_10`).
2. Uma service account do Google Cloud com acesso à Play Developer API
   habilitado no Play Console ("Ver ordens financeiras e gerenciar
   assinaturas"), salva como secret:
   ```bash
   firebase functions:secrets:set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON
   ```
   Sem este secret configurado, `confirmarCompraCredito` rejeita toda
   compra (loga o motivo) em vez de creditar sem verificação.

## Gateway de WhatsApp (Twilio)

`smsGateway.js` envia via Twilio WhatsApp Sandbox — cada destinatário
precisa ter feito o opt-in do sandbox antes de poder receber mensagens.
Credenciais via Secret Manager:

```bash
firebase functions:secrets:set TWILIO_ACCOUNT_SID
firebase functions:secrets:set TWILIO_AUTH_TOKEN
firebase functions:secrets:set TWILIO_FROM_NUMBER
```

Sem essas credenciais configuradas, o envio degrada graciosamente para um
aviso de log (não quebra o restante do pipeline).

## Pré-requisitos para deploy

1. **Plano Blaze (pay-as-you-go)** no projeto `guardiaox` — necessário
   para chamadas de rede a APIs externas (Twilio, Google Play Developer
   API). Console do Firebase → Configurações do projeto → Uso e
   faturamento → Detalhes e configurações → Alterar plano.
2. Firebase CLI instalado e autenticado: `npm install -g firebase-tools`
   seguido de `firebase login`.
3. Dentro de `functions/`: `npm install`.

## Deploy

```bash
# Da raiz do projeto (onde está firebase.json):
firebase deploy --only functions
firebase deploy --only firestore:rules,firestore:indexes
```

## Regras do Firestore (`firestore.rules`)

Exigem Firebase Auth real (`request.auth.uid`) — cada usuário só lê/edita
o próprio documento em `usuarios/{uid}`, `saldoUsd` e `historicoCreditos`
são somente leitura para o cliente, e `entregas_alerta` é inteiramente
gerido pelas Cloud Functions (exceto a subcoleção `confirmacoes`, onde
cada usuário só grava a própria confirmação de entrega).

## Testando localmente (emulador)

```bash
firebase emulators:start --only functions,firestore
```
