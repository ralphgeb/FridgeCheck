package com.ralphgeb.halo.ui

import androidx.compose.foundation.clickable
import com.ralphgeb.halo.core.HaloTime
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.background
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
    val open = actions.openMetric
    Page(state, actions, title = null) {
        item("rings") { Rings(s, date) { k -> open(k.metric) } }
        item("tiles") { MetricTiles(s, date, open) }
        item("balance") { BalanceCard(s, date, open) }
        s.day(date)?.let { d -> if (d.heartRate.size >= 6) item("heart") { HeartRateCard(d) { open(Metric.RESTING_HEART_RATE) } } }
        item("calories") { CaloriesCard(s, date, state.isToday) { open(Metric.ACTIVE_CALORIES) } }
        item("cardio") { CardioLoadCard(s, date) { open(Metric.CARDIO_LOAD) } }
        item("trend") { ScoreTrendCard(s, date) { open(Metric.RECOVERY) } }
    }
}

/** Recovery, Effort and Sleep: each a ring with its number, opening what went into it. */
@Composable
private fun Rings(s: Snapshot, date: LocalDate, onOpen: (ScoreKind) -> Unit) {
    val scores = s.shownScores(date)
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
private fun MetricTiles(s: Snapshot, date: LocalDate, open: (Metric) -> Unit) {
    val tiles = listOf(Metric.HRV, Metric.RESTING_HEART_RATE, Metric.STEPS, Metric.SLEEP_DURATION)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        tiles.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { m -> MetricTile(s, m, date, Modifier.weight(1f)) { open(m) } }
            }
        }
    }
}

@Composable
private fun MetricTile(s: Snapshot, m: Metric, date: LocalDate, modifier: Modifier, onClick: () -> Unit) {
    val v = s.value(m, date)
    val base = s.baseline(m, date)
    val series = s.series(m, 7, date).map { it.second }
    val title = when (m) {
        Metric.SLEEP_DURATION -> "Asleep"
        Metric.RESTING_HEART_RATE -> "Resting HR"
        else -> m.short
    }
    HaloCard(modifier, padding = 14.dp, onClick = onClick) {
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

/** The score's graph page. */
val ScoreKind.metric: Metric
    get() = when (this) {
        ScoreKind.RECOVERY -> Metric.RECOVERY
        ScoreKind.EFFORT -> Metric.EFFORT
        ScoreKind.SLEEP -> Metric.SLEEP_SCORE
    }

/** Calories: what moving burned on top of what your body uses at rest, as one split bar. */
@Composable
private fun CaloriesCard(s: Snapshot, date: LocalDate, isToday: Boolean, onClick: () -> Unit) {
    val p = s.profile
    val weight = s.days.lastOrNull { !it.date.isAfter(date) && it.weightKg != null }?.weightKg ?: p.weightKg
    // Mifflin–St Jeor, as on the iPhone; today counts only the part of the day gone so far
    val full = 10 * weight + 6.25 * p.heightCm - 5 * p.age + (if (p.male) 5 else -161)
    val resting = if (isToday) full * ((System.currentTimeMillis() - HaloTime.startOf(date)) / 86_400_000.0).coerceIn(0.0, 1.0) else full
    val active = s.day(date)?.activeCalories ?: 0.0
    val total = resting + active
    HaloCard(onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HaloLabel("Calories", Modifier.weight(1f))
            Chevron()
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Text(Format.thousands(Math.round(total)), style = Halo.number(30.sp))
            Text(if (isToday) "  kcal so far" else "  kcal", Modifier.padding(bottom = 5.dp), style = Halo.small)
        }
        Row(Modifier.fillMaxWidth().height(8.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            val share = if (total > 0) (active / total).toFloat().coerceIn(0.02f, 0.98f) else 0.02f
            Box(Modifier.weight(share).fillMaxHeight().clip(CircleShape).background(Halo.ink))
            Box(Modifier.weight(1 - share).fillMaxHeight().clip(CircleShape).background(Halo.ink.copy(alpha = 0.18f)))
        }
        Row {
            CalorieLegend("Active", active, Halo.ink, Modifier.weight(1f))
            CalorieLegend("Resting", resting, Halo.ink.copy(alpha = 0.18f), Modifier)
        }
    }
}

@Composable
private fun CalorieLegend(title: String, v: Double, color: androidx.compose.ui.graphics.Color, modifier: Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(12.dp).height(6.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(6.dp))
        Text(title, style = Halo.small)
        Spacer(Modifier.width(6.dp))
        Text(Format.thousands(Math.round(v)), style = Halo.number(14.sp, FontWeight.Medium))
    }
}
