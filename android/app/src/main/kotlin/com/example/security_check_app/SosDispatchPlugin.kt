package com.example.security_check_app

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin Flutter local responsável por expor, via [MethodChannel], o
 * controle do [SosDispatchService] — o Foreground Service que mantém o
 * processo vivo durante a janela crítica de envio do SOS (SMS + upload à
 * nuvem, ver documentação completa em [SosDispatchService] e em
 * `SosDisparoService` no lado Dart).
 *
 * MethodChannel ("com.example.security_check_app/sos_dispatch"):
 * - "iniciar": inicia o Foreground Service (chamado ANTES de despachar
 *   o SMS/upload).
 * - "parar": encerra o Foreground Service (chamado num `finally`, assim
 *   que o SMS/upload concluir — sucesso ou falha).
 *
 * Não precisa de [io.flutter.embedding.engine.plugins.activity.ActivityAware]:
 * iniciar/parar um Service só depende do `applicationContext`, disponível
 * já em [onAttachedToEngine].
 */
class SosDispatchPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "iniciar" -> {
                        try {
                            SosDispatchService.iniciar(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SOS_DISPATCH_ERROR", "Falha ao iniciar SosDispatchService: ${e.message}", null)
                        }
                    }
                    "parar" -> {
                        try {
                            SosDispatchService.parar(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SOS_DISPATCH_ERROR", "Falha ao parar SosDispatchService: ${e.message}", null)
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
        const val CHANNEL = "com.example.security_check_app/sos_dispatch"
    }
}
