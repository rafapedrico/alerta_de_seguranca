package com.example.security_check_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager

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
 *
 * CORREÇÃO (2026-09-02): NÃO chama mais `VolumeSosService.iniciar()`
 * diretamente aqui dentro de `onReceive()`. A partir do Android 15/API 35
 * (nosso targetSdk), iniciar um Foreground Service de tipo restrito
 * (`VolumeSosService` é "specialUse") de forma síncrona a partir de um
 * BroadcastReceiver de BOOT_COMPLETED passou a ser proibido pelo sistema
 * — o Play Console reportou isso como aviso de pré-lançamento na versão de
 * Produção (o stack trace citado por ele, de um plugin do Firebase Functions
 * sem nenhum receiver/serviço, era um artefato de minificação R8; a
 * violação real era esta classe). A chamada agora é delegada para
 * [VolumeSosBootWorker] via WorkManager, que executa fora dessa janela
 * síncrona restrita.
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
            val request = OneTimeWorkRequestBuilder<VolumeSosBootWorker>().build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                "volume_sos_boot_restart",
                ExistingWorkPolicy.REPLACE,
                request
            )
        } catch (_: Exception) {
            // Silenciosamente ignorado: pior caso é o mesmo comportamento
            // histórico (usuário precisa abrir o app manualmente uma
            // vez), nunca derruba o boot do sistema.
        }
    }
}
