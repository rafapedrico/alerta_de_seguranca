import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/firebase_auth_service.dart';
import 'recuperar_senha_dialog.dart';

/// Modal de vinculação de conta Google a uma conta e-mail/senha JÁ
/// EXISTENTE com o MESMO e-mail — pedido explícito do usuário (2026-09-06:
/// "se tentar logar de um telefone novo vai dar aviso de que este e-mail
/// já está sendo usado... precisamos da recuperação, com confirmação de
/// e-mail para garantir que o usuário é o real").
///
/// Exibido por [LoginScreen] quando [SocialAuthService.signInWithGoogle]
/// lança `ContaGoogleParaVincularException` — o Firebase Auth recusa
/// autenticar direto porque já existe uma conta com esse e-mail usando um
/// provedor diferente (não funde contas de provedores diferentes
/// sozinho). A PROVA DE IDENTIDADE aqui é a SENHA da conta existente —
/// nunca "confirmar automaticamente só por dizer o e-mail" (isso seria
/// uma credencial fraca igual à do telefone, já recusada em
/// `telefonePerfilService.js` pelo mesmo motivo). Quem não lembra mais a
/// senha usa "Esqueci minha senha" (fluxo real já existente,
/// [RecuperarSenhaDialog]) e tenta de novo depois de trocá-la.
///
/// Ao confirmar a senha com sucesso, vincula o credential do Google (via
/// `linkWithCredential`) à MESMA conta — dali em diante, os dois métodos
/// (e-mail/senha e Google) funcionam para essa conta.
///
/// Retorna `true` (via `Navigator.pop`) quando a vinculação teve sucesso
/// — [LoginScreen] segue então para o fluxo pós-login normal; `false`/
/// `null` se o usuário cancelar.
class VincularContaGoogleDialog extends StatefulWidget {
  const VincularContaGoogleDialog({
    super.key,
    required this.email,
    required this.credencialGoogle,
  });

  final String email;
  final OAuthCredential credencialGoogle;

  @override
  State<VincularContaGoogleDialog> createState() => _VincularContaGoogleDialogState();
}

class _VincularContaGoogleDialogState extends State<VincularContaGoogleDialog> {
  final _formKey = GlobalKey<FormState>();
  final _senhaController = TextEditingController();

  bool _senhaVisivel = false;
  bool _vinculando = false;
  String? _erro;

  @override
  void dispose() {
    _senhaController.dispose();
    super.dispose();
  }

  Future<void> _vincular() async {
    if (_vinculando) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _vinculando = true;
      _erro = null;
    });
    final l10n = AppLocalizations.of(context)!;

    try {
      // Passo 1: prova de identidade — login normal na conta EXISTENTE
      // com a senha informada (nunca aceita o e-mail sozinho como prova).
      await FirebaseAuthService().login(email: widget.email, senha: _senhaController.text);
      // Passo 2: com a identidade confirmada, vincula o credential do
      // Google JÁ obtido (mesmo idToken da tentativa original) a esta
      // MESMA conta — nenhum novo login com o Google é necessário.
      await FirebaseAuth.instance.currentUser!.linkWithCredential(widget.credencialGoogle);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _vinculando = false;
        _erro = _mensagemErro(l10n, e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _vinculando = false;
        _erro = l10n.erroLoginGenerico;
      });
    }
  }

  /// Mesmo padrão de `LoginScreen._mensagemErroLogin` — cobre tanto a
  /// falha do login por senha (passo 1) quanto da vinculação em si
  /// (passo 2, ex: `credential-already-in-use` — este Google já está
  /// vinculado a OUTRA conta, cenário raro mas possível).
  String _mensagemErro(AppLocalizations l10n, FirebaseAuthException e) {
    switch (e.code) {
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-credential':
        return l10n.erroLoginCredenciaisInvalidas;
      case 'too-many-requests':
        return l10n.erroLoginMuitasTentativas;
      case 'network-request-failed':
        return l10n.erroLoginSemConexao;
      case 'credential-already-in-use':
      case 'provider-already-linked':
        return l10n.vincularContaGoogleJaVinculada;
      default:
        return l10n.erroLoginGenerico;
    }
  }

  void _abrirEsqueciMinhaSenha() {
    showDialog<void>(
      context: context,
      builder: (_) => RecuperarSenhaDialog(emailInicial: widget.email),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.vincularContaGoogleTitulo),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.vincularContaGoogleMensagem(widget.email)),
            const SizedBox(height: 16),
            TextFormField(
              controller: _senhaController,
              obscureText: !_senhaVisivel,
              autofocus: true,
              enabled: !_vinculando,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l10n.campoSenhaLabel,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_senhaVisivel ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => _senhaVisivel = !_senhaVisivel),
                ),
              ),
              validator: (valor) =>
                  (valor == null || valor.isEmpty) ? l10n.campoSenhaObrigatoria : null,
              onFieldSubmitted: (_) => _vincular(),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _vinculando ? null : _abrirEsqueciMinhaSenha,
                child: Text(l10n.esqueciMinhaSenha),
              ),
            ),
            if (_erro != null) ...[
              const SizedBox(height: 8),
              Text(_erro!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _vinculando ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelar),
        ),
        ElevatedButton(
          onPressed: _vinculando ? null : _vincular,
          child: _vinculando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.vincularContaGoogleBotao),
        ),
      ],
    );
  }
}
