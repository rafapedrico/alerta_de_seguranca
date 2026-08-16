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

  /// Ids de alarme de ROTINA (mesma string usada como chave do documento,
  /// ver [_documento]) cujo PRÓXIMO registro em
  /// `BackgroundLocationHeartbeatService._executarCiclo` deve usar
  /// [reiniciarCicloComoPendente] em vez de [registrarAlarmeAgendado] — ver
  /// [sinalizarNovoCiclo]/[consumirSinalizacaoDeNovoCiclo].
  final Set<String> _idsRotinaComNovoCicloPendente = {};

  /// Sinaliza que o ciclo do alarme de ROTINA [idAlarme] acabou de ser
  /// CONCLUÍDO de forma definitiva (PIN correto, alerta de emergência
  /// disparado — inclusive pelo callback headless —, ou o alarme foi
  /// reativado/reagendado manualmente pelo usuário na aba Família) e que a
  /// PRÓXIMA vez que este mesmo id for registrado pelo heartbeat deve
  /// nascer como um ciclo PENDENTE totalmente novo no Firestore.
  ///
  /// CORREÇÃO DE DÉBITO TÉCNICO (2026-08-15): diferente do Cronômetro (id
  /// fixo `checkin_seguranca`, que já reiniciava o ciclo via
  /// `BackgroundLocationHeartbeatService.registrarCheckinAtivo`), os
  /// alarmes de Rotina reaproveitam o MESMO `idAlarme` (autoincrement do
  /// SQLite) em toda repetição semanal/diária — mas
  /// [registrarAlarmeAgendado] deliberadamente PRESERVA o `status` já
  /// gravado a cada heartbeat. Sem esta sinalização, depois do PRIMEIRO
  /// ciclo de um alarme recorrente (êxito ou falha), o documento ficava
  /// PARA SEMPRE fora de PENDENTE, e a Cloud Function agendada
  /// (`monitorarAlarmesAgendados`) parava de proteger TODAS as ocorrências
  /// seguintes desse mesmo alarme.
  ///
  /// IMPORTANTE — NUNCA chamar isto no instante em que o alarme apenas
  /// DISPARA (`RotinaAlarmeService`, callback `_callbackCheckinRotina`): o
  /// reagendamento nativo da PRÓXIMA ocorrência já acontece nesse momento,
  /// mas o ciclo ATUAL ainda está em aberto (teclado de PIN prestes a
  /// abrir) — reiniciar o documento nesse instante apagaria o
  /// monitoramento do ciclo em andamento sempre que a repetição for
  /// diária/frequente o bastante para a PRÓXIMA ocorrência já cair dentro
  /// da janela de 48h de heartbeat. Só chamar quando o ciclo ATUAL já
  /// estiver definitivamente resolvido (ou antes dele sequer começar, ex:
  /// reativação manual de um alarme pausado/editado).
  void sinalizarNovoCiclo(String idAlarme) {
    _idsRotinaComNovoCicloPendente.add(idAlarme);
  }

  /// Consome (lê E remove) a sinalização de [sinalizarNovoCiclo] para
  /// [idAlarme] — chamado por
  /// `BackgroundLocationHeartbeatService._executarCiclo` a cada ciclo, para
  /// decidir entre [registrarAlarmeAgendado] (preserva status) e
  /// [reiniciarCicloComoPendente] (sempre PENDENTE) para este candidato.
  bool consumirSinalizacaoDeNovoCiclo(String idAlarme) {
    return _idsRotinaComNovoCicloPendente.remove(idAlarme);
  }

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

  /// Reinicia o documento do alarme como um NOVO ciclo PENDENTE —
  /// necessário para ids FIXOS e reaproveitados entre ciclos (ex: o
  /// cronômetro de check-in da aba Segurança, ver
  /// `BackgroundLocationHeartbeatService.idAlarmeCheckinSeguranca`), cujo
  /// documento de um ciclo ANTERIOR já finalizado (CONFIRMADO_SEGURA ou
  /// ALERTA_DISPARADO) senão ficaria "preso" nesse status para sempre.
  /// Diferente de [registrarAlarmeAgendado] (que deliberadamente
  /// PRESERVA o status já gravado — correto para heartbeats dentro do
  /// MESMO ciclo), este método sobrescreve o documento inteiro, sempre
  /// que um novo ciclo de monitoramento está começando.
  Future<void> reiniciarCicloComoPendente(AlarmeAgendadoModel modelo) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(modelo.idAlarme)
          .set(modelo.toFirestore())
          .timeout(_timeoutFirestore);
      debugPrint(
          '☁️ [AlarmeAgendadoCloudService] Ciclo #${modelo.idAlarme} reiniciado como PENDENTE.');
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao reiniciar ciclo #${modelo.idAlarme}: $e');
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

  /// Marca o alarme como ALERTA_DISPARADO — chamado assim que o alerta de
  /// emergência já foi disparado PELO PRÓPRIO APARELHO (3ª tentativa de
  /// PIN incorreta OU os 60s de tolerância se esgotando localmente, ver
  /// `BackgroundLocationHeartbeatService.confirmarAlertaJaDisparado`).
  ///
  /// CORREÇÃO DE BUG REAL (2026-08-15, duplo disparo do Cronômetro): sem
  /// esta chamada, o documento `alarmes_agendados/{idAlarme}` permanecia
  /// PENDENTE mesmo depois do disparo local — a única forma de sair de
  /// PENDENTE antes desta correção era [marcarConfirmadoSeguro] (PIN
  /// certo). Isso significa que, quando as 3 tentativas de PIN erradas
  /// aconteciam ANTES do prazo (`prazoFinalEpochMs`) se esgotar, o alerta
  /// já tinha sido enviado pelo aparelho, mas o documento continuava
  /// PENDENTE — e assim que o prazo original vencia (poucos segundos
  /// depois), a Cloud Function agendada (`monitorarAlarmesAgendados`, que
  /// só olha para `status == PENDENTE`) encontrava esse mesmo documento
  /// "vencido sem confirmação" e disparava um SEGUNDO alerta duplicado.
  /// Gravar ALERTA_DISPARADO aqui, no mesmo instante do disparo local,
  /// tira o documento da consulta da function e resolve o duplo envio —
  /// mesmo espírito de [marcarConfirmadoSeguro], só que para o outro
  /// desfecho possível do ciclo.
  Future<void> marcarAlertaDisparado(String idAlarme) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(idAlarme).set(
        {
          'status': AlarmeAgendadoStatus.alertaDisparado.valorFirestore,
          'alertaDisparadoEm': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao marcar alarme #$idAlarme como alerta disparado: $e');
    }
  }
}
