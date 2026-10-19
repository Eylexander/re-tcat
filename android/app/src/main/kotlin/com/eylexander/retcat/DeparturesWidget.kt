package com.eylexander.retcat

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Next buses at the stop chosen in the app. It only draws the `data` JSON written by lib/widget.dart (format
 * documented there); buses that have left are dropped at each redraw, and the app schedules a redraw at each
 * departure. When the data is over 10 minutes old, a redraw also asks Dart (widgetCallback) for fresh live times.
 */
class DeparturesWidget : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val data = widgetData.getString("data", null)?.let { runCatching { JSONObject(it) }.getOrNull() }
        val now = System.currentTimeMillis() / 1000
        if (data != null && now - data.optLong("updated") > 600) {
            HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("retcat://refresh")).send()
        }
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, render(context, data, appWidgetManager.getAppWidgetOptions(id), now))
        }
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        val data = es.antonborri.home_widget.HomeWidgetPlugin.getData(context).getString("data", null)
            ?.let { runCatching { JSONObject(it) }.getOrNull() }
        manager.updateAppWidget(id, render(context, data, options, System.currentTimeMillis() / 1000))
    }

    private fun render(context: Context, data: JSONObject?, options: Bundle, now: Long): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.departures_widget)
        val station = data?.optString("station").orEmpty()
        views.setOnClickPendingIntent(
            R.id.widget_root,
            HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse(if (station.isEmpty()) "retcat://open" else "retcat://stop?station=${Uri.encode(station)}"),
            ),
        )
        views.setOnClickPendingIntent(
            R.id.widget_refresh,
            HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("retcat://refresh")),
        )
        views.removeAllViews(R.id.widget_rows)
        if (data == null) {
            views.setTextViewText(R.id.widget_stop, "Re-TCAT")
            views.setTextViewText(R.id.widget_updated, "")
            views.setTextViewText(R.id.widget_empty, "Dans l'app, ouvrez un arrêt puis ⋮ → Afficher sur le widget")
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            return views
        }
        views.setTextViewText(R.id.widget_stop, data.optString("stop"))
        views.setTextViewText(R.id.widget_updated, "màj ${clock(data.optLong("updated"))}")

        // As many rows as fit: header ~44 dp, rows ~34 dp.
        val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 110)
        val max = ((height - 44) / 34).coerceIn(1, 8)
        val deps = data.optJSONArray("deps")
        var shown = 0
        for (i in 0 until (deps?.length() ?: 0)) {
            val d = deps!!.getJSONObject(i)
            if (d.optLong("at") < now - 30 || shown >= max) continue
            val row = RemoteViews(context.packageName, R.layout.departures_widget_row)
            row.setTextViewText(R.id.row_line, d.optString("l"))
            row.setTextColor(R.id.row_line, parse(d.optString("t"), Color.WHITE))
            row.setInt(R.id.row_badge, "setColorFilter", parse(d.optString("c"), Color.DKGRAY))
            row.setTextViewText(R.id.row_terminus, d.optString("h"))
            row.setTextViewText(R.id.row_time, clock(d.optLong("at")))
            row.setViewVisibility(R.id.row_live, if (d.optBoolean("rt")) View.VISIBLE else View.GONE)
            views.addView(R.id.widget_rows, row)
            shown++
        }
        views.setTextViewText(R.id.widget_empty, "Pas de bus dans les prochaines heures")
        views.setViewVisibility(R.id.widget_empty, if (shown == 0) View.VISIBLE else View.GONE)
        return views
    }

    private fun clock(epoch: Long) = SimpleDateFormat("HH:mm", Locale.FRANCE).format(Date(epoch * 1000))

    private fun parse(hex: String, fallback: Int) = runCatching { Color.parseColor(hex) }.getOrDefault(fallback)
}
