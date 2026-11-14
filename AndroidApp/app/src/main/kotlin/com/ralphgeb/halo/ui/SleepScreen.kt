package com.ralphgeb.halo.ui

import androidx.compose.foundation.Canvas
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
import com.ralphgeb.halo.core.ScoreKind
import com.ralphgeb.halo.core.SleepSession
import com.ralphgeb.halo.core.SleepStageKind
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.data.HaloState
import java.time.LocalDate
import kotlin.math.abs
import kotlin.math.max

@Composable
fun SleepScreen(state: HaloState, actions: PageActions) {
    val s = state.snapshot
    val date = state.selected
    val night = s.day(date)?.sleep
    var sheet by remember { mutableStateOf(false) }
    Page(state, actions, title = "Sleep") {
        if (night == null) {
            item("none") {
                HaloCard { Text("No sleep recorded for ${Format.dayTitle(date).lowercase()}.", style = Halo.small.copy(fontSize = 15.sp)) }
            }
        } else {
            item("hero") { Hero(s, date, night) { sheet = true } }
            item("stats") { Stats(s, date, night) }
            if (night.stages.isNotEmpty()) item("stages") { Hypnogram(night) }
            item("breakdown") { Breakdown(night) }
        }
        item("bank") { SleepBank(s, date) }
    }
    if (sheet) FactorsSheet(s, ScoreKind.SLEEP, date) { sheet = false }
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
private fun Stats(s: Snapshot, date: LocalDate, night: SleepSession) {
    val day = s.day(date)
    val stats = listOf(
        "Efficiency" to "${Math.round(night.efficiency * 100)}%",
        "Woke up" to "${night.wakeUps}×",
        "Fell asleep in" to Format.duration(night.minutesToFallAsleep),
        "Deep + REM" to Format.duration(night.minutes(SleepStageKind.DEEP) + night.minutes(SleepStageKind.REM)),
        "Breathing" to (day?.respiratoryRate?.let { "%.1f br/min".format(it) } ?: "–"),
        "Overnight HRV" to (day?.hrv?.let { "${Math.round(it)} ms" } ?: "–"),
    )
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        stats.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { (label, value) ->
                    HaloCard(Modifier.weight(1f), padding = 14.dp) {
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
private fun Hypnogram(night: SleepSession) {
    val order = listOf(SleepStageKind.AWAKE, SleepStageKind.REM, SleepStageKind.LIGHT, SleepStageKind.DEEP)
    HaloCard {
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
                    drawRoundRect(stageColor(st.kind), Offset(x0, lane * row + (lane - h) / 2), Size(max(2f, x1 - x0), h), CornerRadius(h / 2))
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
private fun Breakdown(night: SleepSession) {
    val stages = listOf(
        Triple(SleepStageKind.DEEP, "13–23%", night.minutes(SleepStageKind.DEEP)),
        Triple(SleepStageKind.LIGHT, "50–60%", night.minutes(SleepStageKind.LIGHT)),
        Triple(SleepStageKind.REM, "20–25%", night.minutes(SleepStageKind.REM)),
        Triple(SleepStageKind.AWAKE, "under 10%", if (night.stages.isEmpty()) night.minutesAwake else night.minutes(SleepStageKind.AWAKE)),
    )
    val total = max(1.0, stages.sumOf { it.third })
    HaloCard {
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
private fun SleepBank(s: Snapshot, date: LocalDate) {
    val nights = s.nights(date, 7)
    if (nights.isEmpty()) return
    val balance = nights.sumOf { it.balance }
    val biggest = max(60.0, nights.maxOf { abs(it.balance) })
    val bedtime = s.bedtime(date)
    HaloCard {
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
