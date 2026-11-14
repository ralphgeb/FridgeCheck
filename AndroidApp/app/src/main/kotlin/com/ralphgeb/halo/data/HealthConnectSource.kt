package com.ralphgeb.halo.data

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SkinTemperatureRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.Vo2MaxRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.request.AggregateGroupByDurationRequest
import androidx.health.connect.client.request.AggregateGroupByPeriodRequest
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import com.ralphgeb.halo.core.DayMetrics
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.HeartMinutes
import com.ralphgeb.halo.core.HeartSample
import com.ralphgeb.halo.core.SleepSession
import com.ralphgeb.halo.core.SleepStage
import com.ralphgeb.halo.core.SleepStageKind
import com.ralphgeb.halo.core.Workout
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.Period
import kotlin.reflect.KClass

/** One line of what a sync found, for Settings. */
data class SyncLine(val name: String, val result: String, val ok: Boolean)

/**
 * Reads from Health Connect, where the Fitbit app (and other bands' apps) keep their data on
 * Android. Read only: Halo never writes. Each kind of data is read on its own, so one that's
 * missing or not allowed never stops the rest.
 */
class HealthConnectSource(private val context: Context) {

    companion object {
        const val PROVIDER = "com.google.android.apps.healthdata"
        const val HISTORY = "android.permission.health.READ_HEALTH_DATA_HISTORY"

        /** Everything Halo asks to read. */
        val permissions: Set<String> = setOf(
            HealthPermission.getReadPermission(SleepSessionRecord::class),
            HealthPermission.getReadPermission(HeartRateRecord::class),
            HealthPermission.getReadPermission(RestingHeartRateRecord::class),
            HealthPermission.getReadPermission(HeartRateVariabilityRmssdRecord::class),
            HealthPermission.getReadPermission(StepsRecord::class),
            HealthPermission.getReadPermission(ActiveCaloriesBurnedRecord::class),
            HealthPermission.getReadPermission(ExerciseSessionRecord::class),
            HealthPermission.getReadPermission(DistanceRecord::class),
            HealthPermission.getReadPermission(OxygenSaturationRecord::class),
            HealthPermission.getReadPermission(RespiratoryRateRecord::class),
            HealthPermission.getReadPermission(WeightRecord::class),
            HealthPermission.getReadPermission(Vo2MaxRecord::class),
            HealthPermission.getReadPermission(SkinTemperatureRecord::class),
            HISTORY,
        )

        /** Without these there's nothing to score. */
        val essential: Set<String> = setOf(
            HealthPermission.getReadPermission(SleepSessionRecord::class),
            HealthPermission.getReadPermission(HeartRateRecord::class),
            HealthPermission.getReadPermission(StepsRecord::class),
        )

        /** Heart rate minute by minute is heavy: only the last two weeks are read. */
        const val HEART_RATE_DAYS = 14
    }

    /** HealthConnectClient.SDK_AVAILABLE, SDK_UNAVAILABLE or SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED. */
    fun status(): Int = HealthConnectClient.getSdkStatus(context, PROVIDER)

    private val client: HealthConnectClient by lazy { HealthConnectClient.getOrCreate(context) }

    suspend fun granted(): Set<String> =
        if (status() == HealthConnectClient.SDK_AVAILABLE) client.permissionController.getGrantedPermissions() else emptySet()

    suspend fun isConnected(): Boolean = granted().containsAll(essential)

    /** Reads the last `days` days (and the evening before, for the first night's sleep). */
    suspend fun fetchDays(days: Int): Pair<List<DayMetrics>, List<SyncLine>> {
        val zone = HaloTime.zone
        val today = HaloTime.today()
        val firstDay = today.minusDays((days - 1).toLong())
        val start = firstDay.minusDays(1).atStartOfDay(zone).toInstant()
        val end = Instant.now()
        val range = TimeRangeFilter.between(start, end)
        val report = mutableListOf<SyncLine>()
        val builders = HashMap<LocalDate, DayMetrics>()
        fun edit(day: LocalDate, change: (DayMetrics) -> DayMetrics) {
            if (day.isBefore(firstDay) || day.isAfter(today)) return
            builders[day] = change(builders[day] ?: DayMetrics(day))
        }
        suspend fun step(name: String, work: suspend () -> String) {
            report += try {
                SyncLine(name, work(), true)
            } catch (e: SecurityException) {
                SyncLine(name, "Not allowed", false)
            } catch (e: Exception) {
                SyncLine(name, e.message ?: "Couldn't read", false)
            }
        }

        step("Sleep") {
            val sessions = readAll(SleepSessionRecord::class, range)
            // a day's sleep is the longest session that ended on it (naps aside)
            sessions.groupBy { HaloTime.dayOf(it.endTime.toEpochMilli()) }.forEach { (day, list) ->
                val longest = list.maxBy { Duration.between(it.startTime, it.endTime).toMinutes() }
                edit(day) { it.copy(sleep = toSession(longest)) }
            }
            "${sessions.size} nights"
        }
        step("Resting heart rate") {
            val records = readAll(RestingHeartRateRecord::class, range)
            records.groupBy { HaloTime.dayOf(it.time.toEpochMilli()) }.forEach { (day, list) ->
                edit(day) { it.copy(restingHeartRate = list.maxBy { r -> r.time }.beatsPerMinute.toDouble()) }
            }
            "${records.size} readings"
        }
        step("Heart rate variability") {
            val records = readAll(HeartRateVariabilityRmssdRecord::class, range)
            records.groupBy { HaloTime.dayOf(it.time.toEpochMilli()) }.forEach { (day, list) ->
                edit(day) { it.copy(hrv = list.map { r -> r.heartRateVariabilityMillis }.average()) }
            }
            "${records.size} readings"
        }
        step("Steps") {
            val groups = client.aggregateGroupByPeriod(
                AggregateGroupByPeriodRequest(
                    metrics = setOf(StepsRecord.COUNT_TOTAL),
                    timeRangeFilter = TimeRangeFilter.between(firstDay.atStartOfDay(), today.plusDays(1).atStartOfDay()),
                    timeRangeSlicer = Period.ofDays(1),
                )
            )
            var n = 0
            groups.forEach { g ->
                g.result[StepsRecord.COUNT_TOTAL]?.let { steps -> n++; edit(g.startTime.toLocalDate()) { it.copy(steps = steps.toInt()) } }
            }
            "$n days"
        }
        step("Active calories") {
            val groups = client.aggregateGroupByPeriod(
                AggregateGroupByPeriodRequest(
                    metrics = setOf(ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL),
                    timeRangeFilter = TimeRangeFilter.between(firstDay.atStartOfDay(), today.plusDays(1).atStartOfDay()),
                    timeRangeSlicer = Period.ofDays(1),
                )
            )
            var n = 0
            groups.forEach { g ->
                g.result[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.let { e ->
                    n++
                    edit(g.startTime.toLocalDate()) { it.copy(activeCalories = e.inKilocalories) }
                }
            }
            "$n days"
        }
        step("Steps by hour") {
            // today and yesterday, for the day graphs
            val from = today.minusDays(1)
            val groups = client.aggregateGroupByDuration(
                AggregateGroupByDurationRequest(
                    metrics = setOf(StepsRecord.COUNT_TOTAL),
                    timeRangeFilter = TimeRangeFilter.between(from.atStartOfDay(zone).toInstant(), end),
                    timeRangeSlicer = Duration.ofHours(1),
                )
            )
            val hours = HashMap<LocalDate, DoubleArray>()
            groups.forEach { g ->
                val t = g.startTime.toEpochMilli()
                val steps = g.result[StepsRecord.COUNT_TOTAL] ?: return@forEach
                hours.getOrPut(HaloTime.dayOf(t)) { DoubleArray(24) }[HaloTime.hourOf(t)] += steps.toDouble()
            }
            hours.forEach { (day, h) -> edit(day) { it.copy(hourlySteps = h.toList()) } }
            "${groups.size} hours"
        }
        val heart = mutableListOf<HeartSample>()
        step("Heart rate") {
            val from = today.minusDays((HEART_RATE_DAYS - 1).toLong()).atStartOfDay(zone).toInstant()
            val records = readAll(HeartRateRecord::class, TimeRangeFilter.between(maxOf(from, start), end))
            records.forEach { r -> r.samples.forEach { heart += HeartSample(it.time.toEpochMilli(), it.beatsPerMinute.toDouble()) } }
            HeartMinutes.buckets(heart).forEach { (day, minutes) -> edit(day) { it.copy(minuteHeartRate = minutes) } }
            "${heart.size} readings"
        }
        step("Workouts") {
            val sessions = readAll(ExerciseSessionRecord::class, range)
            sessions.groupBy { HaloTime.dayOf(it.startTime.toEpochMilli()) }.forEach { (day, list) ->
                val workouts = list.map { s -> toWorkout(s, heart) }
                edit(day) { it.copy(workouts = workouts) }
            }
            "${sessions.size} sessions"
        }
        step("Blood oxygen") {
            val records = readAll(OxygenSaturationRecord::class, range)
            records.groupBy { HaloTime.dayOf(it.time.toEpochMilli()) }.forEach { (day, list) ->
                edit(day) { it.copy(spo2 = list.map { r -> r.percentage.value }.average()) }
            }
            "${records.size} readings"
        }
        step("Breathing rate") {
            val records = readAll(RespiratoryRateRecord::class, range)
            records.groupBy { HaloTime.dayOf(it.time.toEpochMilli()) }.forEach { (day, list) ->
                edit(day) { it.copy(respiratoryRate = list.map { r -> r.rate }.average()) }
            }
            "${records.size} readings"
        }
        step("Skin temperature") {
            // change from your baseline, through the night
            val records = readAll(SkinTemperatureRecord::class, range)
            records.groupBy { HaloTime.dayOf(it.endTime.toEpochMilli()) }.forEach { (day, list) ->
                val deltas = list.flatMap { r -> r.deltas.map { d -> d.delta.inCelsius } }
                if (deltas.isNotEmpty()) edit(day) { it.copy(skinTempDelta = Math.round(deltas.average() * 10) / 10.0) }
            }
            "${records.size} nights"
        }
        step("Weight") {
            val records = readAll(WeightRecord::class, range)
            records.groupBy { HaloTime.dayOf(it.time.toEpochMilli()) }.forEach { (day, list) ->
                edit(day) { it.copy(weightKg = list.maxBy { r -> r.time }.weight.inKilograms) }
            }
            "${records.size} readings"
        }
        step("VO₂ max") {
            val records = readAll(Vo2MaxRecord::class, range)
            records.groupBy { HaloTime.dayOf(it.time.toEpochMilli()) }.forEach { (day, list) ->
                edit(day) { it.copy(vo2Max = list.maxBy { r -> r.time }.vo2MillilitersPerMinuteKilogram) }
            }
            "${records.size} readings"
        }
        return builders.values.sortedBy { it.date } to report
    }

    private suspend fun <T : Record> readAll(type: KClass<T>, range: TimeRangeFilter): List<T> {
        val out = mutableListOf<T>()
        var token: String? = null
        do {
            val response = client.readRecords(ReadRecordsRequest(type, range, pageToken = token))
            out += response.records
            token = response.pageToken
        } while (!token.isNullOrEmpty())
        return out
    }

    private fun toSession(r: SleepSessionRecord): SleepSession {
        val stages = r.stages.mapNotNull { s ->
            val kind = when (s.stage) {
                SleepSessionRecord.STAGE_TYPE_DEEP -> SleepStageKind.DEEP
                SleepSessionRecord.STAGE_TYPE_REM -> SleepStageKind.REM
                SleepSessionRecord.STAGE_TYPE_LIGHT, SleepSessionRecord.STAGE_TYPE_SLEEPING -> SleepStageKind.LIGHT
                SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
                SleepSessionRecord.STAGE_TYPE_OUT_OF_BED -> SleepStageKind.AWAKE
                else -> null
            }
            kind?.let { SleepStage(it, s.startTime.toEpochMilli(), s.endTime.toEpochMilli()) }
        }.sortedBy { it.start }
        val start = r.startTime.toEpochMilli()
        val end = r.endTime.toEpochMilli()
        val awake = stages.filter { it.kind == SleepStageKind.AWAKE }.sumOf { it.minutes }
        val asleep = if (stages.any { it.kind != SleepStageKind.AWAKE }) {
            stages.filter { it.kind != SleepStageKind.AWAKE }.sumOf { it.minutes }
        } else (end - start) / 60_000.0 - awake
        return SleepSession(start, end, Math.round(asleep).toDouble(), Math.round(awake).toDouble(), stages)
    }

    private suspend fun toWorkout(s: ExerciseSessionRecord, heart: List<HeartSample>): Workout {
        val start = s.startTime.toEpochMilli()
        val end = s.endTime.toEpochMilli()
        val during = heart.filter { it.time in start..end }
        val range = TimeRangeFilter.between(s.startTime, s.endTime)
        val totals = runCatching {
            client.aggregate(AggregateRequest(setOf(ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL, DistanceRecord.DISTANCE_TOTAL), range))
        }.getOrNull()
        return Workout(
            id = s.metadata.id,
            kind = s.title?.takeIf { it.isNotBlank() } ?: exerciseName(s.exerciseType),
            start = start,
            end = end,
            calories = totals?.get(ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL)?.inKilocalories,
            averageHeartRate = during.takeIf { it.isNotEmpty() }?.map { it.bpm }?.average(),
            maxHeartRate = during.maxOfOrNull { it.bpm },
            distanceKm = totals?.get(DistanceRecord.DISTANCE_TOTAL)?.inKilometers?.takeIf { it > 0.05 },
        )
    }

    private fun exerciseName(type: Int): String = when (type) {
        ExerciseSessionRecord.EXERCISE_TYPE_RUNNING -> "Run"
        ExerciseSessionRecord.EXERCISE_TYPE_WALKING -> "Walk"
        ExerciseSessionRecord.EXERCISE_TYPE_BIKING -> "Ride"
        ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL, ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER -> "Swim"
        ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING -> "Strength"
        ExerciseSessionRecord.EXERCISE_TYPE_HIKING -> "Hike"
        ExerciseSessionRecord.EXERCISE_TYPE_YOGA -> "Yoga"
        ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING -> "HIIT"
        ExerciseSessionRecord.EXERCISE_TYPE_TENNIS -> "Tennis"
        ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL -> "Elliptical"
        ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE -> "Rowing"
        else -> "Workout"
    }
}
