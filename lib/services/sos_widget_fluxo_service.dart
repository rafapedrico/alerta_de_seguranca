import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_navigator.dart';
import '../screens/sos_sem_login_screen.dart';
import 'bloqueio_app_service.dart';
import 'captura_dissuasao_service.dart';
import 'historico_alertas_service.dart';
import 'plano_ciclo_service.dart';
import 'premium_purchase_service.dart';
import 'sos_disparo_service.dart';
import 'sos_plano_aviso_service.dart';

/// Texto da tela preta do Widget SOS (ver [CamadaTelaSosWidget]).
enum EtapaTelaSosWidget {
  /// "Alerta acionado. Enviando sua localização…" — o mesmo primeiro aviso
  /// da `SosEmAndamentoScreen`, que assume a partir daí.
  enviandoLocalizacao,

  /// Dias bloqueados do Plano Free: "Botão SOS desativado no Plano Free
  /// até DD/MM" com "Assinar Premium" — nada é enviado.
  desativadoPlanoFree,
}

/// Toque no Widget SOS da tela de início (ver `SosWidgetProvider.kt`) —
/// o mesmo fluxo do widget do iOS e do botão SOS do app.
///
/// Do toque até a `SosEmAndamentoScreen` abrir, a tela preta
/// ([CamadaTelaSosWidget]) fica em `MaterialApp.builder`, POR CIMA de tudo
/// — splash, Navigator e a camada de bloqueio: nada do app aparece, nem
/// no cold start.
///
/// Sequência:
///   - sem sessão → [SosSemLoginScreen];
///   - Plano Free nos dias bloqueados → "Botão SOS desativado no Plano
///     Free até DD/MM" (nada é enviado);
///   - senão, o MESMO pipeline do botão SOS ([CapturaDissuasaoService.iniciarSos],
///     origem `sos_widget`): localização exata na hora, sem confirmação,
///     envio confirmado/fila de reenvio, "Localização enviada com
///     sucesso" (2 s), "Abrindo a câmera", câmera, foto e tela vermelha.
class SosWidgetFluxoService {
  SosWidgetFluxoService._internal();
  static final SosWidgetFluxoService _instance = SosWidgetFluxoService._internal();
  factory SosWidgetFluxoService() => _instance;

  /// `origem` do alerta no Firestore e tipo do histórico.
  static const String origem = TipoAlertaHistorico.sosWidget;

  /// Rota inicial do engine no cold start pelo widget (ver
  /// `MainActivity.getInitialRoute`).
  static const String rotaInicial = '/sos_widget';

  static const MethodChannel _canal = MethodChannel('guardiaox/sos_widget');

  /// Teto para o Firebase/Auth no cold start antes de decidir pela sessão.
  static const Duration _limiteFirebase = Duration(seconds: 10);

  /// Tempo da transição da `SosEmAndamentoScreen` antes de tirar a tela
  /// preta (as duas são iguais: a troca não aparece).
  static const Duration _transicaoRota = Duration(milliseconds: 450);

  /// `null` = tela preta fora da tela.
  final ValueNotifier<EtapaTelaSosWidget?> etapa = ValueNotifier<EtapaTelaSosWidget?>(null);

  /// Fim do bloqueio do Plano Free exibido em
  /// [EtapaTelaSosWidget.desativadoPlanoFree].
  DateTime? fimBloqueioPlano;

  VoidCallback? _encerrarLiberacao;

  /// Toques com o app já aberto (`onNewIntent` da MainActivity).
  void escutarToques({required Future<void> Function() garantirFirebaseEAuth}) {
    _canal.setMethodCallHandler((call) async {
      if (call.method == 'sosWidgetTocado') {
        iniciar(garantirFirebaseEAuth: garantirFirebaseEAuth);
      }
    });
  }

  /// Começa o fluxo. Síncrono até a tela preta estar pedida: chamado antes
  /// do `runApp` no cold start (o primeiro quadro já sai preto) e direto do
  /// evento nativo com o app aberto. Um toque com o SOS já em andamento é
  /// ignorado.
  void iniciar({Future<void> Function()? garantirFirebaseEAuth}) {
    if (etapa.value != null || SosDisparoService().emAndamento) {
      debugPrint('🆘 [SosWidget] Toque ignorado — SOS já em andamento.');
      return;
    }
    debugPrint('🆘 [SosWidget] Toque no Widget SOS — tela preta e envio imediato.');
    // O SOS nunca espera desbloqueio: esconde a camada de bloqueio
    // enquanto a tela preta estiver na tela.
    _encerrarLiberacao = BloqueioAppService().liberarParaEmergencia();
    FocusManager.instance.primaryFocus?.unfocus();
    etapa.value = EtapaTelaSosWidget.enviandoLocalizacao;
    unawaited(_executar(garantirFirebaseEAuth));
  }

  Future<void> _executar(Future<void> Function()? garantirFirebaseEAuth) async {
    try {
      await garantirFirebaseEAuth?.call().timeout(_limiteFirebase);
    } catch (e) {
      debugPrint('⚠️ [SosWidget] Firebase/Auth indisponível: $e');
    }

    if (!BloqueioAppService.sessaoValida()) {
      // Ninguém entrou neste aparelho: não há como enviar o alerta.
      debugPrint('🆘 [SosWidget] Sem sessão — explicando como ativar o botão.');
      final navigator = await _aguardarNavigator();
      _encerrarTela();
      navigator?.push(MaterialPageRoute<void>(builder: (_) => const SosSemLoginScreen()));
      return;
    }

    final bloqueio = await _bloqueioVigente();
    if (bloqueio != null) {
      debugPrint('🔒 [SosWidget] Plano Free nos dias bloqueados — SOS não enviado.');
      fimBloqueioPlano = bloqueio.fim;
      etapa.value = EtapaTelaSosWidget.desativadoPlanoFree;
      return;
    }

    try {
      final iniciou = await CapturaDissuasaoService().iniciarSos(
        origem: origem,
        planoJaVerificado: true,
      );
      if (iniciou) await Future<void>.delayed(_transicaoRota);
    } catch (e) {
      debugPrint('⚠️ [SosWidget] Falha ao iniciar o SOS: $e');
    }
    _encerrarTela();
  }

  /// Bloqueio do Plano Free em vigor. O SOS nunca espera a rede pelo plano:
  /// vale o status em cache; só quando ele diz "bloqueado" há uma leitura
  /// nova (assinatura recém-feita), e sem ela fica o cache.
  Future<BloqueioSosPlano?> _bloqueioVigente() async {
    final cache = await PlanoCicloService().statusEmCache();
    if (cache == null || cache.ativo) {
      unawaited(PlanoCicloService().obterStatusAtualizado());
      return null;
    }
    final atual = await PlanoCicloService().obterStatusAtualizado();
    return BloqueioSosPlano.vigente(atual ?? cache);
  }

  /// "Assinar Premium" na tela do botão desativado.
  void assinarPremium() {
    _encerrarTela();
    unawaited(PremiumPurchaseService().comprarPremium());
  }

  /// "Agora não" na tela do botão desativado.
  void fecharAvisoPlano() => _encerrarTela();

  /// Tira a tela preta. A tela do SOS e a câmera têm a própria liberação
  /// do bloqueio ([LiberaBloqueioEnquantoAberta]).
  void _encerrarTela() {
    etapa.value = null;
    _encerrarLiberacao?.call();
    _encerrarLiberacao = null;
  }

  Future<NavigatorState?> _aguardarNavigator() async {
    for (var tentativa = 0; tentativa < 20; tentativa++) {
      final navigator = appNavigatorKey.currentState;
      if (navigator != null) return navigator;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return null;
  }
}
