import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';

/// Tela de Histórico Geral: lê os eventos reais gravados no banco de
/// dados (tabela 'historico') e os exibe organizados por categoria
/// administrativa ('seguranca', 'familia', 'sistema'), de forma 100%
/// transparente para o usuário do aplicativo.
///
/// Regra de negócio de privacidade/blindagem: os registros da categoria
/// 'critico' (alarmes de emergência e disparos de SMS de socorro) NUNCA
/// aparecem nesta tela — a exclusão é garantida diretamente na query
/// [DatabaseHelper.getHistorico], que filtra essa categoria na origem,
/// independentemente do filtro rápido selecionado pelo usuário. Esses
/// eventos são isolados exclusivamente na tela de Auditoria de Eventos
/// Sensíveis (ícone superior direito), protegida pela trava de segurança
/// de 3 horas.

class HistoricoTab extends StatefulWidget {
  const HistoricoTab({super.key});

  @override
  State<HistoricoTab> createState() => _HistoricoTabState();
}

class _HistoricoTabState extends State<HistoricoTab> {
  final DatabaseHelper _dbHelper = DatabaseHelper();

  // Filtro rápido selecionado no topo (chave interna neutra, independente
  // do idioma — o rótulo exibido é traduzido separadamente em
  // [_rotuloFiltro]). 'todos' por padrão.
  String _filtroSelecionado = 'todos';

  final List<String> _filtros = const ['todos', 'seguranca', 'familia', 'sistema'];

  /// Rótulo traduzido exibido no chip do filtro [chave].
  String _rotuloFiltro(String chave) {
    final l10n = AppLocalizations.of(context)!;
    switch (chave) {
      case 'seguranca':
        return l10n.tabSeguranca;
      case 'familia':
        return l10n.tabFamilia;
      case 'sistema':
        return l10n.historicoFiltroSistema;
      case 'todos':
      default:
        return l10n.historicoFiltroTodos;
    }
  }

  bool _carregando = true;
  List<Map<String, dynamic>> _eventos = [];

  @override
  void initState() {
    super.initState();
    _carregarHistorico();
  }

  Future<void> _carregarHistorico() async {
    final eventos = await _dbHelper.getHistorico();
    if (!mounted) return;
    setState(() {
      _eventos = eventos;
      _carregando = false;
    });
  }

  List<Map<String, dynamic>> get _eventosFiltrados {
    switch (_filtroSelecionado) {
      case 'seguranca':
        return _eventos.where((e) => e['categoria'] == 'seguranca').toList();
      case 'familia':
        return _eventos.where((e) => e['categoria'] == 'familia').toList();
      case 'sistema':
        return _eventos.where((e) => e['categoria'] == 'sistema').toList();
      case 'todos':
      default:
        return _eventos;
    }
  }

  Color _corCategoria(String categoria) {
    switch (categoria) {
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

  IconData _iconeCategoria(String categoria) {
    switch (categoria) {
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
      _eventos.removeWhere((e) => e['id'] == id);
    });
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
                const SizedBox(height: 8),
                Expanded(
                  child: _carregando
                      ? const Center(child: CircularProgressIndicator())
                      : _eventosFiltrados.isEmpty
                          ? _construirEstadoVazio()
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                              itemCount: _eventosFiltrados.length,
                              itemBuilder: (context, index) {
                                final evento = _eventosFiltrados[index];
                                final isUltimo = index == _eventosFiltrados.length - 1;
                                return _construirCardTimeline(evento, isUltimo);
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

  Widget _construirCardTimeline(Map<String, dynamic> evento, bool isUltimo) {
    final categoria = evento['categoria'] as String? ?? 'sistema';
    final cor = _corCategoria(categoria);
    final icone = _iconeCategoria(categoria);
    final titulo = evento['titulo'] as String? ?? '';
    final descricao = evento['descricao'] as String? ?? '';
    final timestamp = evento['timestamp'] as String? ?? '';
    final id = evento['id'] as int;

    return Dismissible(
      key: ValueKey(id),
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
      onDismissed: (_) => _excluirEvento(id),
      child: IntrinsicHeight(
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
                    border: Border.all(color: Colors.white.withOpacity(0.4)),
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
                                  Expanded(
                                    child: Text(
                                      titulo,
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
                                      _formatarDataHora(timestamp),
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
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                descricao,
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
      ),
    );
  }
}
