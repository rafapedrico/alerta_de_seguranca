import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Representa um som disponível para o Alerta Sonoro Customizável,
/// disparado ao término do cronômetro de check-in (aba Segurança).
class SomAlarme {
  final int numero;
  final String nomeExibicao;
  final String assetPath;

  const SomAlarme({
    required this.numero,
    required this.nomeExibicao,
    required this.assetPath,
  });

  /// Nome do som traduzido no idioma ativo do app — usado na UI de
  /// Configurações (dropdown de seleção) no lugar de [nomeExibicao], que
  /// permanece só em português para uso em logs internos (`debugPrint`).
  String nomeLocalizado(AppLocalizations l10n) {
    switch (numero) {
      case 1:
        return l10n.somNome1;
      case 2:
        return l10n.somNome2;
      case 3:
        return l10n.somNome3;
      case 4:
        return l10n.somNome4;
      case 5:
        return l10n.somNome5;
      case 6:
        return l10n.somNome6;
      case 7:
        return l10n.somNome7;
      case 8:
        return l10n.somNome8;
      case 9:
        return l10n.somNome9;
      case 10:
        return l10n.somNome10;
      default:
        return nomeExibicao;
    }
  }
}

/// Serviço central responsável por:
/// - Listar os 10 sons disponíveis (placeholders `som_1.mp3` até
///   `som_10.mp3`, ver `assets/sounds/README.md`).
/// - Persistir (SharedPreferences) a escolha do som e da duração do
///   toque (em segundos) feitas pelo usuário em Configurações.
/// - Tocar o som escolhido em LOOP contínuo pelo tempo configurado,
///   usado pela `SegurancaTab` quando o cronômetro principal chega a
///   zero (tela de bloqueio de PIN é exibida).
/// - Permitir "testar/ouvir" um som isoladamente na tela de
///   Configurações, sem depender de nenhum outro estado do app.
///
/// Implementado como singleton para que exista uma única instância de
/// [AudioPlayer] ativa a qualquer momento, evitando sons sobrepostos.
class AlarmeSonoroService {
  AlarmeSonoroService._internal();
  static final AlarmeSonoroService _instance = AlarmeSonoroService._internal();
  factory AlarmeSonoroService() => _instance;

  static const String _prefsKeySom = 'alarme_sonoro_som_selecionado';
  static const String _prefsKeyDuracao = 'alarme_sonoro_duracao_segundos';

  /// Duração padrão do toque, em segundos, caso o usuário nunca tenha
  /// configurado nada ainda.
  static const int duracaoPadraoSegundos = 30;

  /// Som padrão (numero 1) usado enquanto o usuário não escolher outro.
  static const int somPadrao = 1;

  /// Os 10 sons suportados pelo app, exibidos com nomes comerciais para
  /// facilitar a identificação pelo usuário. Os nomes de arquivo
  /// continuam sendo placeholders (`som_1.mp3` ... `som_10.mp3`) — ver
  /// `assets/sounds/README.md` para instruções de substituição pelos
  /// arquivos de áudio reais antes de um build de produção.
  static const List<SomAlarme> sonsDisponiveis = [
    SomAlarme(numero: 1, nomeExibicao: 'Bipe Clássico', assetPath: 'sounds/som_1.mp3'),
    SomAlarme(numero: 2, nomeExibicao: 'Sirene Tática', assetPath: 'sounds/som_2.mp3'),
    SomAlarme(numero: 3, nomeExibicao: 'Alarme de Emergência', assetPath: 'sounds/som_3.mp3'),
    SomAlarme(numero: 4, nomeExibicao: 'Alerta Estridente', assetPath: 'sounds/som_4.mp3'),
    SomAlarme(numero: 5, nomeExibicao: 'Toque Urbano', assetPath: 'sounds/som_5.mp3'),
    SomAlarme(numero: 6, nomeExibicao: 'Sino de Alerta', assetPath: 'sounds/som_6.mp3'),
    SomAlarme(numero: 7, nomeExibicao: 'Buzina de Segurança', assetPath: 'sounds/som_7.mp3'),
    SomAlarme(numero: 8, nomeExibicao: 'Alarme Industrial', assetPath: 'sounds/som_8.mp3'),
    SomAlarme(numero: 9, nomeExibicao: 'Sirene Policial', assetPath: 'sounds/som_9.mp3'),
    SomAlarme(numero: 10, nomeExibicao: 'Toque Silencioso', assetPath: 'sounds/som_10.mp3'),
  ];

  final AudioPlayer _player = AudioPlayer();

  /// Player independente e efêmero, usado exclusivamente pelo botão de
  /// "testar/ouvir" em Configurações, para nunca interferir no player
  /// principal (o que poderia estar em loop de emergência).
  final AudioPlayer _playerTeste = AudioPlayer();

  bool _tocandoEmLoop = false;

  /// Token de controle usado pelo auto-stop de 4 segundos do
  /// [testarSom]. Cada chamada incrementa este contador; o callback do
  /// `Future.delayed` só executa o `stop()` se o token não tiver mudado
  /// nesse meio tempo, evitando que um teste mais novo (som diferente
  /// clicado pelo usuário dentro da janela de 4s) seja interrompido por
  /// engano pelo timer do teste anterior.
  int _tokenTeste = 0;

  /// Retorna o [SomAlarme] correspondente ao número informado, ou o som
  /// padrão caso o número seja inválido/desconhecido.
  SomAlarme _somPorNumero(int numero) {
    return sonsDisponiveis.firstWhere(
      (s) => s.numero == numero,
      orElse: () => sonsDisponiveis.first,
    );
  }

  /// Guard defensivo: verifica se o arquivo de asset do som informado
  /// existe e tem conteúdo real (mais do que 0 bytes). Os 10 arquivos
  /// `som_1.mp3` ... `som_10.mp3` foram criados inicialmente como
  /// placeholders VAZIOS (ver `assets/sounds/README.md`) — um MP3 vazio
  /// não falha ao carregar, mas também não produz nenhum áudio audível,
  /// fazendo o alarme parecer "mudo" mesmo com toda a lógica de
  /// reprodução funcionando perfeitamente. Este método permite detectar
  /// esse cenário ANTES de tentar tocar, para que o chamador possa
  /// avisar o usuário de forma clara em vez de falhar silenciosamente.
  ///
  /// EXCEÇÃO: o som de número 10 ("Toque Silencioso") é um placeholder de
  /// SILÊNCIO PROPOSITAL — não um placeholder esquecido — então ele é
  /// sempre considerado válido, independentemente do tamanho em bytes do
  /// arquivo, evitando que o aviso de "arquivo vazio" apareça para ele
  /// tanto no teste quanto no disparo real do alarme.
  Future<bool> _assetDeSomEhValido(String assetPath, {int? numeroSom}) async {
    if (numeroSom == 10) {
      return true;
    }
    try {
      final bytes = await rootBundle.load('assets/$assetPath');
      return bytes.lengthInBytes > 0;
    } catch (e) {
      debugPrint('⚠️ [AlarmeSonoroService] Falha ao validar asset "$assetPath": $e');
      return false;
    }
  }

  // ==========================================================
  // PERSISTÊNCIA (SharedPreferences)
  // ==========================================================

  /// Salva o número do som escolhido (1 a 10) em SharedPreferences.
  Future<void> salvarSomSelecionado(int numero) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKeySom, numero);
  }

  /// Recupera o número do som atualmente selecionado, ou [somPadrao]
  /// caso nunca tenha sido configurado.
  Future<int> carregarSomSelecionado() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefsKeySom) ?? somPadrao;
  }

  /// Salva a duração (em segundos) configurada para o toque do alarme.
  Future<void> salvarDuracaoSegundos(int segundos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKeyDuracao, segundos);
  }

  /// Recupera a duração (em segundos) configurada, ou
  /// [duracaoPadraoSegundos] caso nunca tenha sido configurada.
  Future<int> carregarDuracaoSegundos() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefsKeyDuracao) ?? duracaoPadraoSegundos;
  }

  // ==========================================================
  // TESTE/PREVIEW (tela de Configurações)
  // ==========================================================

  /// Toca uma única vez (sem loop) o som informado, usado pelo botão de
  /// "testar/ouvir" na tela de Configurações. Interrompe automaticamente
  /// qualquer teste anterior ainda em execução.
  ///
  /// Retorna `true` quando a reprodução foi de fato iniciada com um
  /// arquivo de áudio válido (não vazio), e `false` quando o asset está
  /// vazio/inválido (placeholder ainda não substituído, ver
  /// `assets/sounds/README.md`) ou quando qualquer outra falha ocorrer
  /// ao tentar tocar. O chamador (tela de Configurações) pode usar este
  /// retorno para avisar o usuário de forma clara, em vez de deixar o
  /// botão "testar" falhar silenciosamente.
  Future<bool> testarSom(int numero) async {
    try {
      await _playerTeste.stop();
      final som = _somPorNumero(numero);

      // Som 10 = "Toque Silencioso": silêncio proposital, não há o que
      // validar/tocar. Short-circuit total: nem verificamos os bytes do
      // asset nem chamamos o player, apenas simulamos sucesso.
      if (som.numero == 10) {
        return true;
      }

      final valido = await _assetDeSomEhValido(som.assetPath, numeroSom: som.numero);
      if (!valido) {
        debugPrint(
            '⚠️ [AlarmeSonoroService] Som ${som.numero} ("${som.nomeExibicao}") está vazio/inválido — placeholder ainda não substituído.');
        return false;
      }

      await _playerTeste.setReleaseMode(ReleaseMode.stop);
      await _playerTeste.play(AssetSource(som.assetPath));

      // Trava de tempo: interrompe automaticamente a reprodução de
      // teste após exatamente 4 segundos, mesmo que o áudio real seja
      // mais longo (ou, em builds de produção, evitando que o teste
      // fique tocando indefinidamente). Usa um token de controle para
      // não interromper um teste mais novo, caso o usuário clique em
      // testar outro som dentro dessa janela de 4s.
      final meuToken = ++_tokenTeste;
      Future.delayed(const Duration(seconds: 4), () async {
        if (meuToken == _tokenTeste) {
          await _playerTeste.stop();
        }
      });

      return true;
    } catch (e) {
      debugPrint('⚠️ [AlarmeSonoroService] Falha ao testar som $numero: $e');
      return false;
    }
  }

  /// Interrompe a reprodução de teste/preview, se estiver tocando.
  Future<void> pararTeste() async {
    try {
      await _playerTeste.stop();
    } catch (_) {}
  }

  // ==========================================================
  // DISPARO REAL (fim do cronômetro / SegurancaTab)
  // ==========================================================

  /// Dispara o alerta sonoro em LOOP contínuo, usando o som e a duração
  /// atualmente configurados pelo usuário (persistidos via
  /// SharedPreferences). Chamado pela `SegurancaTab` no exato momento em
  /// que o cronômetro principal chega a zero e a tela de bloqueio de
  /// PIN é exibida.
  ///
  /// Após [duracaoSegundos] o som para automaticamente sozinho (mesmo
  /// que o usuário nunca digite o PIN), evitando que o alarme toque
  /// indefinidamente. Se o PIN correto for digitado antes disso, o
  /// chamador deve invocar [pararAlarme] imediatamente.
  Future<void> dispararAlarme() async {
    if (_tocandoEmLoop) return; // já está tocando, evita sobreposição
    _tocandoEmLoop = true;

    try {
      final numeroSom = await carregarSomSelecionado();
      final duracaoSegundos = await carregarDuracaoSegundos();
      final som = _somPorNumero(numeroSom);

      // Som 10 = "Toque Silencioso": silêncio proposital. Short-circuit
      // total: nem carregamos nem tocamos o asset, apenas simulamos o
      // fluxo de "alarme ativo" com o mesmo auto-stop de segurança dos
      // demais sons.
      if (som.numero == 10) {
        debugPrint(
            '🔇 [AlarmeSonoroService] Som 10 ("Toque Silencioso") selecionado — pulando carregamento/reprodução de áudio (silêncio proposital).');
        Future.delayed(Duration(seconds: duracaoSegundos), () {
          if (_tocandoEmLoop) {
            pararAlarme();
          }
        });
        return;
      }

      final valido = await _assetDeSomEhValido(som.assetPath, numeroSom: som.numero);
      if (!valido) {
        debugPrint(
            '⚠️ [AlarmeSonoroService] Som ${som.numero} ("${som.nomeExibicao}") está vazio/inválido — o alarme NÃO produzirá áudio até que o placeholder seja substituído em assets/sounds/.');
        // Mesmo sem áudio real, mantemos o fluxo de "alarme ativo" e o
        // auto-stop de segurança abaixo, para que o restante da lógica
        // de emergência (tela de PIN etc.) continue funcionando
        // normalmente mesmo sem som.
      } else {
        await _player.setReleaseMode(ReleaseMode.loop);
        await _player.play(AssetSource(som.assetPath));
      }

      debugPrint(
          '🔊 [AlarmeSonoroService] Alarme sonoro disparado (${som.nomeExibicao}, loop por ${duracaoSegundos}s).');

      // Auto-stop de segurança: garante que o som nunca toque além do
      // tempo configurado, mesmo que o PIN nunca seja digitado.
      Future.delayed(Duration(seconds: duracaoSegundos), () {
        if (_tocandoEmLoop) {
          pararAlarme();
        }
      });
    } catch (e) {
      debugPrint('⚠️ [AlarmeSonoroService] Falha ao disparar alarme sonoro: $e');
      _tocandoEmLoop = false;
    }
  }

  /// Interrompe IMEDIATAMENTE o alarme sonoro em loop. Deve ser chamado
  /// assim que o usuário digitar o PIN correto, ou quando o disparo de
  /// emergência for concluído (o alerta já cumpriu seu propósito de
  /// notificar quem estiver por perto).
  Future<void> pararAlarme() async {
    if (!_tocandoEmLoop) return;
    _tocandoEmLoop = false;
    try {
      await _player.stop();
      debugPrint('🔇 [AlarmeSonoroService] Alarme sonoro interrompido.');
    } catch (e) {
      debugPrint('⚠️ [AlarmeSonoroService] Falha ao parar alarme sonoro: $e');
    }
  }

  bool get estaTocando => _tocandoEmLoop;
}
