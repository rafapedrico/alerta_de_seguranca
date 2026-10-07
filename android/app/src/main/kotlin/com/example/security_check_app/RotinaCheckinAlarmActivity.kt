package com.example.security_check_app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine

/**
 * Activity nativa DEDICADA à tela do alarme — despertador (aba Família) e
 * Cronômetro Regressivo (aba Segurança) — por cima da tela bloqueada,
 * inclusive com o app fechado. Aberta pelo [RotinaAlarmWakeService]
 * (full-screen intent / `startActivity`).
 *
 * O SOM não é tocado aqui nem no Dart: é responsabilidade exclusiva do
 * [RotinaAlarmWakeService] (um único som, o escolhido em Configurações).
 *
 * A ocorrência exibida (tipo/id/ciclo/prazo) vem nos extras do Intent e é
 * lida pelo Dart pelo método `ocorrenciaDaTela` do [RotinaAlarmPlugin];
 * `abrirTeclado` (botão "Desativar despertador" da notificação) abre a
 * tela direto no teclado de PIN. Um novo Intent com a Activity já aberta
 * (`onNewIntent`) é avisado ao Dart pelo [RotinaAlarmEventBridge].
 */
class RotinaCheckinAlarmActivity : MainActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        RotinaAlarmPlugin.registrarActivity(this)
        super.onCreate(savedInstanceState)

        // Flags de Keyguard aplicadas aqui (não herdadas da MainActivity):
        // a tela do alarme aparece por cima do bloqueio e acende o aparelho.
        // Sem requestDismissKeyguard: o teclado de PIN do próprio app já faz
        // esse papel.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
    }

    /** Rota inicial do Dart conforme o tipo da ocorrência (ver `main.dart`). */
    override fun getInitialRoute(): String {
        return if (tipoAlarmeDoIntent(intent) == TIPO_ALARME_CRONOMETRO) {
            ROTA_INICIAL_CRONOMETRO_ALARME
        } else {
            ROTA_INICIAL_ROTINA_ALARME
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        RotinaAlarmEventBridge.notificarNovoDisparo(ocorrenciaDoIntent(intent))
    }

    override fun onDestroy() {
        RotinaAlarmPlugin.registrarActivity(null)
        super.onDestroy()
    }

    companion object {
        const val ROTA_INICIAL_ROTINA_ALARME = "/rotina_alarme_confirmacao"
        const val ROTA_INICIAL_CRONOMETRO_ALARME = "/cronometro_alarme_confirmacao"

        const val EXTRA_ID_ALARME = "id_alarme_rotina"
        const val EXTRA_TIPO_ALARME = "tipo_alarme"
        const val EXTRA_CICLO = "ciclo_epoch_ms"
        const val EXTRA_PRAZO = "prazo_epoch_ms"
        const val EXTRA_ABRIR_TECLADO = "abrir_teclado"
        const val TIPO_ALARME_ROTINA = "rotina"
        const val TIPO_ALARME_CRONOMETRO = "cronometro"

        fun idAlarmeDoIntent(intent: Intent?): Int? {
            if (intent == null || !intent.hasExtra(EXTRA_ID_ALARME)) return null
            val valor = intent.getIntExtra(EXTRA_ID_ALARME, -1)
            return if (valor >= 0) valor else null
        }

        fun tipoAlarmeDoIntent(intent: Intent?): String {
            return intent?.getStringExtra(EXTRA_TIPO_ALARME) ?: TIPO_ALARME_ROTINA
        }

        /** Ocorrência + `abrirTeclado` dos extras, para o Dart. */
        fun ocorrenciaDoIntent(intent: Intent?): Map<String, Any?>? {
            val id = idAlarmeDoIntent(intent) ?: return null
            val tipo = tipoAlarmeDoIntent(intent)
            val ciclo = intent?.getLongExtra(EXTRA_CICLO, 0L) ?: 0L
            val prazo = intent?.getLongExtra(EXTRA_PRAZO, 0L) ?: 0L
            return mapOf(
                "tipo" to tipo,
                "id" to id,
                "ciclo" to ciclo,
                "prazo" to prazo,
                "chave" to Ocorrencia.chave(tipo, id, ciclo),
                "abrirTeclado" to (intent?.getBooleanExtra(EXTRA_ABRIR_TECLADO, false) ?: false),
            )
        }
    }
}

/**
 * Avisa o Dart (EventChannel do [RotinaAlarmPlugin]) quando a Activity, já
 * aberta, recebe uma NOVA ocorrência ou o toque em "Desativar despertador".
 */
object RotinaAlarmEventBridge {
    var eventSink: io.flutter.plugin.common.EventChannel.EventSink? = null

    fun notificarNovoDisparo(ocorrencia: Map<String, Any?>?) {
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            eventSink?.success(ocorrencia)
        }
    }
}
