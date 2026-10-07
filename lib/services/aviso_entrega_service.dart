import 'package:flutter/foundation.dart';

import 'database_helper.dart';
import 'historico_alertas_service.dart';
import 'notificacao_service.dart';

/// Status de entrega de um alerta a UM contato (detalhe do Histórico).
class StatusEntregaContato {
  StatusEntregaContato._();

  static const String entregue = 'entregue';
  static const String tentando = 'tentando';
  static const String naoEntregue = 'nao_entregue';
}

/// Avisos do servidor ao REMETENTE sobre a entrega do alerta a cada
/// contato ("{nome} ainda não recebeu seu alerta…", "{nome} recebeu seu
/// alerta.", "Não foi possível entregar…").
///
/// Push data-only. Campos lidos:
/// - `tipo`: `aviso_entrega` (com `statusEntrega`) ou um de
///   `entrega_alerta_tentando` / `entrega_alerta_entregue` /
///   `entrega_alerta_nao_entregue`;
/// - `statusEntrega`: `tentando` | `entregue` | `nao_entregue`;
/// - `titulo`, `corpo`: o texto mostrado, como veio do servidor;
/// - `alertaId` (id do documento em `usuarios/{uid}/alertas`), e para
///   identificar o contato `contatoId` ou `telefone`, e `nomeContato`.
///
/// Mostra uma notificação visível com `titulo`/`corpo` e grava o status do
/// contato na entrada do alerta (pelo `alertaId`; sem ele, no alerta mais
/// recente das últimas 48 h).
class AvisoEntregaService {
  AvisoEntregaService._();

  static const Set<String> tipos = {
    'aviso_entrega',
    'entrega_alerta_tentando',
    'entrega_alerta_entregue',
    'entrega_alerta_nao_entregue',
  };

  static String? statusDoPush(Map<String, dynamic> data) {
    final explicito = (data['statusEntrega'] as String?)?.trim();
    if (explicito == StatusEntregaContato.entregue ||
        explicito == StatusEntregaContato.tentando ||
        explicito == StatusEntregaContato.naoEntregue) {
      return explicito;
    }
    switch (data['tipo']) {
      case 'entrega_alerta_entregue':
        return StatusEntregaContato.entregue;
      case 'entrega_alerta_tentando':
        return StatusEntregaContato.tentando;
      case 'entrega_alerta_nao_entregue':
        return StatusEntregaContato.naoEntregue;
    }
    return null;
  }

  static Future<void> processar(Map<String, dynamic> data) async {
    final titulo = ((data['titulo'] as String?) ?? '').trim();
    final corpo = ((data['corpo'] as String?) ?? '').trim();
    final contato = ((data['contatoId'] as String?) ??
            (data['telefone'] as String?) ??
            (data['nomeContato'] as String?) ??
            '')
        .trim();

    try {
      final db = DatabaseHelper();
      var alertaId = (data['alertaId'] as String?)?.trim();
      if (alertaId == null || alertaId.isEmpty) {
        alertaId = await db.alertaMaisRecenteEnviado(const Duration(hours: 48));
      }
      final status = statusDoPush(data);
      if (alertaId != null && contato.isNotEmpty && status != null) {
        await db.salvarEntregaContato(
          alertaId: alertaId,
          contato: contato,
          nome: (data['nomeContato'] as String?) ?? '',
          status: status,
          texto: corpo.isNotEmpty ? corpo : titulo,
        );
      }
    } catch (e) {
      debugPrint('⚠️ [AvisoEntrega] Falha ao gravar o status de entrega: $e');
    }

    if (titulo.isEmpty && corpo.isEmpty) return;
    try {
      await NotificacaoService.exibirNotificacaoInformativa(
        id: 71000 + ('${data['alertaId']}$contato'.hashCode.abs() % 900),
        titulo: titulo.isNotEmpty ? titulo : corpo,
        corpo: corpo.isNotEmpty ? corpo : titulo,
      );
    } catch (e) {
      debugPrint('⚠️ [AvisoEntrega] Falha ao exibir o aviso de entrega: $e');
    }
  }

  /// Tipos de entrada que são alertas enviados (não eventos do cronômetro).
  static const Set<String> tiposDeAlerta = {
    TipoAlertaHistorico.sosManual,
    TipoAlertaHistorico.sosFisico,
    TipoAlertaHistorico.cronometroExpirado,
    TipoAlertaHistorico.tentativaDesarmeIncorreto,
    TipoAlertaHistorico.despertadorExpirado,
  };
}
