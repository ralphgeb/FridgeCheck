package com.ralphgeb.halo.ui

import androidx.compose.foundation.Canvas
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import com.ralphgeb.halo.core.Metric
import androidx.compose.runtime.mutableStateOf
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.CardioFocus
import com.ralphgeb.halo.core.DayMetrics
import com.ralphgeb.halo.core.Format
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.ScoreKind
import com.ralphgeb.halo.core.Snapshot
import java.time.LocalDate
import java.time.format.TextStyle as DayStyle
import java.util.Locale
import kotlin.math.max

/** Which graph each Balance spoke opens, and what it scores. */
fun balanceMetric(name: String): Metric = when (name) {
    "Sleep" -> Metric.SLEEP_SCORE
    "HRV" -> Metric.HRV
    "Recovery" -> Metric.RECOVERY
    "Steps" -> Metric.STEPS
    "Resting HR" -> Metric.RESTING_HEART_RATE
    else -> Metric.CARDIO_LOAD
}

private fun balanceAbout(name: String): String = when (name) {
    "Sleep" -> "Average sleep score over the period."
    "HRV" -> "Scores 70 at your usual level, more when higher and steady."
    "Recovery" -> "Average recovery over the period."
    "Steps" -> "Daily average against your step target."
    "Resting HR" -> "Scores 70 at your usual; lower than usual scores higher."
    else -> "Cardio load over the week against your target."
}

/**
 * Balance: the radar on the left and the grades on the right, as on the iPhone. Tap a grade or a
 * spoke to light it up; the panel below says what it is and opens its graph.
 */
@Composable
fun BalanceCard(s: Snapshot, date: LocalDate, onOpen: (Metric) -> Unit) {
    var span by rememberSaveable { mutableIntStateOf(1) }   // 0 = 1D, 1 = 1W
    var picked by rememberSaveable { mutableStateOf<String?>(null) }
    val days = if (span == 0) 1 else 7
    val axes = s.balance(date, days)
    val before = date.minusDays(days.toLong())
    val previous = if (!before.isBefore(s.firstDate)) s.balance(before, days) else null
    val score = Math.round(axes.map { it.value }.average() * 100)
    val weakest = axes.minByOrNull { it.value }
    val marked = axes.firstOrNull { it.name == picked } ?: weakest
    HaloCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HaloLabel("Balance")
            Spacer(Modifier.width(10.dp))
            SpanSwitch(listOf("1D", "1W"), span) { span = it }
            Spacer(Modifier.weight(1f))
            Text("$score", style = Halo.number(24.sp))
            Text(" / 100", style = Halo.small.copy(fontSize = 12.sp))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Radar(axes, Modifier.weight(1f).aspectRatio(1f), highlight = marked?.name, previous = previous) { name ->
                picked = if (picked == name) null else name
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.width(112.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                axes.forEach { a ->
                    val on = a.name == marked?.name
                    Column(
                        Modifier.fillMaxWidth().clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                            .clickable { picked = if (picked == a.name) null else a.name }.padding(vertical = 4.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Row {
                            Text(a.short, Modifier.weight(1f), style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, color = if (on) Halo.accent else Halo.ink))
                            Text("${Math.round(a.value * 100)}", style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                                color = if (on) Halo.accent else Halo.secondary, fontFeatureSettings = "tnum"))
                        }
                        Canvas(Modifier.fillMaxWidth().height(3.dp)) {
                            drawRoundRect(Halo.track, size = size, cornerRadius = CornerRadius(size.height / 2))
                            drawRoundRect(if (on) Halo.accent else Halo.ink.copy(alpha = 0.55f), size = Size(max(3f, size.width * a.value.toFloat()), size.height),
                                cornerRadius = CornerRadius(size.height / 2))
                        }
                    }
                }
            }
        }
        marked?.let { m ->
            Row(
                Modifier.fillMaxWidth().clip(androidx.compose.foundation.shape.RoundedCornerShape(14.dp)).background(Halo.track)
                    .clickable { onOpen(balanceMetric(m.name)) }.padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(m.name, style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
                        if (m.name == weakest?.name) {
                            Spacer(Modifier.width(6.dp))
                            Text("WEAKEST", style = TextStyle(fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp, color = Halo.accent))
                        }
                    }
                    m.detail?.let { Text(it, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, color = Halo.ink.copy(alpha = 0.75f))) }
                    Text(balanceAbout(m.name), style = TextStyle(fontSize = 11.sp, color = Halo.secondary))
                }
                Spacer(Modifier.width(8.dp))
                Column(horizontalAlignment = Alignment.End) {
                    Text("${Math.round(m.value * 100)}", style = Halo.number(22.sp).copy(color = Halo.accent))
                    Text("score", style = TextStyle(fontSize = 9.sp, fontWeight = FontWeight.SemiBold, color = Halo.tertiary))
                }
                Chevron()
            }
        }
    }
}

/** The small arrow on a card that opens something. */
@Composable
fun Chevron() {
    androidx.compose.material3.Icon(
        androidx.compose.material.icons.Icons.AutoMirrored.Outlined.KeyboardArrowRight, null,
        tint = Halo.tertiary, modifier = Modifier.size(18.dp),
    )
}

/** This week's cardio load against its target, day by day. */
@Composable
fun CardioLoadCard(s: Snapshot, date: LocalDate, onClick: (() -> Unit)? = null) {
    val w = s.cardioWeek(date)
    HaloCard(onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HaloLabel("Cardio load · this week", Modifier.weight(1f))
            Row(Modifier.clip(CircleShape).background(Halo.track).padding(horizontal = 10.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Dot(Halo.accent)
                Spacer(Modifier.width(6.dp))
                Text(w.focus.title, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(104.dp), contentAlignment = Alignment.Center) {
                Ring(w.progress, Modifier.size(104.dp), stroke = 7.dp)
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("${Math.round(w.load)}", style = Halo.number(26.sp))
                    Text("of ${w.target.toInt()}", style = Halo.small.copy(fontSize = 11.sp))
                }
            }
            Spacer(Modifier.width(18.dp))
            val max = max(w.days.mapNotNull { it.second }.maxOrNull() ?: 0.0, w.target / 7)
            Row(Modifier.weight(1f).height(84.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Bottom) {
                w.days.forEach { (d, load) ->
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Canvas(Modifier.width(12.dp).height(62.dp)) {
                            val h = if (load == null) 0f else (size.height * (load / max).coerceIn(0.03, 1.0)).toFloat()
                            if (load == null) {
                                drawCircle(Halo.tertiary, 3.dp.toPx(), Offset(size.width / 2, size.height - 3.dp.toPx()), style = Stroke(1.dp.toPx()))
                            } else {
                                drawRoundRect(if (d == date) Halo.accent else Halo.ink.copy(alpha = 0.5f), Offset(0f, size.height - h), Size(size.width, h), CornerRadius(4.dp.toPx()))
                            }
                        }
                        Text(d.dayOfWeek.getDisplayName(DayStyle.NARROW, Locale.getDefault()), style = TextStyle(fontSize = 10.sp, color = Halo.tertiary))
                    }
                }
            }
        }
        Row {
            Stat("Today", "${Math.round(w.days.firstOrNull { it.first == date }?.second ?: 0.0)}", Modifier.weight(1f))
            Stat("To go", "${Math.round(w.remaining)}", Modifier.weight(1f))
            Stat("Usual week", w.baseline?.let { "${Math.round(it)}" } ?: "–", Modifier.weight(1f))
        }
        Text("${w.focus.title}: ${w.focus.detail.replaceFirstChar { it.lowercase() }}", style = Halo.small)
    }
}

@Composable
fun Stat(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier) {
        HaloLabel(label)
        Text(value, style = Halo.number(20.sp))
    }
}

/** The day's heart rate as a soft accent wash over a thin line, with the resting line dashed. */
@Composable
fun HeartRateCard(day: DayMetrics, onClick: (() -> Unit)? = null) {
    val samples = day.heartRate
    if (samples.size < 6) return
    val values = samples.map { it.bpm }
    HaloCard(onClick = onClick) {
        Row(verticalAlignment = Alignment.Bottom) {
            HaloLabel("Heart rate · ${Format.dayTitle(day.date).lowercase()}", Modifier.weight(1f))
            Text("peak ${Math.round(values.max())}", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Halo.accent))
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Text("${Math.round(values.last())}", style = Halo.number(30.sp))
            Text(" bpm last · low ${Math.round(values.min())}", style = Halo.small)
        }
        val start = HaloTime.startOf(day.date)
        val resting = day.restingHeartRate
        Canvas(Modifier.fillMaxWidth().height(130.dp)) {
            val lo = minOf(values.min(), resting ?: 200.0) - 4
            val hi = values.max() + 4
            fun x(t: Long) = (size.width * ((t - start) / 86_400_000.0)).toFloat()
            fun y(v: Double) = (size.height - size.height * ((v - lo) / (hi - lo))).toFloat()
            val line = Path()
            val area = Path()
            var last: Long? = null
            var firstX = 0f
            var lastX = 0f
            samples.sortedBy { it.time }.forEach { s ->
                val p = Offset(x(s.time), y(s.bpm))
                if (last != null && s.time - last!! < 30 * 60_000) {
                    line.lineTo(p.x, p.y); area.lineTo(p.x, p.y)
                } else {
                    if (last != null) { area.lineTo(lastX, size.height); area.lineTo(firstX, size.height); area.close() }
                    line.moveTo(p.x, p.y); area.moveTo(p.x, size.height); area.lineTo(p.x, p.y); firstX = p.x
                }
                last = s.time
                lastX = p.x
            }
            area.lineTo(lastX, size.height); area.lineTo(firstX, size.height); area.close()
            drawPath(area, Brush.verticalGradient(listOf(Halo.accent.copy(alpha = 0.4f), Halo.accent.copy(alpha = 0.02f))))
            drawPath(line, Halo.ink, style = Stroke(1.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            resting?.let {
                drawLine(Halo.ink.copy(alpha = 0.35f), Offset(0f, y(it)), Offset(size.width, y(it)), 1.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 8f)))
            }
        }
        HourLabels()
    }
}

@Composable
fun HourLabels() {
    Row(Modifier.fillMaxWidth()) {
        listOf("12 am", "6 am", "12 pm", "6 pm", "12 am").forEachIndexed { i, t ->
            Text(t, Modifier.weight(1f), style = TextStyle(fontSize = 10.sp, color = Halo.tertiary,
                textAlign = when (i) { 0 -> androidx.compose.ui.text.style.TextAlign.Start; 4 -> androidx.compose.ui.text.style.TextAlign.End; else -> androidx.compose.ui.text.style.TextAlign.Center }))
        }
    }
}

/** The three scores over the last seven days. */
@Composable
fun ScoreTrendCard(s: Snapshot, date: LocalDate, onClick: (() -> Unit)? = null) {
    val days = (6 downTo 0).map { date.minusDays(it.toLong()) }
    val today = s.scores(date)
    HaloCard(onClick = onClick) {
        HaloLabel("Last 7 days")
        Row {
            ScoreKind.entries.forEachIndexed { i, k ->
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.width(12.dp).height(3.dp).clip(CircleShape).background(trendColor(i)))
                        Spacer(Modifier.width(6.dp))
                        Text(k.title, style = Halo.small)
                    }
                    Text(k.value(today)?.let { Format.percent(it) } ?: "–", style = Halo.number(22.sp))
                }
            }
        }
        Canvas(Modifier.fillMaxWidth().height(140.dp)) {
            ScoreKind.entries.forEachIndexed { i, k ->
                val pts = days.mapIndexedNotNull { j, d ->
                    k.value(s.scores(d))?.let { Offset(size.width * j / 6f, (size.height * (1 - it)).toFloat()) }
                }
                if (pts.size >= 2) {
                    val p = Path().apply { pts.forEachIndexed { n, o -> if (n == 0) moveTo(o.x, o.y) else lineTo(o.x, o.y) } }
                    drawPath(p, trendColor(i), style = Stroke(if (i == 0) 2.5.dp.toPx() else 1.8.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                    drawCircle(Halo.accent, 3.5.dp.toPx(), pts.last())
                }
            }
        }
        Row(Modifier.fillMaxWidth()) {
            days.forEach { d ->
                Text(d.dayOfWeek.getDisplayName(DayStyle.NARROW, Locale.getDefault()), Modifier.weight(1f),
                    style = TextStyle(fontSize = 10.sp, color = Halo.tertiary, textAlign = androidx.compose.ui.text.style.TextAlign.Center))
            }
        }
    }
}

private fun trendColor(i: Int): Color = when (i) {
    0 -> Halo.ink
    1 -> Halo.ink.copy(alpha = 0.55f)
    else -> Halo.ink.copy(alpha = 0.3f)
}

/** What went into one of the three scores on a day. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FactorsSheet(s: Snapshot, kind: ScoreKind, date: LocalDate, onDismiss: () -> Unit) {
    val value = kind.value(s.scores(date))
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Halo.background) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(84.dp), contentAlignment = Alignment.Center) {
                    Ring(value ?: 0.0, Modifier.size(84.dp), stroke = 7.dp)
                    Text(value?.let { Format.percent(it) } ?: "–", style = Halo.number(26.sp))
                }
                Spacer(Modifier.width(16.dp))
                Column {
                    Text(kind.title, style = TextStyle(fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Halo.text))
                    Text(Format.dayTitle(date), style = Halo.small)
                }
            }
            Text(about(kind), style = Halo.small)
            s.factors(kind, date).forEach { f ->
                HaloCard(padding = 16.dp) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(f.name, Modifier.weight(1f), style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
                        Text(f.value, style = Halo.number(17.sp))
                    }
                    f.level?.let { ProgressBar(it, color = if (it < 0.34) Halo.accent else Halo.ink) }
                    Row {
                        Text(f.note, Modifier.weight(1f), style = Halo.small)
                        Spacer(Modifier.width(8.dp))
                        HaloLabel(f.weight)
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
        }
    }
}

private fun about(kind: ScoreKind): String = when (kind) {
    ScoreKind.RECOVERY -> "How ready your body is today, set once in the morning from last night: your heart rate variability and resting heart rate against your own last 30 days, and how well you slept."
    ScoreKind.EFFORT -> "How much you've done today. It starts at zero at midnight: half is your steps against your target, half your active minutes, where harder minutes count for more."
    ScoreKind.SLEEP -> "Time asleep against your need, deep and REM sleep, how much of your time in bed you slept, a calm night and a steady bedtime."
}

/** For screens that show "Mon", "Tue" … */
fun LocalDate.shortDay(): String = dayOfWeek.getDisplayName(DayStyle.SHORT, Locale.getDefault())

/** Whether this day is still to come. */
fun LocalDate.isFuture(): Boolean = isAfter(HaloTime.today())

val CardioFocus.short: String get() = title
