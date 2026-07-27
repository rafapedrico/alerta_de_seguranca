# cloud_functions/ — Esboço: monitoramento agendado de alarmes (heartbeat & cloud alert)

**Esta pasta é um ESBOÇO/DRAFT, ainda NÃO conectado ao deploy.** O
`firebase.json` da raiz do projeto só aponta para `functions/` (codebase
`default`) — o código aqui dentro não é implantado por
`firebase deploy --only functions` enquanto permanecer assim. Veja
"Como ativar" no final deste arquivo.

Ela existe separada de `functions/` (a Cloud Function já em produção, que
reage a `usuarios/{usuarioId}/alertas/{alertaId}`) porque implementa uma
arquitetura DIFERENTE e nova: em vez de reagir a um evento já disparado
pelo app, esta função roda em **horário fixo** (`onSchedule`, ex: a cada 5
minutos) e ela mesma decide se algum alarme de rotina passou do prazo sem
confirmação — cobrindo o cenário em que o aparelho é destruído, desligado
ou perde sinal ANTES do alarme/alerta local conseguir agir.

## Modelo de dados (Firestore)

Coleção `alarmes_agendados/{idAlarme}` (ver `AlarmeAgendadoModel` no app
Flutter, `lib/models/alarme_agendado_model.dart`):

```jsonc
{
  "idAlarme": "12",
  "dataHoraDisparo": "<Timestamp>",
  "status": "PENDENTE" | "CONFIRMADO_SEGURA" | "ALERTA_DISPARADO",
  "ultimaLocalizacao": { "lat": -23.5, "lng": -47.47, "timestamp": "<Timestamp>" },
  "telefonesEmergencia": ["+5511999999999"],
  "tokensGuardioes": ["<token FCM>"]
}
```

Ciclo de vida do campo `status` (escrito por três atores diferentes):

1. **App (heartbeat)** — `BackgroundLocationHeartbeatService` cria/atualiza
   o documento como `PENDENTE` a cada 5 minutos, sempre que faltar ≤2h
   para o próximo disparo de um alarme de rotina ativo.
2. **App (PIN correto)** — `RotinaAlarmeService.confirmarCheckinRotina`
   marca `CONFIRMADO_SEGURA` imediatamente ao digitar o PIN certo.
3. **Esta Cloud Function** — se encontrar um documento `PENDENTE` cujo
   `dataHoraDisparo` já passou, marca `ALERTA_DISPARADO` e dispara o
   alerta (FCM para `tokensGuardioes` + SMS/Twilio para
   `telefonesEmergencia`).

## Arquivo principal

`src/scheduledAlarmMonitor.ts` — esboço da função agendada
(`onSchedule`), com os mesmos princípios já usados em `functions/index.js`:
nunca deixa a falha de UM alarme/contato impedir o processamento dos
demais, e o gateway de SMS (Twilio) fica como TODO explícito, exatamente
como no gateway de `functions/index.js`.

## Pendências conhecidas (mesmas de `functions/`)

- **Gateway de SMS (Twilio)**: ainda não envia SMS de verdade — apenas
  loga o que seria enviado. Requer plano Blaze + credenciais Twilio (ver
  comentário no código).
- **Tokens de guardiões**: o app ainda não tem UI para o usuário vincular
  um "guardião" (segundo usuário do app) e obter seu token FCM — o campo
  `tokensGuardioes` existe no modelo e é lido aqui, mas hoje chega sempre
  vazio.

## Como ativar (sair do estado de esboço)

Duas opções, escolha uma:

1. **Mesclar em `functions/`** (mais simples, um único codebase): mover
   `src/scheduledAlarmMonitor.ts` para dentro de `functions/` (convertendo
   para JS ou configurando TypeScript nesse projeto) e adicionar
   `exports.monitorarAlarmesAgendados = ...` ao `functions/index.js`.
2. **Registrar como codebase adicional** no `firebase.json` da raiz:
   ```jsonc
   "functions": [
     { "source": "functions", "codebase": "default", "ignore": [...] },
     { "source": "cloud_functions", "codebase": "alarmes_agendados", "ignore": ["node_modules", ".git"] }
   ]
   ```
   e então `npm install` dentro de `cloud_functions/` antes do deploy.

Em ambos os casos, revise antes do deploy:
- Índice composto do Firestore para a query `status == "PENDENTE" AND
  dataHoraDisparo <= now` (adicionar a `firestore.indexes.json` da raiz).
- Regra do Firestore para `alarmes_agendados/{idAlarme}` (já adicionada em
  `firestore.rules` da raiz, mesma postura temporária/aberta do resto do
  arquivo).
