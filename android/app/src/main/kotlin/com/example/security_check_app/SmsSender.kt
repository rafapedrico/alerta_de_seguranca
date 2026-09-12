package com.example.security_check_app

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Log
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

                        val enviados = enviar(binding.applicationContext, telefones, mensagem)

                        // CORREÇÃO DE BUG REAL (2026-08-11): antes, uma falha em
                        // QUALQUER telefone da lista (número malformado, chip sem
                        // sinal etc.) lançava e abortava o `for` inteiro dentro de
                        // [enviar] — os contatos seguintes da lista, mesmo com
                        // números perfeitamente válidos, nunca chegavam a ser
                        // tentados. Agora [enviar] isola cada tentativa e retorna
                        // quantos realmente saíram; só reporta erro ao lado Dart
                        // (`EmergencyAlertService._enviarSms`, que já trata isso
                        // sem travar o Histórico) quando NENHUM dos contatos foi
                        // enviado com sucesso.
                        if (enviados == 0 && telefones.isNotEmpty()) {
                            result.error(
                                "SMS_ERROR",
                                "Falha ao enviar SMS nativo para todos os ${telefones.size} contato(s).",
                                null,
                            )
                        } else {
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Falha inesperada ao processar enviarSms", e)
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
        private const val TAG = "SmsSender"

        /** Nome do MethodChannel usado tanto pela Activity quanto pelo engine headless. */
        const val CHANNEL = "com.example.security_check_app/sms"

        /** Ação do broadcast usado como `sentIntent` de cada parte do SMS —
         * ver [garantirReceiverDeStatusRegistrado]/[enviar]. Diagnóstico
         * pedido pelo usuário (2026-08-15): "status do envio" de verdade,
         * não só "a chamada não lançou exceção" (que só prova que o
         * PEDIDO foi bem formado, não que o RÁDIO aceitou/transmitiu o
         * SMS). */
        private const val ACAO_SMS_STATUS = "com.example.security_check_app.ACTION_SMS_STATUS"
        private var receiverDeStatusRegistrado = false

        /** Traduz o `resultCode` devolvido pelo `sentIntent` do
         * `SmsManager` num motivo legível — os códigos de erro
         * (`RESULT_ERROR_*`) são exatamente o diagnóstico que faltava
         * para saber SE/POR QUE o rádio recusou o envio (sem serviço,
         * rádio desligado/modo avião, etc.), distinto de qualquer
         * exceção Kotlin (que só cobre erros ANTES de chegar ao rádio). */
        private fun descreverResultadoEnvio(resultCode: Int): String {
            return when (resultCode) {
                Activity.RESULT_OK -> "OK — aceito pelo rádio"
                SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "RESULT_ERROR_GENERIC_FAILURE (falha genérica do rádio/operadora)"
                SmsManager.RESULT_ERROR_NO_SERVICE -> "RESULT_ERROR_NO_SERVICE (sem serviço/sinal de rede no momento do envio)"
                SmsManager.RESULT_ERROR_NULL_PDU -> "RESULT_ERROR_NULL_PDU (falha interna ao montar o PDU do SMS)"
                SmsManager.RESULT_ERROR_RADIO_OFF -> "RESULT_ERROR_RADIO_OFF (rádio desligado — modo avião?)"
                SmsManager.RESULT_ERROR_LIMIT_EXCEEDED -> "RESULT_ERROR_LIMIT_EXCEEDED (limite de SMS da operadora/sistema excedido)"
                SmsManager.RESULT_ERROR_SHORT_CODE_NOT_ALLOWED -> "RESULT_ERROR_SHORT_CODE_NOT_ALLOWED"
                SmsManager.RESULT_ERROR_SHORT_CODE_NEVER_ALLOWED -> "RESULT_ERROR_SHORT_CODE_NEVER_ALLOWED"
                SmsManager.RESULT_ERROR_FDN_CHECK_FAILURE -> "RESULT_ERROR_FDN_CHECK_FAILURE (lista de discagem fixa do chip bloqueando o número)"
                else -> "código desconhecido ($resultCode)"
            }
        }

        /** Registra, uma única vez por processo, o `BroadcastReceiver` que
         * recebe o resultado REAL de cada `sentIntent` (ver [enviar]) —
         * dispara assim que o rádio confirma (ou recusa) o envio, não
         * quando a chamada Kotlin retorna (que é só o pedido sendo
         * enfileirado). */
        private fun garantirReceiverDeStatusRegistrado(context: Context) {
            if (receiverDeStatusRegistrado) return
            val appContext = context.applicationContext
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, intent: Intent) {
                    val telefone = intent.getStringExtra(EXTRA_TELEFONE) ?: "(desconhecido)"
                    val parte = intent.getIntExtra(EXTRA_PARTE, 1)
                    val totalPartes = intent.getIntExtra(EXTRA_TOTAL_PARTES, 1)
                    Log.i(
                        TAG,
                        "[SMS] Status do envio para $telefone (parte $parte/$totalPartes): " +
                            descreverResultadoEnvio(resultCode),
                    )
                }
            }
            val filtro = IntentFilter(ACAO_SMS_STATUS)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(receiver, filtro, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                appContext.registerReceiver(receiver, filtro)
            }
            receiverDeStatusRegistrado = true
        }

        private const val EXTRA_TELEFONE = "telefone"
        private const val EXTRA_PARTE = "parte"
        private const val EXTRA_TOTAL_PARTES = "total_partes"

        /**
         * Envia a [mensagem] para cada telefone da lista [telefones], dividindo
         * automaticamente em múltiplas partes caso exceda o limite de
         * caracteres de um único SMS.
         *
         * CORREÇÃO DE BUG REAL (2026-08-11): cada tentativa é isolada em seu
         * próprio try/catch — antes, uma exceção em UM telefone (número
         * malformado, chip sem sinal/serviço, etc.) escapava do `for` e
         * abortava o restante da lista, deixando os demais contatos de
         * emergência SEM SMS mesmo com números perfeitamente válidos. Nunca
         * lança exceção: erros por telefone só são logados (`Log.e`,
         * visíveis via `adb logcat -s SmsSender`) para diagnóstico.
         *
         * DIAGNÓSTICO REFORÇADO (2026-08-15, pedido do usuário): cada
         * tentativa agora carrega um `sentIntent` por parte — o Android só
         * dispara esse broadcast quando o RÁDIO efetivamente processa o
         * envio (sucesso ou erro específico, ver [descreverResultadoEnvio]),
         * diferente do log anterior ("enfileirado com sucesso"), que só
         * provava que `sendMultipartTextMessage` não lançou exceção — ou
         * seja, que o PEDIDO estava bem formado, nunca que o SMS de fato
         * saiu do aparelho.
         *
         * @return quantos telefones tiveram o envio efetivamente tentado com
         * sucesso (sem exceção) — 0 se todos falharem, usado pelo chamador
         * para decidir se reporta erro ao lado Dart. O resultado REAL de
         * cada tentativa (aceito pelo rádio ou não) chega em seguida, de
         * forma assíncrona, nos logs de [garantirReceiverDeStatusRegistrado].
         */
        fun enviar(context: Context, telefones: List<String>, mensagem: String): Int {
            garantirReceiverDeStatusRegistrado(context)
            val smsManager = resolverSmsManagerAtivo(context)
            var enviados = 0

            // ÚLTIMA LINHA DE DEFESA (bug real confirmado em teste físico,
            // 2026-09-11, Motorola Razr 40 Ultra) contra o alerta de pânico
            // voltar para o PRÓPRIO aparelho — ver documentação completa em
            // [numerosDoProprioChip]. Diferente do filtro do lado Dart
            // (`TelefoneUtils.excluirProprioNumero`, que depende do campo
            // "Meu Perfil" estar preenchido), esta checagem lê o número
            // REAL do(s) chip(s) instalado(s), funcionando mesmo quando
            // aquele campo está vazio ou desatualizado.
            val terminacoesProprias = numerosDoProprioChip(context)
                .map { terminacaoComparavel(it) }
                .filter { it.length >= DIGITOS_COMPARACAO }
                .toSet()

            for (telefone in telefones) {
                if (telefone.isBlank()) continue

                if (terminacoesProprias.isNotEmpty()) {
                    val terminacaoDestino = terminacaoComparavel(telefone)
                    if (terminacaoDestino.length >= DIGITOS_COMPARACAO &&
                        terminacaoDestino in terminacoesProprias
                    ) {
                        Log.w(
                            TAG,
                            "[SMS] Destino $telefone corresponde ao PRÓPRIO chip deste " +
                                "aparelho — envio BLOQUEADO (o alerta de pânico nunca pode " +
                                "voltar para quem o disparou).",
                        )
                        continue
                    }
                }

                try {
                    val partes = smsManager.divideMessage(mensagem)
                    Log.i(TAG, "[SMS] Enviando para: $telefone (${partes.size} parte(s))...")

                    val flagsImutavel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        PendingIntent.FLAG_IMMUTABLE
                    } else {
                        0
                    }
                    val sentIntents = ArrayList<PendingIntent>(partes.size)
                    for (indiceParte in partes.indices) {
                        val intent = Intent(ACAO_SMS_STATUS).apply {
                            setPackage(context.packageName)
                            putExtra(EXTRA_TELEFONE, telefone)
                            putExtra(EXTRA_PARTE, indiceParte + 1)
                            putExtra(EXTRA_TOTAL_PARTES, partes.size)
                        }
                        // requestCode único (telefone + parte) — cada
                        // PendingIntent precisa carregar seus PRÓPRIOS
                        // extras sem ser sobrescrito por outra tentativa
                        // concorrente (ex: 2+ contatos cadastrados).
                        val requestCode = telefone.hashCode() * 31 + indiceParte
                        sentIntents.add(
                            PendingIntent.getBroadcast(
                                context, requestCode, intent,
                                PendingIntent.FLAG_UPDATE_CURRENT or flagsImutavel,
                            ),
                        )
                    }

                    smsManager.sendMultipartTextMessage(telefone, null, partes, sentIntents, null)
                    enviados++
                } catch (e: Exception) {
                    Log.e(TAG, "[SMS] Falha ao enviar SMS para $telefone — demais contatos da lista seguem tentados normalmente.", e)
                }
            }

            return enviados
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
        /** Quantidade de dígitos finais usada para comparar dois números de
         * telefone "na prática" (ver [numerosDoProprioChip]/[enviar]) —
         * ignora diferenças de formatação/DDI (com ou sem "+55", "0" de
         * acesso nacional, espaços, parênteses) sem precisar de uma
         * biblioteca de parsing de telefone no lado nativo: a terminação
         * do número (DDD + assinante) já basta para identificar com
         * segurança se é o MESMO número. */
        private const val DIGITOS_COMPARACAO = 8

        private fun terminacaoComparavel(numero: String): String =
            numero.filter { it.isDigit() }.takeLast(DIGITOS_COMPARACAO)

        /**
         * Números de telefone do(s) PRÓPRIO(S) chip(s) deste aparelho —
         * usados como ÚLTIMA linha de defesa em [enviar] contra o alerta de
         * pânico voltar para o próprio aparelho da vítima.
         *
         * CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-09-11,
         * Motorola Razr 40 Ultra): o usuário tinha o PRÓPRIO número do chip
         * cadastrado como contato de emergência — a mensagem de
         * localização voltou para o próprio aparelho ~10 minutos depois
         * (latência normal de concatenação multi-parte da operadora, já
         * documentada em `EmergencyAlertService`). A proteção existente do
         * lado Dart (`TelefoneUtils.excluirProprioNumero`) compara com
         * `user_config.telefone` ("Meu Perfil") — só protege quando esse
         * campo foi preenchido corretamente. Esta checagem NATIVA lê o
         * número REAL do(s) chip(s) via [SubscriptionManager]/
         * [TelephonyManager] (mesma permissão READ_PHONE_STATE já
         * concedida para [resolverSubscriptionIdAtivo]), funcionando
         * independentemente de qualquer campo preenchido manualmente.
         *
         * Best-effort: várias operadoras/eSIMs não expõem o próprio número
         * por essas APIs (retornam vazio/null) — nesse caso, o conjunto
         * retornado fica vazio e [enviar] simplesmente não filtra nada,
         * exatamente o comportamento anterior a esta correção. NUNCA
         * lança exceção nem impede o envio por si só.
         */
        private fun numerosDoProprioChip(context: Context): Set<String> {
            val temPermissao = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_PHONE_STATE,
            ) == PackageManager.PERMISSION_GRANTED
            if (!temPermissao) return emptySet()

            val numeros = mutableSetOf<String>()

            try {
                val subscriptionManager = context.getSystemService(
                    Context.TELEPHONY_SUBSCRIPTION_SERVICE,
                ) as? SubscriptionManager
                val assinaturas = subscriptionManager?.activeSubscriptionInfoList ?: emptyList()
                for (assinatura in assinaturas) {
                    try {
                        val numero = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            subscriptionManager?.getPhoneNumber(assinatura.subscriptionId)
                        } else {
                            @Suppress("DEPRECATION")
                            assinatura.number
                        }
                        if (!numero.isNullOrBlank()) numeros.add(numero)
                    } catch (_: Exception) {
                        // Best-effort por assinatura — segue para as demais.
                    }
                }
            } catch (_: Exception) {
                // SubscriptionManager indisponível — segue só com o
                // fallback de TelephonyManager abaixo.
            }

            try {
                @Suppress("DEPRECATION")
                val numeroLinha1 =
                    (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)
                        ?.line1Number
                if (!numeroLinha1.isNullOrBlank()) numeros.add(numeroLinha1)
            } catch (_: Exception) {
                // Best-effort — nunca impede o envio.
            }

            Log.d(TAG, "[SMS] ${numeros.size} número(s) do próprio chip identificado(s) " +
                "para a checagem de autoenvio (best-effort — pode ficar vazio em algumas " +
                "operadoras/eSIMs).")

            return numeros
        }

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
