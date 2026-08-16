package com.example.security_check_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Modo "Despertador de Emergência" (reespecificação do usuário, 2026-08-15):
 * Foreground Service que toca um alarme sonoro em LOOP contínuo, no volume
 * MÁXIMO do canal `STREAM_ALARM` do Android — o mesmo canal de áudio usado
 * por despertadores/alarmes do sistema, que NUNCA é silenciado pelo modo
 * Silencioso/Vibrar do aparelho (diferente de `STREAM_NOTIFICATION`,
 * facilmente ignorado) — quando ESTE aparelho recebe o alerta crítico de
 * OUTRO usuário via [FcmService]/[NotificacaoService.exibirNotificacaoAlertaRecebido].
 *
 * NÃO substitui a notificação rica (foto/mapa/texto) já exibida pelo
 * `flutter_local_notifications` (ver [NotificacaoService]) — é uma camada
 * SONORA adicional, iniciada/parada via [AlertaRecebidoAlarmPlugin]
 * (MethodChannel chamado do lado Dart, ver `notificacao_service.dart`).
 *
 * LIMITAÇÃO CONHECIDA: como este é um `FlutterPlugin` customizado (não um
 * pacote do pub.dev), ele só está registrado nos engines Flutter que o app
 * cria via `MainActivity.configureFlutterEngine` — NÃO no engine headless
 * separado que o `firebase_messaging` cria para processar mensagens em
 * segundo plano com o app TOTALMENTE fechado (mesma limitação documentada
 * em `SmsSender.kt` para o `android_alarm_manager_plus`). Nesse cenário
 * mais extremo (app 100% fechado), a notificação de tela cheia com som/
 * vibração padrão do canal Android ainda funciona normalmente (já usa
 * `audioAttributesUsage: AudioAttributesUsage.alarm`, ver
 * `NotificacaoService.inicializar`) — só o loop contínuo em volume máximo
 * desta service específica não chega a iniciar nesse caso extremo.
 *
 * DESARME (item 4 do pedido): a PRÓPRIA notificação exigida pelo Android
 * para este Foreground Service tem `setDeleteIntent` (arrastar para
 * descartar) e uma ação "Silenciar" (toque) apontando para
 * [ACTION_PARAR] — ambos chamam [pararSomEVolume] imediatamente. O lado
 * Dart também chama [parar] explicitamente ao abrir `AlertaRecebidoScreen`
 * (toque na notificação PRINCIPAL/ação/card) e ao tocar no link do mapa.
 *
 * SEGURANÇA CONTRA TOQUE INFINITO: [_TEMPO_MAXIMO_TOCANDO] encerra o
 * alarme sozinho após 5 minutos (reespecificado pelo usuário, 2026-08-15;
 * era 3 minutos), mesmo sem nenhuma ação do usuário — rede
 * de segurança para o caso (sem hook nativo de "notificação descartada"
 * exposto pelo `flutter_local_notifications` da notificação PRINCIPAL)
 * de o usuário arrastar aquela notificação para fora sem tocar em nada
 * desta aqui.
 */
class AlertaRecebidoAlarmService : Service() {

    private var mediaPlayer: MediaPlayer? = null
    private var volumeOriginalAlarme: Int? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val pararPorTimeout = Runnable {
        Log.i(TAG, "Timeout de segurança (${_TEMPO_MAXIMO_TOCANDO / 1000}s) atingido — parando o alarme sozinho.")
        pararSomEVolume()
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PARAR) {
            // BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-15, via
            // logcat): todo Service iniciado via `startForegroundService()`
            // (ver [parar], chamado inclusive quando este Service JÁ NÃO
            // ESTÁ RODANDO — ex: `MainActivity` abrindo por uma
            // notificação "despertador" antiga já resolvida — nesse
            // caso o Android cria uma instância NOVA só para processar
            // este `ACTION_PARAR`) é OBRIGADO pelo Android 8+ a chamar
            // `startForeground()` dentro de 5 segundos, mesmo que a
            // intenção real seja parar imediatamente — sem isso, o
            // sistema lança `ForegroundServiceDidNotStartInTimeException`
            // e MATA O PROCESSO INTEIRO. Sintoma real observado: "Input
            // dispatching timed out... Waited 5001ms" seguido de
            // `Process ... has died`, sempre que este branch rodava sem
            // nunca chamar `startForeground()`. `iniciarNotificacaoForeground()`
            // satisfaz o contrato imediatamente; `pararSomEVolume()`, na
            // sequência, já remove essa mesma notificação quase
            // instantaneamente (`stopForeground(STOP_FOREGROUND_REMOVE)`).
            iniciarNotificacaoForeground()
            pararSomEVolume()
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            iniciarNotificacaoForeground()
            forcarVolumeMaximo()
            iniciarSomEmLoop()
            handler.removeCallbacks(pararPorTimeout)
            handler.postDelayed(pararPorTimeout, _TEMPO_MAXIMO_TOCANDO)
        } catch (e: Exception) {
            Log.e(TAG, "Falha ao iniciar o Despertador de Emergência", e)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(pararPorTimeout)
        pararSomEVolume()
        super.onDestroy()
    }

    /**
     * Notificação PRÓPRIA deste Foreground Service (exigida pelo Android
     * a partir da API 26) — funciona também como a UI de desarme do
     * alarme sonoro (item 4): toque no corpo/ação "Silenciar" ou arrastar
     * para descartar chamam [ACTION_PARAR] de volta nesta mesma Service.
     * `ongoing = false` de propósito: precisa continuar arrastável/
     * descartável pelo usuário (diferente de outras notificações
     * persistentes do app).
     */
    private fun iniciarNotificacaoForeground() {
        criarCanalSeNecessario()

        val intentParar = Intent(this, AlertaRecebidoAlarmService::class.java).apply {
            action = ACTION_PARAR
        }
        val flagsImutavel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
        val pendingParar = PendingIntent.getService(
            this, 0, intentParar, PendingIntent.FLAG_UPDATE_CURRENT or flagsImutavel,
        )

        val intentAbrir = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            // Item 4 do pedido ("clicar... no card da tela" também
            // silencia): tocar no CORPO desta notificação abre o app E
            // silencia o alarme — ver `MainActivity.tratarIntentDeAlertaRecebido`.
            putExtra(EXTRA_PARAR_AO_ABRIR, true)
        }
        val pendingAbrir = PendingIntent.getActivity(
            this, 0, intentAbrir, PendingIntent.FLAG_UPDATE_CURRENT or flagsImutavel,
        )

        val notificacao = NotificationCompat.Builder(this, CANAL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(getString(R.string.alerta_alarme_titulo))
            .setContentText(getString(R.string.alerta_alarme_corpo))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setOngoing(false)
            .setAutoCancel(true)
            .setContentIntent(pendingAbrir)
            .setDeleteIntent(pendingParar)
            .addAction(0, getString(R.string.alerta_alarme_silenciar), pendingParar)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notificacao,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIF_ID, notificacao)
        }
    }

    private fun criarCanalSeNecessario() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CANAL_ID) != null) return

        val canal = NotificationChannel(CANAL_ID, "Despertador de Emergência", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Controle do alarme sonoro tocado quando um contato dispara um alerta de emergência."
            enableVibration(false)
            // O som em si é tocado pelo MediaPlayer em loop (ver
            // [iniciarSomEmLoop]), nunca pelo próprio canal — evita dois
            // sons sobrepostos.
            setSound(null, null)
        }
        manager.createNotificationChannel(canal)
    }

    /**
     * Salva o volume ATUAL do canal `STREAM_ALARM` (para restaurar depois,
     * em [pararSomEVolume] — nunca alterar a preferência de volume do
     * usuário permanentemente) e força o volume MÁXIMO nesse mesmo canal.
     * Requer `MODIFY_AUDIO_SETTINGS` (permissão normal, sem diálogo — ver
     * AndroidManifest.xml).
     */
    private fun forcarVolumeMaximo() {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (volumeOriginalAlarme == null) {
                volumeOriginalAlarme = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
            }
            val volumeMaximo = audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            audioManager.setStreamVolume(AudioManager.STREAM_ALARM, volumeMaximo, 0)
        } catch (e: Exception) {
            Log.e(TAG, "Falha ao forçar volume máximo do STREAM_ALARM", e)
        }
    }

    private fun restaurarVolumeOriginal() {
        try {
            val original = volumeOriginalAlarme ?: return
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.setStreamVolume(AudioManager.STREAM_ALARM, original, 0)
        } catch (e: Exception) {
            Log.e(TAG, "Falha ao restaurar volume original do STREAM_ALARM", e)
        } finally {
            volumeOriginalAlarme = null
        }
    }

    /**
     * Toca, em loop contínuo, o toque de despertador PADRÃO já configurado
     * no aparelho (`RingtoneManager.TYPE_ALARM`) — sem precisar embutir
     * nenhum arquivo de áudio extra no APK. `AudioAttributes.USAGE_ALARM`
     * é o que efetivamente roteia esta reprodução para o canal
     * `STREAM_ALARM` (o mesmo forçado ao máximo em [forcarVolumeMaximo]),
     * furando o modo Silencioso/Vibrar do aparelho.
     */
    private fun iniciarSomEmLoop() {
        pararSomSomente()

        val uriAlarme = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)

        mediaPlayer = MediaPlayer().apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            isLooping = true
            try {
                setDataSource(this@AlertaRecebidoAlarmService, uriAlarme)
                prepare()
                start()
            } catch (e: Exception) {
                Log.e(TAG, "Falha ao preparar/tocar o som do Despertador de Emergência", e)
            }
        }
    }

    private fun pararSomSomente() {
        try {
            mediaPlayer?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (_: Exception) {
        } finally {
            mediaPlayer = null
        }
    }

    /** Ponto ÚNICO de desarme: para o som, restaura o volume e remove a
     * notificação/Foreground Service. Chamado tanto pela própria
     * notificação (toque/descarte, ver [iniciarNotificacaoForeground])
     * quanto pelo lado Dart (ver [AlertaRecebidoAlarmPlugin]). Seguro
     * chamar mesmo se nada estiver tocando (idempotente). */
    private fun pararSomEVolume() {
        pararSomSomente()
        restaurarVolumeOriginal()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val TAG = "AlertaRecebidoAlarme"
        private const val CANAL_ID = "despertador_emergencia_controle"
        private const val NOTIF_ID = 91234
        const val ACTION_PARAR = "com.example.security_check_app.ACTION_PARAR_ALARME_RECEBIDO"

        /** Extra booleano em um Intent de abertura da [MainActivity] —
         * ver [iniciarNotificacaoForeground]/`MainActivity.tratarIntentDeAlertaRecebido`. */
        const val EXTRA_PARAR_AO_ABRIR = "parar_alarme_recebido_ao_abrir"

        /** Rede de segurança contra toque infinito — ver documentação da
         * classe. 5 minutos (reespecificado pelo usuário, 2026-08-15; era
         * 3 minutos): tempo generoso para o usuário perceber e agir, sem
         * tocar indefinidamente caso ele ignore/esqueça o aparelho. MESMO
         * valor de [NotificacaoService._tempoMaximoAlarmeRecebido] (Dart)
         * — os dois tetos precisam ficar sincronizados. */
        private const val _TEMPO_MAXIMO_TOCANDO = 5 * 60 * 1000L

        fun iniciar(context: Context) {
            val intent = Intent(context, AlertaRecebidoAlarmService::class.java)
            ContextCompat.startForegroundService(context, intent)
        }

        fun parar(context: Context) {
            val intent = Intent(context, AlertaRecebidoAlarmService::class.java).apply {
                action = ACTION_PARAR
            }
            ContextCompat.startForegroundService(context, intent)
        }
    }
}
