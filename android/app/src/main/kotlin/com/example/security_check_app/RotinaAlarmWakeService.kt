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
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

private const val TAG = "RotinaAlarmWakeService"

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
 *
 * DESBLOQUEIO DO APARELHO: o alarme não para de tocar/exigir o PIN só
 * porque a tela foi desbloqueada — `android:stopWithTask="false"` no
 * manifest garante que este Service (que já roda em primeiro plano) não
 * seja parado automaticamente por remoção de tarefa, e o
 * [BroadcastReceiver] registrado dinamicamente abaixo reabre
 * [RotinaCheckinAlarmActivity] sempre que o aparelho for desbloqueado
 * ([Intent.ACTION_USER_PRESENT]) enquanto o fluxo ([RotinaAlarmFluxoState])
 * ainda não tiver sido resolvido.
 *
 * FECHAMENTO FORÇADO ("jogar para cima"/force close) — especificação do
 * usuário (2026-08-07, item 4), COMPORTAMENTO INVERTIDO em relação à
 * versão anterior: antes, [onTaskRemoved] reabria a tela e deixava o
 * alarme continuar tocando normalmente (tratava o swipe como um gesto
 * sem consequência). Agora, esse gesto — enquanto o fluxo ainda
 * está em andamento (sem PIN confirmado) — é tratado como uma falha de
 * confirmação: a tela É reaberta (só para ter um engine Flutter vivo
 * capaz de rodar o disparo real, ver [RotinaAlarmFluxoState.marcarFechamentoForcado]/
 * `RotinaAlarmeService.consumirFechamentoForcado`), mas
 * [AlarmeDisparadoScreen] detecta esse motivo específico e dispara o
 * alerta de emergência IMEDIATAMENTE em vez de retomar o toque normal.
 */
class RotinaAlarmWakeService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var idAlarmeAtual: Int = -1
    private var receiverRegistrado = false

    private val receiverDesbloqueio = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val emAndamento = RotinaAlarmFluxoState.estaEmAndamento(applicationContext)
            Log.d(
                TAG,
                "receiverDesbloqueio.onReceive: action=${intent?.action} emAndamento=$emAndamento " +
                    "idAlarme=${RotinaAlarmFluxoState.idAlarmeAtual(applicationContext)}",
            )
            // Só reabre a tela se o fluxo REALMENTE ainda não tiver sido
            // resolvido (PIN correto ou alerta já disparado) — evita
            // reabrir uma tela de alarme já encerrado por qualquer
            // desbloqueio/tela-ligada subsequente e não relacionado.
            if (emAndamento) {
                iniciarTelaDoAlarme(
                    RotinaAlarmFluxoState.idAlarmeAtual(applicationContext),
                    RotinaAlarmFluxoState.tipoAlarmeAtual(applicationContext),
                )
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val tipoAlarme = intent?.getStringExtra(RotinaCheckinAlarmActivity.EXTRA_TIPO_ALARME)
            ?: RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA
        Log.d(
            TAG,
            "onStartCommand: idAlarme=${intent?.getIntExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, -1)} " +
                "tipoAlarme=$tipoAlarme",
        )
        iniciarEmForeground()
        adquirirWakeLock()
        registrarReceiverDeDesbloqueio()

        idAlarmeAtual = intent?.getIntExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, -1) ?: -1
        RotinaAlarmFluxoState.marcarEmAndamento(applicationContext, idAlarmeAtual, tipoAlarme)
        iniciarTelaDoAlarme(idAlarmeAtual, tipoAlarme)

        // START_NOT_STICKY: não faz sentido o Android recriar este Service
        // sozinho sem o extra do idAlarme — o próprio alarme nativo (ou o
        // lado Dart, se o usuário reabrir o app) já cuida de tudo a partir
        // daqui.
        return START_NOT_STICKY
    }

    /**
     * FECHAMENTO FORÇADO (item 4, ver comentário da classe): se o
     * Android remover a TAREFA (task) associada a este Service — ex:
     * usuário arrastou o app para cima nos Recentes — enquanto o fluxo
     * ainda estiver em andamento (PIN não confirmado), marca a flag
     * [RotinaAlarmFluxoState.marcarFechamentoForcado] ANTES de reabrir a
     * tela, para que [AlarmeDisparadoScreen] (assim que seu engine
     * reiniciar) saiba que deve disparar o alerta de emergência de
     * imediato, em vez de retomar o toque/teclado normal. O Service em
     * si (`stopWithTask="false"`) já sobrevive à remoção da tarefa; isto
     * cobre a Activity, que É destruída nesse evento.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        val emAndamento = RotinaAlarmFluxoState.estaEmAndamento(applicationContext)
        Log.d(TAG, "onTaskRemoved: emAndamento=$emAndamento — ${if (emAndamento) "fechamento forçado: marcando flag e reabrindo só para disparar o alerta" else "nada a fazer (fluxo já resolvido)"}")
        if (emAndamento) {
            RotinaAlarmFluxoState.marcarFechamentoForcado(applicationContext)
            Handler(Looper.getMainLooper()).postDelayed({
                val aindaEmAndamento = RotinaAlarmFluxoState.estaEmAndamento(applicationContext)
                Log.d(TAG, "onTaskRemoved (delayed 500ms): aindaEmAndamento=$aindaEmAndamento")
                if (aindaEmAndamento) {
                    iniciarTelaDoAlarme(
                        RotinaAlarmFluxoState.idAlarmeAtual(applicationContext),
                        RotinaAlarmFluxoState.tipoAlarmeAtual(applicationContext),
                    )
                }
            }, 500L)
        }
    }

    private fun registrarReceiverDeDesbloqueio() {
        if (receiverRegistrado) return
        try {
            val filtro = IntentFilter().apply {
                addAction(Intent.ACTION_USER_PRESENT)
            }
            // RECEIVER_NOT_EXPORTED: ACTION_USER_PRESENT é enviado pelo
            // próprio sistema (sempre entregue independente desta flag —
            // ela só controla se OUTROS apps de terceiros poderiam forjar
            // o broadcast para este receiver), exigido a partir do
            // Android 13 (API 33) para registro dinâmico de receivers.
            ContextCompat.registerReceiver(
                this,
                receiverDesbloqueio,
                filtro,
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
     * CORREÇÃO DE BUG REAL (2026-09-04 — pedido explícito do usuário: "com
     * o aparelho desbloqueado e o app em segundo plano, só aparece uma
     * notificação, sem tocar o alarme até tocar nela"): o `startActivity()`
     * direto abaixo, chamado a partir de um Foreground Service, está
     * sujeito à MESMA restrição de "Background Activity Launch" (BAL) do
     * Android 10+/12+ já diagnosticada e corrigida em
     * [VolumeSosService.forcarAberturaLockscreenCameraActivity] (ver aquele
     * comentário para o log real de `ActivityTaskManager: Background
     * activity launch blocked!` que motivou a correção lá) — com o app
     * fora do primeiro plano (mesmo desbloqueado), o Android pode
     * simplesmente recusar abrir [RotinaCheckinAlarmActivity], deixando só
     * o WakeLock e a notificação MÍNIMA/silenciosa de
     * [iniciarEmForeground] (que existe só para o Android permitir o
     * Foreground Service em si, não para alertar o usuário).
     *
     * FIX: o MESMO mecanismo já validado no botão físico — uma notificação
     * com `setFullScreenIntent(..., true)` é a exceção OFICIAL do Android
     * a essa restrição (documentada desde o Android 10): quando postada,
     * o próprio sistema abre a Activity do `PendingIntent`
     * automaticamente, mesmo com o app em segundo plano ou a tela
     * bloqueada, sem passar pelo BAL. Continua tentando o `startActivity()`
     * direto também (mais rápido quando funciona — app já em primeiro
     * plano, ou aparelhos/versões onde o BAL não bloqueia — e inofensivo
     * quando falha, já que a notificação full-screen acima cobre o caso).
     */
    private fun iniciarTelaDoAlarme(
        idAlarme: Int,
        tipoAlarme: String = RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA,
    ) {
        Log.d(TAG, "iniciarTelaDoAlarme: idAlarme=$idAlarme tipoAlarme=$tipoAlarme")

        val intent = Intent(this, RotinaCheckinAlarmActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
            putExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, idAlarme)
            putExtra(RotinaCheckinAlarmActivity.EXTRA_TIPO_ALARME, tipoAlarme)
        }

        postarNotificacaoFullScreen(intent, idAlarme)

        try {
            startActivity(intent)
        } catch (e: Exception) {
            // Falha silenciosa: a notificação full-screen-intent acima já
            // cobre a abertura da tela; o WakeLock adquirido também ajuda
            // o caminho Dart/headless a completar seu trabalho mesmo que
            // esta chamada direta não funcione neste aparelho/versão.
            Log.d(TAG, "iniciarTelaDoAlarme: falha ao iniciar Activity diretamente (esperado em " +
                "Android 12+/BAL) — a notificação full-screen-intent cobre a abertura: ${e.message}")
        }
    }

    /** Ver documentação completa em [iniciarTelaDoAlarme]. */
    private fun postarNotificacaoFullScreen(intentAbrir: Intent, idAlarme: Int) {
        try {
            criarCanalFullScreenSeNecessario()

            val flagsImutavel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
            val pendingAbrir = PendingIntent.getActivity(
                this,
                idAlarme,
                intentAbrir,
                PendingIntent.FLAG_UPDATE_CURRENT or flagsImutavel,
            )

            val notificacao = NotificationCompat.Builder(this, CANAL_FULLSCREEN_ID)
                .setContentTitle(getString(R.string.alerta_rotina_fisico_titulo))
                .setContentText(getString(R.string.alerta_rotina_fisico_corpo))
                .setSmallIcon(applicationInfo.icon)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setAutoCancel(true)
                .setOngoing(false)
                .setContentIntent(pendingAbrir)
                .setFullScreenIntent(pendingAbrir, true)
                .build()

            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID_FULLSCREEN, notificacao)
            Log.d(TAG, "postarNotificacaoFullScreen: notificação full-screen-intent postada (bypass de BAL).")
        } catch (e: Exception) {
            Log.w(TAG, "postarNotificacaoFullScreen: falha ao postar notificação full-screen.", e)
        }
    }

    /** Canal dedicado à notificação full-screen-intent de
     * [postarNotificacaoFullScreen] — `IMPORTANCE_HIGH` é exigido pelo
     * Android para que `setFullScreenIntent` realmente acorde/abra a
     * Activity automaticamente (canais de importância menor só mostram a
     * notificação normal, sem abrir nada sozinha) — DIFERENTE do canal
     * `rotina_alarme_wake_channel` de [iniciarEmForeground] (`IMPORTANCE_MIN`,
     * só existe para o próprio Foreground Service ser permitido, nunca
     * pensado para alertar o usuário).
     *
     * MITIGAÇÃO (2026-09-04 — pedido explícito do usuário, confirmado em
     * teste físico): com a TELA JÁ ACESA e desbloqueada (app só em
     * segundo plano), o Android — de PROPÓSITO, documentado oficialmente
     * desde a versão 10 — NÃO abre sozinho um full-screen-intent; mostra
     * só o banner da notificação e espera o toque. Isso é uma proteção
     * deliberada da plataforma (nenhum app comum consegue "sequestrar" a
     * tela enquanto o usuário está usando o aparelho para outra coisa) —
     * NÃO existe bypass público para isto, nem mesmo para apps de
     * despertador. O que dá pra fazer: o som da PRÓPRIA notificação (que
     * toca imediatamente ao ser postada, mesmo sem abrir a tela) usa o
     * canal de ALARME (`AudioAttributes.USAGE_ALARM`) em vez do toque
     * padrão de notificação — ganha foco de áudio/ignora o Modo Não
     * Perturbe e chama atenção IMEDIATA mesmo nesse cenário limitado,
     * ainda que o loop completo do som customizado só comece de fato
     * depois do toque na notificação (que aí sim abre a tela e o
     * `AudioPlayer` Dart assume, ver [RotinaCheckinAlarmActivity]).
     *
     * ID do canal com sufixo `_v2`: parâmetros de som/vibração de um
     * `NotificationChannel` já criado no aparelho são IMUTÁVEIS — o
     * Android ignora silenciosamente qualquer nova tentativa de
     * `createNotificationChannel` com o mesmo id mas configuração
     * diferente. Mudar o id força a criação de um canal novo com o som
     * de alarme de verdade em qualquer instalação já existente (em vez
     * de depender do usuário desinstalar/reinstalar o app).
     */
    private fun criarCanalFullScreenSeNecessario() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CANAL_FULLSCREEN_ID) != null) return

        val somDeAlarme = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val atributosDeAlarme = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        val canal = NotificationChannel(
            CANAL_FULLSCREEN_ID,
            "Alarme de rotina (abertura)",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Usado internamente para abrir a tela do alarme de rotina mesmo com o app em segundo plano ou a tela bloqueada."
            setShowBadge(false)
            setSound(somDeAlarme, atributosDeAlarme)
            enableVibration(true)
            vibrationPattern = longArrayOf(0L, 500L, 250L, 500L, 250L, 500L)
            setBypassDnd(true)
        }
        manager.createNotificationChannel(canal)
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
            Log.d(TAG, "adquirirWakeLock: WakeLock adquirido (timeout 10min)")
        } catch (e: Exception) {
            Log.d(TAG, "adquirirWakeLock: falha: ${e.message}")
            wakeLock = null
        }
    }

    private fun liberarWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
                Log.d(TAG, "liberarWakeLock: WakeLock liberado")
            }
        } catch (e: Exception) {
            Log.d(TAG, "liberarWakeLock: falha: ${e.message}")
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
        Log.d(TAG, "onDestroy")
        desregistrarReceiverDeDesbloqueio()
        liberarWakeLock()
        // CORREÇÃO DE BUG REAL (2026-09-04 — confirmado em teste físico e
        // no log: `FlashNotifController`/`MediaProvider` mostraram o toque
        // de alarme padrão do aparelho — `Platinum.ogg` — continuando a
        // tocar por ~37s DEPOIS do PIN correto já ter sido digitado): ver
        // documentação completa em [cancelarNotificacaoFullScreen].
        // Defensivo aqui também (além de [parar] abaixo, o ponto normal de
        // saída) para cobrir qualquer caminho de encerramento do Service
        // que não passe por lá.
        cancelarNotificacaoFullScreen(applicationContext)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val NOTIFICATION_ID = 7712

        /** Id/canal da notificação full-screen-intent de
         * [postarNotificacaoFullScreen] — diferente de [NOTIFICATION_ID]
         * (a notificação PERSISTENTE/silenciosa deste Foreground Service):
         * esta é disparada uma única vez por alarme e some sozinha
         * (`setAutoCancel(true)`) assim que a Activity abre. */
        private const val NOTIFICATION_ID_FULLSCREEN = 7713
        private const val CANAL_FULLSCREEN_ID = "rotina_alarme_fullscreen_channel_v2"

        /**
         * Libera o WakeLock e encerra este Service — chamado pelo lado
         * Dart (via [RotinaAlarmPlugin], MethodChannel
         * "pararServicoForeground") assim que o fluxo é resolvido: PIN
         * confirmado com sucesso OU alerta de emergência já disparado.
         * Seguro mesmo se o Service não estiver rodando.
         */
        fun parar(context: Context) {
            try {
                Log.d(TAG, "parar: marcando fluxo como resolvido e parando o Service")
                RotinaAlarmFluxoState.marcarResolvido(context)
                cancelarNotificacaoFullScreen(context)
                context.stopService(Intent(context, RotinaAlarmWakeService::class.java))
            } catch (e: Exception) {
                Log.d(TAG, "parar: falha: ${e.message}")
            }
        }

        /**
         * CORREÇÃO DE BUG REAL (2026-09-04 — pedido explícito do usuário,
         * confirmado em teste físico via logcat): a notificação
         * full-screen-intent de [postarNotificacaoFullScreen] usa
         * `category=alarm` + o som/canal de ALARME do sistema (mitigação
         * do cenário "tela acesa, app em segundo plano" — ver comentário
         * completo em [criarCanalFullScreenSeNecessario]). O log confirmou
         * `MediaProvider`/`FlashNotifController` (recurso do Motorola)
         * tratando isso como um alarme de verdade e tocando o toque padrão
         * do aparelho (`Platinum.ogg`) POR CONTA PRÓPRIA — e continuando a
         * tocar por dezenas de segundos MESMO DEPOIS do PIN correto já ter
         * sido digitado e o som do `AudioPlayer` Dart já ter sido parado,
         * porque `setAutoCancel(true)` só remove a notificação quando o
         * USUÁRIO toca nela diretamente — nunca quando o app resolve o
         * alarme sozinho por outro caminho (PIN digitado direto na tela já
         * aberta, sem precisar tocar na notificação). Sintoma real
         * reportado: "quando digito a senha corretamente o som do
         * Guardião-X desliga e fica tocando somente o alarme nativo do
         * celular" — que na really era esta MESMA notificação, sozinha,
         * ainda ativa. `NotificationManager.cancel()` aqui é o que
         * realmente encerra esse efeito, chamado em todo ponto em que o
         * alarme é considerado resolvido/encerrado (ver [parar] acima e
         * [onDestroy]).
         */
        fun cancelarNotificacaoFullScreen(context: Context) {
            try {
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.cancel(NOTIFICATION_ID_FULLSCREEN)
            } catch (e: Exception) {
                Log.d(TAG, "cancelarNotificacaoFullScreen: falha: ${e.message}")
            }
        }
    }
}

/**
 * Estado do fluxo do alarme de rotina, persistido num arquivo
 * [android.content.SharedPreferences] NATIVO próprio (independente do
 * `FlutterSharedPreferences` usado pelo plugin `shared_preferences` do
 * lado Dart, cujo formato de armazenamento interno pode mudar entre
 * versões do plugin) — usado exclusivamente por componentes 100%
 * nativos ([RotinaAlarmWakeService]) para decidir, de forma confiável e
 * independente do Flutter, se o alarme ainda está "em andamento"
 * (aguardando PIN) ou já foi resolvido, mesmo que nenhum engine Flutter
 * esteja vivo no momento (ex: logo após um desbloqueio de tela).
 *
 * Marcado como "em andamento" em [RotinaAlarmWakeService.onStartCommand]
 * (disparo inicial nativo) e em [RotinaAlarmPlugin] sempre que a tela do
 * alarme é (re)aberta via MethodChannel (`iniciarTelaAlarme`/
 * `acordarParaFaseFinal` — disparo/fase final vindos do lado Dart).
 * Marcado como "resolvido" em [RotinaAlarmWakeService.parar], o MESMO
 * ponto único já usado por `pararServicoForeground` (chamado tanto ao
 * confirmar o PIN quanto ao disparar o alerta de emergência real — ver
 * `RotinaAlarmeService` no lado Dart).
 */
object RotinaAlarmFluxoState {
    private const val PREFS_NAME = "rotina_alarme_wake_state"
    private const val CHAVE_EM_ANDAMENTO = "em_andamento"
    private const val CHAVE_ID_ALARME = "id_alarme_atual"
    private const val CHAVE_FECHAMENTO_FORCADO = "fechamento_forcado"

    /**
     * Tipo do alarme atualmente em andamento — [RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA]
     * (padrão, retrocompatível) ou [RotinaCheckinAlarmActivity.TIPO_ALARME_CRONOMETRO].
     * Generalização que permite este MESMO estado nativo (e o restante da
     * infraestrutura de [RotinaAlarmWakeService]) ser compartilhado pelo
     * Cronômetro Regressivo da aba Segurança, sem duplicar nenhuma classe.
     */
    private const val CHAVE_TIPO_ALARME = "tipo_alarme_atual"

    fun marcarEmAndamento(
        context: Context,
        idAlarme: Int,
        tipoAlarme: String = RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA,
    ) {
        try {
            Log.d(TAG, "RotinaAlarmFluxoState.marcarEmAndamento: idAlarme=$idAlarme tipoAlarme=$tipoAlarme")
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(CHAVE_EM_ANDAMENTO, true)
                .putInt(CHAVE_ID_ALARME, idAlarme)
                .putString(CHAVE_TIPO_ALARME, tipoAlarme)
                .apply()
        } catch (_: Exception) {
        }
    }

    /** Tipo do alarme atualmente em andamento (ver [CHAVE_TIPO_ALARME]) —
     * [RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA] se ausente/erro. */
    fun tipoAlarmeAtual(context: Context): String {
        return try {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getString(CHAVE_TIPO_ALARME, RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA)
                ?: RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA
        } catch (_: Exception) {
            RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA
        }
    }

    fun marcarResolvido(context: Context) {
        try {
            Log.d(TAG, "RotinaAlarmFluxoState.marcarResolvido")
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(CHAVE_EM_ANDAMENTO, false)
                .apply()
        } catch (_: Exception) {
        }
    }

    fun estaEmAndamento(context: Context): Boolean {
        return try {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(CHAVE_EM_ANDAMENTO, false)
        } catch (_: Exception) {
            false
        }
    }

    fun idAlarmeAtual(context: Context): Int {
        return try {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getInt(CHAVE_ID_ALARME, -1)
        } catch (_: Exception) {
            -1
        }
    }

    /**
     * Marca que a próxima reabertura da tela do alarme aconteceu por
     * FECHAMENTO FORÇADO (ver [RotinaAlarmWakeService.onTaskRemoved]) —
     * consumida (lida E limpa) uma única vez pelo lado Dart via
     * [consumirFechamentoForcado]/`RotinaAlarmPlugin`
     * ("consumirFechamentoForcado").
     */
    fun marcarFechamentoForcado(context: Context) {
        try {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(CHAVE_FECHAMENTO_FORCADO, true)
                .apply()
        } catch (_: Exception) {
        }
    }

    /**
     * Lê e IMEDIATAMENTE limpa a flag de fechamento forçado — chamada
     * pelo lado Dart assim que o engine desta reabertura inicia (ver
     * `AlarmeDisparadoScreen.initState`), garantindo que o sinal só seja
     * processado uma única vez, mesmo que a tela seja recriada depois
     * por outro motivo (ex: desbloqueio de tela) antes do fluxo terminar.
     */
    /**
     * [tipoEsperado]: só consome (lê E limpa) a flag se o tipo do alarme
     * ATUALMENTE em andamento (ver [tipoAlarmeAtual]) bater com o
     * chamador — evita que uma instância de [RotinaCheckinAlarmActivity]
     * do Alarme de Rotina consuma por engano um fechamento forçado que
     * era, na verdade, do Cronômetro (ou vice-versa), no raro caso dos
     * dois estarem ativos ao mesmo tempo. Retrocompatível: chamadores que
     * não informam [tipoEsperado] (`null`) continuam consumindo a flag
     * incondicionalmente, como antes.
     */
    fun consumirFechamentoForcado(context: Context, tipoEsperado: String? = null): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (tipoEsperado != null && tipoAlarmeAtual(context) != tipoEsperado) return false
            val valor = prefs.getBoolean(CHAVE_FECHAMENTO_FORCADO, false)
            if (valor) {
                prefs.edit().putBoolean(CHAVE_FECHAMENTO_FORCADO, false).apply()
            }
            valor
        } catch (_: Exception) {
            false
        }
    }
}
