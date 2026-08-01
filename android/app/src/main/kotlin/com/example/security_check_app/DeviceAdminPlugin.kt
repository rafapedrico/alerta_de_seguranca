package com.example.security_check_app

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin Flutter local responsável por expor, via [MethodChannel], o
 * fluxo de Administrador do Dispositivo (Device Admin) — única forma que
 * o Android permite bloquear a tela sob demanda
 * (`DevicePolicyManager.lockNow()`) sem privilégios de root/Device
 * Owner. Ver [GuardiaoDeviceAdminReceiver] para o receiver em si e
 * `DeviceAdminService` no lado Dart para o wrapper consumido pela UI
 * (Configurações/Segurança) e por `CameraCapturaScreen` (P4 da
 * sequência unificada de SOS).
 *
 * MethodChannel ("com.example.security_check_app/device_admin"):
 * - "estaAtivo": retorna `true`/`false` se o app JÁ é um administrador
 *   do dispositivo ativo.
 * - "solicitarAtivacao": abre o diálogo NATIVO do Android pedindo a
 *   permissão (nunca concedida silenciosamente) — o resultado real só é
 *   conhecido depois, via nova chamada a "estaAtivo" quando o app
 *   voltar ao primeiro plano.
 * - "bloquearTelaAgora": chama `lockNow()`. Só funciona se "estaAtivo"
 *   for `true`; caso contrário retorna erro, permitindo que o lado Dart
 *   caia num fallback (ver `CameraCapturaScreen`).
 */
class DeviceAdminPlugin : FlutterPlugin, ActivityAware {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var applicationContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "estaAtivo" -> result.success(estaAtivo())
                    "solicitarAtivacao" -> {
                        try {
                            solicitarAtivacao()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("DEVICE_ADMIN_ERROR", "Falha ao solicitar Device Admin: ${e.message}", null)
                        }
                    }
                    "bloquearTelaAgora" -> {
                        if (!estaAtivo()) {
                            result.error("DEVICE_ADMIN_INATIVO", "App não é administrador do dispositivo.", null)
                        } else {
                            try {
                                obterDevicePolicyManager()?.lockNow()
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("DEVICE_ADMIN_ERROR", "Falha ao bloquear a tela: ${e.message}", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    private fun obterDevicePolicyManager(): DevicePolicyManager? {
        val ctx = applicationContext ?: return null
        return ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
    }

    private fun componenteAdmin(): ComponentName? {
        val ctx = applicationContext ?: return null
        return ComponentName(ctx, GuardiaoDeviceAdminReceiver::class.java)
    }

    private fun estaAtivo(): Boolean {
        val dpm = obterDevicePolicyManager() ?: return false
        val admin = componenteAdmin() ?: return false
        return try {
            dpm.isAdminActive(admin)
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Abre o diálogo nativo `ACTION_ADD_DEVICE_ADMIN`, com uma explicação
     * clara do motivo — jamais chamado durante o próprio SOS (deve ser
     * concedido com antecedência, ver `DeviceAdminService`/tela de
     * consentimento). Requer uma Activity em primeiro plano.
     */
    private fun solicitarAtivacao() {
        val act = activity ?: throw IllegalStateException("Nenhuma Activity disponível.")
        val admin = componenteAdmin() ?: throw IllegalStateException("Componente admin indisponível.")
        val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
            putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, admin)
            putExtra(
                DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                "Necessário para que o Guardião X consiga bloquear a tela automaticamente " +
                    "ao final do fluxo de SOS de emergência.",
            )
        }
        act.startActivity(intent)
    }

    companion object {
        const val CHANNEL = "com.example.security_check_app/device_admin"
    }
}
