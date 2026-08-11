import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import 'dart:async';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';
import '../../services/location_service.dart';
import '../../services/emergency_alert_service.dart';
import '../../services/firebase_sync_service.dart';
import '../../services/alarme_service.dart';
import '../../services/api_service.dart';
import '../../services/background_location_heartbeat_service.dart';
import '../../services/captura_dissuasao_service.dart';
import '../../services/sos_disparo_service.dart';
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

  // Variáveis do Banco de Dados
  String? _pinRealConfirmado;

  // Variáveis de controle do Timer Padrão
  int _horaSelecionada = 0;
  int _minutoSelecionada = 5;

  // Variáveis de controle do Timer Ativo
  Timer? _timer;
  bool _isTimerAtivo = false;
  int _segundosRestantes = 0;

  // ==========================================================
  // CONTROLE DO DIÁLOGO DE PIN DE DESARME
  // ==========================================================
  // Regra de negócio reespecificada em 2026-08-09: o toque no botão
  // laranja NÃO interrompe mais o cronômetro principal — ele continua
  // rodando normalmente em segundo plano por trás do diálogo de PIN
  // (ver [_abrirDialogoDesarme]). Esta flag apenas evita que o mesmo
  // diálogo seja aberto duas vezes simultaneamente (o modal já bloqueia
  // toques na tela por baixo dele, mas esta guarda extra cobre qualquer
  // chamada programática repetida).
  bool _dialogoPinAberto = false;

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
  // Ponto ÚNICO de cancelamento de TODOS os Timers desta tela (cronômetro
  // principal e status da API). Chamado sistematicamente ANTES de
  // qualquer novo Timer ser criado (iniciar cronômetro, dispose), e
  // também diretamente pelo dispose(). Isso elimina de raiz qualquer
  // possibilidade de dois Timers do mesmo tipo coexistirem
  // simultaneamente.
  void _cancelarTodosOsTimers() {
    _timer?.cancel();
    _timer = null;
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
  /// Regra de segurança crítica (reespecificada em 2026-08-09): uma vez
  /// que o timer esteja ativo (botão laranja, "Toque: desarmar"), o
  /// toque NUNCA cancela o cronômetro diretamente — em vez disso, abre
  /// IMEDIATAMENTE o teclado numérico de PIN (ver [_abrirDialogoDesarme]).
  /// O cronômetro principal CONTINUA rodando normalmente em segundo
  /// plano por trás do diálogo: só o PIN correto o cancela, ou o próprio
  /// tempo se esgotando dispara o alerta. O ALARME NATIVO agendado via
  /// AlarmeService só é cancelado quando o PIN correto for digitado com
  /// sucesso — abrir o diálogo, por si só, NUNCA cancela o alarme nativo.
  void _alternarTimer() {
    if (_isTimerAtivo) {
      _abrirDialogoDesarme();
    } else {
      _iniciarTimer();
    }
  }

  /// Abre o diálogo de PIN para tentativa de desarme (toque no botão
  /// laranja). Exige o PIN correto ou 3 tentativas erradas consecutivas
  /// para se resolver (ver [_aoConfirmarPinCorreto]/
  /// [_aoAtingirTerceiraSenhaErrada]) — NÃO interrompe o cronômetro
  /// principal, que continua contando em segundo plano por trás do
  /// diálogo. Protegido por [_dialogoPinAberto] contra abertura em
  /// duplicidade.
  void _abrirDialogoDesarme() {
    if (_dialogoPinAberto || !mounted) return;
    _dialogoPinAberto = true;
    exibirDialogoPin(
      context: context,
      pinEsperado: _pinRealConfirmado,
      aoConfirmarPinCorreto: _aoConfirmarPinCorreto,
      // Regra de negócio: exatamente 3 tentativas de PIN erradas
      // encerram o cronômetro imediatamente e disparam o alerta
      // completo — ver [_aoAtingirTerceiraSenhaErrada]. Nas 2 primeiras
      // tentativas erradas o diálogo apenas mostra o erro e permanece
      // aberto para uma nova tentativa, sem disparar nada.
      limiteErrosConsecutivos: 3,
      aoAtingirLimiteDeErros: _aoAtingirTerceiraSenhaErrada,
    ).then((_) {
      _dialogoPinAberto = false;
    });
  }

  /// Fecha o diálogo de PIN se estiver aberto — usado quando o próprio
  /// cronômetro (não o usuário) precisa encerrar o ciclo: o tempo se
  /// esgotou naturalmente, ou a 3ª tentativa de PIN errada disparou o
  /// alerta. Devolve a interface ao estado normal (regra de negócio:
  /// "libere a interface do aplicativo para uso normal").
  void _fecharDialogoPinSeAberto() {
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    _dialogoPinAberto = false;
  }


  void _iniciarTimer() {
    _carregarConfiguracoesSeguranca();
    int totalSegundos = (_horaSelecionada * 3600) + (_minutoSelecionada * 60);

    if (totalSegundos <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.segurancaSelecioneTempo)),
      );
      return;
    }

    // Cancela sistematicamente QUALQUER Timer principal que ainda possa
    // estar rodando de um ciclo anterior, antes de iniciar um novo —
    // elimina a possibilidade de dois cronômetros concorrentes
    // coexistirem.
    _cancelarTimerPrincipal();

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
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      _db.inserirEventoHistorico(
        titulo: l10n.historicoCronometroAtivadoTitulo,
        descricao: l10n.historicoCronometroAtivadoDescricao(
          _horaSelecionada.toString().padLeft(2, '0'),
          _minutoSelecionada.toString().padLeft(2, '0'),
        ),
        categoria: 'seguranca',
      );
    }

    // Regra de negócio 2 e 3 (Captura Proativa + Loop de Atualização):
    // no exato momento em que o cronômetro é iniciado, dispara IMEDIATAMENTE
    // a busca de localização de alta precisão em segundo plano (warm-up) e
    // agenda a atualização automática a cada 2 minutos enquanto o
    // cronômetro permanecer ativo. A chamada não é aguardada (fire-and-
    // -forget) para não travar a UI do botão de check-in.
    _locationService.iniciarCicloDeAtualizacao();

    // Agenda o alarme NATIVO (android_alarm_manager_plus), que garante o
    // disparo de emergência mesmo que o app seja fechado ou fique em
    // segundo plano. Regra de negócio reespecificada em 2026-08-09: sem
    // tolerância extra — dispara exatamente no fim do tempo escolhido
    // pelo usuário, replicando o mesmo instante do cronômetro em memória.
    _alarmeService.agendarAlarmeEmergencia(
      duracaoAteDisparo: Duration(seconds: totalSegundos),
      contexto: _contextoController.text.trim(),
    );

    // Regra de negócio 4 (Rastreamento em segundo plano): registra este
    // ciclo como um dead man's switch na nuvem, reaproveitando a mesma
    // infraestrutura já validada para o alarme de rotina — dentro da
    // janela de 120 minutos antes do fim, a localização passa a ser
    // capturada e sobrescrita na nuvem a cada 1 minuto; se o aparelho
    // ficar offline/desligado antes do fim, a Cloud Function agendada
    // (`scheduledAlarmMonitor.js`) dispara o alerta usando a ÚLTIMA
    // localização válida registrada, com seu horário exato.
    BackgroundLocationHeartbeatService().registrarCheckinAtivo(
      dataHoraDisparo: DateTime.now().add(Duration(seconds: totalSegundos)),
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
        // Reespecificação do usuário (2026-08-10, Parte 3): o tempo
        // chegou ao fim — a partir daqui, quem conduz o fluxo real é a
        // tela dedicada [CronometroDisparadoScreen], aberta pelo alarme
        // NATIVO agendado em [AlarmeService.agendarAlarmeEmergencia] para
        // este MESMO instante (som + teclado de PIN com 180 segundos de
        // tolerância, 3 tentativas). Este Timer visual só encerra a
        // contagem local — NUNCA MAIS dispara o alerta diretamente (antes
        // disparava aqui, sem nenhuma chance de PIN).
        _finalizarTimerLocalAoZerar();
      }
    });
  }

  /// Encerra apenas o Timer visual e o loop LOCAL de localização desta
  /// tela (par do `iniciarCicloDeAtualizacao()` feito em [_iniciarTimer])
  /// quando o cronômetro chega a zero — a partir daqui,
  /// [CronometroDisparadoScreen] assume seu PRÓPRIO par
  /// iniciar/parar de rastreamento pela duração da janela de 180s.
  /// Propositalmente NÃO chama [_pararTimer]/[BackgroundLocationHeartbeatService.cancelarCheckinAtivo]:
  /// o heartbeat de nuvem (dead man's switch) e o alarme nativo continuam
  /// intactos até o fluxo ser realmente resolvido (PIN correto ou alerta
  /// disparado), dentro da nova tela.
  void _finalizarTimerLocalAoZerar() {
    _cancelarTimerPrincipal();
    _fecharDialogoPinSeAberto();
    _locationService.pararCicloDeAtualizacao();
    if (mounted) {
      setState(() {
        _isTimerAtivo = false;
        _segundosRestantes = 0;
      });
    }
  }

  void _pararTimer() {
    _cancelarTimerPrincipal();
    // O cronômetro foi parado/desarmado (por qualquer motivo): interrompe
    // o loop de atualização de localização a cada 2 minutos, já que ele
    // só deve rodar enquanto o check-in estiver ativo.
    _locationService.pararCicloDeAtualizacao();
    // Encerra o acompanhamento do dead man's switch na nuvem para este
    // ciclo (ver [BackgroundLocationHeartbeatService.cancelarCheckinAtivo]) —
    // não altera o status já gravado, apenas para de atualizá-lo.
    BackgroundLocationHeartbeatService().cancelarCheckinAtivo();

    if (!mounted) return;
    setState(() {
      _isTimerAtivo = false;
      _segundosRestantes = 0;
    });

    // NOTA: o fechamento do diálogo de PIN (Navigator.pop) é tratado
    // explicitamente em cada ponto de chamada específico (dentro do
    // próprio PinDialogContent ao confirmar o PIN, e em
    // [_fecharDialogoPinSeAberto] quando o disparo de emergência
    // acontece) — NUNCA aqui, pois _pararTimer() também é chamado por
    // esses fluxos, onde um pop indevido poderia fechar a rota errada ou
    // falhar silenciosamente.
  }

  /// Chamado pelo [PinDialogContent] quando o PIN correto é digitado
  /// (1ª ou 2ª tentativa). Regra de negócio: cancela o cronômetro
  /// IMEDIATAMENTE e NENHUMA mensagem de alerta é enviada. Cancela o
  /// alarme NATIVO (só agora, com o PIN confirmado), interrompe os
  /// timers/heartbeat locais e registra o desarme no histórico. Envolvido
  /// em try/catch para NUNCA travar o diálogo/UI mesmo em caso de falha.
  Future<void> _aoConfirmarPinCorreto() async {
    try {
      await _alarmeService.cancelarAlarme();
      await _db.limparAguardandoConfirmacaoPin();
      // Avisa a nuvem imediatamente que o check-in foi desarmado com
      // sucesso (ver [BackgroundLocationHeartbeatService.confirmarCheckinSeguro]),
      // antes que o dead man's switch agendado tenha qualquer chance de
      // considerar o prazo vencido.
      BackgroundLocationHeartbeatService().confirmarCheckinSeguro();

      _pararTimer();
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        _db.inserirEventoHistorico(
          titulo: l10n.historicoCheckinDesarmadoTitulo,
          descricao: l10n.historicoCheckinDesarmadoDescricao,
          categoria: 'seguranca',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.segurancaCheckinDesarmado), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao confirmar PIN/desarmar check-in: $e');
    }
  }

  // Flag simples para garantir que, mesmo diante de eventuais chamadas
  // concorrentes (ex.: o cronômetro chegando a zero E a 3ª tentativa de
  // PIN errada quase ao mesmo tempo), o disparo de emergência ocorra NO
  // MÁXIMO uma única vez por ciclo — nunca em loop, nunca duplicado.
  bool _disparoJaExecutadoNesteCiclo = false;

  /// Ponto ÚNICO de disparo de emergência deste cronômetro — usado tanto
  /// quando o tempo se esgota sem desarme (regra de negócio 3) quanto
  /// quando o PIN é digitado errado pela 3ª vez consecutiva (regra de
  /// negócio 2). Garante (via [_disparoJaExecutadoNesteCiclo]) que o
  /// disparo ocorra apenas UMA vez por ciclo, fecha o diálogo de PIN se
  /// estiver aberto (libera a interface para uso normal) e delega para
  /// [_executarDisparoDeEmergencia] o disparo em si + o aviso na tela.
  Future<void> _dispararUmaVezSeNecessario() async {
    if (_disparoJaExecutadoNesteCiclo) return;
    _disparoJaExecutadoNesteCiclo = true;
    // Idempotente mesmo se o cronômetro já tiver sido cancelado pelo
    // chamador (ex: o próprio Timer.periodic ao chegar a zero) — cobre
    // também o caminho da 3ª tentativa de PIN errada, onde o cronômetro
    // ainda pode estar rodando neste exato instante.
    _cancelarTimerPrincipal();
    _fecharDialogoPinSeAberto();
    await _executarDisparoDeEmergencia();
  }

  /// Executa o disparo de emergência (SMS + Push App-para-App + WhatsApp,
  /// se ativado/com créditos) e exibe IMEDIATAMENTE o aviso na tela (regra
  /// de negócio 2/3: "Mensagem com a localização foi enviada para os
  /// números cadastrados."), sem esperar a confirmação de rede do
  /// SMS/nuvem, que roda em paralelo. Reaproveita o [EmergencyAlertService],
  /// compartilhado com o callback headless do [AlarmeService]. Protegido
  /// por try/catch para que qualquer falha (GPS, SMS, banco) jamais trave
  /// a interface do usuário ou dispare novamente em loop.
  ///
  /// Regra de negócio 7 (restrições obrigatórias): a CÂMERA nunca é
  /// acionada em nenhum ponto deste fluxo. NOTA (reespecificação do
  /// usuário, 2026-08-10): a restrição original também proibia qualquer
  /// som de alarme — isso foi revertido DE PROPÓSITO, mas só para o novo
  /// fluxo "ao zerar" (ver [CronometroDisparadoScreen], que toca o alarme
  /// e abre o teclado de PIN por até 180s). Este método específico
  /// (disparo por 3ª tentativa de PIN errada durante uma tentativa
  /// MANUAL de desarme, ANTES do cronômetro zerar) continua sem tocar
  /// nenhum som — regra histórica preservada aqui, não pedida para
  /// mudar.
  Future<void> _executarDisparoDeEmergencia() async {
    _mostrarAlertaMensagemEnviada();
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

  /// Exibe o alerta na tela avisando que a mensagem de emergência foi
  /// enviada (regras de negócio 2 e 3). Chamado uma única vez por ciclo,
  /// de dentro de [_executarDisparoDeEmergencia] — nunca aguarda a
  /// confirmação de rede do SMS/nuvem para aparecer.
  void _mostrarAlertaMensagemEnviada() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 36),
        title: Text(l10n.segurancaAlertaEnviadoTitulo),
        content: Text(l10n.segurancaAlertaEnviadoConteudo),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.fechar),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // 3ª TENTATIVA DE PIN ERRADA (gatilho de emergência)
  // ==========================================================

  /// Callback passado ao [PinDialogContent] (ver [_abrirDialogoDesarme]),
  /// acionado automaticamente quando o usuário digita o PIN INCORRETO 3
  /// VEZES CONSECUTIVAS durante uma tentativa de desarme. Regra de
  /// negócio: o cronômetro é encerrado IMEDIATAMENTE, o diálogo de PIN é
  /// fechado, o alerta na tela é exibido e o alerta de emergência
  /// completo (Push App-para-App, SMS e WhatsApp) é disparado.
  ///
  /// ORDEM CRÍTICA: o alerta prioritário para a nuvem (Firebase) é
  /// disparado e AGUARDADO PRIMEIRO, antes de qualquer outro
  /// processamento local — garantindo que, mesmo que o aparelho seja
  /// destruído/desligado nos segundos seguintes, a nuvem já tenha
  /// recebido o alerta. Só depois disso o disparo completo local é
  /// executado (ver [_dispararUmaVezSeNecessario]).
  ///
  /// Protegido por try/catch em cada etapa para nunca propagar exceção de
  /// volta ao diálogo de PIN.
  Future<void> _aoAtingirTerceiraSenhaErrada() async {
    debugPrint('🚨 [PIN INCORRETO 3x] 3 PINs incorretos consecutivos detectados. '
        'Encerrando o cronômetro e disparando o alerta completo.');

    try {
      await FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto();
    } catch (e) {
      debugPrint('⚠️ [PIN INCORRETO 3x] Falha ao disparar alerta prioritário na nuvem: $e');
    }

    // Reaproveita o mesmo guard de disparo único por ciclo
    // ([_disparoJaExecutadoNesteCiclo]), que também fecha o diálogo de
    // PIN e cancela o cronômetro principal.
    await _dispararUmaVezSeNecessario();
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
          title: Text(AppLocalizations.of(context)!.segurancaConfirmarSosTitulo),
          content: Text(AppLocalizations.of(context)!.segurancaConfirmarSosConteudo),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(AppLocalizations.of(context)!.cancelar),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(AppLocalizations.of(context)!.segurancaConfirmarSosBotao, style: const TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (confirmou != true || !mounted) return;

    try {
      // P1 (SMS + nuvem/WhatsApp) e P2 (abre a câmera) disparam EM
      // PARALELO — P1 nunca deve atrasar o obturador (câmera física
      // ~3s: nenhuma espera de rede/GPS entre o toque e a câmera
      // abrindo). Também não exibimos mais nenhuma faixa/SnackBar de
      // aviso por cima do botão/câmera: a tela vermelha de dissuasão
      // exibida após a foto já confirma visualmente o disparo.
      unawaited(SosDisparoService().executarP1LocalizacaoImediata(origem: 'sos_manual'));
      // P2: abre a câmera (Recurso de Captura e Dissuasão) — checa o
      // limite mensal de fotos do Plano Gratuito internamente.
      await CapturaDissuasaoService().abrirCapturaSePermitido(origemUnificada: 'sos_manual');
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
    // (com o cronômetro em contagem regressiva) é SEMPRE exibida — o
    // diálogo de PIN, quando necessário, é aberto por cima dela via
    // [exibirDialogoPin] (ver [_abrirDialogoDesarme]), nunca bloqueando a
    // navegação para as demais abas (Família, Histórico) nem a
    // HomeScreen.
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
                  Text(
                    AppLocalizations.of(context)!.segurancaTituloSecaoTempo,
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
      texto = AppLocalizations.of(context)!.segurancaServidorVerificando;
    } else if (_apiOnline == true) {
      cor = Colors.green;
      icone = Icons.cloud_done;
      texto = AppLocalizations.of(context)!.segurancaServidorOnline;
    } else {
      cor = Colors.red;
      icone = Icons.cloud_off;
      texto = AppLocalizations.of(context)!.segurancaServidorOffline;
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
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(context)!.segurancaDicaContextoLabel,
                  hintText: AppLocalizations.of(context)!.segurancaDicaContextoHint,
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
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
            Text(
              AppLocalizations.of(context)!.horasLabel,
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
            Text(
              AppLocalizations.of(context)!.minutosLabel,
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
                  _isTimerAtivo ? _formatarTempo(_segundosRestantes) : AppLocalizations.of(context)!.segurancaFazerCheckin,
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
                _isTimerAtivo ? AppLocalizations.of(context)!.segurancaToqueDesarmar : AppLocalizations.of(context)!.segurancaToqueIniciar,
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
        label: Text(
          AppLocalizations.of(context)!.segurancaBotaoPanico,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

}
