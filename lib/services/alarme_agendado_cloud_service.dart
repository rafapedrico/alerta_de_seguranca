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
/// coleção `alarmes_agendados`, escrita paralela e independente da
/// coleção `usuarios` já usada por `FirebaseSyncService`. Mesma postura
/// defensiva do resto do app: nunca lança exceção para quem a invoca,
/// sempre com timeout explícito, e um no-op silencioso se o Firebase não
/// tiver inicializado (ver [_firebaseDisponivel]) — o alarme local
/// (som, tela, tolerância, janela final, SMS nativo) continua 100%
/// funcional mesmo que toda esta classe falhe.
class AlarmeAgendadoCloudService {
  AlarmeAgendadoCloudService._internal();
  static final AlarmeAgendadoCloudService _instance =
      AlarmeAgendadoCloudService._internal();
  factory AlarmeAgendadoCloudService() => _instance;

  static const String _colecao = 'alarmes_agendados';

  bool get _firebaseDisponivel =>
      Firebase.apps.isNotEmpty && FirebaseAuthService().uidAtual != null;

  /// Id do documento namespaced por usuário (`{uid}_{idAlarme}`) — evita
  /// colisão entre o mesmo `idAlarme` local (autoincrement do SQLite) de
  /// dois usuários diferentes, e casa com a regra de segurança do
  /// Firestore que restringe leitura/escrita ao dono (`usuarioId`
  /// gravado no próprio documento, ver `firestore.rules`).
  DocumentReference<Map<String, dynamic>> _documento(String idAlarme) {
    final uid = FirebaseAuthService().uidAtual;
    return FirebaseFirestore.instance
        .collection(_colecao)
        .doc('${uid}_$idAlarme');
  }

  /// Cria/atualiza (via merge, nunca acumula) o documento do alarme
  /// agendado — chamado a cada ciclo do
  /// `BackgroundLocationHeartbeatService` enquanto o alarme estiver
  /// dentro da janela de heartbeat (≤ 2h do disparo previsto),
  /// substituindo sempre `dataHoraDisparo`, `ultimaLocalizacao` e
  /// `contatosEmergencia` pelos valores mais recentes. Preserva o
  /// `status` já gravado na nuvem (nunca sobrescreve de volta para
  /// PENDENTE um alarme já confirmado/alertado) a menos que o documento
  /// ainda não exista.
  Future<void> registrarAlarmeAgendado(AlarmeAgendadoModel modelo) async {
    if (!_firebaseDisponivel) return;
    try {
      final doc = _documento(modelo.idAlarme);
      final dadosParaGravar = modelo.toFirestore();

      final snapshotAtual = await doc.get().timeout(_timeoutFirestore);
      if (snapshotAtual.exists) {
        // Não pisa no status já confirmado/alertado por um heartbeat
        // subsequente — apenas o PIN correto (CONFIRMADO_SEGURA) ou a
        // Cloud Function (ALERTA_DISPARADO) podem mudar o status depois
        // do registro inicial.
        dadosParaGravar.remove('status');
      }

      await doc.set(dadosParaGravar, SetOptions(merge: true)).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao registrar alarme agendado #${modelo.idAlarme}: $e');
    }
  }

  /// Marca o alarme como CONFIRMADO_SEGURA — chamado assim que o PIN
  /// correto é digitado (ver
  /// `RotinaAlarmeService.confirmarCheckinRotina`), avisando a nuvem que
  /// o usuário está a salvo antes mesmo de a Cloud Function agendada
  /// rodar novamente e checar o prazo.
  Future<void> marcarConfirmadoSeguro(String idAlarme) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(idAlarme).set(
        {
          'status': AlarmeAgendadoStatus.confirmadoSeguro.valorFirestore,
          'confirmadoEm': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao marcar alarme #$idAlarme como seguro: $e');
    }
  }
}
