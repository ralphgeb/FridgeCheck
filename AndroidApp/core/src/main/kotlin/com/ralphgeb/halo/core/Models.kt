package com.ralphgeb.halo.core

import java.time.LocalDate
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Sleep stages, in Fitbit's names. */
enum class SleepStageKind(val title: String, val depth: Int) {
    AWAKE("Awake", 0), REM("REM", 1), LIGHT("Light", 2), DEEP("Deep", 3)
}

data class SleepStage(val kind: SleepStageKind, val start: Long, val end: Long) : java.io.Serializable {
    val minutes: Double get() = (end - start) / 60_000.0
}

data class SleepSession(
    val start: Long,
    val end: Long,
    val minutesAsleep: Double,
    val minutesAwake: Double,
    val stages: List<SleepStage>,
    /** Minutes in each stage, for sources that share totals but no timeline. */
    val stageTotals: Map<SleepStageKind, Double>? = null,
) : java.io.Serializable {
    val minutesInBed: Double get() = (end - start) / 60_000.0
    val efficiency: Double get() = if (minutesInBed > 0) min(1.0, minutesAsleep / minutesInBed) else 0.0

    fun minutes(kind: SleepStageKind): Double {
        if (stages.isEmpty() && stageTotals != null) return stageTotals[kind] ?: 0.0
        return stages.filter { it.kind == kind }.sumOf { it.minutes }
    }

    /** Times you woke for at least 5 minutes. */
    val wakeUps: Int get() = stages.count { it.kind == SleepStageKind.AWAKE && it.minutes >= 5 }

    /** Minutes from getting into bed to the first sleep stage. */
    val minutesToFallAsleep: Double
        get() {
            val first = stages.firstOrNull { it.kind != SleepStageKind.AWAKE } ?: return 0.0
            return max(0.0, (first.start - start) / 60_000.0)
        }
}

/** One exercise session, as your band logged it. */
data class Workout(
    val id: String,
    /** The exercise type's name, e.g. "RUNNING". */
    val kind: String,
    val start: Long,
    val end: Long,
    val calories: Double? = null,
    val averageHeartRate: Double? = null,
    val distanceKm: Double? = null,
    val maxHeartRate: Double? = null,
    val elevationGainM: Double? = null,
) : java.io.Serializable {
    val minutes: Double get() = (end - start) / 60_000.0
    val isManual: Boolean get() = id.startsWith("manual-")
}

data class HeartSample(val time: Long, val bpm: Double) : java.io.Serializable

/** Minutes spent in each heart-rate zone. */
data class ZoneMinutes(val fatBurn: Double = 0.0, val cardio: Double = 0.0, val peak: Double = 0.0) : java.io.Serializable {
    val total: Double get() = fatBurn + cardio + peak

    /** Harder minutes count for more: fat burn ×¼, cardio ×2, peak ×3. */
    val points: Double get() = 0.25 * fatBurn + 2 * cardio + 3 * peak
}

/** Everything Halo knows about one day. The day is the calendar day you woke up on. */
data class DayMetrics(
    val date: LocalDate,
    val steps: Int? = null,
    val activeCalories: Double? = null,
    val activeZoneMinutes: Double? = null,
    /** Time in each heart-rate zone, as the band reports it. */
    val zoneMinutes: ZoneMinutes? = null,
    /** Cardio load worked out from the day's heart rate. */
    val heartLoad: Double? = null,
    /** Zone minutes worked out from the day's heart rate. */
    val heartZones: ZoneMinutes? = null,
    val restingHeartRate: Double? = null,
    /** Milliseconds (RMSSD). */
    val hrv: Double? = null,
    val spo2: Double? = null,
    val respiratoryRate: Double? = null,
    /** °C from your personal baseline. */
    val skinTempDelta: Double? = null,
    val vo2Max: Double? = null,
    val weightKg: Double? = null,
    val sleep: SleepSession? = null,
    val workouts: List<Workout>? = null,
    /** Intraday readings, kept for the most recent days only. */
    val heartRate: List<HeartSample> = emptyList(),
    /** Heart rate minute by minute (1,440 values from midnight, 0 where there was no reading). */
    val minuteHeartRate: List<Int>? = null,
    /** 24 hours from midnight; recent days only. */
    val hourlySteps: List<Double>? = null,
    val hourlyCalories: List<Double>? = null,
) : java.io.Serializable {
    /**
     * Cardio load for the day: best from the heart rate itself, then from the band's zone
     * minutes, then estimated from Active Zone Minutes.
     */
    val cardioLoad: Double?
        get() {
            heartLoad?.let { return it }
            zoneMinutes?.let { if (it.total > 0) return CardioLoad.fromZones(it) }
            return activeZoneMinutes?.let(CardioLoad::fromActiveZoneMinutes)
        }

    /** Minutes in each zone: the band's own count, else from the heart rate. */
    val zones: ZoneMinutes?
        get() {
            zoneMinutes?.let { if (it.total > 0) return it }
            return heartZones
        }

    /**
     * This day from a new sync, with anything the sync didn't bring back kept from what the app
     * already had, so a type that fails or comes back empty never wipes a value.
     */
    fun filling(old: DayMetrics?): DayMetrics {
        if (old == null) return this
        return copy(
            steps = steps ?: old.steps,
            activeCalories = activeCalories ?: old.activeCalories,
            activeZoneMinutes = activeZoneMinutes ?: old.activeZoneMinutes,
            zoneMinutes = zoneMinutes ?: old.zoneMinutes,
            heartLoad = heartLoad ?: old.heartLoad,
            heartZones = heartZones ?: old.heartZones,
            restingHeartRate = restingHeartRate ?: old.restingHeartRate,
            hrv = hrv ?: old.hrv,
            spo2 = spo2 ?: old.spo2,
            respiratoryRate = respiratoryRate ?: old.respiratoryRate,
            skinTempDelta = skinTempDelta ?: old.skinTempDelta,
            vo2Max = vo2Max ?: old.vo2Max,
            weightKg = weightKg ?: old.weightKg,
            sleep = sleep ?: old.sleep,
            workouts = workouts ?: old.workouts,
            heartRate = heartRate.ifEmpty { old.heartRate },
            minuteHeartRate = HeartMinutes.merge(old.minuteHeartRate, minuteHeartRate),
            hourlySteps = hourlySteps ?: old.hourlySteps,
            hourlyCalories = hourlyCalories ?: old.hourlyCalories,
        )
    }
}

/** A day's heart rate as one average per minute. */
object HeartMinutes {
    /** Per-minute averages for each day the readings touch. */
    fun buckets(readings: List<HeartSample>): Map<LocalDate, List<Int>> {
        val sums = HashMap<LocalDate, DoubleArray>()
        val counts = HashMap<LocalDate, DoubleArray>()
        for (r in readings) {
            val day = HaloTime.dayOf(r.time)
            val m = ((r.time - HaloTime.startOf(day)) / 60_000).toInt().coerceIn(0, 1439)
            sums.getOrPut(day) { DoubleArray(1440) }[m] += r.bpm
            counts.getOrPut(day) { DoubleArray(1440) }[m] += 1.0
        }
        return sums.mapValues { (day, s) ->
            val c = counts.getValue(day)
            List(1440) { if (c[it] > 0) (s[it] / c[it]).roundToInt() else 0 }
        }
    }

    /** Old minutes with new ones laid over them (a new reading wins its minute). */
    fun merge(old: List<Int>?, new: List<Int>?): List<Int>? {
        if (new == null || new.size != 1440) return old
        if (old == null || old.size != 1440) return new
        return List(1440) { if (new[it] > 0) new[it] else old[it] }
    }

    /** The minutes as readings, one at the start of each minute that has one. */
    fun samples(minutes: List<Int>, day: LocalDate): List<HeartSample> {
        val start = HaloTime.startOf(day)
        return minutes.mapIndexedNotNull { m, bpm -> if (bpm > 0) HeartSample(start + m * 60_000L, bpm.toDouble()) else null }
    }

    /** One reading per 5 minutes (the average), plenty for a chart. */
    fun fiveMinuteAverages(samples: List<HeartSample>): List<HeartSample> =
        samples.groupBy { it.time / 300_000 }.toSortedMap().map { (key, group) ->
            HeartSample(key * 300_000, Math.round(group.sumOf { it.bpm } / group.size).toDouble())
        }
}

/** The three scores, each 0..1. Null when there isn't enough data. */
data class Scores(val recovery: Double? = null, val effort: Double? = null, val sleep: Double? = null)

/** The user's targets (set in Settings). */
data class Targets(
    val sleepNeedHours: Double = 7.5,
    val steps: Double = 10_000.0,
    /** Daily heart zone minutes, with cardio counting double and peak triple. */
    val zoneMinutes: Double = 30.0,
)

/** What this week's cardio load target is for. Auto picks one from your recovery and recent load. */
enum class CardioFocus(val title: String, val factor: Double, val detail: String) {
    AUTO("Auto", 1.0, "Halo picks a focus each week."),
    MAINTAIN("Maintain", 1.0, "Similar to your recent weeks, to stay consistent."),
    BUILD("Build", 1.1, "A little above your recent weeks, to build fitness safely."),
    RECOVER("Recover", 0.75, "Below your recent weeks, so your body can adapt."),
}

/** Body details, used for resting calories (Mifflin-St Jeor) and heart-rate zones. */
data class Profile(
    val male: Boolean = true,
    val birthYear: Int = 1990,
    val heightCm: Double = 178.0,
    val weightKg: Double = 78.0,
) {
    val age: Int get() = max(14, HaloTime.today().year - birthYear)

    /** Estimated maximum heart rate (Tanaka: 208 − 0.7 × age). */
    val maxHeartRate: Double get() = 208 - 0.7 * age

    /** Calories your body burns at rest in a full day. */
    fun restingCalories(weight: Double? = null): Double {
        val kg = weight ?: weightKg
        val base = 10 * kg + 6.25 * heightCm - 5 * age
        return base + if (male) 5 else -161
    }
}

/** One spoke of the Balance chart (0..1). */
data class BalanceAxis(val name: String, val value: Double, val detail: String? = null) {
    /** Label on the radar itself, where space is tight. */
    val short: String
        get() = when (name) {
            "Resting HR" -> "RHR"
            "Weekly cardio" -> "Cardio"
            else -> name
        }
}

/** The three rings, in the order they appear. */
enum class ScoreKind(val title: String) {
    RECOVERY("Recovery"), EFFORT("Effort"), SLEEP("Sleep");

    fun value(s: Scores): Double? = when (this) {
        RECOVERY -> s.recovery
        EFFORT -> s.effort
        SLEEP -> s.sleep
    }
}
