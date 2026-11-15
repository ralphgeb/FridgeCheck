package com.ralphgeb.halo.core

import java.time.LocalDate
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Turns raw band data into Halo's three scores, exactly as the iPhone app does. Every score
 * compares you with your own recent baseline, not with population averages.
 */
object ScoreEngine {
    const val BASELINE_DAYS = 30

    fun scores(day: DayMetrics, history: List<DayMetrics>, targets: Targets): Scores {
        val past = history.filter { it.date < day.date }.takeLast(BASELINE_DAYS)
        val sleep = sleepScore(day.sleep, past, targets)
        return Scores(
            recovery = recoveryScore(day, past, sleep),
            effort = effortScore(day, targets),
            sleep = sleep,
        )
    }

    // ---- Sleep

    /** What a normal night's stages look like on the band (a Fitbit calls about 20% of the night deep). */
    data class StageNorms(val deep: Double, val rem: Double) {
        companion object {
            val STANDARD = StageNorms(0.20, 0.23)
        }
    }

    var stageNorms = StageNorms.STANDARD

    /** What goes into the sleep score, each 0..1. */
    data class SleepParts(
        val duration: Double,
        val deep: Double,
        val rem: Double,
        val efficiency: Double,
        val calm: Double,
        val consistency: Double,
    ) {
        val restorative: Double get() = (deep + rem) / 2
    }

    fun sleepParts(s: SleepSession, previous: List<DayMetrics>, targets: Targets, need: Double? = null): SleepParts {
        val needMinutes = need ?: (targets.sleepNeedHours * 60)
        val asleep = max(s.minutesAsleep, 1.0)
        // the share of your need you slept (as Whoop's "hours vs needed")
        val duration = clamp(s.minutesAsleep / needMinutes)
        val deep = clamp(s.minutes(SleepStageKind.DEEP) / asleep / stageNorms.deep)
        val rem = clamp(s.minutes(SleepStageKind.REM) / asleep / stageNorms.rem)
        // a normal night is about 90% efficient with half an hour awake
        val efficiency = clamp((s.efficiency - 0.75) / 0.20)
        val awake = if (s.stages.isEmpty()) s.minutesAwake else s.minutes(SleepStageKind.AWAKE)
        val calm = clamp(1 - max(0.0, awake - 10) / 65)
        // bedtime against your usual one (the median of the last week): within half an hour is
        // full marks, then it fades out over the next two hours
        val bedtimes = previous.takeLast(7).mapNotNull { d -> d.sleep?.let { minutesAfterEvening(it.start) } }
        val usual = median(bedtimes)
        val consistency = if (bedtimes.size >= 3 && usual != null) {
            clamp(1 - (abs(minutesAfterEvening(s.start) - usual) - 30) / 120)
        } else 0.8
        return SleepParts(duration, deep, rem, efficiency, calm, consistency)
    }

    /**
     * Time asleep out of your need (half the score), deep and REM (20%), efficiency, a calm night
     * and a steady bedtime (10% each), with a gentle curve so only a near-perfect night reaches the
     * high 90s. Calibrated on ten nights with a Fitbit, a Whoop and an Apple Watch worn together:
     * within a few points of Whoop's own sleep score (a short 6-hour night about 70, a full, steady
     * one in the high 80s to 90s), where it used to read 30 to 40 low.
     */
    fun sleepScore(s: SleepSession?, previous: List<DayMetrics>, targets: Targets): Double? {
        if (s == null || s.minutesAsleep <= 60) return null
        val p = sleepParts(s, previous, targets)
        val raw = 0.50 * p.duration + 0.20 * p.restorative + 0.10 * p.efficiency + 0.10 * p.calm + 0.10 * p.consistency
        return clamp(clamp(raw).pow(1.15))
    }

    /** Bedtime as minutes after 6 pm, so 23:30 and 00:30 sit next to each other. */
    fun minutesAfterEvening(time: Long): Double {
        val m = HaloTime.minuteOfDay(time).toDouble()
        return if (m >= 18 * 60) m - 18 * 60 else m + 6 * 60
    }

    // ---- Recovery

    /**
     * How this morning's HRV and resting heart rate compare with your last 30 days, in your own
     * day-to-day spread (+1 is a good day for you, -1 a poor one). Null without a baseline.
     */
    fun recoveryZ(day: DayMetrics, previous: List<DayMetrics>): Pair<Double?, Double?> {
        // HRV on a log scale: it swings by percentages, not by milliseconds
        val logs = previous.mapNotNull { it.hrv }.filter { it > 0 }.map { ln(it) }
        // in the first week the baseline is a handful of mornings: a reading is held closer to usual
        fun settle(z: Double, n: Int): Double = (z * min(1.0, n / 7.0)).coerceIn(-2.5, 2.5)
        var zh: Double? = null
        val hrv = day.hrv
        val logMean = mean(logs)
        if (hrv != null && hrv > 0 && logs.size >= 3 && logMean != null) {
            val sd = if (logs.size >= 7) max(0.08, standardDeviation(logs)) else 0.15
            zh = settle((ln(hrv) - logMean) / sd, logs.size)
        }
        val rhrs = previous.mapNotNull { it.restingHeartRate }
        var zr: Double? = null
        val rhr = day.restingHeartRate
        val rhrMean = mean(rhrs)
        if (rhr != null && rhrs.size >= 3 && rhrMean != null) {
            val sd = if (rhrs.size >= 7) max(1.5, standardDeviation(rhrs)) else 2.5
            zr = settle((rhrMean - rhr) / sd, rhrs.size)
        }
        return zh to zr
    }

    /** A z-score as a 0..1 level: a usual morning is about 67%, one spread better about 86%, worse about 41%. */
    fun recoveryLevel(z: Double): Double = 1 / (1 + exp(-(1.1 * z + 0.7)))

    /** HRV (70%) and resting heart rate (30%) against your own normal, then last night's sleep (a quarter). */
    fun recoveryScore(day: DayMetrics, previous: List<DayMetrics>, sleep: Double?): Double? {
        val (zh, zr) = recoveryZ(day, previous)
        val parts = listOfNotNull(zh?.let { it to 0.7 }, zr?.let { it to 0.3 })
        if (parts.isEmpty()) return null
        val combined = parts.sumOf { it.first * it.second } / parts.sumOf { it.second }
        val body = recoveryLevel(combined)
        if (sleep == null) return clamp(body)
        return clamp(0.75 * body + 0.25 * sleep)
    }

    // ---- Effort

    /**
     * Today only: half steps against your target, half heart zone points against your daily target.
     * Like Whoop's strain it fills quickly at first and slower as it goes: meeting both targets is
     * about 70, twice them about 90, and 100 is out of reach. (It used to stop at the targets, so
     * an ordinary active day read 99.)
     */
    fun effortScore(day: DayMetrics, targets: Targets): Double? {
        if (day.steps == null && day.zones == null && day.activeZoneMinutes == null && day.cardioLoad == null) return null
        val work = if (day.steps == null) effortZonesRatio(day, targets)
        else 0.5 * effortStepsRatio(day, targets) + 0.5 * effortZonesRatio(day, targets)
        return clamp(1 - exp(-1.2 * work))
    }

    /** Steps against your target (1 is the target; it can go over). */
    fun effortStepsRatio(day: DayMetrics, targets: Targets): Double = (day.steps ?: 0) / max(targets.steps, 1.0)

    /** Zone points against your target (1 is the target; it can go over). */
    fun effortZonesRatio(day: DayMetrics, targets: Targets): Double = zonePoints(day) / max(targets.zoneMinutes, 1.0)

    /** For the bars on "What goes into it": full at the target. */
    fun effortStepsPart(day: DayMetrics, targets: Targets): Double = min(1.0, effortStepsRatio(day, targets))
    fun effortZonesPart(day: DayMetrics, targets: Targets): Double = min(1.0, effortZonesRatio(day, targets))

    /**
     * Zone points so far today: from zone minutes, or Active Zone Minutes (which count the same
     * way), else from the day's cardio load (about 3.3 load to a point, as across the Fitbit days compared).
     */
    fun zonePoints(day: DayMetrics): Double = day.zones?.points ?: day.activeZoneMinutes ?: ((day.cardioLoad ?: 0.0) / 3.3)

    // ---- Balance (the radar chart)

    /** Six spokes, each 0..1, describing the week ending on `date` (or, with `span` 1, the day). */
    fun balance(days: List<DayMetrics>, endingOn: LocalDate, targets: Targets, span: Int = 7, scores: (DayMetrics) -> Scores): List<BalanceAxis> {
        val oneDay = span <= 1
        val start = endingOn.minusDays((max(1, span) - 1).toLong())
        val week = days.filter { !it.date.isBefore(start) && !it.date.isAfter(endingOn) }
        val before = days.filter { it.date.isBefore(start) }.takeLast(BASELINE_DAYS)
        val weekScores = week.map(scores)

        // being exactly at your usual level scores 70; better climbs to 100, worse falls away
        var hrvValue = 0.0
        var hrvDetail: String? = null
        val hrvs = week.mapNotNull { it.hrv }
        mean(hrvs)?.let { m ->
            val base = mean(before.mapNotNull { it.hrv }) ?: m
            val level = clamp(0.7 + (m / base - 1) / 0.25)
            val sd = sqrt(hrvs.sumOf { (it - m) * (it - m) } / hrvs.size)
            if (hrvs.size >= 3) {
                hrvValue = 0.6 * level + 0.4 * clamp(1 - (sd / m) / 0.25)
                hrvDetail = "${Math.round(m)} ms this week · usual ${Math.round(base)} · ${if (sd / m < 0.1) "steady" else "up and down"}"
            } else {
                hrvValue = level
                hrvDetail = "${Math.round(m)} ms ${if (oneDay) "today" else "this week"} · usual ${Math.round(base)}"
            }
        }
        var rhrValue = 0.0
        var rhrDetail: String? = null
        mean(week.mapNotNull { it.restingHeartRate })?.let { m ->
            val usual = before.mapNotNull { it.restingHeartRate }
            val base = mean(usual) ?: m
            val spread = max(if (usual.size >= 5) standardDeviation(usual) else 0.0, 2.0)
            rhrValue = clamp(0.7 + 0.2 * (base - m) / spread)
            val change = Math.round((m / base - 1) * 100).toInt()
            rhrDetail = "${Math.round(m)} bpm ${if (oneDay) "today" else "this week"} · usual ${Math.round(base)}" +
                if (change == 0) "" else " (${if (change > 0) "+" else ""}$change%)"
        }
        val cardio = CardioLoad.week(days, endingOn, CardioFocus.AUTO, week.lastOrNull()?.let { scores(it).recovery })
        val sleep = mean(weekScores.mapNotNull { it.sleep })
        val recovery = mean(weekScores.mapNotNull { it.recovery })
        val steps = mean(week.mapNotNull { d -> d.steps?.toDouble() })
        val lastLoad = week.lastOrNull()?.cardioLoad ?: 0.0

        return listOf(
            BalanceAxis("Sleep", sleep ?: 0.0, sleep?.let { "Sleep score ${pct(it)} on average" }),
            BalanceAxis("HRV", hrvValue, hrvDetail),
            BalanceAxis("Recovery", recovery ?: 0.0, recovery?.let { "Recovery ${pct(it)} on average" }),
            BalanceAxis("Steps", clamp((steps ?: 0.0) / max(targets.steps, 1.0)),
                steps?.let { "${Format.thousands(Math.round(it))}${if (oneDay) "" else " a day"} · target ${Format.thousands(targets.steps.toLong())}" }),
            if (oneDay) BalanceAxis("Weekly cardio", clamp(lastLoad / max(cardio.target / 7, 1.0)),
                "Load ${Math.round(lastLoad)} today · a seventh of the week is ${Math.round(cardio.target / 7)}")
            else BalanceAxis("Weekly cardio", clamp(cardio.pace),
                "Load ${Math.round(cardio.load)} of ${cardio.target.toInt()} · day ${cardio.daysElapsed} of 7"),
            BalanceAxis("Resting HR", rhrValue, rhrDetail),
        )
    }

    // ---- Sleep debt

    data class Night(val date: LocalDate, val asleep: Double, val need: Double) {
        /** Negative = short. */
        val balance: Double get() = asleep - need
    }

    fun nights(days: List<DayMetrics>, endingOn: LocalDate, count: Int, needHours: Double): List<Night> {
        val start = endingOn.minusDays((count - 1).toLong())
        return days.filter { !it.date.isAfter(endingOn) && !it.date.isBefore(start) }
            // naps count towards it too
            .mapNotNull { d -> if (d.sleep == null && d.napMinutes <= 0) null else Night(d.date, (d.sleep?.minutesAsleep ?: 0.0) + d.napMinutes, needHours * 60) }
    }

    /** Minutes of sleep missed across the nights (nights over your need pay some of it back). */
    fun sleepDebt(nights: List<Night>): Double = max(0.0, -nights.sumOf { it.balance })

    /** When to get into bed tonight: usual wake time, minus your need, how long you take to fall asleep, and up to 30 minutes for debt. */
    fun bedtime(days: List<DayMetrics>, endingOn: LocalDate, needHours: Double): Long? {
        val recent = days.filter { !it.date.isAfter(endingOn) }.takeLast(7).mapNotNull { it.sleep }
        if (recent.size < 3) return null
        val wakes = recent.map { minutesAfterEvening(it.end) }.sorted()
        val usualWake = wakes[wakes.size / 2]
        val latency = mean(recent.map { it.minutesToFallAsleep }) ?: 10.0
        val debt = sleepDebt(nights(days, endingOn, 7, needHours))
        val bed = usualWake - needHours * 60 - latency - min(30.0, debt / 7)
        return HaloTime.at(endingOn, 18) + (bed * 60_000).toLong()
    }

    // ---- What goes into each score

    /** One thing a score takes into account: today's value, what it's compared with, how well it did and how much it counts. */
    data class Factor(val name: String, val value: String, val note: String, val level: Double?, val weight: String)

    fun factors(kind: ScoreKind, day: DayMetrics, history: List<DayMetrics>, targets: Targets): List<Factor> {
        val past = history.filter { it.date < day.date }.takeLast(BASELINE_DAYS)
        val sleep = sleepScore(day.sleep, past, targets)
        return when (kind) {
            ScoreKind.RECOVERY -> {
                val hrvBase = mean(past.mapNotNull { it.hrv })
                val rhrBase = mean(past.mapNotNull { it.restingHeartRate })
                val (zh, zr) = recoveryZ(day, past)
                listOf(
                    Factor("Heart rate variability", day.hrv?.let { "${it.toInt()} ms" } ?: "–",
                        hrvBase?.let { "Your normal ${Math.round(it)} ms. Higher means more recovered." } ?: "Needs a few nights of data.",
                        zh?.let(::recoveryLevel), "Counts most"),
                    Factor("Resting heart rate", day.restingHeartRate?.let { "${it.toInt()} bpm" } ?: "–",
                        rhrBase?.let { "Your normal ${Math.round(it)} bpm. Lower means more recovered." } ?: "Needs a few days of data.",
                        zr?.let(::recoveryLevel), "Counts some"),
                    Factor("Last night's sleep", sleep?.let { pct(it).toString() } ?: "–", "Your sleep score.", sleep, "A quarter"),
                )
            }
            ScoreKind.EFFORT -> {
                val z = day.zones
                val detail = z?.let { "Moderate ${Math.round(it.fatBurn)} ×¼, cardio ${Math.round(it.cardio)} ×2, peak ${Math.round(it.peak)} ×3. " } ?: ""
                listOf(
                    Factor("Steps", Format.thousands((day.steps ?: 0).toLong()), "Target ${Format.thousands(targets.steps.toLong())}.",
                        effortStepsPart(day, targets), "Half"),
                    Factor("Active minutes", "${Math.round(zonePoints(day))}", "${detail}Target ${targets.zoneMinutes.toInt()}.",
                        effortZonesPart(day, targets), "Half"),
                )
            }
            ScoreKind.SLEEP -> {
                val s = day.sleep ?: return emptyList()
                val need = targets.sleepNeedHours * 60
                val p = sleepParts(s, past, targets)
                val asleep = max(s.minutesAsleep, 1.0)
                val awake = if (s.stages.isEmpty()) s.minutesAwake else s.minutes(SleepStageKind.AWAKE)
                val usual = median(past.takeLast(7).mapNotNull { d -> d.sleep?.let { minutesAfterEvening(it.start) } })
                listOf(
                    Factor("Time asleep", Format.duration(s.minutesAsleep), "Your need is ${Format.duration(need)}.", p.duration, "Counts most"),
                    Factor("Deep and REM",
                        "${Math.round(s.minutes(SleepStageKind.DEEP) / asleep * 100)}% · ${Math.round(s.minutes(SleepStageKind.REM) / asleep * 100)}%",
                        "The restoring stages. Full marks at 20% deep and 23% REM.", p.restorative, "Counts some"),
                    Factor("Efficiency", "${Math.round(s.efficiency * 100)}%", "Time asleep out of time in bed.", p.efficiency, "Counts a little"),
                    Factor("Calm night", "${Math.round(awake)} min awake",
                        "Time awake after falling asleep. 10 minutes or less is full marks.", p.calm, "Counts a little"),
                    Factor("Steady bedtime", Format.time(s.start),
                        usual?.let { "Your usual is around ${Format.time(eveningTime(it, day.date))}." } ?: "Needs a few nights of data.",
                        usual?.let { p.consistency }, "Counts a little"),
                )
            }
        }
    }

    /** Minutes after 6 pm back to a clock time on the evening before `day`. */
    fun eveningTime(minutes: Double, day: LocalDate): Long =
        HaloTime.startOf(day) - 6 * HOUR_MS + (minutes * 60_000).toLong()

    // ---- Words

    fun headline(s: Scores): Pair<String, String> {
        val r = s.recovery ?: return "Waiting for data" to "Wear your band to sleep and Halo will score your recovery in the morning."
        return when {
            r >= 0.67 -> "Primed" to "Your body has bounced back. A good day for a hard session."
            r >= 0.34 -> "Steady" to "You're recovered enough for normal training. Keep intensity moderate."
            else -> "Recharge" to "Your body is still recovering. Go easy and protect tonight's sleep."
        }
    }

    // ---- Helpers

    fun clamp(v: Double): Double = min(1.0, max(0.0, v))

    fun pct(v: Double): Int = Math.round(v * 100).toInt()

    fun median(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        val v = values.sorted()
        val n = v.size
        return if (n % 2 == 1) v[n / 2] else (v[n / 2 - 1] + v[n / 2]) / 2
    }

    fun standardDeviation(values: List<Double>): Double {
        if (values.size <= 1) return 0.0
        val m = mean(values) ?: return 0.0
        return sqrt(values.sumOf { (it - m) * (it - m) } / (values.size - 1))
    }

    fun mean(values: List<Double>): Double? = if (values.isEmpty()) null else values.sum() / values.size
}
