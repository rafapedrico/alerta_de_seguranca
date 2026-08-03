import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/screens/tabs/inicio_dashboard.dart';

void main() {
  testWidgets('InicioDashboard renderiza sem excecao', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: const Locale('pt'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: InicioDashboard(),
        ),
      ),
    );

    // Deixa as imagens/assets assincronos tentarem carregar.
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
  });
}
