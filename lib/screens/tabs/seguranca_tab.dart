import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'dart:async';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';
import '../../services/location_service.dart';
import '../../services/emergency_alert_service.dart';
import '../../services/alarme_service.dart';
import '../../services/api_service.dart';
import '../../widgets/pin_dialog.dart';


class SegurancaTab extends StatefulWidget {
  const SegurancaTab({super.key});

  @override
  State<SegurancaTab> createState() => _SegurancaTabState();
}

class _SegurancaTabState extends State<SegurancaTab> {
  final DatabaseHelper _db = DatabaseHelper();
  final EmergencyAlertService _emergencyAlertService = EmergencyAlertService();
  final AlarmeService _alarmeService = AlarmeService();

  // Controlador para o campo de Anotações/Dica de Contexto
  final TextEditingController _contextoController = TextEditingController();

  // Estilos de texto reutilizados na tela, centralizados para evitar
  // duplicação e facilitar futuras alterações de tema.
  static const TextStyle _estiloTituloSecao = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: Colors.black87,
  );
  static const TextStyle _estiloLabelPicker = TextStyle(
    color: Colors.grey,
    fontWeight: FontWeight.w500,
  );

  // Tolerância fixa (em segundos) após o cronômetro chegar a zero, antes
  // do disparo automático de emergência. Usada tanto para a contagem
  // visual em memória (com o app aberto) quanto somada à duração do
  // alarme NATIVO agendado via AlarmeService (que continua rodando
  // mesmo se o app for fechado).
  static const int _segundosToleranciaPadrao = 60;

  // Variáveis do Banco de Dados
  String? _pinRealConfirmado;

  // Variáveis de controle do Timer Padrão
  int _horaSelecionada = 0;
  int _minutoSelecionada = 5;

  // Variáveis de controle do Timer Ativo
  Timer? _timer;
  bool _isTimerAtivo = false;
  int _segundosRestantes = 0;

  // Estado de Bloqueio por PIN
  Timer? _timerToleranciaBloqueio;

  int _segundosToleranciaBloqueio = _segundosToleranciaPadrao;

  // ==========================================================
  // GUARDA CONTRA CONDIÇÃO DE CORRIDA (race condition) DE TIMERS
  // ==========================================================
  // Flag de controle centralizada: impede que _ativarBloqueioDeSeguranca()
  // seja executada mais de uma vez simultaneamente (ex: o _timer principal
  // chegando a zero E um toque manual do usuário em _alternarTimer quase
  // ao mesmo tempo), o que anteriormente podia criar DOIS
  // _timerToleranciaBloqueio concorrentes — o mais antigo ficava "órfão"
  // rodando em paralelo sem que sua referência fosse cancelada antes de
  // ser sobrescrita pelo novo Timer, causando decrementos/disparos de SOS
  // mais rápidos e inesperados que o esperado (o efeito visual relatado:
  // o botão fica laranja por ~1s e o SOS já dispara).
  bool _bloqueioEmAndamento = false;

  // Serviço singleton responsável pelo ciclo de vida proativo do GPS:
  // solicitação de permissão, warm-up ao iniciar o cronômetro e loop de
  // atualização a cada 2 minutos enquanto o check-in estiver ativo.
  final LocationService _locationService = LocationService();

  // ==========================================================
  // STATUS DE CONECTIVIDADE COM O BACKEND (API)
  // ==========================================================
  // Indicador visual de conectividade com o servidor FastAPI
  // (security_backend), verificado periodicamente via
  // ApiService.enviarStatus(). null = ainda verificando (primeira
  // checagem em andamento), true = Online, false = Offline.
  bool? _apiOnline;
  Timer? _timerStatusApi;
  static const Duration _intervaloChecagemApi = Duration(seconds: 15);

  // Guarda simples para evitar que múltiplas chamadas de
  // _verificarStatusApi() rodem sobrepostas caso uma chamada anterior
  // ainda esteja pendente (ex: rede lenta/instável) quando o próximo
  // tick do Timer.periodic disparar — previne o acúmulo de Futures
  // concorrentes que poderiam retornar fora de ordem e "piscar" o
  // indicador de status de forma inconsistente.
  bool _verificacaoStatusEmAndamento = false;

  @override
  void initState() {
    super.initState();
    _carregarConfiguracoesSeguranca();

    // Regra de negócio 1 (Permissão ao Iniciar): assim que a tela de
    // Segurança é aberta, o app já verifica/solicita a permissão de
    // localização do Android, garantindo que o GPS esteja liberado antes
    // mesmo de o usuário ativar o cronômetro de check-in.
    _locationService.garantirPermissaoDeLocalizacao();

    // Dispara a primeira checagem de conectividade imediatamente e
    // agenda checagens periódicas enquanto a tela estiver aberta,
    // mantendo o indicador visual (Online/Offline) sempre atualizado.
    _verificarStatusApi();
    _timerStatusApi = Timer.periodic(_intervaloChecagemApi, (_) {
      _verificarStatusApi();
    });
  }

  @override
  void dispose() {
    _contextoController.dispose();
    _cancelarTodosOsTimers();
    // Interrompe o loop de atualização de localização (se ainda ativo) ao
    // destruir a tela, evitando Timers órfãos em segundo plano.
    _locationService.pararCicloDeAtualizacao();
    super.dispose();
  }

  // ==========================================================
  // GERENCIADOR CENTRALIZADO DO CICLO DE VIDA DOS TIMERS
  // ==========================================================
  // Ponto ÚNICO de cancelamento de TODOS os Timers desta tela
  // (cronômetro principal, tolerância de bloqueio e status da API).
  // Chamado sistematicamente ANTES de qualquer novo Timer ser criado em
  // qualquer fluxo (iniciar cronômetro, ativar bloqueio, dispose), e
  // também diretamente pelo dispose(). Isso elimina de raiz qualquer
  // possibilidade de dois Timers do mesmo tipo coexistirem
  // simultaneamente — a causa raiz da condição de corrida relatada (o
  // cronômetro "piscando" laranja por ~1s e disparando o SOS
  // prematuramente).
  void _cancelarTodosOsTimers() {
    _timer?.cancel();
    _timer = null;
    _timerToleranciaBloqueio?.cancel();
    _timerToleranciaBloqueio = null;
    _timerStatusApi?.cancel();
    _timerStatusApi = null;
  }

  /// Cancela exclusivamente o cronômetro principal de check-in,
  /// garantindo que nenhuma referência antiga fique rodando "invisível"
  /// antes de um novo ser agendado.
  void _cancelarTimerPrincipal() {
    _timer?.cancel();
    _timer = null;
  }

  /// Cancela exclusivamente o Timer de tolerância de bloqueio (60s),
  /// sempre chamado ANTES de criar um novo — nunca permitindo que dois
  /// Timers de tolerância concorram entre si.
  void _cancelarTimerToleranciaBloqueio() {
    _timerToleranciaBloqueio?.cancel();
    _timerToleranciaBloqueio = null;
  }

  /// Chama ApiService.enviarStatus (heartbeat para /api/status) e
  /// atualiza o indicador visual de conectividade (Online/Offline).
  ///
  /// Protegido em múltiplas camadas para NUNCA travar a UI ou o app,
  /// mesmo diante de instabilidade de rede:
  /// - [_verificacaoStatusEmAndamento] evita chamadas sobrepostas caso
  ///   uma requisição anterior ainda esteja pendente.
  /// - `.timeout(...)` garante um limite máximo de espera MESMO que o
  ///   Dio interno não respeite seu próprio timeout configurado (ex: em
  ///   cenários de conexão "pendurada"/half-open), evitando que este
  ///   Future fique pendente indefinidamente e trave o próximo ciclo do
  ///   Timer.periodic.
  /// - O try/catch mais externo garante que QUALQUER exceção (timeout,
  ///   erro de socket, DNS, etc.) resulte simplesmente em "Offline",
  ///   nunca propagando uma exceção não tratada para o Timer.
  Future<void> _verificarStatusApi() async {
    if (_verificacaoStatusEmAndamento) return;
    _verificacaoStatusEmAndamento = true;

    bool online = false;
    try {
      const double bateriaSimulada = 100;
      online = await ApiService()
          .enviarStatus(bateriaSimulada, '1.0.0')
          .timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          debugPrint(
              '⚠️ [SegurancaTab] Timeout ao verificar status da API (>8s sem resposta).');
          return false;
        },
      );
    } catch (e) {
      debugPrint('⚠️ [SegurancaTab] Falha inesperada ao verificar status da API: $e');
      online = false;
    }

    _verificacaoStatusEmAndamento = false;
    if (!mounted) return;
    setState(() {
      _apiOnline = online;
    });
  }


  Future<void> _carregarConfiguracoesSeguranca() async {
    try {
      final config = await _db.getUserConfig();
      if (config != null && mounted) {
        setState(() {
          _pinRealConfirmado = config['pin_real'] as String?;
        });
        // Verifica se o prazo de segurança de 24h já expirou, e caso
        // afirmativo, efetiva a troca de senha pendente automaticamente.
        await _processarSenhaPendenteSeExpirada();
      }
    } catch (_) {}
  }

  /// Verifica se existe uma senha pendente e se o prazo de segurança de
  /// 24 horas desde a solicitação já se passou. Se sim, promove a senha
  /// pendente para senha principal (pin_real) e limpa os campos temporários.
  /// Caso contrário, mantém a senha antiga como válida para autenticação.
  ///
  /// A verificação/efetivação em si é centralizada no DatabaseHelper
  /// (`processarSenhaPendenteSeExpirada`), garantindo que o mesmo
  /// comportamento ocorra independentemente de qual tela do app o usuário
  /// abrir primeiro (Segurança, Configurações ou cold start em main.dart).
  Future<void> _processarSenhaPendenteSeExpirada() async {
    final efetivado = await _db.processarSenhaPendenteSeExpirada();
    if (efetivado && mounted) {
      final config = await _db.getUserConfig();
      if (config != null) {
        setState(() {
          _pinRealConfirmado = config['pin_real'] as String?;
        });
      }
    }
    // Se ainda não passaram 24h, nada é feito: a senha antiga
    // (_pinRealConfirmado) continua sendo a única válida para autenticação.
  }

  /// Ação disparada ao tocar no botão circular de check-in.
  ///
  /// Regra de segurança crítica: uma vez que o timer esteja ativo (em
  /// contagem regressiva), ele NUNCA pode ser cancelado diretamente por um
  /// simples toque. Em vez disso, o toque interrompe a contagem regressiva
  /// e abre a MESMA tela de bloqueio com teclado de PIN (com os mesmos 60s
  /// de tolerância) usada quando o timer expira naturalmente. Isso garante
  /// que, mesmo para desarmar voluntariamente, o usuário precise confirmar
  /// com o PIN. O ALARME NATIVO agendado via AlarmeService só é cancelado
  /// quando o PIN correto for digitado com sucesso — abrir a tela de
  /// bloqueio, por si só, NUNCA cancela o alarme nativo.
  void _alternarTimer() {
    if (_isTimerAtivo) {
      _ativarBloqueioDeSeguranca();
    } else {
      _iniciarTimer();
    }
  }


  void _iniciarTimer() {
    _carregarConfiguracoesSeguranca();
    int totalSegundos = (_horaSelecionada * 3600) + (_minutoSelecionada * 60);

    if (totalSegundos <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, selecione um tempo maior que zero!')),
      );
      return;
    }

    // Cancela sistematicamente QUALQUER Timer principal ou de tolerância
    // que ainda possa estar rodando de um ciclo anterior, antes de
    // iniciar um novo — elimina a possibilidade de dois cronômetros
    // concorrentes coexistirem.
    _cancelarTimerPrincipal();
    _cancelarTimerToleranciaBloqueio();
    _bloqueioEmAndamento = false;

    // Novo ciclo de check-in: reseta a flag de disparo único, garantindo
    // que o próximo esgotamento de tolerância possa disparar novamente
    // (uma única vez por ciclo).
    _disparoJaExecutadoNesteCiclo = false;

    setState(() {
      _segundosRestantes = totalSegundos;
      _isTimerAtivo = true;
    });



    // Registra no histórico ('seguranca') a ativação do cronômetro de
    // check-in, tornando a ação 100% transparente e auditável.
    _db.inserirEventoHistorico(
      titulo: 'Cronômetro ativado',
      descricao: 'Check-in de segurança iniciado com duração de '
          '${_horaSelecionada.toString().padLeft(2, '0')}h'
          '${_minutoSelecionada.toString().padLeft(2, '0')}min.',
      categoria: 'seguranca',
    );

    // Regra de negócio 2 e 3 (Captura Proativa + Loop de Atualização):
    // no exato momento em que o cronômetro é iniciado, dispara IMEDIATAMENTE
    // a busca de localização de alta precisão em segundo plano (warm-up) e
    // agenda a atualização automática a cada 2 minutos enquanto o
    // cronômetro permanecer ativo. A chamada não é aguardada (fire-and-
    // -forget) para não travar a UI do botão de check-in.
    _locationService.iniciarCicloDeAtualizacao();

    // Agenda o alarme NATIVO (android_alarm_manager_plus), que garante o
    // disparo de emergência mesmo que o app seja fechado ou fique em
    // segundo plano. A duração agendada replica exatamente o mesmo
    // comportamento em memória: tempo escolhido pelo usuário + 60s de
    // tolerância da tela de bloqueio.
    final duracaoTotalComTolerancia = Duration(
      seconds: totalSegundos + _segundosToleranciaPadrao,
    );
    _alarmeService.agendarAlarmeEmergencia(
      duracaoAteDisparo: duracaoTotalComTolerancia,
      contexto: _contextoController.text.trim(),
    );

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      // Guarda defensiva extra: se por qualquer motivo esta referência de
      // Timer não for mais a atual (ex: foi substituída por um cancel +
      // novo Timer entre um tick e outro), interrompe imediatamente esta
      // instância "fantasma" em vez de continuar decrementando o estado.
      if (!identical(timer, _timer)) {
        timer.cancel();
        return;
      }

      if (_segundosRestantes > 0) {
        setState(() {
          _segundosRestantes--;
        });
      } else {
        _cancelarTimerPrincipal();
        _ativarBloqueioDeSeguranca();
      }
    });
  }

  void _pararTimer() {
    _cancelarTimerPrincipal();
    _cancelarTimerToleranciaBloqueio();
    _bloqueioEmAndamento = false;
    // O cronômetro foi parado/desarmado (por qualquer motivo): interrompe
    // o loop de atualização de localização a cada 2 minutos, já que ele
    // só deve rodar enquanto o check-in estiver ativo.
    _locationService.pararCicloDeAtualizacao();
    if (!mounted) return;
    setState(() {
      _isTimerAtivo = false;
      _segundosRestantes = 0;
    });

    // NOTA: o fechamento do diálogo de PIN (Navigator.pop) é tratado
    // explicitamente em cada ponto de chamada específico (dentro do
    // próprio PinDialogContent ao confirmar o PIN, e em
    // _ativarBloqueioDeSeguranca quando a tolerância esgota) — NUNCA
    // aqui, pois _pararTimer() também é chamado pelo fluxo de disparo
    // automático de emergência, onde um pop indevido poderia fechar a
    // rota errada ou falhar silenciosamente.
  }



  /// Ativa a etapa de tolerância (60s) antes do disparo automático de
  /// emergência. IMPORTANTE (correção do erro de design original): esta
  /// etapa NÃO substitui mais a tela inteira por uma TelaBloqueioPin — a
  /// UI normal (SegurancaTab, HomeScreen, BottomNavigationBar) permanece
  /// totalmente visível e navegável. Um AlertDialog leve com o teclado
  /// de PIN é aberto POR CIMA da tela atual, evitando os conflitos de
  /// ciclo de vida relatados. Se o tempo esgotar SEM o PIN correto, o
  /// disparo de emergência é executado exatamente UMA vez (ver
  /// [_dispararUmaVezSeNecessario]), sem loop e sem travar a interface.
  ///
  /// CORREÇÃO DE RACE CONDITION: esta função agora é protegida pela flag
  /// [_bloqueioEmAndamento], impedindo que seja executada mais de uma vez
  /// simultaneamente — cenário que antes podia ocorrer quando o [_timer]
  /// principal chegava a zero e, quase ao mesmo tempo, o usuário tocava
  /// manualmente no botão (via [_alternarTimer]). Antes dessa proteção,
  /// isso podia criar DOIS [_timerToleranciaBloqueio] concorrentes: o
  /// mais antigo nunca era cancelado antes do novo sobrescrever sua
  /// referência, continuando a rodar "invisível" em paralelo e
  /// disparando o SOS de forma prematura/inesperada (o efeito relatado:
  /// o botão fica laranja por ~1s e o alerta já dispara).
  void _ativarBloqueioDeSeguranca() {
    if (_bloqueioEmAndamento) {
      // Já existe um ciclo de tolerância em andamento: ignora esta nova
      // chamada por completo, em vez de criar um segundo Timer
      // concorrente.
      return;
    }
    _bloqueioEmAndamento = true;

    // Cancela sistematicamente qualquer Timer de tolerância remanescente
    // antes de criar um novo (defesa em profundidade, mesmo com a flag
    // acima já impedindo reentrância).
    _cancelarTimerToleranciaBloqueio();

    if (!mounted) return;
    setState(() {
      _segundosToleranciaBloqueio = _segundosToleranciaPadrao;
    });


    // Exibe o diálogo de PIN por cima da tela atual. Não é aguardado
    // (fire-and-forget) para não bloquear a contagem de tolerância, que
    // continua rodando normalmente em paralelo via Timer.
    if (mounted) {
      exibirDialogoPin(
        context: context,
        pinEsperado: _pinRealConfirmado,
        segundosTolerancia: _segundosToleranciaBloqueio,
        aoConfirmarPinCorreto: _aoConfirmarPinCorreto,
        aoErrarPinDuasVezes: _dispararSosDeCoacao,
      );
    }


    _timerToleranciaBloqueio = Timer.periodic(const Duration(seconds: 1), (t) {
      // Guarda defensiva extra: garante que apenas o Timer de tolerância
      // "atual" continue executando sua lógica, mesmo que uma referência
      // antiga por algum motivo ainda não tenha sido totalmente
      // finalizada pelo scheduler do Dart.
      if (!identical(t, _timerToleranciaBloqueio)) {
        t.cancel();
        return;
      }

      if (_segundosToleranciaBloqueio > 0) {
        if (!mounted) return;
        setState(() {
          _segundosToleranciaBloqueio--;
        });
      } else {
        _cancelarTimerToleranciaBloqueio();
        // BLINDAGEM DE SEGURANÇA: o diálogo de PIN NUNCA é fechado
        // automaticamente pela expiração da tolerância — ele permanece
        // aberto e travado na tela (teclado de PIN idêntico, mesma
        // mensagem), exigindo o PIN CORRETO para ser fechado. Isso
        // impede que um agressor, ao ver o diálogo desaparecer sozinho,
        // conclua que o alerta foi disparado e destrua o aparelho antes
        // que a vítima consiga confirmar sua segurança. O disparo de
        // emergência ocorre normalmente em paralelo, SEM fechar o
        // diálogo (ver [_dispararUmaVezSeNecessario] /
        // [_aoConfirmarPinCorreto], o ÚNICO ponto que fecha o diálogo).
        _dispararUmaVezSeNecessario();
      }
    });
  }



  /// Chamado pelo [PinDialogContent] quando o PIN correto é digitado.
  /// Cancela o alarme NATIVO (só agora, com o PIN confirmado), interrompe
  /// os timers locais e registra o desarme no histórico. Envolvido em
  /// try/catch para NUNCA travar o diálogo/UI mesmo em caso de falha.
  Future<void> _aoConfirmarPinCorreto() async {
    try {
      _cancelarTimerToleranciaBloqueio();
      await _alarmeService.cancelarAlarme();
      await _db.limparAguardandoConfirmacaoPin();

      _pararTimer();
      if (mounted) {
        _db.inserirEventoHistorico(
          titulo: 'Check-in desarmado com sucesso',
          descricao: 'O cronômetro de segurança foi interrompido/desarmado '
              'pelo usuário com o PIN correto.',
          categoria: 'seguranca',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Check-in desarmado com sucesso!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao confirmar PIN/desarmar check-in: $e');
    }
  }

  // Flag simples para garantir que, mesmo diante de eventuais chamadas
  // concorrentes (ex.: Timer da tolerância + fechamento do diálogo quase
  // simultâneos), o disparo de emergência ocorra NO MÁXIMO uma única vez
  // por ciclo de tolerância — nunca em loop.
  bool _disparoJaExecutadoNesteCiclo = false;

  /// Garante (via flag [_disparoJaExecutadoNesteCiclo]) que o disparo de
  /// emergência seja executado apenas UMA vez quando a tolerância
  /// esgotar, e delega para [_executarDisparoDeEmergencia] o try/catch
  /// completo em torno do EmergencyAlertService.
  Future<void> _dispararUmaVezSeNecessario() async {
    if (_disparoJaExecutadoNesteCiclo) return;
    _disparoJaExecutadoNesteCiclo = true;
    await _executarDisparoDeEmergencia();
  }

  /// Executa o disparo de emergência quando a tolerância expira com o
  /// app ainda aberto (fluxo em memória). Reaproveita o
  /// [EmergencyAlertService], compartilhado com o callback headless do
  /// [AlarmeService]. Protegido por try/catch para que qualquer falha
  /// (GPS, SMS, banco) jamais trave a interface do usuário ou dispare
  /// novamente em loop — o [EmergencyAlertService] já é 100% silencioso
  /// e não-repetitivo internamente.
  Future<void> _executarDisparoDeEmergencia() async {
    _cancelarTimerToleranciaBloqueio();
    try {
      await _emergencyAlertService.dispararAlertaDeEmergencia(
        contexto: _contextoController.text.trim(),
        posicaoEmMemoria: _locationService.ultimaPosicao,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao executar disparo de emergência: $e');
    }
    _pararTimer();
  }

  // ==========================================================
  // PIN DE COAÇÃO (gatilho discreto de emergência)
  // ==========================================================

  /// Callback silencioso passado ao [PinDialogContent] (ver
  /// [_ativarBloqueioDeSeguranca]), acionado automaticamente quando o
  /// usuário digita o PIN INCORRETO 2 vezes consecutivas. Dispara o
  /// MESMO fluxo de emergência real usado pelo SOS manual/automático
  /// (SMS nativo + alerta ao backend), mas de forma 100% SILENCIOSA:
  /// nenhum SnackBar, nenhuma alteração visual no diálogo de PIN, nada
  /// que possa denunciar o disparo a quem estiver observando a tela
  /// (ex: um agressor coagindo o usuário a digitar o PIN).
  ///
  /// Protegido por try/catch para nunca propagar exceção de volta ao
  /// diálogo de PIN, mantendo seu comportamento visual inalterado
  /// independentemente do resultado deste disparo.
  Future<void> _dispararSosDeCoacao() async {
    debugPrint('🚨 [PIN DE COAÇÃO] 2 PINs incorretos consecutivos detectados. '
        'Disparando SOS silencioso.');
    try {
      await _emergencyAlertService.dispararAlertaDeEmergencia(
        contexto: _contextoController.text.trim(),
        posicaoEmMemoria: _locationService.ultimaPosicao,
      );
    } catch (e) {
      debugPrint('⚠️ [PIN DE COAÇÃO] Falha ao disparar SOS silencioso: $e');
    }
  }

  // ==========================================================
  // BOTÃO DE SOS/PÂNICO MANUAL
  // ==========================================================


  /// Exibe um diálogo de confirmação simples ("Confirmar SOS?") antes de
  /// disparar o alerta de emergência manualmente. Diferente do gatilho
  /// físico (Volume+ segurado por 3s, que dispara IMEDIATAMENTE sem
  /// diálogo, pois pode ocorrer com a tela apagada), o botão SOS dentro
  /// do app SEMPRE pede essa confirmação, já que o usuário está olhando
  /// a tela e pode ter tocado por engano. O diálogo permanece aberto até
  /// o usuário decidir (sem timeout automático).
  Future<void> _confirmarEDispararSosManual() async {
    final bool? confirmou = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Confirmar SOS?'),
          content: const Text(
            'Isso enviará imediatamente um SMS de emergência e um alerta '
            'para os seus contatos cadastrados, com sua localização atual. '
            'Deseja continuar?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Confirmar SOS', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (confirmou != true || !mounted) return;

    try {
      await _emergencyAlertService.dispararAlertaDeEmergencia(
        contexto: _contextoController.text.trim(),
        posicaoEmMemoria: _locationService.ultimaPosicao,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🚨 SOS disparado! Contatos de emergência notificados.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar SOS manual: $e');
    }
  }



  String _formatarTempo(int totalSegundos) {
    int horas = totalSegundos ~/ 3600;
    int minutos = (totalSegundos % 3600) ~/ 60;
    int segundos = totalSegundos % 60;
    return "${horas.toString().padLeft(2, '0')}:${minutos.toString().padLeft(2, '0')}:${segundos.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    // Correção do erro de design original: a tela de bloqueio de PIN por
    // inatividade que substituía toda a rota foi removida. A UI normal
    // (com o cronômetro em contagem regressiva ou já em tolerância) é
    // SEMPRE exibida — o diálogo de PIN, quando necessário, é aberto por
    // cima dela via [exibirDialogoPin] (ver [_ativarBloqueioDeSeguranca]),
    // nunca bloqueando a navegação para as demais abas (Família,
    // Histórico) nem a HomeScreen.
    return _buildTelaPrincipal();
  }


  /// Tela de funcionamento normal com plano de fundo dinâmico, sincronizado
  /// em tempo real com a escolha feita em Configurações.
  Widget _buildTelaPrincipal() {
    return Scaffold(
      backgroundColor: Colors.transparent, // Permite que o fundo do Container apareça
      body: ValueListenableBuilder<String>(
        valueListenable: WallpaperService.wallpaperNotifier,
        builder: (context, fundoAtivo, _) {
          return Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              image: DecorationImage(
                image: AssetImage(fundoAtivo),
                fit: BoxFit.cover,
              ),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildIndicadorStatusApi(),
                  const SizedBox(height: 12),
                  _buildCampoContexto(),
                  const SizedBox(height: 24),
                  const Text(
                    'Daqui quanto tempo vou chegar',
                    textAlign: TextAlign.center,
                    softWrap: true,
                    overflow: TextOverflow.clip,
                    style: _estiloTituloSecao,
                  ),
                  const SizedBox(height: 16),
                  _buildSeletoresDeTempo(),
                  const SizedBox(height: 32),
                  _buildBotaoCheckIn(),
                  const SizedBox(height: 24),
                  _buildBotaoSos(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Indicador visual compacto de conectividade com o backend FastAPI
  /// (security_backend): um pequeno "chip" com ícone e texto
  /// "Online"/"Offline"/"Verificando...", com a cor refletindo o status
  /// (verde = conectado, vermelho = sem conexão, cinza = checando).
  Widget _buildIndicadorStatusApi() {
    late final Color cor;
    late final IconData icone;
    late final String texto;

    if (_apiOnline == null) {
      cor = Colors.grey;
      icone = Icons.sync;
      texto = 'Verificando servidor...';
    } else if (_apiOnline == true) {
      cor = Colors.green;
      icone = Icons.cloud_done;
      texto = 'Servidor Online';
    } else {
      cor = Colors.red;
      icone = Icons.cloud_off;
      texto = 'Servidor Offline';
    }

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cor.withOpacity(0.4)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icone, color: cor, size: 14),
            const SizedBox(width: 6),
            Text(
              texto,
              style: TextStyle(color: cor, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  /// Card com o campo de texto para anotações/dica de contexto.
  Widget _buildCampoContexto() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
        child: Row(
          children: [
            const Icon(Icons.lightbulb_outline, color: Colors.blue, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _contextoController,
                enabled: !_isTimerAtivo,
                decoration: const InputDecoration(
                  labelText: 'Dica de Contexto',
                  hintText: 'Ex: Placa do carro / Ônibus / Localização',
                  hintStyle: TextStyle(color: Colors.grey, fontSize: 13),
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Seletores (pickers estilo iOS) de horas e minutos para definir a
  /// duração do timer de check-in.
  Widget _buildSeletoresDeTempo() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Column(
          children: [
            SizedBox(
              height: 130,
              width: 70,
              child: CupertinoPicker(
                itemExtent: 38,
                scrollController: FixedExtentScrollController(initialItem: _horaSelecionada),
                onSelectedItemChanged: (index) => setState(() => _horaSelecionada = index),
                children: List.generate(24, (index) => Center(child: Text(index.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)))),
              ),
            ),
            const Text(
              'Horas',
              softWrap: true,
              overflow: TextOverflow.clip,
              style: _estiloLabelPicker,
            ),
          ],
        ),
        const SizedBox(width: 40),
        Column(
          children: [
            SizedBox(
              height: 130,
              width: 70,
              child: CupertinoPicker(
                itemExtent: 38,
                scrollController: FixedExtentScrollController(initialItem: _minutoSelecionada),
                onSelectedItemChanged: (index) => setState(() => _minutoSelecionada = index),
                children: List.generate(60, (index) => Center(child: Text(index.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)))),
              ),
            ),
            const Text(
              'Minutos',
              softWrap: true,
              overflow: TextOverflow.clip,
              style: _estiloLabelPicker,
            ),
          ],
        ),
      ],
    );
  }

  /// Botão circular central que inicia/desarma o timer de check-in.
  Widget _buildBotaoCheckIn() {
    return GestureDetector(
      onTap: _alternarTimer,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isTimerAtivo ? const Color(0xFFE67E22) : const Color(0xFF4C7040),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_isTimerAtivo ? Icons.timer : Icons.check_circle_outline, color: Colors.white, size: 36),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _isTimerAtivo ? _formatarTempo(_segundosRestantes) : 'Fazer\nCheck-in',
                  textAlign: TextAlign.center,
                  softWrap: true,
                  overflow: TextOverflow.clip,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: _isTimerAtivo ? 20 : 16, letterSpacing: _isTimerAtivo ? 1.2 : 0),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _isTimerAtivo ? 'Toque: desarmar' : 'Toque para iniciar',
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Botão de SOS/Pânico manual: dispara o alerta de emergência
  /// imediatamente (após confirmação simples via diálogo), reutilizando
  /// o mesmo [EmergencyAlertService.dispararAlertaDeEmergencia] usado
  /// pelo fluxo automático do cronômetro. Complementa (não substitui) o
  /// gatilho físico via botão de Volume+ segurado por 3s, que dispara
  /// sem diálogo (ver VolumeSosService/main.dart).
  Widget _buildBotaoSos() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _confirmarEDispararSosManual,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.red,
          side: const BorderSide(color: Colors.red, width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        icon: const Icon(Icons.sos),
        label: const Text(
          'SOS - Botão de Pânico',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
