package com.example.security_check_app

import android.app.NotificationManager
import android.content.Context
import android.media.AudioManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Ponte Dart <-> Android do alerta RECEBIDO de outro usuário.
 *
 * O som do alerta recebido é o da PRÓPRIA notificação (canal
 * `alerta_recebido_som_N`, com o som escolhido pelo destinatário em
 * Configurações, uso de notificação, repetido até o toque — ver
 * `NotificacaoService.exibirNotificacaoAlertaRecebido`): no volume atual do
 * aparelho, sem forçar o máximo e sem o uso de alarme. Este plugin só
 * informa ao Dart o modo de som do aparelho, para não tocar nada no
 * silencioso, no vibrar ou no Não Perturbe.
 *
 * Registrado em [MainActivity.configureFlutterEngine]; no engine headless
 * do `firebase_messaging` (app fechado) não existe — o Dart trata a falha e
 * o próprio Android silencia o canal de notificação nesses modos.
 */
class AlertaRecebidoAlarmPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "podeTocarSom" -> result.success(podeTocarSom(context))
                    // Compatibilidade: o loop nativo em volume máximo foi
                    // removido — o som é o da notificação.
                    "iniciarAlarme", "pararAlarme" -> result.success(true)
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object {
        const val CHANNEL = "com.example.security_check_app/alerta_recebido_alarme"

        /** `false` no silencioso, no vibrar ou com o Não Perturbe ligado. */
        fun podeTocarSom(context: Context): Boolean {
            return try {
                val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                if (audio.ringerMode != AudioManager.RINGER_MODE_NORMAL) return false
                val notificacoes = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                notificacoes.currentInterruptionFilter == NotificationManager.INTERRUPTION_FILTER_ALL ||
                    notificacoes.currentInterruptionFilter == NotificationManager.INTERRUPTION_FILTER_UNKNOWN
            } catch (_: Exception) {
                true
            }
        }
    }
}
