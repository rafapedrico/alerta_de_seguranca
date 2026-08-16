package com.example.security_check_app

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Ponte Dart <-> Android para o modo "Despertador de Emergência" (ver
 * [AlertaRecebidoAlarmService] para a implementação/documentação
 * completa) — chamado por `NotificacaoService`/`AlertaRecebidoScreen` no
 * lado Dart sempre que ESTE aparelho recebe (ou o usuário abre) o alerta
 * crítico de outro usuário.
 *
 * Registrado em [MainActivity.configureFlutterEngine], igual aos demais
 * plugins locais deste app (ver [SmsSender]) — mesma limitação conhecida
 * de NÃO estar disponível no engine headless separado do
 * `firebase_messaging` (ver documentação completa em
 * [AlertaRecebidoAlarmService]): chamadas vindas de lá lançam
 * `MissingPluginException`, tratada com segurança do lado Dart (nunca
 * derruba a notificação principal, que usa um plugin de verdade do
 * pub.dev e continua funcionando normalmente nesse cenário).
 */
class AlertaRecebidoAlarmPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "iniciarAlarme" -> {
                        try {
                            AlertaRecebidoAlarmService.iniciar(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ALERTA_ALARME_ERROR", "Falha ao iniciar o Despertador de Emergência: ${e.message}", null)
                        }
                    }
                    "pararAlarme" -> {
                        try {
                            pararAlarme(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ALERTA_ALARME_ERROR", "Falha ao parar o Despertador de Emergência: ${e.message}", null)
                        }
                    }
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

        /** Reaproveitado por [MainActivity] (ao abrir vindo do toque na
         * notificação PRINCIPAL — ver `tratarIntentDeAlertaRecebido`),
         * silenciando o alarme mesmo antes do lado Dart ter chance de
         * chamar `pararAlarme` pelo MethodChannel. */
        fun pararAlarme(context: Context) {
            AlertaRecebidoAlarmService.parar(context)
        }
    }
}
