package com.ralphgeb.halo.data

import com.ralphgeb.halo.core.DayMetrics
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.HeartMinutes
import com.ralphgeb.halo.core.HeartSample
import com.ralphgeb.halo.core.SleepSession
import com.ralphgeb.halo.core.SleepStage
import com.ralphgeb.halo.core.SleepStageKind
import com.ralphgeb.halo.core.Workout
import com.ralphgeb.halo.core.ZoneMinutes
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

/**
 * Reads Fitbit data straight from your Fitbit account, through the Google Health API (v4), which
 * replaced the Fitbit Web API. This is the same reader as the iPhone app's, and it gets more than
 * Health Connect: skin temperature, heart-rate zones, Active Zone Minutes, breathing rate, HRV and
 * blood oxygen as Fitbit works them out.
 *
 * Responses are read loosely (maps and lists) on purpose: the API is new and several daily types
 * name their value differently.
 */
class GoogleHealthClient(private val token: suspend () -> String) {
    private val base = "https://health.googleapis.com/v4/users/me/dataTypes"

    class ApiError(code: Int, message: String) : Exception("Google Health API error $code: $message")

    private fun <T> take(name: String, result: Result<List<T>>, unit: String, report: MutableList<SyncLine>): List<T> =
        result.fold(
            onSuccess = { report += SyncLine(name, "${it.size} $unit", true); it },
            onFailure = { report += SyncLine(name, it.message ?: "Couldn't read", false); emptyList() },
        )

    /** The last `count` days. */
    suspend fun fetchDays(count: Int): Pair<List<DayMetrics>, List<SyncLine>> = coroutineScope {
        val today = HaloTime.today()
        val from = today.minusDays((count - 1).toLong())
        val days = HashMap<LocalDate, DayMetrics>()
        val report = mutableListOf<SyncLine>()
        fun edit(date: LocalDate, change: (DayMetrics) -> DayMetrics) {
            if (date.isBefore(from) || date.isAfter(today)) return
            days[date] = change(days[date] ?: DayMetrics(date))
        }
        fun <T> attempt(work: suspend () -> List<T>) = async { runCatching { work() } }

        // everything runs at once
        val rhr = attempt { dailyValues("daily-resting-heart-rate", from) }
        val hrv = attempt { dailyValues("daily-heart-rate-variability", from, listOf("rmssd", "average", "milli")) }
        val spo2 = attempt { dailyValues("daily-oxygen-saturation", from, listOf("average", "percentage")) }
        val resp = attempt { dailyValues("daily-respiratory-rate", from, listOf("breath", "average", "rate")) }
        val temp = attempt { dailyValues("daily-sleep-temperature-derivations", from, listOf("relative", "deviation", "delta", "difference"), strict = true) }
        val vo2 = attempt { dailyValues("daily-vo2-max", from) }
        val steps = attempt { dailyTotals("steps", from, today, listOf("count")) }
        val azm = attempt { rollUp("active-zone-minutes", from, today) }
        val zones = attempt { zoneMinutes(from, today) }
        val kcal = attempt { dailyTotals("active-energy-burned", from, today, listOf("kcal", "calorie")) }
        val sleeps = attempt { sleepSessions(from) }
        val weights = attempt { weightReadings(from) }
        val exercises = attempt { workouts(minOf(from, today.minusDays(60))) }
        // heart rate is tens of thousands of readings a day: only the last two days each sync
        val heart = attempt { heartRate(HaloTime.startOf(today.minusDays(2))) }
        val hourSteps = attempt { hourly("steps", HaloTime.startOf(today.minusDays(1)), listOf("count")) }
        val hourKcal = attempt { hourly("active-energy-burned", HaloTime.startOf(today.minusDays(1)), listOf("kcal", "calorie")) }

        take("Steps", steps.await(), "days", report).forEach { (d, v) -> edit(d) { it.copy(steps = Math.round(v).toInt()) } }
        take("Heart-rate zones", zones.await(), "days", report).forEach { (d, z) -> edit(d) { it.copy(zoneMinutes = z) } }
        take("Active Zone Minutes", azm.await(), "days", report).forEach { (d, v) -> edit(d) { it.copy(activeZoneMinutes = v) } }
        take("Active calories", kcal.await(), "days", report).forEach { (d, v) -> edit(d) { it.copy(activeCalories = v) } }
        take("Resting heart rate", rhr.await(), "days", report).forEach { (d, v) -> edit(d) { it.copy(restingHeartRate = v) } }
        take("HRV", hrv.await(), "days", report).forEach { (d, v) -> edit(d) { it.copy(hrv = v) } }
        take("Blood oxygen", spo2.await(), "days", report).forEach { (d, v) -> edit(d) { it.copy(spo2 = v) } }
        take("Breathing rate", resp.await(), "days", report).forEach { (d, v) -> edit(d) { it.copy(respiratoryRate = v) } }
        take("Skin temperature", temp.await(), "days", report).forEach { (d, v) -> edit(d) { it.copy(skinTempDelta = v) } }
        take("Cardio fitness", vo2.await(), "days", report).forEach { (d, v) -> edit(d) { it.copy(vo2Max = v) } }
        take("Weight", weights.await(), "readings", report).forEach { (t, kg) -> edit(HaloTime.dayOf(t)) { it.copy(weightKg = kg) } }
        // sleep belongs to the day you woke up on; with naps, the longest wins
        val sleepResult = sleeps.await()
        take("Sleep", sleepResult, "nights", report).forEach { s ->
            edit(HaloTime.dayOf(s.end)) { d -> if ((d.sleep?.minutesAsleep ?: 0.0) < s.minutesAsleep) d.copy(sleep = s) else d }
        }
        take("Workouts", exercises.await(), "sessions", report).forEach { w ->
            edit(HaloTime.dayOf(w.start)) { d ->
                val list = d.workouts.orEmpty()
                if (list.any { it.id == w.id }) d else d.copy(workouts = (list + w).sortedBy { it.start })
            }
        }
        val readings = take("Heart rate", heart.await(), "readings", report)
        HeartMinutes.buckets(readings).forEach { (day, minutes) -> edit(day) { it.copy(minuteHeartRate = minutes) } }
        applyHourly(take("Steps by hour", hourSteps.await(), "hours", report)) { d, h -> edit(d) { it.copy(hourlySteps = h) } }
        applyHourly(take("Calories by hour", hourKcal.await(), "hours", report)) { d, h -> edit(d) { it.copy(hourlyCalories = h) } }
        // without sleep there's nothing to score, so that one fails the sync
        sleepResult.exceptionOrNull()?.let { throw it }
        days.values.sortedBy { it.date } to report
    }

    private fun applyHourly(values: List<Pair<Long, Double>>, set: (LocalDate, List<Double>) -> Unit) {
        val byDay = HashMap<LocalDate, DoubleArray>()
        values.forEach { (t, v) -> byDay.getOrPut(HaloTime.dayOf(t)) { DoubleArray(24) }[HaloTime.hourOf(t)] += v }
        byDay.forEach { (d, h) -> set(d, h.toList()) }
    }

    // ---- Data types

    /** Daily summary types: each point holds a civil "date" and one number. */
    private suspend fun dailyValues(type: String, from: LocalDate, prefer: List<String> = emptyList(), strict: Boolean = false): List<Pair<LocalDate, Double>> {
        val filter = "${type.replace('-', '_')}.date >= \"$from\""
        return list(type, filter, 1000).mapNotNull { point ->
            val inner = innerObject(point) ?: return@mapNotNull null
            val date = dateFromCivil(inner["date"]) ?: return@mapNotNull null
            val value = number(inner, prefer, strict) ?: return@mapNotNull null
            date to value
        }
    }

    /** Daily totals: by civil day first, else 24-hour windows from local midnight. */
    private suspend fun dailyTotals(type: String, from: LocalDate, to: LocalDate, prefer: List<String>): List<Pair<LocalDate, Double>> {
        val civil = try {
            rollUp(type, from, to, prefer)
        } catch (e: Exception) {
            val fallback = runCatching { physicalRollUp(type, from, to, prefer) }.getOrNull()
            if (!fallback.isNullOrEmpty()) return fallback
            throw e
        }
        return civil.ifEmpty { physicalRollUp(type, from, to, prefer) }
    }

    /** Daily totals by civil day, a month at a time (the API caps a request at 90 days). */
    private suspend fun rollUp(type: String, from: LocalDate, to: LocalDate, prefer: List<String> = emptyList()): List<Pair<LocalDate, Double>> {
        val out = mutableListOf<Pair<LocalDate, Double>>()
        var firstError: Exception? = null
        for ((start, end) in chunks(from, to, 30)) {
            try {
                out += rollUpChunk(type, start, end, prefer)
            } catch (e: Exception) {
                if (firstError == null) firstError = e
            }
        }
        if (out.isEmpty() && firstError != null) throw firstError
        return out
    }

    private suspend fun rollUpChunk(type: String, from: LocalDate, to: LocalDate, prefer: List<String>): List<Pair<LocalDate, Double>> {
        val body = JSONObject()
            .put("range", JSONObject().put("start", civilObject(from)).put("end", civilObject(to.plusDays(1))))
            .put("windowSizeDays", 1)
        val out = mutableListOf<Pair<LocalDate, Double>>()
        pages("$base/$type/dataPoints:dailyRollUp", body) { json ->
            for (point in maps(json["rollupDataPoints"])) {
                val date = dateFromCivil((point["civilStartTime"] as? Map<*, *>)?.get("date")) ?: continue
                val inner = valueObject(point, type) ?: continue
                val v = number(inner, prefer + "sum") ?: continue
                out += date to v
            }
        }
        return out
    }

    private suspend fun physicalRollUp(type: String, from: LocalDate, to: LocalDate, prefer: List<String>): List<Pair<LocalDate, Double>> {
        val out = mutableListOf<Pair<LocalDate, Double>>()
        for ((start, last) in chunks(from, to, 30)) {
            val body = JSONObject()
                .put("range", JSONObject().put("startTime", iso(HaloTime.startOf(start))).put("endTime", iso(HaloTime.startOf(last.plusDays(1)))))
                .put("windowSize", "86400s")
            pages("$base/$type/dataPoints:rollUp", body) { json ->
                for (point in maps(json["rollupDataPoints"])) {
                    val t = instant(point["startTime"]) ?: continue
                    val inner = valueObject(point, type) ?: continue
                    val v = number(inner, prefer + "sum") ?: continue
                    // an hour in, so a daylight-saving shift can't push it into the day before
                    out += HaloTime.dayOf(t + 3_600_000) to v
                }
            }
        }
        return out
    }

    /** Hourly totals from `from` until now. */
    private suspend fun hourly(type: String, from: Long, prefer: List<String>): List<Pair<Long, Double>> {
        val body = JSONObject()
            .put("range", JSONObject().put("startTime", iso(from)).put("endTime", iso(System.currentTimeMillis())))
            .put("windowSize", "3600s")
        val out = mutableListOf<Pair<Long, Double>>()
        pages("$base/$type/dataPoints:rollUp", body) { json ->
            for (point in maps(json["rollupDataPoints"])) {
                val t = instant(point["startTime"]) ?: continue
                val inner = valueObject(point, type) ?: continue
                val v = number(inner, prefer + "sum") ?: continue
                out += t to v
            }
        }
        return out
    }

    /** Minutes in each heart-rate zone per day. */
    private suspend fun zoneMinutes(from: LocalDate, to: LocalDate): List<Pair<LocalDate, ZoneMinutes>> {
        val out = mutableListOf<Pair<LocalDate, ZoneMinutes>>()
        for ((start, last) in chunks(from, to, 30)) {
            val body = JSONObject()
                .put("range", JSONObject().put("start", civilObject(start)).put("end", civilObject(last.plusDays(1))))
                .put("windowSizeDays", 1)
            pages("$base/time-in-heart-rate-zone/dataPoints:dailyRollUp", body) { json ->
                for (point in maps(json["rollupDataPoints"])) {
                    val date = dateFromCivil((point["civilStartTime"] as? Map<*, *>)?.get("date")) ?: continue
                    var z = zones(point.filterKeys { !it.startsWith("civil") && it != "dataSource" })
                    if (z.total <= 0) continue
                    // a day has 1,440 minutes: more means the units were misread
                    if (z.total > 1440) { val f = 1440 / z.total; z = ZoneMinutes(z.fatBurn * f, z.cardio * f, z.peak * f) }
                    out += date to z
                }
            }
        }
        return out
    }

    /** Sleep sessions with their stages. */
    private suspend fun sleepSessions(from: LocalDate): List<SleepSession> {
        val filter = "sleep.interval.civil_end_time >= \"${from}T00:00:00\""
        return list("sleep", filter, 25, 24).mapNotNull { point ->
            val sleep = point["sleep"] as? Map<*, *> ?: return@mapNotNull null
            val interval = sleep["interval"] as? Map<*, *> ?: return@mapNotNull null
            val start = instant(interval["startTime"]) ?: return@mapNotNull null
            val end = instant(interval["endTime"]) ?: return@mapNotNull null
            val summary = sleep["summary"] as? Map<*, *> ?: emptyMap<String, Any?>()
            val stages = maps(sleep["stages"]).mapNotNull { st ->
                val s = instant(st["startTime"]) ?: return@mapNotNull null
                val e = instant(st["endTime"]) ?: return@mapNotNull null
                SleepStage(stageKind(st["type"] as? String), s, e)
            }.sortedBy { it.start }
            val awake = double(summary["minutesAwake"]) ?: stages.filter { it.kind == SleepStageKind.AWAKE }.sumOf { it.minutes }
            val asleep = double(summary["minutesAsleep"]) ?: maxOf(0.0, (end - start) / 60_000.0 - awake)
            SleepSession(start, end, asleep, awake, stages)
        }
    }

    /** Exercise sessions with Fitbit's summary (calories, average heart rate, distance). */
    private suspend fun workouts(from: LocalDate): List<Workout> {
        val filter = "exercise.interval.civil_start_time >= \"${from}T00:00:00\""
        return list("exercise", filter, 25, 12).mapNotNull { point ->
            val ex = point["exercise"] as? Map<*, *> ?: return@mapNotNull null
            val interval = ex["interval"] as? Map<*, *> ?: return@mapNotNull null
            val start = instant(interval["startTime"]) ?: return@mapNotNull null
            val end = instant(interval["endTime"]) ?: return@mapNotNull null
            if (end <= start) return@mapNotNull null
            val raw = (ex["exerciseType"] ?: ex["activityType"] ?: ex["type"] ?: ex["displayName"]) as? String ?: "WORKOUT"
            val summary = ex["metricsSummary"] as? Map<*, *> ?: emptyMap<String, Any?>()
            Workout(
                id = point["name"] as? String ?: "$raw-${start / 1000}",
                kind = prettyKind(raw),
                start = start,
                end = end,
                calories = double(summary["caloriesKcal"]),
                averageHeartRate = double(summary["averageHeartRateBeatsPerMinute"]),
                distanceKm = double(summary["distanceMillimeters"])?.let { it / 1_000_000 }?.takeIf { it > 0.05 },
            )
        }
    }

    /** "OUTDOOR_RUN" → "Outdoor run". */
    private fun prettyKind(raw: String): String =
        raw.replace('_', ' ').lowercase().replaceFirstChar { it.uppercase() }

    private suspend fun weightReadings(from: LocalDate): List<Pair<Long, Double>> {
        val filter = "weight.sample_time.physical_time >= \"${iso(HaloTime.startOf(from))}\""
        return list("weight", filter, 1000).mapNotNull { point ->
            val w = point["weight"] as? Map<*, *> ?: return@mapNotNull null
            val grams = double(w["weightGrams"]) ?: return@mapNotNull null
            val t = instant((w["sampleTime"] as? Map<*, *>)?.get("physicalTime")) ?: return@mapNotNull null
            t to grams / 1000
        }.sortedBy { it.first }
    }

    private suspend fun heartRate(since: Long): List<HeartSample> {
        val filter = "heart_rate.sample_time.physical_time >= \"${iso(since)}\""
        return list("heart-rate", filter, 10000, 60).mapNotNull { point ->
            val hr = point["heartRate"] as? Map<*, *> ?: return@mapNotNull null
            val bpm = double(hr["beatsPerMinute"]) ?: return@mapNotNull null
            val t = instant((hr["sampleTime"] as? Map<*, *>)?.get("physicalTime")) ?: return@mapNotNull null
            HeartSample(t, bpm)
        }
    }

    // ---- HTTP

    private suspend fun list(type: String, filter: String, pageSize: Int, maxPages: Int = 10): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        var pageToken: String? = null
        repeat(maxPages) {
            var url = "$base/$type/dataPoints?filter=${enc(filter)}&pageSize=$pageSize"
            pageToken?.let { url += "&pageToken=${enc(it)}" }
            val json = request(url, null)
            out += maps(json["dataPoints"])
            pageToken = (json["nextPageToken"] as? String)?.takeIf { it.isNotEmpty() } ?: return out
        }
        return out
    }

    /** POSTs `body` page after page, handing each page to `each`. */
    private suspend fun pages(url: String, body: JSONObject, each: (Map<String, Any?>) -> Unit) {
        for (i in 0 until 10) {
            val json = request(url, body)
            each(json)
            val next = (json["nextPageToken"] as? String)?.takeIf { it.isNotEmpty() } ?: break
            body.put("pageToken", next)
        }
    }

    private suspend fun request(url: String, body: JSONObject?): Map<String, Any?> {
        val token = token()
        return kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 20_000
            c.readTimeout = 60_000
            c.setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                c.requestMethod = "POST"
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/json")
                c.outputStream.use { it.write(body.toString().toByteArray()) }
            }
            val status = c.responseCode
            val text = (if (status in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            c.disconnect()
            val json = runCatching { toMap(JSONObject(text)) }.getOrDefault(emptyMap())
            if (status !in 200..299) {
                val message = ((json["error"] as? Map<*, *>)?.get("message") as? String) ?: "no details"
                throw ApiError(status, message)
            }
            json
        }
    }

    companion object {
        private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

        fun toMap(o: JSONObject): Map<String, Any?> = o.keys().asSequence().associateWith { toKotlin(o.opt(it)) }
        private fun toKotlin(v: Any?): Any? = when (v) {
            is JSONObject -> toMap(v)
            is JSONArray -> (0 until v.length()).map { toKotlin(v.opt(it)) }
            JSONObject.NULL -> null
            else -> v
        }

        @Suppress("UNCHECKED_CAST")
        fun maps(v: Any?): List<Map<String, Any?>> = (v as? List<*>)?.filterIsInstance<Map<*, *>>()?.map { it as Map<String, Any?> } ?: emptyList()

        /** The type's object inside a daily point (e.g. "dailyRestingHeartRate": {...}). */
        @Suppress("UNCHECKED_CAST")
        fun innerObject(point: Map<String, Any?>): Map<String, Any?>? =
            point.entries.firstOrNull { it.key != "dataSource" && (it.value as? Map<*, *>)?.get("date") != null }?.value as? Map<String, Any?>

        /** The object holding a rollup's values: the one named after the type, else the first that isn't a time or source. */
        @Suppress("UNCHECKED_CAST")
        fun valueObject(point: Map<String, Any?>, type: String): Map<String, Any?>? {
            (point[camelCase(type)] as? Map<String, Any?>)?.let { return it }
            return point.entries.firstOrNull {
                !it.key.startsWith("civil") && !it.key.endsWith("Time") && it.key != "dataSource" && it.value is Map<*, *>
            }?.value as? Map<String, Any?>
        }

        fun camelCase(kebab: String): String =
            kebab.split("-").mapIndexed { i, p -> if (i == 0) p else p.replaceFirstChar { it.uppercase() } }.joinToString("")

        fun chunks(from: LocalDate, to: LocalDate, days: Long): List<Pair<LocalDate, LocalDate>> {
            val out = mutableListOf<Pair<LocalDate, LocalDate>>()
            var start = from
            while (!start.isAfter(to)) {
                val end = minOf(to, start.plusDays(days - 1))
                out += start to end
                start = end.plusDays(1)
            }
            return out
        }

        /** Zone durations found anywhere inside a rollup point. */
        fun zones(obj: Any?): ZoneMinutes {
            var fat = 0.0; var cardio = 0.0; var peak = 0.0
            fun add(zone: String, minutes: Double) {
                val n = zone.lowercase()
                when {
                    "peak" in n -> peak += minutes
                    "cardio" in n || "vigorous" in n -> cardio += minutes
                    "fat" in n || "moderate" in n -> fat += minutes
                }
            }
            fun walk(v: Any?) {
                if (v is List<*>) { v.forEach { walk(it) }; return }
                val o = v as? Map<*, *> ?: return
                // {zone: "CARDIO", duration: "600s"}
                val label = o.values.filterIsInstance<String>().firstOrNull { isZoneName(it) }
                val m = o.entries.firstNotNullOfOrNull { minutes(it.key.toString(), it.value) }
                if (label != null && m != null) { add(label, m); return }
                for ((k, value) in o) {
                    val key = k.toString()
                    // {cardioDuration: "600s"} or {peakMinutes: 4}
                    val km = if (isZoneName(key)) minutes(key, value, keyless = true) else null
                    if (km != null) add(key, km) else walk(value)
                }
            }
            walk(obj)
            return ZoneMinutes(fat, cardio, peak)
        }

        fun isZoneName(s: String): Boolean = s.lowercase().let { l -> listOf("fat", "cardio", "peak", "moderate", "vigorous").any { it in l } }

        /** A duration in minutes: "600s", {"seconds": 600}, or a number whose key names the unit. */
        fun minutes(key: String, value: Any?, keyless: Boolean = false): Double? {
            val k = key.lowercase()
            val isDuration = keyless || listOf("duration", "minute", "second", "milli", "time").any { it in k }
            if (!isDuration) return null
            if (value is String && value.endsWith("s")) value.dropLast(1).toDoubleOrNull()?.let { return it / 60 }
            if (value is Map<*, *>) double(value["seconds"])?.let { return it / 60 }
            val n = double(value) ?: return null
            return when {
                "milli" in k -> n / 60_000
                "minute" in k -> n
                "second" in k || "duration" in k -> n / 60
                else -> if (n > 1440) n / 60 else n
            }
        }

        /** The first number in an object, preferring keys containing one of `prefer`; with `strict`, only those. */
        fun number(obj: Map<*, *>, prefer: List<String>, strict: Boolean = false): Double? {
            val found = mutableListOf<Pair<String, Double>>()
            fun walk(o: Map<*, *>, path: String) {
                for ((k, v) in o) {
                    val key = k.toString()
                    if (key in listOf("date", "year", "month", "day", "dataSource")) continue
                    val n = double(v)
                    if (n != null) found += (path + key.lowercase()) to n
                    else if (v is Map<*, *>) walk(v, path + key.lowercase() + ".")
                }
            }
            walk(obj, "")
            found.sortBy { it.first }
            for (p in prefer) found.firstOrNull { p in it.first }?.let { return it.second }
            return if (strict) null else found.firstOrNull()?.second
        }

        fun double(v: Any?): Double? = when (v) {
            is Number -> v.toDouble()
            is String -> v.toDoubleOrNull()
            else -> null
        }

        fun stageKind(raw: String?): SleepStageKind {
            val s = raw?.uppercase() ?: ""
            return when {
                "DEEP" in s -> SleepStageKind.DEEP
                "REM" in s -> SleepStageKind.REM
                "AWAKE" in s || "WAKE" in s || "RESTLESS" in s -> SleepStageKind.AWAKE
                else -> SleepStageKind.LIGHT
            }
        }

        fun iso(millis: Long): String = DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(millis / 1000 * 1000))

        fun instant(v: Any?): Long? {
            val s = v as? String ?: return null
            return runCatching { OffsetDateTime.parse(s).toInstant().toEpochMilli() }.getOrNull()
                ?: runCatching { Instant.parse(s).toEpochMilli() }.getOrNull()
        }

        fun civilObject(d: LocalDate): JSONObject =
            JSONObject().put("date", JSONObject().put("year", d.year).put("month", d.monthValue).put("day", d.dayOfMonth))

        fun dateFromCivil(v: Any?): LocalDate? {
            val d = v as? Map<*, *> ?: return null
            val y = double(d["year"]) ?: return null
            val m = double(d["month"]) ?: return null
            val day = double(d["day"]) ?: return null
            return runCatching { LocalDate.of(y.toInt(), m.toInt(), day.toInt()) }.getOrNull()
        }
    }
}
