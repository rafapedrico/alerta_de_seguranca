import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../app_navigator.dart';
import '../screens/login_screen.dart';
import 'firebase_auth_service.dart';

/// Bloqueio LOCAL do app (digital/rosto, com o código do aparelho e o PIN
/// do Guardião-X como alternativas — ver `CamadaBloqueioApp`). Substituiu
/// a antiga "Opção A" (logout forçado do Firebase Auth a cada cold start),
/// mesma troca já feita no app iOS: sem sessão, nem os pushes de SOS, nem
/// os pedidos de localização, nem o rastreamento contínuo funcionam.
///
/// A sessão do Firebase fica SEMPRE persistida (logout só no "Sair"), e
/// quem protege o conteúdo do app é este bloqueio:
/// - Cold start normal com sessão: o app abre bloqueado.
/// - Volta do segundo plano depois de [tempoEmSegundoPlanoParaBloquear]:
///   bloqueia de novo.
/// - Emergências PULAM o bloqueio enquanto estão na tela (câmera do SOS,
///   alerta recebido, alarme de rotina/cronômetro) via
///   [liberarParaEmergencia]/[LiberaBloqueioEnquantoAberta].
///
/// O bloqueio é uma camada POR CIMA do Navigator (ver `CamadaBloqueioApp`
/// em `MaterialApp.builder`), não uma rota — nenhuma navegação consegue
/// "escapar" dele.
///
/// Sessão encerrada fora do app (login da mesma conta em outro aparelho,
/// conta apagada): o SDK desloga sozinho na renovação do token; ao
/// detectar, volta para a LoginScreen (ver [_aoMudarSessao]).
class BloqueioAppService with WidgetsBindingObserver {
  BloqueioAppService._internal();
  static final BloqueioAppService _instance = BloqueioAppService._internal();
  factory BloqueioAppService() => _instance;

  /// Tempo em segundo plano a partir do qual o app volta bloqueado.
  static const Duration tempoEmSegundoPlanoParaBloquear = Duration(minutes: 2);

  /// Códigos do Firebase Auth que significam "esta sessão não vale mais".
  static const Set<String> _codigosSessaoInvalida = {
    'user-token-expired',
    'invalid-user-token',
    'user-disabled',
    'user-not-found',
  };

  /// `true` = o conteúdo do app exige desbloqueio.
  final ValueNotifier<bool> bloqueado = ValueNotifier<bool>(false);

  /// Quantas emergências estão na tela agora (> 0 esconde a camada).
  final ValueNotifier<int> emergenciasAbertas = ValueNotifier<int>(0);

  bool _observando = false;
  DateTime? _foiParaSegundoPlanoEm;

  bool _sessaoObservada = false;
  bool _saidaVoluntaria = false;
  String? _uidAnterior;

  /// `true` quando a camada de bloqueio deve estar visível.
  bool get camadaVisivel => bloqueado.value && emergenciasAbertas.value == 0;

  /// Começa a observar o ciclo de vida do app. Idempotente.
  void iniciar() {
    if (_observando) return;
    _observando = true;
    WidgetsBinding.instance.addObserver(this);
  }

  /// Chamado depois do `Firebase.initializeApp()`: acompanha a sessão para
  /// detectar quando ela é encerrada fora do app. Idempotente.
  void observarSessao() {
    if (_sessaoObservada || Firebase.apps.isEmpty) return;
    _sessaoObservada = true;
    _uidAnterior = FirebaseAuthService().uidAtual;
    FirebaseAuth.instance.authStateChanges().listen(_aoMudarSessao);
  }

  void _aoMudarSessao(User? usuario) {
    final anterior = _uidAnterior;
    _uidAnterior = usuario?.uid;
    if (usuario != null || anterior == null) return;
    final voluntaria = _saidaVoluntaria;
    _saidaVoluntaria = false;
    bloqueado.value = false;
    if (voluntaria) return;
    // Sessão derrubada pelo SDK (login em outro aparelho, conta apagada):
    // o app não tem mais acesso à conta — volta ao login. Durante uma
    // emergência na tela, não interrompe: o login aparece ao sair dela.
    debugPrint('🔐 [BloqueioApp] Sessão encerrada fora do app — voltando ao login.');
    if (emergenciasAbertas.value > 0) return;
    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  /// Bloqueia se houver uma sessão restaurada — chamado depois que o
  /// Firebase Auth termina de restaurar a sessão no cold start.
  void bloquearSeHouverSessao() {
    if (sessaoValida()) _bloquear();
  }

  /// Sessão que de fato dá acesso ao app: conta por e-mail/senha só vale
  /// com o e-mail confirmado (a tela de verificação de e-mail não deve
  /// ficar atrás do bloqueio).
  static bool sessaoValida() {
    // Firebase pode não ter inicializado (sem rede no 1º uso, falha do
    // SDK): sem ele não há sessão — nunca lança.
    if (Firebase.apps.isEmpty) return false;
    try {
      final usuario = FirebaseAuthService().usuarioAtual;
      if (usuario == null) return false;
      return usuario.emailVerified ||
          usuario.providerData.every((p) => p.providerId != 'password');
    } catch (_) {
      return false;
    }
  }

  /// Desbloqueio confirmado (biometria, código do aparelho, PIN) ou login
  /// novo de verdade.
  void desbloquear() {
    bloqueado.value = false;
  }

  /// "Sair" tocado pelo usuário: não há mais nada a proteger, e a volta ao
  /// login já é feita por quem chamou.
  void aoEncerrarSessao() {
    _saidaVoluntaria = true;
    bloqueado.value = false;
  }

  /// A conta vai sumir do servidor (exclusão): o SDK pode deslogar sozinho
  /// no meio do caminho — não é "sessão encerrada em outro aparelho".
  void marcarSaidaVoluntaria() => _saidaVoluntaria = true;

  /// Exclusão falhou: a sessão continua valendo.
  void desmarcarSaidaVoluntaria() => _saidaVoluntaria = false;

  /// Esconde a camada enquanto uma emergência está em andamento. Devolve a
  /// função que encerra a liberação (idempotente).
  VoidCallback liberarParaEmergencia() {
    emergenciasAbertas.value++;
    var encerrada = false;
    return () {
      if (encerrada) return;
      encerrada = true;
      emergenciasAbertas.value--;
    };
  }

  void _bloquear() {
    // Fecha o teclado de qualquer campo que estivesse em foco por baixo.
    FocusManager.instance.primaryFocus?.unfocus();
    bloqueado.value = true;
  }

  /// Renovação forçada do token ao voltar ao primeiro plano: é ela que faz
  /// o SDK perceber uma sessão revogada (e deslogar — ver [_aoMudarSessao]).
  Future<void> _conferirSessao() async {
    if (Firebase.apps.isEmpty) return;
    final usuario = FirebaseAuth.instance.currentUser;
    if (usuario == null) return;
    try {
      await usuario.getIdToken(true);
    } on FirebaseAuthException catch (e) {
      if (_codigosSessaoInvalida.contains(e.code)) {
        debugPrint('🔐 [BloqueioApp] Sessão inválida (${e.code}).');
        await FirebaseAuth.instance.signOut();
      }
    } catch (_) {
      // Sem rede: tenta de novo na próxima volta.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // Só `paused`/`hidden` contam como "saiu do app". `inactive` NÃO: o
      // próprio prompt da digital e o seletor de contatos deixam o app
      // inativo por instantes — contar isso criaria um ciclo de bloqueio.
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _foiParaSegundoPlanoEm ??= DateTime.now();
        break;
      case AppLifecycleState.resumed:
        final saiuEm = _foiParaSegundoPlanoEm;
        _foiParaSegundoPlanoEm = null;
        if (saiuEm != null) unawaited(_conferirSessao());
        if (saiuEm != null &&
            DateTime.now().difference(saiuEm) >= tempoEmSegundoPlanoParaBloquear) {
          bloquearSeHouverSessao();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }
}

/// Telas de emergência que precisam funcionar SEM desbloqueio (câmera do
/// SOS, alerta recebido, alarme de rotina, cronômetro): a camada de
/// bloqueio fica escondida enquanto a tela existir.
mixin LiberaBloqueioEnquantoAberta<T extends StatefulWidget> on State<T> {
  VoidCallback? _encerrarLiberacao;

  @override
  void initState() {
    super.initState();
    _encerrarLiberacao = BloqueioAppService().liberarParaEmergencia();
  }

  @override
  void dispose() {
    _encerrarLiberacao?.call();
    super.dispose();
  }
}
