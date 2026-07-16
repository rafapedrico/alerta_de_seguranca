package com.example.security_check_app

import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.preference.PreferenceManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class RotinaAlarmPlugin : FlutterPlugin {
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    companion object {
        const val METHOD_CHANNEL = "com.example.security_check_app/rotina_alarme"
        const val EVENT_CHANNEL = "com.example.security_check_app/rotina_alarme_events"
        
        // Referência estática segura para fechar a Activity ativa do alarme
        private var activityReference: WeakReference<RotinaCheckinAlarmActivity>? = null

        fun registrarActivity(activity: RotinaCheckinAlarmActivity?) {
            activityReference = activity?.let { WeakReference(it) }
        }

        fun fecharActivityAtiva() {
            try {
                activityReference?.get()?.let { activity ->
                    if (!activity.isFinishing) {
                        activity.finish()
                    }
                }
            } catch (_: Exception) {
            } finally {
                activityReference = null
            }
        }
    }

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
               "pararAlarme", "pausarAlarme" -> {
                        try {
                            // 1. Desliga o som nativo
                            RotinaAlarmSomBridge.pararSom()
                            // 2. O segredo da vitória: Força a Activity nativa do Android a fechar e sumir!
                            fecharActivityAtiva() 
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao parar alarme: ${e.message}", null)
                        }
                    }
                    "setAlarmDuration" -> {
                        try {
                            val seconds = call.arguments as Int
                            PreferenceManager.getDefaultSharedPreferences(context)
                                .edit()
                                .putInt("alarm_sound_duration", seconds)
                                .apply()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao definir duração do alarme: ${e.message}", null)
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
}

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