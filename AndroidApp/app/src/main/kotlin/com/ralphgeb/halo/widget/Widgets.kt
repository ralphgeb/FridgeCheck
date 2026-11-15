package com.ralphgeb.halo.widget

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.ralphgeb.halo.MainActivity
import com.ralphgeb.halo.core.Format
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.Metric
import com.ralphgeb.halo.core.SleepStageKind
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.ui.Looks
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

/**
 * What the widgets show, saved by the app after each sync (the widgets never read your Fitbit
 * account or Health Connect themselves), and redrawing them when it changes or the colours do.
 */
object Widgets {
    private const val PREFS = "halo_widget"
    val TAB = ActionParameters.Key<Int>(MainActivity.EXTRA_TAB)
    val METRIC = ActionParameters.Key<String>(MainActivity.EXTRA_METRIC)
    /** Bumped to redraw the widgets. */
    val VERSION = longPreferencesKey("version")
    /** Which score a one-ring widget shows. */
    val SCORE = stringPreferencesKey("score")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    data class Vital(val name: String, val metric: String, val value: String, val unit: String, val dot: Double?, val concerning: Boolean)
    data class Stage(val kind: SleepStageKind, val start: Long, val end: Long)
    data class Night(
        val start: Long, val end: Long, val asleep: Double, val score: Double?,
        val totals: Map<SleepStageKind, Double>, val stages: List<Stage>,
    )
    data class Data(
        val recovery: Double?, val effort: Double?, val sleep: Double?,
        val vitals: List<Vital>, val night: Night?, val note: String,
    ) {
        fun score(kind: String): Double? = when (kind) { "EFFORT" -> effort; "SLEEP" -> sleep; else -> recovery }
    }

    suspend fun save(context: Context, s: Snapshot) {
        val today = HaloTime.today()
        val scores = s.shownScores(today)
        val vitals = JSONArray()
        s.vitals(today).forEach { v ->
            // where the reading sits: 0 is the middle of your normal, ±0.6 its edges
            val range = v.range
            val value = v.value
            val dot = if (value != null && range != null) {
                val mid = (range.low + range.high) / 2
                val half = maxOf((range.high - range.low) / 2, 0.0001)
                ((value - mid) / half * 0.6).coerceIn(-1.0, 1.0)
            } else null
            vitals.put(JSONObject().apply {
                put("name", v.metric.short)
                put("metric", v.metric.name)
                put("value", value?.let { v.metric.format(it) } ?: "–")
                put("unit", when (v.metric) { Metric.SPO2 -> "%"; Metric.SKIN_TEMP -> "°C"; else -> v.metric.unit })
                dot?.let { put("dot", it) }
                put("concerning", v.concerning)
            })
        }
        // last night: today's sleep, or yesterday's until tonight's comes in
        val nightDay = listOf(today, today.minusDays(1)).firstOrNull { s.day(it)?.sleep != null }
        val night = nightDay?.let { d -> s.day(d)?.sleep?.let { n ->
            JSONObject().apply {
                put("start", n.start); put("end", n.end); put("asleep", n.minutesAsleep)
                s.scores(d).sleep?.let { put("score", it) }
                val totals = JSONObject()
                SleepStageKind.entries.forEach { k ->
                    totals.put(k.name, if (n.stages.isEmpty() && k == SleepStageKind.AWAKE) n.minutesAwake else n.minutes(k))
                }
                put("totals", totals)
                put("stages", JSONArray().apply { n.stages.forEach { st -> put(JSONArray().put(st.kind.name).put(st.start).put(st.end)) } })
            }
        } }
        val json = JSONObject().apply {
            scores.recovery?.let { put("recovery", it) }
            scores.effort?.let { put("effort", it) }
            scores.sleep?.let { put("sleep", it) }
            put("vitals", vitals)
            night?.let { put("night", it) }
            put("note", if (s.isSample) "Sample data" else "Updated " + Format.time(System.currentTimeMillis()))
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("data", json.toString()).apply()
        update(context)
    }

    fun load(context: Context): Data {
        val text = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("data", null)
        val json = runCatching { JSONObject(text ?: "{}") }.getOrDefault(JSONObject())
        fun opt(o: JSONObject, key: String) = if (o.has(key)) o.optDouble(key) else null
        val arr = json.optJSONArray("vitals") ?: JSONArray()
        val vitals = (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            Vital(o.optString("name"), o.optString("metric"), o.optString("value", "–"), o.optString("unit"),
                opt(o, "dot"), o.optBoolean("concerning"))
        }
        val night = json.optJSONObject("night")?.let { n ->
            val totals = n.optJSONObject("totals") ?: JSONObject()
            val stages = n.optJSONArray("stages") ?: JSONArray()
            Night(
                n.optLong("start"), n.optLong("end"), n.optDouble("asleep"), opt(n, "score"),
                SleepStageKind.entries.associateWith { totals.optDouble(it.name, 0.0) },
                (0 until stages.length()).mapNotNull { i ->
                    val st = stages.getJSONArray(i)
                    runCatching { Stage(SleepStageKind.valueOf(st.getString(0)), st.getLong(1), st.getLong(2)) }.getOrNull()
                },
            )
        }
        return Data(opt(json, "recovery"), opt(json, "effort"), opt(json, "sleep"), vitals, night, json.optString("note", "Open Halo to sync"))
    }

    /** Redraws every Halo widget (after a new look, or on leaving the app). */
    fun refresh(context: Context) {
        val app = context.applicationContext
        scope.launch { update(app) }
    }

    private suspend fun update(context: Context) {
        val manager = GlanceAppWidgetManager(context)
        listOf(ScoresWidget(), ScoreWidget(), SleepWidget(), VitalsWidget()).forEach { widget ->
            runCatching {
                manager.getGlanceIds(widget.javaClass).forEach { id ->
                    updateAppWidgetState(context, id) { it[VERSION] = System.nanoTime() }
                    widget.update(context, id)
                }
            }
        }
    }

    // ---- Pictures (widgets can't draw arcs or shapes, so these are small bitmaps)

    fun ring(progress: Double?, c: Looks.WidgetColors, px: Int = 150, width: Float = 0.085f): Bitmap {
        val bmp = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val w = px * width
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

    /** Your normal lying down: ticks at its edges and middle, a dot where last night is. */
    fun rangeLine(dot: Double?, concerning: Boolean, c: Looks.WidgetColors, width: Int = 108, height: Int = 26): Bitmap {
        val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val y = height / 2f
        val pad = height * 0.3f
        val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c.ink.copy(alpha = 0.12f).toArgb(); strokeWidth = height * 0.12f; strokeCap = Paint.Cap.ROUND }
        canvas.drawLine(pad, y, width - pad, y, line)
        listOf(-0.6f, 0f, 0.6f).forEach { t ->
            val x = width / 2f + t * (width / 2f - pad)
            val tick = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c.ink.copy(alpha = if (t == 0f) 0.45f else 0.22f).toArgb(); strokeWidth = height * 0.07f }
            val h = if (t == 0f) height * 0.28f else height * 0.2f
            canvas.drawLine(x, y - h, x, y + h, tick)
        }
        if (dot != null) {
            val x = width / 2f + dot.toFloat() * (width / 2f - pad)
            canvas.drawCircle(x, y, height * 0.24f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = (if (concerning) c.accent else c.ink).toArgb() })
        }
        return bmp
    }

    /** Your normal standing up (as on the iPhone): a slim track, the normal band in the middle, a bar where last night is. */
    fun rangeColumn(dot: Double?, concerning: Boolean, c: Looks.WidgetColors, width: Int = 36, height: Int = 150): Bitmap {
        val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val w = width * 0.3f
        val x = (width - w) / 2
        val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        fill.color = c.ink.copy(alpha = 0.08f).toArgb()
        canvas.drawRoundRect(RectF(x, 0f, x + w, height.toFloat()), w / 2, w / 2, fill)
        fill.color = c.ink.copy(alpha = 0.22f).toArgb()
        canvas.drawRoundRect(RectF(x, height * 0.2f, x + w, height * 0.8f), w / 2, w / 2, fill)
        if (dot != null) {
            val y = (height / 2f - dot.toFloat() * height / 2f).coerceIn(6f, height - 6f)
            fill.color = (if (concerning) c.accent else c.ink).toArgb()
            canvas.drawRoundRect(RectF(x - w * 0.7f, y - 4f, x + w * 1.7f, y + 4f), 4f, 4f, fill)
        }
        return bmp
    }

    fun stageColor(k: SleepStageKind, c: Looks.WidgetColors): Color = when (k) {
        SleepStageKind.DEEP -> c.ink
        SleepStageKind.REM -> c.accent
        SleepStageKind.LIGHT -> c.ink.copy(alpha = 0.45f)
        SleepStageKind.AWAKE -> c.ink.copy(alpha = 0.16f)
    }

    /** The night's stages as lanes, as on the iPhone: awake at the top, deep at the bottom. */
    fun hypnogram(n: Night, c: Looks.WidgetColors, width: Int = 420, height: Int = 120): Bitmap {
        val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val order = listOf(SleepStageKind.AWAKE, SleepStageKind.REM, SleepStageKind.LIGHT, SleepStageKind.DEEP)
        val span = max(1L, n.end - n.start).toFloat()
        val lane = height / order.size.toFloat()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        n.stages.forEach { st ->
            val row = order.indexOf(st.kind)
            val x0 = (st.start - n.start) / span * width
            val x1 = (st.end - n.start) / span * width
            paint.color = stageColor(st.kind, c).toArgb()
            canvas.drawRoundRect(RectF(x0, row * lane + lane * 0.15f, x0 + max(2f, x1 - x0), row * lane + lane * 0.85f), 3f, 3f, paint)
        }
        return bmp
    }

    /** The night's share of each stage as one bar. */
    fun shareBar(n: Night, c: Looks.WidgetColors, width: Int = 300, height: Int = 18): Bitmap {
        val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val order = listOf(SleepStageKind.DEEP, SleepStageKind.REM, SleepStageKind.LIGHT, SleepStageKind.AWAKE)
        val sum = max(1.0, order.sumOf { n.totals[it] ?: 0.0 })
        val gap = 4f
        var x = 0f
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        order.forEach { k ->
            val w = ((width - gap * 3) * ((n.totals[k] ?: 0.0) / sum)).toFloat()
            if (w > 0) {
                paint.color = stageColor(k, c).toArgb()
                canvas.drawRoundRect(RectF(x, 0f, x + max(3f, w), height.toFloat()), height / 2f, height / 2f, paint)
                x += w + gap
            }
        }
        return bmp
    }
}

private fun cp(c: Color) = ColorProvider(c)

/** Opens Halo on a tab, or on a metric's graphs. */
private fun open(tab: Int, metric: String? = null): Action =
    actionStartActivity<MainActivity>(
        if (metric != null) actionParametersOf(Widgets.TAB to tab, Widgets.METRIC to metric) else actionParametersOf(Widgets.TAB to tab)
    )

private fun metricFor(kind: String) = when (kind) { "EFFORT" -> "EFFORT"; "SLEEP" -> "SLEEP_SCORE"; else -> "RECOVERY" }
private fun titleFor(kind: String) = when (kind) { "EFFORT" -> "Effort"; "SLEEP" -> "Sleep"; else -> "Recovery" }

/** A ring with its number in the middle. */
@Composable
private fun RingWithNumber(v: Double?, c: Looks.WidgetColors, size: androidx.compose.ui.unit.Dp, fontSize: Float) {
    Box(GlanceModifier.size(size), contentAlignment = Alignment.Center) {
        Image(ImageProvider(Widgets.ring(v, c)), contentDescription = null, modifier = GlanceModifier.size(size))
        Text(v?.let { "${Math.round(it * 100)}" } ?: "–", style = TextStyle(color = cp(c.ink), fontSize = fontSize.sp, fontWeight = FontWeight.Bold))
    }
}

/** Recovery, Effort and Sleep as three rings, like the top of Today. Each opens its graphs. */
class ScoresWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            // read on every redraw, so a new look or a sync shows at once
            currentState<Preferences>()[Widgets.VERSION]
            val data = Widgets.load(context)
            val c = Looks.forWidget(context)
            val size = LocalSize.current
            // the rings as big as the widget allows
            val ring = minOf((size.width.value - 40) / 3, size.height.value - 44).coerceIn(48f, 104f).dp
            Column(
                GlanceModifier.fillMaxSize().cornerRadius(24.dp).background(cp(c.card)).padding(12.dp).clickable(open(0)),
                verticalAlignment = Alignment.CenterVertically,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    listOf("RECOVERY", "EFFORT", "SLEEP").forEach { kind ->
                        Column(GlanceModifier.defaultWeight().clickable(open(0, metricFor(kind))), horizontalAlignment = Alignment.CenterHorizontally) {
                            RingWithNumber(data.score(kind), c, ring, ring.value * 0.32f)
                            Spacer(GlanceModifier.height(6.dp))
                            Text(titleFor(kind).uppercase(), style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 10.sp, fontWeight = FontWeight.Medium))
                        }
                    }
                }
            }
        }
    }
}

/** One score as a big ring (2×2): Recovery, Effort or Sleep, chosen when you add it. */
class ScoreWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val prefs = currentState<Preferences>()
            prefs[Widgets.VERSION]
            val kind = prefs[Widgets.SCORE] ?: "RECOVERY"
            val data = Widgets.load(context)
            val c = Looks.forWidget(context)
            val size = LocalSize.current
            val ring = minOf(size.width.value - 28, size.height.value - 64).coerceIn(56f, 124f).dp
            Column(
                GlanceModifier.fillMaxSize().cornerRadius(24.dp).background(cp(c.card)).padding(12.dp).clickable(open(0, metricFor(kind))),
                verticalAlignment = Alignment.CenterVertically,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                RingWithNumber(data.score(kind), c, ring, ring.value * 0.3f)
                Spacer(GlanceModifier.height(8.dp))
                Text(titleFor(kind).uppercase(), style = TextStyle(color = cp(c.ink.copy(alpha = 0.55f)), fontSize = 11.sp, fontWeight = FontWeight.Bold))
            }
        }
    }
}

/** Last night's stages in colour: small (2×2) shows the total and a share bar; wide (4×2) the night lane by lane. */
class SleepWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition
    override val sizeMode = SizeMode.Responsive(setOf(DpSize(110.dp, 110.dp), DpSize(250.dp, 110.dp)))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            currentState<Preferences>()[Widgets.VERSION]
            val data = Widgets.load(context)
            val c = Looks.forWidget(context)
            val wide = LocalSize.current.width >= 240.dp
            val n = data.night
            Column(
                GlanceModifier.fillMaxSize().cornerRadius(24.dp).background(cp(c.card)).padding(horizontal = if (wide) 20.dp else 16.dp, vertical = 16.dp).clickable(open(3)),
                verticalAlignment = if (n == null) Alignment.CenterVertically else Alignment.Top,
                horizontalAlignment = if (n == null) Alignment.CenterHorizontally else Alignment.Start,
            ) {
                if (n == null) {
                    Text("No sleep yet", style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 13.sp, fontWeight = FontWeight.Medium))
                } else if (wide) {
                    Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(Format.duration(n.asleep), style = TextStyle(color = cp(c.ink), fontSize = 20.sp, fontWeight = FontWeight.Bold))
                        Spacer(GlanceModifier.width(8.dp))
                        Text("${Format.time(n.start)} – ${Format.time(n.end)}", modifier = GlanceModifier.defaultWeight(),
                            style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 11.sp), maxLines = 1)
                        n.score?.let { Text("${Math.round(it * 100)}", style = TextStyle(color = cp(c.accent), fontSize = 20.sp, fontWeight = FontWeight.Bold)) }
                    }
                    Spacer(GlanceModifier.height(8.dp))
                    if (n.stages.isNotEmpty()) {
                        Image(ImageProvider(Widgets.hypnogram(n, c)), contentDescription = "Sleep stages",
                            modifier = GlanceModifier.fillMaxWidth().defaultWeight(), contentScale = ContentScale.FillBounds)
                    } else {
                        Spacer(GlanceModifier.defaultWeight())
                        Image(ImageProvider(Widgets.shareBar(n, c)), contentDescription = null, modifier = GlanceModifier.fillMaxWidth().height(12.dp), contentScale = ContentScale.FillBounds)
                        Spacer(GlanceModifier.defaultWeight())
                    }
                    Spacer(GlanceModifier.height(8.dp))
                    Row(GlanceModifier.fillMaxWidth()) {
                        listOf(SleepStageKind.DEEP, SleepStageKind.REM, SleepStageKind.LIGHT, SleepStageKind.AWAKE).forEach { k ->
                            Column(GlanceModifier.defaultWeight()) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("●", style = TextStyle(color = cp(Widgets.stageColor(k, c)), fontSize = 9.sp))
                                    Spacer(GlanceModifier.width(3.dp))
                                    Text(k.title.uppercase(), style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 9.sp, fontWeight = FontWeight.Bold))
                                }
                                Text(Format.duration(n.totals[k] ?: 0.0), style = TextStyle(color = cp(c.ink), fontSize = 12.sp, fontWeight = FontWeight.Bold))
                            }
                        }
                    }
                } else {
                    Text(Format.duration(n.asleep), style = TextStyle(color = cp(c.ink), fontSize = 26.sp, fontWeight = FontWeight.Bold), maxLines = 1)
                    Text("${Format.time(n.start)} – ${Format.time(n.end)}", style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 10.sp), maxLines = 1)
                    Spacer(GlanceModifier.defaultWeight())
                    Image(ImageProvider(Widgets.shareBar(n, c, width = 240, height = 16)), contentDescription = null, modifier = GlanceModifier.fillMaxWidth().height(8.dp), contentScale = ContentScale.FillBounds)
                    Spacer(GlanceModifier.height(6.dp))
                    listOf(SleepStageKind.DEEP to SleepStageKind.REM, SleepStageKind.LIGHT to SleepStageKind.AWAKE).forEach { (a, b) ->
                        Row(GlanceModifier.fillMaxWidth()) {
                            listOf(a, b).forEach { k ->
                                Row(GlanceModifier.defaultWeight(), verticalAlignment = Alignment.CenterVertically) {
                                    Text("●", style = TextStyle(color = cp(Widgets.stageColor(k, c)), fontSize = 8.sp))
                                    Spacer(GlanceModifier.width(3.dp))
                                    Text("${k.title} ${Format.duration(n.totals[k] ?: 0.0)}", style = TextStyle(color = cp(c.ink), fontSize = 9.sp, fontWeight = FontWeight.Bold), maxLines = 1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * The five vitals, as on the iPhone: a line saying whether any is outside your normal, then a
 * column for each with its number and your normal standing up (4×2). Squeezed to 4×1 it shows
 * each as a number over a short line.
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
                outside == 0 -> "All in your normal range"
                outside == 1 -> "1 outside your range"
                else -> "$outside outside your range"
            }
            Column(
                GlanceModifier.fillMaxSize().cornerRadius(if (tall) 24.dp else 20.dp).background(cp(c.card))
                    .padding(horizontal = 16.dp, vertical = if (tall) 14.dp else 8.dp)
                    .clickable(open(2)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (tall) {
                    Row(GlanceModifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(if (outside > 0) "!" else "✓", style = TextStyle(color = cp(c.accent), fontSize = 13.sp, fontWeight = FontWeight.Bold))
                        Spacer(GlanceModifier.width(6.dp))
                        Text(status, modifier = GlanceModifier.defaultWeight(),
                            style = TextStyle(color = cp(c.ink), fontSize = 13.sp, fontWeight = FontWeight.Bold), maxLines = 1)
                        Text("Last night", style = TextStyle(color = cp(c.ink.copy(alpha = 0.3f)), fontSize = 10.sp, fontWeight = FontWeight.Bold))
                    }
                    Spacer(GlanceModifier.height(10.dp))
                    Row(GlanceModifier.fillMaxWidth().defaultWeight()) {
                        data.vitals.forEachIndexed { i, v ->
                            if (i > 0) Spacer(GlanceModifier.width(7.dp))
                            Column(
                                GlanceModifier.defaultWeight().fillMaxHeight().cornerRadius(10.dp)
                                    .background(cp(if (v.concerning) c.accent.copy(alpha = 0.14f) else c.ink.copy(alpha = 0.05f)))
                                    .padding(top = 8.dp, bottom = 8.dp, start = 3.dp, end = 3.dp)
                                    .clickable(open(2, v.metric)),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(v.name, style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 10.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center), maxLines = 1)
                                Text(v.value, style = TextStyle(color = cp(if (v.concerning) c.accent else c.ink), fontSize = 15.sp,
                                    fontWeight = FontWeight.Bold, textAlign = TextAlign.Center), maxLines = 1)
                                Spacer(GlanceModifier.height(6.dp))
                                Image(ImageProvider(Widgets.rangeColumn(v.dot, v.concerning, c)), contentDescription = null,
                                    modifier = GlanceModifier.width(14.dp).defaultWeight(), contentScale = ContentScale.FillBounds)
                            }
                        }
                    }
                } else {
                    Row(GlanceModifier.fillMaxWidth().defaultWeight(), verticalAlignment = Alignment.CenterVertically) {
                        data.vitals.forEachIndexed { i, v ->
                            if (i > 0) Spacer(GlanceModifier.width(6.dp))
                            Column(
                                GlanceModifier.defaultWeight().fillMaxHeight().cornerRadius(10.dp)
                                    .background(cp(if (v.concerning) c.accent.copy(alpha = 0.14f) else c.ink.copy(alpha = 0.05f)))
                                    .padding(vertical = 4.dp).clickable(open(2, v.metric)),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(v.name, style = TextStyle(color = cp(c.ink.copy(alpha = 0.5f)), fontSize = 10.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center), maxLines = 1)
                                Text(v.value, style = TextStyle(color = cp(if (v.concerning) c.accent else c.ink), fontSize = 15.sp,
                                    fontWeight = FontWeight.Bold, textAlign = TextAlign.Center), maxLines = 1)
                                Spacer(GlanceModifier.height(2.dp))
                                Image(ImageProvider(Widgets.rangeLine(v.dot, v.concerning, c)), contentDescription = null,
                                    modifier = GlanceModifier.width(32.dp).height(8.dp))
                            }
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

class ScoreWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ScoreWidget()
}

class SleepWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SleepWidget()
}

class VitalsWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = VitalsWidget()
}
