import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/rotina_alarme_service.dart';
import '../services/database_helper.dart';

class AlarmeDisparadoScreen extends StatelessWidget {
  const AlarmeDisparadoScreen({super.key});

  Future<void> _desligarAlarmeEFechar(BuildContext context) async {
    try {
      // 1. Grava IMEDIATAMENTE as flags no disco para matar o áudio Headless do Flutter
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      await prefs.reload(); // Força o salvamento físico imediato

      // 2. Busca o ID do alarme ativo para rodar a confirmação
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
        // Para o cronômetro do SMS e chama o encerramento nativo
        await RotinaAlarmeService.confirmarCheckinRotina(idAlarme);
      } else {
        // Fallback nativo direto
        const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
        await canalNativo.invokeMethod('pararAlarme');
      }

      // 3. Fecha a interface e a activity nativa
      await SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    } catch (e) {
      debugPrint('⚠️ Erro ao desligar alarme e fechar: $e');
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212), // Fundo escuro discreto premium
      body: SafeArea(
        child: Stack(
          children: [
            // Escudo de segurança em segundo plano
            const Center(
              child: Icon(
                Icons.security_rounded,
                color: Colors.white10,
                size: 140,
              ),
            ),
            // O Botão Azul Grande Clássico posicionado na parte inferior
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Alarme de rotina ativo.\nConfirme seu segurança para pausar.',
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 64,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade700, // O azul original
                          foregroundColor: Colors.white,
                          elevation: 6,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(32),
                          ),
                        ),
                        onPressed: () => _desligarAlarmeEFechar(context),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.alarm_off, size: 26),
                            SizedBox(width: 12),
                            Text(
                              'DESLIGAR ALARME',
                              style: TextStyle(
                                fontSize: 18, 
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}