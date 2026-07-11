package com.example.security_check_app

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

open class MainActivity: FlutterActivity() {


    /// Garante que a Activity seja capaz de se sobrepor à tela de
    /// bloqueio (lockscreen) e acordar o dispositivo imediatamente,
    /// SEM exigir o PIN/senha do usuário do Android. Essencial para o
    /// fluxo de SOS disparado pelo botão físico de Volume+
    /// (ver VolumeSosService) enquanto o aparelho está bloqueado: a
    /// tela de Captura e Dissuasão (CameraCapturaScreen) precisa abrir
    /// instantaneamente por cima do Keyguard, e não ficar esperando o
    /// usuário desbloquear o aparelho manualmente.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            keyguardManager.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {

        super.configureFlutterEngine(flutterEngine)

        // Registra o plugin local de SMS neste engine (usado quando o app
        // está em primeiro plano/Activity visível). Como SmsSender agora
        // implementa io.flutter.embedding.engine.plugins.FlutterPlugin, o
        // registro do MethodChannel e todo o ciclo de vida
        // (onAttachedToEngine/onDetachedFromEngine) ficam encapsulados na
        // própria classe — bastando adicioná-la ao PluginRegistry do
        // engine, exatamente como plugins de pacotes reais fariam.
        //
        // OBS: o FlutterEngine headless criado internamente pelo pacote
        // android_alarm_manager_plus (usado para os disparos de
        // emergência/rotina com o app fechado) NÃO passa por este método
        // e não tem acesso a este registro — ver comentário detalhado em
        // SmsSender.kt. A proteção para esse cenário fica no lado Dart
        // (EmergencyAlertService), que trata MissingPluginException sem
        // travar nem repetir em loop.
        flutterEngine.plugins.add(SmsSender())

        // Registra o plugin local de SOS via botão físico de Volume+
        // (ver VolumeSosPlugin/VolumeSosService). Expõe o MethodChannel
        // usado para iniciar/parar o Foreground Service de monitoramento
        // e o EventChannel usado para notificar o lado Dart quando o
        // gatilho físico (3 incrementos de volume em até 3s) for detectado.
        flutterEngine.plugins.add(VolumeSosPlugin())

        // Registra o plugin local de reforço de showWhenLocked/turnScreenOn
        // (ver LockscreenPlugin). Permite que o lado Dart force, em tempo de
        // execução — exatamente no initState() da CameraCapturaScreen —
        // a reaplicação das flags de sobreposição ao Keyguard na Activity
        // atualmente visível, cobrindo o cenário em que o Android redesenha
        // o lockscreen por cima da Activity entre o onCreate() original e a
        // navegação para a tela de Captura e Dissuasão.
        flutterEngine.plugins.add(LockscreenPlugin())

        // Registra o plugin local de comunicação com a
        // RotinaCheckinAlarmActivity (ver RotinaAlarmPlugin/
        // RotinaCheckinAlarmActivity), usado tanto para abrir a tela de
        // confirmação de check-in de rotina por cima do Keyguard quanto
        // para pausar o som do alarme em loop a partir do lado Dart.
        flutterEngine.plugins.add(RotinaAlarmPlugin())
    }
}



