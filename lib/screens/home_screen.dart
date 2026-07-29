import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'tabs/seguranca_tab.dart';
import 'tabs/familia_tab.dart';
import 'tabs/monitoramento_tab.dart';
import 'tabs/historico_tab.dart';
import 'tabs/configuracoes_tab.dart';
import 'auditoria_sensivel_screen.dart';


class HomeScreen extends StatefulWidget {
  /// Índice da aba exibida ao abrir esta tela — usado para abrir
  /// diretamente na aba Monitoramento (índice 2) ao tocar numa
  /// notificação de push de solicitação/resposta de localização (ver
  /// NotificacaoService.exibirNotificacaoMonitoramento). `0` (Segurança)
  /// no fluxo normal de login/cold start.
  final int abaInicial;

  const HomeScreen({super.key, this.abaInicial = 0});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _indiceAbaAtual = widget.abaInicial;

  // GlobalKey usada para acionar, a partir do AppBar global (botão "+"),
  // o modal de "Adicionar Alarme" definido dentro da FamiliaTab.
  final GlobalKey<FamiliaTabState> _familiaTabKey = GlobalKey<FamiliaTabState>();

  // GlobalKey usada para acionar, a partir do AppBar global (botão "+"),
  // o modal de "Adicionar Contato" definido dentro da MonitoramentoTab —
  // mesmo padrão de [_familiaTabKey].
  final GlobalKey<MonitoramentoTabState> _monitoramentoTabKey =
      GlobalKey<MonitoramentoTabState>();

  // Ordem exata das abas: Segurança, Família, Monitoramento, Histórico
  late final List<Widget> _telas = [
    const SegurancaTab(),
    FamiliaTab(key: _familiaTabKey),
    MonitoramentoTab(key: _monitoramentoTabKey),
    const HistoricoTab(),
  ];


  List<String> _titulos(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return [l10n.tabSeguranca, l10n.tabFamilia, l10n.tabMonitoramento, l10n.tabHistorico];
  }

  void _aoSelecionarAba(int indice) {
    setState(() {
      _indiceAbaAtual = indice;
    });
  }

  void _abrirConfiguracoes(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(AppLocalizations.of(context)!.appTituloConfiguracoes),
          ),
          body: const ConfiguracoesTab(),
        ),
      ),
    );
  }

  /// Abre a tela de Auditoria de Eventos Sensíveis, protegida pela trava
  /// de segurança temporal de 3 horas (ver AuditoriaSensivelScreen).
  void _abrirAuditoriaSensivel(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const AuditoriaSensivelScreen(),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final titulos = _titulos(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(titulos[_indiceAbaAtual], style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (_indiceAbaAtual == 1)
            IconButton(
              icon: const Icon(Icons.add_alarm),
              tooltip: l10n.tooltipAdicionarAlarme,
              onPressed: () => _familiaTabKey.currentState?.abrirModalAdicionarAlarme(),
            ),
          if (_indiceAbaAtual == 2)
            IconButton(
              icon: const Icon(Icons.person_add_alt_1),
              tooltip: l10n.monitoramentoAdicionarContato,
              onPressed: () => _monitoramentoTabKey.currentState?.abrirModalAdicionarContato(),
            ),
          if (_indiceAbaAtual == 3)
            IconButton(
              icon: const Icon(Icons.privacy_tip_outlined),
              tooltip: l10n.tooltipAuditoriaSensivel,
              onPressed: () => _abrirAuditoriaSensivel(context),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _abrirConfiguracoes(context),
          ),
        ],
      ),


      body: IndexedStack(
        index: _indiceAbaAtual,
        children: _telas,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _indiceAbaAtual,
        onTap: _aoSelecionarAba,
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.shield),
            label: l10n.tabSeguranca,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.people),
            label: l10n.tabFamilia,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.location_on_outlined),
            label: l10n.tabMonitoramento,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.history),
            label: l10n.tabHistorico,
          ),
        ],
      ),
    );
  }
}
