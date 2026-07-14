import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/rotina_alarme_service.dart';
import '../services/database_helper.dart';
import '../app_navigator.dart';

class AlarmeDisparadoScreen extends StatelessWidget {
  const AlarmeDisparadoScreen({super.key});

  Future<void> _desligarAlarmeEFechar(BuildContext context) async {
    try {
      // 1. FORÇA O PREFS GLOBAL PARA PARAR O LOOP EM DART E LIMPA A FLAG
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
        await RotinaAlarmeService.confirmarCheckinRotina(idAlarme);
        debugPrint('⏸️ Alarme de rotina #$idAlarme confirmado e pausado.');
      }

      // 3. FECHA A ATIVIDADE NATIVA DO ANDROID IMEDIATAMENTE (ELIMINA A TELA PRETA)
      await SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    } catch (e) {
      debugPrint('⚠️ Erro ao desligar alarme e fechar: $e');
      // Fallback de segurança caso o canal falhe
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Fundo preto para máxima discrição
      body: Stack(
        children: [
          // Espaço centralizado para alguma informação ou apenas vácuo discreto
          const Center(
            child: Icon(
              Icons.security,
              color: Colors.white10,
              size: 120,
            ),
          ),
          // Botão Flutuante Branco idêntico posicionado na parte inferior
          Positioned(
            bottom: 32,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(28),
                color: Colors.white,
                child: InkWell(
                  onTap: () => _desligarAlarmeEFechar(context),
                  borderRadius: BorderRadius.circular(28),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.alarm_off, color: Colors.black87),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Cancelar alarme de rotina',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.black87,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Roboto',
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}