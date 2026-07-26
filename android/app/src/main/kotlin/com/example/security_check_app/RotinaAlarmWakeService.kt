package com.example.security_check_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Foreground Service que garante que o alarme de rotina "acorde" o
 * aparelho de verdade, mesmo em Doze/deep sleep — CORREÇÃO do bug
 * relatado em teste real: com o aparelho bloqueado por alguns minutos, o
 * Android suspendia o processo do app antes que o isolate headless do
 * `android_alarm_manager_plus` conseguisse sequer abrir a tela do
 * alarme, e o disparo do alerta de emergência na janela final também era
 * interrompido no meio (nenhuma confirmação de envio chegava a ser
 * logada).
 *
 * ESTRATÉGIA (mesma já validada em [VolumeSosService] para o botão físico
 * de SOS): este Service é iniciado DIRETAMENTE por um
 * [android.app.PendingIntent] nativo do `AlarmManager`
 * (`setExactAndAllowWhileIdle`, ver [RotinaAlarmNativeReceiver]) — um
 * caminho 100% nativo, que NÃO depende de nenhum MethodChannel/engine
 * Flutter estar "quente" (diferente do isolate headless do
 * `android_alarm_manager_plus`, que não tem NENHUM plugin local
 * registrado nele, ver `MainApplication.kt`). Ele:
 *
 * 1. Adquire um [PowerManager.PARTIAL_WAKE_LOCK], mantendo a CPU do
 *    processo ativa (sem Doze) por toda a duração do fluxo (do disparo
 *    inicial até o desarme/disparo do alerta) — é isso que garante que o
 *    cronômetro de tolerância/janela final e o disparo final de SMS/nuvem
 *    (ambos ainda coordenados pelo lado Dart, ver `rotina_alarme_service.dart`)
 *    consigam de fato terminar de executar, mesmo com a tela apagada.
 * 2. Inicia a [RotinaCheckinAlarmActivity] via [Intent], que exibe o
 *    teclado de PIN por cima da tela de bloqueio e toca o som em loop.
 *
 * O WakeLock é liberado explicitamente assim que o lado Dart sinaliza
 * que o fluxo foi resolvido (PIN confirmado ou alerta de emergência já
 * disparado — ver método `pararServicoForeground` em
 * [RotinaAlarmPlugin]), e tem um teto de segurança de 10 minutos para
 * NUNCA ficar preso indefinidamente drenando bateria caso esse sinal de
 * conclusão falhe por qualquer motivo.
 */
class RotinaAlarmWakeService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        iniciarEmForeground()
        adquirirWakeLock()

        val idAlarme = intent?.getIntExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, -1) ?: -1
        iniciarTelaDoAlarme(idAlarme)

        // START_NOT_STICKY: não faz sentido o Android recriar este Service
        // sozinho sem o extra do idAlarme — o próprio alarme nativo (ou o
        // lado Dart, se o usuário reabrir o app) já cuida de tudo a partir
        // daqui.
        return START_NOT_STICKY
    }

    private fun iniciarTelaDoAlarme(idAlarme: Int) {
        try {
            val intent = Intent(this, RotinaCheckinAlarmActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
                putExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, idAlarme)
            }
            startActivity(intent)
        } catch (_: Exception) {
            // Falha silenciosa: o WakeLock adquirido acima já ajuda o
            // caminho Dart/headless a completar seu trabalho mesmo que a
            // Activity não abra por algum motivo específico de fabricante.
        }
    }

    /**
     * Adquire um WakeLock parcial (mantém só a CPU ativa; a tela é
     * ligada separadamente pelas flags da própria Activity —
     * `setShowWhenLocked`/`setTurnScreenOn`, ver
     * [RotinaCheckinAlarmActivity]). Timeout de segurança de 10 minutos:
     * cobre o pior caso realista (tolerância + 2 minutos da janela final)
     * sem risco de vazamento de bateria caso o sinal explícito de
     * liberação nunca chegue.
     */
    private fun adquirirWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "SecurityCheckApp::RotinaAlarmWakeLock",
            ).apply {
                setReferenceCounted(false)
                acquire(10 * 60 * 1000L)
            }
        } catch (_: Exception) {
            wakeLock = null
        }
    }

    private fun liberarWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {
        } finally {
            wakeLock = null
        }
    }

    private fun iniciarEmForeground() {
        val canalId = "rotina_alarme_wake_channel"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(canalId) == null) {
                val canal = NotificationChannel(
                    canalId,
                    "Alarme de rotina (segurança)",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description = "Mantém o alarme de rotina funcionando com a tela bloqueada."
                    setShowBadge(false)
                }
                manager.createNotificationChannel(canal)
            }
        }

        val notificacao = NotificationCompat.Builder(this, canalId)
            .setContentTitle("Alarme de rotina ativo")
            .setContentText("Confirmando se está tudo bem...")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notificacao,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notificacao)
        }
    }

    override fun onDestroy() {
        liberarWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val NOTIFICATION_ID = 7712

        /**
         * Libera o WakeLock e encerra este Service — chamado pelo lado
         * Dart (via [RotinaAlarmPlugin], MethodChannel
         * "pararServicoForeground") assim que o fluxo é resolvido: PIN
         * confirmado com sucesso OU alerta de emergência já disparado.
         * Seguro mesmo se o Service não estiver rodando.
         */
        fun parar(context: Context) {
            try {
                context.stopService(Intent(context, RotinaAlarmWakeService::class.java))
            } catch (_: Exception) {
            }
        }
    }
}
