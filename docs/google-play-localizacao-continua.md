# Google Play — localização contínua (Monitoramento)

Textos para o **Play Console** da versão que traz o compartilhamento contínuo
de localização (ramo `feat/rastreamento-continuo-android`). Nada aqui foi
enviado. A Google revisa em inglês: cole a versão em inglês e use a versão em
português como referência.

O roteiro do vídeo exigido está em
[`roteiro-video-localizacao-continua-android.md`](roteiro-video-localizacao-continua-android.md).

---

## 1. Declaração de localização em segundo plano

**Onde:** Play Console → Política e programas → Conteúdo do app →
*Permissões de localização* (`ACCESS_BACKGROUND_LOCATION`).

### Recurso que usa a localização em segundo plano

**English (paste):**

> Continuous location sharing with trusted contacts (Monitoring tab). A user
> can let family members they explicitly approved see their current location
> (for example, a teenager coming home at night or an elderly parent). Sharing
> is opt-in: it is only offered after the user approves a contact, and turned
> on through an in-app disclosure screen with an "I agree" checkbox. To keep
> the position current while Guardian-X is closed, the app runs a location
> foreground service with a persistent notification ("Guardian-X is sharing
> your location with N contact(s)"). The user can pause it at any time in the
> Monitoring tab.

**Português (referência):**

> Compartilhamento contínuo da localização com contatos de confiança (aba
> Monitoramento). A pessoa permite que familiares que ela aprovou
> explicitamente vejam onde ela está agora (por exemplo, um adolescente
> voltando para casa à noite ou um pai idoso). É opcional: só é oferecido
> depois que a pessoa aprova um contato e é ligado numa tela de divulgação
> dentro do app, com a caixa "Concordo". Para a posição continuar atualizada
> com o Guardião-X fechado, o app roda um serviço em primeiro plano de
> localização com notificação fixa ("Guardião-X está compartilhando sua
> localização com N contato(s)"). A pessoa pode pausar a qualquer momento na
> aba Monitoramento.

### Por que o recurso precisa da localização em segundo plano

**English (paste):**

> The core purpose of the feature is that approved contacts see where the
> user is right now, at any moment, including when the user is not using the
> app (walking home, commuting, phone in the pocket). With "While using the
> app" only, the position would freeze the moment the app is closed, which
> defeats a personal-safety feature. Background location is never used for
> advertising, analytics or any purpose other than showing the position to
> the contacts the user approved, and only the latest position is stored.

**Português (referência):**

> O objetivo do recurso é que os contatos aprovados vejam onde a pessoa está
> agora, a qualquer momento, inclusive quando ela não está usando o app
> (voltando a pé para casa, no trajeto, com o celular no bolso). Só com
> "Durante o uso do app", a posição congelaria no momento em que o app fosse
> fechado, o que anula um recurso de segurança pessoal. A localização em
> segundo plano nunca é usada para publicidade, análise ou outra finalidade
> além de mostrar a posição aos contatos aprovados, e só a última posição é
> guardada.

### Divulgação em destaque (no app)

A tela *Compartilhamento contínuo → 2/2* (`ConsentimentoRastreamentoScreen`)
mostra, **antes** do pedido do sistema, o texto `rcEtapa2Texto`:

> O Guardião-X coleta dados de localização para mostrar sua posição atual aos
> contatos que você aprovou na aba Monitoramento, mesmo quando o app está
> fechado ou não está em uso. […]

Ele segue o formato que a Google pede ("*[app] collects location data to
enable [feature] even when the app is closed or not in use*"). O botão
**Permitir o tempo todo** só fica habilitado depois de a pessoa marcar
"Concordo em compartilhar minha localização continuamente com: [nomes]".

---

## 2. Declaração de serviço em primeiro plano (tipo `location`)

**Onde:** Play Console → Conteúdo do app → *Permissões de serviço em primeiro
plano* (`FOREGROUND_SERVICE_LOCATION`). Tipo: **Location**.

### Descrição da tarefa

**English (paste):**

> RastreamentoContinuoService keeps the user's location shared with the
> family contacts they approved in the Monitoring tab while the app is closed.
> It is started only after the user turns on "Continuous sharing" and grants
> "Allow all the time"; it uses the Fused Location Provider with balanced
> power accuracy (about every minute while moving, about every 15 minutes
> when stationary, less often below 15% battery) and shows a persistent
> notification while running. It stops when the user pauses sharing, signs
> out, deletes the account, removes the last approved contact, or during the
> blocked days of the free plan.

**Português (referência):**

> O RastreamentoContinuoService mantém a localização do usuário compartilhada
> com os familiares que ele aprovou na aba Monitoramento enquanto o app está
> fechado. Só é iniciado depois que o usuário liga o "Compartilhamento
> contínuo" e concede "Permitir o tempo todo"; usa o Fused Location Provider
> com precisão equilibrada (cerca de 1 vez por minuto em movimento, cerca de a
> cada 15 min parado, menos com bateria abaixo de 15%) e mostra uma
> notificação fixa enquanto roda. Para quando o usuário pausa, sai da conta,
> exclui a conta, remove o último contato aprovado, ou nos dias bloqueados do
> plano gratuito.

### Impacto se a tarefa for adiada ou interrompida pelo sistema

**English (paste):**

> The approved contacts would see an outdated position and could not find the
> user in an emergency. The task must start right away and keep running
> while sharing is on: it cannot be deferred to WorkManager because location
> must be read periodically with the app closed, and the user is always aware
> of it through the persistent notification.

**Português (referência):**

> Os contatos aprovados veriam uma posição desatualizada e não conseguiriam
> encontrar a pessoa numa emergência. A tarefa precisa começar na hora e
> continuar enquanto o compartilhamento estiver ligado: não pode ser adiada
> para o WorkManager porque a localização precisa ser lida periodicamente com
> o app fechado, e a pessoa sempre sabe que ela está rodando pela notificação
> fixa.

### Link do vídeo

O mesmo vídeo do item 1 (ver o roteiro). Deve mostrar a notificação fixa e o
recurso funcionando com o app fechado.

---

## 3. Política de privacidade — pontos sobre localização contínua

A página publicada (`website/privacidade.html`) hoje cita a localização em
segundo plano "estritamente para o envio e o salvamento de alertas
preventivos e de pânico" (seção de dados coletados) e a base legal de
consentimento. **Não foi alterada nesta entrega**, porque nenhum deploy foi
pedido. Antes de publicar a versão, ela precisa dizer, além disso:

1. **Compartilhamento contínuo com contatos aprovados.** Com o recurso
   ligado, a localização é coletada também em segundo plano (inclusive com o
   app fechado) para mostrar a posição atual aos contatos que a pessoa aprovou
   na aba Monitoramento.
2. **Consentimento e controle.** É opcional, ligado só depois de uma tela
   explicativa com "Concordo"; pode ser pausado a qualquer momento na aba
   Monitoramento; remover ou bloquear um contato revoga o acesso dele na hora;
   sair da conta ou excluí-la desliga o recurso.
3. **Quem vê.** Só os contatos com permissão "aprovado". Eles também recebem
   avisos quando a posição para de ser atualizada ou quando a localização em
   segundo plano é desativada.
4. **O que é guardado.** Só a **última** posição (latitude, longitude,
   precisão e horário) em `usuarios/{uid}/monitoramento/atual`, além do estado
   do recurso (ligado/desligado e o motivo, permissão concedida, economia de
   bateria) em `.../monitoramento/estado`. Não há histórico de trajetos.
5. **Finalidade exclusiva.** A localização não é usada para publicidade,
   análise, perfilamento nem vendida ou compartilhada com terceiros além dos
   contatos aprovados e dos provedores de infraestrutura (Google Firebase).
6. **Retenção.** A última posição é substituída a cada atualização e apagada
   com a exclusão da conta (ver a seção de exclusão de dados).

---

## Checklist antes de enviar a versão

- [ ] Vídeo gravado (roteiro) e enviado como link não listado do YouTube.
- [ ] Declarações dos itens 1 e 2 preenchidas no Play Console.
- [ ] Política de privacidade atualizada com os pontos do item 3 e publicada.
- [ ] Ficha da loja (descrição) menciona o compartilhamento contínuo opcional.
- [ ] Duas contas de teste pareadas e **Premium** nas instruções de acesso do
      app (Play Console → Acesso ao app), para o plano gratuito não pausar o
      recurso durante a revisão.
- [ ] Teste no aparelho conforme o resumo do PR (reinício do aparelho,
      bateria baixa, saída da conta, sessão encerrada em outro aparelho).
