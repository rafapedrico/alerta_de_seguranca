package com.example.security_check_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Plugin Flutter local responsável por expor, via [MethodChannel], o
 * controle do [SosDispatchService] — o Foreground Service que mantém o
 * processo vivo durante a janela crítica de envio do SOS (SMS + upload à
 * nuvem, ver documentação completa em [SosDispatchService] e em
 * `SosDisparoService` no lado Dart).
 *
 * MethodChannel ("com.example.security_check_app/sos_dispatch"):
 * - "iniciar": inicia o Foreground Service (chamado ANTES de despachar
 *   o SMS/upload).
 * - "parar": encerra o Foreground Service (chamado num `finally`, assim
 *   que o SMS/upload concluir — sucesso ou falha).
 *
 * Não precisa de [io.flutter.embedding.engine.plugins.activity.ActivityAware]:
 * iniciar/parar um Service só depende do `applicationContext`, disponível
 * já em [onAttachedToEngine].
 */
class SosDispatchPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "iniciar" -> {
                        try {
                            SosDispatchService.iniciar(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SOS_DISPATCH_ERROR", "Falha ao iniciar SosDispatchService: ${e.message}", null)
                        }
                    }
                    "parar" -> {
                        try {
                            SosDispatchService.parar(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SOS_DISPATCH_ERROR", "Falha ao parar SosDispatchService: ${e.message}", null)
                        }
                    }
                    "redimensionarFoto" -> {
                        val origem = call.argument<String>("origem")
                        val destino = call.argument<String>("destino")
                        if (origem == null || destino == null) {
                            result.success(null)
                        } else {
                            val ladoMaximo = call.argument<Int>("ladoMaximo") ?: 1600
                            val qualidade = call.argument<Int>("qualidade") ?: 75
                            executor.execute {
                                val ok = FotoSos.redimensionar(origem, destino, ladoMaximo, qualidade)
                                principal.post { result.success(if (ok) destino else null) }
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
    }

    companion object {
        const val CHANNEL = "com.example.security_check_app/sos_dispatch"
        private val executor = Executors.newSingleThreadExecutor()
        private val principal = Handler(Looper.getMainLooper())
    }
}

/**
 * Foto do SOS antes do upload (redução de custo do Storage e envio mais
 * rápido): no máximo [ladoMaximo] px no lado maior, JPEG com [qualidade],
 * já na orientação certa (EXIF aplicado).
 */
object FotoSos {
    fun redimensionar(origem: String, destino: String, ladoMaximo: Int, qualidade: Int): Boolean {
        return try {
            val limites = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(origem, limites)
            val maior = maxOf(limites.outWidth, limites.outHeight)
            if (maior <= 0) return false
            var amostra = 1
            while (maior / (amostra * 2) >= ladoMaximo) amostra *= 2
            val bitmap = BitmapFactory.decodeFile(origem, BitmapFactory.Options().apply { inSampleSize = amostra })
                ?: return false

            val escala = minOf(1f, ladoMaximo.toFloat() / maxOf(bitmap.width, bitmap.height))
            val matriz = Matrix().apply {
                if (escala < 1f) postScale(escala, escala)
                val graus = when (ExifInterface(origem).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL,
                )) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
                if (graus != 0f) postRotate(graus)
            }
            val final = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matriz, true)
            File(destino).parentFile?.mkdirs()
            FileOutputStream(destino).use { final.compress(Bitmap.CompressFormat.JPEG, qualidade, it) }
            if (final !== bitmap) final.recycle()
            bitmap.recycle()
            true
        } catch (e: Throwable) {
            android.util.Log.w("FotoSos", "Falha ao redimensionar a foto: $e")
            false
        }
    }
}
