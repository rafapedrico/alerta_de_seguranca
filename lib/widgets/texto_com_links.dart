import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Varre [texto] em busca de URLs (`http`/`https` — cobre tanto o link do
/// Google Maps das coordenadas quanto o link do Firebase Storage de uma
/// foto, ambos embutidos como texto simples nas mensagens de SOS/alertas
/// já persistidas) e devolve os spans prontos para um `Text.rich`, com
/// cada URL encontrada em AZUL, sublinhada e clicável (aciona
/// [aoTocarLink]) — o restante do texto permanece com [estiloBase], sem
/// estilo de link.
///
/// ÚNICA função de linkificação do app (reespecificação do usuário,
/// 2026-08-14: "padronização do link de localização na cor azul") —
/// reaproveitada por `historico_tab.dart` (cards do Histórico e da lista
/// de Alertas Enviados) e `alerta_recebido_screen.dart` (corpo da
/// mensagem de um alerta recebido de terceiro), garantindo o MESMO azul
/// em qualquer lugar do app onde um link de localização/foto apareça
/// dentro de um texto — nunca a cor padrão do corpo do texto.
List<InlineSpan> construirSpansComLinks(
  String texto,
  TextStyle estiloBase,
  void Function(String url) aoTocarLink,
) {
  final regexUrl = RegExp(r'https?://[^\s\)]+');
  final spans = <InlineSpan>[];
  int ultimoIndice = 0;

  for (final match in regexUrl.allMatches(texto)) {
    if (match.start > ultimoIndice) {
      spans.add(TextSpan(text: texto.substring(ultimoIndice, match.start), style: estiloBase));
    }
    final url = match.group(0)!;
    spans.add(
      TextSpan(
        text: url,
        style: estiloBase.copyWith(
          color: Colors.blue,
          decoration: TextDecoration.underline,
          decorationColor: Colors.blue,
        ),
        recognizer: TapGestureRecognizer()..onTap = () => aoTocarLink(url),
      ),
    );
    ultimoIndice = match.end;
  }

  if (ultimoIndice < texto.length) {
    spans.add(TextSpan(text: texto.substring(ultimoIndice), style: estiloBase));
  }

  return spans;
}
