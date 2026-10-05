// O teste anterior montava o app inteiro (SecurityCheckApp), que depende do
// Firebase e de plugins nativos e não roda no `flutter test` — estava
// quebrado desde o commit a59fcfa (parâmetro `futuroFirebaseEAuth` que não
// existe mais). Substituído por um teste de widget das mensagens do
// Programa de Indicação, que não depende de nada nativo.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:security_check_app/services/indicacao_service.dart';
import 'package:security_check_app/widgets/campo_codigo_indicacao.dart';

Future<AppLocalizations> _l10n(WidgetTester tester, Locale locale) async {
  late AppLocalizations l10n;
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(builder: (context) {
      l10n = AppLocalizations.of(context)!;
      return const SizedBox.shrink();
    }),
  ));
  await tester.pumpAndSettle();
  return l10n;
}

void main() {
  testWidgets('cada motivo de registrarIndicacao tem mensagem própria (pt)', (tester) async {
    final l10n = await _l10n(tester, const Locale('pt'));
    final mensagens = MotivoIndicacao.values.map((m) => mensagemMotivoIndicacao(l10n, m)).toSet();
    expect(mensagens.length, MotivoIndicacao.values.length);
    expect(mensagemMotivoIndicacao(l10n, MotivoIndicacao.autoindicacao),
        'Você não pode usar o seu próprio código.');
  });

  testWidgets('mensagens existem nos outros idiomas (en)', (tester) async {
    final l10n = await _l10n(tester, const Locale('en'));
    expect(mensagemMotivoIndicacao(l10n, MotivoIndicacao.ok), 'Referral code saved.');
    expect(l10n.indicacaoCampoTitulo, 'Have a referral code?');
  });
}
