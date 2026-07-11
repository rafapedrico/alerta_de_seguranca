package com.example.security_check_app

import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin Flutter local responsável por expor, via [MethodChannel] e
 * [EventChannel], a comunicação entre o app Dart e a
 * [RotinaCheckinAlarmActivity] (Activity nativa que toca o som do
 * alarme de check-in de ROTINA em loop, por cima do Keyguard/lockscreen).
 *
 * MethodChannel ("com.example.security_check_app/rotina_alarme"):
 * - "iniciarTelaAlarme": inicia (ou traz ao topo) a
 *   [RotinaCheckinAlarmActivity] para o [idAlarme] informado, chamado
 *   pelo callback headless de [RotinaAlarmeService] no momento exato do
 *   disparo do alarme de check-in nativo (Etapa 3), garantindo que a
 *   tela apareça mesmo com o app fechado/aparelho bloqueado.
 * - "pausarAlarme": interrompe IMEDIATAMENTE o som em loop tocando na
 *   Activity atualmente visível (chamado pelo Dart assim que o PIN
 *   correto é confirmado ou o botão "Cancelar"/"Pausar Alarme" é
 *   tocado no pin_dialog.dart).
 *
 * EventChannel ("com.example.security_check_app/rotina_alarme_events"):
 * - Emite o id (int) do alarme de rotina toda vez que um NOVO disparo
 *   chega via `onNewIntent` com a Activity já viva (ver
 *   [RotinaAlarmEventBridge] em RotinaCheckinAlarmActivity.kt).
 */
class RotinaAlarmPlugin : FlutterPlugin {
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "iniciarTelaAlarme" -> {
                        try {
                            val idAlarme = (call.argument<Int>("idAlarme")) ?: -1
                            iniciarTelaAlarme(context, idAlarme)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao iniciar tela de alarme: ${e.message}", null)
                        }
                    }
                    "pausarAlarme" -> {
                        try {
                            RotinaAlarmSomBridge.pararSom()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao pausar som do alarme: ${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    RotinaAlarmEventBridge.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    RotinaAlarmEventBridge.eventSink = null
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

    /**
     * Inicia diretamente, via [Intent] nativo, a
     * [RotinaCheckinAlarmActivity], reproduzindo exatamente a mesma
     * estratégia já usada por [VolumeSosService.forcarAberturaLockscreenCameraActivity]
     * para o SOS físico: garante que a Activity seja criada (ou trazida
     * ao topo) com as flags de sobreposição ao Keyguard aplicadas em seu
     * próprio `onCreate()`, mesmo que o app esteja completamente fechado
     * e apenas este callback headless do `android_alarm_manager_plus`
     * esteja em execução.
     */
    private fun iniciarTelaAlarme(context: Context, idAlarme: Int) {
        val intent = Intent(context, RotinaCheckinAlarmActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
            putExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, idAlarme)
        }
        context.startActivity(intent)
    }

    companion object {
        const val METHOD_CHANNEL = "com.example.security_check_app/rotina_alarme"
        const val EVENT_CHANNEL = "com.example.security_check_app/rotina_alarme_events"
    }
}

/**
 * Ponte estática simples usada pelo [RotinaAlarmPlugin] para solicitar,
 * de qualquer lugar (inclusive de fora do ciclo de vida normal da
 * Activity), a interrupção IMEDIATA do som do alarme de rotina tocando
 * em loop na [RotinaCheckinAlarmActivity] atualmente visível.
 *
 * A própria Activity registra seu [MediaPlayer] aqui em `onCreate()` e o
 * remove em `onDestroy()`, evitando qualquer referência pendurada
 * (memory leak) após a Activity ser finalizada.
 */
object RotinaAlarmSomBridge {
    private var mediaPlayer: android.media.MediaPlayer? = null

    fun registrarPlayer(player: android.media.MediaPlayer?) {
        mediaPlayer = player
    }

    fun pararSom() {
        try {
            mediaPlayer?.let {
                if (it.isPlaying) {
                    it.stop()
                }
                it.release()
            }
        } catch (_: Exception) {
        } finally {
            mediaPlayer = null
        }
    }
}
