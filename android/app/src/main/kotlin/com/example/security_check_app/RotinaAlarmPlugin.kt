package com.example.security_check_app

import android.content.Context
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Ponte Dart <-> nativo do Cronômetro Regressivo e dos despertadores:
 * agenda nativa ([DespertadorAgenda]), ocorrências em andamento
 * ([RotinaAlarmFluxoState]/[RotinaAlarmWakeService]), janelas de
 * localização ([VigiaLocalizacao]) e textos/identidade usados pelos
 * serviços nativos quando o app está fechado.
 */
class RotinaAlarmPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var contexto: Context? = null

    companion object {
        const val METHOD_CHANNEL = "com.example.security_check_app/rotina_alarme"
        const val EVENT_CHANNEL = "com.example.security_check_app/rotina_alarme_events"

        private var activityReference: WeakReference<RotinaCheckinAlarmActivity>? = null

        fun registrarActivity(activity: RotinaCheckinAlarmActivity?) {
            activityReference = activity?.let { WeakReference(it) }
        }

        fun fecharActivityAtiva() {
            try {
                activityReference?.get()?.let { activity ->
                    if (!activity.isFinishing) activity.finish()
                }
            } catch (_: Exception) {
            } finally {
                activityReference = null
            }
        }

        // Trava atômica contra disparo duplo entre dois engines Flutter do
        // MESMO processo (MainActivity + RotinaCheckinAlarmActivity): um
        // HashSet Kotlin é compartilhado por ambos, e as chamadas pelo
        // MethodChannel são serializadas na thread principal.
        private val chavesDisparoReivindicadas = HashSet<String>()

        @Synchronized
        fun reivindicarDisparoUnico(chave: String): Boolean = chavesDisparoReivindicadas.add(chave)

        @Synchronized
        fun liberarReivindicacaoDisparo(chave: String) {
            chavesDisparoReivindicadas.remove(chave)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        contexto = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
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
        contexto = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = contexto ?: return result.error("ROTINA_ALARME_ERROR", "sem contexto", null)
        try {
            when (call.method) {
                "sincronizarDespertador" -> {
                    val regra = DespertadorAgenda.Regra(
                        id = call.argument<Int>("id") ?: return result.error("args", "id", null),
                        hora = call.argument<Int>("hora") ?: 0,
                        minuto = call.argument<Int>("minuto") ?: 0,
                        dias = (call.argument<List<Int>>("dias") ?: emptyList()).toSet(),
                        toleranciaMin = call.argument<Int>("toleranciaMin") ?: 10,
                        ativo = call.argument<Boolean>("ativo") ?: true,
                        pausadoEm = call.argument<String>("pausadoEm"),
                        etiqueta = call.argument<String>("etiqueta") ?: "",
                        contexto = call.argument<String>("contexto") ?: "",
                    )
                    result.success(DespertadorAgenda.sincronizar(ctx, regra)?.paraMapa())
                }
                "removerDespertador" -> {
                    DespertadorAgenda.remover(ctx, call.argument<Int>("id") ?: -1)
                    result.success(true)
                }
                "proximaOcorrencia" -> {
                    val id = call.argument<Int>("id") ?: -1
                    val regra = DespertadorAgenda.regras(ctx)[id]
                    result.success(regra?.let { DespertadorAgenda.proximaOcorrencia(ctx, it)?.paraMapa() })
                }
                "armarCronometro" -> {
                    val ciclo = (call.argument<Number>("ciclo"))?.toLong() ?: 0L
                    val prazo = (call.argument<Number>("prazo"))?.toLong() ?: 0L
                    result.success(DespertadorAgenda.armarCronometro(ctx, ciclo, prazo))
                }
                "encerrarCronometro" -> {
                    DespertadorAgenda.encerrarCronometro(ctx)
                    result.success(true)
                }
                "podeAgendarExato" -> result.success(DespertadorAgenda.podeAgendarExato(ctx))
                "rearmarTudo" -> {
                    DespertadorAgenda.rearmarTudo(ctx)
                    result.success(true)
                }
                "ocorrenciaDaTela" -> {
                    result.success(RotinaCheckinAlarmActivity.ocorrenciaDoIntent(activityReference?.get()?.intent))
                }
                "pendentes" -> {
                    result.success(RotinaAlarmFluxoState.pendentes(ctx).map { it.paraMapa() })
                }
                "resolverOcorrencia", "pararServicoForeground" -> {
                    RotinaAlarmWakeService.resolver(ctx, call.argument<String>("chave"))
                    result.success(true)
                }
                "estaResolvida" -> {
                    result.success(RotinaAlarmFluxoState.estaResolvida(ctx, call.argument<String>("chave") ?: ""))
                }
                "consumirFechamentoForcado" -> {
                    val chave = call.argument<String>("chave") ?: return result.success(false)
                    result.success(RotinaAlarmFluxoState.consumirFechamentoForcado(ctx, chave))
                }
                "salvarTextos" -> {
                    @Suppress("UNCHECKED_CAST")
                    val textos = (call.arguments as? Map<String, String>) ?: emptyMap()
                    TextosNativos.salvar(ctx, textos)
                    result.success(true)
                }
                "configurarIdentidade" -> {
                    @Suppress("UNCHECKED_CAST")
                    val dados = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                    GxFirestoreRest.configurar(ctx, dados)
                    result.success(true)
                }
                "registrarJanelaLocalizacao" -> {
                    VigiaLocalizacao.registrar(
                        ctx,
                        call.argument<String>("docId") ?: return result.error("args", "docId", null),
                        (call.argument<Number>("inicio"))?.toLong() ?: System.currentTimeMillis(),
                        (call.argument<Number>("fim"))?.toLong() ?: 0L,
                        call.argument<String>("tipo") ?: "rotina",
                    )
                    result.success(true)
                }
                "removerJanelaLocalizacao" -> {
                    VigiaLocalizacao.remover(ctx, call.argument<String>("docId") ?: "")
                    result.success(true)
                }
                "fecharTela", "pararAlarme" -> {
                    fecharActivityAtiva()
                    result.success(true)
                }
                "acordarTela" -> {
                    acordarTelaFisicamente(ctx)
                    result.success(true)
                }
                "reivindicarDisparoUnico" -> {
                    result.success(reivindicarDisparoUnico(call.argument<String>("chave") ?: "default"))
                }
                "liberarReivindicacaoDisparo" -> {
                    liberarReivindicacaoDisparo(call.argument<String>("chave") ?: "default")
                    result.success(true)
                }
                "cancelarAlarmeNativo" -> {
                    DespertadorAgenda.cancelarToque(ctx, call.argument<Int>("idAlarme") ?: -1)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("ROTINA_ALARME_ERROR", "${call.method}: ${e.message}", null)
        }
    }

    /** Acende a tela fisicamente agora (WakeLock de tela, 10 s). */
    private fun acordarTelaFisicamente(context: Context) {
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            powerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "SecurityCheckApp::RotinaAlarmScreenWake",
            ).acquire(10_000L)
        } catch (_: Exception) {
        }
    }
}
