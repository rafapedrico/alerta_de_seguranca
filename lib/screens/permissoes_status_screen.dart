import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/onboarding_service.dart';
import '../services/plano_ciclo_service.dart';
import '../services/premium_purchase_service.dart';
import '../services/rastreamento_continuo_service.dart';
import '../services/sos_plano_aviso_service.dart';
import '../services/sos_widget_status_service.dart';
import '../widgets/permissao_status_card.dart';

/// Tela "Status de Permissões", acessível a qualquer momento em
/// Configurações > Minha Conta > Status de Permissões — mostra EXATAMENTE
/// os mesmos cards de verificação de permissões exibidos no Assistente de
/// Configuração Inicial (`OnboardingScreen`, ver [PermissaoStatusCard]),
/// reaproveitando o mesmo [OnboardingService] de checagem/solicitação.
///
/// Diferente do onboarding, esta tela:
/// - Não é exibida automaticamente nem bloqueia nada — é só uma consulta/
///   ação avulsa, com um AppBar normal (botão Voltar).
/// - Não chama [OnboardingService.marcarConcluido] nem tem um botão
///   "Continuar" — o usuário sai tocando Voltar quando quiser.
/// - Todo card (não só Localização) ganha o atalho "Abrir Configurações",
///   permitindo abrir as configurações nativas do aparelho para QUALQUER
///   permissão pendente, não só a essencial.
class PermissoesStatusScreen extends StatefulWidget {
  const PermissoesStatusScreen({super.key});

  @override
  State<PermissoesStatusScreen> createState() => _PermissoesStatusScreenState();
}

class _PermissoesStatusScreenState extends State<PermissoesStatusScreen>
    with WidgetsBindingObserver {
  final OnboardingService _service = OnboardingService();

  StatusPermissaoOnboarding _bateria = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _notificacoes = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _localizacao = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _camera = StatusPermissaoOnboarding.pendente;

  StatusPermissaoOnboarding _telaCheia = StatusPermissaoOnboarding.pendente;

  /// Widget SOS na tela de início (`getAppWidgetIds`, ver
  /// [SosWidgetStatusService]). `null` = desconhecido.
  bool? _widgetSos;

  /// Dias bloqueados do Plano Free: o botão SOS está desativado.
  BloqueioSosPlano? _bloqueioSosPlano;

  bool _carregando = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _carregarStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _carregarStatus();
    }
  }

  Future<void> _carregarStatus() async {
    final resultados = await Future.wait([
      _service.statusBateria(),
      _service.statusNotificacoes(),
      _service.statusLocalizacao(),
      _service.statusCamera(),
      _service.statusTelaCheia(),
    ]);
    // Reverificado também a cada volta ao primeiro plano (ver
    // didChangeAppLifecycleState): fica verde sozinho depois que o
    // usuário adiciona o widget e volta ao app.
    final widgetSos = await SosWidgetStatusService.widgetInstalado();
    final bloqueioSosPlano =
        BloqueioSosPlano.vigente(await PlanoCicloService().obterStatusAtualizado());
    await RastreamentoContinuoService().atualizarEstado();
    if (!mounted) return;
    setState(() {
      _bateria = resultados[0];
      _notificacoes = resultados[1];
      _localizacao = resultados[2];
      _camera = resultados[3];
      _telaCheia = resultados[4];
      _widgetSos = widgetSos;
      _bloqueioSosPlano = bloqueioSosPlano;
      _carregando = false;
    });
  }

  Future<void> _tocarBateria() async {
    await _service.solicitarBateria();
    final novo = await _service.statusBateria();
    if (mounted) setState(() => _bateria = novo);
  }

  Future<void> _tocarNotificacoes() async {
    await _service.solicitarNotificacoes();
    final novo = await _service.statusNotificacoes();
    if (mounted) setState(() => _notificacoes = novo);
  }

  Future<void> _tocarLocalizacao() async {
    await _service.solicitarLocalizacao();
    final novo = await _service.statusLocalizacao();
    if (mounted) setState(() => _localizacao = novo);
  }

  Future<void> _tocarCamera() async {
    await _service.solicitarCamera();
    final novo = await _service.statusCamera();
    if (mounted) setState(() => _camera = novo);
  }

  Future<void> _tocarTelaCheia() async {
    await _service.solicitarTelaCheia();
    final novo = await _service.statusTelaCheia();
    if (mounted) setState(() => _telaCheia = novo);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(title: Text(l10n.statusPermissoesTitulo)),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  Text(
                    l10n.statusPermissoesIntroducao,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  PermissaoStatusCard(
                    icone: Icons.notifications_active_rounded,
                    titulo: l10n.onboardingNotificacoesTitulo,
                    descricao: l10n.onboardingNotificacoesConteudo,
                    essencial: true,
                    status: _notificacoes,
                    aoConceder: _tocarNotificacoes,
                    aoAbrirConfiguracoes:
                        _notificacoes != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                  ),
                  PermissaoStatusCard(
                    icone: Icons.my_location_rounded,
                    titulo: l10n.onboardingLocalizacaoTitulo,
                    descricao: '${l10n.onboardingLocalizacaoConteudo} ${l10n.localizacaoSempreMotivoMonitoramento}',
                    essencial: true,
                    status: _localizacao,
                    aoConceder: _tocarLocalizacao,
                    aoAbrirConfiguracoes:
                        _localizacao != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                    textoStatusParcial: l10n.onboardingLocalizacaoStatusParcial,
                  ),
                  PermissaoStatusCard(
                    icone: Icons.battery_saver_rounded,
                    titulo: l10n.permissaoBateriaTitulo,
                    descricao: l10n.permissaoBateriaConteudo,
                    essencial: false,
                    status: _bateria,
                    aoConceder: _tocarBateria,
                    aoAbrirConfiguracoes:
                        _bateria != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                  ),
                  PermissaoStatusCard(
                    icone: Icons.camera_alt_rounded,
                    titulo: l10n.onboardingCameraTitulo,
                    descricao: l10n.onboardingCameraConteudo,
                    essencial: false,
                    status: _camera,
                    aoConceder: _tocarCamera,
                    aoAbrirConfiguracoes:
                        _camera != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                  ),
                  PermissaoStatusCard(
                    icone: Icons.fullscreen_rounded,
                    titulo: l10n.onboardingTelaCheiaTitulo,
                    descricao: l10n.onboardingTelaCheiaConteudo,
                    essencial: false,
                    status: _telaCheia,
                    aoConceder: _tocarTelaCheia,
                    aoAbrirConfiguracoes:
                        _telaCheia != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                  ),
                  if (_widgetSos != null)
                    PermissaoStatusCard(
                      icone: Icons.sos_rounded,
                      titulo: l10n.sosWidgetStatusTitulo,
                      descricao: l10n.sosWidgetStatusDescricao,
                      essencial: false,
                      status: _widgetSos == true && _bloqueioSosPlano == null
                          ? StatusPermissaoOnboarding.concedida
                          : StatusPermissaoOnboarding.pendente,
                      textoStatusConcedida: l10n.sosWidgetStatusAtivo,
                      textoStatusPendente: _bloqueioSosPlano != null
                          ? l10n.sosPlanoStatusDesativado
                          : l10n.sosWidgetStatusNaoAdicionado,
                      corStatusPendente: Colors.red.shade600,
                      textoBotaoConceder: l10n.sosWidgetBotaoComoAdicionar,
                      aoConceder: () => SosWidgetStatusService.abrirTutorial(context),
                      aoTocarCard: () => SosWidgetStatusService.abrirTutorial(context),
                      aviso: _bloqueioSosPlano == null
                          ? null
                          : l10n.sosPlanoDesativadoAte(formatarDiaMes(_bloqueioSosPlano!.fim)),
                      textoBotaoAviso: l10n.sosPlanoBotaoAssinar,
                      aoTocarBotaoAviso: PremiumPurchaseService().comprarPremium,
                    ),
                  const _CartaoRastreamentoContinuo(),
                ],
              ),
            ),
    );
  }
}

/// Card "Rastreamento contínuo" (aba Monitoramento): "Ativado" ou
/// "Desativado — motivo", e cada requisito do Android para funcionar com o
/// app fechado, com atalho para as Configurações. Escuta o serviço: muda
/// sozinho quando uma permissão de compartilhamento muda.
class _CartaoRastreamentoContinuo extends StatelessWidget {
  const _CartaoRastreamentoContinuo();

  @override
  Widget build(BuildContext context) {
    final servico = RastreamentoContinuoService();
    return AnimatedBuilder(
      animation: Listenable.merge(
          [servico.estado, servico.monitorandoMe, servico.consentido, servico.pausado]),
      builder: (context, _) {
        final estado = servico.estado.value;
        if (estado == null) return const SizedBox.shrink();
        return _conteudo(context, servico, estado);
      },
    );
  }

  Widget _conteudo(
      BuildContext context, RastreamentoContinuoService servico, EstadoRastreamento estado) {
    final l10n = AppLocalizations.of(context)!;
    final ativo = estado.rastreamentoAtivo && servico.motivoInativo == null;
    String status = ativo ? l10n.rcStatusAtivado : l10n.rcStatusDesativado;
    final cor = ativo ? Colors.green.shade600 : Colors.grey.shade700;
    final motivo = ativo ? null : textoMotivoRastreamento(l10n, servico.motivoInativo);
    if (motivo != null) status = l10n.rcStatusComMotivo(status, motivo);
    final itens = <(String, bool)>[
      (l10n.rcItemSempre, estado.sempre),
      (l10n.rcItemPrecisao, estado.precisaoExata),
      (l10n.rcItemSegundoPlano, estado.atualizacaoSegundoPlano && estado.otimizacaoBateriaIgnorada),
      (l10n.rcItemPoucaEnergia, !estado.modoPoucaEnergia),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: Colors.blue.shade400.withValues(alpha: 0.12),
                child: Icon(Icons.share_location_rounded, color: Colors.blue.shade400),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.rcStatusTitulo,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(status,
                        style: TextStyle(color: cor, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            l10n.rcStatusDescricao,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.35),
          ),
          const SizedBox(height: 10),
          for (final (rotulo, ok) in itens)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(
                    ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
                    size: 17,
                    color: ok ? Colors.green.shade600 : Colors.red.shade400,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(rotulo, style: const TextStyle(fontSize: 13))),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: openAppSettings, child: Text(l10n.rcAbrirAjustes)),
          ),
        ],
      ),
    );
  }
}
