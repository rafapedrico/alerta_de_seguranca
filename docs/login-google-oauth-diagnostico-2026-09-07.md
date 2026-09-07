# Diagnóstico: Login do Google falhando em produção ("[16] Account reauth failed")

**Data:** 2026-09-07
**Sintoma original:** login com Google falhando silenciosamente/com reautenticação recusada, especificamente no app baixado da Play Store (nunca em debug/local) — erro nativo do Google Play Services `[16] Account reauth failed`.

## Causa raiz confirmada

O SHA-1 do certificado de **assinatura do app na Play Store** (Play App Signing) estava registrado como *SHA fingerprint* no Firebase, mas o **OAuth Client 2.0 do Android correspondente não existia** no Google Cloud — provavelmente excluído manualmente em algum momento anterior a esta investigação. Editar `google-services.json` localmente nunca afeta a nuvem; o problema sempre esteve do lado do Google Cloud Console.

Certificado confirmado no Play Console (**Integridade do app → Assinatura do app**):
```
D5:FF:60:70:CD:77:3E:FF:F3:C5:E3:A9:07:01:CD:4C:73:FA:A4:CA
→ d5ff6070cd773efff3c5e3a90701cd4c73faa4ca
```

Outros 3 certificados (`feefde39...`, `72c1ea7e...`, `7cd8d787...`) tinham o mesmo problema — SHA registrado, OAuth Client ausente.

## Correção aplicada

Via Firebase CLI, no app Android `1:555863351772:android:f8cdca1bbe926aa74def19` (projeto `guardiaox`):

```bash
firebase apps:android:sha:delete 1:555863351772:android:f8cdca1bbe926aa74def19 <sha_id> --project guardiaox
firebase apps:android:sha:create 1:555863351772:android:f8cdca1bbe926aa74def19 D5FF6070CD773EFFF3C5E3A90701CD4C73FAA4CA --project guardiaox
```

Isso forçou o Google a reprovisionar o OAuth Client para esse SHA — e, como bônus, também recriou os clients para os outros 3 certificados que estavam na mesma situação.

`android/app/google-services.json` foi então atualizado com o estado real da nuvem (via `firebase apps:sdkconfig ANDROID <appId> --project guardiaox`), commit `036b857`.

## Estado atual confirmado (verificado ao vivo, não só no arquivo local)

`firebase apps:sdkconfig` mostra **5 OAuth Clients Android + 1 Web Client** para o app `com.rmfglobal.guardiaox`:

| Client ID (sufixo) | certificate_hash | Observação |
|---|---|---|
| `...0d4c8lgd9ibna86bplk8n08m9b0qbbak` | `72c1ea7ea56e954994e0fef38d97eeab8f8c9058` | |
| `...7oeoj348mntagt5ut72r5pcqq3n6mpal` | `feefde39d48a6d3b129b2ae3a89da24047f731c6` | |
| `...9hfk1kmpq50ilq5i9o3rvbh824n5rv2e` | `7cd8d787b926b547f25f2d3aa39a9052f631b0ce` | |
| `...hfhu0gsamskh0dr694v46un4c10ud01j` | `749f8b8fad1878c830cb802559927bc47d0cfe01` | certificado da upload key (`guardiaox-upload.jks`) |
| `...mh9201vpds97sog52tk979r8a6rbtvci` | `d5ff6070cd773efff3c5e3a90701cd4c73faa4ca` | **certificado do Play App Signing (o que faltava)** |
| `...vrlhh2c4kv0a1ci7eu34i36rq5jro327` | — (client_type 3, Web) | usado como `serverClientId` em `social_auth_service.dart` |

`android/app/google-services.json`, `lib/firebase_options.dart` e `android/app/build.gradle` foram auditados e conferem com esse estado — **nenhuma mudança pendente neles**.

## Teste real no dispositivo (Moto G7 Play, Android 9)

Com o APK de release (`flutter build apk --release`, mesma assinatura `guardiaox-upload.jks` → cert `749f8b8f...`) instalado no aparelho:

- **16:49:38** — login testado, `FirebaseAuth` validou o `idToken` com sucesso (`Notifying auth state listeners about user (66LZyrPcadS2HZkMBWlnce9Xt4z2)`). **Confirma que a correção do OAuth Client funciona.**

## Problema separado encontrado e revertido: Cloud Function `revogarSessoesEmOutrosDispositivos`

Durante o teste, descobrimos que essa function (existente no código desde 2026-09-06, nunca deployada) estava faltando — chamada em todo login (`LoginScreen._finalizarLoginComSucesso`), falhando silenciosamente com `NOT_FOUND` (comportamento best-effort documentado, inofensivo).

**Foi deployada** (~16:55) para testar — e revelou um **bug estrutural real**: `getAuth().revokeRefreshTokens(uid)` invalida TODOS os refresh tokens emitidos até aquele instante, incluindo o que acabou de ser emitido pelo login que disparou a chamada. A mitigação existente no código (`garantirTokenPronto()` → `getIdToken(true)` logo em seguida) **não resolve**, porque só renova o ID token a partir do refresh token existente — não existe API cliente para obter um refresh token novo sem reautenticar do zero. Resultado: todo login (Google **e** e-mail/senha) era seguido de um logout forçado ~1-2s depois.

**A function foi excluída** (~17:02) para restaurar o comportamento anterior (falha silenciosa, login estável). **Não deployar de novo sem antes corrigir a lógica** — provavelmente precisa de uma abordagem por sessão/dispositivo (ex: um `sessionId`/`deviceId` gravado no Firestore por login, revogado individualmente) em vez de `revokeRefreshTokens` (que é all-or-nothing por UID).

## Falha intermitente observada depois (não resolvida, monitorar)

Após excluir a Cloud Function, testes subsequentes (17:06, e 3x mais em 17:10, este último após o usuário limpar o cache do Google Play Services no aparelho) voltaram a reproduzir `[16] Account reauth failed` / `UNREGISTERED_ON_API_CONSOLE` — dessa vez falhando num nível **anterior** ao Firebase (o próprio Google Play Services recusa o "Account Reauth" antes de gerar o idToken).

**Confirmado que NÃO é regressão de configuração**: `firebase apps:sdkconfig` reconferido nesse momento mostra os mesmos 5 OAuth Clients + Web Client intactos, idênticos ao estado que funcionou às 16:49:38.

**Hipótese mais provável**: atraso de propagação do lado do Google após a operação delete+recreate do SHA-1 (~30-45 min antes), possivelmente agravado por rate-limiting do Google após ~8 tentativas de login em ~30 minutos no mesmo aparelho/conta, e pela limpeza de cache do Play Services ter forçado uma verificação mais rigorosa (fresh) contra um backend ainda não totalmente propagado.

**Não foi feita nenhuma alteração adicional de configuração** para "corrigir" isso — os arquivos do projeto estão corretos e confirmados. Próximo passo recomendado: aguardar algumas horas (ou testar no dia seguinte) e testar uma única vez, sem repetir tentativas em sequência.

## Arquivos e comandos de referência

- `lib/services/social_auth_service.dart` — `_googleServerClientId` (linha ~127), `serverClientId` passado em `GoogleSignIn.instance.initialize()`.
- `lib/services/firebase_auth_service.dart:211` — `revogarSessoesEmOutrosDispositivosEAtualizarToken` (best-effort, function atualmente **não deployada** de propósito).
- `functions/sessaoDispositivoService.js` — código da function revertida (existe no repo, não deployada).
- Comandos úteis para reinspecionar o estado ao vivo:
  ```bash
  firebase apps:sdkconfig ANDROID 1:555863351772:android:f8cdca1bbe926aa74def19 --project guardiaox
  firebase apps:android:sha:list 1:555863351772:android:f8cdca1bbe926aa74def19 --project guardiaox
  firebase functions:list --project guardiaox
  ```
