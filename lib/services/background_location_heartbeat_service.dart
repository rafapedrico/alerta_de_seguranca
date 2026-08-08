import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/alarme_agendado_model.dart';
import 'alarme_agendado_cloud_service.dart';
import 'database_helper.dart';
import 'firebase_auth_service.dart';
import 'location_service.dart';
import 'rotina_alarme_service.dart';

/// Janela de REGISTRO (dead man's switch): todo alarme ativo entra em
/// `alarmes_agendados` (status PENDENTE, com `prazoFinalDisparo` e
/// telefones de emergência) assim que faltar isto ou menos para o
/// próximo disparo — MESMO sem GPS recente ainda — garantindo que a
/// Cloud Function agendada (ver `cloud_functions/scheduledAlarmMonitor.ts`)
/// já saiba do alarme com bastante antecedência, cobrindo o cenário em
/// que o aparelho é destruído/desligado bem antes do horário programado.
const Duration janelaRegistro48h = Duration(hours: 48);

/// Janela de LOCALIZAÇÃO: só dentro deste período (mais curto que a
/// janela de registro) o heartbeat também captura o GPS e o anexa ao
/// documento — mantém o consumo de bateria/GPS restrito ao período em
/// que uma posição recente realmente importa.
const Duration janelaLocalizacao2h = Duration(hours: 2);

/// Intervalo entre cada ciclo do heartbeat (registro de 48h +,
/// opcionalmente, localização de 2h) — 1 minuto por especificação do
/// usuário (2026-08-07, item 7: "a cada 1 minuto" dentro da janela de
/// 120 minutos antes do horário agendado). Antes era 2 minutos.
const Duration intervaloHeartbeat = Duration(minutes: 1);

/// Serviço em segundo plano, TOTALMENTE independente do alarme local
/// (`android_alarm_manager_plus` + `RotinaAlarmeService`), com DUAS
/// responsabilidades:
///
/// 1. **Registro antecipado (dead man's switch, ≤48h)**: mantém
///    `alarmes_agendados/{idAlarme}` atualizado com `dataHoraDisparo`,
///    `prazoFinalDisparo` (dataHoraDisparo + tolerância + janela final —
///    o MESMO instante em que o alerta real dispararia localmente) e
///    `contatosEmergencia`, para que a Cloud Function agendada consiga
///    agir mesmo que o aparelho nunca mais responda depois disso.
/// 2. **Localização recente (≤2h)**: dentro desta janela mais estreita,
///    também captura o GPS a cada ciclo e o anexa ao mesmo documento
///    (sobrescrevendo sempre a leitura anterior) — usado pela Cloud
///    Function para montar o link do mapa no alerta, se o disparo
///    realmente acontecer.
///
/// Roda como um `Timer.periodic` simples dentro do isolate principal do
/// app (iniciado uma única vez em `main()`) — NÃO é um serviço Android
/// nativo em primeiro plano, então só atualiza enquanto o processo Dart
/// estiver vivo. NUNCA interfere com o alarme local já validado (som,
/// tela, tolerância, janela final, SMS nativo) — qualquer falha aqui é
/// apenas registrada via [debugPrint] e nunca propagada.
class BackgroundLocationHeartbeatService {
  BackgroundLocationHeartbeatService._internal();
  static final BackgroundLocationHeartbeatService _instance =
      BackgroundLocationHeartbeatService._internal();
  factory BackgroundLocationHeartbeatService() => _instance;

  Timer? _timer;

  /// Inicia o ciclo de heartbeat, se ainda não estiver rodando —
  /// idempotente (chamadas repetidas são ignoradas). Não bloqueia quem
  /// chama: o primeiro ciclo roda em segundo plano (fire-and-forget).
  void iniciar() {
    if (_timer != null) return;
    unawaited(_executarCiclo());
    _timer = Timer.periodic(intervaloHeartbeat, (_) => _executarCiclo());
  }

  /// Encerra o ciclo. Não usado hoje pelo fluxo normal do app (o
  /// heartbeat roda durante toda a vida do processo), mas disponível para
  /// testes e para um eventual encerramento explícito futuro.
  void parar() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _executarCiclo() async {
    try {
      final usuarioId = FirebaseAuthService().uidAtual;
      if (usuarioId == null) return;

      final alarmes = await DatabaseHelper().listarAlarmes();
      final agora = DateTime.now();

      final candidatos = <({
        Map<String, dynamic> alarme,
        DateTime proximoDisparo,
        DateTime prazoFinal,
        bool dentroDaJanelaDeLocalizacao,
      })>[];

      for (final alarme in alarmes) {
        final ativo = (alarme['ativo'] as int?) == 1;
        if (!ativo) continue;

        final proximoDisparo = RotinaAlarmeService.proximoDisparoPrevisto(alarme);
        if (proximoDisparo == null) continue;

        final faltam = proximoDisparo.difference(agora);
        if (faltam.isNegative || faltam > janelaRegistro48h) continue;

        final minutosTolerancia = alarme['minutos_tolerancia'] as int? ?? 10;
        final prazoFinal = proximoDisparo
            .add(Duration(minutes: minutosTolerancia))
            .add(RotinaAlarmeService.duracaoJanelaFinal);

        candidatos.add((
          alarme: alarme,
          proximoDisparo: proximoDisparo,
          prazoFinal: prazoFinal,
          dentroDaJanelaDeLocalizacao: faltam <= janelaLocalizacao2h,
        ));
      }

      if (candidatos.isEmpty) return;

      final precisaLocalizacao =
          candidatos.any((c) => c.dentroDaJanelaDeLocalizacao);
      final posicao =
          precisaLocalizacao ? await LocationService().capturarLocalizacaoAtual() : null;

      final contatos = await _resolverContatosEmergencia();

      for (final candidato in candidatos) {
        final idAlarme = (candidato.alarme['id'] as int?)?.toString();
        if (idAlarme == null) continue;

        final incluirLocalizacao =
            candidato.dentroDaJanelaDeLocalizacao && posicao != null;

        await AlarmeAgendadoCloudService().registrarAlarmeAgendado(
          AlarmeAgendadoModel(
            idAlarme: idAlarme,
            usuarioId: usuarioId,
            dataHoraDisparo: candidato.proximoDisparo,
            prazoFinalDisparo: candidato.prazoFinal,
            contatosEmergencia: contatos,
            etiqueta: (candidato.alarme['etiqueta'] as String?) ?? '',
            contextoPersonalizado:
                (candidato.alarme['contexto_personalizado'] as String?) ?? '',
            ultimaLocalizacao: incluirLocalizacao
                ? UltimaLocalizacaoModel(lat: posicao.latitude, lng: posicao.longitude)
                : null,
          ),
        );
      }

      final comLocalizacao =
          candidatos.where((c) => c.dentroDaJanelaDeLocalizacao).length;
      debugPrint(
          '💓 [BackgroundLocationHeartbeatService] Ciclo executado — '
          '${candidatos.length} alarme(s) dentro da janela de 48h '
          '($comLocalizacao com localização, dentro de 2h).');
    } catch (e) {
      debugPrint(
          '⚠️ [BackgroundLocationHeartbeatService] Falha no ciclo de heartbeat: $e');
    }
  }

  /// Mesmo formato `{nome, telefone, whatsappHabilitado}` gravado em
  /// `usuarios/{uid}.contatosEmergencia` (ver
  /// `FirebaseSyncService.sincronizarContatosEmergencia`), repassado
  /// junto com o alarme agendado para a Cloud Function de disparo poder
  /// aplicar as mesmas regras de contingência via WhatsApp.
  Future<List<Map<String, dynamic>>> _resolverContatosEmergencia() async {
    try {
      final contatos = await DatabaseHelper().getContatosEmergencia();
      return contatos
          .map((c) => {
                'nome': (c['nome'] as String?) ?? '',
                'telefone': (c['telefone'] as String?) ?? '',
                'whatsappHabilitado': (c['whatsapp_habilitado'] as int?) == 1,
              })
          .where((c) => (c['telefone'] as String).isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint(
          '⚠️ [BackgroundLocationHeartbeatService] Falha ao resolver contatos de emergência: $e');
      return const [];
    }
  }
}
