import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_helper.dart';
import 'emergency_alert_service.dart';
import 'notificacao_service.dart';

/// MethodChannel espelhando o `RotinaAlarmPlugin.kt` nativo, usado para:
/// - "iniciarTelaAlarme": abrir a `RotinaCheckinAlarmActivity` nativa por
///   cima do Keyguard/lockscreen no momento exato do disparo do alarme
///   de check-in de rotina (chamado pelo callback headless
///   `_callbackCheckinRotina`).
/// - "pausarAlarme": interromper IMEDIATAMENTE o som em loop tocando na
///   Activity nativa (chamado pelo `pin_dialog.dart` assim que o botão
///   "Pausar Alarme" é tocado ou o PIN correto é confirmado).
const MethodChannel _canalRotinaAlarme =
    MethodChannel('com.example.security_check_app/rotina_alarme');


/// Serviço responsável por agendar/cancelar os alarmes NATIVOS de
/// check-in de rotina (Etapa 3), um por [AlarmeRotina] cadastrado na aba
/// Família, usando [AndroidAlarmManager] (android_alarm_manager_plus).
///
/// Cada alarme de rotina, ao disparar no horário configurado, executa em
/// um FlutterEngine headless (sem UI) o fluxo:
/// 1. Exibe uma notificação local pedindo a confirmação "✅ Cheguei bem".
/// 2. Agenda um segundo alarme (de TOLERÂNCIA) para daqui a
///    [AlarmeRotina.minutosTolerancia] minutos.
/// 3. Se o usuário tocar em "Cheguei bem" antes da tolerância expirar
///    (ver [NotificacaoService]/[confirmarCheckinRotina]), o alarme de
///    tolerância é cancelado e nada mais acontece.
/// 4. Se a tolerância expirar sem confirmação, dispara o mesmo fluxo de
///    emergência (GPS + SMS) usado no cronômetro manual da SegurancaTab,
///    via [EmergencyAlertService], usando o
///    [AlarmeRotina.contextoPersonalizado] deste alarme específico.
///
/// IDs de alarme nativo usados (para não colidir com o alarme de
/// emergência manual, id 9001, do [AlarmeService]):
/// - Disparo do check-in: 20000 + idDoAlarmeDeRotina
/// - Alarme de tolerância: 30000 + idDoAlarmeDeRotina
class RotinaAlarmeService {
  RotinaAlarmeService._internal();
  static final RotinaAlarmeService _instance = RotinaAlarmeService._internal();
  factory RotinaAlarmeService() => _instance;

  static const int _offsetIdCheckin = 20000;
  static const int _offsetIdTolerancia = 30000;

  static int _idCheckin(int idAlarme) => _offsetIdCheckin + idAlarme;
  static int _idTolerancia(int idAlarme) => _offsetIdTolerancia + idAlarme;

  /// Agenda (ou reagenda, cancelando qualquer instância anterior) o
  /// alarme nativo de check-in de rotina para o próximo horário válido
  /// dentre os dias da semana configurados em [alarmeMap] (mapa oriundo
  /// de [AlarmeRotina.toMap]/linha do SQLite).
  ///
  /// Chamado pela FamiliaTab sempre que um alarme é criado, editado ou
  /// reativado (switch ligado). Alarmes inativos (switch desligado) não
  /// devem chamar este método — devem chamar [cancelarAlarme] em vez
  /// disso.
  static Future<void> agendarAlarme(Map<String, dynamic> alarmeMap) async {
    final id = alarmeMap['id'] as int?;
    if (id == null) return;

    final hora = alarmeMap['hora'] as int? ?? 0;
    final minuto = alarmeMap['minuto'] as int? ?? 0;
    final diasSemanaCsv = alarmeMap['dias_semana'] as String? ?? '';

    final proximoDisparo = _calcularProximoDisparo(hora, minuto, diasSemanaCsv);
    if (proximoDisparo == null) {
      // Nenhum dia da semana selecionado: trata como disparo único, se o
      // horário de hoje ainda não tiver passado; caso contrário, não
      // agenda nada.
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

    debugPrint(
        '⏰ Alarme de rotina #$idAlarme agendado para ${dataHoraDisparo.toIso8601String()}');
  }

  /// Calcula a próxima data/hora (a partir de agora) em que o alarme deve
  /// disparar, considerando os dias da semana em [diasSemanaCsv] (CSV,
  /// 1=Segunda ... 7=Domingo). Retorna `null` se [diasSemanaCsv] estiver
  /// vazio (nenhum dia selecionado).
  static DateTime? _calcularProximoDisparo(
      int hora, int minuto, String diasSemanaCsv) {
    final dias = diasSemanaCsv
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
    if (dias.isEmpty) return null;

    final agora = DateTime.now();
    for (int offset = 0; offset < 8; offset++) {
      final candidatoData = agora.add(Duration(days: offset));
      final diaSemanaCandidato = candidatoData.weekday; // 1=Segunda...7=Domingo
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
    // Não deveria acontecer (sempre há um próximo dia dentro de 8 dias),
    // mas por segurança retorna null.
    return null;
  }

  /// Cancela o alarme nativo de check-in (e também um eventual alarme de
  /// tolerância pendente) para o [idAlarme] informado. Chamado ao
  /// desativar (switch desligado) ou excluir um alarme de rotina.
  static Future<void> cancelarAlarme(int idAlarme) async {
    await AndroidAlarmManager.cancel(_idCheckin(idAlarme));
    await AndroidAlarmManager.cancel(_idTolerancia(idAlarme));
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
    debugPrint('⏰ Alarme de rotina #$idAlarme cancelado.');
  }

  /// Pausa o alarme de check-in de rotina [idAlarme]: cancela o alarme
  /// nativo de check-in e um eventual alarme de tolerância pendente,
  /// marca `alarme_pausado = 1` no banco (SEM excluir o alarme, que
  /// continua listado normalmente na aba Família, apenas com o texto
  /// "Alarme Pausado" no lugar do horário) e interrompe IMEDIATAMENTE o
  /// som em loop tocando na `RotinaCheckinAlarmActivity` nativa, caso
  /// esteja visível. Chamado pelo `pin_dialog.dart` quando o usuário
  /// toca no botão "Pausar Alarme".
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
      await _canalRotinaAlarme.invokeMethod('pausarAlarme');
    } catch (e) {
      debugPrint('⚠️ Falha ao pausar som nativo do alarme #$idAlarme: $e');
    }

    debugPrint('⏸️ Alarme de rotina #$idAlarme pausado pelo usuário.');
  }

  /// Reativa (despausa) o alarme de rotina [idAlarme], marcando
  /// `alarme_pausado = 0` no banco e reagendando o próximo disparo
  /// normalmente (caso o alarme esteja com `ativo = 1`). Chamado pelo
  /// botão de reativação exibido na aba Família ao lado do texto
  /// "Alarme Pausado".
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

  /// Solicita ao lado nativo (via [MethodChannel]) que a
  /// `RotinaCheckinAlarmActivity` seja iniciada/trazida ao topo por
  /// cima do Keyguard/lockscreen para o [idAlarme] informado. Chamado
  /// pelo callback headless `_callbackCheckinRotina` assim que o
  /// disparo de check-in de rotina ocorre, garantindo que a tela de
  /// confirmação apareça imediatamente mesmo com o app fechado ou o
  /// aparelho bloqueado.
  static Future<void> iniciarTelaAlarmeNativa(int idAlarme) async {
    try {
      await _canalRotinaAlarme.invokeMethod('iniciarTelaAlarme', {
        'idAlarme': idAlarme,
      });
    } catch (e) {
      debugPrint(
          '⚠️ Falha ao iniciar tela nativa do alarme de rotina #$idAlarme: $e');
    }
  }


  /// Chamado pelo [NotificacaoService] quando o usuário toca em "✅
  /// Cheguei bem" na notificação (com o app aberto ou fechado). Cancela
  /// o alarme de tolerância pendente, remove a notificação e registra a
  /// confirmação no histórico (categoria 'sistema').
  static final MethodChannel _alarmeChannel = MethodChannel('com.example.security_check_app/rotina_alarme');

  static Future<void> confirmarCheckinRotina(int idAlarme) async {
    await AndroidAlarmManager.cancel(_idTolerancia(idAlarme));
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);

    Map<String, dynamic>? dados;
    try {
      await _alarmeChannel.invokeMethod('pararAlarme');
      dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
    } catch (_) {}

    final etiqueta = (dados?['etiqueta'] as String?)?.trim().isNotEmpty == true
        ? dados!['etiqueta'] as String
        : 'Alarme de rotina';

    await NotificacaoService.registrarEventoSistema(
      titulo: 'Check-in de rotina confirmado',
      descricao: '$etiqueta: o usuário confirmou "Cheguei bem" com sucesso.',
    );

    // Reagenda o próximo disparo (próxima ocorrência dentre os dias da
    // semana configurados), mantendo o ciclo recorrente ativo.
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

/// Callback estático executado pelo Android em um FlutterEngine headless
/// quando um alarme de check-in de ROTINA dispara (possivelmente com o
/// app totalmente fechado). Exibe a notificação de confirmação e agenda
/// o alarme de tolerância correspondente.
///
/// Assinatura `Function(int, Map<String, dynamic>)` exigida pelo
/// android_alarm_manager_plus quando `params` é utilizado no
/// agendamento: [idAlarmeParam] é o próprio id do alarme nativo
/// (idêntico ao id salvo em `params['idAlarme']`).
///
/// Precisa ser uma função top-level e anotada com
/// `@pragma('vm:entry-point')`.
@pragma('vm:entry-point')
void _callbackCheckinRotina(int idAlarmeParam, Map<String, dynamic> params) async {
  final idAlarme = params['idAlarme'] as int? ?? idAlarmeParam;

  debugPrint('🔔 [HEADLESS] Alarme de check-in de rotina #$idAlarme disparado!');

  Map<String, dynamic>? dados;
  try {
    dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao buscar dados do alarme #$idAlarme: $e');
  }

  if (dados == null) return;

  final ativo = (dados['ativo'] as int?) == 1;
  if (!ativo) return;

  // Verificar se o alarme foi pausado por hoje via swipe
  final prefs = await SharedPreferences.getInstance();
  final key = 'pausado_hoje_$idAlarme';
  if (prefs.getBool(key) == true) {
    debugPrint('⏸️ [HEADLESS] Alarme de rotina #$idAlarme pausado por hoje via swipe — disparo ignorado.');
    // Remover a flag após processar para não afetar futuros disparos
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

  // Exibe uma notificação de tela cheia com som e vibração
  try {
    await NotificacaoService.exibirNotificacaoAlarmeCompleto(
      idAlarme: idAlarme,
      etiqueta: etiqueta,
    );
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao exibir notificação de alarme: $e');
  }


  // Agenda o alarme de TOLERÂNCIA: se o usuário não confirmar "Cheguei
  // bem" dentro de [minutosTolerancia], o disparo de emergência ocorre
  // automaticamente.
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

  // Já reagenda a PRÓXIMA ocorrência deste mesmo alarme de rotina
  // (próximo dia da semana configurado), garantindo o ciclo recorrente
  // mesmo que o usuário nunca abra o app.
  try {
    await RotinaAlarmeService.agendarAlarme(dados);
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao reagendar próxima ocorrência: $e');
  }
}

/// Callback estático executado quando a tolerância de confirmação de um
/// check-in de rotina expira sem que o usuário tenha tocado em "Cheguei
/// bem". Dispara o fluxo completo de emergência (GPS + SMS), usando o
/// contexto PRÓPRIO deste alarme de rotina.
@pragma('vm:entry-point')
void _callbackToleranciaExpirada(int idAlarmeParam, Map<String, dynamic> params) async {
  final idAlarme = params['idAlarme'] as int? ?? idAlarmeParam;

  debugPrint(
      '🚨 [HEADLESS] Tolerância do check-in de rotina #$idAlarme expirada — disparando emergência!');

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
      final contextoPersonalizado =
          (dados['contexto_personalizado'] as String?)?.trim() ?? '';
      if (contextoPersonalizado.isNotEmpty) {
        contexto = contextoPersonalizado;
      }
    }
  } catch (_) {}

  try {
    await NotificacaoService.registrarEventoSistema(
      titulo: 'Check-in de rotina não confirmado',
      descricao:
          '$etiqueta: o usuário não confirmou "Cheguei bem" dentro do prazo de tolerância.',
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
