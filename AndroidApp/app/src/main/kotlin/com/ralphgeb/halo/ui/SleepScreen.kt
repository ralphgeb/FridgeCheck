package com.ralphgeb.halo.ui

import androidx.compose.foundation.Canvas
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.Format
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.Metric
import com.ralphgeb.halo.core.ScoreKind
import com.ralphgeb.halo.core.SleepSession
import com.ralphgeb.halo.core.SleepStageKind
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.data.HaloState
import java.time.LocalDate
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

@Composable
fun SleepScreen(state: HaloState, actions: PageActions) {
    val s = state.snapshot
    val date = state.selected
    val night = s.day(date)?.sleep
    val open = actions.openMetric
    Page(state, actions, title = "Sleep") {
        if (night == null) {
            item("none") {
                HaloCard { Text("No sleep recorded for ${Format.dayTitle(date).lowercase()}.", style = Halo.small.copy(fontSize = 15.sp)) }
            }
        } else {
            item("hero") { Hero(s, date, night) { open(Metric.SLEEP_SCORE) } }
            item("stats") { Stats(s, date, night, open) }
            if (night.stages.isNotEmpty()) item("stages") { Hypnogram(night) { open(Metric.SLEEP_DURATION) } }
            val heart = nightHeart(s, date, night)
            if (heart.size >= 6) item("heart") { SleepHeart(night, heart) { open(Metric.RESTING_HEART_RATE) } }
            item("breakdown") { Breakdown(night) { open(Metric.SLEEP_DURATION) } }
        }
        item("bank") { SleepBank(s, date) { open(Metric.SLEEP_DURATION) } }
        item("rhythm") { SleepRhythm(s, date) { open(Metric.SLEEP_DURATION) } }
    }
}

fun stageColor(k: SleepStageKind): Color = when (k) {
    SleepStageKind.DEEP -> Halo.ink
    SleepStageKind.LIGHT -> Halo.ink.copy(alpha = 0.55f)
    SleepStageKind.REM -> Halo.ink.copy(alpha = 0.8f)
    SleepStageKind.AWAKE -> Halo.accent
}

@Composable
private fun Hero(s: Snapshot, date: LocalDate, night: SleepSession, onOpen: () -> Unit) {
    val score = s.scores(date).sleep
    val need = s.targets.sleepNeedHours * 60
    val gap = night.minutesAsleep - need
    HaloCard(onClick = onOpen) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                HaloLabel("Time asleep")
                Text(Format.duration(night.minutesAsleep), style = Halo.number(44.sp))
                Text("${Format.time(night.start)} – ${Format.time(night.end)}", style = Halo.small.copy(fontSize = 14.sp))
                Text(
                    if (abs(gap) < 10) "Right on your need" else if (gap < 0) "${Format.duration(-gap)} short of your need" else "${Format.duration(gap)} over your need",
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium, color = if (gap < -10) Halo.accent else Halo.secondary),
                )
            }
            Box(Modifier.size(110.dp), contentAlignment = Alignment.Center) {
                Ring(score ?: 0.0, Modifier.size(110.dp), stroke = 8.dp)
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(score?.let { Format.percent(it) } ?: "–", style = Halo.number(30.sp))
                    Text("Score", style = Halo.small.copy(fontSize = 11.sp))
                }
            }
        }
    }
}

/** The night's numbers, two to a row. */
@Composable
private fun Stats(s: Snapshot, date: LocalDate, night: SleepSession, open: (Metric) -> Unit) {
    val day = s.day(date)
    val stats = listOf(
        Triple("Efficiency", "${Math.round(night.efficiency * 100)}%", Metric.SLEEP_SCORE),
        Triple("Woke up", "${night.wakeUps}×", Metric.SLEEP_SCORE),
        Triple("Fell asleep in", Format.duration(night.minutesToFallAsleep), Metric.SLEEP_SCORE),
        Triple("Deep + REM", Format.duration(night.minutes(SleepStageKind.DEEP) + night.minutes(SleepStageKind.REM)), Metric.SLEEP_DURATION),
        Triple("Breathing", day?.respiratoryRate?.let { "%.1f br/min".format(it) } ?: "–", Metric.RESPIRATORY_RATE),
        Triple("Overnight HRV", day?.hrv?.let { "${Math.round(it)} ms" } ?: "–", Metric.HRV),
    )
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        stats.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { (label, value, metric) ->
                    HaloCard(Modifier.weight(1f), padding = 14.dp, onClick = { open(metric) }) {
                        HaloLabel(label)
                        Text(value, style = Halo.number(22.sp))
                    }
                }
            }
        }
    }
}

/** Stages through the night: awake at the top, deep at the bottom. */
@Composable
private fun Hypnogram(night: SleepSession, onClick: () -> Unit) {
    val order = listOf(SleepStageKind.AWAKE, SleepStageKind.REM, SleepStageKind.LIGHT, SleepStageKind.DEEP)
    HaloCard(onClick = onClick) {
        HaloLabel("Stages")
        Row {
            Column(Modifier.height(140.dp).width(46.dp), verticalArrangement = Arrangement.SpaceAround) {
                order.forEach { Text(it.title, style = TextStyle(fontSize = 11.sp, color = Halo.secondary)) }
            }
            Canvas(Modifier.weight(1f).height(140.dp)) {
                val span = max(1L, night.end - night.start).toDouble()
                val lane = size.height / order.size
                order.indices.forEach { i ->
                    val y = lane * i + lane / 2
                    drawLine(Halo.hairline, Offset(0f, y), Offset(size.width, y), 1f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(4f, 6f)))
                }
                night.stages.forEach { st ->
                    val row = order.indexOf(st.kind)
                    val x0 = (size.width * ((st.start - night.start) / span)).toFloat()
                    val x1 = (size.width * ((st.end - night.start) / span)).toFloat()
                    val h = lane * 0.55f
                    drawRoundRect(stageColor(st.kind), Offset(x0, lane * row + (lane - h) / 2), Size(max(2f, x1 - x0), h), CornerRadius(min(3.dp.toPx(), (x1 - x0) / 2)))
                }
            }
        }
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.width(46.dp))
            Text(Format.time(night.start), Modifier.weight(1f), style = TextStyle(fontSize = 10.sp, color = Halo.tertiary))
            Text(Format.time(night.end), style = TextStyle(fontSize = 10.sp, color = Halo.tertiary))
        }
    }
}

/** Minutes in each stage and its share of the night, against a usual range. */
@Composable
private fun Breakdown(night: SleepSession, onClick: () -> Unit) {
    val stages = listOf(
        Triple(SleepStageKind.DEEP, "13–23%", night.minutes(SleepStageKind.DEEP)),
        Triple(SleepStageKind.LIGHT, "50–60%", night.minutes(SleepStageKind.LIGHT)),
        Triple(SleepStageKind.REM, "20–25%", night.minutes(SleepStageKind.REM)),
        Triple(SleepStageKind.AWAKE, "under 10%", if (night.stages.isEmpty()) night.minutesAwake else night.minutes(SleepStageKind.AWAKE)),
    )
    val total = max(1.0, stages.sumOf { it.third })
    HaloCard(onClick = onClick) {
        HaloLabel("Breakdown")
        Canvas(Modifier.fillMaxWidth().height(10.dp)) {
            var x = 0f
            val gap = 3.dp.toPx()
            stages.forEach { (k, _, m) ->
                val w = ((size.width - gap * 3) * (m / total)).toFloat()
                if (w > 0) drawRoundRect(stageColor(k), Offset(x, 0f), Size(w, size.height), CornerRadius(size.height / 2))
                x += w + gap
            }
        }
        stages.forEach { (k, usual, m) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Dot(stageColor(k), 8.dp)
                Spacer(Modifier.width(10.dp))
                Text(k.title, style = TextStyle(fontSize = 15.sp, color = Halo.text))
                Spacer(Modifier.width(6.dp))
                Text(usual, Modifier.weight(1f), style = TextStyle(fontSize = 12.sp, color = Halo.tertiary))
                Text(Format.duration(m), style = Halo.number(15.sp))
                Text("${Math.round(m / total * 100)}%", Modifier.width(44.dp), style = TextStyle(fontSize = 13.sp, color = Halo.secondary, textAlign = androidx.compose.ui.text.style.TextAlign.End))
            }
        }
    }
}

/** The last seven nights against your need, the running balance and when to go to bed tonight. */
@Composable
private fun SleepBank(s: Snapshot, date: LocalDate, onClick: () -> Unit) {
    val nights = s.nights(date, 7)
    if (nights.isEmpty()) return
    val balance = nights.sumOf { it.balance }
    val biggest = max(60.0, nights.maxOf { abs(it.balance) })
    val bedtime = s.bedtime(date)
    HaloCard(onClick = onClick) {
        Row(verticalAlignment = Alignment.Bottom) {
            HaloLabel("Sleep bank", Modifier.weight(1f))
            Text("Need ${Format.duration(s.targets.sleepNeedHours * 60)}", style = Halo.small.copy(fontSize = 12.sp))
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Text((if (balance < 0) "−" else "+") + Format.duration(abs(balance)), style = Halo.number(34.sp))
            Spacer(Modifier.weight(1f))
            Text(if (balance < 0) "Debt" else "Ahead", style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = if (balance < 0) Halo.accent else Halo.text))
        }
        Text("Last ${nights.size} nights", style = Halo.small)
        Row(Modifier.fillMaxWidth().height(110.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            nights.forEach { n ->
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Canvas(Modifier.width(18.dp).weight(1f)) {
                        val half = size.height / 2
                        drawLine(Halo.hairline, Offset(-20f, half), Offset(size.width + 20f, half), 1f)
                        val h = max(3f, (half * (abs(n.balance) / biggest)).toFloat())
                        val top = if (n.balance < 0) half else half - h
                        drawRoundRect(if (n.balance < 0) Halo.accent else Halo.ink, Offset(0f, top), Size(size.width, h), CornerRadius(4.dp.toPx()))
                    }
                    Text(n.date.shortDay().take(1), style = TextStyle(fontSize = 10.sp, color = Halo.tertiary))
                }
            }
        }
        bedtime?.let {
            Text("Tonight, aim for bed by ${Format.time(it)}", style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Halo.text))
        }
    }
}

/** Heart rate through the night: the day's and the evening before's readings inside the night. */
private fun nightHeart(s: Snapshot, date: LocalDate, night: SleepSession): List<com.ralphgeb.halo.core.HeartSample> =
    (s.day(date.minusDays(1))?.heartRate.orEmpty() + s.day(date)?.heartRate.orEmpty())
        .filter { it.time in night.start..night.end }.sortedBy { it.time }

/**
 * Heart rate by stage: the night's heart rate with the stages as a strip under it. Tap Deep, Light,
 * REM or Awake to light up where that stage fell and its readings.
 */
@Composable
private fun SleepHeart(night: SleepSession, samples: List<com.ralphgeb.halo.core.HeartSample>, onClick: () -> Unit) {
    var picked by remember(night.start) { mutableStateOf<SleepStageKind?>(null) }
    val lowest = samples.minBy { it.bpm }
    val hasStages = night.stages.isNotEmpty()
    fun inStage(k: SleepStageKind): List<com.ralphgeb.halo.core.HeartSample> {
        val spans = night.stages.filter { it.kind == k }
        return samples.filter { s -> spans.any { s.time >= it.start && s.time < it.end } }
    }
    HaloCard {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable(onClick = onClick)) {
            HaloLabel(if (hasStages) "Heart rate by stage" else "Heart rate overnight", Modifier.weight(1f))
            Text("Lowest ${Math.round(lowest.bpm)} at ${Format.time(lowest.time)}", style = Halo.small.copy(fontSize = 12.sp))
        }
        val ink = Halo.ink
        val accent = Halo.accent
        val hairline = Halo.hairline
        val lo = samples.minOf { it.bpm } - 6
        val hi = samples.maxOf { it.bpm } + 4
        val span = max(1L, night.end - night.start).toDouble()
        val pickedSpans = picked?.let { k -> night.stages.filter { it.kind == k } }.orEmpty()
        val pickedSamples = picked?.let { inStage(it) }.orEmpty()
        Row {
            Canvas(Modifier.weight(1f).height(140.dp)) {
                fun x(t: Long) = (size.width * ((t - night.start) / span)).toFloat()
                fun y(v: Double) = (size.height - size.height * ((v - lo) / (hi - lo))).toFloat()
                listOf(0.25, 0.5, 0.75).forEach { f -> drawLine(hairline, Offset(0f, size.height * f.toFloat()), Offset(size.width, size.height * f.toFloat()), 1f) }
                pickedSpans.forEach { st -> drawRect(accent.copy(alpha = 0.16f), Offset(x(st.start), 0f), Size(max(1f, x(st.end) - x(st.start)), size.height)) }
                val path = androidx.compose.ui.graphics.Path()
                samples.forEachIndexed { i, p -> if (i == 0) path.moveTo(x(p.time), y(p.bpm)) else path.lineTo(x(p.time), y(p.bpm)) }
                drawPath(path, ink.copy(alpha = if (picked == null) 1f else 0.45f), style = androidx.compose.ui.graphics.drawscope.Stroke(1.5.dp.toPx(),
                    cap = androidx.compose.ui.graphics.StrokeCap.Round, join = androidx.compose.ui.graphics.StrokeJoin.Round))
                pickedSamples.forEach { drawCircle(accent, 2.dp.toPx(), Offset(x(it.time), y(it.bpm))) }
                if (picked == null) drawCircle(accent, 4.dp.toPx(), Offset(x(lowest.time), y(lowest.bpm)))
            }
            Column(Modifier.height(140.dp).width(30.dp).padding(start = 6.dp), verticalArrangement = Arrangement.SpaceBetween) {
                listOf(hi, (hi + lo) / 2, lo).forEach { Text("${Math.round(it)}", style = TextStyle(fontSize = 10.sp, color = Halo.tertiary)) }
            }
        }
        if (hasStages) {
            // the stages as one strip, on the same time axis: deeper stages stand taller
            Canvas(Modifier.fillMaxWidth().padding(end = 30.dp).height(22.dp)) {
                night.stages.forEach { st ->
                    val x0 = (size.width * ((st.start - night.start) / span)).toFloat()
                    val x1 = (size.width * ((st.end - night.start) / span)).toFloat()
                    val h = size.height * (0.35f + 0.65f * st.kind.depth / 3f)
                    val c = if (st.kind == picked) accent else ink.copy(alpha = if (picked == null) 0.2f + 0.18f * st.kind.depth else 0.12f)
                    drawRect(c, Offset(x0, size.height - h), Size(max(1f, x1 - x0), h))
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(end = 30.dp)) {
            Text(Format.time(night.start), Modifier.weight(1f), style = TextStyle(fontSize = 10.sp, color = Halo.tertiary))
            Text(Format.time(night.end), style = TextStyle(fontSize = 10.sp, color = Halo.tertiary))
        }
        if (hasStages) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(SleepStageKind.DEEP, SleepStageKind.LIGHT, SleepStageKind.REM, SleepStageKind.AWAKE).forEach { k ->
                    val on = picked == k
                    val bpm = inStage(k).map { it.bpm }.takeIf { it.isNotEmpty() }?.average()
                    Column(
                        Modifier.weight(1f).clip(androidx.compose.foundation.shape.RoundedCornerShape(12.dp))
                            .background(if (on) Halo.accent.copy(alpha = 0.12f) else Halo.track)
                            .clickable { picked = if (on) null else k }.padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text(k.title, style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = if (on) Halo.accent else Halo.secondary))
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(bpm?.let { "${Math.round(it)}" } ?: "–", style = Halo.number(18.sp))
                            Text(" bpm", Modifier.padding(bottom = 2.dp), style = TextStyle(fontSize = 9.sp, fontWeight = FontWeight.Medium, color = Halo.secondary))
                        }
                        Text(Format.duration(night.minutes(k)), style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Medium, color = Halo.tertiary))
                    }
                }
            }
            Text(picked?.let { stageNote(it) } ?: "Tap a stage to see where it falls in the night.", style = Halo.small.copy(fontSize = 12.sp))
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("Lowest" to samples.minOf { it.bpm }, "Average" to samples.map { it.bpm }.average(), "Highest" to samples.maxOf { it.bpm }).forEach { (t, v) ->
                    Column(Modifier.weight(1f).clip(androidx.compose.foundation.shape.RoundedCornerShape(12.dp)).background(Halo.track).padding(10.dp)) {
                        Text(t, style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Halo.secondary))
                        Text("${Math.round(v)} bpm", style = Halo.number(17.sp))
                    }
                }
            }
        }
    }
}

private fun stageNote(k: SleepStageKind): String = when (k) {
    SleepStageKind.DEEP -> "Deep sleep comes early in the night, and your heart rate is at its lowest and steadiest."
    SleepStageKind.LIGHT -> "Light sleep fills most of the night, between the deeper and dreaming stages."
    SleepStageKind.REM -> "REM gets longer towards morning. Heart rate rises and varies, like when you're awake."
    SleepStageKind.AWAKE -> "Short wake-ups are normal. Most you won't remember."
}

/** Two weeks of nights from 8 pm to noon, each with its stages, against your usual bed and wake times. */
@Composable
private fun SleepRhythm(s: Snapshot, date: LocalDate, onClick: () -> Unit) {
    val nights = s.days.filter { !it.date.isAfter(date) }.takeLast(14).mapNotNull { d -> d.sleep?.let { d.date to it } }
    // hours from the evening before's midnight: 20 = 8 pm, 36 = noon
    fun hour(t: Long, wake: LocalDate) = (t - HaloTime.startOf(wake.minusDays(1))) / 3_600_000.0
    val beds = nights.map { (d, n) -> hour(n.start, d) }
    val wakes = nights.map { (d, n) -> hour(n.end, d) }
    val usualBed = beds.takeIf { it.isNotEmpty() }?.sorted()?.let { it[it.size / 2] }
    val usualWake = wakes.takeIf { it.isNotEmpty() }?.sorted()?.let { it[it.size / 2] }
    fun clock(h: Double): String = Format.time(HaloTime.startOf(date.minusDays(1)) + (h * 3_600_000).toLong())
    HaloCard(onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HaloLabel("Sleep rhythm · 2 weeks", Modifier.weight(1f))
            if (usualBed != null && usualWake != null) Text("${clock(usualBed)} – ${clock(usualWake)}", style = Halo.small.copy(fontSize = 12.sp))
        }
        if (nights.size < 3) {
            Text("Shows once there are a few nights.", style = Halo.small)
        } else {
        val ink = Halo.ink
        val accent = Halo.accent
        Canvas(Modifier.fillMaxWidth().height((nights.size * 11).dp)) {
            val row = size.height / nights.size
            fun x(h: Double) = (size.width * ((h - 20) / 16)).toFloat().coerceIn(0f, size.width)
            listOfNotNull(usualBed, usualWake).forEach { m ->
                drawLine(accent.copy(alpha = 0.6f), Offset(x(m), 0f), Offset(x(m), size.height), 1.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f)))
            }
            nights.forEachIndexed { i, (d, n) ->
                val y = i * row + row * 0.2f
                val h = row * 0.6f
                val shown = d == date
                val a = x(hour(n.start, d))
                val b = x(hour(n.end, d))
                if (n.stages.isEmpty()) {
                    drawRoundRect(if (shown) ink else ink.copy(alpha = 0.4f), Offset(a, y), Size(max(2f, b - a), h), CornerRadius(h / 2))
                } else {
                    drawRoundRect(ink.copy(alpha = 0.08f), Offset(a, y), Size(max(2f, b - a), h), CornerRadius(h / 2))
                    n.stages.filter { it.kind != SleepStageKind.AWAKE }.forEach { st ->
                        val c = when (st.kind) { SleepStageKind.DEEP -> ink; SleepStageKind.REM -> accent; else -> ink.copy(alpha = 0.4f) }
                        val sa = x(hour(st.start, d))
                        val sb = x(hour(st.end, d))
                        drawRect(if (shown) c else c.copy(alpha = c.alpha * 0.7f), Offset(sa, y), Size(max(1f, sb - sa), h))
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth()) {
            listOf("8 pm", "midnight", "4 am", "8 am", "noon").forEachIndexed { i, t ->
                Text(t, Modifier.weight(1f), style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Medium, color = Halo.tertiary,
                    textAlign = when (i) { 0 -> androidx.compose.ui.text.style.TextAlign.Start; 4 -> androidx.compose.ui.text.style.TextAlign.End; else -> androidx.compose.ui.text.style.TextAlign.Center }))
            }
        }
        }
    }
}
