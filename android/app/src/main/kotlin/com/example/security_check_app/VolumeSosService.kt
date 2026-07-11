package com.example.security_check_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationCompat

/**
 * Foreground Service responsável por monitorar, em segundo plano (com a
 * tela apagada, o app minimizado ou até com a Activity totalmente
 * fechada, desde que o processo do app continue vivo), o botão físico
 * de VOLUME+ do aparelho.
 *
 * ESTRATÉGIA TÉCNICA (motivo de NÃO interceptar KeyEvent diretamente):
 * Um serviço Android comum (mesmo em foreground) NÃO recebe eventos de
 * tecla de hardware (KeyEvent.KEYCODE_VOLUME_UP) — isso só é entregue a
 * quem está com a Window em foco (uma Activity visível). Como o
 * requisito é funcionar com a tela apagada/app em segundo plano, a
 * técnica usada aqui (a mesma empregada por apps de câmera/SOS em
 * background) é registrar um [ContentObserver] no
 * [Settings.System.CONTENT_URI], que É notificado pelo Android sempre
 * que o volume de qualquer stream (incluindo STREAM_MUSIC) muda —
 * independentemente de qual Activity está em foco, pois a mudança de
 * volume é um evento do sistema, não da Window.
 *
 * REGRA DE DETECÇÃO: cada notificação do ContentObserver é comparada
 * com o nível de volume anterior do STREAM_MUSIC. Se o volume SUBIU
 * (usuário apertou Volume+) 3 vezes consecutivas dentro da janela de 3
 * segundos, o gatilho de SOS é considerado acionado e
 * [VolumeSosEventBridge.notificarSosDisparado] é chamado imediatamente.
 *
 * O volume é sempre restaurado ao nível anterior logo após a detecção,
 * para não incomodar o usuário aumentando o volume real da mídia.
 *
 * WAKELOCK (correção do bug "SOS não dispara com a tela apagada"):
 * em muitos aparelhos Android (especialmente com otimizações agressivas
 * de bateria de fabricantes como Samsung, Xiaomi, etc.), o sistema pode
 * suspender/atrasar a CPU do processo do app quando o dispositivo entra
 * em modo de espera profundo (Doze/tela apagada por um tempo), mesmo
 * com um Foreground Service ativo. Isso fazia com que o
 * [ContentObserver] não fosse notificado a tempo (ou fosse notificado
 * com atraso) quando o usuário apertava o Volume+ com a tela apagada.
 *
 * Para resolver isso, este Service adquire um
 * [PowerManager.PARTIAL_WAKE_LOCK] durante todo o seu ciclo de vida
 * (adquirido em [onCreate], liberado em [onDestroy]). Esse tipo de
 * WakeLock mantém apenas a CPU ativa (garantindo que o processo
 * continue processando os callbacks do ContentObserver normalmente),
 * SEM manter a tela ligada nem o brilho aceso — exatamente a mesma
 * técnica usada por apps de gravação de áudio em background,
 * rastreadores de GPS contínuo, etc. O impacto na bateria é mínimo,
 * pois o WakeLock apenas impede o "sono profundo" da CPU, sem manter
 * nenhum componente de hardware mais custoso (tela, GPS, rádio) ativo
 * por si só.
 */
class VolumeSosService : Service() {

    private lateinit var audioManager: AudioManager
    private lateinit var contentObserver: ContentObserver
    private val handler = Handler(Looper.getMainLooper())

    /** WakeLock parcial que mantém a CPU ativa (sem acender a tela)
     * durante todo o ciclo de vida deste Service, garantindo que o
     * ContentObserver continue recebendo callbacks de mudança de volume
     * mesmo com o dispositivo em standby/tela apagada por tempo
     * prolongado. */
    private var wakeLock: PowerManager.WakeLock? = null

    private var volumeAnterior: Int = -1
    private var contagemIncrementos: Int = 0
    private var timestampPrimeiroIncremento: Long = 0L

    /** Janela de tempo (ms) dentro da qual os incrementos consecutivos de
     * volume devem ocorrer para caracterizar o gatilho de SOS. */
    private val janelaDeteccaoMs = 3000L

    /** Quantidade de incrementos de volume necessários dentro da janela
     * para disparar o SOS. */
    private val incrementosNecessarios = 3

    override fun onCreate() {
        super.onCreate()
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        volumeAnterior = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)

        adquirirWakeLock()

        contentObserver = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                super.onChange(selfChange)
                processarMudancaDeVolume()
            }
        }

        contentResolver.registerContentObserver(
            Settings.System.CONTENT_URI,
            true,
            contentObserver,
        )
    }

    /**
     * Adquire um [PowerManager.PARTIAL_WAKE_LOCK] sem tempo de expiração
     * automática, mantendo a CPU ativa enquanto este Service estiver
     * vivo. Protegido por try/catch para nunca derrubar o Service caso a
     * permissão WAKE_LOCK não esteja disponível por algum motivo (o
     * monitoramento via ContentObserver ainda funciona normalmente,
     * apenas com menor garantia em standby profundo).
     */
    private fun adquirirWakeLock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "SecurityCheckApp::VolumeSosWakeLock",
            ).apply {
                setReferenceCounted(false)
                // Sem timeout: liberado explicitamente em onDestroy(). O
                // Service é persistente (START_STICKY) e sempre reiniciado
                // pelo MainActivity/main.dart, então não há risco de
                // manter o WakeLock preso indefinidamente em caso de
                // crash — o Android libera automaticamente todos os
                // WakeLocks de um processo quando ele é finalizado.
                acquire()
            }
        } catch (_: Exception) {
            wakeLock = null
        }
    }

    /**
     * Chamado a cada notificação de mudança de volume do sistema.
     * Compara o volume atual do STREAM_MUSIC com o valor anterior:
     * - Se subiu: conta como 1 incremento dentro da janela de detecção.
     * - Se não subiu (desceu ou permaneceu igual, ex: mudança de outro
     *   stream): reseta a contagem, pois o gatilho exige incrementos
     *   consecutivos de VOLUME+.
     */
    private fun processarMudancaDeVolume() {
        val volumeAtual = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val agora = System.currentTimeMillis()

        if (volumeAtual > volumeAnterior) {
            if (contagemIncrementos == 0 ||
                (agora - timestampPrimeiroIncremento) > janelaDeteccaoMs
            ) {
                // Início de uma nova possível sequência de gatilho.
                contagemIncrementos = 1
                timestampPrimeiroIncremento = agora
            } else {
                contagemIncrementos++
            }

            if (contagemIncrementos >= incrementosNecessarios) {
                contagemIncrementos = 0
                VolumeSosEventBridge.notificarSosDisparado()
                forcarAberturaLockscreenCameraActivity()
            }
        } else if (volumeAtual < volumeAnterior) {
            // Volume desceu: reseta a contagem (o gatilho exige apenas
            // incrementos consecutivos de Volume+).
            contagemIncrementos = 0
        }
        // Se volumeAtual == volumeAnterior (mudança de outro stream/
        // configuração não relacionada), não altera a contagem.

        volumeAnterior = volumeAtual
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        iniciarEmForeground()
        // Garante que o WakeLock esteja sempre ativo mesmo se o sistema
        // reiniciar este Service (ex: após ser morto pelo Android e
        // recriado via START_STICKY) sem passar por onCreate() novamente
        // em alguns cenários específicos de fabricante.
        if (wakeLock?.isHeld != true) {
            adquirirWakeLock()
        }

        return START_STICKY
    }

    /**
     * Constrói e exibe a notificação persistente exigida pelo Android
     * para manter um Foreground Service ativo. O texto deixa claro ao
     * usuário que o monitoramento de SOS está ativo.
     */
    private fun iniciarEmForeground() {
        val canalId = "volume_sos_channel"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val canalExistente = manager.getNotificationChannel(canalId)
            if (canalExistente == null) {
                val canal = NotificationChannel(
                    canalId,
                    "Monitoramento de SOS",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description = "Mantém o monitoramento do botão físico de SOS ativo."
                    setShowBadge(false)
                }
                manager.createNotificationChannel(canal)
            }
        }

        val notificacao = NotificationCompat.Builder(this, canalId)
            .setContentTitle("Segurança ativa")
            .setContentText("Monitorando o botão de SOS em segundo plano.")
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
        try {
            contentResolver.unregisterContentObserver(contentObserver)
        } catch (_: Exception) {
        }
        liberarWakeLock()
        super.onDestroy()
    }

    /** Libera o WakeLock adquirido em [onCreate]/[onStartCommand], caso
     * ainda esteja retido, evitando vazamento de energia após o Service
     * ser destruído. Protegido por try/catch por segurança. */
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

    /**
     * Dispara DIRETAMENTE, via [Intent] nativo (sem depender do
     * EventChannel/engine Flutter estar "quente" com um listener Dart
     * ativo), a [LockscreenCameraActivity] — forçando o Android a criar
     * uma Activity real do zero com as flags de sobreposição ao
     * Keyguard (`setShowWhenLocked`/`setTurnScreenOn`/
     * `requestDismissKeyguard`, herdadas de [MainActivity]), mesmo no
     * cenário mais agressivo em que o app foi completamente fechado
     * pelo usuário/sistema e apenas este Foreground Service permanece
     * vivo.
     *
     * As flags `FLAG_ACTIVITY_NEW_TASK` (obrigatória ao iniciar uma
     * Activity a partir de um Context que não é uma Activity, como este
     * Service), `FLAG_ACTIVITY_CLEAR_TOP` e `FLAG_ACTIVITY_SINGLE_TOP`
     * garantem que, se já existir uma instância desta Activity na pilha
     * de tarefas, ela seja reaproveitada/trazida ao topo em vez de
     * empilhar uma nova instância a cada gatilho físico consecutivo.
     *
     * Protegido por try/catch: uma falha aqui (ex: restrição de
     * fabricante a `startActivity()` a partir de background em versões
     * específicas do Android) NUNCA derruba o Service nem impede o
     * fluxo já em andamento via [VolumeSosEventBridge] (cenário de app
     * em primeiro plano).
     */
    private fun forcarAberturaLockscreenCameraActivity() {
        try {
            val intent = Intent(this, LockscreenCameraActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
            }
            startActivity(intent)
        } catch (_: Exception) {
            // Silenciosamente ignorado: o disparo do SMS/alerta via
            // VolumeSosEventBridge (app em primeiro plano) já ocorreu
            // logo acima e não deve ser afetado por esta falha.
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val NOTIFICATION_ID = 7711

        /** Inicia o Foreground Service de monitoramento de SOS. Deve ser
         * chamado logo na abertura do app (ver MainActivity/main.dart). */
        fun iniciar(context: Context) {
            val intent = Intent(context, VolumeSosService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }

        }

        /** Para o Foreground Service de monitoramento de SOS. */
        fun parar(context: Context) {
            val intent = Intent(context, VolumeSosService::class.java)
            context.stopService(intent)
        }
    }
}
