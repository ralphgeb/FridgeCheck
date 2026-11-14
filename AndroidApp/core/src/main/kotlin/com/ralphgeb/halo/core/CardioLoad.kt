package com.ralphgeb.halo.core

import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * Cardio load: how hard your heart worked, not just for how long. Each minute in a heart-rate
 * zone earns load, and harder zones earn it at an accelerating rate (Banister's training impulse,
 * using the middle of each zone as a share of heart-rate reserve). Same as the iPhone app.
 */
object CardioLoad {
    /** Load earned by one minute at a share of heart-rate reserve (0 = resting, 1 = max). */
    fun perMinute(reserve: Double): Double = if (reserve <= 0) 0.0 else reserve * 0.64 * exp(1.92 * reserve)

    /** Zones: fat burn is 40–59% of reserve, cardio 60–84%, peak 85% and up. */
    fun fromZones(z: ZoneMinutes): Double =
        z.fatBurn * perMinute(0.5) + z.cardio * perMinute(0.72) + z.peak * perMinute(0.9)

    const val FAT_BURN_START = 0.4
    const val CARDIO_START = 0.6
    const val PEAK_START = 0.85

    /** Load starts a little below the zones: a brisk walk adds a few points, sitting adds none. */
    const val LOAD_START = 0.3

    /** The bpm where a zone starts, for this resting and max heart rate. */
    fun bpm(atReserve: Double, resting: Double, max: Double): Double = resting + atReserve * (max - resting)

    data class Credited(val time: Long, val minutes: Double, val x: Double)

    /**
     * Each reading's share of heart-rate reserve and the minutes it counts for: the time until the
     * next reading (at most `maxGapSeconds`), and only when the time in a zone lasts. A reading in
     * a zone needs a neighbour in a zone within a few minutes, so a lone spike adds nothing.
     */
    fun credited(samples: List<HeartSample>, resting: Double, maxHR: Double, maxGapSeconds: Double = 120.0): List<Credited> {
        val sorted = samples.sortedBy { it.time }
        val reserve = max(maxHR - resting, 1.0)
        val xs = sorted.map { (it.bpm - resting) / reserve }
        val near = (maxGapSeconds + 60) * 1000
        fun inZone(j: Int, i: Int): Boolean =
            j >= 0 && j < sorted.size && xs[j] >= LOAD_START && abs(sorted[j].time - sorted[i].time) <= near
        return sorted.indices.map { i ->
            val s = sorted[i]
            val next = if (i + 1 < sorted.size) sorted[i + 1].time else s.time + 60_000
            val minutes = min((next - s.time) / 1000.0, maxGapSeconds) / 60
            val lasts = xs[i] >= LOAD_START && (inZone(i - 1, i) || inZone(i + 1, i))
            Credited(s.time, if (lasts) minutes else 0.0, xs[i])
        }
    }

    /** Load and zone minutes worked out from heart-rate readings. */
    fun fromHeartRate(samples: List<HeartSample>, resting: Double, maxHR: Double, maxGapSeconds: Double = 120.0): Pair<Double, ZoneMinutes> {
        var load = 0.0
        var fat = 0.0
        var cardio = 0.0
        var peak = 0.0
        for (r in credited(samples, resting, maxHR, maxGapSeconds)) {
            if (r.minutes <= 0) continue
            load += perMinute(min(r.x, 1.1)) * r.minutes
            when {
                r.x >= PEAK_START -> peak += r.minutes
                r.x >= CARDIO_START -> cardio += r.minutes
                r.x >= FAT_BURN_START -> fat += r.minutes
            }
        }
        return load to ZoneMinutes(fat, cardio, peak)
    }

    data class Running(val time: Long, val load: Double, val azm: Double)

    /** Running totals through the day: load and Active Zone Minutes after each reading. */
    fun timeline(samples: List<HeartSample>, resting: Double, maxHR: Double, maxGapSeconds: Double = 300.0): List<Running> {
        var load = 0.0
        var azm = 0.0
        return credited(samples, resting, maxHR, maxGapSeconds).map { r ->
            if (r.minutes > 0) {
                load += perMinute(min(r.x, 1.1)) * r.minutes
                if (r.x >= FAT_BURN_START) azm += (if (r.x >= CARDIO_START) 2 else 1) * r.minutes
            }
            Running(r.time, load, azm)
        }
    }

    /** Active Zone Minutes count moderate minutes once and cardio or peak twice: about one unit of load per minute. */
    fun fromActiveZoneMinutes(azm: Double): Double = azm * 0.95

    /** The weekly target never goes below this, and it's the target until there are a few weeks of history. */
    const val MINIMUM_TARGET = 210.0

    data class Week(
        val start: LocalDate,
        /** From the start of the week up to the day shown. */
        val load: Double,
        /** For the whole week. */
        val target: Double,
        /** Never AUTO: the focus Halo chose. */
        val focus: CardioFocus,
        /** Average of the four weeks before this one. */
        val baseline: Double?,
        /** All seven; null loads for days still to come. */
        val days: List<Pair<LocalDate, Double?>>,
        val daysElapsed: Int,
    ) {
        val progress: Double get() = if (target > 0) load / target else 0.0
        val remaining: Double get() = max(0.0, target - load)

        /** Progress against where you'd be by now with an even spread over the week. */
        val pace: Double get() = if (target > 0) load / (target * daysElapsed / 7) else 0.0
    }

    /** The calendar week containing `date` (up to `date`), with a target from your recent weeks and your recovery. */
    fun week(days: List<DayMetrics>, endingOn: LocalDate, chosen: CardioFocus, recovery: Double?): Week {
        val start = HaloTime.weekStart(endingOn)
        val byDate = days.associateBy { it.date }
        val window = (0 until 7).map { i ->
            val d = start.plusDays(i.toLong())
            d to (if (!d.isAfter(endingOn)) (byDate[d]?.cardioLoad ?: 0.0) else null)
        }
        val load = window.mapNotNull { it.second }.sum()
        val base = baseline(byDate, start)

        var focus = chosen
        if (focus == CardioFocus.AUTO) {
            // last week against your usual one (acute against chronic load)
            val lastWeek = weekTotal(byDate, start.minusDays(7))
            val ratio = base?.let { b -> (lastWeek ?: b) / max(b, 1.0) } ?: 1.0
            val ready = recovery ?: 0.5
            focus = when {
                ready < 0.34 || ratio > 1.4 -> CardioFocus.RECOVER
                ready >= 0.6 && ratio < 1.05 -> CardioFocus.BUILD
                else -> CardioFocus.MAINTAIN
            }
        }
        val target = max(MINIMUM_TARGET, Math.round((base ?: MINIMUM_TARGET) * focus.factor / 5) * 5.0)
        val elapsed = ChronoUnit.DAYS.between(start, endingOn).toInt() + 1
        return Week(start, load, target, focus, base, window, elapsed.coerceIn(1, 7))
    }

    /** Average load of the four full weeks before `weekStart`. Needs two weeks with data. */
    fun baseline(byDate: Map<LocalDate, DayMetrics>, weekStart: LocalDate): Double? {
        val weeks = (1..4).mapNotNull { k -> weekTotal(byDate, weekStart.minusDays(7L * k)) }
        if (weeks.size < 2) return null
        return weeks.sum() / weeks.size
    }

    /** Total load of the seven days from `start`, if at least three of them have data. */
    fun weekTotal(byDate: Map<LocalDate, DayMetrics>, start: LocalDate): Double? {
        val loads = (0 until 7).mapNotNull { i -> byDate[start.plusDays(i.toLong())]?.cardioLoad }
        return if (loads.size >= 3) loads.sum() else null
    }
}
