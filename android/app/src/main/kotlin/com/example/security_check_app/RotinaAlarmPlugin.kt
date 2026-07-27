package com.example.security_check_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import androidx.preference.PreferenceManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class RotinaAlarmPlugin : FlutterPlugin {
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    companion object {
        const val METHOD_CHANNEL = "com.example.security_check_app/rotina_alarme"
        const val EVENT_CHANNEL = "com.example.security_check_app/rotina_alarme_events"
        
        // Referência estática segura para fechar a Activity ativa do alarme
        private var activityReference: WeakReference<RotinaCheckinAlarmActivity>? = null

        fun registrarActivity(activity: RotinaCheckinAlarmActivity?) {
            activityReference = activity?.let { WeakReference(it) }
        }

        fun fecharActivityAtiva() {
            try {
                activityReference?.get()?.let { activity ->
                    if (!activity.isFinishing) {
                        activity.finish()
                    }
                }
            } catch (_: Exception) {
            } finally {
                activityReference = null
            }
        }

        /**
         * Reinicia o som em loop na Activity atualmente registrada (se
         * houver uma viva e não finalizando). Retorna `true` se conseguiu
         * encontrar e reiniciar o som em uma Activity já existente, ou
         * `false` caso não haja nenhuma ativa no momento (cenário em que
         * o chamador deve criar uma nova via [iniciarTelaAlarme], cujo
         * próprio `onCreate` já toca o som).
         */
        fun reiniciarSomNaActivityAtiva(): Boolean {
            return try {
                val activity = activityReference?.get()
                if (activity != null && !activity.isFinishing) {
                    activity.reiniciarSom()
                    true
                } else {
                    false
                }
            } catch (_: Exception) {
                false
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "iniciarTelaAlarme" -> {
                        try {
                            val idAlarme = (call.argument<Int>("idAlarme")) ?: -1
                            iniciarTelaAlarme(context, idAlarme)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao iniciar tela de alarme: ${e.message}", null)
                        }
                    }
                    "reiniciarSomSeAtivo" -> {
                        try {
                            // Propositalmente NÃO chama [iniciarTelaAlarme]
                            // aqui: diferente do método antigo
                            // "tocarAlarmeNovamente", este NÃO deve lançar
                            // uma nova Activity via Intent. Se o app já
                            // estiver em primeiro plano rodando dentro da
                            // MainActivity (não da RotinaCheckinAlarmActivity
                            // dedicada), lançar a Activity aqui criaria uma
                            // SEGUNDA janela nativa duplicada por cima da
                            // tela que o usuário já está vendo. Este método
                            // só reinicia o som se JÁ houver uma
                            // RotinaCheckinAlarmActivity viva e registrada —
                            // caso contrário, não faz nada (o som, nesse
                            // cenário, já é garantido pelo AudioPlayer Dart
                            // do lado Flutter, que roda no mesmo engine em
                            // primeiro plano que fez esta chamada).
                            val reiniciado = reiniciarSomNaActivityAtiva()
                            result.success(reiniciado)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao reiniciar som: ${e.message}", null)
                        }
                    }
               "pararAlarme", "pausarAlarme" -> {
                        try {
                            // 1. Desliga o som nativo
                            RotinaAlarmSomBridge.pararSom()
                            // 2. O segredo da vitória: Força a Activity nativa do Android a fechar e sumir!
                            fecharActivityAtiva()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao parar alarme: ${e.message}", null)
                        }
                    }
                    "silenciarSomSemFechar" -> {
                        // CORREÇÃO (bug real observado em teste): diferente de
                        // "pararAlarme"/"pausarAlarme" acima, este método
                        // NUNCA chama [fecharActivityAtiva] — usado
                        // exclusivamente pelo botão azul ("Interromper
                        // Alarme") para silenciar o som ENQUANTO o teclado de
                        // PIN é exibido, sem fechar a Activity nativa (e o
                        // engine Flutter dentro dela) ANTES do PIN ser
                        // digitado. Antes, o botão azul chamava
                        // "pararAlarme", que fechava a Activity
                        // (RotinaCheckinAlarmActivity, cenário de tela
                        // bloqueada) e o teclado nunca chegava a aparecer.
                        try {
                            android.util.Log.d(
                                "RotinaAlarmWakeService",
                                "silenciarSomSemFechar: parando apenas o som nativo (Activity permanece aberta)",
                            )
                            RotinaAlarmSomBridge.pararSom()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao silenciar som: ${e.message}", null)
                        }
                    }
                    "setAlarmDuration" -> {
                        try {
                            val seconds = call.arguments as Int
                            PreferenceManager.getDefaultSharedPreferences(context)
                                .edit()
                                .putInt("alarm_sound_duration", seconds)
                                .apply()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao definir duração do alarme: ${e.message}", null)
                        }
                    }
                    "agendarAlarmeNativo" -> {
                        try {
                            val idAlarme = (call.argument<Int>("idAlarme")) ?: -1
                            val epochMillis = (call.argument<Number>("epochMillis"))?.toLong() ?: -1L
                            val agendado = agendarAlarmeNativo(context, idAlarme, epochMillis)
                            result.success(agendado)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao agendar alarme nativo: ${e.message}", null)
                        }
                    }
                    "cancelarAlarmeNativo" -> {
                        try {
                            val idAlarme = (call.argument<Int>("idAlarme")) ?: -1
                            cancelarAlarmeNativo(context, idAlarme)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao cancelar alarme nativo: ${e.message}", null)
                        }
                    }
                    "pararServicoForeground" -> {
                        try {
                            RotinaAlarmWakeService.parar(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao parar serviço em primeiro plano: ${e.message}", null)
                        }
                    }
                    "acordarParaFaseFinal" -> {
                        try {
                            val idAlarme = (call.argument<Int>("idAlarme")) ?: -1
                            // CORREÇÃO (bug real observado em teste): ao
                            // expirar a tolerância, a tela permanecia apagada
                            // — `setTurnScreenOn`/`setShowWhenLocked` só têm
                            // efeito pleno quando a Activity é CRIADA ou
                            // RETOMADA, e nada estava trazendo-a de volta ao
                            // primeiro plano nesse momento (só o som Dart era
                            // reiniciado). Este método faz os 3 passos
                            // necessários, nesta ordem:
                            // 1. Acende a tela FISICAMENTE agora (WakeLock —
                            //    mecanismo mais antigo, porém confiável em
                            //    qualquer fabricante/versão).
                            acordarTelaFisicamente(context)
                            // 2. Garante que a RotinaCheckinAlarmActivity
                            //    exista e volte ao primeiro plano (cria do
                            //    zero se necessário, ou apenas retoma —
                            //    ambos os casos acionam
                            //    setTurnScreenOn/setShowWhenLocked).
                            iniciarTelaAlarme(context, idAlarme)
                            // 3. Reinicia o som nativo se a Activity já
                            //    existia (senão, o próprio onCreate cuida).
                            reiniciarSomNaActivityAtiva()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ROTINA_ALARME_ERROR", "Falha ao acordar para a janela final: ${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    RotinaAlarmEventBridge.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    RotinaAlarmEventBridge.eventSink = null
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
    }

    /**
     * Força o aparelho a acender a tela FISICAMENTE agora, usando um
     * WakeLock (API mais antiga, marcada como "deprecated" desde o
     * Android 4.2, mas ainda 100% funcional em qualquer versão/fabricante
     * — é exatamente a técnica usada por apps de despertador/chamada
     * para garantir o aceso da tela num instante preciso). Complementa
     * (não substitui) as flags `setShowWhenLocked`/`setTurnScreenOn` da
     * própria Activity, que dependem dela estar sendo criada/retomada
     * para surtir efeito — aqui garantimos o "acender" em si,
     * independente disso. Liberado automaticamente após 10s
     * (`ON_AFTER_RELEASE` mantém a tela ligada por um tempo extra do
     * jeito configurado pelo usuário, sem prendê-la ligada para sempre).
     */
    private fun acordarTelaFisicamente(context: Context) {
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            val wakeLock = powerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "SecurityCheckApp::RotinaAlarmScreenWake",
            )
            wakeLock.acquire(10_000L)
        } catch (_: Exception) {
            // Falha silenciosa: as flags da Activity (showWhenLocked/
            // turnScreenOn) ainda tentam acender a tela por conta própria.
        }
    }

    private fun iniciarTelaAlarme(context: Context, idAlarme: Int) {
        // Marca o fluxo como "em andamento" para [RotinaAlarmWakeService]
        // saber (via [RotinaAlarmFluxoState], persistido nativamente)
        // que deve reabrir esta tela caso o usuário desbloqueie o
        // aparelho ou arraste o app para fora dos Recentes antes do PIN
        // correto ser digitado.
        RotinaAlarmFluxoState.marcarEmAndamento(context, idAlarme)
        val intent = Intent(context, RotinaCheckinAlarmActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
            putExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, idAlarme)
        }
        context.startActivity(intent)
    }

    private fun criarPendingIntentNativo(context: Context, idAlarme: Int): PendingIntent {
        val intent = Intent(context, RotinaAlarmNativeReceiver::class.java).apply {
            putExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, idAlarme)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        // idAlarme como requestCode: cada alarme de rotina tem seu próprio
        // PendingIntent independente, igual ao esquema de IDs usado pelo
        // android_alarm_manager_plus do lado Dart.
        return PendingIntent.getBroadcast(context, idAlarme, intent, flags)
    }

    /**
     * Agenda o alarme NATIVO paralelo (ver [RotinaAlarmNativeReceiver]),
     * usando `setExactAndAllowWhileIdle` para dispará-lo no segundo exato
     * programado MESMO com o aparelho em Doze/deep sleep — o mesmo
     * horário já agendado do lado Dart via `android_alarm_manager_plus`
     * (ver `RotinaAlarmeService.agendarAlarme`). Retorna `false` (sem
     * lançar exceção) se a permissão de alarmes exatos tiver sido
     * revogada pelo usuário (Android 12+/S) — nesse caso, o alarme Dart
     * "normal" ainda tenta funcionar por conta própria.
     */
    private fun agendarAlarmeNativo(context: Context, idAlarme: Int, epochMillis: Long): Boolean {
        if (idAlarme < 0 || epochMillis <= 0L) return false

        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !alarmManager.canScheduleExactAlarms()) {
            return false
        }

        val pendingIntent = criarPendingIntentNativo(context, idAlarme)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, epochMillis, pendingIntent)
        } else {
            alarmManager.setExact(AlarmManager.RTC_WAKEUP, epochMillis, pendingIntent)
        }
        return true
    }

    /** Cancela o alarme nativo paralelo agendado por [agendarAlarmeNativo]. */
    private fun cancelarAlarmeNativo(context: Context, idAlarme: Int) {
        if (idAlarme < 0) return
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(criarPendingIntentNativo(context, idAlarme))
    }
}

object RotinaAlarmSomBridge {
    private var mediaPlayer: android.media.MediaPlayer? = null

    fun registrarPlayer(player: android.media.MediaPlayer?) {
        mediaPlayer = player
    }

    fun pararSom() {
        try {
            mediaPlayer?.let {
                if (it.isPlaying) {
                    it.stop()
                }
                it.release()
            }
        } catch (_: Exception) {
        } finally {
            mediaPlayer = null
        }
    }
}