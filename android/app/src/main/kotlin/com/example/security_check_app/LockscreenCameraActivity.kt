package com.example.security_check_app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine

/**
 * Activity nativa DEDICADA a forçar a abertura do app por cima do
 * Keyguard/lockscreen quando o gatilho físico de SOS (Volume+ 3x em
 * até 3s) é detectado pelo [VolumeSosService] rodando em SEGUNDO PLANO
 * — inclusive nos cenários mais agressivos em que o app já foi
 * completamente fechado pelo usuário/sistema (apenas o próprio
 * Foreground Service permanece vivo) e a `MainActivity` original não
 * existe mais em memória.
 *
 * MOTIVAÇÃO ARQUITETURAL (Android 14/15): em builds recentes do
 * Android, disparar apenas um `Navigator.push` do lado Dart (via
 * `appNavigatorKey`, como faz [CapturaDissuasaoService]) NÃO é
 * suficiente para sobrepor o Keyguard quando não existe nenhuma
 * Activity/Window do app já visível na tela — o sistema simplesmente
 * ignora silenciosamente a navegação, pois ela não passa por nenhuma
 * das APIs de janela do Android (`setShowWhenLocked`/`setTurnScreenOn`/
 * `requestDismissKeyguard`) que exigem uma Activity REAL sendo criada
 * pelo próprio Android via `startActivity()`.
 *
 * Por isso, esta Activity é iniciada DIRETAMENTE via `Intent` a partir
 * do [VolumeSosService] (ver `VolumeSosService.processarMudancaDeVolume`),
 * com as flags `FLAG_ACTIVITY_NEW_TASK`/`FLAG_ACTIVITY_CLEAR_TOP`/
 * `FLAG_ACTIVITY_SINGLE_TOP`, garantindo que o Android crie (ou traga
 * ao topo) uma Activity nova do zero, aplicando as flags de lockscreen
 * em seu `onCreate()` — herdadas diretamente de [MainActivity], que já
 * implementa toda essa lógica (`setShowWhenLocked`/`setTurnScreenOn`/
 * `requestDismissKeyguard`/flags legadas para versões antigas) e
 * também registra os plugins locais (`SmsSender`, `VolumeSosPlugin`,
 * `LockscreenPlugin`) necessários para o restante do fluxo Dart.
 *
 * ROTA INICIAL PARA O FLUTTER: o extra [EXTRA_ROTA_INICIAL] é lido no
 * lado Dart (`main.dart`) através do `getFlutterEngine()`/argumentos
 * iniciais do `FlutterActivity`, permitindo que a UI Flutter navegue
 * DIRETAMENTE para a `CameraCapturaScreen` (pulando a tela de Login/
 * Home) e dispare, em paralelo, o SMS de emergência via
 * `EmergencyAlertService.dispararSosComDuplaLocalizacao()` — sem
 * depender do `EventChannel`/engine já estar "quente" com um listener
 * Dart ativo (cenário de app completamente fechado).
 *
 * IMPORTANTE: esta Activity reaproveita o MESMO engine em cache
 * (`FlutterEngineCache`) que a [MainActivity] usa, através do
 * `provideFlutterEngine` herdado do próprio Flutter embedding — ou
 * seja, os plugins locais registrados em
 * [MainActivity.configureFlutterEngine] continuam disponíveis
 * normalmente aqui, já que essa Activity ESTENDE [MainActivity] em vez
 * de duplicar a lógica de registro de plugins.
 */
class LockscreenCameraActivity : MainActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // Reaplica toda a lógica de sobreposição ao Keyguard já
        // implementada em MainActivity.onCreate (setShowWhenLocked,
        // setTurnScreenOn, requestDismissKeyguard, flags legadas).
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Garante que os mesmos plugins locais (SmsSender,
        // VolumeSosPlugin, LockscreenPlugin) sejam registrados também
        // neste engine, exatamente como na MainActivity.
        super.configureFlutterEngine(flutterEngine)
    }

    /**
     * Repassa ao Flutter, através da rota inicial padrão do
     * `FlutterActivity` (`window.setInitialRoute`/`getInitialRoute`),
     * o sinal de que este cold start específico deve ir DIRETO para a
     * tela de Captura e Dissuasão, disparando o SOS em paralelo. Ver
     * `main.dart` (`_lerRotaInicialSosFisico`).
     */
    override fun getInitialRoute(): String {
        return ROTA_INICIAL_SOS_FISICO
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Se a Activity já existir (singleTask) e um novo gatilho físico
        // chegar enquanto ela ainda está viva, apenas reforça as flags de
        // lockscreen novamente — a navegação para a tela de captura já é
        // tratada pelo próprio EventChannel/listener Dart normalmente
        // nesse cenário (app já em primeiro plano).
        setIntent(intent)
    }

    companion object {
        /**
         * Extra/rota especial reconhecida pelo lado Dart (`main.dart`)
         * para identificar que o app foi iniciado a partir do gatilho
         * físico de SOS com o aparelho bloqueado/app fechado, e deve
         * navegar imediatamente para `CameraCapturaScreen` + disparar o
         * SOS, sem passar pela tela de Login/Home padrão.
         */
        const val ROTA_INICIAL_SOS_FISICO = "/sos_fisico_lockscreen"
    }
}
