package com.example.security_check_app

import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import androidx.preference.PreferenceManager
import io.flutter.embedding.engine.FlutterEngine

/**
 * Activity nativa DEDICADA a exibir, com o som do alarme de rotina
 * tocando em LOOP e por cima do Keyguard/lockscreen, a tela de
 * confirmação "Cheguei bem" quando um alarme de check-in de ROTINA
 * dispara (ver [RotinaAlarmeService]/`_callbackCheckinRotina`) —
 * inclusive com o aparelho bloqueado ou o app completamente fechado.
 *
 * MOTIVAÇÃO ARQUITETURAL: idêntica à de [LockscreenCameraActivity] —
 * uma notificação local (`flutter_local_notifications`) sozinha não é
 * suficiente para sobrepor o Keyguard nem para tocar um som em loop de
 * forma confiável enquanto aguarda a interação do usuário. Iniciar esta
 * Activity diretamente via [Intent] — agora também a partir de
 * [RotinaAlarmWakeService], um caminho 100% nativo que sobrevive ao
 * Doze/deep sleep — com as flags de Keyguard aplicadas no PRÓPRIO
 * [onCreate] (ver abaixo; NÃO são herdadas de [MainActivity], que não
 * define nenhuma), garante que a tela de confirmação (com o botão
 * "Pausar Alarme"/"Cheguei bem") realmente apareça por cima da tela
 * bloqueada, e que o alerta sonoro do check-in de rotina toque mesmo com
 * a tela apagada.
 *
 * SOM EM LOOP (MediaPlayer nativo): esta Activity é responsável por
 * tocar, ela mesma, o som de alarme em loop assim que é criada
 * ([onCreate]), usando o mesmo asset de áudio configurado pelo usuário
 * em Configurações (`assets/sounds/som_1.mp3` ... `som_10.mp3`, ver
 * [AlarmeSonoroService]). O som é interrompido via [RotinaAlarmSomBridge]
 * (ver [RotinaAlarmPlugin]), chamado pelo lado Dart assim que o PIN
 * correto for digitado ou o botão "Cancelar"/"Pausar Alarme" for tocado
 * no `pin_dialog.dart`.
 *
 * ROTA INICIAL PARA O FLUTTER: o extra/rota [ROTA_INICIAL_ROTINA_ALARME]
 * é lido no lado Dart (`main.dart`) para navegar diretamente para a
 * tela de confirmação de check-in de rotina, exibindo o diálogo de PIN
 * com o botão "Cancelar"/"Pausar Alarme" (ver `pin_dialog.dart`,
 * parâmetro `mostrarBotaoCancelar`).
 *
 * Reaproveita o MESMO engine em cache (`FlutterEngineCache`) que a
 * [MainActivity] usa, através do `provideFlutterEngine` herdado do
 * próprio Flutter embedding — os plugins locais registrados em
 * [MainActivity.configureFlutterEngine] continuam disponíveis
 * normalmente aqui, já que esta Activity ESTENDE [MainActivity] em vez
 * de duplicar a lógica de registro de plugins.
 */
class RotinaCheckinAlarmActivity : MainActivity() {

    /** Player nativo responsável por tocar o som do alarme de rotina em
     * loop enquanto esta Activity estiver visível. Registrado em
     * [RotinaAlarmSomBridge] logo após ser criado, permitindo que o lado
     * Dart o interrompa remotamente via MethodChannel
     * ("pausarAlarme", ver [RotinaAlarmPlugin]). */
    private var mediaPlayer: MediaPlayer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        RotinaAlarmPlugin.registrarActivity(this)
        super.onCreate(savedInstanceState)

        // CORREÇÃO (bug real de Doze/lockscreen): MainActivity NÃO define
        // nenhuma flag de Keyguard programaticamente — ela conta apenas
        // com os atributos declarativos do AndroidManifest
        // (`showWhenLocked`/`turnScreenOn`), que se mostraram
        // insuficientes em testes reais com o aparelho bloqueado por
        // vários minutos (Doze). Aplicamos aqui, explicitamente, o MESMO
        // padrão já validado em [LockscreenCameraActivity] para o fluxo
        // de SOS: `setShowWhenLocked`/`setTurnScreenOn` (API 27+) com
        // fallback de flags de Window para versões antigas, garantindo
        // que a tela do alarme SEMPRE apareça por cima do bloqueio e
        // ACENDA o aparelho, mesmo vindo de uma Activity criada por um
        // Service em segundo plano (ver [RotinaAlarmWakeService]).
        //
        // Propositalmente NÃO chamamos requestDismissKeyguard()/
        // FLAG_DISMISS_KEYGUARD (mesma decisão de LockscreenCameraActivity):
        // em aparelhos com bloqueio seguro (PIN/padrão/senha do sistema),
        // isso acionaria a tela de autenticação NATIVA do Android por
        // cima da nossa — confuso e desnecessário, já que o teclado de
        // PIN do próprio app já cumpre esse papel.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Impede que o teclado virtual do sistema suba automaticamente
        // por cima da tela de confirmação de check-in ao abrir esta
        // Activity diretamente por cima do Keyguard.
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)

        iniciarSomEmLoop()
    }

    /**
     * Inicia a reprodução do som de alarme (número 1, "Bipe Clássico",
     * usado como padrão neste MVP nativo) em LOOP contínuo, protegido
     * por try/catch para NUNCA impedir a exibição da tela de
     * confirmação caso o asset de áudio esteja ausente/inválido
     * (ex: placeholder vazio, ver `assets/sounds/README.md`).
     */
    private fun iniciarSomEmLoop() {
        try {
            val prefs = PreferenceManager.getDefaultSharedPreferences(this)
            val soundPath = prefs.getString("alarm_sound_path", "som_1.mp3")
            val durationSeconds = prefs.getInt("alarm_sound_duration", 30) // Padrão 30s

            val descritor = assets.openFd("flutter_assets/assets/sounds/$soundPath")
            val novoPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(descritor.fileDescriptor, descritor.startOffset, descritor.length)
                descritor.close()
                isLooping = true
                prepare()
                start()
                setVolume(1.0f, 1.0f)
            }
            mediaPlayer = novoPlayer
            RotinaAlarmSomBridge.registrarPlayer(novoPlayer)

            // Agendar parada automática após duração configurada.
            // CORREÇÃO (crash real observado em teste, IllegalStateException
            // em MediaPlayer.stop()): esta closure referencia [novoPlayer]
            // (uma val LOCAL, capturada no instante em que este método foi
            // chamado) em vez do campo mutável [mediaPlayer] — evita tentar
            // parar/liberar um player DIFERENTE (mais novo) caso
            // [reiniciarSom] tenha substituído [mediaPlayer] entretanto
            // (ex: a janela final "tocando novamente" antes destes 30s
            // originais terminarem). Também protege .stop() e .release()
            // em blocos try/catch SEPARADOS: se o player já tiver sido
            // parado/liberado por outro caminho (ex: MethodChannel
            // "pararAlarme" chamado enquanto este Handler ainda esperava),
            // a falha em .stop() não impede a tentativa de .release().
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    if (novoPlayer.isPlaying) {
                        novoPlayer.stop()
                    }
                } catch (e: Exception) {
                    Log.e("RotinaCheckin", "Erro ao parar som automaticamente (player já parado?)", e)
                }
                try {
                    novoPlayer.release()
                } catch (e: Exception) {
                    Log.e("RotinaCheckin", "Erro ao liberar player automaticamente", e)
                }
                // Só limpa o campo/bridge se ainda apontarem para ESTE
                // player específico — um [reiniciarSom] mais recente pode
                // já ter os substituído por um player mais novo.
                if (mediaPlayer === novoPlayer) {
                    mediaPlayer = null
                    RotinaAlarmSomBridge.registrarPlayer(null)
                }
                Log.d("RotinaCheckin", "Som interrompido após $durationSeconds segundos")
            }, durationSeconds * 1000L)
        } catch (e: Exception) {
            // Falha silenciosa: a tela de confirmação continua
            // funcionando normalmente mesmo sem áudio (ex: asset
            // placeholder vazio ou dispositivo sem suporte).
            mediaPlayer = null
        }
    }

    /**
     * Reinicia a reprodução do som de alarme em loop — chamado pelo
     * [RotinaAlarmPlugin] (método "reiniciarSomSeAtivo") quando a
     * tolerância de check-in expira e o alarme precisa "tocar
     * novamente" para a janela final de 2 minutos. Para qualquer
     * MediaPlayer ainda em execução antes de iniciar um novo, evitando
     * duas instâncias tocando simultaneamente.
     */
    fun reiniciarSom() {
        try {
            RotinaAlarmSomBridge.pararSom()
        } catch (_: Exception) {
        }
        mediaPlayer = null
        iniciarSomEmLoop()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Garante que os mesmos plugins locais (SmsSender,
        // VolumeSosPlugin, LockscreenPlugin, RotinaAlarmPlugin) sejam
        // registrados também neste engine, exatamente como na
        // MainActivity.
        super.configureFlutterEngine(flutterEngine)
    }

    /**
     * Repassa ao Flutter, através da rota inicial padrão do
     * `FlutterActivity` (`window.setInitialRoute`/`getInitialRoute`),
     * o sinal de que este cold start específico deve ir DIRETO para a
     * tela de confirmação de check-in de rotina (com o botão "Pausar
     * Alarme"). Ver `main.dart` (`_lerRotaInicialRotinaAlarme`).
     */
    override fun getInitialRoute(): String {
        return ROTA_INICIAL_ROTINA_ALARME
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Se a Activity já existir (singleTop) e um novo disparo de
        // rotina chegar enquanto ela ainda está viva, apenas reforça as
        // flags de lockscreen novamente e atualiza o idAlarme mais
        // recente através do próprio Intent — a navegação/exibição do
        // diálogo em si já é tratada pelo lado Dart via MethodChannel
        // (ver [RotinaAlarmPlugin]).
        setIntent(intent)
        idAlarmeDoIntent(intent)?.let { idAlarme ->
            RotinaAlarmEventBridge.notificarNovoDisparo(idAlarme)
        }
  }

    override fun onDestroy() {
        RotinaAlarmSomBridge.pararSom()
        mediaPlayer = null
        // 2. Remove o registro para não vazar memória
        RotinaAlarmPlugin.registrarActivity(null)
        super.onDestroy()
    }

    companion object {
        /**
         * Extra/rota especial reconhecida pelo lado Dart (`main.dart`)
         * para identificar que o app foi iniciado a partir de um
         * disparo de alarme de check-in de ROTINA com o aparelho
         * bloqueado/app fechado, devendo navegar imediatamente para a
         * tela de confirmação "Cheguei bem" (com opção de pausar o
         * alarme sonoro).
         */
        const val ROTA_INICIAL_ROTINA_ALARME = "/rotina_alarme_confirmacao"

        /** Chave do extra inteiro (id do alarme de rotina) enviado
         * junto com o [Intent] que abre esta Activity. */
        const val EXTRA_ID_ALARME = "id_alarme_rotina"

        /** Extrai o id do alarme de rotina do [intent] recebido, ou
         * `null` se ausente/inválido. */
        fun idAlarmeDoIntent(intent: Intent?): Int? {
            if (intent == null || !intent.hasExtra(EXTRA_ID_ALARME)) return null
            val valor = intent.getIntExtra(EXTRA_ID_ALARME, -1)
            return if (valor >= 0) valor else null
        }
    }
}

/**
 * Ponte estática simples usada para notificar o lado Dart (via
 * EventChannel do [RotinaAlarmPlugin]), quando esta Activity já está
 * viva e um NOVO disparo de alarme de rotina chega através de
 * `onNewIntent` (cenário em que o Flutter já está rodando e não passa
 * novamente pela rota inicial de cold start).
 */
object RotinaAlarmEventBridge {
    var eventSink: io.flutter.plugin.common.EventChannel.EventSink? = null

    fun notificarNovoDisparo(idAlarme: Int) {
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            eventSink?.success(idAlarme)
        }
    }
}
