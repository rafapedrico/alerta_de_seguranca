package com.example.security_check_app

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * Executa fora do contexto síncrono do broadcast BOOT_COMPLETED a chamada
 * que efetivamente inicia o [VolumeSosService] (Foreground Service do tipo
 * "specialUse").
 *
 * MOTIVO DE EXISTIR (Android 15 / API 35+): a partir do targetSdk 35, o
 * Android lança `ForegroundServiceStartNotAllowedException` (e o Play
 * Console reporta isso como aviso de pré-lançamento) quando um Foreground
 * Service de tipo restrito é iniciado diretamente de dentro do
 * `onReceive()` de um BroadcastReceiver de BOOT_COMPLETED/QUICKBOOT_POWERON/
 * MY_PACKAGE_REPLACED. Ver [VolumeSosBootReceiver], que agora só enfileira
 * este Worker via WorkManager em vez de chamar `VolumeSosService.iniciar()`
 * diretamente — a execução do Worker acontece fora dessa janela restrita,
 * o que é permitido.
 */
class VolumeSosBootWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    override fun doWork(): Result {
        return try {
            VolumeSosService.iniciar(applicationContext)
            Result.success()
        } catch (_: Exception) {
            // Mesma postura defensiva do receiver original: pior caso é o
            // usuário precisar abrir o app manualmente uma vez, nunca deve
            // derrubar nada do sistema.
            Result.failure()
        }
    }
}
