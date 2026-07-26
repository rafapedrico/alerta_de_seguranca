package com.example.security_check_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * BroadcastReceiver 100% NATIVO, alvo direto do `AlarmManager`
 * (`setExactAndAllowWhileIdle`, agendado por [RotinaAlarmPlugin] em
 * paralelo ao agendamento Dart do `android_alarm_manager_plus`, ver
 * `rotina_alarme_service.dart`).
 *
 * MOTIVO DE EXISTIR: o isolate headless do `android_alarm_manager_plus`
 * não tem NENHUM plugin/MethodChannel local registrado nele (ver
 * `MainApplication.kt`) e, na prática, também se mostrou vulnerável a
 * ser suspenso/encerrado pelo Doze antes de terminar seu trabalho (teste
 * real: o processo foi encerrado entre o toque no botão "Interromper
 * Alarme" e a expiração da tolerância, e o disparo final do alerta foi
 * cortado no meio). Este receiver, por ser 100% nativo e disparado
 * diretamente pelo próprio `AlarmManager` do sistema, NÃO depende de
 * nenhum engine Flutter estar vivo — sua única responsabilidade é
 * acordar o aparelho e abrir a tela do alarme o mais rápido possível,
 * via [RotinaAlarmWakeService] (que segura um WakeLock durante todo o
 * fluxo seguinte).
 *
 * O agendamento Dart via `android_alarm_manager_plus` continua existindo
 * em paralelo (mesmo horário) para toda a lógica de negócio que não é
 * tão crítica em termos de tempo (consultar o banco, reagendar a próxima
 * ocorrência, exibir a notificação) — ver `_callbackCheckinRotina`.
 */
class RotinaAlarmNativeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val idAlarme = intent.getIntExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, -1)
        if (idAlarme < 0) return

        val serviceIntent = Intent(context, RotinaAlarmWakeService::class.java).apply {
            putExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, idAlarme)
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (_: Exception) {
            // Nunca deixa uma exceção aqui derrubar o processo do
            // BroadcastReceiver — na pior das hipóteses, o caminho Dart
            // (headless) ainda tenta abrir a tela por conta própria.
        }
    }
}
