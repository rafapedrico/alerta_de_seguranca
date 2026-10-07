import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import '../models/alarme_rotina.dart';
import 'alarme_agendado_cloud_service.dart';
import 'alarme_nativo_service.dart';
import 'background_location_heartbeat_service.dart';
import 'database_helper.dart';
import 'firebase_sync_service.dart';
import 'historico_alertas_service.dart';
import 'l10n_headless_service.dart';
import 'location_service.dart';
import 'notificacao_service.dart';
import 'plano_ciclo_service.dart';

/// Despertadores da aba Família (alarmes de rotina com PIN).
///
/// O agendamento em si é NATIVO (`DespertadorAgenda.kt`): o Dart sincroniza
/// a regra e o nativo arma a próxima ocorrência, toca no horário (tela cheia
/// sobre o bloqueio, som escolhido em loop até o PIN correto ou o fim da
/// tolerância) e liga a localização das 2 h antes. Aqui ficam as regras de
/// negócio que dependem do Dart: nuvem (`alarmes_agendados`, por ciclo),
/// histórico, notificações e o backup do fim da tolerância.
///
/// CICLO: o documento do ciclo atual fica PENDENTE (prazo = horário +
/// tolerância) até ser resolvido — PIN correto ([confirmarDesativacao]) ou
/// alerta ([registrarAlertaEnviado]). Só depois a próxima ocorrência é
/// armada (nativo) e registrada (nuvem).
class RotinaAlarmeService {
  RotinaAlarmeService._internal();
  static final RotinaAlarmeService _instance = RotinaAlarmeService._internal();
  factory RotinaAlarmeService() => _instance;

  /// Faixa de ids do `android_alarm_manager_plus` para o backup do fim da
  /// tolerância (não colide com a fila de reenvio nem com o alerta recebido).
  static const int _offsetIdBackupTolerancia = 30000;

  static int _idBackup(int idAlarme) => _offsetIdBackupTolerancia + idAlarme;

  static String _chaveResolvidoLocal(String chave) => 'despertador_resolvido_$chave';

  /// Marca a ocorrência como resolvida NESTE aparelho (cruza isolates via
  /// disco): o backup do fim da tolerância não dispara de novo.
  static Future<void> marcarResolvidoLocal(String chave) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_chaveResolvidoLocal(chave), true);
    } catch (_) {}
  }

  static Future<bool> estaResolvidoLocal(String chave) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getBool(_chaveResolvidoLocal(chave)) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 00h00 do dia seguinte à pausa (fim da pausa), ou `null`.
  static DateTime? fimDaPausa(Map<String, dynamic> alarmeMap) {
    final pausadoEm = AlarmeRotina.fromMap(alarmeMap).pausadoEm;
    if (pausadoEm == null) return null;
    final dia = DateTime.tryParse(pausadoEm);
    if (dia == null) return null;
    return DateTime(dia.year, dia.month, dia.day).add(const Duration(days: 1));
  }

  /// Sincroniza o despertador com a agenda nativa (que arma a próxima
  /// ocorrência válida — nunca durante uma ocorrência em andamento) e grava
  /// o ciclo dessa ocorrência na nuvem. Chamado ao criar, editar, reativar,
  /// pausar e ao abrir o app.
  static Future<OcorrenciaAlarme?> agendarAlarme(Map<String, dynamic> alarmeMap) async {
    final id = alarmeMap['id'] as int?;
    if (id == null) return null;
    if ((alarmeMap['ativo'] as int?) != 1) {
      await AlarmeNativoService.removerDespertador(id);
      return null;
    }
    final ocorrencia = await AlarmeNativoService.sincronizarDespertador(alarmeMap);
    if (ocorrencia != null) {
      unawaited(BackgroundLocationHeartbeatService().registrarAlarmeRotinaImediatamente(
        alarmeMap,
        ocorrencia: ocorrencia,
        pausadoAte: fimDaPausa(alarmeMap),
      ));
      debugPrint('⏰ Despertador #$id: próxima ocorrência ${DateTime.fromMillisecondsSinceEpoch(ocorrencia.ciclo)}');
    }
    return ocorrencia;
  }

  /// Apagar/desativar: desarma no nativo e marca CANCELADO na nuvem (o
  /// servidor não dispara).
  static Future<void> cancelarAlarme(int idAlarme) async {
    unawaited(AlarmeAgendadoCloudService().marcarCancelado(idAlarme.toString()));
    await AlarmeNativoService.removerDespertador(idAlarme);
    try {
      await AndroidAlarmManager.cancel(_idBackup(idAlarme));
    } catch (_) {}
    debugPrint('⏰ Despertador #$idAlarme cancelado.');
  }

  /// Pausa até 00h00 de amanhã: grava o dia da pausa (a agenda nativa pula
  /// as ocorrências de hoje) e registra na nuvem a próxima ocorrência
  /// válida com `pausadoAte`.
  static Future<OcorrenciaAlarme?> pausarAteAmanha(int idAlarme) async {
    final agora = DateTime.now();
    final hoje = '${agora.year.toString().padLeft(4, '0')}-'
        '${agora.month.toString().padLeft(2, '0')}-${agora.day.toString().padLeft(2, '0')}';
    await DatabaseHelper().definirAlarmePausado(idAlarme, hoje);
    final dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
    if (dados == null) return null;
    return agendarAlarme(dados);
  }

  /// Reativar antes das 00h00: tira a pausa e rearma.
  static Future<OcorrenciaAlarme?> despausarAlarme(int idAlarme) async {
    await DatabaseHelper().definirAlarmePausado(idAlarme, '0');
    final dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
    if (dados == null) return null;
    return agendarAlarme(dados);
  }

  /// Próxima ocorrência VÁLIDA (fora do dia pausado) — para o texto
  /// "Retorna" da lista. Mesmo algoritmo da agenda nativa.
  static DateTime? proximaOcorrenciaValida(Map<String, dynamic> alarmeMap) {
    final alarme = AlarmeRotina.fromMap(alarmeMap);
    final agora = DateTime.now();
    for (var offset = 0; offset <= 8; offset++) {
      final dia = DateTime(agora.year, agora.month, agora.day).add(Duration(days: offset));
      final candidato = DateTime(dia.year, dia.month, dia.day, alarme.hora, alarme.minuto);
      if (!candidato.isAfter(agora)) continue;
      if (alarme.diasSemana.isNotEmpty && !alarme.diasSemana.contains(candidato.weekday)) continue;
      if (alarme.diasSemana.isEmpty && offset > 0) return null;
      if (alarme.pausadoEm != null && alarme.pausadoEm == AlarmeRotina.dataIso(candidato)) continue;
      return candidato;
    }
    return null;
  }

  /// Compatibilidade com quem só precisa saber o próximo horário.
  static DateTime? proximoDisparoPrevisto(Map<String, dynamic> alarmeMap) =>
      proximaOcorrenciaValida(alarmeMap);

  /// Ao abrir o app (e depois de reiniciar o aparelho, pelo nativo):
  /// rearma todos os despertadores ativos — inclusive a tolerância de uma
  /// ocorrência em andamento — e o ciclo de cada um na nuvem.
  static Future<void> rearmarTodos() async {
    await AlarmeNativoService.rearmarTudo();
    try {
      final alarmes = await DatabaseHelper().listarAlarmes();
      final idsAtivos = <int>{};
      for (final alarme in alarmes) {
        final id = alarme['id'] as int?;
        if (id == null) continue;
        if ((alarme['ativo'] as int?) == 1) idsAtivos.add(id);
        await agendarAlarme(alarme);
      }
      debugPrint('⏰ ${idsAtivos.length} despertador(es) ativo(s) rearmado(s).');
    } catch (e) {
      debugPrint('⚠️ Falha ao rearmar os despertadores: $e');
    }
  }

  /// Plano Free nos dias bloqueados: desativa todos os despertadores
  /// (nativo + CANCELADO na nuvem, o servidor não dispara). Status
  /// desconhecido (sem rede) nunca desativa nada.
  static Future<void> desativarAlarmesSePlanoBloqueado() async {
    try {
      final status = await PlanoCicloService().obterStatusAtualizado();
      if (status == null || status.ativo) {
        // Agenda o próximo "início do bloqueio" (o despertador para no dia
        // em que o bloqueio começa, não só ao abrir o app).
        if (status != null && !status.isPremium) {
          unawaited(PlanoCicloService().agendarVerificacaoNoInicioDoBloqueio(status));
        }
        return;
      }
      final db = DatabaseHelper();
      final alarmes = await db.listarAlarmes();
      for (final mapa in alarmes.where((m) => (m['ativo'] as int?) == 1)) {
        final id = mapa['id'] as int;
        await cancelarAlarme(id);
        await db.alternarAtivoAlarme(id, false);
        debugPrint('🔒 Despertador #$id desativado — Plano Free nos dias bloqueados.');
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao desativar despertadores por plano bloqueado: $e');
    }
  }

  // ==========================================================
  // DESFECHO DE UMA OCORRÊNCIA
  // ==========================================================

  /// PIN correto: CONFIRMADO_SEGURA no ciclo atual, som parado (nativo),
  /// notificação "Despertador desativado (pausado)", histórico — e só então
  /// a próxima ocorrência é armada.
  static Future<void> confirmarDesativacao(OcorrenciaAlarme ocorrencia) async {
    await marcarResolvidoLocal(ocorrencia.chave);
    await AlarmeNativoService.resolver(ocorrencia.chave);
    try {
      await AndroidAlarmManager.cancel(_idBackup(ocorrencia.id));
    } catch (_) {}
    unawaited(AlarmeAgendadoCloudService()
        .marcarConfirmadoSeguro(ocorrencia.id.toString(), ciclo: ocorrencia.ciclo)
        .then((_) => _registrarProximoCiclo(ocorrencia.id)));

    final l10n = await L10nHeadlessService.obter();
    final dados = await DatabaseHelper().buscarAlarmePorId(ocorrencia.id);
    final etiqueta = dados != null
        ? AlarmeRotina.fromMap(dados).etiquetaExibida(l10n)
        : l10n.familiaEtiquetaPadrao;
    final posicao = await _posicaoRapida();
    await DatabaseHelper().inserirEventoHistorico(
      titulo: l10n.despertadorDesativadoPausado,
      descricao: l10n.historicoDespertadorDesativadoDescricao(etiqueta),
      categoria: 'familia',
      latitude: posicao?.$1,
      longitude: posicao?.$2,
      precisao: posicao?.$3,
    );
    await NotificacaoService.exibirNotificacaoInformativa(
      id: 70100 + ocorrencia.id % 800,
      titulo: etiqueta,
      corpo: l10n.despertadorDesativadoPausado,
    );
  }

  /// Alerta enviado (3 PINs errados ou tolerância esgotada): ALERTA_DISPARADO
  /// no ciclo atual, som parado, e a próxima ocorrência armada.
  static Future<void> registrarAlertaEnviado(OcorrenciaAlarme ocorrencia) async {
    await marcarResolvidoLocal(ocorrencia.chave);
    await AlarmeNativoService.resolver(ocorrencia.chave);
    try {
      await AndroidAlarmManager.cancel(_idBackup(ocorrencia.id));
    } catch (_) {}
    await AlarmeAgendadoCloudService()
        .marcarAlertaDisparado(ocorrencia.id.toString(), ciclo: ocorrencia.ciclo);
    unawaited(_registrarProximoCiclo(ocorrencia.id));
  }

  static Future<void> _registrarProximoCiclo(int idAlarme) async {
    try {
      final dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
      if (dados == null || (dados['ativo'] as int?) != 1) return;
      final proxima = await AlarmeNativoService.proximaOcorrencia(idAlarme);
      await BackgroundLocationHeartbeatService().registrarAlarmeRotinaImediatamente(
        dados,
        ocorrencia: proxima,
        pausadoAte: fimDaPausa(dados),
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao registrar o próximo ciclo do despertador #$idAlarme: $e');
    }
  }

  /// Backup do fim da tolerância (isolate headless do
  /// `android_alarm_manager_plus`): se a tela não resolveu a ocorrência até
  /// o prazo, dispara o alerta pela nuvem EXATAMENTE no fim da tolerância.
  static Future<void> agendarBackupFimTolerancia(OcorrenciaAlarme ocorrencia) async {
    try {
      await AndroidAlarmManager.oneShotAt(
        DateTime.fromMillisecondsSinceEpoch(ocorrencia.prazo),
        _idBackup(ocorrencia.id),
        _callbackFimToleranciaDespertador,
        exact: true,
        wakeup: true,
        allowWhileIdle: true,
        rescheduleOnReboot: true,
        params: {'idAlarme': ocorrencia.id, 'ciclo': ocorrencia.ciclo, 'prazo': ocorrencia.prazo},
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao agendar o backup do fim da tolerância: $e');
    }
  }

  static Future<(double, double, double)?> _posicaoRapida() async {
    try {
      final posicao = await LocationService().posicaoRecente();
      if (posicao == null) return null;
      return (posicao.latitude, posicao.longitude, posicao.accuracy);
    } catch (_) {
      return null;
    }
  }
}

/// Fim da tolerância de um despertador sem resolução local (backup da
/// tela): alerta pela nuvem (o SMS só sai pela tela — o isolate headless não
/// tem o canal de SMS), status ALERTA_DISPARADO no ciclo, histórico e a
/// notificação de alerta enviado.
@pragma('vm:entry-point')
void _callbackFimToleranciaDespertador(int idParam, Map<String, dynamic> params) async {
  final idAlarme = params['idAlarme'] as int? ?? idParam;
  final ciclo = (params['ciclo'] as num?)?.toInt() ?? 0;
  final prazo = (params['prazo'] as num?)?.toInt() ?? 0;
  final ocorrencia = OcorrenciaAlarme(
    tipo: OcorrenciaAlarme.tipoRotina,
    id: idAlarme,
    ciclo: ciclo,
    prazo: prazo,
  );
  // Prazo vencido há muito (ex.: aparelho religado depois) — o servidor
  // já cuidou do alerta.
  if (DateTime.now().millisecondsSinceEpoch > prazo + 5 * 60 * 1000) return;
  if (await RotinaAlarmeService.estaResolvidoLocal(ocorrencia.chave)) return;

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
          .timeout(const Duration(seconds: 8));
    }
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Firebase indisponível: $e');
  }
  if (await AlarmeAgendadoCloudService().cicloJaResolvidoNaNuvem(idAlarme.toString(), ciclo)) {
    await RotinaAlarmeService.marcarResolvidoLocal(ocorrencia.chave);
    return;
  }
  // A tela pode ter resolvido enquanto o Firebase subia.
  if (await RotinaAlarmeService.estaResolvidoLocal(ocorrencia.chave)) return;
  await RotinaAlarmeService.marcarResolvidoLocal(ocorrencia.chave);

  final l10n = await L10nHeadlessService.obter();
  final dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
  final alarme = dados != null ? AlarmeRotina.fromMap(dados) : null;
  final etiqueta = alarme?.etiquetaExibida(l10n) ?? l10n.familiaEtiquetaPadrao;
  final motivo = l10n.historicoCheckinRotinaFalhaMotivo(etiqueta);
  final alertaId = 'rotina_${idAlarme}_$ciclo';

  await HistoricoAlertasService().criarAlerta(
    alertaId: alertaId,
    tipo: TipoAlertaHistorico.despertadorExpirado,
    titulo: l10n.historicoTipoDespertadorExpirado,
    descricao: motivo,
    contexto: alarme?.contextoPersonalizado,
  );
  final enviado = await FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto(
    motivo: motivo,
    eventoId: alertaId,
    tipo: TipoAlertaHistorico.despertadorExpirado,
    contextoPersonalizado: alarme?.contextoPersonalizado,
  );
  await HistoricoAlertasService().marcarStatus(
    alertaId,
    enviado.confirmado ? StatusAlertaHistorico.enviado : StatusAlertaHistorico.pendente,
  );
  await AlarmeAgendadoCloudService().marcarAlertaDisparado(idAlarme.toString(), ciclo: ciclo);
  try {
    await NotificacaoService.exibirNotificacaoAlertaEnviado(
      corpo: l10n.despertadorNotif3ErrosCorpo,
    );
  } catch (_) {}
}
