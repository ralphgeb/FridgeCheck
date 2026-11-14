package com.ralphgeb.halo.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.DirectionsBike
import androidx.compose.material.icons.automirrored.outlined.DirectionsRun
import androidx.compose.material.icons.automirrored.outlined.DirectionsWalk
import androidx.compose.material.icons.outlined.FitnessCenter
import androidx.compose.material.icons.outlined.Pool
import androidx.compose.material.icons.outlined.SportsTennis
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.Format
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.ReadinessWords
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.core.Workout
import com.ralphgeb.halo.data.HaloState
import java.time.LocalDate

@Composable
fun FitnessScreen(state: HaloState, actions: PageActions) {
    val s = state.snapshot
    val date = state.selected
    Page(state, actions, title = "Fitness") {
        item("days") { DayStrip(s, date, actions.select) }
        item("readiness") { ReadinessCard(s, date, state.syncing && state.isToday) }
        item("activities") { Activities(s, date, state.isToday) }
        s.day(date)?.zones?.let { z -> if (z.total > 0) item("zones") { ZonesCard(z) } }
        item("cardio") { CardioLoadCard(s, date) }
    }
}

/** A row of days, like a training log: an accent dot per workout, a faint ring on a rest day. */
@Composable
private fun DayStrip(s: Snapshot, selected: LocalDate, onSelect: (LocalDate) -> Unit) {
    val today = HaloTime.today()
    val days = (-27..3).map { today.plusDays(it.toLong()) }
    val list = rememberLazyListState()
    LaunchedEffect(selected) {
        val i = days.indexOf(selected).coerceAtLeast(0)
        list.animateScrollToItem((i - 3).coerceAtLeast(0))
    }
    LazyRow(state = list, contentPadding = PaddingValues(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        items(days, key = { it.toEpochDay() }) { d ->
            val on = d == selected
            val future = d.isAfter(today)
            val workouts = s.workouts(d).size
            Column(
                Modifier.width(44.dp).clip(RoundedCornerShape(14.dp)).clickable(enabled = !future) { onSelect(d) }.padding(vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(d.shortDay().take(1), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = Halo.tertiary))
                Box(
                    Modifier.size(36.dp).clip(CircleShape).background(if (on) Halo.ink else Color.Transparent)
                        .then(if (d == today && !on) Modifier.border(1.5.dp, Halo.accent, CircleShape) else Modifier),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("${d.dayOfMonth}", style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                        color = when { on -> Halo.background; future -> Halo.tertiary; else -> Halo.text }, fontFeatureSettings = "tnum"))
                }
                Row(Modifier.height(6.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    when {
                        future -> {}
                        workouts == 0 -> Box(Modifier.size(5.dp).border(1.dp, Halo.tertiary, CircleShape))
                        else -> repeat(minOf(3, workouts)) { Dot(Halo.accent, 5.dp) }
                    }
                }
            }
        }
    }
}

/** How ready you are to train, as a bar from "take a day off" to "go hard", and what it means. */
@Composable
private fun ReadinessCard(s: Snapshot, date: LocalDate, updating: Boolean) {
    val r = s.readiness(date)
    val (title, line) = if (r == null && updating) "Updating" to "Getting today's data from your band." else ReadinessWords.words(r, date)
    HaloCard {
        Row(verticalAlignment = Alignment.Bottom) {
            HaloLabel("Readiness", Modifier.weight(1f))
            Text(r?.let { "${Math.round(it * 100)}" } ?: "–", style = Halo.number(30.sp))
            Text(" / 100", style = Halo.small)
        }
        // segments, filled up to the readiness, the last one in the accent
        Canvas(Modifier.fillMaxWidth().height(12.dp)) {
            val n = 36
            val gap = 2.5.dp.toPx()
            val w = (size.width - gap * (n - 1)) / n
            val filled = ((r ?: 0.0) * n).toInt()
            for (i in 0 until n) {
                val color = when {
                    i < filled - 1 -> Halo.ink.copy(alpha = 0.85f)
                    i == filled - 1 -> Halo.accent
                    else -> Halo.track
                }
                drawRoundRect(color, Offset(i * (w + gap), 0f), Size(w, size.height), CornerRadius(2.dp.toPx()))
            }
        }
        Row {
            Text("Take a day off", Modifier.weight(1f), style = TextStyle(fontSize = 10.sp, color = Halo.tertiary))
            Text("Go hard", style = TextStyle(fontSize = 10.sp, color = Halo.tertiary))
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
            Text(line, style = Halo.small.copy(fontSize = 14.sp))
        }
    }
}

/** The day's workouts, or a rest day. */
@Composable
private fun Activities(s: Snapshot, date: LocalDate, isToday: Boolean) {
    val workouts = s.workouts(date)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.Bottom) {
            HaloLabel(if (isToday) "Today's activities" else "Activities", Modifier.weight(1f))
            if (workouts.isNotEmpty()) {
                Text("${workouts.size} · ${Format.duration(workouts.sumOf { it.minutes })}", style = Halo.small.copy(fontSize = 12.sp))
            }
        }
        if (workouts.isEmpty()) {
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp))
                    .border(1.dp, Halo.hairline, RoundedCornerShape(22.dp)).padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(44.dp).border(1.dp, Halo.hairline, CircleShape), contentAlignment = Alignment.Center) {
                    Text("z z", style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Halo.tertiary))
                }
                Spacer(Modifier.width(14.dp))
                Text(if (isToday) "No activities yet today" else "Rest day", style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium, color = Halo.secondary))
            }
        }
        workouts.forEach { WorkoutRow(it) }
    }
}

@Composable
private fun WorkoutRow(w: Workout) {
    HaloCard(padding = 14.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(46.dp).clip(CircleShape).background(Halo.accent.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
                Icon(iconFor(w.kind), w.kind, tint = Halo.accent, modifier = Modifier.size(22.dp))
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(w.kind, style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
                Text("${Format.time(w.start)} – ${Format.time(w.end)}", style = Halo.small.copy(fontSize = 12.sp))
                val bits = listOfNotNull(
                    w.distanceKm?.let { "%.1f km".format(it) },
                    w.calories?.let { "${Math.round(it)} kcal" },
                    w.averageHeartRate?.let { "${Math.round(it)} bpm avg" },
                )
                if (bits.isNotEmpty()) Text(bits.joinToString("  "), style = Halo.small.copy(fontSize = 12.sp, color = Halo.tertiary))
            }
            Text(Format.duration(w.minutes), style = Halo.number(18.sp))
        }
    }
}

private fun iconFor(kind: String): ImageVector {
    val k = kind.lowercase()
    return when {
        "run" in k -> Icons.AutoMirrored.Outlined.DirectionsRun
        "walk" in k || "hike" in k -> Icons.AutoMirrored.Outlined.DirectionsWalk
        "ride" in k || "bik" in k || "cycl" in k -> Icons.AutoMirrored.Outlined.DirectionsBike
        "swim" in k -> Icons.Outlined.Pool
        "tennis" in k -> Icons.Outlined.SportsTennis
        else -> Icons.Outlined.FitnessCenter
    }
}

/** Minutes in each heart-rate zone today. */
@Composable
private fun ZonesCard(z: com.ralphgeb.halo.core.ZoneMinutes) {
    HaloCard {
        Row(verticalAlignment = Alignment.Bottom) {
            HaloLabel("Heart zones", Modifier.weight(1f))
            Text(Format.duration(z.total), style = Halo.number(20.sp))
        }
        val zones = listOf("Moderate" to z.fatBurn, "Cardio" to z.cardio, "Peak" to z.peak)
        val max = maxOf(zones.maxOf { it.second }, 1.0)
        zones.forEachIndexed { i, (name, minutes) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(name, Modifier.width(78.dp), style = TextStyle(fontSize = 13.sp, color = Halo.text))
                Canvas(Modifier.weight(1f).height(12.dp)) {
                    drawRoundRect(Halo.track, size = size, cornerRadius = CornerRadius(6.dp.toPx()))
                    val w = (size.width * (minutes / max)).toFloat()
                    if (w > 0) drawRoundRect(if (i == 2) Halo.accent else Halo.ink.copy(alpha = 0.5f + 0.2f * i), size = Size(w, size.height), cornerRadius = CornerRadius(6.dp.toPx()))
                }
                Spacer(Modifier.width(10.dp))
                Text("${Math.round(minutes)} min", Modifier.width(56.dp), style = TextStyle(fontSize = 12.sp, color = Halo.secondary, fontFeatureSettings = "tnum"))
            }
        }
    }
}
