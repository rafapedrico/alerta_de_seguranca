import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/alarme_agendado_model.dart';
import 'alarme_agendado_cloud_service.dart';
import 'alarme_nativo_service.dart';
import 'alarme_service.dart';
import 'database_helper.dart';
import 'firebase_auth_service.dart';

/// Janela de LOCALIZAÇÃO do despertador: das 2 h antes do horário até o
/// fim da tolerância (lida a cada 1 min pelo serviço nativo
/// `VigiaLocalizacao`). Fora dela, nada de localização para o despertador.
const Duration janelaLocalizacao2h = Duration(hours: 2);

/// Intervalo do heartbeat (mantém contatos/etiqueta do ciclo na nuvem).
const Duration intervaloHeartbeat = Duration(minutes: 15);

/// "Dead man's switch" na nuvem (`alarmes_agendados`), independente do
/// alarme local:
///
/// - **Cronômetro**: [registrarCheckinAtivo] grava o ciclo PENDENTE no
///   início (prazo = fim + 60 s de tolerância); [confirmarCheckinSeguro]/
///   [confirmarAlertaJaDisparado] resolvem o ciclo.
/// - **Despertadores**: [registrarAlarmeRotinaImediatamente] grava o
///   ciclo da PRÓXIMA ocorrência (calculada pela agenda nativa) sem nunca
///   substituir uma ocorrência em andamento (ver
///   [AlarmeAgendadoCloudService.registrarCiclo]); o ciclo periódico só
///   reafirma esse mesmo ciclo — NUNCA empurra o prazo para a próxima
///   ocorrência depois do horário, e respeita a pausa.
///
/// A LOCALIZAÇÃO não é enviada daqui nem gravada nos documentos de
/// `alarmes_agendados`: o serviço nativo (`VigiaLocalizacao.kt`) grava SÓ em
/// `usuarios/{uid}/monitoramento/atual` durante o cronômetro e nas 2 h antes
/// de cada despertador (deslocamento de 30 m ou a cada 5 min parado), mesmo
/// com o app fechado.
class BackgroundLocationHeartbeatService {
  BackgroundLocationHeartbeatService._internal();
  static final BackgroundLocationHeartbeatService _instance =
      BackgroundLocationHeartbeatService._internal();
  factory BackgroundLocationHeartbeatService() => _instance;

  Timer? _timer;

  /// Id fixo do documento do cronômetro de check-in da aba Segurança.
  static const String idAlarmeCheckinSeguranca = 'checkin_seguranca';

  /// Fim (epoch ms) do ciclo do cronômetro em andamento — identifica o
  /// ciclo nas marcações de status.
  int? _cicloCheckin;

  /// Inicia o ciclo periódico (idempotente).
  void iniciar() {
    if (_timer != null) return;
    unawaited(_executarCiclo());
    _timer = Timer.periodic(intervaloHeartbeat, (_) => _executarCiclo());
  }

  void parar() {
    _timer?.cancel();
    _timer = null;
  }

  /// Cronômetro iniciado: grava o ciclo PENDENTE na nuvem já com o prazo
  /// real (fim + tolerância de 60 s).
  Future<void> registrarCheckinAtivo({
    required DateTime dataHoraDisparo,
    required String contexto,
  }) async {
    _cicloCheckin = dataHoraDisparo.millisecondsSinceEpoch;
    try {
      final usuarioId = FirebaseAuthService().uidAtual;
      if (usuarioId == null) return;
      await AlarmeAgendadoCloudService().reiniciarCicloComoPendente(AlarmeAgendadoModel(
        idAlarme: idAlarmeCheckinSeguranca,
        usuarioId: usuarioId,
        dataHoraDisparo: dataHoraDisparo,
        prazoFinalDisparo: dataHoraDisparo.add(AlarmeService.duracaoJanelaFinalCronometro),
        contatosEmergencia: await _resolverContatosEmergencia(),
        etiqueta: '',
        contextoPersonalizado: contexto,
        cicloEpochMs: dataHoraDisparo.millisecondsSinceEpoch,
      ));
    } catch (e) {
      debugPrint('⚠️ [Heartbeat] Falha ao registrar o cronômetro na nuvem: $e');
    }
  }

  Future<int?> _cicloCheckinAtual() async =>
      _cicloCheckin ?? await AlarmeService().fimDoCicloAtual();

  /// PIN correto no cronômetro: CONFIRMADO_SEGURA no ciclo atual.
  Future<void> confirmarCheckinSeguro() async {
    final ciclo = await _cicloCheckinAtual();
    _cicloCheckin = null;
    await AlarmeAgendadoCloudService()
        .marcarConfirmadoSeguro(idAlarmeCheckinSeguranca, ciclo: ciclo);
  }

  /// Alerta do cronômetro já disparado pelo aparelho: ALERTA_DISPARADO no
  /// ciclo atual (sem alerta duplicado da Cloud Function).
  Future<void> confirmarAlertaJaDisparado() async {
    final ciclo = await _cicloCheckinAtual();
    _cicloCheckin = null;
    await AlarmeAgendadoCloudService()
        .marcarAlertaDisparado(idAlarmeCheckinSeguranca, ciclo: ciclo);
  }

  /// Compatibilidade: encerra o acompanhamento local do cronômetro.
  void cancelarCheckinAtivo() {
    _cicloCheckin = null;
  }

  /// Grava na nuvem o ciclo da próxima ocorrência do despertador
  /// [alarmeMap] ([ocorrencia], calculada pela agenda nativa). Sem
  /// [ocorrencia] (despertador inativo/sem próxima), nada é gravado.
  /// [pausadoAte] = 00h00 do dia seguinte à pausa, quando pausado.
  Future<void> registrarAlarmeRotinaImediatamente(
    Map<String, dynamic> alarmeMap, {
    OcorrenciaAlarme? ocorrencia,
    DateTime? pausadoAte,
  }) async {
    try {
      final usuarioId = FirebaseAuthService().uidAtual;
      if (usuarioId == null || ocorrencia == null) return;
      final idAlarme = (alarmeMap['id'] as int?)?.toString();
      if (idAlarme == null) return;

      await AlarmeAgendadoCloudService().registrarCiclo(AlarmeAgendadoModel(
        idAlarme: idAlarme,
        usuarioId: usuarioId,
        dataHoraDisparo: DateTime.fromMillisecondsSinceEpoch(ocorrencia.ciclo),
        prazoFinalDisparo: DateTime.fromMillisecondsSinceEpoch(ocorrencia.prazo),
        contatosEmergencia: await _resolverContatosEmergencia(),
        etiqueta: AlarmeNativoService.etiquetaParaNuvem(alarmeMap['etiqueta'] as String?),
        contextoPersonalizado: (alarmeMap['contexto_personalizado'] as String?) ?? '',
        cicloEpochMs: ocorrencia.ciclo,
        pausadoAte: pausadoAte,
      ));
    } catch (e) {
      debugPrint('⚠️ [Heartbeat] Falha ao registrar o despertador na nuvem: $e');
    }
  }

  /// Reafirma o ciclo da próxima ocorrência de cada despertador ativo (sem
  /// localização). Pula os pausados no dia de hoje? Não precisa: a agenda
  /// nativa já devolve a próxima ocorrência VÁLIDA (fora do dia pausado),
  /// e [AlarmeAgendadoCloudService.registrarCiclo] nunca mexe numa
  /// ocorrência em andamento.
  Future<void> _executarCiclo() async {
    try {
      if (FirebaseAuthService().uidAtual == null) return;
      final alarmes = await DatabaseHelper().listarAlarmes();
      for (final alarme in alarmes) {
        if ((alarme['ativo'] as int?) != 1) continue;
        final id = alarme['id'] as int?;
        if (id == null) continue;
        final ocorrencia = await AlarmeNativoService.proximaOcorrencia(id);
        if (ocorrencia == null) continue;
        await registrarAlarmeRotinaImediatamente(alarme, ocorrencia: ocorrencia);
      }
    } catch (e) {
      debugPrint('⚠️ [Heartbeat] Falha no ciclo: $e');
    }
  }

  /// `{nome, telefone}` dos contatos de emergência (mesmo formato de
  /// `usuarios/{uid}.contatosEmergencia`).
  Future<List<Map<String, dynamic>>> _resolverContatosEmergencia() async {
    try {
      final contatos = await DatabaseHelper().getContatosEmergencia();
      return contatos
          .map((c) => {
                'nome': (c['nome'] as String?) ?? '',
                'telefone': (c['telefone'] as String?) ?? '',
              })
          .where((c) => (c['telefone'] as String).isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('⚠️ [Heartbeat] Falha ao resolver contatos de emergência: $e');
      return const [];
    }
  }
}
