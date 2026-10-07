package com.example.security_check_app

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.auth.FirebaseAuth
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

// Localização a cada 1 minuto durante o Cronômetro Regressivo (e a
// tolerância) e nas 2 h antes de cada despertador (até o fim da
// tolerância) — com a tela apagada ou o app fechado.
//
// Foreground service do tipo `location` ("Cronômetro de segurança ativo"),
// ligado só enquanto houver uma JANELA aberta. A cada 60 s grava a posição,
// sobrescrevendo, em `usuarios/{uid}`, `usuarios/{uid}/monitoramento/atual`
// e `alarmes_agendados/{uid}_{idAlarme}.ultimaLocalizacao` de cada janela
// aberta. Fora das janelas, nada é enviado. Gravação pela API REST do
// Firestore (mesmo caminho de `RastreamentoContinuo.kt`), com o token da
// sessão do Firebase Auth nativo — funciona sem engine Flutter.

/** Textos das notificações nativas no idioma escolhido NO APP (o Dart
 * grava os textos traduzidos; o recurso Android é só o padrão). */
object TextosNativos {
    private const val PREFS = "gx_textos_nativos"

    fun salvar(ctx: Context, textos: Map<String, String>) {
        val editor = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        for ((chave, valor) in textos) editor.putString(chave, valor)
        editor.apply()
    }

    fun texto(ctx: Context, chave: String, padrao: Int): String {
        val salvo = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(chave, null)
        return if (!salvo.isNullOrBlank()) salvo else ctx.getString(padrao)
    }
}

/** Sessão (uid + opções do Firebase) e Firestore REST para os serviços
 * nativos de segurança. */
object GxFirestoreRest {
    private const val TAG = "GxFirestoreRest"
    private const val PREFS = "gx_identidade_nativa"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun configurar(ctx: Context, dados: Map<String, Any?>) {
        val editor = prefs(ctx).edit()
        for ((chave, valor) in dados) {
            when (valor) {
                null -> editor.remove(chave)
                is String -> editor.putString(chave, valor)
                else -> editor.putString(chave, valor.toString())
            }
        }
        editor.apply()
    }

    fun uidConfigurado(ctx: Context): String? = prefs(ctx).getString("uid", null)

    /** Dias 11–30 do ciclo do Plano Free (sem Premium) em [instanteMs] —
     * os despertadores não tocam nesse período. Sem dado = liberado. */
    fun planoBloqueadoEm(ctx: Context, instanteMs: Long): Boolean {
        val p = prefs(ctx)
        if (p.getString("planoPremium", "false") == "true") return false
        val inicio = p.getString("planoInicioMs", null)?.toLongOrNull() ?: return false
        val dia = ((instanteMs - inicio) / 86_400_000L).toInt() + 1
        return dia in 11..30
    }

    /** Marca o documento do despertador como CANCELADO (plano bloqueado). */
    fun marcarCancelado(ctx: Context, idAlarme: Int): Boolean = comSessao(ctx) { uid, token, raiz ->
        val campos = JSONObject().put("status", texto("CANCELADO"))
        commit(
            raiz, token,
            JSONArray().put(
                escritaParcial("$raiz/alarmes_agendados/${uid}_$idAlarme", campos, listOf("canceladoEm"), true),
            ),
        )
    }

    /** Lista `[{nome, telefone}]` dos contatos de emergência (JSON). */
    fun contatosJson(ctx: Context): JSONArray = try {
        JSONArray(prefs(ctx).getString("contatos", "[]"))
    } catch (_: Exception) {
        JSONArray()
    }

    private fun garantirFirebase(ctx: Context): FirebaseApp? {
        FirebaseApp.getApps(ctx).firstOrNull { it.name == FirebaseApp.DEFAULT_APP_NAME }?.let { return it }
        val p = prefs(ctx)
        val apiKey = p.getString("firebaseApiKey", null) ?: return null
        val appId = p.getString("firebaseAppId", null) ?: return null
        return try {
            val opcoes = FirebaseOptions.Builder()
                .setApiKey(apiKey)
                .setApplicationId(appId)
                .apply {
                    p.getString("firebaseProjectId", null)?.let { setProjectId(it) }
                    p.getString("firebaseSenderId", null)?.let { setGcmSenderId(it) }
                    p.getString("firebaseStorageBucket", null)?.let { setStorageBucket(it) }
                }
                .build()
            FirebaseApp.initializeApp(ctx.applicationContext, opcoes)
        } catch (e: IllegalStateException) {
            FirebaseApp.getInstance()
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao inicializar o Firebase: $e")
            null
        }
    }

    /** (uid, token, projeto) da sessão atual — só na thread de rede. */
    private fun sessao(ctx: Context, renovar: Boolean): Triple<String, String, String>? {
        val app = garantirFirebase(ctx) ?: return null
        val usuario = FirebaseAuth.getInstance(app).currentUser ?: return null
        val configurado = uidConfigurado(ctx)
        if (configurado != null && configurado != usuario.uid) return null
        val projeto = app.options.projectId ?: return null
        val token = try {
            Tasks.await(usuario.getIdToken(renovar), 20, TimeUnit.SECONDS).token
        } catch (e: Exception) {
            Log.w(TAG, "Sem token: $e")
            null
        } ?: return null
        return Triple(usuario.uid, token, projeto)
    }

    private fun requisicao(metodo: String, url: String, token: String, corpo: JSONObject?): Pair<Int, String> {
        val conexao = URL(url).openConnection() as HttpURLConnection
        return try {
            conexao.requestMethod = metodo
            conexao.connectTimeout = 20_000
            conexao.readTimeout = 20_000
            conexao.setRequestProperty("Authorization", "Bearer $token")
            if (corpo != null) {
                conexao.doOutput = true
                conexao.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                conexao.outputStream.use { it.write(corpo.toString().toByteArray()) }
            }
            val codigo = conexao.responseCode
            val texto = (if (codigo in 200..299) conexao.inputStream else conexao.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            Pair(codigo, texto)
        } finally {
            conexao.disconnect()
        }
    }

    /** Executa [acao] com a sessão; tenta de novo com o token renovado em
     * 401/403. [acao] devolve o código HTTP. */
    private fun comSessao(ctx: Context, acao: (uid: String, token: String, raiz: String) -> Int): Boolean {
        for (tentativa in 0..1) {
            val (uid, token, projeto) = sessao(ctx, tentativa > 0) ?: return false
            val raiz = "projects/$projeto/databases/(default)/documents"
            val codigo = acao(uid, token, raiz)
            if (codigo in 200..299) return true
            if (codigo != 401 && codigo != 403) return false
        }
        return false
    }

    private fun commit(raiz: String, token: String, escritas: JSONArray): Int {
        val projetoBase = raiz.substringBefore("/documents")
        val (codigo, corpo) = requisicao(
            "POST",
            "https://firestore.googleapis.com/v1/$projetoBase/documents:commit",
            token,
            JSONObject().put("writes", escritas),
        )
        if (codigo !in 200..299) Log.w(TAG, "Firestore recusou ($codigo): ${corpo.take(200)}")
        return codigo
    }

    fun duplo(v: Double): JSONObject = JSONObject().put("doubleValue", v)
    fun texto(v: String): JSONObject = JSONObject().put("stringValue", v)
    fun inteiro(v: Long): JSONObject = JSONObject().put("integerValue", v.toString())
    fun booleano(v: Boolean): JSONObject = JSONObject().put("booleanValue", v)
    fun instante(ms: Long): JSONObject = JSONObject().put("timestampValue", iso8601(ms))

    private fun iso8601(ms: Long): String {
        val formato = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        formato.timeZone = TimeZone.getTimeZone("UTC")
        return formato.format(Date(ms))
    }

    private fun escritaParcial(nome: String, campos: JSONObject, transformacoes: List<String>, exigirExistente: Boolean): JSONObject {
        val chaves = JSONArray()
        campos.keys().forEach { chaves.put(it) }
        val transf = JSONArray()
        for (campo in transformacoes) {
            transf.put(JSONObject().put("fieldPath", campo).put("setToServerValue", "REQUEST_TIME"))
        }
        val escrita = JSONObject()
            .put("update", JSONObject().put("name", nome).put("fields", campos))
            .put("updateMask", JSONObject().put("fieldPaths", chaves))
        if (transf.length() > 0) escrita.put("updateTransforms", transf)
        if (exigirExistente) escrita.put("currentDocument", JSONObject().put("exists", true))
        return escrita
    }

    /** Posição em `usuarios/{uid}` e `.../monitoramento/atual` (merge). */
    fun gravarPosicaoUsuario(ctx: Context, local: Location): Boolean = comSessao(ctx) { uid, token, raiz ->
        val base = "$raiz/usuarios/$uid"
        val usuario = JSONObject()
            .put("latitude", duplo(local.latitude))
            .put("longitude", duplo(local.longitude))
        val atual = JSONObject()
            .put("latitude", duplo(local.latitude))
            .put("longitude", duplo(local.longitude))
            .put("precisao", duplo(local.accuracy.toDouble()))
            .put("origem", texto("seguranca"))
            .put("plataforma", texto("android"))
        commit(
            raiz, token,
            JSONArray()
                .put(escritaParcial(base, usuario, listOf("atualizadoEm"), false))
                .put(escritaParcial("$base/monitoramento/atual", atual, listOf("atualizadoEm"), false)),
        )
    }

    /** `alarmes_agendados/{uid}_{idAlarme}.ultimaLocalizacao` (sobrescreve).
     * Só atualiza um documento que já existe. */
    fun gravarUltimaLocalizacao(ctx: Context, idAlarme: String, local: Location): Boolean =
        comSessao(ctx) { uid, token, raiz ->
            val ultima = JSONObject().put(
                "ultimaLocalizacao",
                JSONObject().put(
                    "mapValue",
                    JSONObject().put(
                        "fields",
                        JSONObject()
                            .put("lat", duplo(local.latitude))
                            .put("lng", duplo(local.longitude))
                            .put("precisao", duplo(local.accuracy.toDouble())),
                    ),
                ),
            )
            commit(
                raiz, token,
                JSONArray().put(
                    escritaParcial(
                        "$raiz/alarmes_agendados/${uid}_$idAlarme",
                        ultima,
                        listOf("ultimaLocalizacao.timestamp"),
                        true,
                    ),
                ),
            )
        }

    /**
     * Garante o documento do CICLO [ciclo] do despertador [idAlarme] na
     * nuvem (status PENDENTE, prazo = horário + tolerância) — usado quando o
     * app não abriu desde a ocorrência anterior. Nunca sobrescreve um
     * documento que já é deste mesmo ciclo.
     */
    fun garantirCicloDespertador(
        ctx: Context,
        idAlarme: Int,
        ciclo: Long,
        prazo: Long,
        etiqueta: String,
        contexto: String,
    ): Boolean = comSessao(ctx) { uid, token, raiz ->
        val nome = "$raiz/alarmes_agendados/${uid}_$idAlarme"
        val (codigoLeitura, corpo) = requisicao("GET", "https://firestore.googleapis.com/v1/$nome", token, null)
        if (codigoLeitura in 200..299) {
            val campos = try { JSONObject(corpo).optJSONObject("fields") } catch (_: Exception) { null }
            val cicloAtual = campos?.optJSONObject("cicloEpochMs")?.optString("integerValue")?.toLongOrNull()
            if (cicloAtual == ciclo) return@comSessao 200
        } else if (codigoLeitura != 404) {
            return@comSessao codigoLeitura
        }
        val contatos = JSONArray()
        val lista = contatosJson(ctx)
        for (i in 0 until lista.length()) {
            val c = lista.optJSONObject(i) ?: continue
            contatos.put(
                JSONObject().put(
                    "mapValue",
                    JSONObject().put(
                        "fields",
                        JSONObject()
                            .put("nome", texto(c.optString("nome")))
                            .put("telefone", texto(c.optString("telefone"))),
                    ),
                ),
            )
        }
        val campos = JSONObject()
            .put("idAlarme", texto(idAlarme.toString()))
            .put("usuarioId", texto(uid))
            .put("dataHoraDisparo", instante(ciclo))
            .put("cicloEpochMs", inteiro(ciclo))
            .put("prazoFinalEpochMs", inteiro(prazo))
            .put("status", texto("PENDENTE"))
            .put("contatosEmergencia", JSONObject().put("arrayValue", JSONObject().put("values", contatos)))
            .put("etiqueta", texto(etiqueta))
            .put("contextoPersonalizado", texto(contexto))
        val escrita = JSONObject().put("update", JSONObject().put("name", nome).put("fields", campos))
        commit(raiz, token, JSONArray().put(escrita))
    }
}

/** Janelas de localização (persistidas — sobrevivem ao app fechado e ao
 * reinício do aparelho). */
object VigiaLocalizacao {
    private const val TAG = "VigiaLocalizacao"
    private const val PREFS = "gx_vigia_localizacao"
    private const val CHAVE_JANELAS = "janelas"
    const val ID_CRONOMETRO = "checkin_seguranca"

    data class Janela(val docId: String, val inicio: Long, val fim: Long, val tipo: String)

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun janelas(ctx: Context): List<Janela> {
        val texto = prefs(ctx).getString(CHAVE_JANELAS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(texto)
            (0 until arr.length()).mapNotNull {
                val j = arr.getJSONObject(it)
                Janela(j.getString("docId"), j.getLong("inicio"), j.getLong("fim"), j.optString("tipo", "rotina"))
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    @Synchronized
    private fun salvar(ctx: Context, lista: List<Janela>) {
        val arr = JSONArray()
        lista.forEach {
            arr.put(JSONObject().put("docId", it.docId).put("inicio", it.inicio).put("fim", it.fim).put("tipo", it.tipo))
        }
        prefs(ctx).edit().putString(CHAVE_JANELAS, arr.toString()).commit()
    }

    /** Registra/substitui a janela de [docId]: arma o início (alarme
     * exato) ou liga o serviço agora, se já começou. */
    fun registrar(ctx: Context, docId: String, inicio: Long, fim: Long, tipo: String) {
        val agora = System.currentTimeMillis()
        if (fim <= agora) {
            remover(ctx, docId)
            return
        }
        salvar(ctx, janelas(ctx).filter { it.docId != docId && it.fim > agora } + Janela(docId, inicio, fim, tipo))
        if (inicio <= agora) {
            iniciarServico(ctx)
        } else {
            armarInicio(ctx, docId, inicio)
        }
    }

    fun remover(ctx: Context, docId: String) {
        salvar(ctx, janelas(ctx).filter { it.docId != docId })
        cancelarInicio(ctx, docId)
        if (VigiaLocalizacaoService.emExecucao) {
            try {
                ContextCompat.startForegroundService(
                    ctx, Intent(ctx, VigiaLocalizacaoService::class.java).setAction(VigiaLocalizacaoService.ACAO_REVISAR),
                )
            } catch (_: Exception) {
            }
        }
    }

    fun abertas(ctx: Context, agora: Long = System.currentTimeMillis()): List<Janela> =
        janelas(ctx).filter { it.inicio <= agora && agora <= it.fim }

    /** Depois de reiniciar o aparelho: rearma os inícios e religa o serviço. */
    fun rearmar(ctx: Context) {
        val agora = System.currentTimeMillis()
        val validas = janelas(ctx).filter { it.fim > agora }
        salvar(ctx, validas)
        for (j in validas) if (j.inicio > agora) armarInicio(ctx, j.docId, j.inicio)
        if (validas.any { it.inicio <= agora }) iniciarServico(ctx)
    }

    fun iniciarServico(ctx: Context) {
        if (!temPermissaoLocalizacao(ctx)) {
            Log.w(TAG, "Sem permissão de localização — janela registrada, serviço não iniciado.")
            return
        }
        try {
            ContextCompat.startForegroundService(ctx, Intent(ctx, VigiaLocalizacaoService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "Não foi possível iniciar o serviço de localização: $e")
        }
    }

    fun temPermissaoLocalizacao(ctx: Context): Boolean =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun pendingInicio(ctx: Context, docId: String): PendingIntent {
        val intent = Intent(ctx, VigiaLocalizacaoReceiver::class.java).putExtra("docId", docId)
        return PendingIntent.getBroadcast(
            ctx,
            600_000 + (docId.hashCode() and 0x7fffffff) % 100_000,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun armarInicio(ctx: Context, docId: String, inicio: Long) {
        try {
            val alarmManager = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = pendingInicio(ctx, docId)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !alarmManager.canScheduleExactAlarms()) {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, inicio, pi)
            } else {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, inicio, pi)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao armar o início da janela $docId: $e")
        }
    }

    private fun cancelarInicio(ctx: Context, docId: String) {
        try {
            (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pendingInicio(ctx, docId))
        } catch (_: Exception) {
        }
    }
}

/** Início de uma janela (alarme exato): liga o serviço. */
class VigiaLocalizacaoReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("VigiaLocalizacao", "Início da janela ${intent.getStringExtra("docId")}")
        VigiaLocalizacao.iniciarServico(context)
    }
}

/**
 * Foreground service (tipo `location`): enquanto houver janela aberta, lê
 * uma posição de alta precisão e grava a cada 60 s; encerra sozinho quando
 * a última janela termina.
 */
class VigiaLocalizacaoService : Service() {

    companion object {
        private const val TAG = "VigiaLocalizacao"
        private const val CANAL = "gx_vigia_localizacao"
        private const val ID_NOTIFICACAO = 47_160
        private const val INTERVALO_MS = 60_000L
        const val ACAO_REVISAR = "com.example.security_check_app.VIGIA_REVISAR"

        @Volatile
        var emExecucao = false
            private set
    }

    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var wakeLock: PowerManager.WakeLock? = null
    private var gravando = false
    private val ciclo = Runnable { executarCiclo() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!entrarEmPrimeiroPlano()) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (VigiaLocalizacao.abertas(this).isEmpty() && intent?.action == ACAO_REVISAR) {
            encerrar()
            return START_NOT_STICKY
        }
        if (!emExecucao) {
            emExecucao = true
            adquirirWakeLock()
            Log.i(TAG, "Localização de segurança ligada.")
        }
        handler.removeCallbacks(ciclo)
        handler.post(ciclo)
        return START_STICKY
    }

    private fun executarCiclo() {
        val abertas = VigiaLocalizacao.abertas(this)
        if (abertas.isEmpty()) {
            encerrar()
            return
        }
        atualizarNotificacao(abertas)
        if (!gravando) {
            gravando = true
            executor.execute {
                try {
                    val local = lerPosicao()
                    if (local != null) {
                        GxFirestoreRest.gravarPosicaoUsuario(this, local)
                        for (j in VigiaLocalizacao.abertas(this)) {
                            GxFirestoreRest.gravarUltimaLocalizacao(this, j.docId, local)
                        }
                        Log.i(TAG, "Posição gravada (${abertas.size} janela(s)).")
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Falha no ciclo de localização: $e")
                } finally {
                    handler.post { gravando = false }
                }
            }
        }
        handler.postDelayed(ciclo, INTERVALO_MS)
    }

    private fun lerPosicao(): Location? {
        if (!VigiaLocalizacao.temPermissaoLocalizacao(this)) return null
        return try {
            val cliente = LocationServices.getFusedLocationProviderClient(this)
            val pedido = CurrentLocationRequest.Builder()
                .setPriority(Priority.PRIORITY_HIGH_ACCURACY)
                .setMaxUpdateAgeMillis(30_000L)
                .setDurationMillis(25_000L)
                .build()
            Tasks.await(cliente.getCurrentLocation(pedido, null), 30, TimeUnit.SECONDS)
                ?: Tasks.await(cliente.lastLocation, 5, TimeUnit.SECONDS)
        } catch (e: SecurityException) {
            Log.w(TAG, "Sem permissão de localização: $e")
            null
        } catch (e: Exception) {
            Log.w(TAG, "Posição indisponível: $e")
            null
        }
    }

    private fun encerrar() {
        handler.removeCallbacks(ciclo)
        if (emExecucao) Log.i(TAG, "Localização de segurança desligada.")
        emExecucao = false
        liberarWakeLock()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
        stopSelf()
    }

    override fun onDestroy() {
        handler.removeCallbacks(ciclo)
        emExecucao = false
        liberarWakeLock()
        super.onDestroy()
    }

    private fun adquirirWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SecurityCheckApp::VigiaLocalizacao").apply {
                setReferenceCounted(false)
                // Renovado a cada notificação atualizada (ver [atualizarNotificacao]).
                acquire(3 * 60_000L)
            }
        } catch (_: Exception) {
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

    private fun notificacao(abertas: List<VigiaLocalizacao.Janela>): android.app.Notification {
        val gerente = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && gerente != null) {
            gerente.createNotificationChannel(
                NotificationChannel(
                    CANAL,
                    TextosNativos.texto(this, "canalLocalizacaoSeguranca", R.string.canal_localizacao_seguranca),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    setShowBadge(false)
                    enableVibration(false)
                    setSound(null, null)
                },
            )
        }
        val cronometro = abertas.any { it.tipo == "cronometro" }
        val texto = if (cronometro || abertas.isEmpty()) {
            TextosNativos.texto(this, "cronometroServicoAtivo", R.string.cronometro_servico_ativo)
        } else {
            TextosNativos.texto(this, "despertadorServicoAtivo", R.string.despertador_servico_ativo)
        }
        val abrir = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, ID_NOTIFICACAO, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        return NotificationCompat.Builder(this, CANAL)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(texto)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .apply { abrir?.let { setContentIntent(it) } }
            .build()
    }

    private fun atualizarNotificacao(abertas: List<VigiaLocalizacao.Janela>) {
        try {
            getSystemService(NotificationManager::class.java)?.notify(ID_NOTIFICACAO, notificacao(abertas))
            wakeLock?.acquire(3 * 60_000L)
        } catch (_: Exception) {
        }
    }

    private fun entrarEmPrimeiroPlano(): Boolean = try {
        val n = notificacao(VigiaLocalizacao.abertas(this))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID_NOTIFICACAO, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(ID_NOTIFICACAO, n)
        }
        true
    } catch (e: Exception) {
        Log.w(TAG, "startForeground (location) recusado: $e")
        false
    }
}
