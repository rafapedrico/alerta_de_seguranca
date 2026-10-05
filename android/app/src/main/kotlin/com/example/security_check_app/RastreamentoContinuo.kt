package com.example.security_check_app

import android.Manifest
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseAuthInvalidUserException
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
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

// Rastreamento contínuo da aba Monitoramento (Android) — equivalente ao
// `ios/Runner/RastreamentoContinuo.swift` do app iOS, com os MESMOS campos
// em `usuarios/{uid}/monitoramento/atual` e `.../estado` e os mesmos valores
// de `motivoInativo`.
//
// Foreground service do tipo `location` com o Fused Location Provider
// (PRIORITY_BALANCED_POWER_ACCURACY):
// - em movimento: leitura a cada ~1 min, grava ao andar ~150 m ou a cada
//   ~5 min;
// - parado (10 min sem sair de um raio de 150 m): leitura a cada ~15 min,
//   grava só ao sair do raio ou a cada 1 h (mantém a posição "viva" para o
//   detector de localização parada do servidor);
// - bateria abaixo de 15% e sem carregar: intervalos maiores, nunca para.
//
// O Dart liga/desliga ([RastreamentoPlugin] → `configurar`/`parar`) e passa
// o ciclo do Plano Free e as opções do Firebase; o nativo confere sozinho
// sessão, permissão "Permitir o tempo todo" e plano antes de rodar, e
// segue sem Dart depois de reiniciar o aparelho ([RastreamentoBootReceiver]).
// Gravação pela API REST do Firestore (mesmo caminho do iOS): o SDK
// nativo dividiria a instância (e as configurações) com o plugin do
// Flutter.

/** Configuração gravada pelo Dart e lida mesmo sem Dart (boot). */
data class ConfigRastreamento(
    val ativo: Boolean,
    val uid: String,
    val isPremium: Boolean,
    /** Início do ciclo do Plano Free (ms). `null` = desconhecido (liberado). */
    val cicloInicioMs: Long?,
    /** Motivo quando `ativo == false` (pausado, sem_monitores…). */
    val motivoInativo: String?,
    val temMonitorAprovado: Boolean,
    val tituloNotificacao: String,
    val textoNotificacao: String,
    val nomeCanal: String,
    val firebaseApiKey: String?,
    val firebaseAppId: String?,
    val firebaseProjectId: String?,
    val firebaseSenderId: String?,
    val firebaseStorageBucket: String?,
) {
    fun paraJson(): String = JSONObject().apply {
        put("ativo", ativo)
        put("uid", uid)
        put("isPremium", isPremium)
        put("cicloInicioMs", cicloInicioMs ?: JSONObject.NULL)
        put("motivoInativo", motivoInativo ?: JSONObject.NULL)
        put("temMonitorAprovado", temMonitorAprovado)
        put("tituloNotificacao", tituloNotificacao)
        put("textoNotificacao", textoNotificacao)
        put("nomeCanal", nomeCanal)
        put("firebaseApiKey", firebaseApiKey ?: JSONObject.NULL)
        put("firebaseAppId", firebaseAppId ?: JSONObject.NULL)
        put("firebaseProjectId", firebaseProjectId ?: JSONObject.NULL)
        put("firebaseSenderId", firebaseSenderId ?: JSONObject.NULL)
        put("firebaseStorageBucket", firebaseStorageBucket ?: JSONObject.NULL)
    }.toString()

    companion object {
        fun deJson(texto: String): ConfigRastreamento? = try {
            val j = JSONObject(texto)
            fun opcional(chave: String): String? = if (j.isNull(chave)) null else j.optString(chave)
            ConfigRastreamento(
                ativo = j.optBoolean("ativo"),
                uid = j.getString("uid"),
                isPremium = j.optBoolean("isPremium"),
                cicloInicioMs = if (j.isNull("cicloInicioMs")) null else j.optLong("cicloInicioMs"),
                motivoInativo = opcional("motivoInativo"),
                temMonitorAprovado = j.optBoolean("temMonitorAprovado"),
                tituloNotificacao = j.optString("tituloNotificacao", "Guardião-X"),
                textoNotificacao = j.optString("textoNotificacao", ""),
                nomeCanal = j.optString("nomeCanal", "Guardião-X"),
                firebaseApiKey = opcional("firebaseApiKey"),
                firebaseAppId = opcional("firebaseAppId"),
                firebaseProjectId = opcional("firebaseProjectId"),
                firebaseSenderId = opcional("firebaseSenderId"),
                firebaseStorageBucket = opcional("firebaseStorageBucket"),
            )
        } catch (e: Exception) {
            null
        }
    }
}

object RastreamentoContinuo {
    private const val TAG = "RastreamentoContinuo"
    private const val PREFS = "gx_rastreamento"
    private const val CHAVE_CONFIG = "config"
    private const val CHAVE_ULTIMA_GRAVACAO = "ultima_gravacao"
    private const val CHAVE_ESTADO_ASSINATURA = "estado_assinatura"

    /** Lido pelo Dart (SharedPreferences legado) no pedido sob demanda:
     * com o contínuo ligado, o pedido grava `rastreamentoContinuo: true`. */
    private const val PREFS_FLUTTER = "FlutterSharedPreferences"
    private const val CHAVE_FLUTTER_ATIVO = "flutter.rastreamento_continuo_ativo"

    private const val DIA_MS = 86_400_000L

    /** Uma thread só para rede: gravações saem em ordem. */
    private val executor = Executors.newSingleThreadExecutor()
    private val principal = Handler(Looper.getMainLooper())

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun carregarConfig(ctx: Context): ConfigRastreamento? =
        prefs(ctx).getString(CHAVE_CONFIG, null)?.let { ConfigRastreamento.deJson(it) }

    private fun salvarConfig(ctx: Context, config: ConfigRastreamento) {
        prefs(ctx).edit().putString(CHAVE_CONFIG, config.paraJson()).apply()
    }

    // ------------------------------------------------------------------
    // Entrada (canal / boot)
    // ------------------------------------------------------------------

    fun configurar(ctx: Context, nova: ConfigRastreamento) {
        salvarConfig(ctx, nova)
        aplicar(ctx)
    }

    /** Desliga e grava o motivo (logout, conta excluída, sessão encerrada).
     * [conclusao] roda depois de o estado "desligado" sair (ou falhar). */
    fun parar(ctx: Context, motivo: String, conclusao: (() -> Unit)? = null) {
        carregarConfig(ctx)?.let { salvarConfig(ctx, it.copy(ativo = false, motivoInativo = motivo)) }
        RastreamentoContinuoService.parar(ctx)
        marcarAtivoParaDart(ctx, false)
        gravarEstado(ctx, forcar = true, ativo = false, conclusao = conclusao)
    }

    /** Liga ou desliga o serviço conforme [motivoInativo] e grava o estado. */
    fun aplicar(ctx: Context) {
        val motivo = motivoInativo(ctx)
        if (motivo == null) {
            RastreamentoContinuoService.iniciar(ctx)
        } else {
            if (motivo == "sessao_diferente") {
                // Outra conta entrou neste aparelho sem o Dart avisar: desliga de vez.
                carregarConfig(ctx)?.takeIf { it.ativo }?.let {
                    salvarConfig(ctx, it.copy(ativo = false, motivoInativo = motivo))
                }
            }
            RastreamentoContinuoService.parar(ctx)
            marcarAtivoParaDart(ctx, false)
        }
        // Ligando: quem grava "ativo" é o serviço, quando sobe de fato (o
        // Android pode recusar o start em segundo plano).
        if (motivo != null || RastreamentoContinuoService.emExecucao) {
            gravarEstado(ctx, forcar = false, ativo = motivo == null)
        }
    }

    // ------------------------------------------------------------------
    // Decisão liga/desliga
    // ------------------------------------------------------------------

    /** Motivo para NÃO rastrear agora (`null` = pode rastrear). */
    fun motivoInativo(ctx: Context): String? {
        val config = carregarConfig(ctx) ?: return "nao_configurado"
        if (!config.ativo) return config.motivoInativo ?: "desligado"
        if (!temPermissaoTempoTodo(ctx)) return "sem_permissao_sempre"
        if (planoBloqueadoAteMs(config) != null) return "plano_free"
        val usuario = auth(ctx)?.currentUser ?: return "sem_sessao"
        if (usuario.uid != config.uid) return "sessao_diferente"
        return null
    }

    fun temPermissaoTempoTodo(ctx: Context): Boolean {
        val primeiroPlano = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        if (!primeiroPlano) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }

    /** Dias 11–30 do ciclo do Plano Free (sem Premium): fim do bloqueio. */
    fun planoBloqueadoAteMs(config: ConfigRastreamento?): Long? {
        if (config == null || config.isPremium) return null
        val inicio = config.cicloInicioMs ?: return null
        val dia = ((System.currentTimeMillis() - inicio) / DIA_MS).toInt() + 1
        if (dia <= 10 || dia > 30) return null
        return inicio + 30 * DIA_MS
    }

    private fun marcarAtivoParaDart(ctx: Context, ativo: Boolean) {
        ctx.applicationContext.getSharedPreferences(PREFS_FLUTTER, Context.MODE_PRIVATE)
            .edit().putBoolean(CHAVE_FLUTTER_ATIVO, ativo).apply()
    }

    fun aoIniciarServico(ctx: Context) = marcarAtivoParaDart(ctx, true)

    // ------------------------------------------------------------------
    // Firebase (sessão e token)
    // ------------------------------------------------------------------

    /** Depois de reiniciar o aparelho o Dart não roda: inicializa o app
     * padrão com as MESMAS opções que o Dart usa (`firebase_options.dart`,
     * repassadas no `configurar`) — o FlutterFire reaproveita esse app. */
    private fun garantirFirebase(ctx: Context): FirebaseApp? {
        FirebaseApp.getApps(ctx).firstOrNull { it.name == FirebaseApp.DEFAULT_APP_NAME }?.let { return it }
        val config = carregarConfig(ctx) ?: return null
        val apiKey = config.firebaseApiKey ?: return null
        val appId = config.firebaseAppId ?: return null
        return try {
            val opcoes = FirebaseOptions.Builder()
                .setApiKey(apiKey)
                .setApplicationId(appId)
                .apply {
                    config.firebaseProjectId?.let { setProjectId(it) }
                    config.firebaseSenderId?.let { setGcmSenderId(it) }
                    config.firebaseStorageBucket?.let { setStorageBucket(it) }
                }
                .build()
            FirebaseApp.initializeApp(ctx.applicationContext, opcoes)
        } catch (e: IllegalStateException) {
            // Inicializado por outra thread (o FlutterFire) neste instante.
            FirebaseApp.getInstance()
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao inicializar o Firebase: $e")
            null
        }
    }

    private fun auth(ctx: Context): FirebaseAuth? =
        garantirFirebase(ctx)?.let { FirebaseAuth.getInstance(it) }

    private class SemSessao(val motivo: String, val definitiva: Boolean) : Exception(motivo)

    /** Token da sessão desta conta (thread de rede). [exigirContaConfigurada]:
     * gravações do rastreamento só valem para a conta que o ligou. */
    private fun token(ctx: Context, forcarRenovacao: Boolean = false): Triple<String, String, String> {
        val app = garantirFirebase(ctx) ?: throw SemSessao("Firebase indisponível", false)
        val usuario = FirebaseAuth.getInstance(app).currentUser ?: throw SemSessao("sem sessão", false)
        val config = carregarConfig(ctx)
        if (config != null && config.uid != usuario.uid) throw SemSessao("sessão de outra conta", false)
        val projeto = app.options.projectId ?: throw SemSessao("sem projectId", false)
        val resultado = try {
            Tasks.await(usuario.getIdToken(forcarRenovacao), 20, TimeUnit.SECONDS)
        } catch (e: Exception) {
            val causa = e.cause ?: e
            if (causa is FirebaseAuthInvalidUserException) {
                // Conta apagada/desativada ou sessão revogada por login em
                // outro aparelho: desliga de vez.
                val motivo = if (causa.errorCode == "ERROR_USER_NOT_FOUND") "conta_excluida" else "sessao_encerrada"
                throw SemSessao(motivo, true)
            }
            throw SemSessao("sem token: $causa", false)
        }
        val token = resultado.token ?: throw SemSessao("token vazio", false)
        return Triple(usuario.uid, token, projeto)
    }

    /** Sessão encerrada de vez: grava o motivo e para (sem conseguir avisar
     * o servidor — o token não vale mais). */
    private fun encerrarPorSessao(ctx: Context, motivo: String) {
        principal.post {
            carregarConfig(ctx)?.takeIf { it.ativo }?.let {
                salvarConfig(ctx, it.copy(ativo = false, motivoInativo = motivo))
            }
            RastreamentoContinuoService.parar(ctx)
            marcarAtivoParaDart(ctx, false)
        }
    }

    // ------------------------------------------------------------------
    // Firestore (REST)
    // ------------------------------------------------------------------

    private fun commit(projeto: String, token: String, escritas: JSONArray): Pair<Int, String> {
        val url = URL("https://firestore.googleapis.com/v1/projects/$projeto/databases/(default)/documents:commit")
        val conexao = url.openConnection() as HttpURLConnection
        return try {
            conexao.requestMethod = "POST"
            conexao.connectTimeout = 20_000
            conexao.readTimeout = 20_000
            conexao.doOutput = true
            conexao.setRequestProperty("Authorization", "Bearer $token")
            conexao.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            conexao.outputStream.use { it.write(JSONObject().put("writes", escritas).toString().toByteArray()) }
            val codigo = conexao.responseCode
            val corpo = (if (codigo in 200..299) conexao.inputStream else conexao.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            Pair(codigo, corpo.take(160))
        } finally {
            conexao.disconnect()
        }
    }

    /** Commit com uma nova tentativa de token renovado em 401/403. */
    private fun commitAutenticado(ctx: Context, montar: (uid: String, base: String) -> JSONArray): Boolean {
        var tentativa = 0
        while (tentativa < 2) {
            val (uid, token, projeto) = token(ctx, forcarRenovacao = tentativa > 0)
            val base = "projects/$projeto/databases/(default)/documents/usuarios/$uid"
            val (codigo, corpo) = commit(projeto, token, montar(uid, base))
            if (codigo in 200..299) return true
            Log.w(TAG, "Firestore recusou ($codigo): $corpo")
            if (codigo != 401 && codigo != 403) return false
            tentativa++
        }
        return false
    }

    private fun horarioServidor(): JSONArray = JSONArray().put(
        JSONObject().put("fieldPath", "atualizadoEm").put("setToServerValue", "REQUEST_TIME")
    )

    private fun escritaComMascara(nome: String, campos: JSONObject): JSONObject {
        val chaves = JSONArray()
        campos.keys().forEach { chaves.put(it) }
        return JSONObject()
            .put("update", JSONObject().put("name", nome).put("fields", campos))
            .put("updateMask", JSONObject().put("fieldPaths", chaves))
            .put("updateTransforms", horarioServidor())
    }

    private fun duplo(v: Double) = JSONObject().put("doubleValue", v)
    private fun texto(v: String) = JSONObject().put("stringValue", v)
    private fun booleano(v: Boolean) = JSONObject().put("booleanValue", v)

    /** Grava a posição (merge) em `usuarios/{uid}` e `.../monitoramento/atual`. */
    fun gravarPosicao(ctx: Context, local: Location, origem: String, conclusao: (Boolean) -> Unit) {
        val config = carregarConfig(ctx)
        if (planoBloqueadoAteMs(config) != null) {
            conclusao(false)
            return
        }
        executor.execute {
            val ok = try {
                commitAutenticado(ctx) { _, base ->
                    val usuario = JSONObject()
                        .put("latitude", duplo(local.latitude))
                        .put("longitude", duplo(local.longitude))
                    val atual = JSONObject()
                        .put("latitude", duplo(local.latitude))
                        .put("longitude", duplo(local.longitude))
                        .put("precisao", duplo(local.accuracy.toDouble()))
                        .put("origem", texto(origem))
                        .put("plataforma", texto("android"))
                        .put("rastreamentoContinuo", booleano(true))
                    JSONArray()
                        .put(escritaComMascara(base, usuario))
                        .put(escritaComMascara("$base/monitoramento/atual", atual))
                }
            } catch (e: SemSessao) {
                Log.w(TAG, "Posição não gravada: ${e.motivo}")
                if (e.definitiva) encerrarPorSessao(ctx, e.motivo)
                false
            } catch (e: Exception) {
                Log.w(TAG, "Posição não gravada: $e")
                false
            }
            if (ok) marcarGravacao(ctx, local)
            principal.post { conclusao(ok) }
        }
    }

    // ------------------------------------------------------------------
    // Última gravação (limites de frequência)
    // ------------------------------------------------------------------

    fun ultimaGravacao(ctx: Context): Triple<Long, Double, Double>? {
        val texto = prefs(ctx).getString(CHAVE_ULTIMA_GRAVACAO, null) ?: return null
        return try {
            val j = JSONObject(texto)
            Triple(j.getLong("ts"), j.getDouble("lat"), j.getDouble("lng"))
        } catch (e: Exception) {
            null
        }
    }

    private fun marcarGravacao(ctx: Context, local: Location) {
        prefs(ctx).edit().putString(
            CHAVE_ULTIMA_GRAVACAO,
            JSONObject().put("ts", System.currentTimeMillis()).put("lat", local.latitude)
                .put("lng", local.longitude).toString()
        ).apply()
    }

    // ------------------------------------------------------------------
    // Estado (usuarios/{uid}/monitoramento/estado)
    // ------------------------------------------------------------------

    fun estadoCampos(ctx: Context, ativo: Boolean = RastreamentoContinuoService.emExecucao): Map<String, Any?> {
        val fina = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val grossa = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val permissao = when {
            temPermissaoTempoTodo(ctx) -> "sempre"
            fina || grossa -> "durante_uso"
            else -> "negada"
        }
        val energia = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val atividade = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val restritoEmSegundoPlano = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            atividade?.isBackgroundRestricted == true
        return mapOf(
            "permissao" to permissao,
            "precisaoExata" to fina,
            // Sem Movimento e Condicionamento no Android: o Fused Location
            // Provider já reduz o GPS parado.
            "movimento" to "indisponivel",
            "atualizacaoSegundoPlano" to !restritoEmSegundoPlano,
            "otimizacaoBateriaIgnorada" to (energia?.isIgnoringBatteryOptimizations(ctx.packageName) == true),
            "modoPoucaEnergia" to (energia?.isPowerSaveMode == true),
            "rastreamentoAtivo" to ativo,
            "motivoInativo" to (if (ativo) null else motivoInativo(ctx)),
            "bloqueadoAte" to planoBloqueadoAteMs(carregarConfig(ctx)),
        )
    }

    /** Grava o estado quando muda (ou a cada 6 h). Sem sessão, não grava. */
    fun gravarEstado(
        ctx: Context,
        forcar: Boolean,
        ativo: Boolean = RastreamentoContinuoService.emExecucao,
        conclusao: (() -> Unit)? = null,
    ) {
        // Quem nunca ligou o rastreamento não grava nada.
        if (carregarConfig(ctx) == null) {
            conclusao?.invoke()
            return
        }
        val campos = estadoCampos(ctx, ativo)
        val assinatura = campos.keys.sorted().joinToString(";") { "$it=${campos[it]}" }
        val anterior = prefs(ctx).getString(CHAVE_ESTADO_ASSINATURA, null)?.let {
            try { JSONObject(it) } catch (e: Exception) { null }
        }
        if (!forcar && anterior?.optString("assinatura") == assinatura &&
            System.currentTimeMillis() - (anterior.optLong("ts")) < 6 * 3_600_000L
        ) {
            conclusao?.invoke()
            return
        }
        executor.execute {
            val ok = try {
                commitAutenticado(ctx) { _, base ->
                    val fields = JSONObject().put("plataforma", texto("android"))
                    for ((chave, valor) in campos) {
                        fields.put(chave, when {
                            valor is Boolean -> booleano(valor)
                            valor is String -> texto(valor)
                            valor is Long && chave == "bloqueadoAte" ->
                                JSONObject().put("timestampValue", iso8601(valor))
                            else -> JSONObject().put("nullValue", JSONObject.NULL)
                        })
                    }
                    JSONArray().put(
                        JSONObject()
                            .put("update", JSONObject().put("name", "$base/monitoramento/estado").put("fields", fields))
                            .put("updateTransforms", horarioServidor())
                    )
                }
            } catch (e: SemSessao) {
                if (e.definitiva) encerrarPorSessao(ctx, e.motivo)
                false
            } catch (e: Exception) {
                Log.w(TAG, "Estado não gravado: $e")
                false
            }
            if (ok) {
                prefs(ctx).edit().putString(
                    CHAVE_ESTADO_ASSINATURA,
                    JSONObject().put("assinatura", assinatura).put("ts", System.currentTimeMillis()).toString()
                ).apply()
            }
            principal.post { conclusao?.invoke() }
        }
    }

    private fun iso8601(ms: Long): String {
        val formato = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        formato.timeZone = TimeZone.getTimeZone("UTC")
        return formato.format(Date(ms))
    }
}

/**
 * Foreground service (tipo `location`) que lê o Fused Location Provider e
 * grava a posição — ver o cabeçalho do arquivo para os limites.
 */
class RastreamentoContinuoService : Service() {

    companion object {
        private const val TAG = "RastreamentoContinuo"
        private const val CANAL = "gx_rastreamento_continuo"
        private const val ID_NOTIFICACAO = 47_150

        private const val RAIO_MOVIMENTO_M = 150f
        private const val PRECISAO_MAXIMA_M = 1500f
        private const val PARADO_APOS_MS = 10 * 60_000L

        @Volatile
        var emExecucao = false
            private set

        fun iniciar(ctx: Context) {
            if (emExecucao) {
                // Já em primeiro plano: só a notificação muda (ex.: número
                // de contatos). Um novo startForegroundService com o app em
                // segundo plano pode ser recusado (Android 12+).
                atualizarNotificacao(ctx)
                return
            }
            val intent = Intent(ctx, RastreamentoContinuoService::class.java)
            try {
                ContextCompat.startForegroundService(ctx, intent)
            } catch (e: Exception) {
                // Android 12+: start em segundo plano negado (ex.: sem
                // "Permitir o tempo todo"). Fica para a próxima abertura.
                Log.w(TAG, "Não foi possível iniciar o serviço: $e")
            }
        }

        fun parar(ctx: Context) {
            if (!emExecucao) return
            ctx.stopService(Intent(ctx, RastreamentoContinuoService::class.java))
        }

        fun atualizarNotificacao(ctx: Context) {
            try {
                ctx.getSystemService(NotificationManager::class.java)
                    ?.notify(ID_NOTIFICACAO, montarNotificacao(ctx))
            } catch (_: Exception) {}
        }

        fun montarNotificacao(ctx: Context): Notification {
            val config = RastreamentoContinuo.carregarConfig(ctx)
            val gerente = ctx.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && gerente != null) {
                val canal = NotificationChannel(
                    CANAL, config?.nomeCanal ?: "Guardião-X", NotificationManager.IMPORTANCE_LOW
                ).apply {
                    setShowBadge(false)
                    enableVibration(false)
                    setSound(null, null)
                }
                gerente.createNotificationChannel(canal)
            }
            val abrir = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.let {
                PendingIntent.getActivity(
                    ctx, ID_NOTIFICACAO, it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            }
            return NotificationCompat.Builder(ctx, CANAL)
                .setSmallIcon(ctx.applicationInfo.icon)
                .setContentTitle(config?.tituloNotificacao ?: "Guardião-X")
                .setContentText(config?.textoNotificacao.orEmpty())
                .setStyle(NotificationCompat.BigTextStyle().bigText(config?.textoNotificacao.orEmpty()))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .apply { abrir?.let { setContentIntent(it) } }
                .build()
        }
    }

    private enum class Modo { MOVIMENTO, PARADO }

    private lateinit var fused: FusedLocationProviderClient
    private var modo = Modo.MOVIMENTO
    private var bateriaBaixa = false
    private var atualizacoesLigadas = false

    /** Âncora do raio de 150 m: onde e quando saiu dele pela última vez. */
    private var ancora: Location? = null
    private var ultimoDeslocamentoMs = 0L
    private var gravando = false

    private val callback = object : LocationCallback() {
        override fun onLocationResult(resultado: LocationResult) {
            resultado.lastLocation?.let { processar(it) }
        }
    }

    private val receptorBateria = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val baixa = calcularBateriaBaixa(intent)
            if (baixa != bateriaBaixa) {
                bateriaBaixa = baixa
                pedirAtualizacoes()
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        fused = LocationServices.getFusedLocationProviderClient(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!entrarEmPrimeiroPlano()) {
            stopSelf()
            return START_NOT_STICKY
        }
        val motivo = RastreamentoContinuo.motivoInativo(this)
        if (motivo != null) {
            Log.i(TAG, "Serviço iniciado sem condição de rodar: $motivo")
            stopSelf()
            return START_NOT_STICKY
        }
        if (!emExecucao) {
            emExecucao = true
            RastreamentoContinuo.aoIniciarServico(this)
            val bateria = registerReceiver(receptorBateria, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            bateriaBaixa = bateria?.let { calcularBateriaBaixa(it) } ?: false
            modo = Modo.MOVIMENTO
            ultimoDeslocamentoMs = System.currentTimeMillis()
            pedirAtualizacoes()
            RastreamentoContinuo.gravarEstado(this, forcar = false, ativo = true)
            Log.i(TAG, "Rastreamento contínuo ligado.")
        } else {
            // Nova configuração (ex.: mudou o número de contatos): só a notificação.
            atualizarNotificacao(this)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        if (emExecucao) {
            emExecucao = false
            try { unregisterReceiver(receptorBateria) } catch (_: Exception) {}
            fused.removeLocationUpdates(callback)
            atualizacoesLigadas = false
            RastreamentoContinuo.gravarEstado(this, forcar = false, ativo = false)
            Log.i(TAG, "Rastreamento contínuo desligado.")
        }
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Notificação fixa
    // ------------------------------------------------------------------

    private fun entrarEmPrimeiroPlano(): Boolean = try {
        val notificacao = montarNotificacao(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID_NOTIFICACAO, notificacao, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(ID_NOTIFICACAO, notificacao)
        }
        true
    } catch (e: Exception) {
        // Sem permissão de localização (SecurityException) ou start em
        // segundo plano negado (Android 12+/14+).
        Log.w(TAG, "startForeground recusado: $e")
        false
    }

    // ------------------------------------------------------------------
    // Localização
    // ------------------------------------------------------------------

    private fun calcularBateriaBaixa(intent: Intent): Boolean {
        val nivel = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val escala = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val carregando = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        if (nivel < 0 || escala <= 0) return false
        return !carregando && nivel * 100 / escala < 15
    }

    /** Intervalo de leitura por modo (bateria baixa: mais espaçado). */
    private fun intervaloLeituraMs(): Long = when (modo) {
        Modo.MOVIMENTO -> if (bateriaBaixa) 3 * 60_000L else 60_000L
        Modo.PARADO -> if (bateriaBaixa) 30 * 60_000L else 15 * 60_000L
    }

    /** Grava ao menos a cada X em movimento. */
    private fun intervaloGravacaoMovimentoMs(): Long = if (bateriaBaixa) 10 * 60_000L else 5 * 60_000L

    /** Grava ao menos a cada X parado (posição "viva" para o servidor). */
    private fun intervaloGravacaoParadoMs(): Long = if (bateriaBaixa) 2 * 3_600_000L else 3_600_000L

    /** Entre gravações por deslocamento. */
    private fun intervaloMinimoGravacaoMs(): Long = if (bateriaBaixa) 3 * 60_000L else 60_000L

    private fun pedirAtualizacoes() {
        if (!emExecucao) return
        val intervalo = intervaloLeituraMs()
        val pedido = LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, intervalo)
            .setMinUpdateIntervalMillis(intervalo / 2)
            .setMaxUpdateDelayMillis(intervalo)
            .build()
        try {
            if (atualizacoesLigadas) fused.removeLocationUpdates(callback)
            fused.requestLocationUpdates(pedido, callback, Looper.getMainLooper())
            atualizacoesLigadas = true
            Log.i(TAG, "Leituras: modo=$modo, a cada ${intervalo / 1000}s, bateriaBaixa=$bateriaBaixa")
        } catch (e: SecurityException) {
            // Permissão retirada com o serviço rodando.
            Log.w(TAG, "Sem permissão de localização: $e")
            RastreamentoContinuo.aplicar(this)
        }
    }

    private fun processar(local: Location) {
        if (!emExecucao) return
        if (!local.hasAccuracy() || local.accuracy > PRECISAO_MAXIMA_M) return
        // Permissão ou plano mudaram com o serviço rodando.
        if (RastreamentoContinuo.motivoInativo(this) != null) {
            RastreamentoContinuo.aplicar(this)
            return
        }
        val agora = System.currentTimeMillis()

        // Movimento: saiu do raio de 150 m da âncora?
        val ancoraAtual = ancora
        if (ancoraAtual == null || ancoraAtual.distanceTo(local) >= RAIO_MOVIMENTO_M) {
            ancora = local
            ultimoDeslocamentoMs = agora
            if (modo == Modo.PARADO) {
                modo = Modo.MOVIMENTO
                pedirAtualizacoes()
            }
        } else if (modo == Modo.MOVIMENTO && agora - ultimoDeslocamentoMs >= PARADO_APOS_MS) {
            modo = Modo.PARADO
            pedirAtualizacoes()
        }

        if (gravando || !deveGravar(local, agora)) return
        gravando = true
        RastreamentoContinuo.gravarPosicao(this, local, "continuo") { ok ->
            gravando = false
            Log.i(TAG, if (ok) "Posição gravada (modo=$modo)." else "Posição não gravada.")
        }
        RastreamentoContinuo.gravarEstado(this, forcar = false, ativo = true)
    }

    private fun deveGravar(local: Location, agora: Long): Boolean {
        val (ts, lat, lng) = RastreamentoContinuo.ultimaGravacao(this) ?: return true
        val decorrido = agora - ts
        if (decorrido < 0) return true
        val distancia = FloatArray(1).also { Location.distanceBetween(lat, lng, local.latitude, local.longitude, it) }[0]
        if (distancia >= RAIO_MOVIMENTO_M && decorrido >= intervaloMinimoGravacaoMs()) return true
        if (modo == Modo.MOVIMENTO && decorrido >= intervaloGravacaoMovimentoMs()) return true
        return decorrido >= intervaloGravacaoParadoMs()
    }
}

/** Religa o rastreamento depois de reiniciar o aparelho (ou atualizar o
 * app), se estava ligado — sem abrir o app. */
class RastreamentoBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                val config = RastreamentoContinuo.carregarConfig(context) ?: return
                if (!config.ativo) return
                RastreamentoContinuo.aplicar(context)
            }
        }
    }
}

/** Canal "guardiaox/rastreamento" (ver lib/services/rastreamento_continuo_service.dart). */
class RastreamentoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var canal: MethodChannel? = null
    private var contexto: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        contexto = binding.applicationContext
        canal = MethodChannel(binding.binaryMessenger, "guardiaox/rastreamento").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        canal?.setMethodCallHandler(null)
        canal = null
        contexto = null
    }

    override fun onMethodCall(chamada: MethodCall, resultado: MethodChannel.Result) {
        val ctx = contexto ?: return resultado.error("sem_contexto", null, null)
        when (chamada.method) {
            "configurar" -> {
                val uid = chamada.argument<String>("uid")
                    ?: return resultado.error("args", "uid ausente", null)
                RastreamentoContinuo.configurar(
                    ctx,
                    ConfigRastreamento(
                        ativo = chamada.argument<Boolean>("ativo") ?: false,
                        uid = uid,
                        isPremium = chamada.argument<Boolean>("isPremium") ?: false,
                        cicloInicioMs = chamada.argument<Number>("cicloInicioMs")?.toLong(),
                        motivoInativo = chamada.argument<String>("motivoInativo"),
                        temMonitorAprovado = chamada.argument<Boolean>("temMonitorAprovado") ?: false,
                        tituloNotificacao = chamada.argument<String>("tituloNotificacao") ?: "Guardião-X",
                        textoNotificacao = chamada.argument<String>("textoNotificacao") ?: "",
                        nomeCanal = chamada.argument<String>("nomeCanal") ?: "Guardião-X",
                        firebaseApiKey = chamada.argument<String>("firebaseApiKey"),
                        firebaseAppId = chamada.argument<String>("firebaseAppId"),
                        firebaseProjectId = chamada.argument<String>("firebaseProjectId"),
                        firebaseSenderId = chamada.argument<String>("firebaseSenderId"),
                        firebaseStorageBucket = chamada.argument<String>("firebaseStorageBucket"),
                    )
                )
                resultado.success(estadoComAtivoPrevisto(ctx))
            }
            "parar" -> {
                RastreamentoContinuo.parar(ctx, chamada.argument<String>("motivo") ?: "desligado") {
                    resultado.success(null)
                }
            }
            "estado" -> resultado.success(estadoComAtivoPrevisto(ctx))
            else -> resultado.notImplemented()
        }
    }

    /** Logo depois do `configurar` o serviço ainda está subindo: o
     * "ativo" vem da decisão, não de o serviço já estar rodando. */
    private fun estadoComAtivoPrevisto(ctx: Context): Map<String, Any?> {
        val ativo = RastreamentoContinuoService.emExecucao || RastreamentoContinuo.motivoInativo(ctx) == null
        return RastreamentoContinuo.estadoCampos(ctx, ativo)
    }
}
