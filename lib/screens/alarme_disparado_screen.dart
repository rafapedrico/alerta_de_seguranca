import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/rotina_alarme_service.dart';
import '../services/database_helper.dart';
import '../app_navigator.dart';

class AlarmeDisparadoScreen extends StatelessWidget {
  const AlarmeDisparadoScreen({super.key});

  Future<void> _desligarAlarmeEFechar(BuildContext context) async {
    try {
      // 1. FORÇA O PREFS GLOBAL PARA PARAR O LOOP EM DART
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');

      // 2. BUSCA O ID DO ALARME ATIVO PARA CONFIRMAR O CHECK-IN
      final alarmes = await DatabaseHelper().listarAlarmes();
      Map<String, dynamic>? maisRecente;
      
      for (final alarme in alarmes) {
        final epoch = alarme['ultimo_disparo_epoch'] as int?;
        if (epoch == null) continue;
        final epochAtual = maisRecente?['ultimo_disparo_epoch'] as int?;
        if (epochAtual == null || epoch > epochAtual) {
          maisRecente = alarme;
        }
      }
      
      final idAlarme = maisRecente?['id'] as int?;

      if (idAlarme != null) {
        // Para o áudio nativo e cancela o cronômetro de tolerância do SMS
        await RotinaAlarmeService.confirmarCheckinRotina(idAlarme);
        await RotinaAlarmeService.pausarAlarme(idAlarme);
      } else {
        // Fallback de emergência caso o ID não seja resolvido
        await RotinaAlarmeService.desligarAlarme();
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao desligar áudio do alarme: $e');
    } finally {
      // 3. RECUA A TELA DO VISOR
      if (appNavigatorKey.currentState?.canPop() ?? false) {
        appNavigatorKey.currentState?.pop();
      } else {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.security_rounded,
                color: Colors.blue,
                size: 80,
              ),
              const SizedBox(height: 20),
              const Text(
                'Alarme de rotina -\nConfirme seu segurança e pause o alarme',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 50),
              SizedBox(
                width: double.infinity,
                height: 80,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade800,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 4,
                  ),
                  onPressed: () => _desligarAlarmeEFechar(context),
                  child: const Text(
                    'DESLIGAR ALARME',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}