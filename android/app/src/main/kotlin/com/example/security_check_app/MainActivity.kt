package com.example.security_check_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Nome do canal dedicado ao fluxo de "acordar a tela" para solicitações de
 * monitoramento recebidas via FCM — ver [SolicitacaoMonitoramentoWakeService]/
 * [SolicitacaoMonitoramentoFcmReceiver] no lado nativo e `NotificacaoService`
 * no lado Dart. */
private const val CANAL_SOLICITACAO_MONITORAMENTO =
    "com.example.security_check_app/solicitacao_monitoramento"

open class MainActivity: FlutterActivity() {

    private var canalSolicitacaoMonitoramento: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Mantém o registro dos plugins essenciais
        flutterEngine.plugins.add(SmsSender())
        flutterEngine.plugins.add(VolumeSosPlugin())
        flutterEngine.plugins.add(LockscreenPlugin())
        flutterEngine.plugins.add(RotinaAlarmPlugin())
        flutterEngine.plugins.add(DeviceAdminPlugin())
        flutterEngine.plugins.add(SosDispatchPlugin())

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

        // "obterPayloadPendente": chamado UMA VEZ pelo Dart logo no
        // startup (mesmo padrão de getNotificationAppLaunchDetails) para
        // resgatar os extras de um COLD START via
        // SolicitacaoMonitoramentoWakeService. "solicitacaoRecebida" é
        // invocado NATIVO->DART em [onNewIntent], quando o Intent chega
        // com o engine já rodando (app em primeiro/segundo plano).
        val canal = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CANAL_SOLICITACAO_MONITORAMENTO)
        canal.setMethodCallHandler { call, result ->
            if (call.method == "obterPayloadPendente") {
                result.success(extrairPayloadSolicitacao(intent, limpar = true))
            } else {
                result.notImplemented()
            }
        }
        canalSolicitacaoMonitoramento = canal
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = extrairPayloadSolicitacao(intent, limpar = true) ?: return
        canalSolicitacaoMonitoramento?.invokeMethod("solicitacaoRecebida", payload)
    }

    /** Lê (e opcionalmente limpa, para não reprocessar a mesma solicitação
     * numa navegação/rotação subsequente) os extras deixados pelo
     * [SolicitacaoMonitoramentoWakeService] no Intent que abriu/reabriu
     * esta Activity. Retorna `null` se não houver nenhuma solicitação
     * pendente nesse Intent. */
    private fun extrairPayloadSolicitacao(intent: Intent?, limpar: Boolean): Map<String, String>? {
        val idPermissao = intent?.getStringExtra(SolicitacaoMonitoramentoWakeService.EXTRA_ID_PERMISSAO)
            ?: return null
        val payload = mapOf(
            "idPermissao" to idPermissao,
            "uidSolicitante" to (intent.getStringExtra(SolicitacaoMonitoramentoWakeService.EXTRA_UID_SOLICITANTE) ?: ""),
            "nomeSolicitante" to (intent.getStringExtra(SolicitacaoMonitoramentoWakeService.EXTRA_NOME_SOLICITANTE) ?: ""),
            "telefoneSolicitante" to (intent.getStringExtra(SolicitacaoMonitoramentoWakeService.EXTRA_TELEFONE_SOLICITANTE) ?: ""),
        )
        if (limpar) {
            intent?.removeExtra(SolicitacaoMonitoramentoWakeService.EXTRA_ID_PERMISSAO)
        }
        return payload
    }
}