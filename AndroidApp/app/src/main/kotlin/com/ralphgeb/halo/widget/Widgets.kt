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
import androidx.glance.appwidget.updateAll
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
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    data class Vital(val name: String, val value: String, val unit: String, val dot: Double?, val concerning: Boolean)
    data class Data(val recovery: Double?, val effort: Double?, val sleep: Double?, val vitals: List<Vital>, val note: String)

    suspend fun save(context: Context, s: Snapshot) {
        val today = HaloTime.today()
        val scores = s.scores(today)
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
            Vital(o.optString("name"), o.optString("value", "–"), o.optString("unit"),
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
        runCatching { ScoresWidget().updateAll(context) }
        runCatching { VitalsWidget().updateAll(context) }
    }

    // ---- Drawing (widgets can't draw arcs, so the rings and range lines are small pictures)

    fun ring(progress: Double?, c: Looks.WidgetColors, px: Int = 220): Bitmap {
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

    fun rangeLine(dot: Double?, concerning: Boolean, c: Looks.WidgetColors, width: Int = 140, height: Int = 36): Bitmap {
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

/** Recovery, Effort and Sleep as three rings, like the top of Today. */
class ScoresWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = Widgets.load(context)
        val c = Looks.forWidget(context)
        val rings = listOf("Recovery" to data.recovery, "Effort" to data.effort, "Sleep" to data.sleep)
            .map { (name, v) -> Triple(name, v, Widgets.ring(v, c)) }
        provideContent {
            Column(
                GlanceModifier.fillMaxSize().cornerRadius(24.dp).background(cp(c.card))
                    .padding(horizontal = 14.dp, vertical = 12.dp)
                    .clickable(actionStartActivity<MainActivity>(actionParametersOf(Widgets.TAB to 0))),
                verticalAlignment = Alignment.CenterVertically,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Row(GlanceModifier.fillMaxWidth()) {
                    rings.forEach { (name, v, bmp) -> RingColumn(name, v, bmp, c) }
                }
                Spacer(GlanceModifier.height(6.dp))
                Text(data.note, style = TextStyle(color = cp(c.ink.copy(alpha = 0.3f)), fontSize = 10.sp))
            }
        }
    }

    @Composable
    private fun androidx.glance.layout.RowScope.RingColumn(name: String, v: Double?, bmp: Bitmap, c: Looks.WidgetColors) {
        Column(GlanceModifier.defaultWeight(), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(GlanceModifier.size(70.dp), contentAlignment = Alignment.Center) {
                Image(ImageProvider(bmp), contentDescription = name, modifier = GlanceModifier.size(70.dp))
                Text(v?.let { "${Math.round(it * 100)}" } ?: "–",
                    style = TextStyle(color = cp(c.ink), fontSize = 22.sp, fontWeight = FontWeight.Bold))
            }
            Spacer(GlanceModifier.height(6.dp))
            Text(name.uppercase(), style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 10.sp, fontWeight = FontWeight.Medium))
        }
    }
}

/** The five vitals side by side, each against your normal, with a line saying whether any is outside it. */
class VitalsWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = Widgets.load(context)
        val c = Looks.forWidget(context)
        val lines = data.vitals.map { Widgets.rangeLine(it.dot, it.concerning, c) }
        val measured = data.vitals.count { it.dot != null }
        val outside = data.vitals.count { it.concerning }
        val status = when {
            data.vitals.isEmpty() -> "Open Halo to see your vitals"
            measured == 0 -> "Your vitals show after a few nights"
            outside == 0 -> "All vitals in your normal range"
            outside == 1 -> "1 vital outside your range"
            else -> "$outside vitals outside your range"
        }
        provideContent {
            Column(
                GlanceModifier.fillMaxSize().cornerRadius(24.dp).background(cp(c.card))
                    .padding(horizontal = 14.dp, vertical = 12.dp)
                    .clickable(actionStartActivity<MainActivity>(actionParametersOf(Widgets.TAB to 2))),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("●", style = TextStyle(color = cp(if (outside > 0) c.accent else c.ink.copy(alpha = 0.5f)), fontSize = 10.sp))
                    Spacer(GlanceModifier.width(6.dp))
                    Text(status, modifier = GlanceModifier.defaultWeight(),
                        style = TextStyle(color = cp(c.ink), fontSize = 14.sp, fontWeight = FontWeight.Bold), maxLines = 1)
                }
                Spacer(GlanceModifier.height(10.dp))
                Row(GlanceModifier.fillMaxWidth()) {
                    data.vitals.forEachIndexed { i, v ->
                        Column(GlanceModifier.defaultWeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(v.name, style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 11.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center))
                            Spacer(GlanceModifier.height(3.dp))
                            Text(v.value, style = TextStyle(color = cp(if (v.concerning) c.accent else c.ink), fontSize = 17.sp,
                                fontWeight = FontWeight.Bold, textAlign = TextAlign.Center), maxLines = 1)
                            Text(v.unit, style = TextStyle(color = cp(c.ink.copy(alpha = 0.3f)), fontSize = 9.sp, textAlign = TextAlign.Center), maxLines = 1)
                            Spacer(GlanceModifier.height(4.dp))
                            Image(ImageProvider(lines[i]), contentDescription = null, modifier = GlanceModifier.width(40.dp).height(10.dp))
                        }
                    }
                }
                Spacer(GlanceModifier.height(6.dp))
                Text(data.note, style = TextStyle(color = cp(c.ink.copy(alpha = 0.3f)), fontSize = 10.sp))
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
