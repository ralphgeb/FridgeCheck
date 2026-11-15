package com.ralphgeb.halo.core

import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The formulas checked against values worked out by hand from the iPhone app's ScoreEngine. */
class ScoreEngineTest {
    private val day = LocalDate.of(2026, 11, 10)

    @BeforeTest
    fun zone() {
        HaloTime.zone = ZoneId.of("Europe/London")
    }

    private fun near(expected: Double, actual: Double?, tolerance: Double = 0.001) {
        assertNotNull(actual)
        assertTrue(abs(expected - actual) <= tolerance, "expected $expected, got $actual")
    }

    /** 8 hours asleep in 8h20m in bed: 20% deep, 23% REM, 20 minutes awake, no history. */
    private fun goodNight(): SleepSession {
        val bed = HaloTime.at(day.minusDays(1), 23)
        var t = bed
        val stages = mutableListOf<SleepStage>()
        fun add(kind: SleepStageKind, minutes: Double) {
            val end = t + (minutes * 60_000).toLong()
            stages += SleepStage(kind, t, end)
            t = end
        }
        add(SleepStageKind.AWAKE, 10.0)
        add(SleepStageKind.DEEP, 96.0)
        add(SleepStageKind.REM, 110.4)
        add(SleepStageKind.LIGHT, 273.6)
        add(SleepStageKind.AWAKE, 10.0)
        return SleepSession(bed, t, 480.0, 20.0, stages)
    }

    @Test
    fun sleepScoreMatchesTheFormula() {
        // duration 1, restorative 1, efficiency 1 (96%), calm 1 − 10/65, consistency 0.8 → raw^1.15
        val raw = 0.50 + 0.20 + 0.10 + 0.10 * (1 - 10.0 / 65) + 0.10 * 0.8
        near(Math.pow(raw, 1.15), ScoreEngine.sleepScore(goodNight(), emptyList(), Targets()))
    }

    @Test
    fun shortSleepHasNoScore() {
        val s = SleepSession(0, 50 * 60_000L, 50.0, 0.0, emptyList())
        assertNull(ScoreEngine.sleepScore(s, emptyList(), Targets()))
    }

    @Test
    fun usualMorningIsTheEdgeOfGreen() {
        near(0.6682, ScoreEngine.recoveryLevel(0.0), 0.0001)
    }

    @Test
    fun recoveryAgainstAFlatBaseline() {
        // ten identical mornings: today's HRV 10% up and RHR 2 lower
        val history = (1..10).map { DayMetrics(day.minusDays(it.toLong()), hrv = 50.0, restingHeartRate = 55.0) }.reversed()
        val today = DayMetrics(day, hrv = 55.0, restingHeartRate = 53.0)
        val zh = Math.log(55.0 / 50.0) / 0.08          // spread floors at 0.08 on the log scale
        val zr = 2.0 / 1.5                              // and 1.5 bpm
        val z = (zh.coerceIn(-2.5, 2.5) * 0.7 + zr * 0.3)
        near(ScoreEngine.recoveryLevel(z), ScoreEngine.recoveryScore(today, history, null))
    }

    @Test
    fun effortIsHalfStepsHalfZones() {
        val d = DayMetrics(day, steps = 5_000, zoneMinutes = ZoneMinutes(fatBurn = 8.0, cardio = 10.0))
        // steps 0.5; zone points 8×¼ + 10×2 = 22 of 30; filling like strain
        near(1 - Math.exp(-1.2 * (0.5 * 0.5 + 0.5 * (22.0 / 30))), ScoreEngine.effortScore(d, Targets()))
    }

    @Test
    fun meetingBothTargetsIsAboutSeventy() {
        // 15 Nov on a Fitbit: 10,010 steps and 67/8/0 zone minutes read 100; it should read about 70
        val d = DayMetrics(day, steps = 10_010, zoneMinutes = ZoneMinutes(fatBurn = 67.0, cardio = 8.0))
        val e = ScoreEngine.effortScore(d, Targets())!!
        assertTrue(e in 0.68..0.75, "effort $e")
    }

    @Test
    fun effortWithoutHeartRateUsesTheLoad() {
        // a Whoop day with no heart rate to hand: 14,345 steps and a load of 22 from its strain
        val d = DayMetrics(day, steps = 14_345, heartLoad = 22.0)
        val e = ScoreEngine.effortScore(d, Targets())!!
        assertTrue(e in 0.55..0.70, "effort $e")
    }

    @Test
    fun cardioLoadPerMinute() {
        near(0.5 * 0.64 * Math.exp(0.96), CardioLoad.perMinute(0.5), 0.00001)
        assertEquals(0.0, CardioLoad.perMinute(0.0))
    }

    @Test
    fun aLoneSpikeEarnsNoLoad() {
        val t0 = HaloTime.at(day, 12)
        val samples = listOf(HeartSample(t0, 60.0), HeartSample(t0 + 60_000, 150.0), HeartSample(t0 + 120_000, 60.0))
        val (load, _) = CardioLoad.fromHeartRate(samples, resting = 55.0, maxHR = 185.0)
        assertEquals(0.0, load)
    }

    @Test
    fun sustainedEffortEarnsLoadAndZones() {
        val t0 = HaloTime.at(day, 18)
        // 30 minutes at 150 bpm with 55 resting and 185 max: 73% of reserve, cardio zone
        val samples = (0..30).map { HeartSample(t0 + it * 60_000L, 150.0) }
        val (load, zones) = CardioLoad.fromHeartRate(samples, resting = 55.0, maxHR = 185.0)
        val x = 95.0 / 130.0
        near(CardioLoad.perMinute(x) * 31, load, 0.01)   // every reading counts a minute (the last one too)
        near(31.0, zones.cardio)
    }

    @Test
    fun sampleDataIsDeterministicAndScores() {
        val end = HaloTime.at(day, 20)
        val a = SampleData.days(endingOn = end)
        val b = SampleData.days(endingOn = end)
        assertEquals(182, a.size)
        assertEquals(a, b)
        val last = a.last()
        val s = ScoreEngine.scores(last, a, Targets())
        assertNotNull(s.recovery)
        assertNotNull(s.sleep)
        assertNotNull(s.effort)
        val balance = ScoreEngine.balance(a, last.date, Targets()) { ScoreEngine.scores(it, a, Targets()) }
        assertEquals(6, balance.size)
        balance.forEach { assertTrue(it.value in 0.0..1.0, "${it.name} ${it.value}") }
    }

    @Test
    fun weekTargetStartsAtTheMinimum() {
        val w = CardioLoad.week(emptyList(), day, CardioFocus.AUTO, null)
        assertEquals(CardioLoad.MINIMUM_TARGET, w.target)
        assertEquals(CardioFocus.MAINTAIN, w.focus)
    }

    @Test
    fun formatting() {
        assertEquals("7h 22m", Format.duration(442.0))
        assertEquals("45m", Format.duration(45.0))
    }

    @Test
    fun afterMidnightKeepsYesterdaysRecoveryAndSleep() {
        val today = HaloTime.today()
        // a year of days, but today only has steps so far: no sleep yet
        val days = SampleData.days().filter { it.date.isBefore(today) } + DayMetrics(today, steps = 120)
        val s = Snapshot(days, Targets(), Profile(), isSample = false)
        val yesterday = s.scores(today.minusDays(1))
        assertNotNull(yesterday.recovery)
        assertNull(s.scores(today).recovery)
        val shown = s.shownScores(today)
        assertEquals(yesterday.recovery, shown.recovery)
        assertEquals(yesterday.sleep, shown.sleep)
        assertEquals(s.scores(today).effort, shown.effort)
        // once last night's sleep is in, today's own scores show
        val slept = Snapshot(SampleData.days(), Targets(), Profile(), isSample = false)
        if (slept.day(today)?.sleep != null) assertEquals(slept.scores(today), slept.shownScores(today))
    }

    @Test
    fun theLongestSleepIsTheNightAndTheRestAreNaps() {
        val night = SleepSession(0, 7 * 3_600_000L, 400.0, 20.0, emptyList())
        val nap = SleepSession(13 * 3_600_000L, 13 * 3_600_000L + 40 * 60_000L, 35.0, 5.0, emptyList())
        val blip = SleepSession(16 * 3_600_000L, 16 * 3_600_000L + 6 * 60_000L, 5.0, 1.0, emptyList())
        val d = DayMetrics(day).addingSleep(nap).addingSleep(night).addingSleep(blip)
        assertEquals(400.0, d.sleep?.minutesAsleep)
        assertEquals(listOf(35.0), d.naps?.map { it.minutesAsleep })
        // naps count towards the sleep bank
        val n = ScoreEngine.nights(listOf(d), day, 1, 7.5)
        assertEquals(435.0, n.single().asleep)
    }
}
