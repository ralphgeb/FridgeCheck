package com.ralphgeb.halo.core

import java.time.LocalDate
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Your normal for a metric: the mean of the last 30 days, ±1.5 of your spread (at least `minimumBand`). */
data class NormalRange(val low: Double, val high: Double) {
    fun contains(v: Double): Boolean = v in low..high

    companion object {
        fun of(values: List<Double>, minimumBand: Double): NormalRange? {
            if (values.size < 5) return null
            val mean = values.sum() / values.size
            val sd = sqrt(values.sumOf { (it - mean) * (it - mean) } / values.size)
            val band = max(1.5 * sd, minimumBand)
            return NormalRange(mean - band, mean + band)
        }
    }
}

/** What Halo tracks on the Health tab, in its sections. */
enum class Metric(
    val title: String,
    val short: String,
    val unit: String,
    /** True if higher is better, false if lower is, null if neither. */
    val higherIsBetter: Boolean?,
    /** The smallest normal-range half-width that makes sense. */
    val minimumBand: Double = 0.0,
) {
    HRV("Heart rate variability", "HRV", "ms", true, 6.0),
    RESTING_HEART_RATE("Resting heart rate", "RHR", "bpm", false, 2.0),
    RESPIRATORY_RATE("Respiratory rate", "Breath", "br/min", null, 0.6),
    SPO2("Blood oxygen", "SpO₂", "%", true, 1.0),
    SKIN_TEMP("Skin temperature", "Temp", "°C", null, 0.5),
    STEPS("Steps", "Steps", "steps", true),
    CARDIO_LOAD("Cardio load", "Load", "", true),
    ACTIVE_MINUTES("Active zone minutes", "AZM", "min", true),
    ACTIVE_CALORIES("Active calories", "Active", "kcal", true),
    WEIGHT("Weight", "Weight", "kg", null),
    VO2_MAX("VO₂ max", "VO₂", "", true),
    SLEEP_DURATION("Time asleep", "Asleep", "", true),
    RECOVERY("Recovery", "Recovery", "%", true),
    EFFORT("Effort", "Effort", "%", true),
    SLEEP_SCORE("Sleep score", "Sleep", "%", true);

    /** Whether a reading outside your normal range is worth flagging: only the worse side counts. */
    fun isConcerning(v: Double, range: NormalRange): Boolean = when (this) {
        HRV, SPO2 -> v < range.low
        RESTING_HEART_RATE, RESPIRATORY_RATE -> v > range.high
        else -> !range.contains(v)
    }

    fun format(v: Double): String = when (this) {
        RESPIRATORY_RATE -> "%.1f".format(v)
        SPO2 -> "%.1f".format(v)
        SKIN_TEMP -> (if (v >= 0) "+" else "−") + "%.1f".format(kotlin.math.abs(v))
        WEIGHT -> "%.1f".format(v)
        STEPS, ACTIVE_CALORIES -> Format.thousands(Math.round(v))
        SLEEP_DURATION -> Format.duration(v)
        RECOVERY, EFFORT, SLEEP_SCORE -> Format.percent(v)
        else -> Math.round(v).toString()
    }

    companion object {
        /** The five vitals, as on the iPhone: HRV, resting heart rate, breathing, blood oxygen and skin temperature. */
        val monitored = listOf(HRV, RESTING_HEART_RATE, RESPIRATORY_RATE, SPO2, SKIN_TEMP)
        val sections = listOf(
            "Heart" to listOf(HRV, RESTING_HEART_RATE),
            "Overnight" to listOf(RESPIRATORY_RATE, SPO2, SKIN_TEMP),
            "Activity" to listOf(STEPS, CARDIO_LOAD, ACTIVE_MINUTES, ACTIVE_CALORIES),
            "Body" to listOf(WEIGHT, VO2_MAX),
            "Scores" to listOf(RECOVERY, EFFORT, SLEEP_SCORE),
        )
    }
}

/**
 * Everything the screens read: the days, each day's scores, and what's worked out from them.
 * Built once per change of data (scores take a moment with a year of days), never while drawing.
 */
class Snapshot(
    val days: List<DayMetrics>,
    val targets: Targets,
    val profile: Profile,
    /** True while the days are made-up sample data. */
    val isSample: Boolean,
) {
    private val byDate: Map<LocalDate, DayMetrics> = days.associateBy { it.date }
    private val scoreCache: Map<LocalDate, Scores> = days.indices.associate { i ->
        val history = days.subList(max(0, i - ScoreEngine.BASELINE_DAYS), i)
        days[i].date to ScoreEngine.scores(days[i], history, targets)
    }

    val firstDate: LocalDate get() = days.firstOrNull()?.date ?: HaloTime.today()

    fun day(date: LocalDate): DayMetrics? = byDate[date]

    fun scores(date: LocalDate): Scores = scoreCache[date] ?: Scores()

    /** How ready you are to train: recovery and sleep, less a little after an unusually heavy week. */
    fun readiness(date: LocalDate): Double? {
        val s = scores(date)
        val recovery = s.recovery ?: return null
        var v = 0.7 * recovery + 0.3 * (s.sleep ?: recovery)
        val start = date.minusDays(6)
        val recent = CardioLoad.weekTotal(byDate, start)
        val usual = CardioLoad.baseline(byDate, start)
        if (recent != null && usual != null && usual > 0) {
            val ratio = recent / usual
            if (ratio > 1.3) v -= min(0.15, (ratio - 1.3) * 0.3)
        }
        return ScoreEngine.clamp(v)
    }

    fun value(metric: Metric, d: DayMetrics): Double? = when (metric) {
        Metric.HRV -> d.hrv
        Metric.RESTING_HEART_RATE -> d.restingHeartRate
        Metric.RESPIRATORY_RATE -> d.respiratoryRate
        Metric.SPO2 -> d.spo2
        Metric.SKIN_TEMP -> d.skinTempDelta
        Metric.STEPS -> d.steps?.toDouble()
        Metric.CARDIO_LOAD -> d.cardioLoad
        Metric.ACTIVE_MINUTES -> d.activeZoneMinutes ?: d.zones?.let { it.fatBurn + 2 * (it.cardio + it.peak) }
        Metric.ACTIVE_CALORIES -> d.activeCalories
        Metric.WEIGHT -> d.weightKg
        Metric.VO2_MAX -> d.vo2Max
        Metric.SLEEP_DURATION -> d.sleep?.minutesAsleep
        Metric.RECOVERY -> scores(d.date).recovery
        Metric.EFFORT -> scores(d.date).effort
        Metric.SLEEP_SCORE -> scores(d.date).sleep
    }?.takeIf { it.isFinite() }

    fun value(metric: Metric, date: LocalDate): Double? = day(date)?.let { value(metric, it) }

    /** The last `count` days of a metric ending on `date`, oldest first (days without a value left out). */
    fun series(metric: Metric, count: Int, endingOn: LocalDate): List<Pair<LocalDate, Double>> {
        val start = endingOn.minusDays((count - 1).toLong())
        return days.filter { !it.date.isBefore(start) && !it.date.isAfter(endingOn) }
            .mapNotNull { d -> value(metric, d)?.let { d.date to it } }
    }

    fun normalRange(metric: Metric, before: LocalDate): NormalRange? =
        NormalRange.of(days.filter { it.date.isBefore(before) }.takeLast(30).mapNotNull { value(metric, it) }, metric.minimumBand)

    /** Mean of a metric over the 30 days before `date`. */
    fun baseline(metric: Metric, before: LocalDate): Double? =
        ScoreEngine.mean(days.filter { it.date.isBefore(before) }.takeLast(30).mapNotNull { value(metric, it) })

    fun balance(date: LocalDate, span: Int = 7): List<BalanceAxis> =
        ScoreEngine.balance(days, date, targets, span) { scores(it.date) }

    fun cardioWeek(date: LocalDate): CardioLoad.Week =
        CardioLoad.week(days, date, CardioFocus.AUTO, scores(date).recovery)

    fun factors(kind: ScoreKind, date: LocalDate): List<ScoreEngine.Factor> {
        val d = day(date) ?: return emptyList()
        return ScoreEngine.factors(kind, d, days.filter { it.date.isBefore(date) }.takeLast(ScoreEngine.BASELINE_DAYS) + d, targets)
    }

    fun nights(date: LocalDate, count: Int): List<ScoreEngine.Night> =
        ScoreEngine.nights(days, date, count, targets.sleepNeedHours)

    fun bedtime(date: LocalDate): Long? = ScoreEngine.bedtime(days, date, targets.sleepNeedHours)

    /** One of the five vitals: its latest reading (last night, or up to two nights before) against your normal. */
    data class Vital(val metric: Metric, val value: Double?, val range: NormalRange?, val date: LocalDate?) {
        /** -1 under your normal, 0 inside, 1 over; null until there are enough days. */
        val position: Int?
            get() = if (value == null || range == null) null else if (value < range.low) -1 else if (value > range.high) 1 else 0
        val concerning: Boolean get() = value != null && range != null && metric.isConcerning(value, range)
    }

    fun vitals(date: LocalDate): List<Vital> = Metric.monitored.map { m ->
        val day = (0L..2L).map { date.minusDays(it) }.firstOrNull { value(m, it) != null }
        Vital(m, day?.let { value(m, it) }, day?.let { normalRange(m, it) }, day)
    }

    /** Workouts on a day, latest first. */
    fun workouts(date: LocalDate): List<Workout> = day(date)?.workouts.orEmpty().sortedByDescending { it.start }

    companion object {
        fun sample(targets: Targets = Targets(), profile: Profile = Profile()): Snapshot =
            Snapshot(SampleData.days(), targets, profile, isSample = true)
    }
}
