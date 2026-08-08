package com.example.security_check_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
                iniciarTelaDoAlarme(RotinaAlarmFluxoState.idAlarmeAtual(applicationContext))
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: idAlarme=${intent?.getIntExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, -1)}")
        iniciarEmForeground()
        adquirirWakeLock()
        registrarReceiverDeDesbloqueio()

        idAlarmeAtual = intent?.getIntExtra(RotinaCheckinAlarmActivity.EXTRA_ID_ALARME, -1) ?: -1
        RotinaAlarmFluxoState.marcarEmAndamento(applicationContext, idAlarmeAtual)
        iniciarTelaDoAlarme(idAlarmeAtual)

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
                    iniciarTelaDoAlarme(RotinaAlarmFluxoState.idAlarmeAtual(applicationContext))
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

    private fun iniciarTelaDoAlarme(idAlarme: Int) {
        Log.d(TAG, "iniciarTelaDoAlarme: idAlarme=$idAlarme")
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
        } catch (e: Exception) {
            // Falha silenciosa: o WakeLock adquirido acima já ajuda o
            // caminho Dart/headless a completar seu trabalho mesmo que a
            // Activity não abra por algum motivo específico de fabricante.
            Log.d(TAG, "iniciarTelaDoAlarme: falha ao iniciar Activity: ${e.message}")
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
                Log.d(TAG, "parar: marcando fluxo como resolvido e parando o Service")
                RotinaAlarmFluxoState.marcarResolvido(context)
                context.stopService(Intent(context, RotinaAlarmWakeService::class.java))
            } catch (e: Exception) {
                Log.d(TAG, "parar: falha: ${e.message}")
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

    fun marcarEmAndamento(context: Context, idAlarme: Int) {
        try {
            Log.d(TAG, "RotinaAlarmFluxoState.marcarEmAndamento: idAlarme=$idAlarme")
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(CHAVE_EM_ANDAMENTO, true)
                .putInt(CHAVE_ID_ALARME, idAlarme)
                .apply()
        } catch (_: Exception) {
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
    fun consumirFechamentoForcado(context: Context): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
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
