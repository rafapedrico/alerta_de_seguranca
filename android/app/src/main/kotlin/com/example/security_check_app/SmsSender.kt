package com.example.security_check_app

import android.content.Context
import android.os.Build
import android.telephony.SmsManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin Flutter local (não publicado no pub.dev) responsável por expor,
 * via [MethodChannel], a lógica nativa de envio de SMS através do
 * [SmsManager] do Android.
 *
 * Implementa [FlutterPlugin] seguindo o padrão moderno recomendado pelo
 * Flutter para plugins customizados: ao invés de registrar o
 * MethodChannel manualmente e duplicar a lógica em cada Activity/engine
 * que precisar dele, a própria classe se registra (`onAttachedToEngine`)
 * e se desregistra (`onDetachedFromEngine`) sozinha, bastando chamar
 * `flutterEngine.plugins.add(SmsSender())` em qualquer [FlutterEngine]
 * controlado pelo app (ver [MainActivity]).
 *
 * IMPORTANTE (limitação conhecida): o FlutterEngine headless criado
 * internamente pelo pacote android_alarm_manager_plus
 * (`FlutterBackgroundExecutor.startBackgroundIsolate`) é totalmente
 * opaco — o próprio plugin de alarme o cria via `new FlutterEngine(...)`
 * sem expor nenhum hook para registrar plugins customizados nele. Ou
 * seja, adicionar este plugin ao [MainActivity] cobre o app em primeiro
 * plano, mas NÃO alcança esse engine headless específico. Por isso, a
 * verdadeira proteção contra falhas nesse cenário fica no lado Dart
 * (ver `EmergencyAlertService.dispararAlertaDeEmergencia`), que trata
 * `MissingPluginException` de forma robusta e nunca tenta novamente em
 * loop.
 */
class SmsSender : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "enviarSms") {
                    try {
                        @Suppress("UNCHECKED_CAST")
                        val telefones = call.argument<List<String>>("telefones") ?: emptyList()
                        val mensagem = call.argument<String>("mensagem") ?: ""

                        enviar(binding.applicationContext, telefones, mensagem)

                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SMS_ERROR", "Falha ao enviar SMS nativo: ${e.message}", null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object {
        /** Nome do MethodChannel usado tanto pela Activity quanto pelo engine headless. */
        const val CHANNEL = "com.example.security_check_app/sms"

        /**
         * Envia a [mensagem] para cada telefone da lista [telefones], dividindo
         * automaticamente em múltiplas partes caso exceda o limite de
         * caracteres de um único SMS.
         *
         * @throws Exception em caso de falha no envio (permissão ausente,
         * SmsManager indisponível, etc.), propagada para quem chamou tratar.
         */
        fun enviar(context: Context, telefones: List<String>, mensagem: String) {
            val smsManager: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }

            for (telefone in telefones) {
                if (telefone.isBlank()) continue
                val partes = smsManager.divideMessage(mensagem)
                smsManager.sendMultipartTextMessage(telefone, null, partes, null, null)
            }
        }
    }
}
