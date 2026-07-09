package com.example.security_check_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {

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
    }
}
