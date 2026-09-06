import 'package:firebase_auth/firebase_auth.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

/// Resultado de classificar uma falha ao enviar/reenviar o e-mail de
/// verificação — usado pelos 3 pontos que fazem isso no app
/// (`CadastroScreen` no envio inicial, `LoginScreen` no diálogo de
/// bloqueio, `VerificarEmailScreen` no botão "Reenviar e-mail"), pra
/// mostrar sempre a MESMA mensagem e aplicar o MESMO cooldown local pro
/// mesmo tipo de erro, em vez de cada tela reinventar sua própria lógica
/// (bug real corrigido 2026-09-06: `network-request-failed` caía no texto
/// genérico de "falha ao reenviar" e ainda iniciava um cooldown de espera
/// artificial, mesmo sendo um problema de conexão que o usuário pode
/// resolver na hora — sem nenhuma relação com limite de envio).
class ErroEnvioVerificacao {
  const ErroEnvioVerificacao({required this.mensagem, required this.cooldownSegundos});

  final String mensagem;

  /// `0` = não inicia cooldown local nenhum (ex: falha de rede — assim
  /// que a conexão voltar, o usuário deve poder tentar de novo na hora,
  /// sem espera artificial que não tem relação com o problema real).
  final int cooldownSegundos;
}

ErroEnvioVerificacao classificarErroEnvioVerificacao(
  FirebaseAuthException e,
  AppLocalizations l10n, {
  int cooldownPadraoSegundos = 45,
  int cooldownThrottleSegundos = 120,
}) {
  switch (e.code) {
    case 'too-many-requests':
      // Limite de TAXA de envio do próprio Firebase Auth (não é login) —
      // mensagem orientativa e cooldown local mais longo, já que o limite
      // real do servidor claramente está mais próximo.
      return ErroEnvioVerificacao(
        mensagem: l10n.verificarEmailReenvioMuitasTentativas,
        cooldownSegundos: cooldownThrottleSegundos,
      );
    case 'network-request-failed':
      // Sem conexão — nunca um problema de limite de envio, então nunca
      // deve esperar um cooldown artificial: o usuário só precisa de
      // rede de volta, o quanto antes ele tentar de novo é o certo.
      return ErroEnvioVerificacao(
        mensagem: l10n.erroLoginSemConexao,
        cooldownSegundos: 0,
      );
    default:
      return ErroEnvioVerificacao(
        mensagem: l10n.emailVerificacaoReenvioFalhou,
        cooldownSegundos: cooldownPadraoSegundos,
      );
  }
}
