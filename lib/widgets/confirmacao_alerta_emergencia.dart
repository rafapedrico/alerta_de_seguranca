import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

/// Card de confirmação, em tela cheia, exibido sempre que um alerta de
/// emergência REAL do Cronômetro Regressivo (aba Segurança) acabou de ser
/// disparado — SMS nativo + push/Firestore para o app receptor + registro
/// no histórico local já concluídos (ou em andamento) no momento em que
/// este widget aparece.
///
/// ÚNICO COMPONENTE VISUAL reaproveitado nos DOIS cenários que levam a um
/// disparo de emergência do cronômetro (reespecificação do usuário,
/// 2026-08-14):
/// - 3ª tentativa de PIN incorreta (seja durante uma tentativa MANUAL de
///   desarme, com o cronômetro principal ainda contando — ver
///   `seguranca_tab.dart` —, seja dentro da janela final de 60 segundos de
///   tolerância — ver `cronometro_disparado_screen.dart`).
/// - Timeout: os 60 segundos de tolerância se esgotam sem confirmação
///   (`cronometro_disparado_screen.dart`).
///
/// Ícone e texto SEMPRE em VERMELHO (cor de alerta/emergência do tema do
/// app) — NUNCA verde, que sugeriria sucesso/segurança, o oposto do que
/// de fato aconteceu (um alerta real foi enviado aos contatos de
/// emergência).
class ConfirmacaoAlertaEmergencia extends StatelessWidget {
  const ConfirmacaoAlertaEmergencia({super.key, required this.aoFechar, this.mensagem});

  /// Texto da confirmação (o que aconteceu — ex.: as 3 tentativas com
  /// senha incorreta). `null` = texto padrão de alerta enviado.
  final String? mensagem;

  /// Chamado ao tocar no botão "Fechar" ou ao arrastar o card para cima
  /// com velocidade suficiente. Cada chamador decide o que "fechar"
  /// significa no seu próprio contexto (devolver o app ao Android via
  /// `SystemNavigator.pop`, ou simplesmente um `Navigator.pop` de volta à
  /// tela anterior).
  final VoidCallback aoFechar;

  @override
  Widget build(BuildContext context) {
    // Item 4 (reespecificação do usuário, 2026-08-14): removido o
    // ícone gigante translúcido que ficava centralizado na tela, atrás do
    // texto de confirmação — funcionava como uma "marca d'água" de fundo,
    // atrapalhando a leitura da mensagem. Fica só a tipografia vermelha,
    // limpa, sobre o fundo escuro.
    final Widget tela = Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mensagem ??
                      AppLocalizations.of(context)!.alarmeRotinaAlertaEnviadoDescricao,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                const Icon(
                  Icons.keyboard_arrow_up_rounded,
                  color: Colors.white38,
                  size: 32,
                ),
                Text(
                  AppLocalizations.of(context)!.fecharConfirmacaoDica,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: aoFechar,
                    child: Text(
                      AppLocalizations.of(context)!.fecharConfirmacaoBotao,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Mesmo gesto de "arrastar para cima para fechar" já usado nas duas
    // telas que reaproveitam este widget.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (details) {
        if (details.velocity.pixelsPerSecond.dy < -250) {
          aoFechar();
        }
      },
      child: tela,
    );
  }
}
