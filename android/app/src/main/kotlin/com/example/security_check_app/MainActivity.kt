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
        try {
            if (ringtone == null) {
                val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) 
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ringtone = RingtoneManager.getRingtone(applicationContext, alarmUri)
            }
            ringtone?.play()

            vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 500, 250, 500), 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(longArrayOf(0, 500, 250, 500), 0)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
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