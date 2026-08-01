import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/database_helper.dart';

/// Tela de Auditoria de Eventos Sensíveis (o "cofre" acessado pelo ícone
/// superior direito).
///
/// Recurso de proteção de dados/privacidade: os registros mais críticos do
/// histórico (categoria 'critico' — EXCLUSIVAMENTE alarmes de emergência
/// e disparos de SMS de socorro para os contatos cadastrados) só podem ser
/// visualizados após o usuário solicitar explicitamente a liberação e
/// aguardar um período de carência de 2 horas. Isso evita que alguém com
/// acesso rápido e não autorizado ao dispositivo (ex: um agressor) consiga
/// inspecionar imediatamente o histórico de segurança da vítima.
///
/// Blindagem de privacidade: esses registros são isolados exclusivamente
/// aqui e NUNCA aparecem na tela de Histórico Geral (aba Histórico),
/// independentemente de qualquer status de liberação desta tela — a
/// separação é garantida na origem, pela query de [DatabaseHelper.getHistorico]
/// (que exclui a categoria 'critico') e [DatabaseHelper.getEventosSensiveis]
/// (que busca exclusivamente a categoria 'critico').

///
/// Regras:
/// - Ao solicitar, o timestamp da solicitação é salvo no banco.
/// - Enquanto o tempo decorrido for < 2h, exibe apenas o aviso de carência
///   com a contagem regressiva do tempo restante.
/// - Quando o tempo decorrido for >= 2h, libera a visualização completa
///   dos registros sensíveis.
/// - Assim que o app for totalmente fechado/reiniciado (cold start), o
///   estado de liberação é resetado (ver main.dart), exigindo nova
///   solicitação e nova espera de 2h para o próximo acesso.
/// - O usuário também pode bloquear manualmente o acesso já liberado a
///   qualquer momento através do botão "Bloquear Novamente".
class AuditoriaSensivelScreen extends StatefulWidget {
  const AuditoriaSensivelScreen({super.key});

  @override
  State<AuditoriaSensivelScreen> createState() => _AuditoriaSensivelScreenState();
}

class _AuditoriaSensivelScreenState extends State<AuditoriaSensivelScreen> {
  final DatabaseHelper _db = DatabaseHelper();

  bool _carregando = true;
  bool _liberado = false;
  bool _temSolicitacaoPendente = false;
  int _msRestantes = 0;

  List<Map<String, dynamic>> _eventosSensiveis = [];

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _atualizarStatus();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _atualizarStatus() async {
    final status = await _db.getStatusAuditoria();
    if (!mounted) return;

    final liberado = status['liberado'] as bool;

    setState(() {
      _liberado = liberado;
      _temSolicitacaoPendente = status['temSolicitacaoPendente'] as bool;
      _msRestantes = status['msRestantes'] as int;
      _carregando = false;
    });

    _ticker?.cancel();
    if (liberado) {
      // Já liberado: carrega os registros sensíveis para exibição.
      final eventos = await _db.getEventosSensiveis();
      if (!mounted) return;
      setState(() => _eventosSensiveis = eventos);
    } else if (_temSolicitacaoPendente) {
      // Ainda em carência: atualiza a contagem regressiva a cada segundo,
      // verificando periodicamente se as 2h já se cumpriram.
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _atualizarStatus());
    }
  }

  Future<void> _solicitarLiberacao() async {
    await _db.solicitarLiberacaoAuditoria();
    if (!mounted) return;
    await _atualizarStatus();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.auditoriaSolicitacaoAprovada),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// Exibe um pop-up de confirmação antes de bloquear novamente o acesso
  /// aos registros sensíveis já liberados. O texto de aviso é exibido
  /// SEM cortes (softWrap habilitado, sem overflow/ellipsis e sem
  /// maxLines), garantindo que toda a mensagem seja lida pelo usuário.
  void _confirmarBloquearNovamente() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.lock_outline, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AppLocalizations.of(ctx)!.auditoriaBloquearNovamenteTitulo,
                softWrap: true,
                overflow: TextOverflow.visible,
              ),
            ),
          ],
        ),
        content: Text(
          AppLocalizations.of(ctx)!.auditoriaBloquearNovamenteConteudo,
          softWrap: true,
          overflow: TextOverflow.visible,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(ctx)!.cancelar),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _bloquearNovamente();
            },
            icon: const Icon(Icons.lock, size: 18),
            label: Text(AppLocalizations.of(ctx)!.auditoriaBloquearNovamenteBotao),
          ),
        ],
      ),
    );
  }

  /// Efetiva o rebloqueio dos registros sensíveis, resetando o status de
  /// liberação/solicitação da auditoria no banco e atualizando a tela
  /// imediatamente para a tela de carência.
  Future<void> _bloquearNovamente() async {
    await _db.bloquearAuditoriaNovamente();
    if (!mounted) return;
    await _atualizarStatus();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.auditoriaBloqueadoNovamente),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }


  /// Remove definitivamente um único evento sensível do histórico pelo
  /// id, acionado pelo gesto de "arrastar para excluir" (Dismissible),
  /// exatamente como já funciona na aba Histórico normal. Reaproveita o
  /// mesmo método do DatabaseHelper usado por [HistoricoTab], já que a
  /// tabela 'historico' é única — apenas a categoria ('critico') difere.
  Future<void> _excluirEventoSensivel(int id) async {
    await _db.deletarEventoHistorico(id);
    if (!mounted) return;
    setState(() {
      _eventosSensiveis.removeWhere((e) => e['id'] == id);
    });
  }

  /// Exibe a confirmação e, se aceita, apaga TODOS os registros sensíveis
  /// (categoria 'critico') de uma vez — opção "Limpar Histórico" pedida
  /// também para esta tela protegida.
  void _confirmarLimparHistorico() {
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
              await _db.limparHistoricoPorCategoria('critico');
              if (!mounted) return;
              setState(() => _eventosSensiveis = []);
            },
            child: Text(l10n.historicoLimparBotao),
          ),
        ],
      ),
    );
  }

  String _formatarTempoRestante(int ms) {
    final duracao = Duration(milliseconds: ms);
    final horas = duracao.inHours;
    final minutos = duracao.inMinutes % 60;
    final segundos = duracao.inSeconds % 60;
    return '${horas.toString().padLeft(2, '0')}:'
        '${minutos.toString().padLeft(2, '0')}:'
        '${segundos.toString().padLeft(2, '0')}';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.auditoriaTitulo),
        backgroundColor: const Color(0xFF4C7040),
        foregroundColor: Colors.white,
        actions: [
          if (_liberado && _eventosSensiveis.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: AppLocalizations.of(context)!.historicoLimparBotao,
              onPressed: _confirmarLimparHistorico,
            ),
        ],
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : _liberado
              ? _construirListaLiberada()
              : _construirTelaDeCarencia(),
    );
  }

  Widget _construirTelaDeCarencia() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _temSolicitacaoPendente ? Icons.hourglass_top : Icons.lock_clock,
              size: 72,
              color: const Color(0xFF4C7040),
            ),
            const SizedBox(height: 24),
            Text(
              _temSolicitacaoPendente
                  ? AppLocalizations.of(context)!.auditoriaAguardandoLiberacao
                  : AppLocalizations.of(context)!.auditoriaRegistrosProtegidos,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            if (_temSolicitacaoPendente) ...[
              Text(
                AppLocalizations.of(context)!.auditoriaAvisoCarencia,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.black54),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Column(
                  children: [
                    Text(
                      AppLocalizations.of(context)!.auditoriaTempoRestante,
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatarTempoRestante(_msRestantes),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepOrange,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Text(
                AppLocalizations.of(context)!.auditoriaAvisoSolicitacao,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.black54),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _solicitarLiberacao,
                  icon: const Icon(Icons.lock_open),
                  label: Text(AppLocalizations.of(context)!.auditoriaSolicitarLiberacaoBotao),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4C7040),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _construirListaLiberada() {
    if (_eventosSensiveis.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.verified_user, size: 56, color: Colors.green.shade400),
              const SizedBox(height: 12),
              Text(
                AppLocalizations.of(context)!.auditoriaNenhumEvento,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Colors.green.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.verified_user, color: Colors.green.shade700, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AppLocalizations.of(context)!.auditoriaPrazoLiberado,
                  softWrap: true,
                  overflow: TextOverflow.visible,
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _confirmarBloquearNovamente,
                icon: Icon(Icons.lock, color: Colors.green.shade800, size: 16),
                label: Text(
                  AppLocalizations.of(context)!.auditoriaBloquearNovamenteBotao,
                  style: TextStyle(
                    color: Colors.green.shade800,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _eventosSensiveis.length,
            itemBuilder: (context, index) {
              final evento = _eventosSensiveis[index];
              final id = evento['id'] as int;
              final titulo = evento['titulo'] as String? ?? '';
              final descricao = evento['descricao'] as String? ?? '';
              final timestamp = evento['timestamp'] as String? ?? '';

              // Permite ao usuário arrastar o card para o lado (swipe)
              // e excluir definitivamente o registro sensível, assim
              // como já funciona na aba Histórico normal.
              return Dismissible(
                key: ValueKey(id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade400,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.delete_outline, color: Colors.white),
                ),
                onDismissed: (_) => _excluirEventoSensivel(id),
                child: Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.red.shade50,
                      child: Icon(Icons.shield_outlined, color: Colors.red.shade400),
                    ),
                    title: Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(descricao),
                    trailing: Text(
                      _formatarDataHora(timestamp),
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
