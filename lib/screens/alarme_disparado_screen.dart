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

  // ==========================================================
  // CONFIRMAÇÃO FINAL (alerta de emergência já disparado de verdade)
  // ==========================================================
  // Protege contra disparo/processamento duplicado: tanto o próprio
  // diálogo de PIN em primeiro plano (erro/tempo esgotado, caminho
  // PRIMÁRIO) quanto o polling da flag [chaveAlarmeEmergenciaDisparada]
  // gravada pelo callback headless (caminho de FALLBACK) podem tentar
  // finalizar a tela — apenas o primeiro a chegar deve executar a
  // sequência.
  bool _alertaJaProcessado = false;

  // Controla a UI de confirmação exibida após o alerta real ter sido
  // disparado (ver [_finalizarComConfirmacao]).
  bool _alertaDisparado = false;

  // ==========================================================
  // SINCRONIA ENTRE MÚLTIPLOS ENGINES (bug real observado em teste)
  // ==========================================================
  // RotinaCheckinAlarmActivity é lançada via Intent puro — cria um
  // engine Flutter/isolate Dart TOTALMENTE SEPARADO do da MainActivity
  // (apesar de um comentário antigo do código nativo afirmar o
  // contrário). Isso significa que podem existir DUAS instâncias desta
  // tela rodando em paralelo, cada uma com seu PRÓPRIO AudioPlayer e
  // Timers — resolver o fluxo em UMA (ex: confirmar o PIN) não para
  // automaticamente o som da OUTRA. [_fluxoEncerrado] é setado assim que
  // ESTA instância souber, por qualquer meio (resolveu ela mesma OU
  // detectou [chaveAlarmeFluxoResolvido] gravado por outra instância),
  // que o ciclo terminou — usado para nunca processar/fechar duas vezes.
  bool _fluxoEncerrado = false;

  int? _idAlarmeAtual;

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

    // Verifica imediatamente se este disparo já nasceu na fase final (ou
    // com o alerta real já disparado — ex: a tela foi recriada após ter
    // sido fechada) e continua monitorando a cada 1s enquanto a tela
    // estiver montada — ver [_iniciarPollingDeSinalizacao].
    _verificarSinalizacaoNoDisco();
    _iniciarPollingDeSinalizacao();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('📱 [INTERFACE] Botão azul montado! Carregando som customizado.');
      _tocarSomDoAlarme();
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

  /// Carrega e toca o som de alarme customizado escolhido pelo usuário,
  /// em loop. Extraído para ser reaproveitado tanto no primeiro toque
  /// (initState) quanto ao ENTRAR NA FASE FINAL ([_entrarNaFaseFinal]) —
  /// esse segundo ponto de chamada é o que garante que "o despertador
  /// toca novamente" de verdade quando a tolerância expira, já que o som
  /// NATIVO (Kotlin) não pode ser reiniciado de forma confiável a partir
  /// do callback headless (ver comentário detalhado em
  /// `RotinaAlarmeService.tocarAlarmeNovamente`) — este player Dart, por
  /// rodar sempre no engine em primeiro plano desta tela, é a fonte de
  /// som garantida.
  Future<void> _tocarSomDoAlarme() async {
    try {
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
        await _player.stop();
      } catch (_) {}

      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('sounds/$soundPath'));
      debugPrint('🔊 Som customizado iniciado com sucesso na interface: $soundPath');
    } catch (e) {
      debugPrint('⚠️ Erro ao tocar áudio na interface: $e');
    }
  }

  /// Leitura única (ao montar a tela) das flags de fase final/alerta já
  /// disparado.
  Future<void> _verificarSinalizacaoNoDisco() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    if ((prefs.getBool(chaveAlarmeEmergenciaDisparada) ?? false) && !_alertaJaProcessado) {
      await _aoDetectarEmergenciaDisparadaNoDisco();
      return;
    }

    final bool faseFinal = prefs.getBool(chaveAlarmeFaseFinal) ?? false;
    if (faseFinal && mounted && !_faseFinal) {
      _deadlineEpochMs = prefs.getInt(chaveAlarmeFaseFinalDeadlineEpochMs);
      await _entrarNaFaseFinal();
    }
  }

  /// Monitora as flags de fase final / alerta disparado a cada 1 segundo
  /// enquanto a tela estiver montada — necessário porque os callbacks
  /// headless que gravam essas flags rodam num isolate separado do desta
  /// UI (mesma técnica de "sinalização via disco" já usada em
  /// `main.dart`/`alarme_disparando_no_momento`), e esta tela pode já
  /// estar aberta (com o diálogo "normal" de PIN) no momento exato em
  /// que a tolerância/janela final expira.
  void _iniciarPollingDeSinalizacao() {
    _pollFaseFinalTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _fluxoEncerrado) {
        timer.cancel();
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // PRIORIDADE MÁXIMA: o fluxo já foi resolvido por OUTRA instância
      // desta mesma tela (engine/isolate separado, ver documentação de
      // [chaveAlarmeFluxoResolvido]) — para tudo aqui e fecha em
      // silêncio, sem reprocessar nem mostrar a própria confirmação.
      if (prefs.getBool(chaveAlarmeFluxoResolvido) ?? false) {
        await _aoDetectarResolvidoEmOutraInstancia();
        return;
      }

      if (!_alertaJaProcessado && (prefs.getBool(chaveAlarmeEmergenciaDisparada) ?? false)) {
        await _aoDetectarEmergenciaDisparadaNoDisco();
        return;
      }

      if (!_faseFinal && (prefs.getBool(chaveAlarmeFaseFinal) ?? false)) {
        _deadlineEpochMs = prefs.getInt(chaveAlarmeFaseFinalDeadlineEpochMs);
        await _entrarNaFaseFinal();
      }
    });
  }

  /// Fallback: reage à flag [chaveAlarmeEmergenciaDisparada] gravada pelo
  /// callback headless [_callbackJanelaFinalExpirada] — usado apenas
  /// quando o próprio diálogo de PIN em primeiro plano (caminho
  /// primário, ver [_dispararAlertaDeFalhaDeDesarme]) não tiver
  /// processado a falha sozinho. NÃO reenvia o alerta (o headless já o
  /// fez) — só executa a parte de UI (parar som, fechar diálogo, mostrar
  /// confirmação).
  Future<void> _aoDetectarEmergenciaDisparadaNoDisco() async {
    if (_alertaJaProcessado) return;
    _alertaJaProcessado = true;
    await _finalizarComConfirmacao();
  }

  /// Reage à flag [chaveAlarmeFluxoResolvido]: OUTRA instância desta
  /// tela (rodando num engine/isolate separado — ver documentação
  /// completa da flag) já resolveu o fluxo (PIN correto OU alerta
  /// disparado). Esta instância apenas para seu PRÓPRIO som (nativo +
  /// Dart) e se fecha SILENCIOSAMENTE — não reenvia nada nem mostra sua
  /// própria tela de confirmação, já que a outra instância já cuidou
  /// disso.
  Future<void> _aoDetectarResolvidoEmOutraInstancia() async {
    if (_fluxoEncerrado) return;
    _fluxoEncerrado = true;
    _alertaJaProcessado = true;
    _pollFaseFinalTimer?.cancel();

    debugPrint('🛑 [SINCRONIA MULTI-ENGINE] Fluxo já resolvido em outra '
        'instância da tela do alarme — encerrando esta em silêncio.');

    try {
      const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
      await canalNativo.invokeMethod('pararAlarme');
    } catch (e) {
      debugPrint('⚠️ Falha ao parar som nativo (resolvido alhures): $e');
    }
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('⚠️ Falha ao parar player Dart (resolvido alhures): $e');
    }

    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
    }

    if (!mounted) return;
    if (widget.veioDoForeground) {
      _fecharCaminhoTelaLigada(context);
    } else {
      await _fecharCaminhoTelaDesligada(context);
    }
  }

  /// Transição para a janela final: o alarme "tocou novamente" — reforça
  /// o som (Dart, garantido + nativo, melhor esforço), fecha o diálogo
  /// de PIN "normal" se ainda estiver aberto (não faz sentido mantê-lo,
  /// com o limite de 2 erros, por baixo do novo) e abre diretamente o
  /// diálogo estrito de 2 minutos, sem exigir novo toque em "Interromper
  /// Alarme".
  Future<void> _entrarNaFaseFinal() async {
    if (_faseFinal) return;
    _faseFinal = true;
    if (mounted) setState(() {});

    // Garante que o usuário OUÇA o alarme de novo: o AudioPlayer Dart é
    // a fonte CONFIÁVEL (roda neste mesmo engine em primeiro plano).
    unawaited(_tocarSomDoAlarme());

    // CORREÇÃO (bug real observado em teste): reiniciar apenas o som não
    // bastava — com o aparelho bloqueado há alguns minutos, a TELA
    // continuava apagada (ninguém via o teclado de PIN). Resolve o
    // idAlarme PRIMEIRO e usa o método nativo combinado, que acende a
    // tela fisicamente, traz a Activity de volta ao primeiro plano e
    // reforça o som nativo — tudo em uma única chamada confiável (roda
    // no engine em primeiro plano desta tela).
    _idAlarmeAtual ??= await _resolverIdAlarmeMaisRecente();
    if (_idAlarmeAtual != null) {
      unawaited(RotinaAlarmeService.acordarParaFaseFinal(_idAlarmeAtual!));
    }

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
    // Garante que o diálogo do PIN feche primeiro (se ainda houver um
    // aberto — a confirmação final não abre nenhum diálogo).
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }

    // Varre a pilha limpando qualquer rota residual de alarme que tenha ficado sobreposta
    Navigator.of(context).popUntil((route) {
      return route.isFirst || route.settings.name != '/alarme_disparado';
    });

    debugPrint('🔓 [CAMINHO TELA LIGADA] Telas de alarme limpas com sucesso. App continua aberto!');
  }

  // --- CAMINHO 2: EXCLUSIVO PARA TELA DESLIGADA (Encerra o processo nativo) ---
  Future<void> _fecharCaminhoTelaDesligada(BuildContext context) async {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
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
      // Interrompe apenas o SOM nativo ao tocar no botão — NUNCA chama
      // [RotinaAlarmeService.pausarAlarme] aqui, pois ela cancelaria os
      // alarmes nativos de tolerância/janela final ANTES do PIN ser
      // confirmado. Regra 3 exige que a tolerância continue contando
      // enquanto o PIN correto não for digitado, mesmo que o botão já
      // tenha sido tocado — só [RotinaAlarmeService.confirmarCheckinRotina]
      // (PIN correto) pode cancelá-los de verdade.
      //
      // NÃO para o [_player] aqui (diferente da versão anterior): na
      // fase final ele PRECISA continuar tocando enquanto o teclado é
      // exibido — só é interrompido de fato ao confirmar o PIN correto
      // ou ao disparar o alerta real (ver [_finalizarComConfirmacao]).
      const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
      try {
        await canalNativo.invokeMethod('pararAlarme');
      } catch (e) {
        debugPrint('⚠️ Falha ao parar som nativo do alarme: $e');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      await prefs.reload();

      final idAlarme = _idAlarmeAtual ?? await _resolverIdAlarmeMaisRecente();
      _idAlarmeAtual = idAlarme;

      if (idAlarme == null) {
        unawaited(RotinaAlarmeService.pararServicoForeground());
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
        // consecutivos disparam o alerta, sem prazo duro, SEM mostrar
        // confirmação — mantém o disfarce de segurança). Fase final:
        // ZERO margem — 1 único erro já dispara, há um prazo duro de até
        // 2 minutos exibido ao vivo, e a falha AGORA é transparente
        // (para o som, fecha o teclado e mostra confirmação).
        limiteErrosConsecutivos: ehFaseFinal ? 1 : 2,
        segundosLimiteDuro: ehFaseFinal ? segundosLimiteDuro : null,
        aoAtingirLimiteDeErros: () => _dispararAlertaDeFalhaDeDesarme(
          motivo: ehFaseFinal
              ? 'O PIN foi digitado incorretamente ao tentar confirmar o '
                  'check-in do alarme de rotina, mesmo após o tempo de '
                  'tolerância já ter expirado.'
              : null,
          mostrarConfirmacaoEFechar: ehFaseFinal,
        ),
        aoExpirarTempoLimite: ehFaseFinal
            ? () => _dispararAlertaDeFalhaDeDesarme(
                  motivo: 'O check-in do alarme de rotina não foi confirmado '
                      'dentro do prazo final de 2 minutos, mesmo após o '
                      'tempo de tolerância já ter expirado.',
                  mostrarConfirmacaoEFechar: true,
                )
            : null,
        aoConfirmarPinCorreto: () async {
          _dialogoPinAberto = false;
          _fluxoEncerrado = true;
          _pollFaseFinalTimer?.cancel();
          try {
            await _player.stop();
          } catch (_) {}
          // Grava chaveAlarmeFluxoResolvido (ver RotinaAlarmeService)
          // para que qualquer OUTRA instância desta tela, rodando num
          // engine separado (ver documentação da flag), pare seu
          // próprio som e se feche também.
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

  /// Dispara o alerta de emergência REAL por falha de desarme na JANELA
  /// FINAL (nuvem primeiro e aguardada, depois o fluxo local completo) —
  /// acionado tanto pelo limite de erros de PIN quanto pela expiração do
  /// prazo duro. Este é o caminho PRIMÁRIO (o polling da flag em disco,
  /// ver [_aoDetectarEmergenciaDisparadaNoDisco], é só um fallback).
  ///
  /// [motivo] nulo mantém o texto padrão histórico ("PIN incorreto 2
  /// vezes seguidas"), usado na fase INICIAL (regra 2) — nesse caso,
  /// [mostrarConfirmacaoEFechar] permanece `false`, preservando o
  /// disfarce de segurança (nada muda visualmente na tela). Na fase
  /// FINAL, [mostrarConfirmacaoEFechar] é sempre `true`: não há mais
  /// motivo para disfarçar — o usuário deve ver claramente que o alerta
  /// foi enviado.
  Future<void> _dispararAlertaDeFalhaDeDesarme({
    String? motivo,
    bool mostrarConfirmacaoEFechar = false,
  }) async {
    if (mostrarConfirmacaoEFechar) {
      if (_alertaJaProcessado) return;
      _alertaJaProcessado = true;

      // Este caminho (primeiro plano) já está tratando a falha — cancela
      // o alarme nativo da janela final para que ele não dispare de novo
      // (duplicando o alerta) alguns instantes depois.
      if (_idAlarmeAtual != null) {
        unawaited(RotinaAlarmeService.cancelarJanelaFinal(_idAlarmeAtual!));
      }
    }

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

    if (mostrarConfirmacaoEFechar) {
      await _finalizarComConfirmacao();
    }
  }

  /// Executa a sequência final da JANELA FINAL depois que o alerta real
  /// já foi disparado (ou sinalizado como disparado pelo callback
  /// headless, ver [_aoDetectarEmergenciaDisparadaNoDisco]):
  /// 1. Para o alarme sonoro (nativo + Dart).
  /// 2. Fecha o teclado de PIN, se ainda estiver aberto.
  /// 3. Exibe a mensagem de confirmação de envio.
  /// 4. Após alguns segundos, fecha esta tela automaticamente.
  ///
  /// Idempotente: protegida pela MESMA flag [_alertaJaProcessado] usada
  /// em [_dispararAlertaDeFalhaDeDesarme], para nunca executar esta
  /// sequência mais de uma vez.
  Future<void> _finalizarComConfirmacao() async {
    _fluxoEncerrado = true;
    _pollFaseFinalTimer?.cancel();

    // 1. Para o som — nativo (reliable a partir daqui, pois estamos no
    // engine em primeiro plano) e Dart.
    try {
      const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
      await canalNativo.invokeMethod('pararAlarme');
    } catch (e) {
      debugPrint('⚠️ Falha ao parar som nativo ao finalizar: $e');
    }
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('⚠️ Falha ao parar player Dart ao finalizar: $e');
    }

    // Libera o WakeLock nativo (ver RotinaAlarmWakeService) — não há mais
    // motivo para manter a CPU acordada além deste ponto.
    unawaited(RotinaAlarmeService.pararServicoForeground());

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      // Sinaliza a QUALQUER outra instância desta tela (engine/isolate
      // separado, ver documentação de [chaveAlarmeFluxoResolvido]) que o
      // fluxo já foi resolvido aqui — ela deve parar seu próprio som e
      // se fechar em silêncio.
      await prefs.setBool(chaveAlarmeFluxoResolvido, true);
    } catch (_) {}

    // 2. Fecha o teclado de PIN, se ainda estiver aberto.
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
    }

    // 3. Exibe a confirmação.
    if (mounted) {
      setState(() {
        _alertaDisparado = true;
        _faseFinal = true;
      });
    }

    // 4. Fecha esta tela automaticamente após o usuário ter tempo de ler
    // a confirmação.
    await Future.delayed(const Duration(seconds: 5));
    if (!mounted) return;

    if (widget.veioDoForeground) {
      _fecharCaminhoTelaLigada(context);
    } else {
      await _fecharCaminhoTelaDesligada(context);
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
                _alertaDisparado
                    ? Icons.check_circle_rounded
                    : (_faseFinal ? Icons.warning_amber_rounded : Icons.security_rounded),
                color: _alertaDisparado
                    ? Colors.greenAccent.withOpacity(0.35)
                    : (_faseFinal ? Colors.redAccent.withOpacity(0.25) : Colors.white10),
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
                      _alertaDisparado
                          ? AppLocalizations.of(context)!.alarmeRotinaAlertaEnviadoDescricao
                          : (_faseFinal
                              ? AppLocalizations.of(context)!.alarmeRotinaFaseFinalDescricao
                              : AppLocalizations.of(context)!.alarmeRotinaAtivoDescricao),
                      style: TextStyle(
                        color: _alertaDisparado
                            ? Colors.greenAccent
                            : (_faseFinal ? Colors.redAccent : Colors.white70),
                        fontSize: 16,
                        fontWeight:
                            (_faseFinal || _alertaDisparado) ? FontWeight.bold : FontWeight.normal,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    // Botão "Interromper Alarme": só na fase inicial. Na
                    // fase final o teclado já é aberto automaticamente, e
                    // após a confirmação não há mais nenhuma ação
                    // pendente do usuário.
                    if (!_faseFinal && !_alertaDisparado)
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
