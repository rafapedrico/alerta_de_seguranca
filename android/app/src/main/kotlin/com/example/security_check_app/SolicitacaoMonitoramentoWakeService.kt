package com.example.security_check_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

private const val TAG = "SolicitacaoMonitoramentoWakeService"

/**
 * Foreground Service "dispare e esqueça" que acorda o aparelho e enfileira
 * a abertura do [MainActivity] quando chega uma SOLICITAÇÃO de localização
 * via FCM (ver [SolicitacaoMonitoramentoFcmReceiver]) — WakeLock parcial +
 * `startForeground` (é essa promoção que dá ao Android permissão de abrir
 * uma Activity a partir do background) + `startActivity` direto, mesma
 * técnica de [VolumeSosService]/[RotinaAlarmWakeService].
 *
 * DIFERENÇA DE PROPÓSITO em relação a essas duas classes (segurança,
 * decisão deliberada): [MainActivity] NÃO declara `showWhenLocked` (ver
 * `AndroidManifest.xml`) — diferente do botão físico de SOS
 * ([LockscreenCameraActivity]) e do alarme de rotina
 * ([RotinaCheckinAlarmActivity]), que legitimamente precisam desenhar por
 * cima do Keyguard sem autenticação (emergências reais). Uma solicitação
 * de localização de outra pessoa NÃO justifica esse mesmo bypass: este
 * `startActivity` apenas ACORDA a tela (`turnScreenOn`) — o Android exibe
 * o PRÓPRIO bloqueio (PIN/padrão/biometria) antes de sequer entregar esta
 * Activity ao usuário. Só depois do desbloqueio real do aparelho é que o
 * app abre (sempre na tela de Login — barreira de autenticação, ver
 * política de segurança em `main.dart` — nunca pulada), e o payload desta
 * solicitação (entregue via extras do Intent) fica disponível para o modal
 * de decisão abrir automaticamente assim que o login terminar.
 */
class SolicitacaoMonitoramentoWakeService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        iniciarEmForeground()
        adquirirWakeLock()

        val idPermissao = intent?.getStringExtra(EXTRA_ID_PERMISSAO)
        if (idPermissao != null) {
            abrirMainActivity(
                idPermissao = idPermissao,
                uidSolicitante = intent.getStringExtra(EXTRA_UID_SOLICITANTE) ?: "",
                nomeSolicitante = intent.getStringExtra(EXTRA_NOME_SOLICITANTE) ?: "",
                telefoneSolicitante = intent.getStringExtra(EXTRA_TELEFONE_SOLICITANTE) ?: "",
            )
        } else {
            Log.d(TAG, "onStartCommand: sem idPermissao nos extras — nada a fazer.")
        }

        // Encerra pouco depois — a Activity já foi lançada; o pequeno
        // atraso só garante que ela teve tempo de assumir o foco antes do
        // Service (e seu WakeLock) sumirem.
        Handler(Looper.getMainLooper()).postDelayed({
            liberarWakeLock()
            stopSelf()
        }, 5000L)

        return START_NOT_STICKY
    }

    private fun abrirMainActivity(
        idPermissao: String,
        uidSolicitante: String,
        nomeSolicitante: String,
        telefoneSolicitante: String,
    ) {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
                putExtra(EXTRA_ID_PERMISSAO, idPermissao)
                putExtra(EXTRA_UID_SOLICITANTE, uidSolicitante)
                putExtra(EXTRA_NOME_SOLICITANTE, nomeSolicitante)
                putExtra(EXTRA_TELEFONE_SOLICITANTE, telefoneSolicitante)
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.d(TAG, "abrirMainActivity: falha ao iniciar Activity: ${e.message}")
        }
    }

    private fun adquirirWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "SecurityCheckApp::SolicitacaoMonitoramentoWakeLock",
            ).apply {
                setReferenceCounted(false)
                acquire(30_000L)
            }
        } catch (e: Exception) {
            Log.d(TAG, "adquirirWakeLock: falha: ${e.message}")
            wakeLock = null
        }
    }

    private fun liberarWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        } finally {
            wakeLock = null
        }
    }

    private fun iniciarEmForeground() {
        val canalId = "solicitacao_monitoramento_wake_channel"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(canalId) == null) {
                val canal = NotificationChannel(
                    canalId,
                    "Solicitação de localização (acordar tela)",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description = "Mantém o Service que acorda a tela para solicitações de localização recebidas."
                    setShowBadge(false)
                }
                manager.createNotificationChannel(canal)
            }
        }

        val notificacao = NotificationCompat.Builder(this, canalId)
            .setContentTitle("Solicitação de localização")
            .setContentText("Abrindo...")
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
        private const val NOTIFICATION_ID = 7713

        const val EXTRA_ID_PERMISSAO = "extra_id_permissao_monitoramento"
        const val EXTRA_UID_SOLICITANTE = "extra_uid_solicitante_monitoramento"
        const val EXTRA_NOME_SOLICITANTE = "extra_nome_solicitante_monitoramento"
        const val EXTRA_TELEFONE_SOLICITANTE = "extra_telefone_solicitante_monitoramento"

        fun iniciar(
            context: Context,
            idPermissao: String,
            uidSolicitante: String,
            nomeSolicitante: String,
            telefoneSolicitante: String,
        ) {
            val intent = Intent(context, SolicitacaoMonitoramentoWakeService::class.java).apply {
                putExtra(EXTRA_ID_PERMISSAO, idPermissao)
                putExtra(EXTRA_UID_SOLICITANTE, uidSolicitante)
                putExtra(EXTRA_NOME_SOLICITANTE, nomeSolicitante)
                putExtra(EXTRA_TELEFONE_SOLICITANTE, telefoneSolicitante)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
