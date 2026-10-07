package com.example.security_check_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.concurrent.Executors

/**
 * Agenda NATIVA dos despertadores (aba Família) e do Cronômetro
 * Regressivo — o que precisa continuar funcionando sem engine Flutter:
 * depois de reiniciar o aparelho, com o app fechado, e para armar a
 * PRÓXIMA ocorrência só DEPOIS que a atual foi resolvida.
 *
 * O Dart sincroniza a regra de cada despertador ([sincronizar]: horário,
 * dias, tolerância, pausa, etiqueta) e o nativo calcula a próxima
 * ocorrência, arma o alarme exato do toque ([RotinaAlarmNativeReceiver]) e
 * a janela de localização das 2 h antes ([VigiaLocalizacao]). Uma
 * ocorrência em andamento (na tolerância) nunca é substituída: a próxima só
 * é armada em [armarProxima], chamado quando ela é resolvida (PIN correto,
 * alerta enviado) ou abandonada.
 */
object DespertadorAgenda {
    private const val TAG = "DespertadorAgenda"
    private const val PREFS = "gx_despertador_agenda"
    private const val CHAVE_REGRAS = "regras"
    private const val CHAVE_CRONOMETRO = "cronometro"
    private const val JANELA_LOCALIZACAO_MS = 2 * 60 * 60_000L

    /** Id reservado do Cronômetro (mesmo `AlarmeService.idAlarmeCronometroSeguranca`). */
    const val ID_CRONOMETRO = 999999

    private val rede = Executors.newSingleThreadExecutor()

    data class Regra(
        val id: Int,
        val hora: Int,
        val minuto: Int,
        val dias: Set<Int>,
        val toleranciaMin: Int,
        val ativo: Boolean,
        /** Dia pausado (`yyyy-MM-dd`): a pausa vale até 00h00 do dia seguinte. */
        val pausadoEm: String?,
        val etiqueta: String,
        val contexto: String,
    ) {
        fun paraJson(): JSONObject = JSONObject()
            .put("id", id).put("hora", hora).put("minuto", minuto)
            .put("dias", JSONArray(dias.sorted()))
            .put("toleranciaMin", toleranciaMin).put("ativo", ativo)
            .put("pausadoEm", pausadoEm ?: JSONObject.NULL)
            .put("etiqueta", etiqueta).put("contexto", contexto)

        companion object {
            fun deJson(j: JSONObject): Regra? = try {
                val arr = j.optJSONArray("dias") ?: JSONArray()
                Regra(
                    id = j.getInt("id"),
                    hora = j.getInt("hora"),
                    minuto = j.getInt("minuto"),
                    dias = (0 until arr.length()).map { arr.getInt(it) }.toSet(),
                    toleranciaMin = j.optInt("toleranciaMin", 10),
                    ativo = j.optBoolean("ativo", true),
                    pausadoEm = if (j.isNull("pausadoEm")) null else j.optString("pausadoEm"),
                    etiqueta = j.optString("etiqueta", ""),
                    contexto = j.optString("contexto", ""),
                )
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun regras(ctx: Context): Map<Int, Regra> {
        val texto = prefs(ctx).getString(CHAVE_REGRAS, null) ?: return emptyMap()
        return try {
            val arr = JSONArray(texto)
            (0 until arr.length()).mapNotNull { Regra.deJson(arr.getJSONObject(it)) }.associateBy { it.id }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    @Synchronized
    private fun salvarRegras(ctx: Context, regras: Collection<Regra>) {
        val arr = JSONArray()
        regras.forEach { arr.put(it.paraJson()) }
        prefs(ctx).edit().putString(CHAVE_REGRAS, arr.toString()).commit()
    }

    fun etiqueta(ctx: Context, id: Int): String = regras(ctx)[id]?.etiqueta.orEmpty()

    /**
     * Grava a regra e arma a próxima ocorrência — a menos que exista uma
     * ocorrência DESTE despertador em andamento (na tolerância): nesse caso
     * a próxima só é armada quando ela for resolvida. Devolve a próxima
     * ocorrência armada (ou `null`).
     */
    fun sincronizar(ctx: Context, regra: Regra): Ocorrencia? {
        salvarRegras(ctx, regras(ctx).values.filter { it.id != regra.id } + regra)
        val emAndamento = RotinaAlarmFluxoState.pendentes(ctx).any {
            it.tipo == RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA && it.id == regra.id
        }
        if (emAndamento) {
            Log.d(TAG, "Despertador #${regra.id} na tolerância — próxima ocorrência fica para depois.")
            return null
        }
        return armarProxima(ctx, regra.id)
    }

    /** Remove a regra e cancela o que estiver armado (apagar/desativar). */
    fun remover(ctx: Context, id: Int) {
        salvarRegras(ctx, regras(ctx).values.filter { it.id != id })
        cancelarToque(ctx, id)
        VigiaLocalizacao.remover(ctx, id.toString())
    }

    /** Próxima ocorrência de [regra] depois de [depoisDe] (nunca uma já
     * resolvida, nunca num dia pausado). `null` se não houver. */
    fun proximaOcorrencia(ctx: Context, regra: Regra, depoisDe: Long = System.currentTimeMillis()): Ocorrencia? {
        if (!regra.ativo) return null
        val base = Calendar.getInstance().apply { timeInMillis = depoisDe }
        for (offset in 0..8) {
            val c = (base.clone() as Calendar).apply {
                add(Calendar.DAY_OF_YEAR, offset)
                set(Calendar.HOUR_OF_DAY, regra.hora)
                set(Calendar.MINUTE, regra.minuto)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            val ciclo = c.timeInMillis
            if (ciclo <= depoisDe) continue
            // 1 = segunda … 7 = domingo (mesmo esquema do Dart).
            val diaSemana = ((c.get(Calendar.DAY_OF_WEEK) + 5) % 7) + 1
            if (regra.dias.isNotEmpty() && !regra.dias.contains(diaSemana)) continue
            if (regra.dias.isEmpty() && offset > 0) return null
            if (regra.pausadoEm != null && regra.pausadoEm == dataIso(c)) continue
            val ocorrencia = Ocorrencia(
                RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA,
                regra.id,
                ciclo,
                ciclo + regra.toleranciaMin * 60_000L,
            )
            if (RotinaAlarmFluxoState.estaResolvida(ctx, ocorrencia.chave)) continue
            return ocorrencia
        }
        return null
    }

    /** Arma a próxima ocorrência do despertador [id] (toque + janela de
     * localização das 2 h antes) e garante o documento do ciclo na nuvem. */
    fun armarProxima(ctx: Context, id: Int): Ocorrencia? {
        if (id == ID_CRONOMETRO) return null
        val regra = regras(ctx)[id]
        if (regra == null) {
            cancelarToque(ctx, id)
            VigiaLocalizacao.remover(ctx, id.toString())
            return null
        }
        val ocorrencia = proximaOcorrencia(ctx, regra)
        if (ocorrencia == null) {
            cancelarToque(ctx, id)
            VigiaLocalizacao.remover(ctx, id.toString())
            return null
        }
        if (GxFirestoreRest.planoBloqueadoEm(ctx, ocorrencia.ciclo)) {
            // Plano Free nos dias bloqueados: não toca e a nuvem não dispara.
            Log.d(TAG, "Despertador #$id não armado — Plano Free bloqueado na próxima ocorrência.")
            cancelarToque(ctx, id)
            VigiaLocalizacao.remover(ctx, id.toString())
            rede.execute {
                try { GxFirestoreRest.marcarCancelado(ctx, id) } catch (_: Exception) {}
            }
            return null
        }
        armarToque(ctx, ocorrencia)
        VigiaLocalizacao.registrar(
            ctx, id.toString(), ocorrencia.ciclo - JANELA_LOCALIZACAO_MS, ocorrencia.prazo, "rotina",
        )
        val etiqueta = regra.etiqueta
        val contexto = regra.contexto
        rede.execute {
            try {
                GxFirestoreRest.garantirCicloDespertador(ctx, id, ocorrencia.ciclo, ocorrencia.prazo, etiqueta, contexto)
            } catch (e: Exception) {
                Log.w(TAG, "Ciclo #$id não registrado na nuvem agora: $e")
            }
        }
        Log.d(TAG, "Despertador #$id armado para ${ocorrencia.ciclo} (prazo ${ocorrencia.prazo}).")
        return ocorrencia
    }

    /** Chamado quando o despertador toca: mantém a janela de localização
     * até o fim da tolerância. */
    fun aoTocar(ctx: Context, id: Int, ciclo: Long, prazo: Long) {
        VigiaLocalizacao.registrar(ctx, id.toString(), ciclo - JANELA_LOCALIZACAO_MS, prazo, "rotina")
    }

    // ------------------------------------------------------------------
    // Cronômetro Regressivo
    // ------------------------------------------------------------------

    /** Cronômetro ativo: grava (para o reinício do aparelho), arma o alarme
     * exato no fim e liga a janela de localização até o fim da tolerância. */
    fun armarCronometro(ctx: Context, ciclo: Long, prazo: Long): Boolean {
        prefs(ctx).edit().putString(
            CHAVE_CRONOMETRO,
            JSONObject().put("ciclo", ciclo).put("prazo", prazo).toString(),
        ).commit()
        VigiaLocalizacao.registrar(ctx, VigiaLocalizacao.ID_CRONOMETRO, System.currentTimeMillis(), prazo, "cronometro")
        return armarToque(
            ctx,
            Ocorrencia(RotinaCheckinAlarmActivity.TIPO_ALARME_CRONOMETRO, ID_CRONOMETRO, ciclo, prazo),
        )
    }

    /** Cronômetro encerrado (PIN correto ou alerta enviado). */
    fun encerrarCronometro(ctx: Context) {
        prefs(ctx).edit().remove(CHAVE_CRONOMETRO).commit()
        cancelarToque(ctx, ID_CRONOMETRO)
        VigiaLocalizacao.remover(ctx, VigiaLocalizacao.ID_CRONOMETRO)
    }

    fun cronometroAtivo(ctx: Context): Ocorrencia? {
        val texto = prefs(ctx).getString(CHAVE_CRONOMETRO, null) ?: return null
        return try {
            val j = JSONObject(texto)
            Ocorrencia(
                RotinaCheckinAlarmActivity.TIPO_ALARME_CRONOMETRO,
                ID_CRONOMETRO,
                j.getLong("ciclo"),
                j.getLong("prazo"),
            )
        } catch (_: Exception) {
            null
        }
    }

    // ------------------------------------------------------------------
    // Alarme exato
    // ------------------------------------------------------------------

    fun podeAgendarExato(ctx: Context): Boolean {
        val alarmManager = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()
    }

    private fun pendingToque(ctx: Context, ocorrencia: Ocorrencia?, id: Int): PendingIntent {
        val intent = Intent(ctx, RotinaAlarmNativeReceiver::class.java).apply {
            putExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, id)
            if (ocorrencia != null) {
                putExtra(RotinaCheckinAlarmActivity.EXTRA_TIPO_ALARME, ocorrencia.tipo)
                putExtra(RotinaCheckinAlarmActivity.EXTRA_CICLO, ocorrencia.ciclo)
                putExtra(RotinaCheckinAlarmActivity.EXTRA_PRAZO, ocorrencia.prazo)
            }
        }
        return PendingIntent.getBroadcast(
            ctx, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** `false` se o alarme exato não pôde ser armado (permissão negada). */
    fun armarToque(ctx: Context, ocorrencia: Ocorrencia): Boolean {
        val alarmManager = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (!podeAgendarExato(ctx)) {
            Log.w(TAG, "Sem permissão de alarme exato — ${ocorrencia.chave} não armado.")
            return false
        }
        return try {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP, ocorrencia.ciclo, pendingToque(ctx, ocorrencia, ocorrencia.id),
            )
            true
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao armar ${ocorrencia.chave}: $e")
            false
        }
    }

    fun cancelarToque(ctx: Context, id: Int) {
        try {
            (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pendingToque(ctx, null, id))
        } catch (_: Exception) {
        }
    }

    // ------------------------------------------------------------------
    // Reinício do aparelho
    // ------------------------------------------------------------------

    /**
     * Depois de reiniciar: rearma o cronômetro (ou o toca agora, se o fim
     * passou e a tolerância ainda não acabou) e todos os despertadores —
     * inclusive uma ocorrência que estava na tolerância.
     */
    fun rearmarTudo(ctx: Context) {
        val agora = System.currentTimeMillis()
        cronometroAtivo(ctx)?.let { o ->
            when {
                RotinaAlarmFluxoState.estaResolvida(ctx, o.chave) || o.prazo <= agora -> encerrarCronometro(ctx)
                o.ciclo > agora -> armarCronometro(ctx, o.ciclo, o.prazo)
                else -> {
                    VigiaLocalizacao.registrar(ctx, VigiaLocalizacao.ID_CRONOMETRO, agora, o.prazo, "cronometro")
                    RotinaAlarmWakeService.iniciar(ctx, o)
                }
            }
        }
        val emAndamento = RotinaAlarmFluxoState.pendentes(ctx)
            .filter { it.tipo == RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA && it.prazo > agora }
        for (o in emAndamento) {
            aoTocar(ctx, o.id, o.ciclo, o.prazo)
            RotinaAlarmWakeService.iniciar(ctx, o)
        }
        for (regra in regras(ctx).values) {
            if (emAndamento.any { it.id == regra.id }) continue
            // Uma ocorrência que deveria ter tocado com o aparelho desligado
            // e ainda está na tolerância toca agora.
            val anterior = proximaOcorrencia(ctx, regra, agora - regra.toleranciaMin * 60_000L)
            if (anterior != null && anterior.ciclo <= agora && anterior.prazo > agora) {
                aoTocar(ctx, regra.id, anterior.ciclo, anterior.prazo)
                RotinaAlarmWakeService.iniciar(ctx, anterior)
            } else {
                armarProxima(ctx, regra.id)
            }
        }
        VigiaLocalizacao.rearmar(ctx)
    }

    private fun dataIso(c: Calendar): String =
        "%04d-%02d-%02d".format(c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
}

/** Rearma cronômetro, despertadores e janelas de localização depois de
 * reiniciar o aparelho ou atualizar o app — sem abrir o app. */
class GxAlarmesBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> {
                Log.d("DespertadorAgenda", "Rearmando alarmes (${intent.action}).")
                val pendente = goAsync()
                Thread {
                    try {
                        DespertadorAgenda.rearmarTudo(context.applicationContext)
                    } catch (e: Exception) {
                        Log.w("DespertadorAgenda", "Falha ao rearmar: $e")
                    } finally {
                        pendente.finish()
                    }
                }.start()
            }
        }
    }
}
