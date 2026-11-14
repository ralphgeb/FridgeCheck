package com.ralphgeb.halo.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.Metric
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.data.HaloState
import java.time.LocalDate

@Composable
fun HealthScreen(state: HaloState, actions: PageActions) {
    val s = state.snapshot
    val date = state.selected
    Page(state, actions, title = "Health") {
        item("monitor") { Monitor(s, date) }
        Metric.sections.forEach { (title, metrics) ->
            val shown = metrics.filter { m -> s.series(m, 30, date).isNotEmpty() }
            if (shown.isNotEmpty()) item("section-$title") { Section(s, date, title, shown) }
        }
        item("note") {
            Text(
                "Normal ranges are your own: the middle of your last 30 days. Halo isn't a medical device.",
                Modifier.fillMaxWidth().padding(horizontal = 24.dp),
                style = TextStyle(fontSize = 12.sp, color = Halo.tertiary, textAlign = TextAlign.Center),
            )
        }
    }
}

/** Like a health monitor: one mark per overnight vital, on a short line whose middle is your normal. */
@Composable
private fun Monitor(s: Snapshot, date: LocalDate) {
    val vitals = Metric.monitored.map { m ->
        val v = s.value(m, date)
        val range = s.normalRange(m, date)
        Triple(m, v, range)
    }
    val measured = vitals.filter { it.second != null && it.third != null }
    val outside = measured.count { (m, v, r) -> m.isConcerning(v!!, r!!) }
    HaloCard {
        HaloLabel("Health monitor")
        Text(
            when {
                measured.isEmpty() -> "Waiting for a night's vitals"
                outside == 0 -> "All vitals in your normal range"
                outside == 1 -> "1 vital outside your range"
                else -> "$outside vitals outside your range"
            },
            style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Halo.text),
        )
        Row(Modifier.fillMaxWidth()) {
            vitals.forEach { (m, v, range) ->
                val bad = v != null && range != null && m.isConcerning(v, range)
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(m.short, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Halo.secondary))
                    Text(v?.let { m.format(it) } ?: "–", style = Halo.number(18.sp).copy(color = if (bad) Halo.accent else Halo.text))
                    RangeTicks(v, range, bad, Modifier.width(46.dp).height(12.dp))
                }
            }
        }
    }
}

/** A short line: ticks at the edges of your normal range and its middle, a dot where the day is. */
@Composable
fun RangeTicks(v: Double?, range: com.ralphgeb.halo.core.NormalRange?, bad: Boolean, modifier: Modifier) {
    Canvas(modifier) {
        val y = size.height / 2
        drawLine(Halo.track, Offset(0f, y), Offset(size.width, y), 2.dp.toPx())
        listOf(-0.6f, 0f, 0.6f).forEach { t ->
            val x = size.width / 2 + t * size.width / 2
            val h = if (t == 0f) 4.dp.toPx() else 3.dp.toPx()
            drawLine(Halo.ink.copy(alpha = if (t == 0f) 0.45f else 0.2f), Offset(x, y - h), Offset(x, y + h), 1.dp.toPx())
        }
        if (v != null && range != null) {
            val mid = (range.low + range.high) / 2
            val half = maxOf((range.high - range.low) / 2, 0.0001)
            val g = ((v - mid) / half * 0.6).coerceIn(-1.0, 1.0).toFloat()
            drawCircle(if (bad) Halo.accent else Halo.ink, 4.dp.toPx(), Offset(size.width / 2 + g * size.width / 2, y))
        }
    }
}

@Composable
private fun Section(s: Snapshot, date: LocalDate, title: String, metrics: List<Metric>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        PaddedLabel(title)
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Halo.card)) {
            metrics.forEachIndexed { i, m ->
                MetricRow(s, m, date)
                if (i < metrics.lastIndex) Box(Modifier.padding(start = 18.dp).fillMaxWidth().height(0.5.dp).background(Halo.hairline))
            }
        }
    }
}

@Composable
private fun MetricRow(s: Snapshot, m: Metric, date: LocalDate) {
    val v = s.value(m, date)
    val range = s.normalRange(m, date)
    val base = s.baseline(m, date)
    val bad = v != null && range != null && m in Metric.monitored && m.isConcerning(v, range)
    val note = when {
        m in Metric.monitored && range != null -> "Normal ${m.format(range.low)}–${m.format(range.high)}"
        base != null -> "30-day average ${m.format(base)}"
        else -> "Builds up over a few days"
    }
    Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(m.title, style = TextStyle(fontSize = 16.sp, color = Halo.text))
            Text(note, style = Halo.small.copy(fontSize = 12.sp))
        }
        Sparkline(s.series(m, 14, date).map { it.second }, Modifier.width(64.dp).height(30.dp), dot = if (bad) Halo.accent else Halo.ink)
        Column(Modifier.width(72.dp), horizontalAlignment = Alignment.End) {
            Text(v?.let { m.format(it) } ?: "–", style = Halo.number(20.sp).copy(color = if (bad) Halo.accent else Halo.text))
            if (m.unit.isNotEmpty() && m != Metric.SLEEP_DURATION) Text(m.unit, style = TextStyle(fontSize = 11.sp, color = Halo.tertiary))
        }
    }
}
