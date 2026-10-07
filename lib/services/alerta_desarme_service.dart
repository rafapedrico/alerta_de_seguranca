import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'emergency_alert_service.dart';
import 'firebase_sync_service.dart';
import 'historico_alertas_service.dart';
import 'l10n_headless_service.dart';
import 'location_service.dart';

/// Resultado de um alerta do cronômetro/despertador.
@immutable
class ResultadoAlertaDesarme {
  const ResultadoAlertaDesarme({
    required this.alertaId,
    required this.status,
    this.semContatos = false,
  });

  final String alertaId;

  /// Um de [StatusAlertaHistorico] (`enviado`/`pendente`/`falhou`).
  final String status;

  /// Nenhum contato de emergência cadastrado: nada foi enviado.
  final bool semContatos;
}

/// Alerta do Cronômetro Regressivo e dos despertadores (tempo esgotado, 3
/// PINs errados, fechamento forçado): UMA entrada no histórico (nasce
/// `enviando`), Firestore (`usuarios/{uid}/alertas`, com o tipo correto, o
/// texto do usuário e a posição) e SMS (motivo + texto do usuário +
/// localização) — em paralelo, com a MESMA posição.
class AlertaDesarmeService {
  AlertaDesarmeService._();

  /// Id no formato do Firestore (20 caracteres) — o mesmo no documento e
  /// no `alerta_id` do histórico.
  static String novoAlertaId() {
    const caracteres = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final aleatorio = Random.secure();
    return List.generate(20, (_) => caracteres[aleatorio.nextInt(caracteres.length)]).join();
  }

  /// [tipo]: `cronometro_expirado`, `tentativa_desarme_incorreto` ou
  /// `despertador_expirado`. [eventoId] (opcional) torna o envio único por
  /// evento — dois caminhos detectando o mesmo evento não duplicam.
  static Future<ResultadoAlertaDesarme> disparar({
    required String tipo,
    required String titulo,
    required String motivo,
    String? contexto,
    String? eventoId,
  }) async {
    final l10n = await L10nHeadlessService.obter();
    final alertaId = eventoId ?? novoAlertaId();
    final textoUsuario = (contexto ?? '').trim();

    final posicaoAlerta = await LocationService().obterPosicaoParaAlerta();
    final posicao = posicaoAlerta.posicao;

    await HistoricoAlertasService().criarAlerta(
      alertaId: alertaId,
      tipo: tipo,
      titulo: titulo,
      descricao: motivo,
      contexto: textoUsuario,
      latitude: posicao?.latitude,
      longitude: posicao?.longitude,
      precisao: posicao?.accuracy,
    );

    var mensagem = l10n.smsTentativaDesarmeCorpo(
      motivo,
      EmergencyAlertService().textoLocalizacao(posicao, l10n),
    );
    if (textoUsuario.isNotEmpty) mensagem = '$mensagem\n${l10n.smsTextoDoUsuario(textoUsuario)}';

    final resultados = await Future.wait<Object>([
      FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto(
        motivo: motivo,
        eventoId: alertaId,
        tipo: tipo,
        contextoPersonalizado: textoUsuario,
        latitude: posicao?.latitude,
        longitude: posicao?.longitude,
        precisao: posicao?.accuracy,
      ),
      EmergencyAlertService().enviarSms(mensagem),
    ]);
    final nuvem = resultados[0] as ResultadoEnvioNuvem;
    final sms = resultados[1] as ResultadoSms;

    final String status;
    if (nuvem.confirmado || sms.confirmado) {
      status = StatusAlertaHistorico.enviado;
    } else if (nuvem.naFila || sms.tentados > 0) {
      status = StatusAlertaHistorico.pendente;
    } else {
      status = StatusAlertaHistorico.falhou;
    }
    await HistoricoAlertasService().marcarStatus(alertaId, status);

    if (!posicaoAlerta.precisa && posicaoAlerta.atualizacao != null) {
      unawaited(posicaoAlerta.atualizacao!.then((precisa) async {
        if (precisa == null) return;
        await HistoricoAlertasService().atualizarLocalizacao(
          alertaId,
          latitude: precisa.latitude,
          longitude: precisa.longitude,
          precisao: precisa.accuracy,
        );
        await FirebaseSyncService().registrarAtualizacaoLocalizacaoDoAlerta(
          alertaId: alertaId,
          latitude: precisa.latitude,
          longitude: precisa.longitude,
          precisao: precisa.accuracy,
        );
      }));
    }

    debugPrint('🚨 [AlertaDesarme] $tipo ($alertaId): status=$status '
        'nuvem=${nuvem.confirmado}/${nuvem.naFila} sms=${sms.confirmados}/${sms.tentados}');
    return ResultadoAlertaDesarme(alertaId: alertaId, status: status, semContatos: sms.semContatos);
  }
}
