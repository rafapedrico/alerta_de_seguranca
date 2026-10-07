package com.example.security_check_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/** Widget SOS da tela de início — o mesmo "Botão de Pânico" do iOS
 * (ios/SOSWidget): só a imagem oficial do botão SOS, quadrada e
 * redimensionável. Um toque abre a [MainActivity] direto no fluxo do SOS
 * (`SosWidgetFluxoService` no Dart), com o app fechado ou aberto. Nenhum
 * dado dinâmico: o layout só é (re)montado quando o launcher pede. */
class SosWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = RemoteViews(context.packageName, R.layout.sos_widget)
        views.setOnClickPendingIntent(R.id.sos_widget_raiz, intentDoSos(context))
        ids.forEach { manager.updateAppWidget(it, views) }
    }

    companion object {
        /** Action do Intent que abre o SOS (ver [MainActivity.ehToqueDoWidgetSos]). */
        const val ACAO_SOS_WIDGET = "com.example.security_check_app.SOS_WIDGET"

        /** Rota inicial do engine no cold start pelo widget (ver main.dart). */
        const val ROTA_INICIAL_SOS_WIDGET = "/sos_widget"

        /** CLEAR_TOP + SINGLE_TOP: com o app aberto, a MainActivity que já
         * existe recebe o toque em `onNewIntent` (sem criar outro engine). */
        private fun intentDoSos(context: Context): PendingIntent {
            val intent = Intent(context, MainActivity::class.java)
                .setAction(ACAO_SOS_WIDGET)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
            return PendingIntent.getActivity(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        fun idsInstalados(context: Context): IntArray =
            AppWidgetManager.getInstance(context)
                .getAppWidgetIds(ComponentName(context, SosWidgetProvider::class.java))
    }
}
