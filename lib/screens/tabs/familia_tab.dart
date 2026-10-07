import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import '../../services/alarme_nativo_service.dart';
import '../../services/alerta_desarme_service.dart';
import '../../services/database_helper.dart';
import '../../services/historico_alertas_service.dart';
import '../../services/l10n_headless_service.dart';
import '../../services/location_service.dart';
import '../../services/notificacao_service.dart';
import '../../services/wallpaper_service.dart';
import '../../services/rotina_alarme_service.dart';
import '../../services/contatos_emergencia_service.dart';
import '../../models/alarme_rotina.dart';
import '../../widgets/pin_dialog.dart';
import '../../widgets/plano_bloqueado_dialog.dart';
import '../home_screen.dart' show abrirConfiguracoesDoApp;

/// Aba Despertador: lista de despertadores de segurança (horário, dias,
/// etiqueta, texto opcional e tolerância), cada um com "Pausar" (até 00h00)
/// e "Apagar" — ambos com PIN (3 tentativas). Sem contato de emergência o
/// botão de adicionar fica desabilitado, com o aviso e um atalho para
/// Configurações.
class FamiliaTab extends StatefulWidget {
  const FamiliaTab({super.key});

  /// `false` sem contato de emergência: o botão "+" do AppBar fica
  /// desabilitado (ver HomeScreen).
  static final ValueNotifier<bool> temContatosNotifier = ValueNotifier<bool>(true);

  @override
  State<FamiliaTab> createState() => FamiliaTabState();
}

class FamiliaTabState extends State<FamiliaTab> with WidgetsBindingObserver {
  final DatabaseHelper _db = DatabaseHelper();

  bool _carregandoAlarmes = true;
  List<AlarmeRotina> _alarmes = [];

  bool _carregandoContatos = true;
  List<Map<String, dynamic>> _contatosEmergencia = [];

  static const List<int> _valoresDias = [1, 2, 3, 4, 5, 6, 7];

  List<String> _iniciaisDias(AppLocalizations l10n) => [
        l10n.familiaDiaInicialSeg,
        l10n.familiaDiaInicialTer,
        l10n.familiaDiaInicialQua,
        l10n.familiaDiaInicialQui,
        l10n.familiaDiaInicialSex,
        l10n.familiaDiaInicialSab,
        l10n.familiaDiaInicialDom,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _carregarAlarmes();
    _carregarContatosEmergencia();
    ContatosEmergenciaService.versaoContatos.addListener(_aoContatosAlterados);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _carregarAlarmes();
      _carregarContatosEmergencia();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ContatosEmergenciaService.versaoContatos.removeListener(_aoContatosAlterados);
    super.dispose();
  }

  void _aoContatosAlterados() => _carregarContatosEmergencia();

  Future<void> _carregarAlarmes() async {
    if (!mounted) return;
    setState(() => _carregandoAlarmes = true);
    try {
      final dados = await _db.listarAlarmes();
      if (!mounted) return;
      setState(() {
        _alarmes = dados.map(AlarmeRotina.fromMap).toList();
        _carregandoAlarmes = false;
      });
    } catch (e) {
      debugPrint('⚠️ [Despertador] Falha ao carregar: $e');
      if (mounted) setState(() => _carregandoAlarmes = false);
    }
  }

  Future<void> _carregarContatosEmergencia() async {
    if (!mounted) return;
    setState(() => _carregandoContatos = true);
    try {
      await _db.processarExclusoesPendentesExpiradas();
      final contatos = await _db.getContatosEmergencia();
      FamiliaTab.temContatosNotifier.value =
          contatos.any((c) => ((c['telefone'] as String?) ?? '').isNotEmpty);
      if (!mounted) return;
      setState(() {
        _contatosEmergencia = contatos;
        _carregandoContatos = false;
      });
    } catch (_) {
      if (mounted) setState(() => _carregandoContatos = false);
    }
  }

  bool _isExclusaoPendente(Map<String, dynamic> contato) {
    final valor = contato['exclusao_pendente'];
    return valor == 1 || valor == true;
  }

  /// Registro no histórico (aba Despertador), com data/hora e a
  /// localização quando houver.
  Future<void> _registrarHistorico(String titulo, String descricao) async {
    final posicao = await LocationService().posicaoRecente();
    await _db.inserirEventoHistorico(
      titulo: titulo,
      descricao: descricao,
      categoria: 'familia',
      latitude: posicao?.latitude,
      longitude: posicao?.longitude,
      precisao: posicao?.accuracy,
    );
  }

  /// PIN para pausar/apagar/editar/reativar: 3 tentativas (nunca um PIN
  /// padrão — sem PIN cadastrado, pede o cadastro). No 3º erro o teclado
  /// fecha, o alerta "Tentativa de apagar/pausar o despertador com senha
  /// incorreta" é enviado e o próprio celular é notificado.
  Future<bool> _confirmarComPin() async {
    if (!mounted) return false;
    final config = await _db.getUserConfig();
    final pinGravado = config?['pin_real'] as String?;
    if (!mounted) return false;
    if (!await exigirPinCadastrado(context,
        pinGravado: pinGravado, abrirConfiguracoes: abrirConfiguracoesDoApp)) {
      return false;
    }
    if (!mounted) return false;

    bool confirmado = false;
    final navegador = Navigator.of(context);
    await exibirDialogoPin(
      context: context,
      pinEsperado: pinGravado,
      mostrarBotaoCancelar: true,
      limiteErrosConsecutivos: 3,
      aoConfirmarPinCorreto: () async {
        confirmado = true;
      },
      aoAtingirLimiteDeErros: () async {
        if (navegador.canPop()) navegador.pop();
        await _dispararAlertaPinIncorreto();
      },
    );
    return confirmado;
  }

  Future<void> _dispararAlertaPinIncorreto() async {
    final l10n = await L10nHeadlessService.obter();
    try {
      await AlertaDesarmeService.disparar(
        tipo: TipoAlertaHistorico.tentativaDesarmeIncorreto,
        titulo: l10n.historicoTipoTentativaDesarme,
        motivo: l10n.familiaPinMotivo3Erros,
      );
    } catch (e) {
      debugPrint('⚠️ [Despertador] Falha ao disparar o alerta de PIN incorreto: $e');
    }
    await NotificacaoService.exibirNotificacaoAlertaEnviado(
      titulo: l10n.familiaPinMotivo3Erros,
      corpo: l10n.despertadorNotif3ErrosCorpo,
    );
  }

  Future<void> _alternarAtivo(AlarmeRotina alarme, bool ativo) async {
    if (alarme.id == null) return;
    final l10n = AppLocalizations.of(context)!;

    // Reativar = mesmo recurso que salvar: Plano Free nos dias bloqueados
    // não reativa.
    if (ativo && !await garantirRecursoLiberadoOuExibirUpsell(context)) return;
    if (!mounted) return;

    // Desativar e reativar pedem o PIN.
    if (!await _confirmarComPin()) return;

    await _db.alternarAtivoAlarme(alarme.id!, ativo);
    if (ativo) {
      final atualizado = await _db.buscarAlarmePorId(alarme.id!);
      if (atualizado != null) await RotinaAlarmeService.agendarAlarme(atualizado);
    } else {
      await RotinaAlarmeService.cancelarAlarme(alarme.id!);
    }

    final etiqueta = alarme.etiquetaExibida(l10n);
    await _registrarHistorico(
      ativo ? l10n.historicoAlarmeAtivadoTitulo : l10n.historicoAlarmeDesativadoTitulo,
      ativo
          ? l10n.historicoAlarmeAtivadoDescricao(etiqueta, alarme.horarioFormatado)
          : l10n.historicoAlarmeDesativadoDescricao(etiqueta, alarme.horarioFormatado),
    );
    await _carregarAlarmes();
  }

  Future<void> _apagarComPin(AlarmeRotina alarme) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmouIntencao = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.familiaExcluirAlarmeTitulo),
            content: Text(l10n.familiaExcluirAlarmeConteudo(alarme.etiquetaExibida(l10n), alarme.horarioFormatado)),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancelar)),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(l10n.excluir),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmouIntencao || !mounted) return;
    if (!await _confirmarComPin()) return;
    await _excluirAlarme(alarme);
  }

  Future<void> _pausarComPin(AlarmeRotina alarme) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmouIntencao = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.familiaPausarAlarmeTitulo),
            content: Text(l10n.familiaPausarAlarmeConteudo(alarme.etiquetaExibida(l10n), alarme.horarioFormatado)),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancelar)),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.blue),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(l10n.familiaPausarBotao),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmouIntencao || !mounted) return;
    if (!await _confirmarComPin()) return;
    await _pausarAlarmePorHoje(alarme);
  }

  Future<void> _excluirAlarme(AlarmeRotina alarme) async {
    if (alarme.id == null) return;
    final l10n = AppLocalizations.of(context)!;
    await RotinaAlarmeService.cancelarAlarme(alarme.id!);
    await _db.deletarAlarme(alarme.id!);
    await _registrarHistorico(
      l10n.historicoAlarmeRemovidoTitulo,
      l10n.historicoAlarmeRemovidoDescricao(alarme.etiquetaExibida(l10n), alarme.horarioFormatado),
    );
    await _carregarAlarmes();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.familiaAlarmeRemovido), behavior: SnackBarBehavior.floating),
      );
    }
  }

  /// Pausa até 00h00: a agenda nativa pula as ocorrências de hoje e a
  /// nuvem recebe a próxima ocorrência válida com `pausadoAte`.
  Future<void> _pausarAlarmePorHoje(AlarmeRotina alarme) async {
    if (alarme.id == null) return;
    final l10n = AppLocalizations.of(context)!;
    await RotinaAlarmeService.pausarAteAmanha(alarme.id!);
    await _registrarHistorico(
      l10n.historicoAlarmePausadoTitulo,
      l10n.historicoAlarmePausadoDescricao(alarme.etiquetaExibida(l10n), alarme.horarioFormatado),
    );
    await _carregarAlarmes();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.familiaAlarmePausadoAte), behavior: SnackBarBehavior.floating),
      );
    }
  }

  /// "Retorna": a próxima ocorrência REAL (o próximo dia selecionado
  /// depois da pausa), não sempre amanhã.
  String _textoRetorno(AlarmeRotina alarme, AppLocalizations l10n) {
    final proxima = RotinaAlarmeService.proximaOcorrenciaValida(alarme.toMap());
    if (proxima == null) return l10n.familiaDiasNuncaLabel;
    final siglas = [
      l10n.familiaDiaAbrevSeg,
      l10n.familiaDiaAbrevTer,
      l10n.familiaDiaAbrevQua,
      l10n.familiaDiaAbrevQui,
      l10n.familiaDiaAbrevSex,
      l10n.familiaDiaAbrevSab,
      l10n.familiaDiaAbrevDom,
    ];
    final dia = '${siglas[proxima.weekday - 1]} '
        '${proxima.day.toString().padLeft(2, '0')}/${proxima.month.toString().padLeft(2, '0')}';
    return l10n.familiaRetorna(alarme.horarioFormatado, dia);
  }

  Future<void> _despausarAlarmeManual(AlarmeRotina alarme) async {
    if (alarme.id == null) return;
    final l10n = AppLocalizations.of(context)!;
    if (!await _confirmarComPin()) return;
    await RotinaAlarmeService.despausarAlarme(alarme.id!);
    await _registrarHistorico(
      l10n.historicoAlarmeReativadoTitulo,
      l10n.historicoAlarmeReativadoDescricao(alarme.etiquetaExibida(l10n), alarme.horarioFormatado),
    );
    await _carregarAlarmes();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.familiaReativadoComSucesso(alarme.etiquetaExibida(l10n), alarme.horarioFormatado)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Botão "+" (AppBar): sem contato de emergência, avisa e oferece o
  /// atalho para Configurações em vez de abrir o formulário.
  void abrirModalAdicionarAlarme() {
    if (!FamiliaTab.temContatosNotifier.value) {
      _avisarSemContato();
      return;
    }
    _abrirModalAlarme();
  }

  void _avisarSemContato() {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.familiaCadastreContatoAviso),
        action: SnackBarAction(
          label: l10n.abrirConfiguracoes,
          onPressed: () => abrirConfiguracoesDoApp(context),
        ),
      ),
    );
  }

  /// Alarme exato e tela cheia: sem eles o despertador não toca na hora nem
  /// abre sobre a tela bloqueada. Oferece os botões para conceder.
  Future<void> _verificarPermissoesDoDespertador() async {
    final exato = await AlarmeNativoService.podeAgendarExato();
    final telaCheia = await NotificacaoService.podeUsarTelaCheia();
    if ((exato && telaCheia) || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.alarm_on),
        title: Text(l10n.familiaPermissoesTitulo),
        content: Text(l10n.familiaPermissoesConteudo),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.agoraNao)),
          if (!exato)
            FilledButton(
              onPressed: () async {
                await NotificacaoService.solicitarAlarmesExatos();
                if (ctx.mounted && telaCheia) Navigator.of(ctx).pop();
              },
              child: Text(l10n.familiaPermissaoAlarmesBotao),
            ),
          if (!telaCheia)
            FilledButton(
              onPressed: () async {
                await NotificacaoService.solicitarPermissaoTelaCheia();
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: Text(l10n.familiaPermissaoTelaCheiaBotao),
            ),
        ],
      ),
    );
  }

  Future<void> _abrirModalAlarme({AlarmeRotina? alarmeExistente}) async {
    int horaSelecionada = alarmeExistente?.hora ?? TimeOfDay.now().hour;
    int minutoSelecionado = alarmeExistente?.minuto ?? 0;
    final Set<int> diasSelecionados = Set<int>.from(alarmeExistente?.diasSemana ?? {});
    // Etiqueta padrão (chave interna) aparece VAZIA no campo.
    final etiquetaController = TextEditingController(
      text: (alarmeExistente == null || alarmeExistente.temEtiquetaPadrao)
          ? ''
          : alarmeExistente.etiqueta,
    );
    final contextoController =
        TextEditingController(text: alarmeExistente?.contextoPersonalizado ?? '');
    int minutosTolerancia = alarmeExistente?.minutosTolerancia ?? 10;
    String? erroValidacao;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final l10nModal = AppLocalizations.of(ctx)!;
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.alarm_add, color: Color(0xFF4C7040)),
                          const SizedBox(width: 8),
                          Text(
                            alarmeExistente == null
                                ? l10nModal.familiaAdicionarAlarme
                                : l10nModal.familiaEditarAlarme,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _seletor(
                            rotulo: l10nModal.familiaHoraLabel,
                            quantidade: 24,
                            inicial: horaSelecionada,
                            aoMudar: (v) => setModalState(() => horaSelecionada = v),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(':', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.grey)),
                          ),
                          _seletor(
                            rotulo: l10nModal.familiaMinutoLabel,
                            quantidade: 60,
                            inicial: minutoSelecionado,
                            aoMudar: (v) => setModalState(() => minutoSelecionado = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text(
                        l10nModal.familiaRepetirLabel,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: List.generate(_valoresDias.length, (index) {
                          final valorDia = _valoresDias[index];
                          final selecionado = diasSelecionados.contains(valorDia);
                          return GestureDetector(
                            onTap: () => setModalState(() {
                              selecionado ? diasSelecionados.remove(valorDia) : diasSelecionados.add(valorDia);
                            }),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: selecionado ? const Color(0xFF4C7040) : Colors.grey.shade200,
                              ),
                              child: Center(
                                child: Text(
                                  _iniciaisDias(l10nModal)[index],
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: selecionado ? Colors.white : Colors.black54,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: etiquetaController,
                        decoration: InputDecoration(
                          labelText: l10nModal.familiaEtiquetaLabel,
                          hintText: l10nModal.familiaEtiquetaHint,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          prefixIcon: const Icon(Icons.label_outline),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: contextoController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: l10nModal.familiaDicaContextoOpcionalLabel,
                          hintText: l10nModal.familiaDicaContextoOpcionalHint,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          prefixIcon: const Icon(Icons.edit_note),
                          helperText: l10nModal.familiaDicaContextoHelper,
                          helperMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Icon(Icons.timer_outlined, color: Colors.grey, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10nModal.familiaToleranciaLabel,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                          DropdownButton<int>(
                            value: minutosTolerancia,
                            items: const [5, 10, 15, 20, 30, 45, 60]
                                .map((minutos) => DropdownMenuItem(
                                      value: minutos,
                                      child: Text(l10nModal.familiaMinutosAbrev(minutos)),
                                    ))
                                .toList(),
                            onChanged: (valor) {
                              if (valor != null) setModalState(() => minutosTolerancia = valor);
                            },
                          ),
                        ],
                      ),
                      if (erroValidacao != null) ...[
                        const SizedBox(height: 12),
                        Text(erroValidacao!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF4C7040),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () async {
                            // Pelo menos um dia — ou, se for único, um
                            // horário futuro hoje.
                            if (diasSelecionados.isEmpty) {
                              final agora = DateTime.now();
                              final hoje = DateTime(agora.year, agora.month, agora.day,
                                  horaSelecionada, minutoSelecionado);
                              if (!hoje.isAfter(agora)) {
                                setModalState(() => erroValidacao = l10nModal.familiaHorarioPassado);
                                return;
                              }
                            }
                            if (!await garantirRecursoLiberadoOuExibirUpsell(ctx)) return;
                            if (!ctx.mounted) return;

                            final etiqueta = etiquetaController.text.trim();
                            final alarme = AlarmeRotina(
                              id: alarmeExistente?.id,
                              hora: horaSelecionada,
                              minuto: minutoSelecionado,
                              diasSemana: diasSelecionados,
                              ativo: alarmeExistente?.ativo ?? true,
                              // Chave neutra quando vazio (só no SQLite:
                              // nunca vai para a nuvem/contatos).
                              etiqueta: etiqueta.isNotEmpty ? etiqueta : AlarmeRotina.chaveEtiquetaPadrao,
                              contextoPersonalizado: contextoController.text.trim(),
                              minutosTolerancia: minutosTolerancia,
                              ultimoDisparoEpoch: alarmeExistente?.ultimoDisparoEpoch,
                              // Editar um despertador pausado NÃO o despausa.
                              pausadoEm: alarmeExistente?.pausadoEm,
                            );

                            int idSalvo;
                            if (alarmeExistente == null) {
                              idSalvo = await _db.inserirAlarme(alarme.toMap());
                            } else {
                              idSalvo = alarmeExistente.id!;
                              await _db.atualizarAlarme(alarme.toMap());
                            }
                            final descricao = l10nModal.historicoAlarmeCriadoEditadoDescricao(
                              alarme.etiquetaExibida(l10nModal),
                              alarme.horarioFormatado,
                              alarme.diasResumidos(l10nModal),
                            );
                            await _registrarHistorico(
                              alarmeExistente == null
                                  ? l10nModal.historicoAlarmeCriadoTitulo
                                  : l10nModal.historicoAlarmeEditadoTitulo,
                              descricao,
                            );

                            final dadosSalvos = await _db.buscarAlarmePorId(idSalvo);
                            if (dadosSalvos != null) await RotinaAlarmeService.agendarAlarme(dadosSalvos);

                            if (ctx.mounted) Navigator.of(ctx).pop();
                            await _carregarAlarmes();
                            await _verificarPermissoesDoDespertador();
                          },
                          icon: const Icon(Icons.check, color: Colors.white),
                          label: Text(
                            l10nModal.familiaSalvarAlarme,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _seletor({
    required String rotulo,
    required int quantidade,
    required int inicial,
    required ValueChanged<int> aoMudar,
  }) {
    return Column(
      children: [
        Text(rotulo, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
        SizedBox(
          width: 70,
          height: 110,
          child: CupertinoPicker(
            itemExtent: 36,
            scrollController: FixedExtentScrollController(initialItem: inicial),
            onSelectedItemChanged: aoMudar,
            children: List.generate(
              quantidade,
              (index) => Center(
                child: Text(
                  index.toString().padLeft(2, '0'),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ValueListenableBuilder<String>(
        valueListenable: WallpaperService.wallpaperNotifier,
        builder: (context, fundoAtivo, _) {
          return Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              image: DecorationImage(image: AssetImage(fundoAtivo), fit: BoxFit.cover),
            ),
            child: SafeArea(
              child: RefreshIndicator(
                onRefresh: () async {
                  await _carregarAlarmes();
                  await _carregarContatosEmergencia();
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.alarm, color: Color(0xFF4C7040), size: 28),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            AppLocalizations.of(context)!.familiaAlarmesRotinaTitulo,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (!_carregandoContatos && !FamiliaTab.temContatosNotifier.value) ...[
                      _construirAvisoSemContato(),
                      const SizedBox(height: 16),
                    ],
                    _construirListaAlarmes(),
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 8),
                    _construirCardContatosEmergencia(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _construirAvisoSemContato() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.shade300),
      ),
      child: Row(
        children: [
          Icon(Icons.contact_emergency, color: Colors.orange.shade800),
          const SizedBox(width: 10),
          Expanded(child: Text(l10n.familiaCadastreContatoAviso, style: const TextStyle(fontWeight: FontWeight.w600))),
          TextButton(
            onPressed: () => abrirConfiguracoesDoApp(context),
            child: Text(l10n.abrirConfiguracoes),
          ),
        ],
      ),
    );
  }

  Widget _construirListaAlarmes() {
    if (_carregandoAlarmes) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final l10n = AppLocalizations.of(context)!;
    if (_alarmes.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          children: [
            Icon(Icons.alarm_off, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(l10n.familiaNenhumAlarme,
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
          ],
        ),
      );
    }

    return Column(
      children: _alarmes.map((alarme) {
        final pausadoHoje = alarme.pausado;
        return Dismissible(
          key: ValueKey('alarme_dismiss_${alarme.id}'),
          direction: pausadoHoje ? DismissDirection.endToStart : DismissDirection.horizontal,
          // O arrastar continua, com o MESMO PIN dos botões; a ação só
          // acontece depois do PIN (nunca remove o card antes).
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.endToStart) {
              await _apagarComPin(alarme);
            } else if (!pausadoHoje) {
              await _pausarComPin(alarme);
            }
            return false;
          },
          background: _fundoArraste(Colors.blue.shade600, Icons.pause_circle_filled, l10n.familiaPausarPorHoje, Alignment.centerLeft),
          secondaryBackground:
              _fundoArraste(Colors.red.shade600, Icons.delete, l10n.familiaExcluirPermanente, Alignment.centerRight),
          child: Card(
            elevation: 0,
            color: pausadoHoje ? Colors.amber.shade50.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.92),
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: pausadoHoje ? Colors.amber.shade300 : Colors.grey.shade200,
                width: pausadoHoje ? 1.5 : 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onLongPress: () async {
                if (await _confirmarComPin()) _abrirModalAlarme(alarmeExistente: alarme);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: _conteudoCard(alarme, pausadoHoje, l10n)),
                        Switch(
                          activeThumbColor: const Color(0xFF4C7040),
                          value: pausadoHoje ? false : alarme.ativo,
                          onChanged: (ativo) =>
                              pausadoHoje && ativo ? _despausarAlarmeManual(alarme) : _alternarAtivo(alarme, ativo),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (!pausadoHoje && alarme.ativo)
                          TextButton.icon(
                            onPressed: () => _pausarComPin(alarme),
                            icon: const Icon(Icons.pause_circle_outline, size: 18),
                            label: Text(l10n.familiaPausarBotao),
                          ),
                        TextButton.icon(
                          style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                          onPressed: () => _apagarComPin(alarme),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: Text(l10n.familiaBotaoApagar),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _fundoArraste(Color cor, IconData icone, String texto, Alignment alinhamento) {
    return Container(
      alignment: alinhamento,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: cor, borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisAlignment: alinhamento == Alignment.centerLeft ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          Icon(icone, color: Colors.white),
          const SizedBox(width: 8),
          Text(texto, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _conteudoCard(AlarmeRotina alarme, bool pausadoHoje, AppLocalizations l10n) {
    if (pausadoHoje) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pause_circle_filled, color: Colors.amber.shade800, size: 22),
              const SizedBox(width: 6),
              Text(l10n.familiaPausadoAte0000,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.amber.shade800)),
            ],
          ),
          const SizedBox(height: 2),
          Text(_textoRetorno(alarme, l10n),
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade800)),
          const SizedBox(height: 2),
          Text(alarme.etiquetaExibida(l10n), style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(height: 6),
          InkWell(
            onTap: () => _despausarAlarmeManual(alarme),
            child: Text(l10n.familiaToqueReativar,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.blue.shade700)),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(alarme.horarioFormatado,
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: alarme.ativo ? Colors.black87 : Colors.grey)),
        Text(alarme.diasResumidos(l10n),
            style: TextStyle(color: alarme.ativo ? Colors.grey.shade800 : Colors.grey.shade400, fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(alarme.etiquetaExibida(l10n), style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        Text(l10n.familiaMinutosAbrev(alarme.minutosTolerancia),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      ],
    );
  }

  Widget _construirCardContatosEmergencia() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.contact_emergency, color: Color(0xFF4C7040)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  l10n.familiaContatosEmergenciaTitulo,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(l10n.familiaContatosEmergenciaDescricao, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(height: 12),
          if (_carregandoContatos)
            const Center(child: CircularProgressIndicator())
          else if (_contatosEmergencia.isEmpty)
            Text(l10n.familiaNenhumContato, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))
          else
            Column(
              children: _contatosEmergencia.map((contato) {
                final nome = contato['nome'] as String? ?? l10n.familiaSemNome;
                final telefone = contato['telefone'] as String? ?? '';
                final pendente = _isExclusaoPendente(contato);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(0xFFE8F5E9),
                        child: Text(
                          nome.isNotEmpty ? nome[0].toUpperCase() : '?',
                          style: const TextStyle(color: Color(0xFF4C7040), fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(nome,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            Text(
                              pendente ? l10n.familiaRemovendoEmCarencia : telefone,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: pendente ? Colors.orange.shade800 : Colors.black54,
                                fontWeight: pendente ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (pendente) const Icon(Icons.hourglass_bottom, color: Colors.orange, size: 18),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}
