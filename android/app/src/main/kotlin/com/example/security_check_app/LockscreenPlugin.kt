package com.example.security_check_app

import android.app.Activity
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin Flutter local responsável por permitir que o lado Dart force,
 * em TEMPO DE EXECUÇÃO (ou seja, já com a Activity totalmente criada e
 * a UI do Flutter sendo desenhada), a reaplicação das flags de
 * sobreposição ao Keyguard (`setShowWhenLocked`/`setTurnScreenOn`) e o
 * dismiss do lockscreen.
 *
 * MOTIVAÇÃO: em versões recentes do Android (observado fisicamente em
 * aparelhos como o Motorola razr 40 ultra), aplicar essas flags apenas
 * uma vez em [MainActivity.onCreate] nem sempre é suficiente quando o
 * gatilho de SOS chega via botão físico de Volume+ com o aparelho já
 * bloqueado: o sistema pode redesenhar o Keyguard por cima da Activity
 * entre o `onCreate()` original e o momento em que a
 * `CameraCapturaScreen` é de fato navegada/desenhada pelo Flutter
 * (engine já "quente", rodando em cache). Reaplicar as mesmas flags
 * exatamente no `initState()` dessa tela — através deste
 * MethodChannel — garante que a instância de janela ATUAL (visível
 * naquele exato momento) receba o comando, e não apenas a instância
 * original criada no `onCreate()`.
 *
 * Implementa [ActivityAware] para sempre ter acesso à Activity
 * corrente (necessário, já que o [MainActivity] mantém o engine em
 * cache entre navegações/reaberturas, e a referência de Activity pode
 * mudar entre uma chamada e outra).
 */
class LockscreenPlugin : FlutterPlugin, ActivityAware {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "forcarShowWhenLocked" -> {
                        try {
                            forcarShowWhenLocked()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error(
                                "LOCKSCREEN_ERROR",
                                "Falha ao forçar showWhenLocked: ${e.message}",
                                null
                            )
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

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    /**
     * Reaplica, na Activity atualmente visível, exatamente o mesmo
     * conjunto de flags/chamadas usado em [MainActivity.onCreate]: exibir
     * por cima do Keyguard e ligar a tela — sem jamais chamar
     * requestDismissKeyguard()/FLAG_DISMISS_KEYGUARD, pois em aparelhos com
     * bloqueio seguro isso aciona a tela de autenticação nativa do Android
     * (PIN/padrão/senha do sistema), o que o fluxo de SOS não pode exigir.
     */
    private fun forcarShowWhenLocked() {
        val act = activity ?: return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            act.setShowWhenLocked(true)
            act.setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            act.window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
    }

    companion object {
        const val CHANNEL = "com.example.security_check_app/lockscreen"
    }
}
