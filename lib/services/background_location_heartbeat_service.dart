import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/alarme_agendado_model.dart';
import 'alarme_agendado_cloud_service.dart';
import 'alarme_service.dart';
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

  /// Id fixo (namespaced por usuário dentro de
  /// [AlarmeAgendadoCloudService]) usado para o documento de dead man's
  /// switch do cronômetro de check-in da aba Segurança — REAPROVEITADO a
  /// cada novo ciclo, diferente dos ids numéricos (autoincrement do
  /// SQLite) dos alarmes de rotina. Por isso todo novo ciclo precisa
  /// reiniciar explicitamente o documento como PENDENTE (ver
  /// [registrarCheckinAtivo]/[AlarmeAgendadoCloudService.reiniciarCicloComoPendente])
  /// — sem isso, um ciclo novo herdaria o status (CONFIRMADO_SEGURA ou
  /// ALERTA_DISPARADO) de um ciclo anterior já concluído.
  static const String idAlarmeCheckinSeguranca = 'checkin_seguranca';

  // Estado do cronômetro de check-in ATIVO (aba Segurança), se houver —
  // ver [registrarCheckinAtivo]/[cancelarCheckinAtivo]. `null` em
  // [_checkinDataHoraDisparoAtiva] significa "nenhum check-in ativo no
  // momento", omitindo completamente esse candidato do ciclo.
  DateTime? _checkinDataHoraDisparoAtiva;
  String _checkinContextoAtivo = '';
  bool _checkinPrecisaReiniciarCiclo = false;

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

  /// Registra o cronômetro de check-in ATIVO da aba Segurança como
  /// candidato a dead man's switch neste heartbeat, reaproveitando a
  /// MESMA infraestrutura já validada para os alarmes de rotina
  /// ([AlarmeAgendadoCloudService] + `scheduledAlarmMonitor.js`). Chamado
  /// uma única vez ao iniciar o cronômetro (`SegurancaTab._iniciarTimer`).
  ///
  /// Diferente dos alarmes de rotina (que somam tolerância + janela
  /// final ao horário bruto para calcular o prazo), [dataHoraDisparo] JÁ
  /// é o prazo final: o cronômetro de check-in deve disparar exatamente
  /// no fim do tempo escolhido pelo usuário, sem tolerância extra (regra
  /// de negócio reespecificada em 2026-08-09).
  ///
  /// Dispara imediatamente um ciclo extra (sem esperar o próximo tick de
  /// até 1 minuto) para que o documento na nuvem exista o quanto antes, e
  /// marca [_checkinPrecisaReiniciarCiclo] para que esse primeiro ciclo
  /// reinicie o documento como um ciclo NOVO (nunca herdando o status de
  /// um check-in anterior já concluído).
  void registrarCheckinAtivo({
    required DateTime dataHoraDisparo,
    required String contexto,
  }) {
    _checkinDataHoraDisparoAtiva = dataHoraDisparo;
    _checkinContextoAtivo = contexto;
    _checkinPrecisaReiniciarCiclo = true;
    unawaited(_executarCiclo());
  }

  /// Encerra o acompanhamento do check-in ativo (desarmado com sucesso OU
  /// alerta já disparado localmente) — o heartbeat para de atualizar esse
  /// documento. Propositalmente NÃO altera o status na nuvem aqui: mesma
  /// filosofia já usada pelos alarmes de rotina — se o disparo local já
  /// aconteceu, o documento simplesmente para de ser atualizado; a Cloud
  /// Function agendada continua sendo a rede de segurança final mesmo sem
  /// essa chamada (redundância deliberada, nunca risco de "esquecer" de
  /// alertar).
  void cancelarCheckinAtivo() {
    _checkinDataHoraDisparoAtiva = null;
    _checkinContextoAtivo = '';
    _checkinPrecisaReiniciarCiclo = false;
  }

  /// Marca o check-in ativo como desarmado com sucesso (PIN correto) —
  /// avisa a nuvem IMEDIATAMENTE (ver
  /// [AlarmeAgendadoCloudService.marcarConfirmadoSeguro]) e encerra o
  /// acompanhamento local, chamado por `SegurancaTab._aoConfirmarPinCorreto`.
  void confirmarCheckinSeguro() {
    unawaited(AlarmeAgendadoCloudService()
        .marcarConfirmadoSeguro(idAlarmeCheckinSeguranca));
    cancelarCheckinAtivo();
  }

  /// Marca o check-in ativo como ALERTA JÁ DISPARADO localmente (3ª
  /// tentativa de PIN incorreta OU os 60s de tolerância se esgotando, ver
  /// `CronometroDisparadoScreen._dispararAlerta`) — avisa a nuvem
  /// IMEDIATAMENTE (ver [AlarmeAgendadoCloudService.marcarAlertaDisparado])
  /// e encerra o acompanhamento local, mesmo papel de
  /// [confirmarCheckinSeguro] para o outro desfecho possível do ciclo.
  ///
  /// CORREÇÃO DE BUG REAL (2026-08-15, duplo disparo do Cronômetro): sem
  /// isto, o documento `alarmes_agendados/checkin_seguranca` continuava
  /// PENDENTE mesmo após o alerta já ter sido enviado pelo aparelho (3ª
  /// senha errada, antes do fim natural dos 60s) — e a Cloud Function
  /// `monitorarAlarmesAgendados`, ao rodar minutos depois e ver o prazo
  /// original já vencido num documento ainda PENDENTE, disparava um
  /// SEGUNDO alerta duplicado. Chamar isto no mesmo instante do disparo
  /// local (`_dispararAlerta`, cobrindo tanto a 3ª senha errada quanto o
  /// timeout natural) tira o documento da consulta da function.
  void confirmarAlertaJaDisparado() {
    unawaited(AlarmeAgendadoCloudService()
        .marcarAlertaDisparado(idAlarmeCheckinSeguranca));
    cancelarCheckinAtivo();
  }

  /// Grava o documento `alarmes_agendados/{idAlarme}` como PENDENTE
  /// IMEDIATAMENTE — chamado por [RotinaAlarmeService.agendarAlarme] toda
  /// vez que um alarme de rotina é criado, editado, reativado ou
  /// reagendado (para a PRÓXIMA ocorrência), sem esperar o próximo ciclo
  /// do heartbeat.
  ///
  /// CORREÇÃO DE PONTO CEGO ARQUITETURAL (pedido explícito do usuário,
  /// 2026-09-06): antes, o documento só nascia quando o heartbeat via o
  /// alarme entrar na [janelaRegistro48h] — um alarme agendado para
  /// dias/uma semana no futuro ficava, até lá, com ZERO registro na
  /// nuvem. Se o processo Dart fosse encerrado pelo Android antes de
  /// algum ciclo do heartbeat rodar dentro dessas 48h (nada raro em
  /// vários dias), e o aparelho fosse destruído/roubado/sem bateria
  /// exatamente nesse intervalo, `monitorarAlarmesAgendados`
  /// (`functions/scheduledAlarmMonitor.js`) não tinha NENHUM documento
  /// para agir — a rede de segurança da nuvem ficava cega justamente no
  /// cenário que ela deveria cobrir. Gravar aqui, no instante exato do
  /// agendamento, elimina essa janela de exposição por completo: a partir
  /// de agora, um alarme tem cobertura na nuvem por TODA a sua vida, não
  /// só nas últimas 48h.
  ///
  /// Sempre grava como um ciclo NOVO ([reiniciarCicloComoPendente], nunca
  /// [registrarAlarmeAgendado]) — correto tanto para uma criação de
  /// verdade quanto para o reagendamento da PRÓXIMA ocorrência de um
  /// alarme recorrente, que deve sempre nascer como um ciclo limpo,
  /// nunca herdar o status (CONFIRMADO_SEGURA/ALERTA_DISPARADO) do ciclo
  /// anterior. Depois deste registro inicial, o ciclo normal do heartbeat
  /// (a cada 1 min, dentro de 48h) assume a manutenção do MESMO
  /// documento via [AlarmeAgendadoCloudService.registrarAlarmeAgendado]
  /// (merge, preservando o status) — sem conflito entre os dois.
  ///
  /// SEM localização neste momento, de propósito: não faz sentido gastar
  /// GPS/bateria numa leitura que pode ficar velha por dias antes do
  /// alarme sequer entrar na janela em que a localização importa (ver
  /// [janelaLocalizacao2h]) — a Cloud Function já trata
  /// `ultimaLocalizacao` ausente/velha explicitamente (ver
  /// `montarTextoLocalizacao` em `scheduledAlarmMonitor.js`), e o próprio
  /// heartbeat periódico anexa a localização normalmente assim que o
  /// alarme entrar nas últimas 2h.
  ///
  /// Nunca lança exceção nem bloqueia quem chama — mesma postura
  /// defensiva do resto desta classe: se o Firebase não estiver
  /// disponível nesta isolate específica (ex: reagendamento chamado de
  /// dentro do isolate headless do alarme nativo, sem Firebase
  /// inicializado), [AlarmeAgendadoCloudService] já faz o no-op
  /// silencioso sozinho — o próximo ciclo do heartbeat, já no engine
  /// principal, cobre o registro assim que o app reabrir.
  Future<void> registrarAlarmeRotinaImediatamente(
    Map<String, dynamic> alarmeMap,
  ) async {
    try {
      final usuarioId = FirebaseAuthService().uidAtual;
      if (usuarioId == null) return;

      final idAlarme = (alarmeMap['id'] as int?)?.toString();
      if (idAlarme == null) return;

      final proximoDisparo = RotinaAlarmeService.proximoDisparoPrevisto(alarmeMap);
      if (proximoDisparo == null) return;

      final minutosTolerancia = alarmeMap['minutos_tolerancia'] as int? ?? 10;
      final prazoFinal = proximoDisparo
          .add(Duration(minutes: minutosTolerancia))
          .add(RotinaAlarmeService.duracaoJanelaFinal);

      final contatos = await _resolverContatosEmergencia();

      final modelo = AlarmeAgendadoModel(
        idAlarme: idAlarme,
        usuarioId: usuarioId,
        dataHoraDisparo: proximoDisparo,
        prazoFinalDisparo: prazoFinal,
        contatosEmergencia: contatos,
        etiqueta: (alarmeMap['etiqueta'] as String?) ?? '',
        contextoPersonalizado:
            (alarmeMap['contexto_personalizado'] as String?) ?? '',
      );

      await AlarmeAgendadoCloudService().reiniciarCicloComoPendente(modelo);
      debugPrint(
          '☁️ [BackgroundLocationHeartbeatService] Alarme de rotina #$idAlarme '
          'registrado IMEDIATAMENTE na nuvem (sem esperar a janela de 48h).');
    } catch (e) {
      debugPrint(
          '⚠️ [BackgroundLocationHeartbeatService] Falha ao registrar alarme '
          'de rotina imediatamente na nuvem: $e');
    }
  }

  Future<void> _executarCiclo() async {
    try {
      final usuarioId = FirebaseAuthService().uidAtual;
      if (usuarioId == null) return;

      final alarmes = await DatabaseHelper().listarAlarmes();
      final agora = DateTime.now();

      final candidatos = <({
        String idAlarme,
        DateTime proximoDisparo,
        DateTime prazoFinal,
        bool dentroDaJanelaDeLocalizacao,
        String etiqueta,
        String contextoPersonalizado,
        bool reiniciarComoPendente,
      })>[];

      for (final alarme in alarmes) {
        final ativo = (alarme['ativo'] as int?) == 1;
        if (!ativo) continue;

        final proximoDisparo = RotinaAlarmeService.proximoDisparoPrevisto(alarme);
        if (proximoDisparo == null) continue;

        final faltam = proximoDisparo.difference(agora);
        if (faltam.isNegative || faltam > janelaRegistro48h) continue;

        final idAlarme = (alarme['id'] as int?)?.toString();
        if (idAlarme == null) continue;

        final minutosTolerancia = alarme['minutos_tolerancia'] as int? ?? 10;
        final prazoFinal = proximoDisparo
            .add(Duration(minutes: minutosTolerancia))
            .add(RotinaAlarmeService.duracaoJanelaFinal);

        candidatos.add((
          idAlarme: idAlarme,
          proximoDisparo: proximoDisparo,
          prazoFinal: prazoFinal,
          dentroDaJanelaDeLocalizacao: faltam <= janelaLocalizacao2h,
          etiqueta: (alarme['etiqueta'] as String?) ?? '',
          contextoPersonalizado:
              (alarme['contexto_personalizado'] as String?) ?? '',
          // CORREÇÃO DE DÉBITO TÉCNICO (2026-08-15): antes, sempre `false`
          // — o documento deste alarme (id FIXO, reaproveitado a cada
          // repetição) nunca voltava a PENDENTE depois do primeiro ciclo,
          // desarmando a proteção da Cloud Function para as ocorrências
          // seguintes. Consome (lê E remove) a sinalização gravada pelos
          // caminhos de resolução de ciclo (PIN correto, alerta disparado,
          // reativação manual) — ver
          // [AlarmeAgendadoCloudService.sinalizarNovoCiclo].
          reiniciarComoPendente: AlarmeAgendadoCloudService()
              .consumirSinalizacaoDeNovoCiclo(idAlarme),
        ));
      }

      // Cronômetro de check-in ATIVO da aba Segurança (ver
      // [registrarCheckinAtivo]), se houver — mesma janela de registro
      // (48h) e de localização (2h) usada pelos alarmes de rotina.
      // [prazoFinal] = [checkinDisparo] + 60s (reespecificação do
      // usuário, 2026-08-10, ajustada de 180s para 60s em 2026-08-11):
      // ao zerar, o Cronômetro concede uma tolerância sonora de 60
      // segundos com o teclado de PIN aberto
      // (ver `AlarmeService.duracaoJanelaFinalCronometro`/
      // `cronometro_disparado_screen.dart`) antes de qualquer alerta real
      // ser disparado — o mesmo prazo usado por
      // `functions/scheduledAlarmMonitor.js` como rede de segurança
      // offline precisa refletir esse fim real, não mais o zero puro.
      final checkinDisparo = _checkinDataHoraDisparoAtiva;
      if (checkinDisparo != null) {
        final faltam = checkinDisparo.difference(agora);
        if (!faltam.isNegative && faltam <= janelaRegistro48h) {
          candidatos.add((
            idAlarme: idAlarmeCheckinSeguranca,
            proximoDisparo: checkinDisparo,
            prazoFinal:
                checkinDisparo.add(AlarmeService.duracaoJanelaFinalCronometro),
            dentroDaJanelaDeLocalizacao: faltam <= janelaLocalizacao2h,
            etiqueta: 'Check-in de Segurança',
            contextoPersonalizado: _checkinContextoAtivo,
            reiniciarComoPendente: _checkinPrecisaReiniciarCiclo,
          ));
          _checkinPrecisaReiniciarCiclo = false;
        }
      }

      if (candidatos.isEmpty) return;

      final precisaLocalizacao =
          candidatos.any((c) => c.dentroDaJanelaDeLocalizacao);
      final posicao =
          precisaLocalizacao ? await LocationService().capturarLocalizacaoAtual() : null;

      final contatos = await _resolverContatosEmergencia();

      for (final candidato in candidatos) {
        final incluirLocalizacao =
            candidato.dentroDaJanelaDeLocalizacao && posicao != null;

        final modelo = AlarmeAgendadoModel(
          idAlarme: candidato.idAlarme,
          usuarioId: usuarioId,
          dataHoraDisparo: candidato.proximoDisparo,
          prazoFinalDisparo: candidato.prazoFinal,
          contatosEmergencia: contatos,
          etiqueta: candidato.etiqueta,
          contextoPersonalizado: candidato.contextoPersonalizado,
          ultimaLocalizacao: incluirLocalizacao
              ? UltimaLocalizacaoModel(lat: posicao.latitude, lng: posicao.longitude)
              : null,
        );

        if (candidato.reiniciarComoPendente) {
          await AlarmeAgendadoCloudService().reiniciarCicloComoPendente(modelo);
        } else {
          await AlarmeAgendadoCloudService().registrarAlarmeAgendado(modelo);
        }
      }

      final comLocalizacao =
          candidatos.where((c) => c.dentroDaJanelaDeLocalizacao).length;
      debugPrint(
          '💓 [BackgroundLocationHeartbeatService] Ciclo executado — '
          '${candidatos.length} candidato(s) dentro da janela de 48h '
          '($comLocalizacao com localização, dentro de 2h).');
    } catch (e) {
      debugPrint(
          '⚠️ [BackgroundLocationHeartbeatService] Falha no ciclo de heartbeat: $e');
    }
  }

  /// Mesmo formato `{nome, telefone}` gravado em
  /// `usuarios/{uid}.contatosEmergencia` (ver
  /// `FirebaseSyncService.sincronizarContatosEmergencia`), repassado
  /// junto com o alarme agendado para a Cloud Function de disparo poder
  /// resolver o Push FCM.
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
      debugPrint(
          '⚠️ [BackgroundLocationHeartbeatService] Falha ao resolver contatos de emergência: $e');
      return const [];
    }
  }
}
