import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'database_helper.dart';
import 'firebase_auth_service.dart';
import 'l10n_headless_service.dart';

/// Processa o relatório de falha de entrega de 48h (ver
/// `functions/relatorioFalhaService.js`): sempre 100% SILENCIOSO — nunca
/// exibe notificação nem qualquer UI própria. O relatório vira um evento
/// local da categoria 'critico' (mesma tabela usada pelos disparos de
/// emergência do próprio usuário, ver `DatabaseHelper.inserirEventoHistorico`),
/// visível exclusivamente dentro do cofre de Auditoria de Eventos
/// Sensíveis já existente (trava por PIN de acesso, ver
/// `DatabaseHelper.auditoriaDesbloqueadaNaSessao`/`HistoricoTab`) — nunca
/// numa notificação de tela de bloqueio, preservando o disfarce de
/// segurança do app mesmo 48h depois de um alerta real ter sido disparado.
///
/// Dois caminhos alimentam este serviço, deliberadamente redundantes:
/// 1. [processarRelatorioSilencioso] — Push data-only (nudge) recebido em
///    primeiro/segundo plano (ver `FcmService`), processado assim que
///    chega.
/// 2. [sincronizarPendentes] — varredura de fallback, chamada uma vez por
///    sessão logada (ver `iniciarServicosPosLoginOuDashboard` em
///    `main.dart`), cobrindo o caso do nudge nunca ter chegado (app
///    encerrado pelo SO antes da entrega, sem Google Play Services, etc.)
///    — o relatório nunca se perde, só atrasa até o app ser reaberto.
class RelatorioFalhaEntregaService {
  RelatorioFalhaEntregaService._internal();
  static final RelatorioFalhaEntregaService _instance =
      RelatorioFalhaEntregaService._internal();
  factory RelatorioFalhaEntregaService() => _instance;

  final DatabaseHelper _db = DatabaseHelper();

  String? get _uid => FirebaseAuthService().uidAtual;

  /// Monta a lista de nomes (ou telefone, se o nome não foi informado)
  /// dos contatos que constam como falha no documento já lido.
  String _formatarListaDeContatos(Map<String, dynamic> dados, String textoContatoDesconhecido) {
    final contatosFalha = (dados['contatosFalha'] as List<dynamic>? ?? [])
        .map((c) {
          final mapa = c as Map<dynamic, dynamic>;
          final nome = (mapa['nome'] as String?)?.trim() ?? '';
          if (nome.isNotEmpty) return nome;
          return (mapa['telefone'] as String?)?.trim() ?? '';
        })
        .where((s) => s.isNotEmpty)
        .toList();
    return contatosFalha.isEmpty ? textoContatoDesconhecido : contatosFalha.join(', ');
  }

  /// Grava um relatório já lido do Firestore (mapa cru do documento) como
  /// evento local e remove o documento em `relatoriosFalha` para nunca
  /// duplicar no histórico local numa próxima sincronização.
  Future<void> _ingerirRelatorio(
    String idEntrega,
    Map<String, dynamic> dados,
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    final l10n = await L10nHeadlessService.obter();
    final listaContatos =
        _formatarListaDeContatos(dados, l10n.relatorioFalhaContatoDesconhecido);

    try {
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoRelatorioFalhaEntregaTitulo,
        descricao: l10n.historicoRelatorioFalhaEntregaDescricao(listaContatos),
        categoria: 'critico',
      );
      debugPrint(
          '🔒 [RelatorioFalhaEntregaService] Relatório $idEntrega gravado silenciosamente no cofre local.');
    } catch (e) {
      // Não apaga do Firestore se não conseguiu gravar local — tenta de
      // novo na próxima sincronização, em vez de perder o relatório.
      debugPrint('⚠️ [RelatorioFalhaEntregaService] Falha ao gravar evento local: $e');
      return;
    }

    try {
      await ref.delete();
    } catch (e) {
      debugPrint('⚠️ [RelatorioFalhaEntregaService] Falha ao remover relatório já processado: $e');
    }
  }

  /// Chamado pelo [FcmService] ao receber o nudge silencioso
  /// (`tipo: 'relatorio_falha_entrega'`). NUNCA exibe notificação — só
  /// busca o documento correspondente e o transforma em evento local.
  Future<void> processarRelatorioSilencioso(Map<String, dynamic> data) async {
    final idEntrega = data['idEntrega'] as String?;
    final uid = _uid;
    if (idEntrega == null || uid == null) return;

    try {
      final ref = FirebaseFirestore.instance
          .collection('usuarios')
          .doc(uid)
          .collection('relatoriosFalha')
          .doc(idEntrega);
      final snap = await ref.get();
      if (!snap.exists) return;
      await _ingerirRelatorio(idEntrega, snap.data()!, ref);
    } catch (e) {
      debugPrint('⚠️ [RelatorioFalhaEntregaService] Falha ao processar nudge de $idEntrega: $e');
    }
  }

  /// Varredura de fallback (ver documentação da classe) — busca TODOS os
  /// relatórios ainda não processados do usuário logado nesta sessão.
  Future<void> sincronizarPendentes() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(uid)
          .collection('relatoriosFalha')
          .get();
      for (final doc in snap.docs) {
        await _ingerirRelatorio(doc.id, doc.data(), doc.reference);
      }
    } catch (e) {
      debugPrint('⚠️ [RelatorioFalhaEntregaService] Falha ao sincronizar relatórios pendentes: $e');
    }
  }
}
