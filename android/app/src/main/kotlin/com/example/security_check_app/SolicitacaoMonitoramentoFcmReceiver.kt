package com.example.security_check_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.firebase.messaging.RemoteMessage

private const val TAG = "SolicitacaoMonitoramentoFcmReceiver"

/**
 * BroadcastReceiver ADICIONAL para o mesmo broadcast nativo do FCM
 * (`com.google.android.c2dm.intent.RECEIVE`) já tratado pelo
 * `FlutterFirebaseMessagingReceiver` do plugin `firebase_messaging` — o
 * Android entrega um broadcast implícito como este a TODOS os receivers do
 * PRÓPRIO app que o declararem no manifest, então os dois coexistem sem
 * conflito nem duplicar/roubar a entrega um do outro.
 *
 * MOTIVO deste receiver extra: o handler Dart do FCM em segundo plano
 * (`FirebaseMessaging.onBackgroundMessage`, ver `FcmService`) roda numa
 * `FlutterEngine` criada do zero pelo próprio plugin, SEM os plugins
 * nativos CUSTOMIZADOS deste app (`RotinaAlarmPlugin`, `VolumeSosPlugin`
 * etc. — só registrados em `MainActivity.configureFlutterEngine`, nunca
 * nessa engine separada) — mesma limitação já documentada em
 * `MainApplication.kt` para o isolate headless do `android_alarm_manager_plus`.
 * Ou seja: o lado Dart NÃO tem como acionar, de forma confiável, o mesmo
 * mecanismo nativo de "acordar a tela" (WakeLock + Foreground Service +
 * `startActivity` direto) já validado em [VolumeSosService] (botão físico)
 * e [RotinaAlarmWakeService] (alarme de rotina) — SÓ um caminho 100%
 * nativo, disparado aqui, consegue.
 *
 * O [RemoteMessage] é construído a partir dos extras do Intent da MESMA
 * forma que o próprio `FlutterFirebaseMessagingReceiver` faz internamente
 * (`RemoteMessage(intent.extras)`) — construtor público e estável do SDK
 * do Firebase, não um parsing manual/frágil do payload bruto.
 */
class SolicitacaoMonitoramentoFcmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            val extras = intent.extras ?: return
            val remoteMessage = RemoteMessage(extras)
            val dados = remoteMessage.data
            if (dados["tipo"] != "solicitacao_monitoramento") return

            val idPermissao = dados["idPermissao"] ?: return
            Log.d(TAG, "onReceive: solicitação de monitoramento recebida (idPermissao=$idPermissao) — acordando a tela.")

            SolicitacaoMonitoramentoWakeService.iniciar(
                context = context,
                idPermissao = idPermissao,
                uidSolicitante = dados["uidSolicitante"] ?: "",
                nomeSolicitante = dados["nomeSolicitante"] ?: "",
                telefoneSolicitante = dados["telefoneSolicitante"] ?: "",
            )
        } catch (e: Exception) {
            // Falha silenciosa: o caminho Dart normal (notificação via
            // flutter_local_notifications, ver FcmService/NotificacaoService)
            // continua funcionando independentemente deste atalho nativo.
            Log.d(TAG, "onReceive: falha ao processar broadcast: ${e.message}")
        }
    }
}
