package com.example.security_check_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

open class MainActivity: FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Mantém o registro dos plugins essenciais
        flutterEngine.plugins.add(SmsSender())
        flutterEngine.plugins.add(VolumeSosPlugin())
        flutterEngine.plugins.add(LockscreenPlugin())
        flutterEngine.plugins.add(RotinaAlarmPlugin())

        // ATENÇÃO — NÃO registre aqui um MethodChannel manual no canal
        // "com.example.security_check_app/rotina_alarme": esse canal já
        // é de propriedade do [RotinaAlarmPlugin] (registrado logo acima).
        // Um `MethodChannel(...).setMethodCallHandler{...}` manual no
        // MESMO nome de canal, se chamado DEPOIS de
        // `flutterEngine.plugins.add(RotinaAlarmPlugin())`, SOBRESCREVE
        // silenciosamente o handler do plugin — foi exatamente esse bug
        // (código legado, já removido) que fazia com que
        // "pararAlarme"/"pausarAlarme"/"reiniciarSomSeAtivo" nunca
        // chegassem à implementação real (RotinaAlarmSomBridge.pararSom(),
        // fecharActivityAtiva(), etc.) sempre que o app rodava dentro
        // desta Activity ou de RotinaCheckinAlarmActivity (que a estende).
    }
}