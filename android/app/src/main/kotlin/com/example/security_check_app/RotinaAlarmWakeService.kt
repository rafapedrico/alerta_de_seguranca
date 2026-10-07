package com.example.security_check_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

private const val TAG = "RotinaAlarmWakeService"

/**
 * Foreground Service que "acorda" o aparelho no horário do Cronômetro
 * Regressivo (aba Segurança) e dos despertadores (aba Família), mesmo em
 * Doze, com o app fechado ou a tela bloqueada.
 *
 * Iniciado DIRETAMENTE pelo `AlarmManager` (ver [RotinaAlarmNativeReceiver],
 * caminho 100% nativo, sem depender de engine Flutter). Para cada ocorrência
 * (chave `tipo:id:ciclo`, ver [RotinaAlarmFluxoState]) ele:
 *
 * 1. Marca a ocorrência como em andamento, com o prazo (horário +
 *    tolerância), e segura um `PARTIAL_WAKE_LOCK` até o maior prazo em
 *    aberto (+ margem) — a tolerância inteira, não um teto fixo.
 * 2. Toca UM único som — o escolhido em Configurações (`res/raw/som_N`) — em
 *    loop até a ocorrência ser resolvida ou o prazo acabar:
 *    - despertador: uso de ALARME (toca mesmo no modo silencioso);
 *    - cronômetro: respeita o modo do aparelho (silencioso: nada; vibrar:
 *      só vibra; normal: toca no volume atual do toque, sem forçar o máximo).
 *    O canal da notificação é mudo — nenhum segundo som paralelo.
 * 3. Posta a notificação de tela cheia da ocorrência (sobre a tela
 *    bloqueada). No despertador ela tem o botão "Desativar despertador", que
 *    abre a tela direto no teclado de PIN.
 *
 * A ocorrência só deixa de estar em andamento quando o lado Dart a resolve
 * (PIN correto ou alerta enviado — `pararServicoForeground` com a chave) ou,
 * como rede de segurança, alguns minutos depois do prazo. Resolver uma NUNCA
 * fecha nem silencia outra que esteja tocando ao mesmo tempo.
 *
 * FECHAMENTO FORÇADO (app removido dos Recentes com uma ocorrência em
 * andamento): [onTaskRemoved] marca a ocorrência e reabre a tela, que
 * dispara o alerta — SEMPRE conferindo antes se ela já não foi resolvida
 * (o PIN correto marca a ocorrência como resolvida no nativo).
 */
class RotinaAlarmWakeService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var receiverRegistrado = false
    private val handler = Handler(Looper.getMainLooper())

    private var player: MediaPlayer? = null
    private var vibrando = false
    private var modoSomAtual: String? = null

    private val receiverDesbloqueio = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val proxima = RotinaAlarmFluxoState.proximaParaExibir(applicationContext)
            Log.d(TAG, "receiverDesbloqueio: action=${intent?.action} proxima=${proxima?.chave}")
            if (proxima != null) iniciarTelaDoAlarme(proxima, abrirTeclado = false)
        }
    }

    private val revisao = Runnable { revisarOcorrencias() }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Contrato do Android 8+: startForeground em até 5 s, sempre.
        iniciarEmForeground()

        when (intent?.action) {
            ACAO_RESOLVER -> {
                val chave = intent.getStringExtra(EXTRA_CHAVE)
                if (chave != null) resolver(chave)
            }
            ACAO_REVISAR -> Unit
            else -> {
                val tipo = intent?.getStringExtra(RotinaCheckinAlarmActivity.EXTRA_TIPO_ALARME)
                    ?: RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA
                val id = intent?.getIntExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, -1) ?: -1
                val ciclo = intent?.getLongExtra(RotinaCheckinAlarmActivity.EXTRA_CICLO, 0L) ?: 0L
                val prazo = intent?.getLongExtra(RotinaCheckinAlarmActivity.EXTRA_PRAZO, 0L) ?: 0L
                Log.d(TAG, "onStartCommand: tipo=$tipo id=$id ciclo=$ciclo prazo=$prazo")
                if (id >= 0 && ciclo > 0L) {
                    val prazoEfetivo = if (prazo > ciclo) prazo else ciclo + PRAZO_PADRAO_MS
                    val ocorrencia = Ocorrencia(tipo, id, ciclo, prazoEfetivo)
                    if (RotinaAlarmFluxoState.estaResolvida(this, ocorrencia.chave)) {
                        Log.d(TAG, "Ocorrência ${ocorrencia.chave} já resolvida — ignorada.")
                    } else if (tipo == RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA &&
                        GxFirestoreRest.planoBloqueadoEm(this, System.currentTimeMillis())
                    ) {
                        Log.d(TAG, "Despertador #$id não toca — Plano Free nos dias bloqueados.")
                        RotinaAlarmFluxoState.marcarResolvido(this, ocorrencia.chave)
                    } else {
                        RotinaAlarmFluxoState.marcarEmAndamento(this, ocorrencia)
                        if (tipo == RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA) {
                            DespertadorAgenda.aoTocar(this, id, ciclo, prazoEfetivo)
                        }
                        iniciarTelaDoAlarme(ocorrencia, abrirTeclado = false)
                    }
                }
            }
        }

        revisarOcorrencias()
        return START_NOT_STICKY
    }

    /** Ocorrência resolvida pelo Dart (PIN correto ou alerta enviado). */
    private fun resolver(chave: String) {
        val ocorrencia = RotinaAlarmFluxoState.buscar(this, chave)
        RotinaAlarmFluxoState.marcarResolvido(this, chave)
        cancelarNotificacaoOcorrencia(this, chave)
        if (ocorrencia?.tipo == RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA) {
            DespertadorAgenda.armarProxima(this, ocorrencia.id)
        }
    }

    /**
     * Ponto único de revisão: descarta ocorrências vencidas há muito tempo
     * (rede de segurança — o servidor já cuidou do alerta), ajusta o som e
     * o WakeLock ao que ainda está em aberto e encerra o serviço quando
     * nada mais estiver em andamento.
     */
    private fun revisarOcorrencias() {
        handler.removeCallbacks(revisao)
        val agora = System.currentTimeMillis()
        for (o in RotinaAlarmFluxoState.pendentes(this)) {
            if (agora > o.prazo + MARGEM_ABANDONO_MS) {
                Log.d(TAG, "Ocorrência ${o.chave} abandonada (prazo vencido há mais de ${MARGEM_ABANDONO_MS / 60000} min).")
                RotinaAlarmFluxoState.marcarResolvido(this, o.chave)
                cancelarNotificacaoOcorrencia(this, o.chave)
                if (o.tipo == RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA) {
                    DespertadorAgenda.armarProxima(this, o.id)
                }
            }
        }
        val pendentes = RotinaAlarmFluxoState.pendentes(this)
        if (pendentes.isEmpty()) {
            Log.d(TAG, "Nenhuma ocorrência em andamento — encerrando o serviço.")
            pararSom()
            stopSelf()
            return
        }
        registrarReceiverDeDesbloqueio()
        adquirirWakeLock(pendentes.maxOf { it.prazo } + MARGEM_ABANDONO_MS - agora)
        atualizarSom(pendentes.filter { it.prazo > agora })

        // Próxima revisão: o prazo mais próximo ainda no futuro (o som para
        // nele) ou o abandono da mais antiga.
        val proximosEventos = pendentes.flatMap { listOf(it.prazo, it.prazo + MARGEM_ABANDONO_MS) }
            .filter { it > agora }
        val proximo = proximosEventos.minOrNull()
        if (proximo != null) handler.postDelayed(revisao, (proximo - agora).coerceAtLeast(1000L))
    }

    // ------------------------------------------------------------------
    // Som e vibração
    // ------------------------------------------------------------------

    private fun atualizarSom(ativas: List<Ocorrencia>) {
        if (ativas.isEmpty()) {
            pararSom()
            return
        }
        val despertador = ativas.any { it.tipo == RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA }
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val modo = when {
            despertador -> MODO_ALARME
            audio.ringerMode == AudioManager.RINGER_MODE_NORMAL -> MODO_TOQUE
            audio.ringerMode == AudioManager.RINGER_MODE_VIBRATE -> MODO_VIBRAR
            else -> MODO_MUDO
        }
        if (modo == modoSomAtual) return
        pararSom()
        modoSomAtual = modo
        val numeroSom = somEscolhido(this)
        when (modo) {
            MODO_ALARME -> if (numeroSom == SOM_SILENCIOSO) vibrarEmLoop() else tocarEmLoop(numeroSom, AudioAttributes.USAGE_ALARM)
            MODO_TOQUE -> if (numeroSom == SOM_SILENCIOSO) Unit else tocarEmLoop(numeroSom, AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            MODO_VIBRAR -> vibrarEmLoop()
            else -> Unit
        }
        Log.d(TAG, "Som: modo=$modo som=$numeroSom")
    }

    private fun tocarEmLoop(numeroSom: Int, uso: Int) {
        val recurso = resources.getIdentifier("som_$numeroSom", "raw", packageName)
            .takeIf { it != 0 } ?: resources.getIdentifier("som_1", "raw", packageName)
        try {
            val arquivo = resources.openRawResourceFd(recurso)
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(uso)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(arquivo.fileDescriptor, arquivo.startOffset, arquivo.length)
                arquivo.close()
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao tocar o som $numeroSom: ${e.message}")
            player = null
        }
    }

    private fun vibrador(): Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    private fun vibrarEmLoop() {
        try {
            val padrao = longArrayOf(0L, 700L, 500L)
            val v = vibrador() ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createWaveform(padrao, 0))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(padrao, 0)
            }
            vibrando = true
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao vibrar: ${e.message}")
        }
    }

    private fun pararSom() {
        try {
            player?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (_: Exception) {
        } finally {
            player = null
        }
        if (vibrando) {
            try { vibrador()?.cancel() } catch (_: Exception) {}
            vibrando = false
        }
        modoSomAtual = null
    }

    // ------------------------------------------------------------------
    // Tela / notificação
    // ------------------------------------------------------------------

    /**
     * Abre a tela do alarme por cima da tela bloqueada: notificação com
     * full-screen intent (exceção oficial à restrição de abrir Activity em
     * segundo plano do Android 10+) e, quando possível, `startActivity`.
     */
    private fun iniciarTelaDoAlarme(ocorrencia: Ocorrencia, abrirTeclado: Boolean) {
        val intent = intentDaTela(this, ocorrencia, abrirTeclado)
        postarNotificacaoOcorrencia(ocorrencia)
        try {
            startActivity(intent)
        } catch (e: Exception) {
            Log.d(TAG, "startActivity recusado (esperado com o app em segundo plano): ${e.message}")
        }
    }

    private fun postarNotificacaoOcorrencia(ocorrencia: Ocorrencia) {
        try {
            criarCanalSeNecessario(this)
            val pendingAbrir = PendingIntent.getActivity(
                this,
                idNotificacao(ocorrencia.chave),
                intentDaTela(this, ocorrencia, abrirTeclado = false),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val cronometro = ocorrencia.tipo == RotinaCheckinAlarmActivity.TIPO_ALARME_CRONOMETRO
            val construtor = NotificationCompat.Builder(this, CANAL_TELA_CHEIA_ID)
                .setSmallIcon(applicationInfo.icon)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setOngoing(true)
                .setAutoCancel(false)
                .setSilent(true)
                .setContentIntent(pendingAbrir)
                .setFullScreenIntent(pendingAbrir, true)
            if (cronometro) {
                val texto = TextosNativos.texto(this, "cronometroNotificacaoCorpo", R.string.cronometro_notificacao_corpo)
                construtor
                    .setContentTitle(TextosNativos.texto(this, "cronometroNotificacaoTitulo", R.string.cronometro_notificacao_titulo))
                    .setContentText(texto)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(texto))
            } else {
                val etiqueta = DespertadorAgenda.etiqueta(this, ocorrencia.id)
                val pendingTeclado = PendingIntent.getActivity(
                    this,
                    idNotificacao(ocorrencia.chave) + 1,
                    intentDaTela(this, ocorrencia, abrirTeclado = true),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                construtor
                    .setContentTitle(
                        etiqueta.ifBlank {
                            TextosNativos.texto(this, "despertadorNotificacaoTitulo", R.string.despertador_notificacao_titulo)
                        },
                    )
                    .setContentText(TextosNativos.texto(this, "despertadorNotificacaoCorpo", R.string.despertador_notificacao_corpo))
                    .addAction(
                        0,
                        TextosNativos.texto(this, "despertadorAcaoDesativar", R.string.despertador_acao_desativar),
                        pendingTeclado,
                    )
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(idNotificacao(ocorrencia.chave), construtor.build())
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao postar a notificação da ocorrência ${ocorrencia.chave}", e)
        }
    }

    private fun registrarReceiverDeDesbloqueio() {
        if (receiverRegistrado) return
        try {
            ContextCompat.registerReceiver(
                this,
                receiverDesbloqueio,
                IntentFilter(Intent.ACTION_USER_PRESENT),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            receiverRegistrado = true
        } catch (_: Exception) {
        }
    }

    private fun desregistrarReceiverDeDesbloqueio() {
        if (!receiverRegistrado) return
        try {
            unregisterReceiver(receiverDesbloqueio)
        } catch (_: Exception) {
        } finally {
            receiverRegistrado = false
        }
    }

    /**
     * FECHAMENTO FORÇADO: o app foi removido dos Recentes com ocorrências
     * em andamento. Só as que AINDA não foram resolvidas (conferido aqui e
     * de novo após 500 ms — o PIN correto pode ter acabado de resolvê-la)
     * são marcadas, e a tela reabre para disparar o alerta.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        val abertas = DecisaoFechamentoForcado.aMarcar(
            RotinaAlarmFluxoState.pendentes(this),
            RotinaAlarmFluxoState.resolvidas(this),
            System.currentTimeMillis(),
        )
        Log.d(TAG, "onTaskRemoved: ${abertas.size} ocorrência(s) em andamento")
        if (abertas.isEmpty()) return
        handler.postDelayed({
            // Confere de novo: o PIN correto pode ter acabado de resolver.
            val aMarcar = DecisaoFechamentoForcado.aMarcar(
                abertas, RotinaAlarmFluxoState.resolvidas(this), System.currentTimeMillis(),
            )
            for (o in aMarcar) RotinaAlarmFluxoState.marcarFechamentoForcado(this, o.chave)
            aMarcar.firstOrNull()?.let { iniciarTelaDoAlarme(it, abrirTeclado = false) }
        }, 500L)
    }

    private fun adquirirWakeLock(duracaoMs: Long) {
        try {
            val duracao = duracaoMs.coerceIn(60_000L, 6 * 60 * 60_000L)
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val atual = wakeLock ?: powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "SecurityCheckApp::RotinaAlarmWakeLock",
            ).apply { setReferenceCounted(false) }
            // Reaquirir renova o prazo do timeout para cobrir a tolerância
            // inteira da ocorrência mais longa em aberto.
            atual.acquire(duracao)
            wakeLock = atual
        } catch (e: Exception) {
            Log.d(TAG, "adquirirWakeLock: falha: ${e.message}")
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
        val canalId = "rotina_alarme_wake_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(canalId) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(canalId, "Guardião-X", NotificationManager.IMPORTANCE_MIN).apply {
                        setShowBadge(false)
                        setSound(null, null)
                    },
                )
            }
        }
        val notificacao = NotificationCompat.Builder(this, canalId)
            .setContentTitle("Guardião-X")
            .setContentText(TextosNativos.texto(this, "servicoAlarmeAtivo", R.string.servico_alarme_ativo))
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setSilent(true)
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
        Log.d(TAG, "onDestroy")
        handler.removeCallbacks(revisao)
        pararSom()
        desregistrarReceiverDeDesbloqueio()
        liberarWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val NOTIFICATION_ID = 7712

        /** Canal mudo das notificações de tela cheia (o som é do serviço).
         * Id novo: o `_v2` antigo tinha o som de alarme do sistema — o som
         * duplicado. Canais são imutáveis depois de criados. */
        const val CANAL_TELA_CHEIA_ID = "gx_alarme_tela_cheia_v3"
        private const val CANAL_ANTIGO_ID = "rotina_alarme_fullscreen_channel_v2"

        const val ACAO_RESOLVER = "com.example.security_check_app.ACAO_RESOLVER_OCORRENCIA"
        const val ACAO_REVISAR = "com.example.security_check_app.ACAO_REVISAR_OCORRENCIAS"
        const val EXTRA_CHAVE = "chave_ocorrencia"

        /** Tolerância do cronômetro (60 s) quando o prazo não vem no Intent. */
        private const val PRAZO_PADRAO_MS = 60_000L

        /** Depois do prazo, quanto esperar o Dart resolver antes de
         * abandonar a ocorrência (o servidor dispara pelo prazo). */
        private const val MARGEM_ABANDONO_MS = 5 * 60_000L

        private const val MODO_ALARME = "alarme"
        private const val MODO_TOQUE = "toque"
        private const val MODO_VIBRAR = "vibrar"
        private const val MODO_MUDO = "mudo"

        /** Som 10 = "Toque Silencioso" (silêncio proposital). */
        const val SOM_SILENCIOSO = 10

        /** Som escolhido em Configurações (`som_selecionado`, gravado pelo
         * shared_preferences do Dart). */
        fun somEscolhido(ctx: Context): Int {
            return try {
                val prefs = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val valor = prefs.all["flutter.som_selecionado"]
                when (valor) {
                    is Long -> valor.toInt()
                    is Int -> valor
                    is String -> valor.toIntOrNull() ?: 1
                    else -> 1
                }.coerceIn(1, 10)
            } catch (_: Exception) {
                1
            }
        }

        fun criarCanalSeNecessario(ctx: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            try { manager.deleteNotificationChannel(CANAL_ANTIGO_ID) } catch (_: Exception) {}
            if (manager.getNotificationChannel(CANAL_TELA_CHEIA_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(
                    CANAL_TELA_CHEIA_ID,
                    TextosNativos.texto(ctx, "canalAlarmeTelaCheia", R.string.canal_alarme_tela_cheia),
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                },
            )
        }

        fun idNotificacao(chave: String): Int = 7800 + (chave.hashCode() and 0x7fffffff) % 900 * 2

        fun cancelarNotificacaoOcorrencia(ctx: Context, chave: String) {
            try {
                val manager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.cancel(idNotificacao(chave))
            } catch (_: Exception) {
            }
        }

        fun intentDaTela(ctx: Context, ocorrencia: Ocorrencia, abrirTeclado: Boolean): Intent =
            Intent(ctx, RotinaCheckinAlarmActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
                putExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, ocorrencia.id)
                putExtra(RotinaCheckinAlarmActivity.EXTRA_TIPO_ALARME, ocorrencia.tipo)
                putExtra(RotinaCheckinAlarmActivity.EXTRA_CICLO, ocorrencia.ciclo)
                putExtra(RotinaCheckinAlarmActivity.EXTRA_PRAZO, ocorrencia.prazo)
                putExtra(RotinaCheckinAlarmActivity.EXTRA_ABRIR_TECLADO, abrirTeclado)
            }

        /** Inicia (ou acorda) o serviço para uma ocorrência. */
        fun iniciar(ctx: Context, ocorrencia: Ocorrencia) {
            val intent = Intent(ctx, RotinaAlarmWakeService::class.java).apply {
                putExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, ocorrencia.id)
                putExtra(RotinaCheckinAlarmActivity.EXTRA_TIPO_ALARME, ocorrencia.tipo)
                putExtra(RotinaCheckinAlarmActivity.EXTRA_CICLO, ocorrencia.ciclo)
                putExtra(RotinaCheckinAlarmActivity.EXTRA_PRAZO, ocorrencia.prazo)
            }
            try {
                ContextCompat.startForegroundService(ctx, intent)
            } catch (e: Exception) {
                Log.w(TAG, "Não foi possível iniciar o serviço do alarme: ${e.message}")
            }
        }

        /**
         * Ocorrência resolvida pelo Dart (PIN correto ou alerta enviado):
         * marca como resolvida (o fechamento forçado nunca mais dispara para
         * ela), cancela a notificação de tela cheia, e o serviço revisa o
         * que ainda está tocando. [chave] nulo = todas as ocorrências.
         */
        fun resolver(ctx: Context, chave: String?) {
            val chaves = if (chave != null) listOf(chave) else RotinaAlarmFluxoState.pendentes(ctx).map { it.chave }
            for (c in chaves) {
                val ocorrencia = RotinaAlarmFluxoState.buscar(ctx, c)
                RotinaAlarmFluxoState.marcarResolvido(ctx, c)
                cancelarNotificacaoOcorrencia(ctx, c)
                if (ocorrencia?.tipo == RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA) {
                    DespertadorAgenda.armarProxima(ctx, ocorrencia.id)
                }
            }
            if (RotinaAlarmFluxoState.pendentes(ctx).isEmpty()) {
                try {
                    ctx.stopService(Intent(ctx, RotinaAlarmWakeService::class.java))
                } catch (_: Exception) {
                }
            } else {
                try {
                    ContextCompat.startForegroundService(
                        ctx,
                        Intent(ctx, RotinaAlarmWakeService::class.java).setAction(ACAO_REVISAR),
                    )
                } catch (_: Exception) {
                }
            }
        }
    }
}

/**
 * Regras do FECHAMENTO FORÇADO (app removido dos Recentes durante o
 * alarme), sem dependência do Android — testadas em
 * `DecisaoFechamentoForcadoTest`. Uma ocorrência resolvida (PIN correto ou
 * alerta já enviado) NUNCA dispara o alerta de fechamento forçado.
 */
object DecisaoFechamentoForcado {
    /** Ocorrências a marcar: em andamento, prazo no futuro, não resolvidas. */
    fun aMarcar(pendentes: List<Ocorrencia>, resolvidas: Collection<String>, agora: Long): List<Ocorrencia> =
        pendentes.filter { it.prazo > agora && it.chave !in resolvidas }

    /** Ao reabrir a tela: dispara só se marcada E ainda não resolvida. */
    fun deveDisparar(marcadas: Set<String>, resolvidas: Collection<String>, chave: String): Boolean =
        chave in marcadas && chave !in resolvidas
}

/** Uma ocorrência de alarme: cronômetro (id fixo) ou despertador (id do
 * SQLite), identificada pelo horário programado ([ciclo], epoch ms). */
data class Ocorrencia(val tipo: String, val id: Int, val ciclo: Long, val prazo: Long) {
    val chave: String get() = chave(tipo, id, ciclo)

    fun paraJson(): JSONObject = JSONObject()
        .put("tipo", tipo).put("id", id).put("ciclo", ciclo).put("prazo", prazo)

    fun paraMapa(): Map<String, Any> =
        mapOf("tipo" to tipo, "id" to id, "ciclo" to ciclo, "prazo" to prazo, "chave" to chave)

    companion object {
        fun chave(tipo: String, id: Int, ciclo: Long) = "$tipo:$id:$ciclo"

        fun deJson(j: JSONObject): Ocorrencia? = try {
            Ocorrencia(j.getString("tipo"), j.getInt("id"), j.getLong("ciclo"), j.getLong("prazo"))
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * Estado das ocorrências de alarme, POR OCORRÊNCIA (chave `tipo:id:ciclo`),
 * num SharedPreferences nativo próprio — lido por componentes 100% nativos
 * (serviço, receptor de boot) mesmo sem engine Flutter vivo. Vários
 * despertadores (e o cronômetro) podem estar em andamento ao mesmo tempo;
 * resolver um nunca afeta o outro.
 */
object RotinaAlarmFluxoState {
    private const val PREFS_NAME = "rotina_alarme_wake_state_v2"
    private const val CHAVE_PENDENTES = "pendentes"
    private const val CHAVE_RESOLVIDAS = "resolvidas"
    private const val CHAVE_FECHAMENTO_FORCADO = "fechamento_forcado"
    private const val MAX_RESOLVIDAS = 100

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    @Synchronized
    fun marcarEmAndamento(ctx: Context, ocorrencia: Ocorrencia) {
        val lista = pendentes(ctx).filter { it.chave != ocorrencia.chave } + ocorrencia
        salvarPendentes(ctx, lista)
    }

    @Synchronized
    fun pendentes(ctx: Context): List<Ocorrencia> {
        val texto = prefs(ctx).getString(CHAVE_PENDENTES, null) ?: return emptyList()
        return try {
            val arr = JSONArray(texto)
            (0 until arr.length()).mapNotNull { Ocorrencia.deJson(arr.getJSONObject(it)) }
                .sortedBy { it.ciclo }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun buscar(ctx: Context, chave: String): Ocorrencia? = pendentes(ctx).firstOrNull { it.chave == chave }

    /** A próxima a mostrar na tela (a mais antiga ainda dentro do prazo). */
    fun proximaParaExibir(ctx: Context): Ocorrencia? {
        val agora = System.currentTimeMillis()
        return pendentes(ctx).firstOrNull { it.prazo > agora } ?: pendentes(ctx).firstOrNull()
    }

    @Synchronized
    fun marcarResolvido(ctx: Context, chave: String) {
        salvarPendentes(ctx, pendentes(ctx).filter { it.chave != chave })
        val resolvidas = resolvidas(ctx).filter { it != chave }.takeLast(MAX_RESOLVIDAS - 1) + chave
        prefs(ctx).edit()
            .putString(CHAVE_RESOLVIDAS, JSONArray(resolvidas).toString())
            .putStringSet(CHAVE_FECHAMENTO_FORCADO, fechamentosForcados(ctx) - chave)
            .commit()
    }

    fun estaResolvida(ctx: Context, chave: String): Boolean = resolvidas(ctx).contains(chave)

    fun estaEmAndamento(ctx: Context): Boolean = pendentes(ctx).isNotEmpty()

    @Synchronized
    fun marcarFechamentoForcado(ctx: Context, chave: String) {
        prefs(ctx).edit().putStringSet(CHAVE_FECHAMENTO_FORCADO, fechamentosForcados(ctx) + chave).commit()
    }

    /** Lê e limpa a marca de fechamento forçado de [chave] — `false` se a
     * ocorrência já foi resolvida (nunca alerta depois do PIN correto). */
    @Synchronized
    fun consumirFechamentoForcado(ctx: Context, chave: String): Boolean {
        val marcadas = fechamentosForcados(ctx)
        if (!marcadas.contains(chave)) return false
        prefs(ctx).edit().putStringSet(CHAVE_FECHAMENTO_FORCADO, marcadas - chave).commit()
        return DecisaoFechamentoForcado.deveDisparar(marcadas, resolvidas(ctx), chave)
    }

    private fun fechamentosForcados(ctx: Context): Set<String> =
        prefs(ctx).getStringSet(CHAVE_FECHAMENTO_FORCADO, emptySet())?.toSet() ?: emptySet()

    fun resolvidas(ctx: Context): List<String> {
        val texto = prefs(ctx).getString(CHAVE_RESOLVIDAS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(texto)
            (0 until arr.length()).map { arr.getString(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun salvarPendentes(ctx: Context, lista: List<Ocorrencia>) {
        val arr = JSONArray()
        lista.forEach { arr.put(it.paraJson()) }
        prefs(ctx).edit().putString(CHAVE_PENDENTES, arr.toString()).commit()
    }
}
