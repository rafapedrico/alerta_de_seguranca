import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/alertas_recebidos_service.dart';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';
import '../alerta_recebido_screen.dart';

/// Tela de Histórico Geral: mescla os eventos administrativos locais
/// (tabela 'historico') com os alertas de emergência de TERCEIROS
/// recebidos via Push FCM (tabela 'alertas_terceiros_recebidos', ver
/// [AlertasRecebidosService]/`FcmService`), organizados numa única linha
/// do tempo.
///
/// Alertas recebidos são clicáveis (item 5 do pedido de UX do
/// guardião): um alerta de FOTO abre [AlertaRecebidoScreen] (imagem
/// carregada + Baixar/Compartilhar); um alerta de LOCALIZAÇÃO abre
/// direto o app de mapas do aparelho.
///
/// Regra de negócio de privacidade/blindagem (inalterada): os registros
/// LOCAIS da categoria 'critico' (alarmes de emergência e disparos de
/// SMS de socorro do PRÓPRIO usuário) NUNCA aparecem nesta tela — só na
/// tela de Auditoria de Eventos Sensíveis. Isso é ortogonal aos alertas
/// de TERCEIROS recebidos (sempre exibidos aqui), que são o alerta de
/// OUTRA pessoa, não um evento sensível do próprio usuário.
class HistoricoTab extends StatefulWidget {
  const HistoricoTab({super.key});

  @override
  State<HistoricoTab> createState() => _HistoricoTabState();
}

/// Item normalizado da linha do tempo — une as duas fontes de dados
/// (evento local administrativo vs. alerta de terceiro recebido) atrás
/// de um único formato para a UI, sem misturar os esquemas das duas
/// tabelas de origem.
class _ItemHistorico {
  const _ItemHistorico({
    required this.ehAlertaRecebido,
    required this.id,
    required this.titulo,
    required this.descricao,
    required this.categoria,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.fotoUrl,
    this.idEntrega,
    this.nomeRemetente,
    this.mensagemOriginal,
    this.visualizado = true,
  });

  final bool ehAlertaRecebido;
  final int id;
  final String titulo;
  final String descricao;
  final String categoria;
  final String timestamp;
  final double? latitude;
  final double? longitude;
  final String? fotoUrl;
  final String? idEntrega;
  final String? nomeRemetente;
  final String? mensagemOriginal;
  final bool visualizado;

  bool get ehFoto => fotoUrl != null && fotoUrl!.isNotEmpty;
}

class _HistoricoTabState extends State<HistoricoTab> {
  final DatabaseHelper _dbHelper = DatabaseHelper();

  static const String _categoriaRecebido = 'alerta_recebido';

  // Filtro rápido selecionado no topo (chave interna neutra, independente
  // do idioma — o rótulo exibido é traduzido separadamente em
  // [_rotuloFiltro]). 'todos' por padrão.
  String _filtroSelecionado = 'todos';

  // EXATAMENTE três filtros (pedido de UX): "Todos" (mensagens diversas
  // de agendamentos — eventos locais das abas Segurança/Família não têm
  // mais filtro próprio, mas continuam aparecendo aqui), "Alerta de
  // segurança recebido" (localização/foto de terceiros) e "Sistema"
  // (alterações feitas em Configurações). A categoria 'critico' nunca
  // aparece aqui em nenhum filtro — exclusiva da AuditoriaSensivelScreen.
  final List<String> _filtros = const [
    'todos',
    _categoriaRecebido,
    'sistema',
  ];

  /// Rótulo traduzido exibido no chip do filtro [chave].
  String _rotuloFiltro(String chave) {
    final l10n = AppLocalizations.of(context)!;
    switch (chave) {
      case 'sistema':
        return l10n.historicoFiltroSistema;
      case _categoriaRecebido:
        return l10n.alertaRecebidoTitulo;
      case 'todos':
      default:
        return l10n.historicoFiltroTodos;
    }
  }

  bool _carregando = true;
  List<_ItemHistorico> _itens = [];

  @override
  void initState() {
    super.initState();
    _carregarHistorico();
  }

  Future<void> _carregarHistorico() async {
    final eventosLocais = await _dbHelper.getHistorico();
    final alertasRecebidos = await _dbHelper.getAlertasTerceirosRecebidos();

    final itens = <_ItemHistorico>[
      ...eventosLocais.map((e) => _ItemHistorico(
            ehAlertaRecebido: false,
            id: e['id'] as int,
            titulo: e['titulo'] as String? ?? '',
            descricao: e['descricao'] as String? ?? '',
            categoria: e['categoria'] as String? ?? 'sistema',
            timestamp: e['timestamp'] as String? ?? '',
          )),
      ...alertasRecebidos.map((a) {
        final fotoUrl = a['foto_url'] as String?;
        final nomeRemetente = a['nome_remetente'] as String?;
        final ehFoto = fotoUrl != null && fotoUrl.isNotEmpty;
        return _ItemHistorico(
          ehAlertaRecebido: true,
          id: a['id'] as int,
          titulo: nomeRemetente != null && nomeRemetente.isNotEmpty
              ? nomeRemetente
              : AppLocalizations.of(context)!.alertaRecebidoTitulo,
          descricao: ehFoto
              ? AppLocalizations.of(context)!.alertaRecebidoBaixarFoto
              : (a['mensagem'] as String? ?? ''),
          categoria: _categoriaRecebido,
          timestamp: a['recebido_em'] as String? ?? '',
          latitude: (a['latitude'] as num?)?.toDouble(),
          longitude: (a['longitude'] as num?)?.toDouble(),
          fotoUrl: fotoUrl,
          idEntrega: a['id_entrega'] as String?,
          nomeRemetente: nomeRemetente,
          mensagemOriginal: a['mensagem'] as String?,
          visualizado: (a['visualizado'] as int? ?? 0) == 1,
        );
      }),
    ];

    itens.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    if (!mounted) return;
    setState(() {
      _itens = itens;
      _carregando = false;
    });
  }

  List<_ItemHistorico> get _itensFiltrados {
    if (_filtroSelecionado == 'todos') return _itens;
    return _itens.where((e) => e.categoria == _filtroSelecionado).toList();
  }

  Color _corCategoria(String categoria) {
    switch (categoria) {
      case _categoriaRecebido:
        return Colors.deepOrange;
      case 'seguranca':
        return Colors.redAccent;
      case 'familia':
        return Colors.blueAccent;
      case 'sistema':
        return Colors.green.shade600;
      default:
        return Colors.grey;
    }
  }

  IconData _iconeItem(_ItemHistorico item) {
    if (item.ehAlertaRecebido) {
      return item.ehFoto ? Icons.photo_camera : Icons.location_on;
    }
    switch (item.categoria) {
      case 'seguranca':
        return Icons.shield_outlined;
      case 'familia':
        return Icons.people_alt;
      case 'sistema':
        return Icons.settings_suggest;
      default:
        return Icons.event_note;
    }
  }

  String _formatarDataHora(String timestampIso) {
    final dataHora = DateTime.tryParse(timestampIso);
    if (dataHora == null) return '';

    final agora = DateTime.now();
    final diferenca = agora.difference(dataHora);

    final l10n = AppLocalizations.of(context)!;
    if (diferenca.inMinutes < 1) return l10n.historicoAgoraMesmo;
    if (diferenca.inMinutes < 60) return l10n.historicoHaMinutos(diferenca.inMinutes);
    if (diferenca.inHours < 24) return l10n.historicoHaHoras(diferenca.inHours);
    if (diferenca.inDays == 1) return l10n.historicoOntem;
    return l10n.historicoHaDias(diferenca.inDays);
  }

  Future<void> _excluirEvento(int id) async {
    await _dbHelper.deletarEventoHistorico(id);
    if (!mounted) return;
    setState(() {
      _itens.removeWhere((e) => !e.ehAlertaRecebido && e.id == id);
    });
  }

  /// Exclui um alerta de TERCEIRO recebido pelo gesto de swipe — item
  /// separado de [_excluirEvento] pois vive numa tabela diferente.
  Future<void> _excluirAlertaRecebido(int id) async {
    await _dbHelper.deletarAlertaTerceiroRecebido(id);
    if (!mounted) return;
    setState(() {
      _itens.removeWhere((e) => e.ehAlertaRecebido && e.id == id);
    });
    await AlertasRecebidosService.atualizarContagem();
  }

  /// Exibe a confirmação e, se aceita, apaga TODAS as mensagens da
  /// categoria atualmente em exibição (filtro selecionado) de uma vez —
  /// opção "Limpar Histórico" pedida no topo de cada filtro.
  void _confirmarLimparHistoricoAtual() {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.historicoLimparConfirmarTitulo),
        content: Text(l10n.historicoLimparConfirmarConteudo, softWrap: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancelar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _limparHistoricoAtual();
            },
            child: Text(l10n.historicoLimparBotao),
          ),
        ],
      ),
    );
  }

  Future<void> _limparHistoricoAtual() async {
    switch (_filtroSelecionado) {
      case _categoriaRecebido:
        await _dbHelper.limparAlertasTerceirosRecebidos();
        break;
      case 'sistema':
        await _dbHelper.limparHistoricoPorCategoria('sistema');
        break;
      case 'todos':
      default:
        await _dbHelper.limparHistoricoGeral();
        await _dbHelper.limparAlertasTerceirosRecebidos();
    }
    await AlertasRecebidosService.atualizarContagem();
    if (!mounted) return;
    await _carregarHistorico();
  }

  /// Roteamento do toque em um alerta de TERCEIRO recebido (item 5 do
  /// pedido de UX): foto -> abre [AlertaRecebidoScreen] (imagem +
  /// Baixar/Compartilhar); localização -> abre direto o app de mapas do
  /// aparelho. Marca como visualizado em ambos os casos.
  Future<void> _abrirAlertaRecebido(_ItemHistorico item) async {
    if (item.idEntrega != null && item.idEntrega!.isNotEmpty) {
      await AlertasRecebidosService.marcarVisualizadoPorIdEntrega(item.idEntrega!);
    } else {
      await AlertasRecebidosService.marcarVisualizado(item.id);
    }
    if (!item.visualizado && mounted) {
      setState(() {
        _itens = _itens
            .map((e) => e.id == item.id && e.ehAlertaRecebido
                ? _ItemHistorico(
                    ehAlertaRecebido: e.ehAlertaRecebido,
                    id: e.id,
                    titulo: e.titulo,
                    descricao: e.descricao,
                    categoria: e.categoria,
                    timestamp: e.timestamp,
                    latitude: e.latitude,
                    longitude: e.longitude,
                    fotoUrl: e.fotoUrl,
                    idEntrega: e.idEntrega,
                    nomeRemetente: e.nomeRemetente,
                    mensagemOriginal: e.mensagemOriginal,
                    visualizado: true,
                  )
                : e)
            .toList();
      });
    }

    if (!mounted) return;

    if (item.ehFoto) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AlertaRecebidoScreen(
            mensagem: item.mensagemOriginal ?? item.descricao,
            nomeRemetente: item.nomeRemetente,
            latitude: item.latitude,
            longitude: item.longitude,
            fotoUrl: item.fotoUrl,
            idEntrega: item.idEntrega,
          ),
        ),
      );
      return;
    }

    if (item.latitude != null && item.longitude != null) {
      final uri = Uri.parse('https://maps.google.com/?q=${item.latitude},${item.longitude}');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
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
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 8),
                _construirFiltrosRapidos(),
                if (!_carregando && _itensFiltrados.isNotEmpty) _construirBotaoLimpar(),
                const SizedBox(height: 8),
                Expanded(
                  child: _carregando
                      ? const Center(child: CircularProgressIndicator())
                      : _itensFiltrados.isEmpty
                          ? _construirEstadoVazio()
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                              itemCount: _itensFiltrados.length,
                              itemBuilder: (context, index) {
                                final item = _itensFiltrados[index];
                                final isUltimo = index == _itensFiltrados.length - 1;
                                return _construirCardTimeline(item, isUltimo);
                              },
                            ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Botão "Limpar Histórico" — apaga de uma vez todas as mensagens da
  /// categoria/filtro atualmente em exibição (pedido de UX).
  Widget _construirBotaoLimpar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _confirmarLimparHistoricoAtual,
          icon: const Icon(Icons.delete_sweep_outlined, size: 18, color: Colors.redAccent),
          label: Text(
            AppLocalizations.of(context)!.historicoLimparBotao,
            style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget _construirFiltrosRapidos() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _filtros.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filtro = _filtros[index];
          final selecionado = _filtroSelecionado == filtro;
          return FilterChip(
            label: Text(
              _rotuloFiltro(filtro),
              softWrap: true,
              overflow: TextOverflow.clip,
              style: TextStyle(
                color: selecionado ? Colors.white : Colors.black87,
                fontWeight: selecionado ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            selected: selecionado,
            onSelected: (_) => setState(() => _filtroSelecionado = filtro),
            selectedColor: const Color(0xFF4C7040),
            backgroundColor: Colors.white.withOpacity(0.85),
            checkmarkColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: selecionado ? const Color(0xFF4C7040) : Colors.grey.shade300),
            ),
          );
        },
      ),
    );
  }

  Widget _construirEstadoVazio() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Flexible(
              child: Text(
                AppLocalizations.of(context)!.historicoNenhumEvento,
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _construirCardTimeline(_ItemHistorico item, bool isUltimo) {
    final cor = _corCategoria(item.categoria);
    final icone = _iconeItem(item);

    final conteudoCard = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Coluna da linha do tempo: ícone + linha vertical sutil.
          Column(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cor.withOpacity(0.15),
                  border: Border.all(color: cor, width: 1.5),
                ),
                child: Icon(icone, color: cor, size: 18),
              ),
              if (!isUltimo)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: Colors.grey.withOpacity(0.35),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          // Card de conteúdo do evento.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: item.ehAlertaRecebido && !item.visualizado
                        ? cor
                        : Colors.white.withOpacity(0.4),
                    width: item.ehAlertaRecebido && !item.visualizado ? 2 : 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Barra lateral de categoria.
                    Container(
                      width: 5,
                      decoration: BoxDecoration(
                        color: cor,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(14),
                          bottomLeft: Radius.circular(14),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (item.ehAlertaRecebido && !item.visualizado)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6, top: 4),
                                    child: Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(shape: BoxShape.circle, color: cor),
                                    ),
                                  ),
                                Expanded(
                                  child: Text(
                                    item.titulo,
                                    softWrap: true,
                                    overflow: TextOverflow.clip,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    _formatarDataHora(item.timestamp),
                                    textAlign: TextAlign.right,
                                    softWrap: true,
                                    overflow: TextOverflow.clip,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (item.ehAlertaRecebido)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Icon(Icons.chevron_right, color: Colors.grey.shade700, size: 18),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.descricao,
                              softWrap: true,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.black.withOpacity(0.75),
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
          ),
        ],
      ),
    );

    // Alertas recebidos (item 5) são clicáveis, abrindo o mapa/a foto —
    // envolvido pelo Dismissible comum abaixo para também poderem ser
    // excluídos por swipe (pedido de UX), cada um na sua própria tabela.
    final conteudoComToque = item.ehAlertaRecebido
        ? InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _abrirAlertaRecebido(item),
            child: conteudoCard,
          )
        : conteudoCard;

    return Dismissible(
      key: ValueKey('${item.ehAlertaRecebido ? "recebido" : "local"}_${item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 16, left: 48),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) =>
          item.ehAlertaRecebido ? _excluirAlertaRecebido(item.id) : _excluirEvento(item.id),
      child: conteudoComToque,
    );
  }
}
