import 'package:flutter/foundation.dart';

import 'database_helper.dart';

/// Serviço leve (só um [ValueNotifier] global + wrappers do
/// [DatabaseHelper]) para os alertas de emergência de TERCEIROS
/// recebidos via Push FCM (ver `FcmService`), persistidos na tabela
/// `alertas_terceiros_recebidos`.
///
/// [naoVisualizados] é ouvido pelo [HomeScreen] para mostrar o badge no
/// ícone da aba Histórico (item 4 do pedido: "aviso/indicador visual...
/// caso existam alertas recebidos que ainda não foram visualizados").
class AlertasRecebidosService {
  AlertasRecebidosService._internal();
  static final AlertasRecebidosService _instance = AlertasRecebidosService._internal();
  factory AlertasRecebidosService() => _instance;

  static final DatabaseHelper _db = DatabaseHelper();

  /// Contagem atual de alertas de terceiros ainda não visualizados —
  /// atualizada via [atualizarContagem], nunca escrita diretamente por
  /// quem consome o valor.
  static final ValueNotifier<int> naoVisualizados = ValueNotifier<int>(0);

  /// Persiste um novo alerta recebido (best-effort — nunca lança
  /// exceção) e atualiza [naoVisualizados] em seguida. Chamado por
  /// [FcmService] assim que um alerta de emergência de terceiro é
  /// tratado, tanto em primeiro quanto em segundo plano/terminado.
  static Future<void> registrarAlertaRecebido({
    String? idEntrega,
    String? nomeRemetente,
    required String mensagem,
    double? latitude,
    double? longitude,
    String? fotoUrl,
  }) async {
    try {
      await _db.inserirAlertaTerceiroRecebido(
        idEntrega: idEntrega,
        nomeRemetente: nomeRemetente,
        mensagem: mensagem,
        latitude: latitude,
        longitude: longitude,
        fotoUrl: fotoUrl,
      );
      await atualizarContagem();
    } catch (e) {
      debugPrint('⚠️ [AlertasRecebidosService] Falha ao registrar alerta recebido: $e');
    }
  }

  /// Recarrega [naoVisualizados] a partir do banco — chamado no cold
  /// start (`main.dart`) e sempre que um alerta é registrado/marcado
  /// como visualizado.
  static Future<void> atualizarContagem() async {
    try {
      naoVisualizados.value = await _db.contarAlertasTerceirosNaoVisualizados();
    } catch (e) {
      debugPrint('⚠️ [AlertasRecebidosService] Falha ao atualizar contagem: $e');
    }
  }

  /// Marca o alerta [id] (id LOCAL na tabela, não o `idEntrega`) como
  /// visualizado e atualiza [naoVisualizados] em seguida. Chamado ao
  /// abrir [AlertaRecebidoScreen] a partir da aba Histórico.
  static Future<void> marcarVisualizado(int id) async {
    try {
      await _db.marcarAlertaTerceiroVisualizado(id);
      await atualizarContagem();
    } catch (e) {
      debugPrint('⚠️ [AlertasRecebidosService] Falha ao marcar alerta visualizado: $e');
    }
  }

  /// Mesma ação de [marcarVisualizado], mas identificando o alerta pelo
  /// [idEntrega] — usado quando [AlertaRecebidoScreen] é aberta direto
  /// pelo toque na notificação Push (sem passar pela aba Histórico, onde
  /// o id local já está disponível).
  static Future<void> marcarVisualizadoPorIdEntrega(String idEntrega) async {
    try {
      await _db.marcarAlertaTerceiroVisualizadoPorIdEntrega(idEntrega);
      await atualizarContagem();
    } catch (e) {
      debugPrint('⚠️ [AlertasRecebidosService] Falha ao marcar alerta visualizado: $e');
    }
  }
}
