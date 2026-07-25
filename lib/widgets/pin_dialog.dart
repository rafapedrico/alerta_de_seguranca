import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

/// Diálogo leve (AlertDialog) para confirmação de PIN, exibido POR CIMA
/// da tela atual (sem substituir toda a árvore/rota como a antiga
/// TelaBloqueioPin fazia). Isso elimina os conflitos de ciclo de vida
/// relatados: a navegação (bottom navigation, HomeScreen, FamiliaTab
/// etc.) continua livre e funcionando normalmente por trás do diálogo.
///
/// Uso típico:
/// ```dart
/// await exibirDialogoPin(
///   context: context,
///   pinEsperado: _pinRealConfirmado,
///   aoConfirmarPinCorreto: _aoConfirmarPinCorreto,
/// );
/// ```
///
/// REGRAS DE NEGÓCIO DE SEGURANÇA/DISFARCE (UX) mantidas:
/// - PIN incorreto: exibe apenas "PIN incorreto. Tente novamente.".
/// - PIN correto: aciona [aoConfirmarPinCorreto] e fecha o diálogo
///   silenciosamente.
/// - O diálogo é [barrierDismissible]: false, ou seja, não pode ser
///   fechado tocando fora dele — apenas digitando o PIN correto — mas,
///   diferente da tela cheia antiga, ele NUNCA bloqueia a UI/navegação
///   por trás em caso de erro de ciclo de vida (o app permanece
///   plenamente responsivo).
///
/// PIN DE COAÇÃO (gatilho discreto de emergência): [aoErrarPinDuasVezes]
/// é um callback OPCIONAL, disparado internamente sempre que o usuário
/// digitar o PIN incorreto 2 VEZES CONSECUTIVAS (o contador é resetado
/// automaticamente após acionar o callback, e também sempre que o PIN
/// correto for digitado). A interface NUNCA reflete esse gatilho — a
/// mensagem de erro exibida é sempre a mesma ("PIN incorreto. Tente
/// novamente."), independentemente de qual erro consecutivo for,
/// mantendo o disfarce de segurança 100% intacto diante de um possível
/// agressor observando a tela. Toda a lógica real de disparo (chamar o
/// EmergencyAlertService, obter localização, etc.) fica a cargo de quem
/// fornece o callback (ver [SegurancaTab._dispararSosDeCoacao]) — este
/// widget é propositalmente "burro" e não conhece nada sobre
/// GPS/serviços de emergência.
Future<void> exibirDialogoPin({
  required BuildContext context,
  required String? pinEsperado,
  required Future<void> Function() aoConfirmarPinCorreto,
  int? segundosTolerancia,
  Future<void> Function()? aoErrarPinDuasVezes,
  bool mostrarBotaoCancelar = false,
  VoidCallback? aoCancelar,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return PinDialogContent(
        pinEsperado: pinEsperado,
        aoConfirmarPinCorreto: aoConfirmarPinCorreto,
        segundosTolerancia: segundosTolerancia,
        aoErrarPinDuasVezes: aoErrarPinDuasVezes,
        mostrarBotaoCancelar: mostrarBotaoCancelar,
        aoCancelar: aoCancelar,
      );
    },
  );
}

class PinDialogContent extends StatefulWidget {
  const PinDialogContent({
    super.key,
    required this.pinEsperado,
    required this.aoConfirmarPinCorreto,
    this.segundosTolerancia,
    this.aoErrarPinDuasVezes,
    this.mostrarBotaoCancelar = false,
    this.aoCancelar,
  });

  final String? pinEsperado;
  final Future<void> Function() aoConfirmarPinCorreto;
  final int? segundosTolerancia;

  /// Callback silencioso, opcional, acionado ao 2º erro consecutivo de
  /// PIN. Ver documentação completa em [exibirDialogoPin].
  final Future<void> Function()? aoErrarPinDuasVezes;

  /// Quando `true`, exibe um botão de texto "Cancelar" abaixo do teclado
  /// numérico, permitindo fechar o diálogo sem digitar o PIN. Usado em
  /// fluxos onde a confirmação por PIN é opcional (ex: pausar um alarme
  /// de rotina), diferente do bloqueio de segurança padrão da
  /// SegurancaTab, que nunca deve poder ser cancelado sem o PIN correto.
  final bool mostrarBotaoCancelar;

  /// Callback disparado ao tocar no botão "Cancelar" (visível apenas
  /// quando [mostrarBotaoCancelar] é `true`). O próprio diálogo já se
  /// encarrega de fechar (`Navigator.pop`) antes de chamar este
  /// callback.
  final VoidCallback? aoCancelar;

  @override
  State<PinDialogContent> createState() => _PinDialogContentState();
}


class _PinDialogContentState extends State<PinDialogContent> {
  String _pinDigitado = '';
  String? _mensagemErro;
  bool _verificando = false;

  // Contador de erros consecutivos de PIN, usado exclusivamente para o
  // gatilho silencioso do "PIN de coação" (ver [widget.aoErrarPinDuasVezes]).
  // É resetado para 0 tanto ao acionar o callback (evitando disparos
  // repetidos a cada 2 erros subsequentes) quanto ao digitar o PIN
  // correto. NUNCA influencia a mensagem de erro exibida na tela.
  int _errosConsecutivos = 0;

  void _pressionarTecla(String caractere) {
    if (_pinDigitado.length >= 4 || _verificando) return;
    setState(() {
      _pinDigitado += caractere;
      _mensagemErro = null;
    });

    if (_pinDigitado.length == 4) {
      _verificarPin();
    }
  }

  void _apagarTecla() {
    if (_pinDigitado.isEmpty || _verificando) return;
    setState(() {
      _pinDigitado = _pinDigitado.substring(0, _pinDigitado.length - 1);
      _mensagemErro = null;
    });
  }

  Future<void> _verificarPin() async {
    final pinCorreto = widget.pinEsperado != null &&
        widget.pinEsperado!.isNotEmpty &&
        _pinDigitado == widget.pinEsperado;

    if (pinCorreto) {
      _errosConsecutivos = 0;
      setState(() {
        _verificando = true;
        _mensagemErro = AppLocalizations.of(context)!.pinAlarmeDesligado; // Altera a mensagem no próprio teclado
      });

      // Aguarda 1 segundo para o usuário ler o feedback de sucesso antes de sair
      await Future.delayed(const Duration(seconds: 1));

      try {
        await widget.aoConfirmarPinCorreto();
      } catch (_) {}
      
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }

    // --- NOVA LÓGICA: Mantém o teclado travado e exibe o aviso em minúsculas ---
    _errosConsecutivos++;

    if (_errosConsecutivos >= 2 && widget.aoErrarPinDuasVezes != null) {
      _errosConsecutivos = 0;
      try {
        widget.aoErrarPinDuasVezes!.call();
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _mensagemErro = AppLocalizations.of(context)!.pinSenhaIncorreta; // Mensagem atualizada
        _pinDigitado = ''; // Reseta os indicadores de círculos para nova tentativa
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool exibirContagem = widget.segundosTolerancia != null;

    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, color: Colors.white70, size: 40),
            const SizedBox(height: 10),
            Text(
              AppLocalizations.of(context)!.pinConfirmeSeuPin,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                exibirContagem
                    ? AppLocalizations.of(context)!.pinDigiteParaDesarmar
                    : AppLocalizations.of(context)!.pinDigiteParaContinuar,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            if (exibirContagem) ...[
              const SizedBox(height: 6),
              Text(
                AppLocalizations.of(context)!.pinTempoTolerancia(widget.segundosTolerancia!),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 16),
            _buildIndicadoresPIN(),
            const SizedBox(height: 10),
            SizedBox(
              height: 18,
              child: _mensagemErro != null
                  ? Text(
                      _mensagemErro!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            _buildTecladoPIN(),
            if (widget.mostrarBotaoCancelar) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _verificando
                    ? null
                    : () {
                        if (Navigator.of(context).canPop()) {
                          Navigator.of(context).pop();
                        }
                        widget.aoCancelar?.call();
                      },
                child: Text(
                  AppLocalizations.of(context)!.cancelar,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }


  Widget _buildIndicadoresPIN() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        bool preenchido = index < _pinDigitado.length;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: preenchido ? Colors.redAccent : Colors.white24,
            border: Border.all(color: Colors.white54),
          ),
        );
      }),
    );
  }

  Widget _buildTecladoPIN() {
    return SizedBox(
      width: 260,
      height: 260,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.3,
        ),
        itemCount: 12,
        itemBuilder: (context, index) {
          if (index == 9) return const SizedBox.shrink();
          if (index == 11) {
            return IconButton(
              icon: const Icon(Icons.backspace_outlined,
                  color: Colors.white70, size: 24),
              onPressed: _verificando ? null : _apagarTecla,
            );
          }
          String numero = index == 10 ? '0' : (index + 1).toString();
          return ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.08),
              foregroundColor: Colors.white,
              shape: const CircleBorder(),
              elevation: 0,
            ),
            onPressed: _verificando ? null : () => _pressionarTecla(numero),
            child: Text(numero,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold)),
          );
        },
      ),
    );
  }
}
