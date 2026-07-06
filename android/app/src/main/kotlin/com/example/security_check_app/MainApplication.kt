package com.example.security_check_app

import io.flutter.app.FlutterApplication

// OBS IMPORTANTE: o FlutterEngine headless usado pelo
// android_alarm_manager_plus (dev.fluttercommunity.plus.androidalarmmanager
// .FlutterBackgroundExecutor.startBackgroundIsolate) é criado internamente
// pelo próprio pacote, via `new FlutterEngine(context)`, sem expor nenhum
// hook, callback ou ponto de extensão para que a Application registre
// plugins locais nele. Não existe, portanto, um "onCreate() de
// Application" capaz de garantir a injeção do MethodChannel de SMS nesse
// engine específico — essa é uma limitação do pacote, não uma omissão
// deste código.
//
// A proteção real contra esse cenário (canal de SMS indisponível no
// isolate headless) foi implementada no lado Dart, em
// EmergencyAlertService.dispararAlertaDeEmergencia, que captura
// MissingPluginException (e qualquer outro erro) ao redor da chamada do
// MethodChannel e interrompe o fluxo imediatamente, sem repetir em loop.
class MainApplication : FlutterApplication()
