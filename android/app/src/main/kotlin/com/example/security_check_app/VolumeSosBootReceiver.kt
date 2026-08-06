package com.example.security_check_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Reinicia o [VolumeSosService] (Foreground Service que monitora o botão
 * físico de Volume+ em segundo plano, mesmo com a tela apagada ou o app
 * minimizado — ver documentação completa em [VolumeSosService]) assim
 * que o Android termina de inicializar após um REBOOT, ou logo após uma
 * ATUALIZAÇÃO do app (ex: via Play Store).
 *
 * BUG REAL DE RESILIÊNCIA CORRIGIDO: sem este receiver, o único ponto
 * que iniciava o serviço era `VolumeSosService().iniciarMonitoramento()`
 * em `main.dart` — ou seja, só rodava depois que o usuário abrisse o
 * app Flutter manualmente PELO MENOS UMA VEZ. Reiniciar o aparelho (ou
 * o Android matar o processo em memória crítica e o usuário nunca mais
 * reabrir o app) deixava o botão físico de pânico completamente
 * inoperante, silenciosamente, até a próxima abertura manual — mesmo
 * com a notificação persistente do Foreground Service sugerindo que
 * tudo estivesse normal (ela também some quando o processo morre).
 *
 * Registrado com `android:exported="false"` no manifest — broadcasts do
 * PRÓPRIO SISTEMA (uid=system) sempre alcançam receivers não-exportados;
 * essa flag só impede que OUTROS APPS instalados no aparelho consigam
 * disparar este receiver artificialmente.
 */
class VolumeSosBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val acao = intent?.action
        if (acao != Intent.ACTION_BOOT_COMPLETED &&
            acao != Intent.ACTION_MY_PACKAGE_REPLACED &&
            acao != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }

        try {
            VolumeSosService.iniciar(context)
        } catch (_: Exception) {
            // Silenciosamente ignorado: pior caso é o mesmo comportamento
            // histórico (usuário precisa abrir o app manualmente uma
            // vez), nunca derruba o boot do sistema.
        }
    }
}
