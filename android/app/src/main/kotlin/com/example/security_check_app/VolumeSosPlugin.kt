package com.example.security_check_app

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin Flutter local responsável por expor, via [MethodChannel] e
 * [EventChannel], a comunicação entre o app Dart e o
 * [VolumeSosService] (Foreground Service nativo que monitora o botão
 * físico de Volume+ em segundo plano, mesmo com a tela apagada ou o
 * app minimizado).
 *
 * MethodChannel ("com.example.security_check_app/volume_sos"):
 * - "iniciarServico": inicia o Foreground Service de monitoramento.
 * - "pararServico": para o Foreground Service.
 *
 * EventChannel ("com.example.security_check_app/volume_sos_events"):
 * - Emite o evento "sos_disparado" toda vez que o gatilho físico (3
 *   incrementos de volume em até 3 segundos) for detectado pelo
 *   [VolumeSosService]. O lado Dart escuta esse stream e aciona o
 *   [EmergencyAlertService] correspondente.
 *
 * A comunicação entre o Service (que roda em background, possivelmente
 * fora do ciclo de vida normal da Activity) e este plugin é feita
 * através de um "hub" estático em [VolumeSosEventBridge], já que o
 * EventChannel só pode emitir eventos enquanto houver um listener Dart
 * ativo E o binaryMessenger do engine estiver disponível.
 */
class VolumeSosPlugin : FlutterPlugin {
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "iniciarServico" -> {
                        try {
                            VolumeSosService.iniciar(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SOS_SERVICE_ERROR", "Falha ao iniciar VolumeSosService: ${e.message}", null)
                        }
                    }
                    "pararServico" -> {
                        try {
                            VolumeSosService.parar(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SOS_SERVICE_ERROR", "Falha ao parar VolumeSosService: ${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    VolumeSosEventBridge.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    VolumeSosEventBridge.eventSink = null
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
    }

    companion object {
        const val METHOD_CHANNEL = "com.example.security_check_app/volume_sos"
        const val EVENT_CHANNEL = "com.example.security_check_app/volume_sos_events"
    }
}

/**
 * Ponte estática simples entre o [VolumeSosService] (que roda em
 * background, sem referência direta ao FlutterEngine/Activity) e o
 * [EventChannel] registrado por [VolumeSosPlugin]. Sempre que o
 * EventChannel tiver um listener Dart ativo, [eventSink] estará
 * disponível para receber o evento "sos_disparado".
 *
 * Se o app estiver completamente fechado (nenhum FlutterEngine ativo),
 * [eventSink] será `null` e o Service, nesse caso, aciona diretamente o
 * disparo de emergência via [EmergencyAlertService] teria que ser feito
 * do lado Kotlin — por isso o MainActivity mantém o engine principal
 * "quente" (cached engine) para que o EventChannel sempre tenha um
 * listener, mesmo com o app em segundo plano.
 */
object VolumeSosEventBridge {
    var eventSink: EventChannel.EventSink? = null

    /** Notifica o lado Dart (se houver um listener ativo) que o gatilho
     * físico de SOS foi detectado. Chamado pelo [VolumeSosService] a
     * partir de sua própria thread/handler — por isso a emissão é
     * despachada na main thread do Android. */
    fun notificarSosDisparado() {
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            eventSink?.success("sos_disparado")
        }
    }
}
