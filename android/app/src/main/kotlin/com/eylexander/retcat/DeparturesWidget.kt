package com.eylexander.retcat

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The next buses at the widget's stop (lib/widget.dart documents the data). Each widget has its picks, chosen in
 * WidgetConfigActivity: `config_<id>` lists them, and the app writes each pick's next buses in `dep_<pick>`. Buses that
 * have left are dropped at each redraw, and the app schedules a redraw at each departure. When the data is over 10
 * minutes old or missing, a redraw also asks Dart (widgetCallback) for fresh live times.
 */
class DeparturesWidget : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val now = System.currentTimeMillis() / 1000
        refreshIfStale(context, widgetData, appWidgetIds, now)
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, render(context, widgetData, id, appWidgetManager.getAppWidgetOptions(id), now))
        }
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        manager.updateAppWidget(
            id,
            render(context, HomeWidgetPlugin.getData(context), id, options, System.currentTimeMillis() / 1000),
        )
    }

    private fun render(context: Context, prefs: SharedPreferences, id: Int, options: Bundle, now: Long): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.departures_widget)
        val pick = picks(prefs, id).firstOrNull()
        val data = pick?.let { json(prefs, "dep_$it") }
        views.setOnClickPendingIntent(
            R.id.widget_root,
            if (data == null) configure(context, id) else openStop(context, data.optString("station")),
        )
        views.setOnClickPendingIntent(
            R.id.widget_refresh,
            HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("retcat://refresh")),
        )
        views.removeAllViews(R.id.widget_rows)
        if (data == null) {
            views.setTextViewText(R.id.widget_stop, "Re-TCAT")
            views.setTextViewText(R.id.widget_updated, "")
            views.setTextViewText(R.id.widget_empty, if (pick == null) CHOOSE else LOADING)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            return views
        }
        views.setTextViewText(R.id.widget_stop, data.optString("stop"))
        views.setTextViewText(R.id.widget_updated, "màj ${clock(data.optLong("updated"))}")

        // As many rows as fit: header ~44 dp, rows ~34 dp.
        val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 110)
        val max = ((height - 44) / 34).coerceIn(1, 8)
        val deps = upcoming(data, now)
        for (d in deps.take(max)) views.addView(R.id.widget_rows, departureRow(context, d))
        views.setTextViewText(R.id.widget_empty, "Pas de bus dans les prochaines heures")
        views.setViewVisibility(R.id.widget_empty, if (deps.isEmpty()) View.VISIBLE else View.GONE)
        return views
    }
}

/** The next bus at the widget's stop; [NextBus2Widget] has two stops. Same data and redraws as [DeparturesWidget]. */
open class NextBusWidget : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val now = System.currentTimeMillis() / 1000
        refreshIfStale(context, widgetData, appWidgetIds, now)
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.next_bus_widget)
            views.setOnClickPendingIntent(R.id.widget_root, configure(context, id))
            views.removeAllViews(R.id.widget_rows)
            val picks = picks(widgetData, id)
            for (pick in picks) {
                val data = json(widgetData, "dep_$pick")
                val next = data?.let { upcoming(it, now).firstOrNull() }
                val block = RemoteViews(context.packageName, R.layout.next_bus_stop)
                block.setTextViewText(R.id.next_stop, data?.optString("stop") ?: "Re-TCAT")
                if (data != null) block.setOnClickPendingIntent(R.id.next_block, openStop(context, data.optString("station")))
                if (next != null) block.addView(R.id.next_block, departureRow(context, next))
                block.setTextViewText(R.id.next_none, if (data == null) LOADING else "Pas de bus dans les prochaines heures")
                block.setViewVisibility(R.id.next_none, if (next == null) View.VISIBLE else View.GONE)
                views.addView(R.id.widget_rows, block)
            }
            views.setTextViewText(R.id.widget_empty, CHOOSE)
            views.setViewVisibility(R.id.widget_empty, if (picks.isEmpty()) View.VISIBLE else View.GONE)
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}

/** Its picks come from the same setup, which asks for two stops when the widget is this class. */
class NextBus2Widget : NextBusWidget()

private const val CHOOSE = "Touchez pour choisir l'arrêt"
private const val LOADING = "Ouvrez Re-TCAT pour charger les horaires"

private fun json(prefs: SharedPreferences, key: String) =
    prefs.getString(key, null)?.let { runCatching { JSONObject(it) }.getOrNull() }

/** The widget's picks (`station|route|dir`), empty before its setup. */
private fun picks(prefs: SharedPreferences, id: Int): List<String> =
    prefs.getString("config_$id", null)
        ?.let { runCatching { JSONArray(it).let { a -> List(a.length()) { i -> a.getString(i) } } }.getOrNull() }
        .orEmpty()

/** Buses that haven't left yet. */
private fun upcoming(data: JSONObject, now: Long): List<JSONObject> {
    val deps = data.optJSONArray("deps") ?: return emptyList()
    return List(deps.length()) { deps.getJSONObject(it) }.filter { it.optLong("at") >= now - 30 }
}

/** Asks Dart (widgetCallback) for fresh live times when a widget's data is over 10 minutes old, or missing. */
private fun refreshIfStale(context: Context, prefs: SharedPreferences, ids: IntArray, now: Long) {
    val stale = ids.any { id ->
        picks(prefs, id).any { now - (json(prefs, "dep_$it")?.optLong("updated") ?: 0) > 600 }
    }
    if (stale) HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("retcat://refresh")).send()
}

/** Opens the app at a stop. */
private fun openStop(context: Context, station: String) = HomeWidgetLaunchIntent.getActivity(
    context,
    MainActivity::class.java,
    Uri.parse("retcat://stop?station=${Uri.encode(station)}"),
)

/** Opens the widget's setup (WidgetConfigActivity, lib/setup.dart). */
private fun configure(context: Context, id: Int): PendingIntent = PendingIntent.getActivity(
    context,
    id,
    Intent(context, WidgetConfigActivity::class.java)
        .setAction(AppWidgetManager.ACTION_APPWIDGET_CONFIGURE)
        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
)

/** One bus: line badge, terminus, live mark and time (departures_widget_row.xml). */
private fun departureRow(context: Context, d: JSONObject): RemoteViews {
    val row = RemoteViews(context.packageName, R.layout.departures_widget_row)
    row.setTextViewText(R.id.row_line, d.optString("l"))
    row.setTextColor(R.id.row_line, parse(d.optString("t"), Color.WHITE))
    row.setInt(R.id.row_badge, "setColorFilter", parse(d.optString("c"), Color.DKGRAY))
    row.setTextViewText(R.id.row_terminus, d.optString("h"))
    row.setTextViewText(R.id.row_time, clock(d.optLong("at")))
    row.setViewVisibility(R.id.row_live, if (d.optBoolean("rt")) View.VISIBLE else View.GONE)
    return row
}

private fun clock(epoch: Long) = SimpleDateFormat("HH:mm", Locale.FRANCE).format(Date(epoch * 1000))

private fun parse(hex: String, fallback: Int) = runCatching { Color.parseColor(hex) }.getOrDefault(fallback)
