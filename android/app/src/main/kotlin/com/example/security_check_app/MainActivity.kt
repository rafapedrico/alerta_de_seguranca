package com.example.security_check_app

import android.content.Context
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Vibrator
import android.os.VibrationEffect
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

open class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.security_check_app/rotina_alarme"
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Mantém o registro dos plugins essenciais
        flutterEngine.plugins.add(SmsSender())
        flutterEngine.plugins.add(VolumeSosPlugin())
        flutterEngine.plugins.add(LockscreenPlugin())
        flutterEngine.plugins.add(RotinaAlarmPlugin())
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "iniciarTelaAlarme" -> {
                    iniciarAlarmeNativo()
                    result.success(true)
                }
                "pararAlarme" -> {
                    pararAlarmeNativo()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

private fun iniciarAlarmeNativo() {
        // Método limpo por design: o som customizado agora é disparado e gerenciado 
        // diretamente via AudioPlayer na interface estável do Flutter (alarme_disparado_screen.dart).
        println("📱 [NATIVO] Tela chamada com sucesso. Som gerenciado pelo Flutter.")
    }

    private fun pararAlarmeNativo() {
        ringtone?.stop()
        vibrator?.cancel()
    }

    override fun onDestroy() {
        pararAlarmeNativo()
        super.onDestroy()
    }
}