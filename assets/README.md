# Assets de Som — Alerta Sonoro Customizável

Esta pasta contém os 10 arquivos de som usados pelo recurso de **Alerta
Sonoro Customizável**, disparado quando o cronômetro de check-in (aba
Segurança) chega a zero.

## Arquivos esperados

- `som_1.mp3`
- `som_2.mp3`
- `som_3.mp3`
- `som_4.mp3`
- `som_5.mp3`
- `som_6.mp3`
- `som_7.mp3`
- `som_8.mp3`
- `som_9.mp3`
- `som_10.mp3`

## IMPORTANTE

Os arquivos presentes atualmente nesta pasta são **placeholders vazios**
(criados automaticamente pela IA, que não tem capacidade de gerar áudio
real). Antes de gerar um build de produção, **substitua cada um destes
10 arquivos por um som real** (recomenda-se sons de alarme/sirene
curtos, entre 1 e 5 segundos, para permitir um loop suave).

A lógica de reprodução, loop e duração configurável já está 100%
implementada em `lib/services/alarme_sonoro_service.dart` e não precisa
de nenhuma alteração de código ao trocar os arquivos — basta manter os
mesmos nomes (`som_1.mp3` até `som_10.mp3`).
