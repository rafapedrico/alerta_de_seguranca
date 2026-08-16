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

## Pipeline de entrega via Push FCM (`alertaHibridoService.js`)

Ambos os gatilhos acima terminam chamando `dispararAlertaHibrido`:

1. Resolve, por telefone, quais dos contatos de emergência têm conta no
   app (`usuarios` com `telefone` igual).
2. Envia um Push FCM gratuito (alta prioridade, App-para-App) para quem
   foi encontrado.
3. Registra `entregas_alerta/{id}` como bookkeeping de entrega (ver
   `FirebaseSyncService.confirmarEntregaAlerta`/`FcmService` no app).

Logs em cada etapa: `[FCM Enviado]`, `[dispararAlertaHibrido]`.

> **Removido em 2026-08-11** (a pedido do usuário): toda a integração de
> WhatsApp/Twilio (contingência paga de alerta, webhook de suporte com
> IA, templates) e a Carteira de Créditos que a financiava
> (`walletService.js`, `comprasService.js`, `smsGateway.js`,
> `transbordoWhatsappMonitor.js`, `whatsappWebhook.js`,
> `whatsappSuporteIA.js`, `whatsappTemplates.js`). O único canal de nuvem
> restante é o Push FCM acima; o envio real de SMS de emergência
> continua sendo feito 100% localmente pelo aparelho (`SmsSender.kt` via
> `SmsManager` do Android, ver `EmergencyAlertService` no app Flutter) —
> nunca por uma Cloud Function.

## Pré-requisitos para deploy

1. Firebase CLI instalado e autenticado: `npm install -g firebase-tools`
   seguido de `firebase login`.
2. Dentro de `functions/`: `npm install`.

## Deploy

```bash
# Da raiz do projeto (onde está firebase.json):
firebase deploy --only functions
firebase deploy --only firestore:rules,firestore:indexes
```

## Regras do Firestore (`firestore.rules`)

Exigem Firebase Auth real (`request.auth.uid`) — cada usuário só lê/edita
o próprio documento em `usuarios/{uid}`, e `entregas_alerta` é
inteiramente gerido pelas Cloud Functions (exceto a subcoleção
`confirmacoes`, onde cada usuário só grava a própria confirmação de
entrega).

## Testando localmente (emulador)

```bash
firebase emulators:start --only functions,firestore
```
