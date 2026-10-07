import 'package:flutter/material.dart';

import '../app_navigator.dart';
import '../screens/sos_em_andamento_screen.dart';
import '../widgets/plano_bloqueado_dialog.dart';
import 'plano_ciclo_service.dart';
import 'sos_disparo_service.dart';

/// Ponto de entrada ÚNICO do SOS — botão do app (aba Segurança) e botão
/// físico (Volume+): envia a localização NA HORA, sem diálogo de
/// confirmação, e abre a sequência visual ([SosEmAndamentoScreen] →
/// câmera → tela vermelha).
class CapturaDissuasaoService {
  CapturaDissuasaoService._internal();
  static final CapturaDissuasaoService _instance =
      CapturaDissuasaoService._internal();
  factory CapturaDissuasaoService() => _instance;

  /// Dispara o SOS. Devolve `true` quando a sequência começou (a tela do
  /// SOS foi aberta); `false` se já havia um SOS em andamento (toque
  /// duplo), se o plano em cache diz claramente "bloqueado", ou se não há
  /// navegação disponível.
  ///
  /// O plano NUNCA atrasa o SOS: só o status em cache é consultado (ver
  /// [PlanoCicloService.podeUsarRapido]) — nada de esperar a rede.
  Future<bool> iniciarSos({required String origem, String? contexto}) async {
    if (SosDisparoService().emAndamento) {
      debugPrint('🔁 [SOS] Toque ignorado — já há um SOS em andamento.');
      return false;
    }
    if (!await PlanoCicloService().podeUsarRapido()) {
      final contexto = appNavigatorKey.currentContext;
      if (contexto != null && contexto.mounted) await exibirAvisoPlanoBloqueado(contexto);
      return false;
    }

    final sessao = await SosDisparoService().iniciar(origem: origem, contexto: contexto);
    if (sessao == null) return false;

    NavigatorState? navegador = appNavigatorKey.currentState;
    var tentativas = 0;
    while (navegador == null && tentativas < 10) {
      await Future.delayed(const Duration(milliseconds: 300));
      navegador = appNavigatorKey.currentState;
      tentativas++;
    }
    if (navegador == null) {
      debugPrint('⚠️ [SOS] Navegação indisponível — a localização já foi enviada.');
      SosDisparoService().encerrarSessao();
      return false;
    }
    navegador.push(
      MaterialPageRoute(
        builder: (_) => SosEmAndamentoScreen(sessao: sessao),
        fullscreenDialog: true,
      ),
    );
    return true;
  }
}
