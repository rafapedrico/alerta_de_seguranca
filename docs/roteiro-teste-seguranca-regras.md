# Roteiro de teste — ramo `feat/seguranca-regras` (Android)

Aparelho com chip, PIN de 4 dígitos cadastrado em Configurações, pelo menos
um contato de emergência que tenha o Guardião-X (para conferir o push) e
localização "Permitir o tempo todo". Antes de cada bloco, confira em
Configurações > Status de Permissões: Alarmes e lembretes, Tela cheia,
Notificações e Câmera.

## 1. SOS

### 1.1 SOS com internet
1. Aba Segurança > toque em SOS **uma vez**. Não deve aparecer nenhum
   diálogo de confirmação.
2. Tela preta, letras vermelhas: "Alerta acionado. Enviando sua localização…".
3. Em até ~3 s: "Localização enviada com sucesso" (por 2 s), depois
   "Abrindo a câmera" e a câmera.
4. Tire a foto. Tela vermelha com a frase completa (foto e localização).
5. Contato: recebe **um** SMS com o link do mapa (sem "(botão físico)" e sem
   promessa de atualização) e o push; depois o SMS com o link
   `meuguardiaox.com.br/f/…` da foto.
6. Histórico > Alertas enviados (PIN): **uma** entrada "SOS pelo botão do
   app", status Enviado, miniatura da foto. Toque nela: data e hora,
   status, foto, "Ver no mapa" com coordenadas e precisão.
7. Toque duplo rápido no SOS: só um alerta sai.
8. Repita com o botão físico (Volume+): mesma sequência; SMS com
   "(botão físico)".

### 1.2 SOS em modo avião
1. Ative o modo avião e toque em SOS.
2. Em 8 s: "Sem conexão. Seu alerta será enviado automaticamente assim que
   houver sinal" (2 s) e a câmera abre.
3. Tire a foto. Tela vermelha: "ATENÇÃO, SEU ALERTA SERÁ ENVIADO AOS
   FAMILIARES ASSIM QUE HOUVER CONEXÃO."
4. Histórico: entrada com status Pendente e a miniatura da foto local.
5. Desative o modo avião e abra o app: a foto sobe pela fila (até 15 min),
   o contato recebe o SMS com o link verdadeiro (nenhum SMS de foto sem
   link) e a MESMA entrada passa a ter o link da foto.

### 1.3 SOS sem permissão de câmera
1. Retire a permissão de câmera do Guardião-X e toque em SOS.
2. Depois do aviso de localização: "Câmera indisponível — alerta já enviado
   aos seus contatos" e a tela vermelha "…COM SUA LOCALIZAÇÃO…" (sem foto).

### 1.4 SOS sem contatos (opcional)
Sem contatos cadastrados: o aviso diz que nenhuma mensagem foi enviada; a
tela vermelha não afirma envio.

## 2. Cronômetro

### 2.1 Tela bloqueada
1. Escreva um texto no campo de contexto, escolha 1 min e inicie. Aparece a
   notificação "Cronômetro de segurança ativo".
2. Bloqueie a tela. No fim: a tela acende com "Desligue o alerta de
   emergência — toque para digitar seu PIN", o som escolhido em
   Configurações toca **uma vez em loop** (sem um segundo som).
3. Digite o PIN correto: o som para e chega "Senha correta. O alerta de
   emergência não foi enviado."
4. Repita e erre o PIN 3 vezes: o teclado fecha na hora, a tela confirma
   "Houve 3 tentativas…" e chega a notificação; o contato recebe SMS e push
   com o motivo, o texto do contexto e o mapa.
5. Repita sem digitar nada: em 60 s o alerta "tempo esgotado" sai.
6. Durante o cronômetro (e os 60 s), confira no Firestore que
   `usuarios/{uid}`, `monitoramento/atual` e
   `alarmes_agendados/{uid}_checkin_seguranca.ultimaLocalizacao` mudam a
   cada ~1 min.

### 2.2 App fechado
1. Inicie o cronômetro (2 min) e remova o app dos Recentes.
2. A localização continua a cada 1 min (Firestore) e, no fim, a tela do
   alarme abre sozinha por cima de tudo.

### 2.3 Modo silencioso / vibrar
1. Silencioso: no fim do cronômetro nada toca (a tela abre).
2. Vibrar: só vibra. Normal: toca no volume atual do toque (sem ir ao
   máximo).

### 2.4 PIN correto seguido de fechar o app pelos Recentes (defeito 1.1)
1. Deixe o cronômetro chegar ao fim, digite o PIN correto.
2. Imediatamente remova o app dos Recentes.
3. Esperado: **nenhum** alerta (nada no Histórico, nenhum SMS/push).
4. Contraprova: no fim, SEM digitar o PIN, remova o app dos Recentes — o
   alerta de fechamento forçado sai.

### 2.5 Proteções
- Sem PIN cadastrado: tocar em iniciar pede o cadastro.
- Sem "Alarmes e lembretes": o cronômetro não inicia; aparece o aviso com o
  botão de permissão.
- Tentar iniciar outro cronômetro durante os 60 s de tolerância: recusado.
- Reinicie o aparelho com um cronômetro de 10 min ativo: no fim ele toca.

## 3. Despertador
1. Sem contato de emergência: o "+" fica desabilitado e aparece o aviso
   com o atalho para Configurações.
2. Crie um para daqui a 3 min, tolerância 5 min, com etiqueta vazia.
3. No horário: tela cheia sobre o bloqueio, notificação com
   "Desativar despertador" (abre direto no teclado), som em loop mesmo no
   silencioso.
4. PIN correto: som para, notificação "Despertador desativado (pausado)".
5. 3 PINs errados: teclado fecha, alerta sai e chega a notificação "Um
   alerta de emergência foi enviado aos seus contatos cadastrados."
6. Sem ação: o alerta sai exatamente no fim da tolerância (sem "última
   chance").
7. Pausar (botão "Pausar", com PIN): "Retorna" mostra o próximo dia
   selecionado; editar o despertador não o despausa.
8. Dois despertadores no mesmo minuto: aparecem um de cada vez; resolver o
   primeiro não silencia o segundo.
9. Etiqueta vazia: no SMS/push não aparece `KEY_ALARME_ROTINA`.
10. Desligue o aparelho antes do horário: o servidor envia o alerta no fim
    da tolerância.

## 4. Histórico após reinstalar o app
1. Gere 2 alertas (SOS e cronômetro) e desinstale o app.
2. Reinstale e entre com a mesma conta.
3. Histórico > Alertas enviados (PIN): as entradas voltam do Firestore
   (o banco local não vem do backup do Android). Fotos voltam pelo link.

## 5. PIN errado 3 vezes no Histórico
1. Histórico > Alertas enviados > erre o PIN 3 vezes: a área fica bloqueada
   por 5 min (mensagem com o horário de liberação).
2. Depois do tempo, erre mais 3 vezes: bloqueio de 10 min (dobra).
3. Com o PIN correto: liberado. Troque de aba e volte: pede o PIN de novo.
   App em segundo plano por mais de 2 min: pede de novo.
4. Apagar uma entrada (arrastar) ou "Limpar": pede o PIN de novo.
