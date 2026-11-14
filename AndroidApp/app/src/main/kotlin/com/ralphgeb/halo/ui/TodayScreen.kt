package com.ralphgeb.halo.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.Format
import com.ralphgeb.halo.core.Metric
import com.ralphgeb.halo.core.ScoreKind
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.data.HaloState
import java.time.LocalDate

@Composable
fun TodayScreen(state: HaloState, actions: PageActions) {
    val s = state.snapshot
    val date = state.selected
    var sheet by remember { mutableStateOf<ScoreKind?>(null) }
    Page(state, actions, title = null) {
        item("rings") { Rings(s, date) { sheet = it } }
        item("tiles") { MetricTiles(s, date) }
        item("balance") { BalanceCard(s, date) }
        s.day(date)?.let { d -> if (d.heartRate.size >= 6) item("heart") { HeartRateCard(d) } }
        item("cardio") { CardioLoadCard(s, date) }
        item("trend") { ScoreTrendCard(s, date) }
    }
    sheet?.let { FactorsSheet(s, it, date) { sheet = null } }
}

/** Recovery, Effort and Sleep: each a ring with its number, opening what went into it. */
@Composable
private fun Rings(s: Snapshot, date: LocalDate, onOpen: (ScoreKind) -> Unit) {
    val scores = s.scores(date)
    Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        ScoreKind.entries.forEach { k ->
            Column(Modifier.weight(1f).clickable { onOpen(k) }, horizontalAlignment = Alignment.CenterHorizontally) {
                Box(Modifier.size(100.dp), contentAlignment = Alignment.Center) {
                    Ring(k.value(scores) ?: 0.0, Modifier.size(100.dp), stroke = 9.dp)
                    Text(k.value(scores)?.let { Format.percent(it) } ?: "–", style = Halo.number(32.sp))
                }
                Spacer(Modifier.height(10.dp))
                HaloLabel(k.title)
            }
        }
    }
}

/** HRV, resting heart rate, steps and time asleep, each against your usual with a week's line. */
@Composable
private fun MetricTiles(s: Snapshot, date: LocalDate) {
    val tiles = listOf(Metric.HRV, Metric.RESTING_HEART_RATE, Metric.STEPS, Metric.SLEEP_DURATION)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        tiles.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { m -> MetricTile(s, m, date, Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun MetricTile(s: Snapshot, m: Metric, date: LocalDate, modifier: Modifier) {
    val v = s.value(m, date)
    val base = s.baseline(m, date)
    val series = s.series(m, 7, date).map { it.second }
    val title = when (m) {
        Metric.SLEEP_DURATION -> "Asleep"
        Metric.RESTING_HEART_RATE -> "Resting HR"
        else -> m.short
    }
    HaloCard(modifier, padding = 14.dp) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                HaloLabel(title)
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(v?.let { m.format(it) } ?: "–", style = Halo.number(24.sp))
                    if (m.unit.isNotEmpty() && m != Metric.STEPS && v != null) Text(" ${m.unit}", style = Halo.small)
                }
                if (v != null && base != null && base > 0) {
                    val change = Math.round((v / base - 1) * 100).toInt()
                    val worse = when (m.higherIsBetter) {
                        true -> change < -5
                        false -> change > 5
                        null -> false
                    }
                    Text(
                        "${if (change >= 0) "↗" else "↘"} ${kotlin.math.abs(change)}%",
                        style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = if (worse) Halo.accent else Halo.secondary),
                    )
                }
            }
            Sparkline(series, Modifier.width(52.dp).height(34.dp))
        }
    }
}
