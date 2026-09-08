# Diagnóstico: Login do Google falhando em produção ("[16] Account reauth failed")

**Data:** 2026-09-07
**Sintoma original:** login com Google falhando silenciosamente/com reautenticação recusada, especificamente no app baixado da Play Store (nunca em debug/local) — erro nativo do Google Play Services `[16] Account reauth failed`.

---

## ✅ RESOLUÇÃO DEFINITIVA (2026-09-07, fim do dia)

**Toda a análise abaixo partiu de um SHA-1 ERRADO.** O certificado do Play App
Signing **não é** `d5ff6070...` (esse valor foi copiado do Play Console, mas não
corresponde à chave que assina o APK entregue). O certificado real, extraído do
`base.apk` instalado pela Play Store em dois aparelhos (Moto G7 Play e Razr 40
Ultra) e verificado com `apksigner`:

```
SHA-1   F7:9B:67:51:7E:A9:57:93:53:26:B6:63:0E:77:60:FA:60:76:B6:61
        → f79b67517ea957935326b6630e7760fa6076b661
SHA-256 26:50:A8:6C:69:51:21:BA:76:C9:8D:06:63:0E:FD:41:E8:43:DE:73:B6:32:17:23:AB:F1:AE:2D:C0:CC:49:52
        → 2650a86c695121ba76c98d06630efd41e843de73b6321723abf1ae2dc0cc4952
DN:     CN=Android, O=Google Inc.  (chave gerada pelo Play App Signing)
```

Nunca existiu OAuth Client para esse certificado. O log do Play Services (g7,
versionCode 18, instalado da loja) mostrou a causa sem ambiguidade:

```
W/Auth [GetTokenResponseHandler] Server returned error: This android application
  is not registered to use OAuth2.0, please confirm the package name and SHA-1
  certificate fingerprint match what you registered...
[AccountReauth_flowRunner] Flow failed: [8] ... [status=UNREGISTERED_ON_API_CONSOLE]
[GoogleSignIn_flowRunner] Flow failed: [16] Account reauth failed
```

**Correção (100% server-side):**
```bash
firebase apps:android:sha:create 1:555863351772:android:f8cdca1bbe926aa74def19 \
  F79B67517EA957935326B6630E7760FA6076B661 --project guardiaox
firebase apps:android:sha:create 1:555863351772:android:f8cdca1bbe926aa74def19 \
  2650A86C695121BA76C98D06630EFD41E843DE73B6321723ABF1AE2DC0CC4952 --project guardiaox
```
O Google auto-provisionou o OAuth Client `555863351772-0d6vepdg74rm4bqoqt2h30eobnjdcu2n`.
O client de `d5ff6070...` (`...3ereb8cquc...`) foi mantido — inofensivo, cobre um
eventual upgrade de chave de assinatura do Play.

**Validado:** login com Google no Razr 40 Ultra (versionCode **17**, build antigo
da Play Store, **sem rebuild nem re-upload**) passou a funcionar —
`AccountReauth Flow completed`, zero `UNREGISTERED_ON_API_CONSOLE`, app entrou em
"Complete seu perfil". A correção não depende de build: os pacotes 17 e 18 já
publicados funcionam sozinhos após a propagação.

**Como extrair o SHA real de novo, se precisar:**
```bash
adb -s <serial> shell pm path com.rmfglobal.guardiaox        # acha o base.apk
adb -s <serial> pull <caminho>/base.apk /tmp/gx.apk
<sdk>/build-tools/35.0.0/apksigner verify --print-certs --max-sdk-version 34 /tmp/gx.apk
```
(build-tools 37.0.0 falha com "ML-DSA KeyFactory not available" na assinatura v3.2
PQC nova do Play — usar 35.0.0 ou anterior.)

**Notas paralelas:**
- A upload key (`guardiaox-upload.jks`, alias `guardiaox`) é `72c1ea7e...` — a doc
  original dizia `749f8b8f...`, também errado.
- Firebase App Check API está **desabilitada** no projeto 555863351772 (o app cai
  em placeholder token). Não afeta o login; não ligar enforcement sem habilitar a API.

⚠️ **Tudo abaixo desta linha é a investigação anterior, baseada no cert errado — mantido como histórico.**

---

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
