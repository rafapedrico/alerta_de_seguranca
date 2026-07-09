import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Wrapper Dart em torno do plugin nativo local `VolumeSosPlugin`
/// (Kotlin), responsável por:
/// - Iniciar/parar o Foreground Service (`VolumeSosService`) que
///   monitora, em segundo plano, o gatilho físico de SOS: segurar o
///   botão de Volume+ (3 incrementos consecutivos em até 3 segundos).
/// - Expor um [Stream] ([aoDispararSos]) que emite um evento sempre que
///   esse gatilho físico for detectado pelo lado nativo, permitindo que
///   a UI (main.dart) acione o [EmergencyAlertService] correspondente.
///
/// Mantido como singleton para garantir que exista apenas UMA
/// assinatura ativa do EventChannel durante todo o ciclo de vida do
/// app, evitada duplicidade de disparos.
class VolumeSosService {
  VolumeSosService._internal();
  static final VolumeSosService _instance = VolumeSosService._internal();
  factory VolumeSosService() => _instance;

  static const MethodChannel _methodChannel =
      MethodChannel('com.example.security_check_app/volume_sos');
  static const EventChannel _eventChannel =
      EventChannel('com.example.security_check_app/volume_sos_events');

  StreamSubscription<dynamic>? _assinaturaInterna;
  final StreamController<void> _sosController =
      StreamController<void>.broadcast();

  /// Stream público que emite um evento (sem payload relevante) toda vez
  /// que o gatilho físico de SOS (Volume+ segurado por 3s) for detectado
  /// pelo Foreground Service nativo.
  Stream<void> get aoDispararSos => _sosController.stream;

  /// Inicia o Foreground Service nativo de monitoramento do botão físico
  /// de Volume+. Deve ser chamado uma única vez, logo na inicialização
  /// do app (main.dart), ANTES de runApp(). Protegido por try/catch para
  /// nunca travar o boot do app caso a plataforma não suporte (ex: iOS,
  /// onde este recurso não está implementado).
  Future<void> iniciarMonitoramento() async {
    _iniciarEscutaDeEventos();
    try {
      await _methodChannel.invokeMethod('iniciarServico');
      debugPrint('🔊 [VolumeSosService] Foreground Service de SOS iniciado.');
    } catch (e) {
      debugPrint('⚠️ [VolumeSosService] Falha ao iniciar serviço nativo: $e');
    }
  }

  /// Para o Foreground Service nativo de monitoramento. Normalmente não
  /// é necessário chamar isso durante o uso normal do app (o serviço
  /// deve permanecer ativo o tempo todo para garantir o SOS discreto),
  /// mas fica disponível para cenários de depuração/testes.
  Future<void> pararMonitoramento() async {
    try {
      await _methodChannel.invokeMethod('pararServico');
      debugPrint('🔊 [VolumeSosService] Foreground Service de SOS parado.');
    } catch (e) {
      debugPrint('⚠️ [VolumeSosService] Falha ao parar serviço nativo: $e');
    }
  }

  void _iniciarEscutaDeEventos() {
    if (_assinaturaInterna != null) return;
    _assinaturaInterna = _eventChannel.receiveBroadcastStream().listen(
      (evento) {
        debugPrint('🚨 [VolumeSosService] Gatilho físico de SOS detectado!');
        _sosController.add(null);
      },
      onError: (e) {
        debugPrint('⚠️ [VolumeSosService] Erro no EventChannel: $e');
      },
      cancelOnError: false,
    );
  }
}
