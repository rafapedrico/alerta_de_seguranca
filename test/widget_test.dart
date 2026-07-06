// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:security_check_app/main.dart';

void main() {
  testWidgets('App inicializa e exibe a tela de Segurança', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const SecurityCheckApp(aguardandoConfirmacaoPin: false));
    await tester.pumpAndSettle();

    // Verifica que a aba inicial (Segurança) foi carregada corretamente,
    // exibindo o título no AppBar.
    expect(find.text('Segurança'), findsWidgets);

    // Verifica que a barra de navegação inferior está presente com as 3
    // abas principais do aplicativo.
    expect(find.byIcon(Icons.shield), findsWidgets);
    expect(find.byIcon(Icons.people), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
  });
}
