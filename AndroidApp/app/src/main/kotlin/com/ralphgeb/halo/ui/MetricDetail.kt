package com.ralphgeb.halo.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.Format
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.Metric
import com.ralphgeb.halo.core.NormalRange
import com.ralphgeb.halo.core.ScoreEngine
import com.ralphgeb.halo.core.ScoreKind
import com.ralphgeb.halo.core.Snapshot
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** How much of a metric the graph shows. The longer ones show one line per week, low to high. */
enum class ChartSpan(val label: String, val days: Int, val noun: String) {
    WEEK("W", 7, "week"), MONTH("M", 30, "month"), THREE("3M", 91, "3 months"), SIX("6M", 182, "6 months"), YEAR("Y", 365, "year");

    val weekly: Boolean get() = days > 31
}

/** Bars for the things you add up over a day, a line for readings. */
val Metric.isBar: Boolean
    get() = this in listOf(Metric.STEPS, Metric.CARDIO_LOAD, Metric.ACTIVE_MINUTES, Metric.ACTIVE_CALORIES, Metric.SLEEP_DURATION)

/** Readings that have a personal normal worth drawing. */
val Metric.showsRange: Boolean get() = this in Metric.monitored

val Metric.scoreKind: ScoreKind?
    get() = when (this) {
        Metric.RECOVERY -> ScoreKind.RECOVERY
        Metric.EFFORT -> ScoreKind.EFFORT
        Metric.SLEEP_SCORE -> ScoreKind.SLEEP
        else -> null
    }

/** What a metric is, in a few lines (as on the iPhone). */
val Metric.about: String
    get() = when (this) {
        Metric.RECOVERY -> "How ready your body is today. Set once, in the morning, from last night: your heart rate variability and resting heart rate against your own last 30 days, and how well you slept. It doesn't change as the day goes on."
        Metric.EFFORT -> "How much you've done today. It starts at zero at midnight and fills up as you move. Half is your steps against your step target. Half is your active minutes against your daily target, where a moderate minute counts a quarter, cardio twice and peak three times."
        Metric.SLEEP_SCORE -> "How well last night restored you: time asleep against your need, the share in deep and REM sleep, how much of your time in bed you slept, how little you woke, and how close your bedtime was to your usual one."
        Metric.HRV -> "The variation between heartbeats while you sleep. Higher than your normal usually means you've recovered well."
        Metric.RESTING_HEART_RATE -> "Your lowest steady heart rate. A rise of a few beats can be an early sign of stress, illness or fatigue."
        Metric.VO2_MAX -> "An estimate of how well your body uses oxygen during exercise. It moves slowly, over weeks, so the year shows it best."
        Metric.RESPIRATORY_RATE -> "Breaths per minute while you sleep. It's very stable, so a change is worth noticing."
        Metric.SPO2 -> "How much oxygen your blood carries overnight. Most people sit between 95% and 100%."
        Metric.SKIN_TEMP -> "Change from your personal baseline overnight. A jump can come before you feel unwell."
        Metric.SLEEP_DURATION -> "Time actually asleep, not counting time awake in bed."
        Metric.STEPS -> "Every step your band counted during the day."
        Metric.CARDIO_LOAD -> "How hard your heart worked, from your heart rate minute by minute against your resting and maximum heart rate. A brief spike adds nothing; time that lasts adds more the higher your heart rate climbs: about 1 a minute in moderate, 2 in cardio, 3 in peak."
        Metric.ACTIVE_MINUTES -> "Minutes in your moderate, cardio or peak heart-rate zones. Cardio and peak minutes count double."
        Metric.ACTIVE_CALORIES -> "Energy burned by moving, on top of what your body uses at rest."
        Metric.WEIGHT -> "From your connected scale."
    }

/**
 * The graph page for any metric: the average (or the day you touch), a span switch, the chart with
 * your normal shaded and the average dashed, the lowest, highest and normal, and what it means.
 * The arrows step back and forward a whole span.
 */
@Composable
fun MetricDetail(s: Snapshot, metric: Metric, selected: LocalDate, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    var span by rememberSaveable(metric) { mutableStateOf(if (metric == Metric.VO2_MAX || metric == Metric.WEIGHT) ChartSpan.YEAR else ChartSpan.WEEK) }
    var end by rememberSaveable(metric) { mutableStateOf(selected.toEpochDay()) }
    var scrub by remember(metric, span, end) { mutableStateOf<Int?>(null) }
    val endDate = LocalDate.ofEpochDay(end)
    val start = endDate.minusDays((span.days - 1).toLong())
    val points = s.series(metric, span.days, endDate)
    val previous = ScoreEngine.mean(s.series(metric, span.days, start.minusDays(1)).map { it.second })
    val average = ScoreEngine.mean(points.map { it.second })
    val range = if (metric.showsRange) s.normalRange(metric, endDate.plusDays(1)) else null
    val weeks = if (span.weekly) weekly(points, start, endDate) else emptyList()
    val today = HaloTime.today()

    Column(Modifier.fillMaxSize().background(Halo.background).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).clip(CircleShape).background(Halo.card).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = Halo.ink, modifier = Modifier.size(19.dp))
            }
            Text(metric.title, Modifier.weight(1f).padding(horizontal = 12.dp), style = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
        }
        LazyColumn(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.navigationBars),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item("period") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(rangeTitle(start, endDate), style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
                        Text(if (endDate == today) "${span.days} days to today" else "${span.days} days", style = Halo.small.copy(fontSize = 12.sp))
                    }
                    val canBack = start.isAfter(s.firstDate)
                    val canForward = endDate.isBefore(today)
                    StepArrow(Icons.AutoMirrored.Outlined.KeyboardArrowLeft, canBack) { end = endDate.minusDays(span.days.toLong()).toEpochDay() }
                    Spacer(Modifier.width(8.dp))
                    StepArrow(Icons.AutoMirrored.Outlined.KeyboardArrowRight, canForward) {
                        end = minOf(today, endDate.plusDays(span.days.toLong())).toEpochDay()
                    }
                }
            }
            item("readout") { Readout(metric, span, points, weeks, start, scrub, average, previous) }
            item("span") {
                Row(Modifier.fillMaxWidth().clip(CircleShape).background(Halo.track).padding(3.dp)) {
                    ChartSpan.entries.forEach { sp ->
                        val on = sp == span
                        Text(sp.label, Modifier.weight(1f).clip(CircleShape).background(if (on) Halo.card else Color.Transparent)
                            .clickable { span = sp }.padding(vertical = 7.dp),
                            style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = if (on) Halo.text else Halo.secondary, textAlign = TextAlign.Center))
                    }
                }
            }
            item("chart") {
                HaloCard {
                    if (points.isEmpty()) {
                        Box(Modifier.fillMaxWidth().height(220.dp), contentAlignment = Alignment.Center) {
                            Text("No data for this ${span.noun}.", style = Halo.small.copy(fontSize = 14.sp))
                        }
                    } else {
                        Chart(metric, span, points, weeks, start, range, average, scrub) { scrub = it }
                        XLabels(span, start, endDate)
                    }
                    Legend(span, range != null && !span.weekly, average?.let { metric.format(it) })
                }
            }
            item("stats") {
                val values = points.map { it.second }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    StatTile("Lowest", values.minOrNull()?.let { metric.format(it) } ?: "–", Modifier.weight(1f))
                    StatTile("Highest", values.maxOrNull()?.let { metric.format(it) } ?: "–", Modifier.weight(1f))
                    when {
                        range != null -> StatTile("Normal", "${metric.format(range.low)}–${metric.format(range.high)}", Modifier.weight(1f))
                        metric.isBar && metric != Metric.SLEEP_DURATION -> StatTile("Total", metric.format(values.sum()), Modifier.weight(1f))
                        else -> StatTile("Days", "${values.size}", Modifier.weight(1f))
                    }
                }
            }
            metric.scoreKind?.let { kind -> item("factors") { FactorsCard(s, kind, endDate) } }
            item("about") { HaloCard { Text(metric.about, style = Halo.body.copy(color = Halo.secondary)) } }
        }
    }
}

@Composable
private fun StepArrow(icon: androidx.compose.ui.graphics.vector.ImageVector, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp).alpha(if (enabled) 1f else 0.35f).clip(CircleShape).background(Halo.card)
            .border(1.dp, Halo.hairline, CircleShape).clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = Halo.ink, modifier = Modifier.size(22.dp)) }
}

@Composable
private fun StatTile(title: String, value: String, modifier: Modifier) {
    HaloCard(modifier, padding = 14.dp) {
        HaloLabel(title)
        Text(value, style = Halo.number(17.sp), maxLines = 1)
    }
}

private val shortDate = DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())

private fun rangeTitle(a: LocalDate, b: LocalDate): String =
    if (a.year == b.year) "${a.format(shortDate)} – ${b.format(shortDate)}" else "${a.format(shortDate)} ${a.year} – ${b.format(shortDate)} ${b.year}"

data class WeekBar(val start: LocalDate, val low: Double, val high: Double, val average: Double)

private fun weekly(points: List<Pair<LocalDate, Double>>, from: LocalDate, to: LocalDate): List<WeekBar> =
    points.groupBy { HaloTime.weekStart(it.first) }.mapNotNull { (start, items) ->
        val v = items.map { it.second }
        WeekBar(start, v.min(), v.max(), v.average())
    }.sortedBy { it.start }

@Composable
private fun Readout(
    metric: Metric, span: ChartSpan, points: List<Pair<LocalDate, Double>>, weeks: List<WeekBar>,
    start: LocalDate, scrub: Int?, average: Double?, previous: Double?,
) {
    var label = "Average"
    var value = average
    if (scrub != null) {
        if (span.weekly) {
            weeks.getOrNull(scrub)?.let { label = "Week of ${it.start.format(shortDate)}"; value = it.average }
        } else {
            val day = start.plusDays(scrub.toLong())
            label = Format.dayTitle(day)
            value = points.firstOrNull { it.first == day }?.second
        }
    }
    Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        HaloLabel(label.uppercase())
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value?.let { metric.format(it) } ?: "–", style = Halo.number(46.sp))
            if (metric.unit.isNotEmpty() && metric != Metric.SLEEP_DURATION) {
                Text(" ${metric.unit}", Modifier.padding(bottom = 8.dp), style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium, color = Halo.secondary))
            }
        }
        val change: Pair<String, Color>? = when {
            scrub != null || average == null || previous == null -> null
            metric == Metric.SKIN_TEMP -> {
                val d = average - previous
                (if (abs(d) < 0.05) "Same as the previous ${span.noun}" else "${if (d >= 0) "Up" else "Down"} ${"%.1f".format(abs(d))}° on the previous ${span.noun}") to Halo.secondary
            }
            abs(previous) > 0.0001 && abs(average / previous - 1) < 50 -> {
                val d = average / previous - 1
                val good = metric.higherIsBetter?.let { (d >= 0) == it }
                "${if (d >= 0) "Up" else "Down"} ${Math.round(abs(d) * 100)}% on the previous ${span.noun}" to
                    (if (abs(d) < 0.02 || good == null) Halo.secondary else if (good) Halo.ink else Halo.accent)
            }
            else -> null
        }
        Text(change?.first ?: " ", style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, color = change?.second ?: Halo.secondary))
    }
}

/** The chart, drawn by hand: bars or a line by day, or week bars low to high, with a value to the right. */
@Composable
private fun Chart(
    metric: Metric, span: ChartSpan, points: List<Pair<LocalDate, Double>>, weeks: List<WeekBar>, start: LocalDate,
    range: NormalRange?, average: Double?, scrub: Int?, onScrub: (Int?) -> Unit,
) {
    val ink = Halo.ink
    val accent = Halo.accent
    val track = Halo.track
    val hairline = Halo.hairline
    val tertiary = Halo.tertiary
    val slots = if (span.weekly) weeks.size else span.days
    val values = if (span.weekly) weeks.flatMap { listOf(it.low, it.high) } else points.map { it.second }
    var lo = values.minOrNull() ?: 0.0
    var hi = values.maxOrNull() ?: 1.0
    if (range != null && !span.weekly) { lo = min(lo, range.low); hi = max(hi, range.high) }
    if (metric.isBar) lo = 0.0
    if (hi - lo < 1e-6) { hi += 1; lo -= if (metric.isBar) 0.0 else 1.0 }
    val pad = (hi - lo) * 0.08
    if (!metric.isBar) lo -= pad
    hi += pad
    val latest = rememberUpdatedState(onScrub)
    val axis = listOf(hi - pad, (hi - pad + lo + (if (metric.isBar) 0.0 else pad)) / 2, lo + (if (metric.isBar) 0.0 else pad))

    Row {
        Canvas(
            Modifier.weight(1f).height(220.dp)
                .pointerInput(slots) {
                    detectTapGestures { o -> latest.value(((o.x / size.width) * slots).toInt().coerceIn(0, slots - 1)) }
                }
                .pointerInput(slots) {
                    detectHorizontalDragGestures(onDragEnd = { }) { change, _ ->
                        latest.value(((change.position.x / size.width) * slots).toInt().coerceIn(0, slots - 1))
                    }
                },
        ) {
            val w = size.width
            val h = size.height
            fun y(v: Double) = (h - h * ((v - lo) / (hi - lo))).toFloat()
            fun x(i: Int) = (w * (i + 0.5f) / slots)
            axis.forEach { v -> drawLine(hairline, Offset(0f, y(v)), Offset(w, y(v)), 1f) }
            if (range != null && !span.weekly) {
                drawRect(track, Offset(0f, y(range.high)), Size(w, y(range.low) - y(range.high)))
            }
            if (span.weekly) {
                val bw = min(9.dp.toPx(), w / slots * 0.55f)
                weeks.forEachIndexed { i, wk ->
                    val on = i == scrub
                    val top = y(wk.high)
                    val bottom = max(y(wk.low), top + bw)
                    drawRoundRect(if (on) accent.copy(alpha = 0.5f) else ink.copy(alpha = 0.22f), Offset(x(i) - bw / 2, top), Size(bw, bottom - top), CornerRadius(bw / 2))
                    drawCircle(if (on) accent else ink, bw * 0.45f, Offset(x(i), y(wk.average)))
                }
            } else {
                val byIndex = points.associate { ChronoUnit.DAYS.between(start, it.first).toInt() to it.second }
                if (metric.isBar) {
                    val bw = w / slots * 0.55f
                    byIndex.forEach { (i, v) ->
                        val top = y(v)
                        drawRoundRect(if (i == scrub) accent else ink.copy(alpha = 0.85f), Offset(x(i) - bw / 2, top), Size(bw, h - top),
                            CornerRadius(min(4.dp.toPx(), bw / 2)))
                    }
                } else {
                    val ordered = byIndex.toSortedMap()
                    val line = Path()
                    val area = Path()
                    ordered.entries.forEachIndexed { k, (i, v) ->
                        if (k == 0) { line.moveTo(x(i), y(v)); area.moveTo(x(i), h); area.lineTo(x(i), y(v)) }
                        else { line.lineTo(x(i), y(v)); area.lineTo(x(i), y(v)) }
                    }
                    ordered.keys.lastOrNull()?.let { area.lineTo(x(it), h); area.close() }
                    drawPath(area, Brush.verticalGradient(listOf(ink.copy(alpha = 0.16f), Color.Transparent)))
                    drawPath(line, ink, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                    val dot = if (span == ChartSpan.WEEK) 3.dp.toPx() else if (ordered.size <= 2) 2.5.dp.toPx() else 0f
                    ordered.forEach { (i, v) ->
                        if (i == scrub) drawCircle(accent, 5.dp.toPx(), Offset(x(i), y(v)))
                        else if (dot > 0) drawCircle(ink, dot, Offset(x(i), y(v)))
                    }
                }
                scrub?.let { drawLine(accent.copy(alpha = 0.35f), Offset(x(it), 0f), Offset(x(it), h), 1.dp.toPx()) }
            }
            average?.let {
                drawLine(accent, Offset(0f, y(it)), Offset(w, y(it)), 1.2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 8f)))
            }
        }
        // values down the right, like the iPhone's chart
        Column(Modifier.height(220.dp).width(44.dp).padding(start = 6.dp), verticalArrangement = Arrangement.SpaceBetween) {
            axis.forEach { v ->
                Text(if (metric == Metric.SLEEP_DURATION) "${Math.round(v / 60)}h" else metric.format(v),
                    style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Medium, color = tertiary), maxLines = 1)
            }
        }
    }
}

@Composable
private fun XLabels(span: ChartSpan, start: LocalDate, end: LocalDate) {
    val labels: List<String> = when (span) {
        ChartSpan.WEEK -> (0..6).map { start.plusDays(it.toLong()).shortDay().take(3) }
        ChartSpan.MONTH -> listOf(start, start.plusDays(10), start.plusDays(20), end).map { it.format(shortDate) }
        else -> {
            val months = generateSequence(start.withDayOfMonth(1).plusMonths(1)) { it.plusMonths(if (span == ChartSpan.YEAR) 2 else 1) }
                .takeWhile { !it.isAfter(end) }.toList()
            months.map { it.format(DateTimeFormatter.ofPattern("MMM", Locale.getDefault())) }
        }
    }
    Row(Modifier.fillMaxWidth().padding(end = 44.dp)) {
        labels.forEach { Text(it, Modifier.weight(1f), style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Medium, color = Halo.tertiary, textAlign = TextAlign.Center)) }
    }
}

@Composable
private fun Legend(span: ChartSpan, normal: Boolean, average: String?) {
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
        average?.let {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Canvas(Modifier.width(12.dp).height(2.dp)) {
                    drawLine(Halo.accent, Offset(0f, size.height / 2), Offset(size.width, size.height / 2), size.height,
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 4f)))
                }
                Spacer(Modifier.width(5.dp))
                Text("Average $it", style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = Halo.secondary))
            }
        }
        if (normal) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(12.dp, 8.dp).clip(RoundedCornerShape(2.dp)).background(Halo.track))
                Spacer(Modifier.width(5.dp))
                Text("Your normal", style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = Halo.secondary))
            }
        }
        if (span.weekly) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(4.dp, 12.dp).clip(CircleShape).background(Halo.ink.copy(alpha = 0.22f)))
                Spacer(Modifier.width(5.dp))
                Text("Week low to high", style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = Halo.secondary))
            }
        }
    }
}

/** What went into a score on a day, each with how well it did and how much it counts. */
@Composable
fun FactorsCard(s: Snapshot, kind: ScoreKind, date: LocalDate) {
    val factors = s.factors(kind, date)
    HaloCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HaloLabel("What goes into it", Modifier.weight(1f))
            Text(Format.dayTitle(date), style = Halo.small.copy(fontSize = 12.sp))
        }
        if (factors.isEmpty()) Text("No data for this day.", style = Halo.small.copy(fontSize = 14.sp))
        factors.forEachIndexed { i, f ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(f.name, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
                    Spacer(Modifier.width(6.dp))
                    Text(f.weight.uppercase(), Modifier.weight(1f).padding(bottom = 2.dp),
                        style = TextStyle(fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.6.sp, color = Halo.tertiary))
                    Text(f.value, style = Halo.number(16.sp))
                }
                ProgressBar(f.level ?: 0.0, color = if ((f.level ?: 0.0) < 0.34) Halo.accent else Halo.ink.copy(alpha = 0.7f))
                Text(f.note, style = Halo.small.copy(fontSize = 12.sp))
            }
            if (i < factors.lastIndex) Box(Modifier.fillMaxWidth().height(0.5.dp).background(Halo.hairline))
        }
    }
}
