import 'package:flutter/material.dart';
import 'package:security_check_app/screens/alarme_disparado_screen.dart';

/// [GlobalKey] central do [NavigatorState] do aplicativo, registrada no
/// `navigatorKey` do [MaterialApp] em `main.dart`.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Função para navegar para a tela de alarme disparado, blindada contra cold-starts
/// Função para navegar para a tela de alarme disparado, limpando a pilha no cold-start
void navigateToAlarmeDisparado() {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final state = appNavigatorKey.currentState;
    
    if (state != null) {
      // Força a AlarmeDisparadoScreen a ser a tela raiz atual, eliminando a LoginScreen do caminho
      state.pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => const AlarmeDisparadoScreen(),
          settings: const RouteSettings(name: '/alarme_disparado'),
        ),
        (route) => false, // Remove todas as rotas anteriores (inclusive telas de carregamento/login)
      );
      debugPrint('🚀 [AppNavigator] Tela de alarme injetada com sucesso como raiz absoluta.');
    } else {
      // Fallback defensivo com um delay leve caso o motor gráfico precise de fôlego
      Future.delayed(const Duration(milliseconds: 400), () {
        appNavigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => const AlarmeDisparadoScreen(),
            settings: const RouteSettings(name: '/alarme_disparado'),
          ),
          (route) => false,
        );
      });
    }
  });
}