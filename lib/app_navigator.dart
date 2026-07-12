import 'package:flutter/material.dart';
import 'package:security_check_app/screens/alarme_disparado_screen.dart';

/// [GlobalKey] central do [NavigatorState] do aplicativo, registrada no
/// `navigatorKey` do [MaterialApp] em `main.dart`.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Função para navegar para a tela de alarme disparado, blindada contra cold-starts
void navigateToAlarmeDisparado() {
  // Executa após a renderização do frame atual para evitar conflito se o app estiver abrindo do zero
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final state = appNavigatorKey.currentState;
    
    if (state != null) {
      // Abre a tela por cima de forma limpa
      state.push(
        MaterialPageRoute(
          builder: (context) => const AlarmeDisparadoScreen(),
          settings: const RouteSettings(name: '/alarme_disparado'),
        ),
      );
    } else {
      // Fallback de contingência caso o estado demore um milissegundo a mais para inflar
      Future.delayed(const Duration(milliseconds: 300), () {
        appNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (context) => const AlarmeDisparadoScreen(),
            settings: const RouteSettings(name: '/alarme_disparado'),
          ),
        );
      });
    }
  });
}