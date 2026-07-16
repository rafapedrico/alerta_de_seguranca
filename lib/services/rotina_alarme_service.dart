import 'dart:async';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_helper.dart';
import 'emergency_alert_service.dart';
import 'notificacao_service.dart';

// Canal unificado para comunicação nativa
const MethodChannel _canalRotinaAlarme =
    MethodChannel('com.example.security_check_app/rotina_alarme');

class RotinaAlarmeService {
  RotinaAlarmeService._internal();
  static final RotinaAlarmeService _instance = RotinaAlarmeService._internal();
  factory RotinaAlarmeService() => _instance;

  static const int _offsetIdCheckin = 20000;
  static const int _offsetIdTolerancia = 30000;

  static int _idCheckin(int idAlarme) => _offsetIdCheckin + idAlarme;
  static int _idTolerancia(int idAlarme) => _offsetIdTolerancia + idAlarme;

  static Future<void> agendarAlarme(Map<String, dynamic> alarmeMap) async {
    final id = alarmeMap['id'] as int?;
    if (id == null) return;

    final hora = alarmeMap['hora'] as int? ?? 0;
    final minuto = alarmeMap['minuto'] as int? ?? 0;
    final diasSemanaCsv = alarmeMap['dias_semana'] as String? ?? '';

    final proximoDisparo = _calcularProximoDisparo(hora, minuto, diasSemanaCsv);
    if (proximoDisparo == null) {
      final agora = DateTime.now();
      final candidato = DateTime(agora.year, agora.month, agora.day, hora, minuto);
      if (candidato.isBefore(agora)) return;
      await _agendarNativo(id, candidato);
      return;
    }

    await _agendarNativo(id, proximoDisparo);
  }

  static Future<void> _agendarNativo(int idAlarme, DateTime dataHoraDisparo) async {
    await AndroidAlarmManager.cancel(_idCheckin(idAlarme));

    await AndroidAlarmManager.oneShotAt(
      dataHoraDisparo,
      _idCheckin(idAlarme),
      _callbackCheckinRotina,
      exact: true,
      wakeup: true,
      rescheduleOnReboot: true,
      params: {'idAlarme': idAlarme},
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('stop_current_alarm');

    debugPrint(
        '⏰ Alarme de rotina #$idAlarme agendado para ${dataHoraDisparo.toIso8601String()}');
  }

  static DateTime? _calcularProximoDisparo(int hora, int minuto, String diasSemanaCsv) {
    final dias = diasSemanaCsv
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
    if (dias.isEmpty) return null;

    final agora = DateTime.now();
    for (int offset = 0; offset < 8; offset++) {
      final candidatoData = agora.add(Duration(days: offset));
      final diaSemanaCandidato = candidatoData.weekday;
      if (!dias.contains(diaSemanaCandidato)) continue;

      final candidato = DateTime(
        candidatoData.year,
        candidatoData.month,
        candidatoData.day,
        hora,
        minuto,
      );
      if (candidato.isAfter(agora)) return candidato;
    }
    return null;
  }

  static Future<void> cancelarAlarme(int idAlarme) async {
    await AndroidAlarmManager.cancel(_idCheckin(idAlarme));
    await AndroidAlarmManager.cancel(_idTolerancia(idAlarme));
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
    debugPrint('⏰ Alarme de rotina #$idAlarme cancelado.');
  }

  static Future<void> pausarAlarme(int idAlarme) async {
    await AndroidAlarmManager.cancel(_idCheckin(idAlarme));
    await AndroidAlarmManager.cancel(_idTolerancia(idAlarme));
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);

    try {
      await DatabaseHelper().definirAlarmePausado(idAlarme, true);
    } catch (e) {
      debugPrint('⚠️ Falha ao marcar alarme #$idAlarme como pausado: $e');
    }

    try {
      // Chama apenas o método que o Kotlin realmente implementa
      await _canalRotinaAlarme.invokeMethod('pararAlarme');
    } catch (e) {
      debugPrint('⚠️ Falha ao parar som nativo do alarme #$idAlarme: $e');
    }

    debugPrint('⏸️ Alarme de rotina #$idAlarme pausado pelo usuário.');
  }

  static Future<void> desligarAlarme() async {
    try {
      await _canalRotinaAlarme.invokeMethod('pararAlarme');
      debugPrint('🔇 Alarme desligado pelo usuário');
    } catch (e) {
      debugPrint('⚠️ Falha ao desligar o alarme: $e');
    }
  }

  static Future<void> despausarAlarme(int idAlarme) async {
    try {
      await DatabaseHelper().definirAlarmePausado(idAlarme, false);
    } catch (e) {
      debugPrint('⚠️ Falha ao desmarcar alarme #$idAlarme como pausado: $e');
    }

    try {
      final dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
      final ativo = (dados?['ativo'] as int?) == 1;
      if (dados != null && ativo) {
        await agendarAlarme(dados);
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao reagendar alarme #$idAlarme após despausar: $e');
    }

    debugPrint('▶️ Alarme de rotina #$idAlarme reativado pelo usuário.');
  }

  static Future<void> iniciarTelaAlarmeNativa(int idAlarme) async {
    try {
      await _canalRotinaAlarme.invokeMethod('iniciarTelaAlarme', {
        'idAlarme': idAlarme,
      });
    } catch (e) {
      debugPrint('⚠️ Falha ao iniciar tela nativa do alarme de rotina #$idAlarme: $e');
    }
  }

 static Future<void> confirmarCheckinRotina(int idAlarme) async {
    // 1. Limpa os timers pendentes locais de SMS e notificação
    await AndroidAlarmManager.cancel(_idTolerancia(idAlarme));
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);

    Map<String, dynamic>? dados;
    try {
      // --- CORREÇÃO: Usamos o canal correto _canalRotinaAlarme ---
      await _canalRotinaAlarme.invokeMethod('pararAlarme');
      // -----------------------------------------------------------
      dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
    } catch (e) {
      debugPrint('⚠️ Erro ao parar som nativo no check-in: $e');
    }

    final etiqueta = (dados?['etiqueta'] as String?)?.trim().isNotEmpty == true
        ? dados!['etiqueta'] as String
        : 'Alarme de rotina';

    await NotificacaoService.registrarEventoSistema(
      titulo: 'Check-in de rotina confirmado',
      descricao: '$etiqueta: o usuário confirmou "Cheguei bem" com sucesso.',
    );

    // Reagenda automaticamente a rotina do alarme para o próximo dia/período
    try {
      final ativo = (dados?['ativo'] as int?) == 1;
      if (dados != null && ativo) {
        await agendarAlarme(dados);
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao reagendar alarme de rotina #$idAlarme: $e');
    }
  }
}

@pragma('vm:entry-point')
void _callbackCheckinRotina(int idAlarmeParam, Map<String, dynamic> params) async {
  final idAlarme = params['idAlarme'] as int? ?? idAlarmeParam;

  debugPrint('🔔 [HEADLESS] Alarme de check-in de rotina #$idAlarme disparado!');

  final player = AudioPlayer();
  final prefs = await SharedPreferences.getInstance();
  
  // 1. Grava no disco que o alarme está disparando para o main.dart mostrar o botão azul
  await prefs.setBool('alarme_disparando_no_momento', true);
  await prefs.setBool('stop_current_alarm', false); // Reinicia a flag de parada

  final soundPath = prefs.getString('alarm_sound_path') ?? 'som_1.mp3';

  // 2. Inicia o bloco de reprodução do áudio com segurança
  try {
    await player.setReleaseMode(ReleaseMode.loop);
    await player.play(AssetSource('sounds/$soundPath'));
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao tocar som do alarme: $e');
    await player.stop();
    await player.dispose();
  }

  // O restante do seu arquivo (os Timers e buscas no banco) continua exatamente igual daqui para baixo...

// Monitora a flag no SharedPreferences a cada 200ms para uma parada instantânea
  Timer.periodic(const Duration(milliseconds: 200), (timer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); 
    if (prefs.getBool('stop_current_alarm') == true) {
      try {
        await player.stop();
        await player.dispose();
        timer.cancel(); // Finaliza o monitoramento de segurança
        
        await prefs.remove('stop_current_alarm');
        await prefs.remove('alarme_disparando_no_momento');
        
        debugPrint('🔇 [HEADLESS] Áudio do Flutter silenciado de forma instantânea.');
      } catch (e) {
        debugPrint('⚠️ [HEADLESS] Falha ao parar player do Flutter: $e');
        timer.cancel();
      }
    }
  });

  Timer(const Duration(seconds: 240), () async {
    try {
      await player.stop();
      await player.dispose();
    } catch (e) {
      debugPrint('⚠️ [HEADLESS] Falha ao parar player: $e');
    }
  });

  Map<String, dynamic>? dados;
  try {
    dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao buscar dados do alarme #$idAlarme: $e');
  }

  if (dados == null) return;

  final ativo = (dados['ativo'] as int?) == 1;
  if (!ativo) return;

  final key = 'pausado_hoje_$idAlarme';
  if (prefs.getBool(key) == true) {
    debugPrint('⏸️ [HEADLESS] Alarme de rotina #$idAlarme pausado por hoje via swipe — disparo ignorado.');
    await prefs.remove(key);
    try {
      await RotinaAlarmeService.agendarAlarme(dados);
    } catch (e) {
      debugPrint('⚠️ [HEADLESS] Falha ao reagendar alarme pausado por hoje: $e');
    }
    return;
  }

  final etiqueta = (dados['etiqueta'] as String?) ?? 'Check-in de rotina';
  final minutosTolerancia = dados['minutos_tolerancia'] as int? ?? 10;

  try {
    await DatabaseHelper().marcarUltimoDisparo(
      idAlarme,
      DateTime.now().millisecondsSinceEpoch,
    );
  } catch (_) {}

  try {
    await NotificacaoService.exibirNotificacaoCheckin(
      idAlarme: idAlarme,
      etiqueta: etiqueta,
    );
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao exibir notificação de check-in: $e');
  }

  try {
    await AndroidAlarmManager.oneShot(
      Duration(minutes: minutosTolerancia),
      RotinaAlarmeService._idTolerancia(idAlarme),
      _callbackToleranciaExpirada,
      exact: true,
      wakeup: true,
      rescheduleOnReboot: false,
      params: {'idAlarme': idAlarme},
    );
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao agendar tolerância do alarme #$idAlarme: $e');
  }

  try {
    await RotinaAlarmeService.agendarAlarme(dados);
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao reagendar próxima ocorrência: $e');
  }
}

@pragma('vm:entry-point')
void _callbackToleranciaExpirada(int idAlarmeParam, Map<String, dynamic> params) async {
  final idAlarme = params['idAlarme'] as int? ?? idAlarmeParam;

  debugPrint('🚨 [HEADLESS] Tolerância do check-in de rotina #$idAlarme expirada — disparando emergência!');

  try {
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
  } catch (_) {}

  String contexto = 'Check-in de rotina não confirmado a tempo.';
  String etiqueta = 'Alarme de rotina';
  try {
    final dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
    if (dados != null) {
      etiqueta = (dados['etiqueta'] as String?)?.trim().isNotEmpty == true
          ? dados['etiqueta'] as String
          : etiqueta;
      final contextoPersonalizado = (dados['contexto_personalizado'] as String?)?.trim() ?? '';
      if (contextoPersonalizado.isNotEmpty) {
        contexto = contextoPersonalizado;
      }
    }
  } catch (_) {}

  try {
    await NotificacaoService.registrarEventoSistema(
      titulo: 'Check-in de rotina não confirmado',
      descricao: '$etiqueta: o usuário não confirmou "Cheguei bem" dentro do prazo de tolerância.',
    );
  } catch (_) {}

  try {
    await EmergencyAlertService().dispararAlertaDeEmergencia(contexto: contexto);
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha durante o disparo de emergência de rotina: $e');
  }

  try {
    await DatabaseHelper().marcarAguardandoConfirmacaoPin();
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao marcar aguardando_confirmacao_pin: $e');
  }
}