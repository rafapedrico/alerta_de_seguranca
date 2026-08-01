package com.example.security_check_app

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast

/**
 * Receiver de Administrador do Dispositivo (Device Admin) — única forma
 * que o Android permite que um app comum bloqueie a tela
 * (`DevicePolicyManager.lockNow()`, ver [DeviceAdminPlugin]) sem exigir
 * privilégios de Device Owner/root.
 *
 * A ativação NUNCA acontece automaticamente nem durante o pânico — exige
 * que o usuário conceda essa permissão explicitamente, com antecedência,
 * através do fluxo de consentimento em Configurações/Segurança (ver
 * `DeviceAdminService` no lado Dart), respondendo ao diálogo nativo do
 * Android que avisa exatamente o que a permissão concede.
 *
 * Este receiver só usa a política `force-lock` (ver
 * `device_admin_receiver.xml`) — não usamos NENHUMA outra capacidade de
 * Device Admin (apagar dados, travar senha, desabilitar câmera, etc.).
 */
class GuardiaoDeviceAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        super.onEnabled(context, intent)
        Toast.makeText(
            context,
            "Bloqueio automático de tela ativado para o SOS de emergência.",
            Toast.LENGTH_SHORT,
        ).show()
    }

    override fun onDisabled(context: Context, intent: Intent) {
        super.onDisabled(context, intent)
        Toast.makeText(
            context,
            "Bloqueio automático de tela desativado.",
            Toast.LENGTH_SHORT,
        ).show()
    }
}
