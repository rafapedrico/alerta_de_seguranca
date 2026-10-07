import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../models/alarme_agendado_model.dart';
import 'firebase_auth_service.dart';

/// Mesmo teto de timeout já usado por [FirebaseSyncService] — sem isto,
/// uma chamada ao Firestore sem conectividade real (Wi-Fi só com rede
/// local, por exemplo) poderia ficar pendurada indefinidamente.
const Duration _timeoutFirestore = Duration(seconds: 8);

/// Camada de acesso ao Firestore para o modelo [AlarmeAgendadoModel] —
/// coleção `alarmes_agendados`, o "dead man's switch" na nuvem do
/// cronômetro e dos despertadores. Nunca lança exceção para quem a invoca,
/// sempre com timeout explícito, e um no-op silencioso se o Firebase não
/// tiver inicializado.
///
/// CICLO: cada documento descreve UMA ocorrência (`cicloEpochMs` = horário
/// programado). O documento do ciclo atual fica PENDENTE com
/// `prazoFinalEpochMs = horário + tolerância` até ser resolvido (PIN
/// correto → CONFIRMADO_SEGURA; alerta → ALERTA_DISPARADO). Só então a
/// próxima ocorrência substitui o documento — [registrarCiclo] nunca
/// sobrescreve uma ocorrência em andamento, e [marcarConfirmadoSeguro]/
/// [marcarAlertaDisparado] só mudam o documento se ele ainda for do ciclo
/// informado (nunca o da próxima ocorrência).
class AlarmeAgendadoCloudService {
  AlarmeAgendadoCloudService._internal();
  static final AlarmeAgendadoCloudService _instance =
      AlarmeAgendadoCloudService._internal();
  factory AlarmeAgendadoCloudService() => _instance;

  static const String _colecao = 'alarmes_agendados';

  bool get _firebaseDisponivel =>
      Firebase.apps.isNotEmpty && FirebaseAuthService().uidAtual != null;

  /// Id do documento namespaced por usuário (`{uid}_{idAlarme}`).
  DocumentReference<Map<String, dynamic>> _documento(String idAlarme) {
    final uid = FirebaseAuthService().uidAtual;
    return FirebaseFirestore.instance
        .collection(_colecao)
        .doc('${uid}_$idAlarme');
  }

  /// Ciclo gravado num documento (`cicloEpochMs`, ou o horário em
  /// documentos antigos).
  static int? _cicloDoDocumento(Map<String, dynamic>? dados) {
    if (dados == null) return null;
    final ciclo = (dados['cicloEpochMs'] as num?)?.toInt();
    if (ciclo != null && ciclo > 0) return ciclo;
    final data = dados['dataHoraDisparo'];
    return data is Timestamp ? data.millisecondsSinceEpoch : null;
  }

  /// Registra a ocorrência [modelo] como o ciclo do documento:
  /// - documento do MESMO ciclo: só atualiza contatos/etiqueta/contexto
  ///   (preserva o status);
  /// - documento de OUTRO ciclo ainda em andamento (PENDENTE, prazo no
  ///   futuro e horário já passado — na tolerância): NÃO mexe — a próxima
  ///   ocorrência só entra depois que a atual for resolvida;
  /// - caso contrário: grava o novo ciclo como PENDENTE.
  Future<void> registrarCiclo(AlarmeAgendadoModel modelo) async {
    if (!_firebaseDisponivel) return;
    final doc = _documento(modelo.idAlarme);
    try {
      await FirebaseFirestore.instance.runTransaction<void>((tx) async {
        final atual = await tx.get(doc);
        final dados = atual.data();
        final cicloAtual = _cicloDoDocumento(dados);
        if (atual.exists && cicloAtual == modelo.ciclo) {
          final parcial = modelo.toFirestore()..remove('status');
          tx.set(doc, parcial, SetOptions(merge: true));
          return;
        }
        if (atual.exists && dados?['status'] == AlarmeAgendadoStatus.pendente.valorFirestore) {
          final agora = DateTime.now().millisecondsSinceEpoch;
          final prazoAtual = (dados?['prazoFinalEpochMs'] as num?)?.toInt() ?? 0;
          final emTolerancia = cicloAtual != null && cicloAtual <= agora && prazoAtual > agora;
          if (emTolerancia) {
            debugPrint('☁️ [AlarmeAgendadoCloudService] #${modelo.idAlarme} na tolerância — '
                'próxima ocorrência fica para depois.');
            return;
          }
        }
        tx.set(doc, modelo.toFirestore());
      }).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao registrar o ciclo #${modelo.idAlarme}: $e');
    }
  }

  /// Novo ciclo do CRONÔMETRO (início): substitui o documento — só é
  /// chamado depois de conferir que o ciclo anterior terminou (ver
  /// `AlarmeService.cicloAnteriorEmAndamento`).
  Future<void> reiniciarCicloComoPendente(AlarmeAgendadoModel modelo) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(modelo.idAlarme).set(modelo.toFirestore()).timeout(_timeoutFirestore);
      debugPrint('☁️ [AlarmeAgendadoCloudService] Ciclo #${modelo.idAlarme} reiniciado como PENDENTE.');
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao reiniciar ciclo #${modelo.idAlarme}: $e');
    }
  }

  /// Muda o status SÓ se o documento ainda for do ciclo [ciclo] (`null` =
  /// sem conferência, só para documentos de ciclo único).
  Future<bool> _marcarStatusDoCiclo(
    String idAlarme,
    int? ciclo,
    AlarmeAgendadoStatus status,
    String campoHorario,
  ) async {
    if (!_firebaseDisponivel) return false;
    final doc = _documento(idAlarme);
    try {
      return await FirebaseFirestore.instance.runTransaction<bool>((tx) async {
        final atual = await tx.get(doc);
        if (!atual.exists) return false;
        if (ciclo != null && _cicloDoDocumento(atual.data()) != ciclo) {
          debugPrint('☁️ [AlarmeAgendadoCloudService] #$idAlarme já está em outro ciclo — '
              '${status.valorFirestore} não aplicado.');
          return false;
        }
        tx.set(
          doc,
          {'status': status.valorFirestore, campoHorario: FieldValue.serverTimestamp()},
          SetOptions(merge: true),
        );
        return true;
      }).timeout(_timeoutFirestore);
    } catch (e) {
      // Sem rede a transação não roda: grava direto (vai na fila offline
      // do Firestore). O ciclo é conferido de novo pelo servidor (prazo).
      try {
        await doc.set(
          {'status': status.valorFirestore, campoHorario: FieldValue.serverTimestamp()},
          SetOptions(merge: true),
        ).timeout(_timeoutFirestore);
      } catch (_) {}
      debugPrint('⚠️ [AlarmeAgendadoCloudService] Transação de status #$idAlarme falhou: $e');
      return false;
    }
  }

  /// PIN correto: CONFIRMADO_SEGURA no ciclo [ciclo].
  Future<void> marcarConfirmadoSeguro(String idAlarme, {int? ciclo}) =>
      _marcarStatusDoCiclo(idAlarme, ciclo, AlarmeAgendadoStatus.confirmadoSeguro, 'confirmadoEm');

  /// Alerta já disparado pelo próprio aparelho: ALERTA_DISPARADO no ciclo
  /// [ciclo] — tira o documento da consulta da Cloud Function (sem alerta
  /// duplicado).
  Future<void> marcarAlertaDisparado(String idAlarme, {int? ciclo}) =>
      _marcarStatusDoCiclo(idAlarme, ciclo, AlarmeAgendadoStatus.alertaDisparado, 'alertaDisparadoEm');

  /// Despertador apagado/desativado: CANCELADO (o servidor não dispara).
  Future<void> marcarCancelado(String idAlarme) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(idAlarme).set(
        {
          'status': AlarmeAgendadoStatus.cancelado.valorFirestore,
          'canceladoEm': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao marcar alarme #$idAlarme como cancelado: $e');
    }
  }

  /// Status do documento [idAlarme] já resolvido NO CICLO [ciclo] (PIN
  /// correto, alerta já disparado pela nuvem, cancelado). `false` em
  /// qualquer falha.
  Future<bool> cicloJaResolvidoNaNuvem(String idAlarme, int ciclo) async {
    if (Firebase.apps.isEmpty) return false;
    try {
      final uid = await FirebaseAuthService().aguardarUidPronto();
      if (uid == null) return false;
      final snapshot = await FirebaseFirestore.instance
          .collection(_colecao)
          .doc('${uid}_$idAlarme')
          .get()
          .timeout(_timeoutFirestore);
      if (!snapshot.exists) return false;
      final dados = snapshot.data();
      if (_cicloDoDocumento(dados) != ciclo) return false;
      return AlarmeAgendadoStatus.fromFirestore(dados?['status'] as String?).jaResolvidoNaNuvem;
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao consultar o ciclo #$idAlarme: $e');
      return false;
    }
  }
}
