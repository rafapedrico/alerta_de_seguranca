package com.example.security_check_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

private const val TAG = "SosDispatchService"

/**
 * Foreground Service (`foregroundServiceType="dataSync"`) que garante que
 * a JANELA CRÍTICA do disparo de SOS — envio do SMS nativo + upload da
 * foto ao Firebase Storage + gravação do alerta no Firestore (ver
 * [SosDisparoService] no lado Dart) — sobreviva à destruição da
 * `Activity`/engine principal, em vez de depender do ciclo de vida da UI
 * que a iniciou.
 *
 * MOTIVAÇÃO (equivalente ao pedido de não depender de `ViewModelScope`
 * em apps Android nativos): este app é Flutter, então não existe
 * `ViewModelScope`/`Activity.lifecycleScope` no sentido Kotlin — mas o
 * risco real é análogo: o disparo de SOS é hoje feito por `Future`s Dart
 * (`SosDisparoService.executarP1LocalizacaoImediata`/
 * `dispararFotoCapturada`) que rodam no MESMO processo/engine da UI. Se o
 * sistema operacional matar o PROCESSO do app (memória baixa, usuário
 * força-parou o app, Doze agressivo de fabricante) enquanto esse SMS/
 * upload ainda está em voo, o Dart isolate inteiro morre e o trabalho é
 * perdido — não há como um `Future` Dart "sobreviver" à morte do
 * processo, só um componente 100% nativo (Service em foreground) pode
 * pedir ao Android para NÃO matar o processo durante essa janela.
 *
 * ESTRATÉGIA (mesmo padrão já validado em [VolumeSosService]/
 * [RotinaAlarmWakeService] neste projeto): o lado Dart chama [iniciar]
 * (via [SosDispatchPlugin], MethodChannel) IMEDIATAMENTE ANTES de
 * iniciar o SMS/upload, e [parar] assim que ambos concluírem (sucesso OU
 * falha — o que importa é que o trabalho TERMINOU de executar, não que
 * tenha tido sucesso). Entre esses dois pontos:
 * 1. `startForeground()` com uma notificação de baixa prioridade,
 *    sinalizando ao Android que este processo está fazendo trabalho
 *    importante em primeiro plano — o sistema evita matá-lo.
 * 2. Um [PowerManager.PARTIAL_WAKE_LOCK] mantém a CPU ativa mesmo se a
 *    tela apagar/bloquear no meio do envio.
 *
 * TETO DE SEGURANÇA: o WakeLock tem timeout de 60s (bem acima do pior
 * caso realista de SMS+upload) e este Service se auto-encerra depois
 * disso mesmo sem receber [parar] — nunca fica preso drenando bateria
 * indefinidamente caso o sinal de conclusão do lado Dart falhe por
 * qualquer motivo (ex: exceção não tratada antes do `finally`).
 */
class SosDispatchService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val autoEncerrar = Runnable {
        Log.d(TAG, "Teto de segurança de 60s atingido — encerrando o Service mesmo sem sinal de conclusão do lado Dart.")
        parar(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand")
        iniciarEmForeground()
        adquirirWakeLock()

        handler.removeCallbacks(autoEncerrar)
        handler.postDelayed(autoEncerrar, 60_000L)

        // START_NOT_STICKY: se o Android matar este processo mesmo assim
        // (pior caso — memória crítica), não faz sentido recriá-lo sozinho
        // sem o contexto Dart que sabia o que estava sendo enviado; o
        // próprio SMS nativo já terá sido despachado de forma síncrona (ou
        // não) antes disso, e a fila de retry local (ver
        // `RetryUploadService` no lado Dart) cobre o upload pendente no
        // próximo cold start.
        return START_NOT_STICKY
    }

    private fun adquirirWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "SecurityCheckApp::SosDispatchWakeLock",
            ).apply {
                setReferenceCounted(false)
                acquire(60_000L)
            }
            Log.d(TAG, "WakeLock adquirido (timeout 60s)")
        } catch (e: Exception) {
            Log.d(TAG, "Falha ao adquirir WakeLock: ${e.message}")
            wakeLock = null
        }
    }

    private fun liberarWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
                Log.d(TAG, "WakeLock liberado")
            }
        } catch (e: Exception) {
            Log.d(TAG, "Falha ao liberar WakeLock: ${e.message}")
        } finally {
            wakeLock = null
        }
    }

    private fun iniciarEmForeground() {
        val canalId = "sos_dispatch_channel"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(canalId) == null) {
                val canal = NotificationChannel(
                    canalId,
                    "Envio de alerta de emergência",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description = "Mantém o envio do SMS/upload do alerta de SOS ativo até concluir."
                    setShowBadge(false)
                }
                manager.createNotificationChannel(canal)
            }
        }

        val notificacao = NotificationCompat.Builder(this, canalId)
            .setContentTitle("Enviando alerta de emergência")
            .setContentText("Concluindo o envio do SOS...")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()

        // FOREGROUND_SERVICE_TYPE_DATA_SYNC: categoria correta do Android
        // 14+ para "enviar/sincronizar dados pela rede" — SMS nativo +
        // upload ao Firebase Storage/Firestore é exatamente esse tipo de
        // trabalho (diferente de `location`/`camera`, que já foram usados
        // ANTES deste Service iniciar: a foto já foi capturada e a
        // localização já foi lida pela UI — este Service só cuida do
        // ENVIO em si).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notificacao,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notificacao)
        }
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        handler.removeCallbacks(autoEncerrar)
        liberarWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val NOTIFICATION_ID = 7713

        /**
         * Inicia o Service em foreground — chamado pelo lado Dart (via
         * [SosDispatchPlugin], MethodChannel "iniciar") IMEDIATAMENTE
         * ANTES de despachar o SMS/upload do SOS. Idempotente: chamar de
         * novo enquanto já está rodando apenas reinicia o teto de
         * segurança de 60s (`onStartCommand` é reexecutado).
         */
        fun iniciar(context: Context) {
            try {
                val intent = Intent(context, SosDispatchService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.d(TAG, "Falha ao iniciar: ${e.message}")
            }
        }

        /**
         * Encerra o Service — chamado pelo lado Dart assim que o
         * SMS/upload do SOS TERMINAR (sucesso ou falha; ver
         * `SosDisparoService._comServicoPersistente`), sempre num bloco
         * `finally`. Seguro mesmo se o Service não estiver rodando.
         */
        fun parar(context: Context) {
            try {
                context.stopService(Intent(context, SosDispatchService::class.java))
            } catch (e: Exception) {
                Log.d(TAG, "Falha ao parar: ${e.message}")
            }
        }
    }
}
