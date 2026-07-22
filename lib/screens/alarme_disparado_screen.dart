import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/rotina_alarme_service.dart';
import '../services/database_helper.dart';
import '../widgets/pin_dialog.dart';
import 'package:audioplayers/audioplayers.dart';

class AlarmeDisparadoScreen extends StatefulWidget {
  // --- ADICIONADO: Parâmetro para saber se o app já estava aberto ---
  final bool veioDoForeground;
  const AlarmeDisparadoScreen({super.key, this.veioDoForeground = false});
  // ------------------------------------------------------------------

  @override
  State<AlarmeDisparadoScreen> createState() => _AlarmeDisparadoScreenState();
}

class _AlarmeDisparadoScreenState extends State<AlarmeDisparadoScreen> {
  final AudioPlayer _player = AudioPlayer();

  static bool _instanciaGraficaAberta = false;
  bool _souDuplicada = false;

  @override
  void initState() {
    super.initState();
    
    if (_instanciaGraficaAberta) {
      _souDuplicada = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('🛡️ [SINTONIA] Detetada tentativa de tela azul duplicada. Removendo da pilha imediatamente!');
        Navigator.of(context).pop();
      });
      return;
    }
    
    _instanciaGraficaAberta = true; 
    
WidgetsBinding.instance.addPostFrameCallback((_) async {
      debugPrint('📱 [INTERFACE] Botão azul montado! Carregando som customizado.');
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // Força a leitura atualizada do disco
      if (prefs.getBool('stop_current_alarm') == true) return;

      // 1. Tenta buscar das SharedPreferences (String)
      String? soundPath = prefs.getString('tom_alarme_selecionado') ?? 
                          prefs.getString('tom_alarme');

      // 2. Tenta buscar das SharedPreferences (Int)
      if (soundPath == null || soundPath.isEmpty) {
        final int? somInt = prefs.getInt('som_selecionado') ?? prefs.getInt('tom_alarme_id');
        if (somInt != null) {
          soundPath = 'som_$somInt.mp3';
        }
      }

      // 3. 🟢 FALLBACK DE SEGURANÇA: Consulta direta na tabela user_config
      if (soundPath == null || soundPath.isEmpty) {
        try {
          final dbHelper = DatabaseHelper();
          final config = await dbHelper.getUserConfig();
          final int? somDb = config?['som_alarme_selecionado'] as int? ?? 
                             config?['som_selecionado'] as int?;
          if (somDb != null) {
            soundPath = 'som_$somDb.mp3';
          }
        } catch (e) {
          debugPrint('⚠️ Erro ao buscar som no SQLite: $e');
        }
      }

      // 4. Se nada for encontrado em nenhum lugar, assume som_1.mp3 como padrão
      soundPath ??= 'som_1.mp3';

      if (!soundPath.endsWith('.mp3')) {
        soundPath = '$soundPath.mp3';
      }

      try {
        await _player.setReleaseMode(ReleaseMode.loop);
        await _player.play(AssetSource('sounds/$soundPath'));
        debugPrint('🔊 Som customizado iniciado com sucesso na interface: $soundPath');
      } catch (e) {
        debugPrint('⚠️ Erro ao tocar áudio na interface: $e');
      }
    });
  }

  @override
  void dispose() {
    if (!_souDuplicada) {
      _instanciaGraficaAberta = false;
    }
    _player.dispose();
    super.dispose();
  }

  // --- CAMINHO 1: EXCLUSIVO PARA TELA LIGADA (Limpa toda e qualquer tela azul duplicada) ---
  void _fecharCaminhoTelaLigada(BuildContext context) {
    // Garante que o diálogo do PIN feche primeiro
    Navigator.of(context).pop();
    
    // Varre a pilha limpando qualquer rota residual de alarme que tenha ficado sobreposta
    Navigator.of(context).popUntil((route) {
      return route.isFirst || route.settings.name != '/alarme_disparado';
    });
    
    debugPrint('🔓 [CAMINHO TELA LIGADA] Telas de alarme limpas com sucesso. App continua aberto!');
  }

  // --- CAMINHO 2: EXCLUSIVO PARA TELA DESLIGADA (Encerra o processo nativo) ---
  Future<void> _fecharCaminhoTelaDesligada(BuildContext context) async {
    Navigator.of(context).pop();
    await SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    debugPrint('🔓 [CAMINHO TELA DESLIGADA] Encerrando o processo nativo e voltando para o Android.');
  }

  Future<void> _desligarAlarmeEFechar(BuildContext context) async {
    try {
      try {
        await _player.stop();
        debugPrint('🔇 Som interrompido pelo clique no botão azul.');
      } catch (e) {
        debugPrint('⚠️ Erro ao parar player na interface: $e');
      }

      // --- CORREÇÃO CIRÚRGICA: Limpa o disco IMEDIATAMENTE para matar o loop do main.dart ---
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      await prefs.reload();
      // ----------------------------------------------------------------------------------

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
        await RotinaAlarmeService.pausarAlarme(idAlarme);
        
        final config = await DatabaseHelper().getUserConfig();
        final pinReal = config?['pin_real'] as String? ?? '1234';

        if (!context.mounted) return;

        // Abre o teclado de PIN de forma limpa
        await exibirDialogoPin(
          context: context,
          pinEsperado: pinReal,
          segundosTolerancia: null,
          aoConfirmarPinCorreto: () async {
            await RotinaAlarmeService.confirmarCheckinRotina(idAlarme);
            
            if (!context.mounted) return;

            // --- SEPARAÇÃO DE CAMINHOS BASEADA NA INTERFACE ATIVA ---
            final ModalRoute<dynamic>? rotaAtual = ModalRoute.of(context);
            final bool interfaceGraficaAtiva = rotaAtual?.isActive ?? false;

            if (widget.veioDoForeground && interfaceGraficaAtiva) {
              _fecharCaminhoTelaLigada(context);
            } else {
              await _fecharCaminhoTelaDesligada(context);
            }
          },
        );

      } else {
        const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
        await canalNativo.invokeMethod('pararAlarme');
        
        if (context.mounted) {
          if (widget.veioDoForeground) {
            _fecharCaminhoTelaLigada(context);
          } else {
            await _fecharCaminhoTelaDesligada(context);
          }
        }
      }

    } catch (e) {
      debugPrint('⚠️ Erro no fluxo de silenciamento e PIN: $e');
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212), 
      body: SafeArea(
        child: Stack(
          children: [
            const Center(
              child: Icon(
                Icons.security_rounded,
                color: Colors.white10,
                size: 140,
              ),
            ),
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
                          backgroundColor: Colors.blue.shade700, 
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