import 'package:flutter/material.dart';
import '../../services/wallpaper_service.dart';

/// Categorias usadas tanto para os filtros rápidos quanto para
/// classificar cada evento do histórico.
enum _CategoriaEvento { critico, familia, sistema }

/// Nível de gravidade de cada evento, usado para colorir a barra
/// lateral e escolher o ícone indicativo do card.
enum _GravidadeEvento { alta, media, baixa }

class _EventoHistorico {
  final String titulo;
  final String descricao;
  final DateTime dataHora;
  final _CategoriaEvento categoria;
  final _GravidadeEvento gravidade;
  final IconData icone;

  const _EventoHistorico({
    required this.titulo,
    required this.descricao,
    required this.dataHora,
    required this.categoria,
    required this.gravidade,
    required this.icone,
  });
}

class HistoricoTab extends StatefulWidget {
  const HistoricoTab({super.key});

  @override
  State<HistoricoTab> createState() => _HistoricoTabState();
}

class _HistoricoTabState extends State<HistoricoTab> {
  // Filtro rápido selecionado no topo. 'Todos' por padrão.
  String _filtroSelecionado = 'Todos';

  final List<String> _filtros = const ['Todos', 'Críticos', 'Família', 'Sistema'];

  // Dados fictícios (mock) já ordenados do mais recente para o mais antigo.
  late final List<_EventoHistorico> _eventos = [
    _EventoHistorico(
      titulo: 'Alerta de emergência disparado',
      descricao: 'Check-in não realizado dentro do tempo de tolerância. Contatos de emergência notificados.',
      dataHora: DateTime.now().subtract(const Duration(minutes: 12)),
      categoria: _CategoriaEvento.critico,
      gravidade: _GravidadeEvento.alta,
      icone: Icons.warning_amber_rounded,
    ),
    _EventoHistorico(
      titulo: 'Check-in de Segurança concluído',
      descricao: 'PIN correto informado. Rotina desarmada com sucesso.',
      dataHora: DateTime.now().subtract(const Duration(hours: 1, minutes: 5)),
      categoria: _CategoriaEvento.sistema,
      gravidade: _GravidadeEvento.baixa,
      icone: Icons.check_circle,
    ),
    _EventoHistorico(
      titulo: 'Rotina em Família atualizada',
      descricao: 'Horário fixo de rotina alterado para 23:45, de segunda a sexta-feira.',
      dataHora: DateTime.now().subtract(const Duration(hours: 3)),
      categoria: _CategoriaEvento.familia,
      gravidade: _GravidadeEvento.baixa,
      icone: Icons.people_alt,
    ),
    _EventoHistorico(
      titulo: 'Tentativa de PIN incorreta',
      descricao: 'Um PIN inválido foi digitado durante o bloqueio de segurança.',
      dataHora: DateTime.now().subtract(const Duration(hours: 5, minutes: 30)),
      categoria: _CategoriaEvento.critico,
      gravidade: _GravidadeEvento.media,
      icone: Icons.lock_outline,
    ),
    _EventoHistorico(
      titulo: 'Novo contato de emergência cadastrado',
      descricao: 'Mamãe foi adicionada como contato de emergência número 1.',
      dataHora: DateTime.now().subtract(const Duration(hours: 8)),
      categoria: _CategoriaEvento.familia,
      gravidade: _GravidadeEvento.baixa,
      icone: Icons.contact_phone,
    ),
    _EventoHistorico(
      titulo: 'Plano de fundo alterado',
      descricao: 'O tema visual do aplicativo foi atualizado para "Verde Botânico".',
      dataHora: DateTime.now().subtract(const Duration(days: 1, hours: 2)),
      categoria: _CategoriaEvento.sistema,
      gravidade: _GravidadeEvento.baixa,
      icone: Icons.wallpaper,
    ),
    _EventoHistorico(
      titulo: 'Alarme reiniciado automaticamente',
      descricao: 'O timer de rotina foi reiniciado após o horário programado.',
      dataHora: DateTime.now().subtract(const Duration(days: 1, hours: 6)),
      categoria: _CategoriaEvento.sistema,
      gravidade: _GravidadeEvento.media,
      icone: Icons.refresh,
    ),
    _EventoHistorico(
      titulo: 'Envio para contato (Mamãe)',
      descricao: 'Mensagem de contingência enviada com sucesso via WhatsApp.',
      dataHora: DateTime.now().subtract(const Duration(days: 2)),
      categoria: _CategoriaEvento.familia,
      gravidade: _GravidadeEvento.media,
      icone: Icons.send,
    ),
  ]..sort((a, b) => b.dataHora.compareTo(a.dataHora));

  List<_EventoHistorico> get _eventosFiltrados {
    switch (_filtroSelecionado) {
      case 'Críticos':
        return _eventos.where((e) => e.categoria == _CategoriaEvento.critico).toList();
      case 'Família':
        return _eventos.where((e) => e.categoria == _CategoriaEvento.familia).toList();
      case 'Sistema':
        return _eventos.where((e) => e.categoria == _CategoriaEvento.sistema).toList();
      case 'Todos':
      default:
        return _eventos;
    }
  }

  Color _corGravidade(_GravidadeEvento gravidade) {
    switch (gravidade) {
      case _GravidadeEvento.alta:
        return Colors.redAccent;
      case _GravidadeEvento.media:
        return Colors.amber.shade700;
      case _GravidadeEvento.baixa:
        return Colors.green.shade600;
    }
  }

  String _formatarDataHora(DateTime dataHora) {
    final agora = DateTime.now();
    final diferenca = agora.difference(dataHora);

    if (diferenca.inMinutes < 1) return 'Agora mesmo';
    if (diferenca.inMinutes < 60) return 'Há ${diferenca.inMinutes} min';
    if (diferenca.inHours < 24) return 'Há ${diferenca.inHours}h';
    if (diferenca.inDays == 1) return 'Ontem';
    return 'Há ${diferenca.inDays} dias';
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
                  child: _eventosFiltrados.isEmpty
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
              filtro,
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
                'Nenhum evento encontrado para este filtro.',
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

  Widget _construirCardTimeline(_EventoHistorico evento, bool isUltimo) {
    final cor = _corGravidade(evento.gravidade);

    return IntrinsicHeight(
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
                child: Icon(evento.icone, color: cor, size: 18),
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
                    // Barra lateral de gravidade.
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
                                    evento.titulo,
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
                                    _formatarDataHora(evento.dataHora),
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
                              evento.descricao,
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
  }
}
