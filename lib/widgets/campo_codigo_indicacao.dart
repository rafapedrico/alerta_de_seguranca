import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/indicacao_service.dart';

/// Texto de cada motivo devolvido por `registrarIndicacao` (ver
/// [IndicacaoService]). Nunca fala de recompensa: ela é só do afiliado.
String mensagemMotivoIndicacao(AppLocalizations l10n, MotivoIndicacao motivo) => switch (motivo) {
      MotivoIndicacao.ok => l10n.indicacaoMsgOk,
      MotivoIndicacao.codigoInvalido => l10n.indicacaoMsgCodigoInvalido,
      MotivoIndicacao.autoindicacao => l10n.indicacaoMsgAutoindicacao,
      MotivoIndicacao.jaVinculado => l10n.indicacaoMsgJaVinculado,
      MotivoIndicacao.jaPremium => l10n.indicacaoMsgJaPremium,
      MotivoIndicacao.erro => l10n.indicacaoMsgErro,
    };

/// "Tem um código de indicação?" em Configurações: só aparece enquanto o
/// usuário não é Premium nem tem vínculo ([IndicacaoService.podeInformarCodigo]).
/// Vem preenchido com o código do Install Referrer, quando houver.
class CampoCodigoIndicacao extends StatefulWidget {
  const CampoCodigoIndicacao({super.key});

  @override
  State<CampoCodigoIndicacao> createState() => _CampoCodigoIndicacaoState();
}

class _CampoCodigoIndicacaoState extends State<CampoCodigoIndicacao> {
  final TextEditingController _controller = TextEditingController();
  bool _visivel = false;
  bool _enviando = false;
  String? _mensagem;
  bool _sucesso = false;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _carregar() async {
    final servico = IndicacaoService();
    final pode = await servico.podeInformarCodigo();
    final doReferrer = await servico.codigoDoReferrerGuardado();
    if (!mounted) return;
    setState(() {
      _visivel = pode;
      if (doReferrer != null && _controller.text.isEmpty) _controller.text = doReferrer;
    });
  }

  Future<void> _aplicar() async {
    final l10n = AppLocalizations.of(context)!;
    FocusScope.of(context).unfocus();
    final codigo = _controller.text;
    if (!IndicacaoService.formatoValido(codigo)) {
      setState(() {
        _mensagem = l10n.indicacaoMsgFormato;
        _sucesso = false;
      });
      return;
    }
    setState(() {
      _enviando = true;
      _mensagem = null;
    });
    final motivo = await IndicacaoService().registrar(codigo, origem: IndicacaoService.origemDigitado);
    if (!mounted) return;
    setState(() {
      _enviando = false;
      _sucesso = motivo == MotivoIndicacao.ok;
      _mensagem = mensagemMotivoIndicacao(l10n, motivo);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_visivel) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final concluido = _sucesso;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.indicacaoCampoTitulo,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  enabled: !_enviando && !concluido,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 9,
                  decoration: InputDecoration(
                    hintText: l10n.indicacaoCampoDica,
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onSubmitted: (_) => _aplicar(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _enviando || concluido ? null : _aplicar,
                child: _enviando
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(l10n.indicacaoBotaoAplicar),
              ),
            ],
          ),
          if (_mensagem != null) ...[
            const SizedBox(height: 6),
            Text(
              _mensagem!,
              style: TextStyle(
                fontSize: 12.5,
                color: _sucesso ? Colors.green.shade700 : Colors.red.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
