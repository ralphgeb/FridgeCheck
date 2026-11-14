package com.ralphgeb.halo.core

import java.time.DayOfWeek
import java.time.LocalDate
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Realistic made-up data, shown until Health Connect is connected. Deterministic (the same
 * generator and seed as the iPhone app), so the screens look the same every time.
 */
object SampleData {
    fun days(count: Int = 182, endingOn: Long = HaloTime.now()): List<DayMetrics> {
        val rng = SeededRandom(42u)
        val today = HaloTime.dayOf(endingOn)
        var list = (count - 1 downTo 0).map { offset ->
            val date = today.minusDays(offset.toLong())
            val weekend = date.dayOfWeek == DayOfWeek.SATURDAY || date.dayOfWeek == DayOfWeek.SUNDAY
            val wave = sin(offset / 4.5)
            val hrv = Math.round(58 + 9 * wave + rng.next(-6.0, 6.0)).toDouble()
            val rhr = Math.round(54 - 2.5 * wave + rng.next(-1.5, 1.5)).toDouble()
            val spo2 = Math.round((96.4 + rng.next(-0.8, 0.8)) * 10) / 10.0
            val resp = Math.round((14.6 + rng.next(-0.6, 0.6)) * 10) / 10.0
            val temp = Math.round(rng.next(-0.4, 0.4) * 10) / 10.0
            val vo2 = Math.round(46 + 2 * sin(offset / 40.0)).toDouble()
            val weight = Math.round((78.5 + 1.2 * sin(offset / 25.0) + rng.next(-0.3, 0.3)) * 10) / 10.0
            val steps = rng.next(if (weekend) 5_000.0 else 7_500.0, if (weekend) 14_000.0 else 12_500.0).toInt()
            // a harder session every few days, easy days in between
            val hard = (offset % 3 == 0) || rng.next(0.0, 1.0) > 0.8
            val zones = ZoneMinutes(
                fatBurn = Math.round(rng.next(5.0, 25.0)).toDouble(),
                cardio = Math.round(if (hard) rng.next(10.0, 30.0) else rng.next(0.0, 4.0)).toDouble(),
                peak = Math.round(if (hard) rng.next(0.0, 5.0) else 0.0).toDouble(),
            )
            val azm = zones.fatBurn + 2 * (zones.cardio + zones.peak)
            val calories = Math.round(rng.next(380.0, 920.0)).toDouble()
            val sleep = sleep(date, rng, weekend)
            var workouts: List<Workout>? = null
            if (hard && offset > 0) {
                val kinds = listOf("RUNNING", "STRENGTH_TRAINING", "CYCLING", "SWIMMING")
                val kind = kinds[offset % kinds.size]
                val start = HaloTime.at(date, 18, 10)
                val minutes = zones.cardio + zones.peak + 15
                workouts = listOf(
                    Workout("sample-$offset", kind, start, start + (minutes * 60_000).toLong(),
                        calories = Math.round(minutes * 9.5).toDouble(), averageHeartRate = 138.0,
                        distanceKm = if (kind == "RUNNING") Math.round(minutes / 5.6 * 10) / 10.0 else null)
                )
            }
            DayMetrics(date, steps = steps, activeCalories = calories, activeZoneMinutes = azm, zoneMinutes = zones,
                restingHeartRate = rhr, hrv = hrv, spo2 = spo2, respiratoryRate = resp, skinTempDelta = temp,
                vo2Max = vo2, weightKg = weight, sleep = sleep, workouts = workouts)
        }.map { d ->
            if (d.date == today) {
                // today is still in progress
                d.copy(steps = ((d.steps ?: 0) * 0.62).toInt(), zoneMinutes = ZoneMinutes(9.0, 4.0, 0.0), activeZoneMinutes = 17.0)
            } else d
        }
        list = withHeartRate(list, endingOn, rng)
        return withHours(list, endingOn)
    }

    /** How a typical day's activity spreads over its 24 hours. */
    val dayShape = listOf(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 1.6, 1.4, 0.7, 0.6, 0.8,
        1.7, 1.0, 0.6, 0.6, 0.9, 1.6, 2.4, 1.2, 0.8, 0.5, 0.25, 0.05)

    /** One night: about 7h 20m with realistic 90-minute cycles. */
    fun sleep(wakingOn: LocalDate, rng: SeededRandom, weekend: Boolean): SleepSession {
        val bedHour = if (weekend) 23.6 else 23.0
        val bed = HaloTime.startOf(wakingOn) + ((bedHour - 24) * 60 + rng.next(-25.0, 25.0)).toInt() * 60_000L
        var t = bed
        val stages = mutableListOf<SleepStage>()
        fun add(kind: SleepStageKind, minutes: Double) {
            val end = t + (max(1.0, minutes) * 60_000).toLong()
            stages += SleepStage(kind, t, end)
            t = end
        }
        add(SleepStageKind.AWAKE, rng.next(6.0, 14.0))
        val cycles = 5
        for (c in 0 until cycles) {
            val late = c.toDouble() / (cycles - 1)
            add(SleepStageKind.LIGHT, rng.next(22.0, 34.0))
            add(SleepStageKind.DEEP, rng.next(10.0, 34.0) * (1 - late * 0.85))
            add(SleepStageKind.LIGHT, rng.next(14.0, 26.0))
            add(SleepStageKind.REM, rng.next(8.0, 14.0) + late * rng.next(10.0, 22.0))
            if (rng.next(0.0, 1.0) > 0.55) add(SleepStageKind.AWAKE, rng.next(2.0, 9.0))
        }
        add(SleepStageKind.AWAKE, rng.next(3.0, 8.0))
        val asleep = stages.filter { it.kind != SleepStageKind.AWAKE }.sumOf { it.minutes }
        val awake = stages.filter { it.kind == SleepStageKind.AWAKE }.sumOf { it.minutes }
        return SleepSession(bed, t, Math.round(asleep).toDouble(), Math.round(awake).toDouble(), stages)
    }

    /** Heart rate every 5 minutes; asleep, it follows the sleep stages. */
    fun heartRate(from: Long, until: Long, nights: List<SleepSession>, rng: SeededRandom): List<HeartSample> {
        val out = mutableListOf<HeartSample>()
        val allStages = nights.flatMap { it.stages }
        var t = from
        while (t < until) {
            var bpm: Double
            var spread = 6.0
            val stage = allStages.firstOrNull { it.start <= t && t < it.end }
            if (stage != null) {
                when (stage.kind) {
                    SleepStageKind.DEEP -> { bpm = 49.0; spread = 1.5 }
                    SleepStageKind.LIGHT -> { bpm = 53.0; spread = 2.5 }
                    SleepStageKind.REM -> { bpm = 58.0; spread = 4.0 }
                    SleepStageKind.AWAKE -> { bpm = 63.0; spread = 4.0 }
                }
            } else {
                bpm = when (HaloTime.hourOf(t)) {
                    in 7..8 -> 76.0
                    12 -> 96.0
                    17 -> 132.0
                    else -> 72.0
                }
            }
            out += HeartSample(t, Math.round(bpm + rng.next(-spread, spread)).toDouble())
            t += 5 * 60_000
        }
        return out
    }

    /** Intraday heart rate for yesterday and today (like a real sync, which keeps only recent days). */
    private fun withHeartRate(days: List<DayMetrics>, end: Long, rng: SeededRandom): List<DayMetrics> {
        val nights = days.takeLast(2).mapNotNull { it.sleep }
        val profile = Profile()
        val out = days.toMutableList()
        for (i in max(0, out.size - 2) until out.size) {
            val start = HaloTime.startOf(out[i].date)
            val stop = min(end, start + DAY_MS)
            val hr = heartRate(start, stop, nights, rng)
            val (load, zones) = CardioLoad.fromHeartRate(hr, out[i].restingHeartRate ?: 55.0, profile.maxHeartRate, 300.0)
            out[i] = out[i].copy(heartRate = hr, heartLoad = load, heartZones = zones)
        }
        return out
    }

    /** Steps and active calories hour by hour for the last two weeks. Today only fills the hours so far. */
    private fun withHours(days: List<DayMetrics>, end: Long): List<DayMetrics> {
        val hourNow = HaloTime.hourOf(end)
        val todayDate = HaloTime.dayOf(end)
        val out = days.toMutableList()
        for (i in max(0, out.size - 14) until out.size) {
            val d = out[i]
            val isToday = d.date == todayDate
            val shape = dayShape.mapIndexed { h, w -> if (!isToday || h <= hourNow) w else 0.0 }
            val total = max(shape.sum(), 0.001)
            out[i] = d.copy(
                hourlySteps = shape.map { Math.round((d.steps ?: 0) * it / total).toDouble() },
                hourlyCalories = shape.map { Math.round((d.activeCalories ?: 0.0) * it / total).toDouble() },
            )
        }
        return out
    }
}

/** Small deterministic random generator (xorshift, the same as the iPhone app's). */
class SeededRandom(seed: ULong) {
    private var state: ULong = (seed * 0x9E3779B97F4A7C15uL) or 1uL

    fun next(): Double {
        state = state xor (state shl 13)
        state = state xor (state shr 7)
        state = state xor (state shl 17)
        return (state % 1_000_000uL).toDouble() / 1_000_000
    }

    fun next(lo: Double, hi: Double): Double = lo + (hi - lo) * next()
}
