package com.example.security_check_app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine

class LockscreenCameraActivity : MainActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 🔓 Permite que a Activity apareça POR CIMA do Keyguard, sem
        // desbloqueá-lo. Propositalmente NÃO chamamos requestDismissKeyguard()
        // / FLAG_DISMISS_KEYGUARD: em aparelhos com bloqueio seguro (PIN/
        // padrão/senha) essa chamada aciona a tela de autenticação nativa do
        // Android, que é exatamente o que o fluxo de SOS não pode exigir.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }

        // Mantém a tela acesa e impede chamadas do teclado virtual
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
    }

    override fun getInitialRoute(): String {
        return ROTA_INICIAL_SOS_FISICO
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    companion object {
        const val ROTA_INICIAL_SOS_FISICO = "/sos_fisico_lockscreen"
    }
}