import 'package:cloud_firestore/cloud_firestore.dart';

/// Status do ciclo de vida de um [AlarmeAgendadoModel] no Firestore,
/// espelhando (na nuvem) o mesmo fluxo já validado do alarme de rotina
/// local (ver `RotinaAlarmeService`): o documento nasce `pendente` assim
/// que o alarme entra na janela de heartbeat (ver
/// `BackgroundLocationHeartbeatService`), muda para `confirmadoSeguro`
/// assim que o PIN correto é digitado no aparelho (ver
/// `RotinaAlarmeService.confirmarCheckinRotina`), ou para
/// `alertaDisparado` quando a Cloud Function de monitoramento agendado
/// (ver `cloud_functions/scheduledAlarmMonitor.ts`) detecta que o horário
/// limite foi ultrapassado sem confirmação.
enum AlarmeAgendadoStatus {
  pendente,
  confirmadoSeguro,
  alertaDisparado;

  /// Valor exatamente como gravado no Firestore (mesma grafia lida pela
  /// Cloud Function em TypeScript, ver `cloud_functions/`).
  String get valorFirestore {
    switch (this) {
      case AlarmeAgendadoStatus.pendente:
        return 'PENDENTE';
      case AlarmeAgendadoStatus.confirmadoSeguro:
        return 'CONFIRMADO_SEGURA';
      case AlarmeAgendadoStatus.alertaDisparado:
        return 'ALERTA_DISPARADO';
    }
  }

  static AlarmeAgendadoStatus fromFirestore(String? valor) {
    switch (valor) {
      case 'CONFIRMADO_SEGURA':
        return AlarmeAgendadoStatus.confirmadoSeguro;
      case 'ALERTA_DISPARADO':
        return AlarmeAgendadoStatus.alertaDisparado;
      case 'PENDENTE':
      default:
        return AlarmeAgendadoStatus.pendente;
    }
  }
}

/// Última localização conhecida do usuário no momento do heartbeat (ver
/// `BackgroundLocationHeartbeatService`), embutida diretamente no
/// documento do alarme — permite que a Cloud Function monte o link do
/// Google Maps sem precisar de uma segunda coleção/leitura.
class UltimaLocalizacaoModel {
  final double lat;
  final double lng;

  /// `null` ao montar o mapa para escrita = usa o timestamp do SERVIDOR
  /// (`FieldValue.serverTimestamp()`), preferível sempre que possível
  /// (evita depender do relógio do aparelho). Só vem preenchido ao ler de
  /// volta um documento já existente (ver [fromMap]).
  final DateTime? timestamp;

  const UltimaLocalizacaoModel({
    required this.lat,
    required this.lng,
    this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'lat': lat,
        'lng': lng,
        'timestamp': FieldValue.serverTimestamp(),
      };

  factory UltimaLocalizacaoModel.fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return const UltimaLocalizacaoModel(lat: 0, lng: 0);
    }
    final ts = map['timestamp'];
    return UltimaLocalizacaoModel(
      lat: (map['lat'] as num?)?.toDouble() ?? 0,
      lng: (map['lng'] as num?)?.toDouble() ?? 0,
      timestamp: ts is Timestamp ? ts.toDate() : null,
    );
  }
}

/// Modelo do documento `alarmes_agendados/{idAlarme}` no Firestore — uma
/// camada de monitoramento na nuvem PARALELA e independente do alarme
/// local (`android_alarm_manager_plus` + `RotinaAlarmeService`), pensada
/// para que uma Cloud Function agendada (ver `cloud_functions/`) possa
/// disparar o alerta de emergência mesmo que o aparelho seja
/// destruído/desligado/perca sinal antes do prazo local expirar.
///
/// NÃO substitui o fluxo local já validado (som, tela, tolerância, janela
/// final, SMS nativo) — é uma camada A MAIS de resiliência, assim como
/// `FirebaseSyncService` já é para o alerta reativo de tentativa de
/// desarme incorreta.
class AlarmeAgendadoModel {
  final String idAlarme;
  final DateTime dataHoraDisparo;

  /// Prazo REAL que a Cloud Function agendada (ver
  /// `cloud_functions/scheduledAlarmMonitor.ts`) usa para decidir se o
  /// alarme "venceu sem confirmação" — `dataHoraDisparo` + tolerância +
  /// janela final (`RotinaAlarmeService.duracaoJanelaFinal`), OU SEJA, o
  /// mesmo instante em que o alerta de emergência REAL dispara
  /// localmente. Calculado no app (que sabe a tolerância configurada por
  /// alarme) para a function não precisar reimplementar essa regra.
  final DateTime prazoFinalDisparo;

  final AlarmeAgendadoStatus status;
  final UltimaLocalizacaoModel? ultimaLocalizacao;
  final List<String> telefonesEmergencia;

  /// Etiqueta do alarme (ex: "Corrida no parque") e contexto
  /// personalizado (ex: "Vou por essa trilha, aviso quando voltar"),
  /// copiados do SQLite local — repassados para a Cloud Function incluir
  /// na mensagem de alerta, dando mais contexto aos contatos de
  /// emergência além de horário/localização.
  final String etiqueta;
  final String contextoPersonalizado;

  /// Tokens FCM dos "guardiões" (contatos com o app instalado) para
  /// notificação App-para-App — campo modelado desde já para a Cloud
  /// Function poder enviar `sendEachForMulticast`, mas ainda sem uma UI
  /// no app para o usuário vincular guardiões; por padrão fica vazio.
  final List<String> tokensGuardioes;

  const AlarmeAgendadoModel({
    required this.idAlarme,
    required this.dataHoraDisparo,
    required this.prazoFinalDisparo,
    this.status = AlarmeAgendadoStatus.pendente,
    this.ultimaLocalizacao,
    this.telefonesEmergencia = const [],
    this.tokensGuardioes = const [],
    this.etiqueta = '',
    this.contextoPersonalizado = '',
  });

  Map<String, dynamic> toFirestore() => {
        'idAlarme': idAlarme,
        'dataHoraDisparo': Timestamp.fromDate(dataHoraDisparo),
        'prazoFinalEpochMs': prazoFinalDisparo.millisecondsSinceEpoch,
        'status': status.valorFirestore,
        if (ultimaLocalizacao != null)
          'ultimaLocalizacao': ultimaLocalizacao!.toMap(),
        'telefonesEmergencia': telefonesEmergencia,
        'tokensGuardioes': tokensGuardioes,
        'etiqueta': etiqueta,
        'contextoPersonalizado': contextoPersonalizado,
      };

  factory AlarmeAgendadoModel.fromFirestore(
    Map<String, dynamic> dados,
    String idDocumento,
  ) {
    final dataHora = dados['dataHoraDisparo'];
    final prazoFinalEpochMs = dados['prazoFinalEpochMs'] as int?;
    return AlarmeAgendadoModel(
      idAlarme: (dados['idAlarme'] as String?) ?? idDocumento,
      dataHoraDisparo:
          dataHora is Timestamp ? dataHora.toDate() : DateTime.now(),
      prazoFinalDisparo: prazoFinalEpochMs != null
          ? DateTime.fromMillisecondsSinceEpoch(prazoFinalEpochMs)
          : (dataHora is Timestamp ? dataHora.toDate() : DateTime.now()),
      status: AlarmeAgendadoStatus.fromFirestore(dados['status'] as String?),
      ultimaLocalizacao: UltimaLocalizacaoModel.fromMap(
        dados['ultimaLocalizacao'] as Map<String, dynamic>?,
      ),
      telefonesEmergencia:
          (dados['telefonesEmergencia'] as List?)?.cast<String>() ?? const [],
      tokensGuardioes:
          (dados['tokensGuardioes'] as List?)?.cast<String>() ?? const [],
      etiqueta: (dados['etiqueta'] as String?) ?? '',
      contextoPersonalizado: (dados['contextoPersonalizado'] as String?) ?? '',
    );
  }
}
