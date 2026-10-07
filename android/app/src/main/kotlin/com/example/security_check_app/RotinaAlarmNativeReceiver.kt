package com.example.security_check_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * BroadcastReceiver 100% NATIVO, alvo direto do `AlarmManager`
 * (`setExactAndAllowWhileIdle`, armado por [DespertadorAgenda]) no horário
 * do despertador ou no fim do Cronômetro Regressivo. Não depende de nenhum
 * engine Flutter: só acorda o aparelho e entrega a ocorrência
 * (tipo/id/ciclo/prazo) ao [RotinaAlarmWakeService], que segura o WakeLock,
 * toca o som e abre a tela durante toda a tolerância.
 */
class RotinaAlarmNativeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val idAlarme = intent.getIntExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, -1)
        if (idAlarme < 0) return
        val tipoAlarme = RotinaCheckinAlarmActivity.tipoAlarmeDoIntent(intent)
        val agora = System.currentTimeMillis()
        val ciclo = intent.getLongExtra(RotinaCheckinAlarmActivity.EXTRA_CICLO, 0L).takeIf { it > 0L } ?: agora
        var prazo = intent.getLongExtra(RotinaCheckinAlarmActivity.EXTRA_PRAZO, 0L)
        if (prazo <= ciclo) {
            // Alarme armado por uma versão anterior (sem o prazo no Intent).
            val tolerancia = DespertadorAgenda.regras(context)[idAlarme]?.toleranciaMin
            prazo = ciclo + (if (tolerancia != null) tolerancia * 60_000L else 60_000L)
        }
        RotinaAlarmWakeService.iniciar(context, Ocorrencia(tipoAlarme, idAlarme, ciclo, prazo))
    }
}
