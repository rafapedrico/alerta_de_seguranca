import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/rotina_alarme_service.dart';
import '../services/database_helper.dart';
import '../services/emergency_alert_service.dart';
import '../services/firebase_sync_service.dart';
import '../services/location_service.dart';
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

  // ==========================================================
  // FASE FINAL (última chance, 2 minutos, após a tolerância expirar)
  // ==========================================================
  // Sinalizada em disco (SharedPreferences) pelo callback headless
  // [_callbackToleranciaExpirada] em rotina_alarme_service.dart, que roda
  // num isolate separado do desta UI — por isso a necessidade de checar
  // uma vez ao abrir E também de continuar monitorando via polling
  // enquanto esta tela permanecer montada (o alarme pode "tocar
  // novamente" com o usuário já olhando para a tela do primeiro diálogo).
  bool _faseFinal = false;
  Timer? _pollFaseFinalTimer;

  // Controla se HÁ, neste exato momento, um diálogo de PIN aberto por
  // cima desta tela — usado para fechá-lo antes de abrir o diálogo
  // estrito da fase final, caso o usuário ainda estivesse com o diálogo
  // "normal" (2 erros) aberto quando a tolerância expirou.
  bool _dialogoPinAberto = false;

  // Instante exato (epoch em ms) em que o alarme REAL de emergência da
  // janela final vai disparar (gravado pelo callback headless em
  // [chaveAlarmeFaseFinalDeadlineEpochMs]) — usado para que o cronômetro
  // visual do diálogo comece já refletindo o tempo realmente restante,
  // em vez de sempre recomeçar do zero quando o polling detecta a fase
  // final com um pequeno atraso.
  int? _deadlineEpochMs;

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

    // Camada extra de resiliência (Firebase): enquanto esta tela estiver
    // aberta (alarme de rotina disparado, aguardando confirmação de PIN),
    // envia a localização à nuvem a cada 1 minuto — mesma janela de
    // "monitoramento ativo" já usada pelo cronômetro da aba Segurança.
    // Interrompido em dispose() assim que o alarme for desarmado/fechado.
    LocationService().iniciarCicloDeAtualizacao();

    // Verifica imediatamente se este disparo já nasceu na fase final
    // (ex: a tela foi recriada depois de ter sido fechada durante a
    // tolerância) e continua monitorando a cada 1s enquanto ainda não
    // tivermos entrado nela — ver [_iniciarPollingFaseFinal].
    _verificarFaseFinalNoDisco();
    _iniciarPollingFaseFinal();

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
      // Encerra o ciclo de localização iniciado em initState() — mantém o
      // par iniciar/parar 1:1 exigido pela contagem de referências do
      // LocationService (ver [LocationService.pararCicloDeAtualizacao]).
      LocationService().pararCicloDeAtualizacao();
    }
    _pollFaseFinalTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Leitura única (ao montar a tela) da flag [chaveAlarmeFaseFinal].
  Future<void> _verificarFaseFinalNoDisco() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final bool faseFinal = prefs.getBool(chaveAlarmeFaseFinal) ?? false;
    if (faseFinal && mounted && !_faseFinal) {
      _deadlineEpochMs = prefs.getInt(chaveAlarmeFaseFinalDeadlineEpochMs);
      await _entrarNaFaseFinal();
    }
  }

  /// Monitora a flag [chaveAlarmeFaseFinal] a cada 1 segundo enquanto a
  /// tela estiver montada e ainda não tivermos entrado na fase final —
  /// necessário porque o callback headless que marca essa flag roda num
  /// isolate separado do desta UI (mesma técnica de "sinalização via
  /// disco" já usada em `main.dart`/`alarme_disparando_no_momento`), e
  /// esta tela pode já estar aberta (com o diálogo "normal" de PIN) no
  /// momento exato em que a tolerância expira.
  void _iniciarPollingFaseFinal() {
    _pollFaseFinalTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_faseFinal) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final bool faseFinal = prefs.getBool(chaveAlarmeFaseFinal) ?? false;
      if (faseFinal && mounted && !_faseFinal) {
        _deadlineEpochMs = prefs.getInt(chaveAlarmeFaseFinalDeadlineEpochMs);
        await _entrarNaFaseFinal();
      }
    });
  }

  /// Transição para a janela final: o alarme "tocou novamente" (ver
  /// [RotinaAlarmeService.tocarAlarmeNovamente]) — fecha o diálogo de PIN
  /// "normal" se ainda estiver aberto (não faz sentido mantê-lo, com o
  /// limite de 2 erros, por baixo do novo) e abre diretamente o diálogo
  /// estrito de 2 minutos, sem exigir novo toque em "Interromper Alarme".
  Future<void> _entrarNaFaseFinal() async {
    if (_faseFinal) return;
    _faseFinal = true;
    if (mounted) setState(() {});

    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
      // Pequena espera para o pop concluir antes de empilhar o próximo
      // diálogo por cima da mesma rota.
      await Future.delayed(const Duration(milliseconds: 150));
    }

    if (!mounted) return;
    await _abrirTecladoPin();
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

  /// Resolve o id do alarme de rotina mais recentemente disparado
  /// (`ultimo_disparo_epoch` mais alto), usado tanto pelo toque no botão
  /// "Interromper Alarme" quanto pela transição automática para a fase
  /// final.
  Future<int?> _resolverIdAlarmeMaisRecente() async {
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

    return maisRecente?['id'] as int?;
  }

  /// Ponto ÚNICO de abertura do teclado de PIN — usado tanto pelo toque
  /// no botão "Interromper Alarme" (fase inicial: limite de 2 erros
  /// consecutivos, sem prazo duro) quanto pela transição automática para
  /// a janela final (limite de 1 erro + 2 minutos de prazo duro, ver
  /// [_entrarNaFaseFinal]). Consolida a resolução do alarme mais recente,
  /// a busca do PIN esperado e o fluxo de confirmação/erro/expiração.
  Future<void> _abrirTecladoPin() async {
    try {
      try {
        await _player.stop();
      } catch (e) {
        debugPrint('⚠️ Erro ao parar player na interface: $e');
      }

      // --- CORREÇÃO CIRÚRGICA: Limpa o disco IMEDIATAMENTE para matar o loop do main.dart ---
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      await prefs.reload();
      // ----------------------------------------------------------------------------------

      // Interrompe apenas o SOM nativo ao tocar no botão — NUNCA chama
      // [RotinaAlarmeService.pausarAlarme] aqui, pois ela cancelaria os
      // alarmes nativos de tolerância/janela final ANTES do PIN ser
      // confirmado. Regra 3 exige que a tolerância continue contando
      // enquanto o PIN correto não for digitado, mesmo que o botão já
      // tenha sido tocado — só [RotinaAlarmeService.confirmarCheckinRotina]
      // (PIN correto) pode cancelá-los de verdade.
      const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
      try {
        await canalNativo.invokeMethod('pararAlarme');
      } catch (e) {
        debugPrint('⚠️ Falha ao parar som nativo do alarme: $e');
      }

      final idAlarme = await _resolverIdAlarmeMaisRecente();

      if (idAlarme == null) {
        if (mounted) {
          if (widget.veioDoForeground) {
            _fecharCaminhoTelaLigada(context);
          } else {
            await _fecharCaminhoTelaDesligada(context);
          }
        }
        return;
      }

      final config = await DatabaseHelper().getUserConfig();
      final pinReal = config?['pin_real'] as String? ?? '1234';

      if (!mounted) return;

      // Capturado no momento da abertura: se a fase final mudar enquanto
      // este diálogo específico já está aberto, ela só afeta o PRÓXIMO
      // diálogo (aberto por [_entrarNaFaseFinal] após fechar este).
      final bool ehFaseFinal = _faseFinal;

      // Calcula o tempo REALMENTE restante até o alarme nativo de
      // emergência da janela final disparar (ver [_deadlineEpochMs]), em
      // vez de sempre começar do zero em 2 minutos — garante que o
      // cronômetro visual reflita com precisão o prazo real, mesmo com o
      // pequeno atraso do polling que detectou a fase final.
      int segundosLimiteDuro = RotinaAlarmeService.duracaoJanelaFinal.inSeconds;
      if (ehFaseFinal && _deadlineEpochMs != null) {
        final restanteMs = _deadlineEpochMs! - DateTime.now().millisecondsSinceEpoch;
        segundosLimiteDuro = (restanteMs / 1000).ceil().clamp(
              0,
              RotinaAlarmeService.duracaoJanelaFinal.inSeconds,
            );
      }

      _dialogoPinAberto = true;
      await exibirDialogoPin(
        context: context,
        pinEsperado: pinReal,
        segundosTolerancia: null,
        // Fase inicial: mantém o comportamento histórico (2 erros
        // consecutivos disparam o alerta, sem prazo duro). Fase final:
        // ZERO margem — 1 único erro já dispara, e há um prazo duro de
        // até 2 minutos exibido ao vivo no próprio diálogo.
        limiteErrosConsecutivos: ehFaseFinal ? 1 : 2,
        segundosLimiteDuro: ehFaseFinal ? segundosLimiteDuro : null,
        aoAtingirLimiteDeErros: () => _dispararAlertaDeFalhaDeDesarme(
          motivo: ehFaseFinal
              ? 'O PIN foi digitado incorretamente ao tentar confirmar o '
                  'check-in do alarme de rotina, mesmo após o tempo de '
                  'tolerância já ter expirado.'
              : null,
        ),
        aoExpirarTempoLimite: ehFaseFinal
            ? () => _dispararAlertaDeFalhaDeDesarme(
                  motivo: 'O check-in do alarme de rotina não foi confirmado '
                      'dentro do prazo final de 2 minutos, mesmo após o '
                      'tempo de tolerância já ter expirado.',
                )
            : null,
        aoConfirmarPinCorreto: () async {
          _dialogoPinAberto = false;
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
      _dialogoPinAberto = false;
    } catch (e) {
      debugPrint('⚠️ Erro no fluxo de silenciamento e PIN: $e');
      _dialogoPinAberto = false;
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }
  }

  /// Dispara o alerta de emergência REAL por falha de desarme (nuvem
  /// primeiro e aguardada, depois o fluxo local completo) — reaproveitado
  /// tanto pelo limite de erros de PIN quanto pela expiração do prazo
  /// duro da fase final. [motivo] nulo mantém o texto padrão histórico
  /// ("PIN incorreto 2 vezes seguidas"), usado na fase inicial (regra 2).
  Future<void> _dispararAlertaDeFalhaDeDesarme({String? motivo}) async {
    try {
      await FirebaseSyncService()
          .dispararAlertaTentativaDesarmeIncorreto(motivo: motivo);
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar alerta prioritário na nuvem: $e');
    }
    try {
      await EmergencyAlertService()
          .dispararAlertaTentativaDesarmeIncorreto(motivo: motivo);
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar alerta de tentativa de '
          'desarme incorreta: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Icon(
                _faseFinal ? Icons.warning_amber_rounded : Icons.security_rounded,
                color: _faseFinal ? Colors.redAccent.withOpacity(0.25) : Colors.white10,
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
                    Text(
                      _faseFinal
                          ? AppLocalizations.of(context)!.alarmeRotinaFaseFinalDescricao
                          : AppLocalizations.of(context)!.alarmeRotinaAtivoDescricao,
                      style: TextStyle(
                        color: _faseFinal ? Colors.redAccent : Colors.white70,
                        fontSize: 16,
                        fontWeight: _faseFinal ? FontWeight.bold : FontWeight.normal,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    // Na fase final o teclado de PIN já é aberto
                    // automaticamente (ver [_entrarNaFaseFinal]) — o
                    // botão não é mais necessário nem faz sentido (não há
                    // mais uma segunda chance de "tolerância" para
                    // ativar).
                    if (!_faseFinal)
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
                          onPressed: _abrirTecladoPin,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.alarm_off, size: 26),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  AppLocalizations.of(context)!.desligarAlarmeBotao,
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.1,
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
            ),
          ],
        ),
      ),
    );
  }
}
