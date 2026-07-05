package com.example.security_check_app

import android.os.Build
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.security_check_app/sms"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "enviarSms") {
                try {
                    @Suppress("UNCHECKED_CAST")
                    val telefones = call.argument<List<String>>("telefones") ?: emptyList()
                    val mensagem = call.argument<String>("mensagem") ?: ""

                    val smsManager: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        this.getSystemService(SmsManager::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        SmsManager.getDefault()
                    }

                    for (telefone in telefones) {
                        if (telefone.isBlank()) continue
                        // Divide a mensagem em múltiplas partes caso exceda o
                        // limite de caracteres de um único SMS.
                        val partes = smsManager.divideMessage(mensagem)
                        smsManager.sendMultipartTextMessage(telefone, null, partes, null, null)
                    }

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
