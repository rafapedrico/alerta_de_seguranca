import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';
import '../../services/alerta_desarme_service.dart';
import '../../services/database_helper.dart';
import '../../services/historico_alertas_service.dart';
import '../../services/l10n_headless_service.dart';
import '../../services/notificacao_service.dart';
import '../../services/wallpaper_service.dart';
import '../../services/location_service.dart';
import '../../services/alarme_service.dart';
import '../../services/background_location_heartbeat_service.dart';
import '../../services/captura_dissuasao_service.dart';
import '../cronometro_disparado_screen.dart' show chaveCronometroFluxoResolvido;
import '../home_screen.dart' show abrirConfiguracoesDoApp;
import '../../widgets/confirmacao_alerta_emergencia.dart';
import '../../widgets/pin_dialog.dart';
import '../../widgets/plano_bloqueado_dialog.dart';

class SegurancaTab extends StatefulWidget {
  const SegurancaTab({super.key});

  @override
  State<SegurancaTab> createState() => _SegurancaTabState();
}

class _SegurancaTabState extends State<SegurancaTab> {
  final DatabaseHelper _db = DatabaseHelper();
  final AlarmeService _alarmeService = AlarmeService();

  // Controlador para o campo de Anotações/Dica de Contexto (o texto do
  // usuário que vai em todos os alertas do cronômetro e no SOS).
  final TextEditingController _contextoController = TextEditingController();

  static const TextStyle _estiloTituloSecao = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: Colors.black87,
  );
  static const TextStyle _estiloLabelPicker = TextStyle(
    color: Colors.grey,
    fontWeight: FontWeight.w500,
  );

  /// PIN gravado (hash com sal, ver PinSeguro) — nunca um PIN padrão.
  String? _pinRealConfirmado;

  int _horaSelecionada = 0;
  int _minutoSelecionada = 5;

  Timer? _timer;
  bool _isTimerAtivo = false;
  int _segundosRestantes = 0;

  /// Evita abrir o diálogo de PIN duas vezes.
  bool _dialogoPinAberto = false;

  /// Evita dois inícios simultâneos do cronômetro (toque duplo).
  bool _iniciando = false;

  @override
  void initState() {
    super.initState();
    _carregarConfiguracoesSeguranca();
    // A aba é recriada ao voltar do Início: retoma a contagem VISUAL de um
    // cronômetro ainda ativo (o alarme nativo e a localização a cada 1 min
    // nunca dependeram desta tela).
    _restaurarCronometroAtivoSePersistido();
    LocationService().garantirPermissaoDeLocalizacao();
  }

  @override
  void dispose() {
    _contextoController.dispose();
    // Só o Timer VISUAL para aqui. O cronômetro em si (alarme exato nativo
    // + localização a cada 1 min, ver AlarmeService/VigiaLocalizacao)
    // continua com a tela fechada, o app em segundo plano ou fechado.
    _cancelarTimerPrincipal();
    super.dispose();
  }

  void _cancelarTimerPrincipal() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _carregarConfiguracoesSeguranca() async {
    try {
      // Troca de PIN pendente há 2 h: efetiva antes de ler.
      await _db.processarSenhaPendenteSeExpirada();
      final config = await _db.getUserConfig();
      if (config != null && mounted) {
        setState(() {
          _pinRealConfirmado = config['pin_real'] as String?;
        });
      }
    } catch (_) {}
  }

  /// Toque no botão circular: com o cronômetro ativo, NUNCA o cancela
  /// direto — abre o teclado de PIN (o cronômetro continua contando).
  void _alternarTimer() {
    if (_isTimerAtivo) {
      _abrirDialogoDesarme();
    } else {
      _iniciarTimer();
    }
  }

  void _abrirDialogoDesarme() {
    if (_dialogoPinAberto || !mounted) return;
    _dialogoPinAberto = true;
    exibirDialogoPin(
      context: context,
      pinEsperado: _pinRealConfirmado,
      aoConfirmarPinCorreto: _aoConfirmarPinCorreto,
      // 3 tentativas erradas: o teclado fecha e o alerta é enviado.
      limiteErrosConsecutivos: 3,
      aoAtingirLimiteDeErros: _aoAtingirTerceiraSenhaErrada,
    ).then((_) {
      _dialogoPinAberto = false;
    });
  }

  void _fecharDialogoPinSeAberto() {
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    _dialogoPinAberto = false;
  }

  /// Retoma a contagem visual de um cronômetro ainda ativo (fim gravado no
  /// SQLite no início).
  Future<void> _restaurarCronometroAtivoSePersistido() async {
    try {
      final config = await _db.getUserConfig();
      final epochMs = int.tryParse((config?['timestamp_expiracao_alarme'] as String?) ?? '');
      if (epochMs == null) return;
      final restante = DateTime.fromMillisecondsSinceEpoch(epochMs).difference(DateTime.now());
      if (restante.inSeconds <= 0 || !mounted) return;
      _cancelarTimerPrincipal();
      _disparoJaExecutadoNesteCiclo = false;
      setState(() {
        _segundosRestantes = restante.inSeconds;
        _isTimerAtivo = true;
        _contextoController.text = (config?['contexto_timer_ativo'] as String?) ?? '';
      });
      _iniciarTimerVisual();
    } catch (e) {
      debugPrint('⚠️ [SegurancaTab] Falha ao restaurar cronômetro ativo: $e');
    }
  }

  Future<void> _iniciarTimer() async {
    if (_iniciando) return;
    _iniciando = true;
    try {
      await _iniciarTimerProtegido();
    } finally {
      _iniciando = false;
    }
  }

  Future<void> _iniciarTimerProtegido() async {
    final l10n = AppLocalizations.of(context)!;

    // Sem PIN cadastrado não há como desarmar: pede o cadastro antes.
    await _carregarConfiguracoesSeguranca();
    if (!mounted) return;
    if (!await exigirPinCadastrado(context,
        pinGravado: _pinRealConfirmado, abrirConfiguracoes: abrirConfiguracoesDoApp)) {
      return;
    }
    if (!mounted) return;

    // Plano Free fora dos 10 dias ativos: aviso de upsell.
    if (!await garantirRecursoLiberadoOuExibirUpsell(context)) return;
    if (!mounted) return;

    final totalSegundos = (_horaSelecionada * 3600) + (_minutoSelecionada * 60);
    if (totalSegundos <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.segurancaSelecioneTempo)),
      );
      return;
    }

    // O ciclo anterior na tolerância ou com o alerta pendente: reiniciar
    // agora cancelaria esse alerta sem PIN.
    if (await _alarmeService.cicloAnteriorEmAndamento()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.segurancaCronometroEmAndamento)),
      );
      return;
    }

    // Sem alarme exato o cronômetro não tocaria na hora: NUNCA inicia em
    // silêncio — avisa e oferece a permissão.
    if (!await _alarmeService.podeAgendarExato()) {
      if (mounted) await _pedirPermissaoAlarmeExato();
      return;
    }

    final contexto = _contextoController.text.trim();
    final armado = await _alarmeService.agendarAlarmeEmergencia(
      duracaoAteDisparo: Duration(seconds: totalSegundos),
      contexto: contexto,
    );
    if (!armado) {
      await _db.limparContextoTimerAtivo();
      if (mounted) await _pedirPermissaoAlarmeExato();
      return;
    }
    if (!mounted) return;

    _cancelarTimerPrincipal();
    _disparoJaExecutadoNesteCiclo = false;
    setState(() {
      _segundosRestantes = totalSegundos;
      _isTimerAtivo = true;
    });

    final posicao = await LocationService().posicaoRecente();
    await HistoricoAlertasService().registrarEvento(
      tipo: TipoAlertaHistorico.cronometroAtivado,
      titulo: l10n.historicoCronometroAtivadoTitulo,
      descricao: l10n.historicoCronometroAtivadoDescricao(
        _horaSelecionada.toString().padLeft(2, '0'),
        _minutoSelecionada.toString().padLeft(2, '0'),
      ),
      contexto: contexto,
      latitude: posicao?.latitude,
      longitude: posicao?.longitude,
      precisao: posicao?.accuracy,
    );

    // Dead man's switch na nuvem: ciclo PENDENTE com prazo = fim + 60 s.
    unawaited(BackgroundLocationHeartbeatService().registrarCheckinAtivo(
      dataHoraDisparo: DateTime.now().add(Duration(seconds: totalSegundos)),
      contexto: contexto,
    ));

    _iniciarTimerVisual();
  }

  Future<void> _pedirPermissaoAlarmeExato() async {
    final l10n = AppLocalizations.of(context)!;
    final conceder = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.alarm_on),
        title: Text(l10n.segurancaPermissaoAlarmeExatoTitulo),
        content: Text(l10n.segurancaPermissaoAlarmeExatoConteudo),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancelar)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.botaoConcederPermissao)),
        ],
      ),
    );
    if (conceder == true) await NotificacaoService.solicitarAlarmesExatos();
  }

  /// Contagem visual (só a UI) — quem conduz o fim é a tela nativa
  /// [CronometroDisparadoScreen], aberta pelo alarme exato.
  void _iniciarTimerVisual() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!identical(timer, _timer)) {
        timer.cancel();
        return;
      }
      if (_segundosRestantes > 0) {
        setState(() => _segundosRestantes--);
      } else {
        _finalizarTimerLocalAoZerar();
      }
    });
  }

  /// Zerou: encerra só a contagem visual. O alarme nativo, a localização
  /// e o ciclo na nuvem seguem até a tela do alarme resolver o fluxo.
  void _finalizarTimerLocalAoZerar() {
    _cancelarTimerPrincipal();
    _fecharDialogoPinSeAberto();
    if (mounted) {
      setState(() {
        _isTimerAtivo = false;
        _segundosRestantes = 0;
      });
    }
  }

  /// Ciclo resolvido (PIN correto ou alerta enviado): encerra o alarme
  /// nativo (marcando a ocorrência como resolvida), a localização e a
  /// contagem.
  Future<void> _pararTimer() async {
    _cancelarTimerPrincipal();
    await _alarmeService.cancelarAlarme();
    await _db.limparContextoTimerAtivo();
    if (!mounted) return;
    setState(() {
      _isTimerAtivo = false;
      _segundosRestantes = 0;
    });
  }

  /// PIN correto ANTES do fim: nada é enviado. Ciclo confirmado na nuvem,
  /// alarme nativo resolvido e o desarme registrado (com localização) na
  /// área protegida do histórico.
  Future<void> _aoConfirmarPinCorreto() async {
    try {
      final l10n = AppLocalizations.of(context)!;
      final contexto = _contextoController.text.trim();
      await BackgroundLocationHeartbeatService().confirmarCheckinSeguro();
      await _pararTimer();
      await _db.limparAguardandoConfirmacaoPin();
      final posicao = await LocationService().posicaoRecente();
      await HistoricoAlertasService().registrarEvento(
        tipo: TipoAlertaHistorico.cronometroDesarmado,
        titulo: l10n.historicoCheckinDesarmadoTitulo,
        descricao: l10n.historicoCheckinDesarmadoDescricao,
        contexto: contexto,
        latitude: posicao?.latitude,
        longitude: posicao?.longitude,
        precisao: posicao?.accuracy,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.segurancaCheckinDesarmado), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao confirmar PIN/desarmar check-in: $e');
    }
  }

  // Disparo único por ciclo (tempo zerando E 3ª senha errada juntos).
  bool _disparoJaExecutadoNesteCiclo = false;

  /// 3 PINs errados ANTES do fim: o teclado fecha na hora, o ciclo é
  /// encerrado e o alerta (tentativa_desarme_incorreto, com o texto do
  /// usuário e a posição) é enviado. A confirmação cita a tentativa.
  Future<void> _aoAtingirTerceiraSenhaErrada() async {
    if (_disparoJaExecutadoNesteCiclo) return;
    _disparoJaExecutadoNesteCiclo = true;
    _fecharDialogoPinSeAberto();

    final contexto = _contextoController.text.trim();
    final l10n = await L10nHeadlessService.obter();
    if (!mounted) return;
    _abrirConfirmacaoAlertaEnviado(l10n.notif3PinsCronometroCorpo);

    // Trava contra uma segunda tela (alarme nativo chegando) disparando o
    // mesmo ciclo.
    try {
      await _alarmeService.reivindicarDisparoUnicoCronometro();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(chaveCronometroFluxoResolvido, true);
    } catch (_) {}
    unawaited(BackgroundLocationHeartbeatService().confirmarAlertaJaDisparado());
    await _pararTimer();

    try {
      await AlertaDesarmeService.disparar(
        tipo: TipoAlertaHistorico.tentativaDesarmeIncorreto,
        titulo: l10n.historicoTipoTentativaDesarme,
        motivo: l10n.historicoCronometroPinIncorretoMotivo,
        contexto: contexto,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar o alerta de 3 PINs errados: $e');
    }
    await NotificacaoService.exibirNotificacaoAlertaEnviado(
      titulo: l10n.cronometroNotificacaoTituloAlerta,
      corpo: l10n.notif3PinsCronometroCorpo,
    );
  }

  void _abrirConfirmacaoAlertaEnviado(String mensagem) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (rotaContext) => ConfirmacaoAlertaEmergencia(
          mensagem: mensagem,
          aoFechar: () {
            if (Navigator.of(rotaContext).canPop()) Navigator.of(rotaContext).pop();
          },
        ),
      ),
    );
  }

  // ==========================================================
  // BOTÃO SOS
  // ==========================================================

  /// SOS: envia NA HORA, sem diálogo de confirmação (ver
  /// [CapturaDissuasaoService.iniciarSos], que também ignora o toque
  /// duplo enquanto um SOS estiver em andamento).
  Future<void> _dispararSosManual() async {
    try {
      await CapturaDissuasaoService().iniciarSos(
        origem: TipoAlertaHistorico.sosManual,
        contexto: _contextoController.text.trim(),
      );
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
                style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Botão de SOS: envia a localização na hora, sem confirmação — o
  /// mesmo fluxo do botão físico (Volume+).
  Widget _buildBotaoSos() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _dispararSosManual,
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
