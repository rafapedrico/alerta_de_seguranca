package com.example.security_check_app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin Flutter local (não publicado no pub.dev) responsável por expor,
 * via [MethodChannel], a lógica nativa de envio de SMS através do
 * [SmsManager] do Android.
 *
 * Implementa [FlutterPlugin] seguindo o padrão moderno recomendado pelo
 * Flutter para plugins customizados: ao invés de registrar o
 * MethodChannel manualmente e duplicar a lógica em cada Activity/engine
 * que precisar dele, a própria classe se registra (`onAttachedToEngine`)
 * e se desregistra (`onDetachedFromEngine`) sozinha, bastando chamar
 * `flutterEngine.plugins.add(SmsSender())` em qualquer [FlutterEngine]
 * controlado pelo app (ver [MainActivity]).
 *
 * IMPORTANTE (limitação conhecida): o FlutterEngine headless criado
 * internamente pelo pacote android_alarm_manager_plus
 * (`FlutterBackgroundExecutor.startBackgroundIsolate`) é totalmente
 * opaco — o próprio plugin de alarme o cria via `new FlutterEngine(...)`
 * sem expor nenhum hook para registrar plugins customizados nele. Ou
 * seja, adicionar este plugin ao [MainActivity] cobre o app em primeiro
 * plano, mas NÃO alcança esse engine headless específico. Por isso, a
 * verdadeira proteção contra falhas nesse cenário fica no lado Dart
 * (ver `EmergencyAlertService.dispararAlertaDeEmergencia`), que trata
 * `MissingPluginException` de forma robusta e nunca tenta novamente em
 * loop.
 */
class SmsSender : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "enviarSms") {
                    try {
                        @Suppress("UNCHECKED_CAST")
                        val telefones = call.argument<List<String>>("telefones") ?: emptyList()
                        val mensagem = call.argument<String>("mensagem") ?: ""

                        enviar(binding.applicationContext, telefones, mensagem)

                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SMS_ERROR", "Falha ao enviar SMS nativo: ${e.message}", null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object {
        /** Nome do MethodChannel usado tanto pela Activity quanto pelo engine headless. */
        const val CHANNEL = "com.example.security_check_app/sms"

        /**
         * Envia a [mensagem] para cada telefone da lista [telefones], dividindo
         * automaticamente em múltiplas partes caso exceda o limite de
         * caracteres de um único SMS.
         *
         * @throws Exception em caso de falha no envio (permissão ausente,
         * SmsManager indisponível, etc.), propagada para quem chamou tratar.
         */
        fun enviar(context: Context, telefones: List<String>, mensagem: String) {
            val smsManager = resolverSmsManagerAtivo(context)

            for (telefone in telefones) {
                if (telefone.isBlank()) continue
                val partes = smsManager.divideMessage(mensagem)
                smsManager.sendMultipartTextMessage(telefone, null, partes, null, null)
            }
        }

        /**
         * Resolve o [SmsManager] vinculado ao chip ATIVO/padrão para SMS —
         * essencial em aparelhos DUAL-SIM (ou com um dos dois slots
         * fisicamente vazio, cenário real observado em testes: slot 0
         * `ABSENT`, slot 1 com o chip ativo). Nesses aparelhos,
         * `SmsManager.getDefault()`/o `SmsManager` genérico do sistema pode
         * não conseguir resolver de forma confiável qual assinatura usar,
         * falhando com erros internos de telefonia (ex:
         * `getGroupIdLevel1`) mesmo com um chip perfeitamente funcional e
         * em serviço.
         *
         * ESTRATÉGIA (com fallback seguro em cada etapa — nunca lança
         * exceção antes de tentar o envio de verdade):
         * 1. Sem a permissão `READ_PHONE_STATE` concedida (não é possível
         *    consultar o [SubscriptionManager]), cai direto no
         *    `SmsManager` "padrão" — mesmo comportamento histórico,
         *    preservado como fallback.
         * 2. Com a permissão concedida: prioriza o id de assinatura
         *    PADRÃO do sistema para SMS
         *    (`SubscriptionManager.getDefaultSmsSubscriptionId()`) —
         *    respeita a escolha explícita do usuário quando o aparelho
         *    tem dois chips ativos simultaneamente.
         * 3. Sem um padrão definido (`INVALID_SUBSCRIPTION_ID` — comum
         *    quando só um dos dois slots tem chip, como no aparelho de
         *    teste), usa a PRIMEIRA assinatura ativa encontrada.
         * 4. Qualquer falha em qualquer etapa acima (SecurityException,
         *    SubscriptionManager indisponível, etc.) cai no `SmsManager`
         *    "padrão" — a resolução do chip nunca pode ser, ela mesma, o
         *    motivo de um SOS não ser enviado.
         */
        private fun resolverSmsManagerAtivo(context: Context): SmsManager {
            val subId = resolverSubscriptionIdAtivo(context)
            if (subId != null && subId != SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
                try {
                    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        context.getSystemService(SmsManager::class.java)
                            .createForSubscriptionId(subId)
                    } else {
                        @Suppress("DEPRECATION")
                        SmsManager.getSmsManagerForSubscriptionId(subId)
                    }
                } catch (_: Exception) {
                    // Cai no fallback abaixo — nunca impede o envio por
                    // causa da resolução específica do chip.
                }
            }

            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
        }

        /**
         * @return o id de assinatura (SIM) a usar para o envio, ou `null`
         * quando não foi possível determinar um (sem permissão, nenhuma
         * assinatura ativa, ou qualquer falha ao consultar o
         * [SubscriptionManager]) — nesse caso [resolverSmsManagerAtivo]
         * cai no `SmsManager` padrão.
         */
        private fun resolverSubscriptionIdAtivo(context: Context): Int? {
            val temPermissao = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_PHONE_STATE,
            ) == PackageManager.PERMISSION_GRANTED
            if (!temPermissao) return null

            return try {
                val subscriptionManager = context.getSystemService(
                    Context.TELEPHONY_SUBSCRIPTION_SERVICE,
                ) as? SubscriptionManager ?: return null

                val idPadrao = SubscriptionManager.getDefaultSmsSubscriptionId()
                if (idPadrao != SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
                    return idPadrao
                }

                // Sem um padrão explícito definido pelo usuário (comum
                // quando só um dos dois slots tem chip, como no aparelho
                // de teste real: slot 0 ABSENT, slot 1 ativo) — usa a
                // primeira assinatura ATIVA encontrada.
                subscriptionManager.activeSubscriptionInfoList?.firstOrNull()?.subscriptionId
            } catch (_: Exception) {
                null
            }
        }
    }
}
