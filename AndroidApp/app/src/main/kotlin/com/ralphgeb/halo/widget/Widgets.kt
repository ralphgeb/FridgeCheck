package com.ralphgeb.halo.widget

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.currentState
import androidx.glance.LocalSize
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.compose.ui.unit.DpSize
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.ralphgeb.halo.MainActivity
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.Metric
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.ui.Looks
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.cos
import kotlin.math.sin

/**
 * What the widgets show, saved by the app after each sync (the widgets never read Health Connect or
 * the Fitbit account themselves), and redrawing them when it changes or the colours do.
 */
object Widgets {
    private const val PREFS = "halo_widget"
    val TAB = ActionParameters.Key<Int>(MainActivity.EXTRA_TAB)
    val METRIC = ActionParameters.Key<String>(MainActivity.EXTRA_METRIC)
    /** Bumped to redraw the widgets. */
    val VERSION = longPreferencesKey("version")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    data class Vital(val name: String, val metric: String, val value: String, val unit: String, val dot: Double?, val concerning: Boolean)
    data class Data(val recovery: Double?, val effort: Double?, val sleep: Double?, val vitals: List<Vital>, val note: String)

    suspend fun save(context: Context, s: Snapshot) {
        val today = HaloTime.today()
        val scores = s.shownScores(today)
        val vitals = JSONArray()
        s.vitals(today).forEach { v ->
            // where the reading sits: the middle of the line is your normal, the edge ticks its ends
            val dot = if (v.value != null && v.range != null) {
                val mid = (v.range!!.low + v.range!!.high) / 2
                val half = maxOf((v.range!!.high - v.range!!.low) / 2, 0.0001)
                ((v.value!! - mid) / half * 0.6).coerceIn(-1.0, 1.0)
            } else null
            vitals.put(JSONObject().apply {
                put("name", v.metric.short)
                put("metric", v.metric.name)
                put("value", v.value?.let { v.metric.format(it) } ?: "–")
                put("unit", if (v.metric == Metric.SPO2) "%" else v.metric.unit)
                dot?.let { put("dot", it) }
                put("concerning", v.concerning)
            })
        }
        val json = JSONObject().apply {
            scores.recovery?.let { put("recovery", it) }
            scores.effort?.let { put("effort", it) }
            scores.sleep?.let { put("sleep", it) }
            put("vitals", vitals)
            put("note", if (s.isSample) "Sample data" else "Updated " + com.ralphgeb.halo.core.Format.time(System.currentTimeMillis()))
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("data", json.toString()).apply()
        update(context)
    }

    fun load(context: Context): Data {
        val text = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("data", null)
        val json = runCatching { JSONObject(text ?: "{}") }.getOrDefault(JSONObject())
        fun opt(key: String) = if (json.has(key)) json.optDouble(key) else null
        val arr = json.optJSONArray("vitals") ?: JSONArray()
        val vitals = (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            Vital(o.optString("name"), o.optString("metric"), o.optString("value", "–"), o.optString("unit"),
                if (o.has("dot")) o.optDouble("dot") else null, o.optBoolean("concerning"))
        }
        return Data(opt("recovery"), opt("effort"), opt("sleep"), vitals, json.optString("note", "Open Halo to sync"))
    }

    /** Redraws every Halo widget (after a new look). */
    fun refresh(context: Context) {
        val app = context.applicationContext
        scope.launch { update(app) }
    }

    private suspend fun update(context: Context) {
        val manager = GlanceAppWidgetManager(context)
        listOf(ScoresWidget(), VitalsWidget()).forEach { widget ->
            runCatching {
                manager.getGlanceIds(widget.javaClass).forEach { id ->
                    updateAppWidgetState(context, id) { it[VERSION] = System.nanoTime() }
                    widget.update(context, id)
                }
            }
        }
    }

    // ---- Drawing (widgets can't draw arcs, so the rings and range lines are small pictures)

    fun ring(progress: Double?, c: Looks.WidgetColors, px: Int = 132): Bitmap {
        val bmp = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val w = px * 0.085f
        val rect = RectF(w / 2, w / 2, px - w / 2, px - w / 2)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = w; strokeCap = Paint.Cap.ROUND }
        paint.color = c.ink.copy(alpha = 0.1f).toArgb()
        canvas.drawArc(rect, 0f, 360f, false, paint)
        val p = (progress ?: 0.0).coerceIn(0.0, 1.0).toFloat()
        if (p > 0.001f) {
            paint.color = c.ink.toArgb()
            canvas.drawArc(rect, -90f, 360f * p, false, paint)
            if (p > 0.02f) {
                val a = Math.toRadians(-90.0 + 360 * p)
                val r = (px - w) / 2
                val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c.accent.toArgb() }
                canvas.drawCircle(px / 2f + (r * cos(a)).toFloat(), px / 2f + (r * sin(a)).toFloat(), w * 0.28f, dot)
            }
        }
        return bmp
    }

    fun rangeLine(dot: Double?, concerning: Boolean, c: Looks.WidgetColors, width: Int = 108, height: Int = 26): Bitmap {
        val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val y = height / 2f
        val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c.ink.copy(alpha = 0.12f).toArgb(); strokeWidth = height * 0.12f; strokeCap = Paint.Cap.ROUND }
        val pad = height * 0.3f
        canvas.drawLine(pad, y, width - pad, y, line)
        listOf(-0.6f, 0f, 0.6f).forEach { t ->
            val x = width / 2f + t * (width / 2f - pad)
            val tick = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = c.ink.copy(alpha = if (t == 0f) 0.45f else 0.22f).toArgb(); strokeWidth = height * 0.07f
            }
            val h = if (t == 0f) height * 0.28f else height * 0.2f
            canvas.drawLine(x, y - h, x, y + h, tick)
        }
        if (dot != null) {
            val x = width / 2f + dot.toFloat() * (width / 2f - pad)
            val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = (if (concerning) c.accent else c.ink).toArgb() }
            canvas.drawCircle(x, y, height * 0.24f, p)
        }
        return bmp
    }
}

private fun cp(c: Color) = ColorProvider(c)

/** Opens Halo on a tab, or on a metric's graphs. */
private fun open(tab: Int, metric: String? = null) =
    actionStartActivity<MainActivity>(
        if (metric != null) actionParametersOf(Widgets.TAB to tab, Widgets.METRIC to metric) else actionParametersOf(Widgets.TAB to tab)
    )

/** Recovery, Effort and Sleep as three rings, like the top of Today. Each opens its graphs. */
class ScoresWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            // read on every redraw, so a new look or a sync shows at once
            currentState<Preferences>()[Widgets.VERSION]
            val data = Widgets.load(context)
            val c = Looks.forWidget(context)
            val rings = listOf(
                Triple("Recovery", data.recovery, "RECOVERY"),
                Triple("Effort", data.effort, "EFFORT"),
                Triple("Sleep", data.sleep, "SLEEP_SCORE"),
            )
            Column(
                GlanceModifier.fillMaxSize().cornerRadius(24.dp).background(cp(c.card))
                    .padding(horizontal = 12.dp, vertical = 10.dp)
                    .clickable(open(0)),
                verticalAlignment = Alignment.CenterVertically,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    rings.forEach { (name, v, metric) ->
                        Column(GlanceModifier.defaultWeight().clickable(open(0, metric)), horizontalAlignment = Alignment.CenterHorizontally) {
                            Box(GlanceModifier.size(66.dp), contentAlignment = Alignment.Center) {
                                Image(ImageProvider(Widgets.ring(v, c)), contentDescription = name, modifier = GlanceModifier.size(66.dp))
                                Text(v?.let { "${Math.round(it * 100)}" } ?: "–",
                                    style = TextStyle(color = cp(c.ink), fontSize = 21.sp, fontWeight = FontWeight.Bold))
                            }
                            Spacer(GlanceModifier.height(5.dp))
                            Text(name.uppercase(), style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 10.sp, fontWeight = FontWeight.Medium))
                        }
                    }
                }
            }
        }
    }
}

/**
 * The five vitals side by side, each against your normal. 4×1 by default (name, number and a line
 * per vital); stretched to 4×2 it adds a line saying whether any is outside your range, and units.
 */
class VitalsWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition
    override val sizeMode = SizeMode.Responsive(setOf(DpSize(250.dp, 50.dp), DpSize(250.dp, 110.dp)))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            currentState<Preferences>()[Widgets.VERSION]
            val data = Widgets.load(context)
            val c = Looks.forWidget(context)
            val tall = LocalSize.current.height >= 100.dp
            val measured = data.vitals.count { it.dot != null }
            val outside = data.vitals.count { it.concerning }
            val status = when {
                data.vitals.isEmpty() -> "Open Halo to see your vitals"
                measured == 0 -> "Your vitals show after a few nights"
                outside == 0 -> "All vitals in your normal range"
                outside == 1 -> "1 vital outside your range"
                else -> "$outside vitals outside your range"
            }
            Column(
                GlanceModifier.fillMaxSize().cornerRadius(if (tall) 24.dp else 20.dp).background(cp(c.card))
                    .padding(horizontal = 10.dp, vertical = if (tall) 12.dp else 6.dp)
                    .clickable(open(2)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (tall) {
                    Row(GlanceModifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("●", style = TextStyle(color = cp(if (outside > 0) c.accent else c.ink.copy(alpha = 0.5f)), fontSize = 10.sp))
                        Spacer(GlanceModifier.width(6.dp))
                        Text(status, modifier = GlanceModifier.defaultWeight(),
                            style = TextStyle(color = cp(c.ink), fontSize = 14.sp, fontWeight = FontWeight.Bold), maxLines = 1)
                    }
                    Spacer(GlanceModifier.height(10.dp))
                }
                Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    data.vitals.forEach { v ->
                        Column(GlanceModifier.defaultWeight().clickable(open(2, v.metric)), horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(v.name, style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 10.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center), maxLines = 1)
                            Text(v.value, style = TextStyle(color = cp(if (v.concerning) c.accent else c.ink), fontSize = if (tall) 18.sp else 16.sp,
                                fontWeight = FontWeight.Bold, textAlign = TextAlign.Center), maxLines = 1)
                            if (tall) Text(v.unit, style = TextStyle(color = cp(c.ink.copy(alpha = 0.3f)), fontSize = 9.sp, textAlign = TextAlign.Center), maxLines = 1)
                            Spacer(GlanceModifier.height(3.dp))
                            Image(ImageProvider(Widgets.rangeLine(v.dot, v.concerning, c)), contentDescription = null,
                                modifier = GlanceModifier.width(38.dp).height(9.dp))
                        }
                    }
                }
            }
        }
    }
}

class ScoresWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ScoresWidget()
}

class VitalsWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = VitalsWidget()
}
