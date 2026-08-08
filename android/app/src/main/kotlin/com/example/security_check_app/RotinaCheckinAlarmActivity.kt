package com.example.security_check_app

import android.content.Intent
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
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
 * ÁUDIO: especificação do usuário (2026-08-07, item 1) — toca APENAS o
 * som customizado escolhido em Configurações, SEM nenhuma reprodução
 * paralela. Essa é responsabilidade EXCLUSIVA do `AudioPlayer` Dart em
 * [AlarmeDisparadoScreen._tocarSomDoAlarme] (o único que lê de verdade a
 * preferência do usuário, com múltiplos fallbacks). Este `MediaPlayer`
 * nativo, que existia aqui antes, foi DESATIVADO de propósito
 * ([iniciarSomEmLoop] virou no-op): ele lia a chave nativa
 * `alarm_sound_path` via `PreferenceManager.getDefaultSharedPreferences`
 * — um arquivo de preferências DIFERENTE do `FlutterSharedPreferences`
 * usado pelo plugin `shared_preferences` do lado Dart — e por isso
 * NUNCA era realmente atualizado com a escolha do usuário, tocando
 * sempre "som_1.mp3" fixo em paralelo com o som Dart correto (o
 * "áudio duplicado/paralelo" relatado). [RotinaAlarmSomBridge]/os
 * métodos nativos "pararAlarme"/"silenciarSomSemFechar" continuam
 * existindo e são seguros de chamar (viram no-op sem player nenhum
 * registrado), preservando a mesma interface para o resto do código.
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

        // NÃO chama mais iniciarSomEmLoop() — ver comentário da classe
        // (item 1): o som é responsabilidade exclusiva do AudioPlayer
        // Dart, nunca deste MediaPlayer nativo.
    }

    /**
     * DESATIVADO de propósito (item 1 — ver comentário da classe): não
     * cria mais nenhum `MediaPlayer`. Mantido como método vazio (em vez
     * de removido) só para minimizar o diff nos pontos que ainda o
     * chamam ([reiniciarSom]) — nenhum som nativo volta a tocar a partir
     * daqui.
     */
    private fun iniciarSomEmLoop() {
        mediaPlayer = null
    }

    /**
     * DESATIVADO de propósito (item 1): não reinicia mais nenhum som
     * nativo. Mantido como no-op seguro porque [RotinaAlarmPlugin]
     * ("reiniciarSomSeAtivo") ainda pode chamá-lo — o reforço sonoro da
     * janela final agora é feito 100% pelo AudioPlayer Dart (ver
     * [AlarmeDisparadoScreen._entrarNaFaseFinal]).
     */
    fun reiniciarSom() {
        try {
            RotinaAlarmSomBridge.pararSom()
        } catch (_: Exception) {
        }
        mediaPlayer = null
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
