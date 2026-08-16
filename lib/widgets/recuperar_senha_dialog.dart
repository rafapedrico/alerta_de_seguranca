import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/firebase_auth_service.dart';

/// Modal de recuperação de senha ("Esqueci minha senha") — real, via
/// Firebase Auth (`sendPasswordResetEmail`), reespecificação do usuário
/// (2026-08-16): antes só exibia um SnackBar de placeholder
/// ("Recuperação de senha em breve").
///
/// Uso: `showDialog(context: context, builder: (_) =>
/// RecuperarSenhaDialog(emailInicial: ...))` — [emailInicial] pré-preenche
/// o campo com o que o usuário já tiver digitado no formulário de login,
/// evitando redigitar.
///
/// Fluxo interno de 2 estados nesta MESMA janela (sem navegar para outra
/// tela): formulário de e-mail -> sucesso (com botão "Fechar"). Erros são
/// exibidos INLINE, dentro do próprio diálogo (nunca via SnackBar — um
/// `AlertDialog` não tem Scaffold próprio para hospedar um).
class RecuperarSenhaDialog extends StatefulWidget {
  const RecuperarSenhaDialog({super.key, this.emailInicial});

  final String? emailInicial;

  @override
  State<RecuperarSenhaDialog> createState() => _RecuperarSenhaDialogState();
}

class _RecuperarSenhaDialogState extends State<RecuperarSenhaDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _emailController;

  bool _enviando = false;
  bool _enviado = false;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.emailInicial?.trim() ?? '');
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _enviarLink() async {
    if (_enviando) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _enviando = true;
      _erro = null;
    });

    final l10n = AppLocalizations.of(context)!;
    final email = _emailController.text.trim();

    try {
      // Idioma do e-mail (reespecificação do usuário, 2026-08-16): usa o
      // idioma ATIVO do app (não necessariamente o do sistema — pode ter
      // sido trocado manualmente em Configurações, ver `LocaleService`),
      // para o template do Firebase Auth chegar no mesmo idioma que o
      // usuário está usando no app, em vez do inglês padrão do projeto.
      await FirebaseAuthService().recuperarSenha(
        email: email,
        languageCode: Localizations.localeOf(context).languageCode,
      );
      if (!mounted) return;
      setState(() {
        _enviando = false;
        _enviado = true;
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _enviando = false;
        _erro = _mensagemErro(l10n, e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _enviando = false;
        _erro = l10n.erroLoginGenerico;
      });
    }
  }

  /// Mapeia os códigos reais do Firebase Auth para mensagens claras — ver
  /// mesmo padrão já usado por `LoginScreen._mensagemErroLogin`.
  /// PROPOSITALMENTE não distingue `user-not-found` com uma mensagem
  /// única e diferenciada das demais: por padrão de segurança (evitar que
  /// o formulário sirva para descobrir quais e-mails têm conta
  /// cadastrada — "enumeração de contas"), o próprio Firebase, em
  /// versões recentes do SDK, já pode devolver sucesso mesmo para e-mails
  /// inexistentes; mas quando o SDK realmente devolve `user-not-found`,
  /// mostrar isso não é um vazamento adicional de informação (o usuário
  /// já está tentando recuperar UMA conta específica seguindo o próprio
  /// fluxo de login), por isso a mensagem específica é exibida sim, sem
  /// disfarce artificial.
  String _mensagemErro(AppLocalizations l10n, FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
        return l10n.recuperacaoSenhaErroUsuarioNaoEncontrado;
      case 'invalid-email':
        return l10n.campoEmailInvalido;
      case 'too-many-requests':
        return l10n.erroLoginMuitasTentativas;
      case 'network-request-failed':
        return l10n.recuperacaoSenhaErroRede;
      default:
        return l10n.erroLoginGenerico;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (_enviado) {
      return AlertDialog(
        title: Text(l10n.recuperacaoSenhaTitulo),
        content: Text(l10n.recuperacaoSenhaSucesso(_emailController.text.trim())),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.fechar),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Text(l10n.recuperacaoSenhaTitulo),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.recuperacaoSenhaDescricao),
            const SizedBox(height: 16),
            TextFormField(
              controller: _emailController,
              autofocus: widget.emailInicial == null || widget.emailInicial!.isEmpty,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              enabled: !_enviando,
              decoration: InputDecoration(
                labelText: l10n.campoEmailLabel,
                border: const OutlineInputBorder(),
              ),
              validator: (valor) {
                final texto = valor?.trim() ?? '';
                if (texto.isEmpty) return l10n.campoEmailObrigatorio;
                // Mesma validação simples já usada no resto do app (ver
                // CadastroScreen) — checagem de formato básica, a
                // confirmação real de que o e-mail existe/é válido vem do
                // próprio Firebase (`invalid-email`/`user-not-found`).
                if (!texto.contains('@') || !texto.contains('.')) {
                  return l10n.campoEmailInvalido;
                }
                return null;
              },
              onFieldSubmitted: (_) => _enviarLink(),
            ),
            if (_erro != null) ...[
              const SizedBox(height: 12),
              Text(
                _erro!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancelar),
        ),
        ElevatedButton(
          onPressed: _enviando ? null : _enviarLink,
          child: _enviando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.recuperacaoSenhaBotaoEnviar),
        ),
      ],
    );
  }
}
