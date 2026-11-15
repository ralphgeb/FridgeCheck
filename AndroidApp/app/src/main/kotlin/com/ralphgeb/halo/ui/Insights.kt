package com.ralphgeb.halo.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.DirectionsWalk
import androidx.compose.material.icons.automirrored.outlined.TrendingUp
import androidx.compose.material.icons.outlined.Autorenew
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Bedtime
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.LocalFireDepartment
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.Format
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.ScoreEngine
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.core.Workout
import java.time.LocalDate
import java.time.format.TextStyle as DayStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** One line of insight: an icon, a short headline and a sentence. */
data class InsightLine(val icon: ImageVector, val title: String, val text: String)

private fun signed(v: Double, unit: String): String = (if (v >= 0) "+" else "−") + "${Math.round(abs(v))}$unit"
private fun pct(v: Double) = "${Math.round(v * 100)}"

@Composable
fun InsightRows(lines: List<InsightLine>) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        lines.forEach { l ->
            Row(verticalAlignment = Alignment.Top) {
                Box(Modifier.size(32.dp).clip(CircleShape).background(Halo.accent.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
                    Icon(l.icon, null, tint = Halo.ink, modifier = Modifier.size(16.dp))
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(l.title, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
                    Text(l.text, style = TextStyle(fontSize = 13.sp, color = Halo.secondary))
                }
            }
        }
    }
}

/**
 * What your last two months of activity say, read across workouts, steps, cardio load, sleep and
 * recovery (as on the iPhone). Each line shows once there's enough to say it.
 */
@Composable
fun FitnessInsightsCard(s: Snapshot, date: LocalDate) {
    val lines = remember(s, date) { fitnessInsights(s, date) }
    if (lines.isEmpty()) return
    HaloCard {
        HaloLabel("Insights · last 60 days")
        InsightRows(lines)
    }
}

/** A workout's broad kind, so "Outdoor run" and "Run" count together. */
private fun family(w: Workout): String {
    val k = w.kind.lowercase()
    return when {
        "run" in k -> "Running"
        "walk" in k || "hike" in k -> "Walking"
        "ride" in k || "bik" in k || "cycl" in k -> "Cycling"
        "swim" in k -> "Swimming"
        "strength" in k || "weight" in k -> "Strength"
        "yoga" in k -> "Yoga"
        "hiit" in k || "interval" in k -> "HIIT"
        "tennis" in k -> "Tennis"
        else -> w.kind.replaceFirstChar { it.uppercase() }
    }
}

fun fitnessInsights(s: Snapshot, date: LocalDate): List<InsightLine> {
    val from = date.minusDays(59)
    val days = s.days.filter { !it.date.isBefore(from) && !it.date.isAfter(date) }
    val all = s.days.flatMap { it.workouts.orEmpty() }.sortedBy { it.start }
    fun dayOf(w: Workout) = HaloTime.dayOf(w.start)
    val workouts = all.filter { !dayOf(it).isBefore(from) && !dayOf(it).isAfter(date) }
    val workoutDays = workouts.map { dayOf(it) }.toSet()
    val out = mutableListOf<InsightLine>()

    // this month against last, by the same date
    val monthStart = date.withDayOfMonth(1)
    val lastMonthStart = monthStart.minusMonths(1)
    val sameDayLastMonth = lastMonthStart.plusDays((date.dayOfMonth).toLong())
    val thisMonth = all.filter { !dayOf(it).isBefore(monthStart) && !dayOf(it).isAfter(date) }
    val lastSoFar = all.filter { !dayOf(it).isBefore(lastMonthStart) && dayOf(it).isBefore(minOf(sameDayLastMonth, monthStart)) }
    if (thisMonth.isNotEmpty() || lastSoFar.isNotEmpty()) {
        val a = thisMonth.sumOf { it.minutes }
        val b = lastSoFar.sumOf { it.minutes }
        out += InsightLine(Icons.Outlined.CalendarMonth,
            "${thisMonth.size} workout${if (thisMonth.size == 1) "" else "s"} this month, ${Format.duration(a)}",
            if (b > 0) "${if (a >= b) "Ahead of" else "Behind"} last month by this date (${lastSoFar.size}, ${Format.duration(b)})." else "Nothing by this date last month.")
    }

    // favourite activity
    val byType = workouts.groupBy { family(it) }
    byType.maxByOrNull { e -> e.value.sumOf { it.minutes } }?.takeIf { it.value.size >= 2 }?.let { fav ->
        val others = byType.size - 1
        out += InsightLine(Icons.Outlined.Star, "${fav.key} is your thing",
            "${fav.value.size} sessions, ${Format.duration(fav.value.sumOf { it.minutes })} in two months" +
                (if (others > 0) ", ahead of $others other kind${if (others == 1) "" else "s"}." else "."))
    }

    // busiest day of the week
    val loads = days.mapNotNull { d -> d.cardioLoad?.let { d.date.dayOfWeek to it } }
    if (loads.size >= 14) {
        val byDay = loads.groupBy({ it.first }, { it.second }).mapValues { it.value.average() }
        val top = byDay.maxByOrNull { it.value }
        val low = byDay.minByOrNull { it.value }
        if (top != null && low != null && top.value > 0) {
            val name = top.key.getDisplayName(DayStyle.FULL, Locale.getDefault())
            val quiet = low.key.getDisplayName(DayStyle.FULL, Locale.getDefault())
            out += InsightLine(Icons.Outlined.BarChart, "${name}s are your big days",
                "Cardio load ${Math.round(top.value)} on average, against ${Math.round(low.value)} on ${quiet}s.")
        }
    }

    // the morning after a hard day
    val pairs = days.mapNotNull { d ->
        val load = d.cardioLoad ?: return@mapNotNull null
        val next = d.date.plusDays(1)
        if (s.day(next) == null) return@mapNotNull null
        val rec = s.scores(next).recovery ?: return@mapNotNull null
        load to rec
    }
    if (pairs.size >= 12) {
        val sorted = pairs.sortedBy { it.first }
        val third = sorted.size / 3
        val easy = sorted.take(third).map { it.second }.average()
        val hard = sorted.takeLast(third).map { it.second }.average()
        val cost = Math.round((easy - hard) * 100)
        if (cost >= 3) out += InsightLine(Icons.Outlined.Autorenew, "Hard days cost you $cost points",
            "Next-morning recovery is ${pct(hard)} after your hardest days and ${pct(easy)} after your easiest.")
        else out += InsightLine(Icons.Outlined.Autorenew, "You bounce back from hard days",
            "Next-morning recovery is ${pct(hard)} after your hardest days, about the same as after your easiest (${pct(easy)}).")
    }

    // sleep after workouts
    val nights = days.mapNotNull { d -> s.day(d.date.plusDays(1))?.sleep?.let { (d.date in workoutDays) to it.minutesAsleep } }
    val afterWork = nights.filter { it.first }.map { it.second }
    val afterRest = nights.filter { !it.first }.map { it.second }
    if (afterWork.size >= 4 && afterRest.size >= 4) {
        val a = afterWork.average()
        val b = afterRest.average()
        val d = a - b
        out += InsightLine(Icons.Outlined.Bedtime,
            if (abs(d) < 8) "Workouts don't change your sleep" else "You sleep ${Format.duration(abs(d))} ${if (d > 0) "more" else "less"} after a workout",
            "${Format.duration(a)} after workout days, ${Format.duration(b)} after rest days.")
    }

    // steps on workout days
    val stepsWork = days.filter { it.date in workoutDays }.mapNotNull { it.steps?.toDouble() }
    val stepsRest = days.filter { it.date !in workoutDays && it.date.isBefore(date) }.mapNotNull { it.steps?.toDouble() }
    if (stepsWork.size >= 4 && stepsRest.size >= 4) {
        val a = stepsWork.average()
        val b = stepsRest.average()
        if (b > 0) out += InsightLine(Icons.AutoMirrored.Outlined.DirectionsWalk, "${signed((a / b - 1) * 100, "%")} steps on workout days",
            "${Format.thousands(Math.round(a))} a day when you train, ${Format.thousands(Math.round(b))} when you rest.")
    }

    // when you train
    if (workouts.size >= 5) {
        val hours = workouts.map { HaloTime.hourOf(it.start) }
        val parts = listOf("mornings" to (5 until 12), "afternoons" to (12 until 17), "evenings" to (17 until 23))
        val best = parts.maxBy { p -> hours.count { it in p.second } }
        val n = hours.count { it in best.second }
        out += InsightLine(Icons.Outlined.Schedule, "A creature of ${best.first}",
            "${Math.round(n.toDouble() / hours.size * 100)}% of your workouts start then.")
    }

    // streaks of active days
    val active = days.filter { it.date in workoutDays || ScoreEngine.zonePoints(it) >= 30 }.map { it.date }.toSet()
    var best = 0
    var run = 0
    var d = from
    while (!d.isAfter(date)) {
        if (d in active) { run++; best = max(best, run) } else run = 0
        d = d.plusDays(1)
    }
    if (best >= 3) {
        out += InsightLine(Icons.Outlined.LocalFireDepartment,
            if (run >= 2) "$run active days in a row" else "Best run: $best active days",
            if (run >= 2) "Your best in two months is $best." else "An active day is a workout or 30 active minutes.")
    }

    // recovery trend: the last two weeks against the two before
    val recent = (0L..13L).mapNotNull { s.scores(date.minusDays(it)).recovery }
    val before = (14L..27L).mapNotNull { s.scores(date.minusDays(it)).recovery }
    if (recent.size >= 7 && before.size >= 7) {
        val diff = recent.average() - before.average()
        if (abs(diff) >= 0.03) out += InsightLine(Icons.AutoMirrored.Outlined.TrendingUp,
            "Recovery ${if (diff > 0) "up" else "down"} ${Math.round(abs(diff) * 100)} points",
            "Averaging ${pct(recent.average())} over the last two weeks, against ${pct(before.average())} the two before.")
    }
    return out.take(min(out.size, 8))
}
