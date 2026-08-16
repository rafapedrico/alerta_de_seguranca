package com.example.security_check_app

import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

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
 *
 * SEGUNDA VIA DE DETECÇÃO (correção 2026-08-15, bug real reportado em
 * teste físico: botão físico funcionava no Moto G7 Play — Android 9 —
 * mas não disparava nada no Motorola Razr 40 Ultra — Android 16):
 * o [ContentObserver] acima SÓ enxerga incrementos no volume do
 * STREAM_MUSIC (ver [processarMudancaDeVolume]) — mas o framework do
 * Android decide, em tempo real e por conta própria (dentro de
 * `PhoneWindowManager`/`AudioService`, fora do nosso controle), PARA
 * QUAL stream de áudio um toque no botão físico de Volume+ realmente é
 * roteado quando nada está tocando e a tela está apagada/bloqueada —
 * historicamente STREAM_MUSIC em aparelhos mais antigos, mas
 * STREAM_RING/STREAM_NOTIFICATION em versões mais novas do Android
 * (comportamento que pode variar por versão de SO E por fabricante/
 * skin, sem nenhuma documentação pública estável — só constatável na
 * prática, aparelho por aparelho). Registrar TAMBÉM um
 * [BroadcastReceiver] para `AudioManager.VOLUME_CHANGED_ACTION` (ver
 * [registrarReceiverDeVolume]) cobre esse caso: esse broadcast do
 * sistema informa EXATAMENTE qual stream mudou e qual o valor
 * anterior/novo, então conseguimos detectar o incremento não importa
 * para qual stream o Android tenha decidido rotear o toque físico,
 * sem depender de adivinhar isso estaticamente. Para NUNCA contar o
 * mesmo toque físico duas vezes (o `ContentObserver` acima também
 * reagiria a uma mudança em STREAM_MUSIC), o broadcast só é usado para
 * os streams QUE O CONTENTOBSERVER NÃO JÁ COBRE — ver
 * [STREAMS_MONITORADOS_VIA_BROADCAST].
 */
class VolumeSosService : Service() {

    private lateinit var audioManager: AudioManager
    private lateinit var contentObserver: ContentObserver
    private var receiverDeVolume: BroadcastReceiver? = null
    private val handler = Handler(Looper.getMainLooper())

    /** Última leitura conhecida de cada stream monitorado via broadcast
     * (ver [STREAMS_MONITORADOS_VIA_BROADCAST]) — usada só como
     * diagnóstico em log, já que `AudioManager.VOLUME_CHANGED_ACTION`
     * já entrega o valor anterior/novo diretamente nos extras do
     * Intent, sem precisar rastrear estado manualmente como o
     * `ContentObserver` (que só recebe "algo mudou", sem detalhes). */
    private val ultimoValorPorStream = HashMap<Int, Int>()

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

    /** Timestamp do último disparo de SOS efetivado. */
    private var ultimoDisparoMs: Long = 0L

    /** Período mínimo (ms) entre dois disparos de SOS consecutivos. Evita
     * que uma única sequência prolongada de cliques em Volume+ (o
     * usuário continua clicando além do mínimo de 3 incrementos) dispare
     * vários fluxos de SOS sobrepostos — o que gerava múltiplos SMS e uma
     * corrida entre solicitações concorrentes de permissão de câmera. */
    private val cooldownDisparoMs = 10_000L

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate — iniciando monitoramento do botão físico de SOS.")
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        volumeAnterior = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        STREAMS_MONITORADOS_VIA_BROADCAST.forEach {
            ultimoValorPorStream[it] = audioManager.getStreamVolume(it)
        }

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

        registrarReceiverDeVolume()
    }

    /**
     * Registra um [BroadcastReceiver] dinâmico para
     * `AudioManager.VOLUME_CHANGED_ACTION` — ver documentação completa
     * na classe ("SEGUNDA VIA DE DETECÇÃO") sobre por que isto é
     * necessário além do [ContentObserver] já existente. Usa a
     * STRING LITERAL da ação/extras (em vez das constantes de
     * [AudioManager]) de propósito: esses campos são marcados `@hide`
     * no SDK público do Android — não compilam se referenciados
     * diretamente — mas o broadcast em si é enviado normalmente a
     * qualquer app (é uma ação de sistema protegida, listada em
     * `protected-broadcast` no próprio AOSP), técnica amplamente usada
     * por apps de terceiros para este exato cenário (botão físico como
     * obturador/atalho).
     *
     * [ContextCompat.registerReceiver] com `RECEIVER_NOT_EXPORTED` é
     * exigido a partir do Android 13 (API 33) para registro dinâmico de
     * receivers — a extensão do AndroidX resolve isso automaticamente
     * em versões anteriores (vira um registro comum, sem o parâmetro).
     * Protegido por try/catch: uma falha aqui (im provável, mas nunca
     * derruba o Service) apenas significa que o app continua dependendo
     * só do ContentObserver original, exatamente como antes desta
     * correção.
     */
    private fun registrarReceiverDeVolume() {
        try {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    processarBroadcastDeVolume(intent)
                }
            }
            ContextCompat.registerReceiver(
                this,
                receiver,
                IntentFilter(ACAO_VOLUME_ALTERADO),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            receiverDeVolume = receiver
            Log.d(TAG, "BroadcastReceiver de volume registrado com sucesso.")
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao registrar BroadcastReceiver de volume — " +
                "monitoramento seguirá só via ContentObserver.", e)
        }
    }

    /**
     * Chamado a cada `AudioManager.VOLUME_CHANGED_ACTION` recebido —
     * extrai qual stream mudou e seu novo/antigo valor diretamente dos
     * extras do Intent (mais preciso que o ContentObserver, que só
     * avisa "algo mudou" sem dizer o quê). Só reage aos streams em
     * [STREAMS_MONITORADOS_VIA_BROADCAST] (NUNCA STREAM_MUSIC — esse já
     * é 100% coberto pelo ContentObserver em [processarMudancaDeVolume];
     * reagir aqui também duplicaria a contagem de um único toque físico
     * real).
     */
    private fun processarBroadcastDeVolume(intent: Intent?) {
        if (intent == null || intent.action != ACAO_VOLUME_ALTERADO) return

        val streamType = intent.getIntExtra(EXTRA_TIPO_STREAM, -1)
        if (streamType !in STREAMS_MONITORADOS_VIA_BROADCAST) return

        val valorNovo = intent.getIntExtra(EXTRA_VALOR_STREAM, -1)
        val valorAnteriorExtra = intent.getIntExtra(EXTRA_VALOR_STREAM_ANTERIOR, -1)
        // Prefere o valor anterior informado pelo próprio broadcast (mais
        // confiável); só cai para o último valor rastreado manualmente se,
        // por algum motivo, o extra não vier preenchido.
        val valorAnterior = if (valorAnteriorExtra >= 0) {
            valorAnteriorExtra
        } else {
            ultimoValorPorStream[streamType] ?: valorNovo
        }
        ultimoValorPorStream[streamType] = valorNovo

        Log.d(TAG, "VOLUME_CHANGED_ACTION: stream=$streamType anterior=$valorAnterior novo=$valorNovo")

        if (valorNovo > valorAnterior) {
            registrarIncrementoDetectado("broadcast(stream=$streamType)")
        }
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
     * Compara o volume atual do STREAM_MUSIC com o valor anterior — se
     * subiu, delega a [registrarIncrementoDetectado]. Se não subiu
     * (desceu ou permaneceu igual, ex: mudança de outro stream), reseta
     * a contagem, pois o gatilho exige incrementos consecutivos de
     * VOLUME+.
     */
    private fun processarMudancaDeVolume() {
        val volumeAtual = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)

        if (volumeAtual > volumeAnterior) {
            Log.d(TAG, "ContentObserver: STREAM_MUSIC subiu de $volumeAnterior para $volumeAtual")
            registrarIncrementoDetectado("contentObserver(STREAM_MUSIC)")
        } else if (volumeAtual < volumeAnterior) {
            // Volume desceu: reseta a contagem (o gatilho exige apenas
            // incrementos consecutivos de Volume+).
            contagemIncrementos = 0
        }
        // Se volumeAtual == volumeAnterior (mudança de outro stream/
        // configuração não relacionada), não altera a contagem.

        volumeAnterior = volumeAtual
    }

    /**
     * Ponto ÚNICO de contagem de incrementos — chamado tanto por
     * [processarMudancaDeVolume] (ContentObserver, STREAM_MUSIC) quanto
     * por [processarBroadcastDeVolume] (BroadcastReceiver, demais
     * streams — ver [STREAMS_MONITORADOS_VIA_BROADCAST]), cada um
     * cobrindo um stream DIFERENTE, então nunca há dupla contagem do
     * mesmo toque físico real. [origem] é só para diagnóstico em log.
     */
    private fun registrarIncrementoDetectado(origem: String) {
        val agora = System.currentTimeMillis()

        if (contagemIncrementos == 0 ||
            (agora - timestampPrimeiroIncremento) > janelaDeteccaoMs
        ) {
            // Início de uma nova possível sequência de gatilho.
            contagemIncrementos = 1
            timestampPrimeiroIncremento = agora
        } else {
            contagemIncrementos++
        }

        Log.d(TAG, "Incremento #$contagemIncrementos detectado via $origem.")

        if (contagemIncrementos >= incrementosNecessarios) {
            contagemIncrementos = 0
            if (agora - ultimoDisparoMs >= cooldownDisparoMs) {
                ultimoDisparoMs = agora
                Log.i(TAG, "Gatilho de SOS físico confirmado — disparando.")
                VolumeSosEventBridge.notificarSosDisparado()

                // CORREÇÃO (bug real observado em teste — "câmera reabre"
                // ao deslizar a tela vermelha para cima): com o app
                // aberto (foreground) OU na tela de login, o engine
                // Flutter da MainActivity já está vivo e o EventChannel
                // acima já entrega o gatilho a ele, que empurra a
                // CameraCapturaScreen por cima da tela atual. Chamar
                // [forcarAberturaLockscreenCameraActivity] TAMBÉM nesse
                // caso empilhava uma SEGUNDA Activity/engine de câmera
                // por cima da primeira — ao deslizar para cima, só a de
                // cima fechava/bloqueava, revelando a outra por baixo (
                // parecendo, para o usuário, que a câmera "reabria" em
                // vez do Android bloquear de verdade). Só continuamos
                // abrindo a Activity nativa separada quando o aparelho
                // está DE FATO com a tela bloqueada (Keyguard ativo) —
                // único cenário em que a MainActivity normal não pode
                // aparecer por cima do bloqueio, exigindo a Activity
                // dedicada com `setShowWhenLocked(true)` — ou quando não
                // há nenhum engine Dart vivo para receber o EventChannel
                // (app totalmente fechado).
                if (aparelhoBloqueadoOuSemEngineDartVivo()) {
                    forcarAberturaLockscreenCameraActivity()
                }
            }
        }
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
     *
     * CORREÇÃO DEFENSIVA (2026-08-15): `startForeground()` agora está
     * protegido por try/catch e logado — antes, uma falha aqui (ex:
     * `ForegroundServiceStartNotAllowedException`/
     * `MissingForegroundServiceTypeException`, restrições reforçadas a
     * cada nova versão do Android desde a 12) derrubava o Service
     * inteiro SEM nenhum rastro em log, silenciando também o
     * ContentObserver/BroadcastReceiver registrados em [onCreate] —
     * sintoma indistinguível de "o botão físico simplesmente não faz
     * nada" no aparelho. Não é um fix garantido por si só (se
     * `startForeground()` falhar de verdade, o Android ainda pode matar
     * o Service pouco depois por não ter virado foreground a tempo),
     * mas garante que, se isso estiver acontecendo, apareça no logcat
     * em vez de falhar em silêncio.
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

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notificacao,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notificacao)
            }
            Log.d(TAG, "startForeground() concluído com sucesso (SDK ${Build.VERSION.SDK_INT}).")
        } catch (e: Exception) {
            Log.e(TAG, "FALHA em startForeground() — o monitoramento pode não " +
                "sobreviver em segundo plano neste aparelho/versão do Android.", e)
        }
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy — encerrando monitoramento do botão físico de SOS.")
        try {
            contentResolver.unregisterContentObserver(contentObserver)
        } catch (_: Exception) {
        }
        try {
            receiverDeVolume?.let { unregisterReceiver(it) }
        } catch (_: Exception) {
        }
        receiverDeVolume = null
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
     * `true` quando a Activity nativa dedicada ([LockscreenCameraActivity])
     * ainda é necessária: ou o aparelho está com a tela REALMENTE
     * bloqueada (Keyguard ativo — a MainActivity comum não tem
     * `setShowWhenLocked`, então não conseguiria aparecer por cima do
     * bloqueio), ou não há nenhum engine Dart vivo para receber o evento
     * pelo EventChannel (app totalmente fechado). Nos demais casos (app em
     * foreground ou na tela de login, com a tela desbloqueada), o próprio
     * [VolumeSosEventBridge.eventSink] já entrega o gatilho ao engine já
     * rodando — ver chamador para o contexto completo do bug corrigido.
     */
    private fun aparelhoBloqueadoOuSemEngineDartVivo(): Boolean {
        if (VolumeSosEventBridge.eventSink == null) return true
        return try {
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            keyguardManager?.isKeyguardLocked ?: false
        } catch (_: Exception) {
            // Na dúvida, prefere abrir a Activity dedicada (comportamento
            // histórico) a arriscar não mostrar a câmera de jeito nenhum.
            true
        }
    }

    /**
     * Traz [LockscreenCameraActivity] à frente mesmo no cenário mais
     * agressivo em que o app foi completamente fechado pelo
     * usuário/sistema e apenas este Foreground Service permanece vivo —
     * SEM depender do EventChannel/engine Flutter estar "quente" com um
     * listener Dart ativo.
     *
     * CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-15, via
     * logcat no Motorola Razr 40 Ultra — Android 16): a versão anterior
     * chamava `startActivity()` diretamente a partir deste Service — o
     * Logcat mostrou, na hora exata do toque físico, o Android
     * REJEITANDO essa chamada:
     * ```
     * ActivityTaskManager: Background activity launch blocked!
     *   goo.gle/android-bal ... callingUidProcState: FOREGROUND_SERVICE;
     *   callingUidHasVisibleActivity: false; resultIfPiCreatorAllowsBal:
     *   BAL_BLOCK ... result code=102
     * ```
     * Ou seja: o botão físico ERA detectado e o disparo chegava até
     * aqui, mas a câmera nunca abria — o Android 16 reforçou a restrição
     * de "Background Activity Launch" (BAL) a ponto de nem um Foreground
     * Service legítimo (`specialUse`) conseguir mais abrir uma Activity
     * do nada, sem alguma exceção reconhecida pelo sistema. Isso NÃO
     * acontecia no Moto G7 Play (Android 9), de onde vem a
     * discrepância real reportada entre os dois aparelhos.
     *
     * FIX: uma notificação com `setFullScreenIntent(..., true)` é a
     * exceção OFICIAL do Android a essa restrição (documentada desde o
     * Android 10, e ainda respeitada no 16) — quando o aparelho está
     * bloqueado, o próprio sistema abre a Activity do `PendingIntent`
     * automaticamente por cima do Keyguard, sem passar pelo BAL. É o
     * MESMO mecanismo já usado com sucesso por
     * `NotificacaoService.exibirNotificacaoAlertaRecebido` (Dart) para
     * acordar a tela ao receber um alerta de outro usuário — e exige a
     * MESMA permissão `USE_FULL_SCREEN_INTENT`, já declarada no
     * manifest e concedida por padrão.
     *
     * Protegido por try/catch: uma falha aqui NUNCA derruba o Service
     * nem impede o fluxo já em andamento via [VolumeSosEventBridge]
     * (cenário de app em primeiro plano).
     */
    private fun forcarAberturaLockscreenCameraActivity() {
        try {
            criarCanalFullScreenSeNecessario()

            val intentAbrir = Intent(this, LockscreenCameraActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
            }
            val flagsImutavel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
            val pendingAbrir = PendingIntent.getActivity(
                this,
                0,
                intentAbrir,
                PendingIntent.FLAG_UPDATE_CURRENT or flagsImutavel,
            )

            val notificacao = NotificationCompat.Builder(this, CANAL_FULLSCREEN_ID)
                .setContentTitle(getString(R.string.alerta_sos_fisico_titulo))
                .setContentText(getString(R.string.alerta_sos_fisico_corpo))
                .setSmallIcon(applicationInfo.icon)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setAutoCancel(true)
                .setOngoing(false)
                .setContentIntent(pendingAbrir)
                .setFullScreenIntent(pendingAbrir, true)
                .build()

            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID_FULLSCREEN, notificacao)
            Log.d(TAG, "Notificação full-screen-intent postada (bypass de BAL) para abrir a câmera.")

            // Em aparelhos/estados onde o BAL NÃO bloqueia (ex: versões
            // mais antigas do Android, como o Moto G7 Play), tenta
            // TAMBÉM o caminho direto — mais rápido quando funciona, e
            // inofensivo quando falha (a notificação full-screen acima
            // já cobre o caso). Nunca deixa uma exceção daqui suprimir o
            // log de sucesso da notificação já postada.
            try {
                startActivity(intentAbrir)
            } catch (e: Exception) {
                Log.d(TAG, "startActivity() direto não permitido (esperado em Android " +
                    "12+/BAL) — a notificação full-screen-intent cobre a abertura.", e)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao forçar abertura da câmera na lockscreen.", e)
            // Silenciosamente ignorado além do log: o disparo do
            // SMS/alerta via VolumeSosEventBridge (app em primeiro
            // plano) já ocorreu logo acima e não deve ser afetado.
        }
    }

    /** Canal dedicado à notificação full-screen-intent de
     * [forcarAberturaLockscreenCameraActivity] — `IMPORTANCE_HIGH` é
     * exigido pelo Android para que `setFullScreenIntent` realmente
     * acorde/abra a Activity automaticamente com o aparelho bloqueado
     * (canais de importância menor só mostram a notificação normal). */
    private fun criarCanalFullScreenSeNecessario() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CANAL_FULLSCREEN_ID) != null) return

        val canal = NotificationChannel(
            CANAL_FULLSCREEN_ID,
            "Abertura de câmera do SOS físico",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Usado internamente para abrir a câmera sobre a tela bloqueada ao acionar o botão físico de SOS."
            setShowBadge(false)
        }
        manager.createNotificationChannel(canal)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val NOTIFICATION_ID = 7711

        /** Id/canal da notificação full-screen-intent de
         * [forcarAberturaLockscreenCameraActivity] — diferente de
         * [NOTIFICATION_ID] (a notificação PERSISTENTE deste Foreground
         * Service): esta é disparada uma única vez por gatilho físico e
         * some sozinha (`setAutoCancel(true)`) assim que a Activity abre. */
        private const val NOTIFICATION_ID_FULLSCREEN = 7712
        private const val CANAL_FULLSCREEN_ID = "volume_sos_fullscreen_channel"

        /** Tag única para todo log deste Service — filtrar por ela no
         * logcat (`adb logcat -s VolumeSosService`) mostra o
         * diagnóstico completo do gatilho físico: registro dos dois
         * detectores em [onCreate], cada incremento contado por
         * [registrarIncrementoDetectado] (com a origem — ContentObserver
         * ou BroadcastReceiver, e de qual stream), e o disparo final. */
        private const val TAG = "VolumeSosService"

        /** Ação do broadcast do sistema disparado a cada mudança de
         * volume de QUALQUER stream — ver documentação completa em
         * [registrarReceiverDeVolume] sobre por que é a string literal
         * (não a constante de [AudioManager], marcada `@hide`). */
        private const val ACAO_VOLUME_ALTERADO = "android.media.VOLUME_CHANGED_ACTION"
        private const val EXTRA_TIPO_STREAM = "android.media.EXTRA_VOLUME_STREAM_TYPE"
        private const val EXTRA_VALOR_STREAM = "android.media.EXTRA_VOLUME_STREAM_VALUE"
        private const val EXTRA_VALOR_STREAM_ANTERIOR = "android.media.EXTRA_PREV_VOLUME_STREAM_VALUE"

        /**
         * Streams observados via [processarBroadcastDeVolume] — NUNCA
         * inclui `AudioManager.STREAM_MUSIC`, que já é 100% coberto
         * pelo [ContentObserver] em [processarMudancaDeVolume] (ver
         * documentação da classe, "SEGUNDA VIA DE DETECÇÃO", sobre por
         * que isso evita contar o mesmo toque físico duas vezes).
         * STREAM_RING é o principal suspeito real (Android roteia o
         * botão físico para ele, em vez de STREAM_MUSIC, quando nada
         * está tocando e a tela está apagada/bloqueada — comportamento
         * que pode variar por versão do Android/fabricante);
         * STREAM_NOTIFICATION incluído pelo mesmo motivo, em aparelhos
         * onde ring e notificação são streams separados.
         */
        private val STREAMS_MONITORADOS_VIA_BROADCAST = setOf(
            AudioManager.STREAM_RING,
            AudioManager.STREAM_NOTIFICATION,
        )

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
