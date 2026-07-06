import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'dart:async';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';
import '../../services/location_service.dart';
import '../../services/emergency_alert_service.dart';
import '../../services/alarme_service.dart';
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
  static const TextStyle _estiloRodape = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: Colors.grey,
    fontStyle: FontStyle.italic,
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

  // Serviço singleton responsável pelo ciclo de vida proativo do GPS:
  // solicitação de permissão, warm-up ao iniciar o cronômetro e loop de
  // atualização a cada 2 minutos enquanto o check-in estiver ativo.
  final LocationService _locationService = LocationService();

  @override
  void initState() {
    super.initState();
    _carregarConfiguracoesSeguranca();

    // Regra de negócio 1 (Permissão ao Iniciar): assim que a tela de
    // Segurança é aberta, o app já verifica/solicita a permissão de
    // localização do Android, garantindo que o GPS esteja liberado antes
    // mesmo de o usuário ativar o cronômetro de check-in.
    _locationService.garantirPermissaoDeLocalizacao();
  }

  @override
  void dispose() {
    _contextoController.dispose();
    _timer?.cancel();
    _timerToleranciaBloqueio?.cancel();
    // Interrompe o loop de atualização de localização (se ainda ativo) ao
    // destruir a tela, evitando Timers órfãos em segundo plano.
    _locationService.pararCicloDeAtualizacao();
    super.dispose();
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

      if (_segundosRestantes > 0) {
        setState(() {
          _segundosRestantes--;
        });
      } else {
        _timer?.cancel();
        _ativarBloqueioDeSeguranca();
      }
    });
  }

  void _pararTimer() {
    _timer?.cancel();
    _timerToleranciaBloqueio?.cancel();
    // O cronômetro foi parado/desarmado (por qualquer motivo): interrompe
    // o loop de atualização de localização a cada 2 minutos, já que ele
    // só deve rodar enquanto o check-in estiver ativo.
    _locationService.pararCicloDeAtualizacao();
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
  void _ativarBloqueioDeSeguranca() {
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
      );
    }

    _timerToleranciaBloqueio = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_segundosToleranciaBloqueio > 0) {
        setState(() {
          _segundosToleranciaBloqueio--;
        });
      } else {
        _timerToleranciaBloqueio?.cancel();
        // Fecha o diálogo de PIN (se ainda aberto) antes de disparar o
        // alerta, já que o tempo de tolerância esgotou sem confirmação.
        // Este é o ÚNICO ponto (além da confirmação de PIN correto
        // dentro do próprio PinDialogContent) em que o diálogo é
        // fechado programaticamente, evitando pops indevidos em outras
        // rotas.
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
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
      _timerToleranciaBloqueio?.cancel();
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
    _timerToleranciaBloqueio?.cancel();
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
                  const SizedBox(height: 32),
                  _buildRodape(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
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

  /// Rodapé decorativo exibido ao final da tela principal.
  Widget _buildRodape() {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.favorite, color: Colors.red, size: 16),
        SizedBox(width: 8),
        Flexible(
          child: Text(
            'Cuidando de você com carinho',
            textAlign: TextAlign.center,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: _estiloRodape,
          ),
        ),
        SizedBox(width: 8),
        Icon(Icons.favorite, color: Colors.red, size: 16),
      ],
    );
  }
}
