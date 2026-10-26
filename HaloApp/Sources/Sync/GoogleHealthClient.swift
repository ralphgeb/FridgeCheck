import Foundation

/// Reads Fitbit data through the Google Health API (v4), which replaced the Fitbit Web API in 2026.
/// Reference: https://developers.google.com/health
///
/// Responses are parsed loosely ([String: Any]) on purpose: the API is new and adds fields often,
/// and several daily types name their value differently.
struct GoogleHealthClient: HealthSource {
    let token: () async throws -> String
    private let base = "https://health.googleapis.com/v4/users/me/dataTypes"

    enum APIError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let message): return "Google Health API error \(code): \(message)"
            }
        }
    }

    // MARK: Fetch everything Halo shows

    func fetchDays(_ count: Int, maxHeartRate: Double) async throws -> (days: [DayMetrics], report: [SyncReportLine]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let from = cal.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        var days: [Date: DayMetrics] = [:]
        var report: [SyncReportLine] = []
        func edit(_ date: Date, _ change: (inout DayMetrics) -> Void) {
            let key = cal.startOfDay(for: date)
            guard key >= from else { return }
            var d = days[key] ?? DayMetrics(date: key)
            change(&d)
            days[key] = d
        }
        func take<T>(_ name: String, _ result: Result<[T], Error>, unit: String = "days") -> [T] {
            Self.take(name, result, unit: unit, into: &report)
        }

        // Everything runs at once.
        async let rhr = attempt { try await dailyValues("daily-resting-heart-rate", from: from) }
        async let hrv = attempt { try await dailyValues("daily-heart-rate-variability", from: from, prefer: ["rmssd", "average", "milli"]) }
        async let spo2 = attempt { try await dailyValues("daily-oxygen-saturation", from: from, prefer: ["average", "percentage"]) }
        async let resp = attempt { try await dailyValues("daily-respiratory-rate", from: from, prefer: ["breath", "average", "rate"]) }
        async let temp = attempt { try await dailyValues("daily-sleep-temperature-derivations", from: from,
                                                         prefer: ["relative", "deviation", "delta", "difference"], strict: true) }
        async let vo2 = attempt { try await dailyValues("daily-vo2-max", from: from) }
        async let steps = attempt { try await dailyTotals("steps", from: from, to: today, prefer: ["count"]) }
        async let azm = attempt { try await rollUp("active-zone-minutes", from: from, to: today) }
        async let zones = attempt { try await zoneMinutes(from: from, to: today) }
        async let kcal = attempt { try await dailyTotals("active-energy-burned", from: from, to: today, prefer: ["kcal", "calorie"]) }
        async let sleeps = attempt { try await sleepSessions(from: from) }
        async let weights = attempt { try await weightReadings(from: from) }
        async let exercises = attempt { try await workouts(from: cal.date(byAdding: .day, value: -60, to: today) ?? from) }
        async let heart = attempt { try await heartRate(since: cal.date(byAdding: .day, value: -2, to: today) ?? today) }

        for (date, v) in take("Steps", await steps) { edit(date) { $0.steps = Int(v.rounded()) } }
        for (date, z) in take("Heart-rate zones", await zones) { edit(date) { $0.zoneMinutes = z } }
        for (date, v) in take("Active Zone Minutes", await azm) { edit(date) { $0.activeZoneMinutes = v } }
        for (date, v) in take("Active calories", await kcal) { edit(date) { $0.activeCalories = v } }
        for (date, v) in take("Resting heart rate", await rhr) { edit(date) { $0.restingHeartRate = v } }
        for (date, v) in take("HRV", await hrv) { edit(date) { $0.hrv = v } }
        for (date, v) in take("Blood oxygen", await spo2) { edit(date) { $0.spo2 = v } }
        for (date, v) in take("Breathing rate", await resp) { edit(date) { $0.respiratoryRate = v } }
        for (date, v) in take("Skin temperature", await temp) { edit(date) { $0.skinTempDelta = v } }
        for (date, v) in take("Cardio fitness", await vo2) { edit(date) { $0.vo2Max = v } }
        for (date, kg) in take("Weight", await weights, unit: "readings") { edit(date) { $0.weightKg = kg } }
        // Sleep belongs to the day you woke up on. If there are several (naps), keep the longest.
        let sleepResult = await sleeps
        for s in take("Sleep", sleepResult, unit: "nights") {
            edit(s.end) { d in
                if (d.sleep?.minutesAsleep ?? 0) < s.minutesAsleep { d.sleep = s }
            }
        }
        for w in take("Workouts", await exercises, unit: "sessions") {
            edit(w.start) { d in
                var list = d.workouts ?? []
                if !list.contains(where: { $0.id == w.id }) { list.append(w) }
                d.workouts = list.sorted { $0.start < $1.start }
            }
        }
        // Heart rate: work out each day's load and zone minutes from every reading, then keep
        // 5-minute averages for the charts.
        let readings = take("Heart rate", await heart, unit: "readings")
        Self.applyHeartRate(readings, to: &days, from: from, keepSamplesFrom: from, maxHeartRate: maxHeartRate)
        // What today looks like, to check against the Fitbit app.
        if let line = Self.todayLine(days[today]) { report.append(line) }
        // Without sleep there's nothing to score, so that one is worth failing the sync for.
        if case .failure(let error) = sleepResult { throw error }

        return (days.values.sorted { $0.date < $1.date }, report)
    }

    // MARK: Data types

    /// Daily summary types: each data point holds a civil "date" and one number.
    private func dailyValues(_ type: String, from: Date, prefer: [String] = [], strict: Bool = false) async throws -> [(Date, Double)] {
        let filter = "\(snake(type)).date >= \"\(Self.civil(from))\""
        return try await list(type, filter: filter, pageSize: 1000).compactMap { point in
            guard let inner = Self.innerObject(point),
                  let date = Self.date(fromCivil: inner["date"]),
                  let value = Self.number(in: inner, prefer: prefer, strict: strict) else { return nil }
            return (date, value)
        }
    }

    /// Daily totals for interval types (steps, calories). Asks for civil-day totals first and falls back
    /// to 24-hour windows if that comes back empty or fails.
    private func dailyTotals(_ type: String, from: Date, to: Date, prefer: [String]) async throws -> [(Date, Double)] {
        do {
            let civil = try await rollUp(type, from: from, to: to, prefer: prefer)
            if !civil.isEmpty { return civil }
        } catch {
            if let fallback = try? await physicalRollUp(type, from: from, to: to, prefer: prefer), !fallback.isEmpty { return fallback }
            throw error
        }
        return try await physicalRollUp(type, from: from, to: to, prefer: prefer)
    }

    /// Daily totals by civil day, a month at a time (the API caps a request at 90 days).
    private func rollUp(_ type: String, from: Date, to: Date, prefer: [String] = []) async throws -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        var firstError: Error?
        for (start, end) in Self.chunks(from: from, to: to, days: 30) {
            do {
                out += try await rollUpChunk(type, from: start, to: end, prefer: prefer)
            } catch {
                firstError = firstError ?? error
            }
        }
        if out.isEmpty, let firstError { throw firstError }
        return out
    }

    private func rollUpChunk(_ type: String, from: Date, to: Date, prefer: [String]) async throws -> [(Date, Double)] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: to) ?? to
        var body: [String: Any] = [
            "range": ["start": Self.civilObject(from), "end": Self.civilObject(end)],
            "windowSizeDays": 1,
        ]
        var out: [(Date, Double)] = []
        for _ in 0..<10 {
            let json = try await request("\(base)/\(type)/dataPoints:dailyRollUp", body: body)
            for point in json["rollupDataPoints"] as? [[String: Any]] ?? [] {
                let start = point["civilStartTime"] as? [String: Any]
                guard let date = Self.date(fromCivil: start?["date"]),
                      let inner = Self.valueObject(point, type: type),
                      let value = Self.number(in: inner, prefer: prefer + ["sum"]) else { continue }
                out.append((date, value))
            }
            guard let next = json["nextPageToken"] as? String, !next.isEmpty else { break }
            body["pageToken"] = next
        }
        return out
    }

    /// Daily totals over 24-hour windows starting at local midnight.
    private func physicalRollUp(_ type: String, from: Date, to: Date, prefer: [String]) async throws -> [(Date, Double)] {
        let cal = Calendar.current
        var out: [(Date, Double)] = []
        for (start, last) in Self.chunks(from: from, to: to, days: 30) {
            let end = cal.date(byAdding: .day, value: 1, to: last) ?? last
            var body: [String: Any] = [
                "range": ["startTime": Self.iso.string(from: start), "endTime": Self.iso.string(from: end)],
                "windowSize": "86400s",
            ]
            for _ in 0..<10 {
                let json = try await request("\(base)/\(type)/dataPoints:rollUp", body: body)
                for point in json["rollupDataPoints"] as? [[String: Any]] ?? [] {
                    // an hour in, so a daylight-saving shift can't push the window into the day before
                    guard let t = Self.instant(point["startTime"]),
                          let inner = Self.valueObject(point, type: type),
                          let value = Self.number(in: inner, prefer: prefer + ["sum"]) else { continue }
                    out.append((cal.startOfDay(for: t.addingTimeInterval(3600)), value))
                }
                guard let next = json["nextPageToken"] as? String, !next.isEmpty else { break }
                body["pageToken"] = next
            }
        }
        return out
    }

    /// Minutes in each heart-rate zone per day. The response is read loosely: zones may come as a list
    /// of {zone, duration} entries or as fields named after the zone.
    private func zoneMinutes(from: Date, to: Date) async throws -> [(Date, ZoneMinutes)] {
        var out: [(Date, ZoneMinutes)] = []
        for (start, last) in Self.chunks(from: from, to: to, days: 30) {
            let end = Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last
            var body: [String: Any] = [
                "range": ["start": Self.civilObject(start), "end": Self.civilObject(end)],
                "windowSizeDays": 1,
            ]
            for _ in 0..<10 {
                let json = try await request("\(base)/time-in-heart-rate-zone/dataPoints:dailyRollUp", body: body)
                for point in json["rollupDataPoints"] as? [[String: Any]] ?? [] {
                    let civil = point["civilStartTime"] as? [String: Any]
                    guard let date = Self.date(fromCivil: civil?["date"]) else { continue }
                    var z = Self.zones(in: point.filter { !$0.key.hasPrefix("civil") && $0.key != "dataSource" })
                    // a day has 1,440 minutes: anything more means the units were misread
                    guard z.total > 0 else { continue }
                    if z.total > 1_440 { let f = 1_440 / z.total; z.fatBurn *= f; z.cardio *= f; z.peak *= f }
                    out.append((date, z))
                }
                guard let next = json["nextPageToken"] as? String, !next.isEmpty else { break }
                body["pageToken"] = next
            }
        }
        return out
    }

    /// Main sleep sessions with their stages.
    private func sleepSessions(from: Date) async throws -> [SleepSession] {
        // The API only filters sleep by end time, and caps pages at 25.
        let filter = "sleep.interval.civil_end_time >= \"\(Self.civil(from))T00:00:00\""
        return try await list("sleep", filter: filter, pageSize: 25, maxPages: 24).compactMap { point in
            guard let sleep = point["sleep"] as? [String: Any],
                  let interval = sleep["interval"] as? [String: Any],
                  let start = Self.instant(interval["startTime"]),
                  let end = Self.instant(interval["endTime"]) else { return nil }
            let summary = sleep["summary"] as? [String: Any] ?? [:]
            let stages: [SleepStage] = (sleep["stages"] as? [[String: Any]] ?? []).compactMap { st in
                guard let s = Self.instant(st["startTime"]), let e = Self.instant(st["endTime"]) else { return nil }
                return SleepStage(kind: Self.stageKind(st["type"] as? String), start: s, end: e)
            }
            .sorted { $0.start < $1.start }
            let awake = Self.double(summary["minutesAwake"])
                ?? stages.filter { $0.kind == .awake }.reduce(0) { $0 + $1.minutes }
            let asleep = Self.double(summary["minutesAsleep"])
                ?? max(0, end.timeIntervalSince(start) / 60 - awake)
            return SleepSession(start: start, end: end, minutesAsleep: asleep, minutesAwake: awake, stages: stages)
        }
    }

    /// Exercise sessions: type, start and end, and the summary Fitbit keeps (calories, average heart
    /// rate, distance). Read loosely, since the fields vary by activity.
    private func workouts(from: Date) async throws -> [Workout] {
        let filter = "exercise.interval.civil_start_time >= \"\(Self.civil(from))T00:00:00\""
        return try await list("exercise", filter: filter, pageSize: 25, maxPages: 12).compactMap { point in
            guard let ex = point["exercise"] as? [String: Any],
                  let interval = ex["interval"] as? [String: Any],
                  let start = Self.instant(interval["startTime"]),
                  let end = Self.instant(interval["endTime"]), end > start else { return nil }
            let kind = (ex["exerciseType"] ?? ex["activityType"] ?? ex["type"] ?? ex["displayName"]) as? String ?? "WORKOUT"
            let summary = ex["metricsSummary"] as? [String: Any] ?? [:]
            let id = point["name"] as? String ?? "\(kind)-\(Int(start.timeIntervalSince1970))"
            return Workout(id: id, kind: kind, start: start, end: end,
                           calories: Self.double(summary["caloriesKcal"]),
                           averageHeartRate: Self.double(summary["averageHeartRateBeatsPerMinute"]),
                           distanceKm: Self.double(summary["distanceMillimeters"]).map { $0 / 1_000_000 })
        }
    }

    /// Scale readings in kilograms, one per day (the last of the day wins).
    private func weightReadings(from: Date) async throws -> [(Date, Double)] {
        let filter = "weight.sample_time.physical_time >= \"\(Self.iso.string(from: from))\""
        return try await list("weight", filter: filter, pageSize: 1000).compactMap { point in
            guard let w = point["weight"] as? [String: Any],
                  let grams = Self.double(w["weightGrams"]),
                  let time = Self.instant((w["sampleTime"] as? [String: Any])?["physicalTime"]) else { return nil }
            return (time, grams / 1000)
        }
    }

    /// Every heart-rate reading since a time.
    private func heartRate(since: Date) async throws -> [HeartSample] {
        let filter = "heart_rate.sample_time.physical_time >= \"\(Self.iso.string(from: since))\""
        return try await list("heart-rate", filter: filter, pageSize: 10000, maxPages: 12).compactMap { point in
            guard let hr = point["heartRate"] as? [String: Any],
                  let bpm = Self.double(hr["beatsPerMinute"]),
                  let time = Self.instant((hr["sampleTime"] as? [String: Any])?["physicalTime"]) else { return nil }
            return HeartSample(time: time, bpm: bpm)
        }
    }

    // MARK: HTTP

    private func list(_ type: String, filter: String, pageSize: Int, maxPages: Int = 10) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pageToken: String?
        for _ in 0..<maxPages {
            var comps = URLComponents(string: "\(base)/\(type)/dataPoints")!
            comps.queryItems = [.init(name: "filter", value: filter), .init(name: "pageSize", value: String(pageSize))]
            if let pageToken { comps.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let json = try await request(comps.url!.absoluteString, body: nil)
            out += json["dataPoints"] as? [[String: Any]] ?? []
            guard let next = json["nextPageToken"] as? String, !next.isEmpty else { break }
            pageToken = next
        }
        return out
    }

    private func request(_ url: String, body: [String: Any]?) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "no details"
            throw APIError.http(status, message)
        }
        return json
    }

    // MARK: Parsing helpers

    private func snake(_ kebab: String) -> String { kebab.replacingOccurrences(of: "-", with: "_") }

    /// The type-specific object inside a data point (e.g. "dailyRestingHeartRate": {...}).
    static func innerObject(_ point: [String: Any]) -> [String: Any]? {
        point.first(where: { $0.key != "dataSource" && $0.value is [String: Any] && (($0.value as? [String: Any])?["date"] != nil) })?.value as? [String: Any]
    }

    /// The object holding a rollup's values: the one named after the type ("steps", "activeEnergyBurned"),
    /// or else the first object that isn't a time or a data source.
    static func valueObject(_ point: [String: Any], type: String) -> [String: Any]? {
        let camel = camelCase(type)
        if let named = point[camel] as? [String: Any] { return named }
        return point.first(where: { !$0.key.hasPrefix("civil") && !$0.key.hasSuffix("Time") && $0.key != "dataSource" && $0.value is [String: Any] })?.value as? [String: Any]
    }

    static func camelCase(_ kebab: String) -> String {
        let parts = kebab.split(separator: "-")
        return parts.enumerated().map { i, p in i == 0 ? String(p) : p.prefix(1).uppercased() + p.dropFirst() }.joined()
    }

    static func chunks(from: Date, to: Date, days: Int) -> [(Date, Date)] {
        let cal = Calendar.current
        var out: [(Date, Date)] = []
        var start = from
        while start <= to {
            let end = min(to, cal.date(byAdding: .day, value: days - 1, to: start) ?? to)
            out.append((start, end))
            guard let next = cal.date(byAdding: .day, value: 1, to: end) else { break }
            start = next
        }
        return out
    }

    /// Finds zone durations anywhere inside a rollup point.
    static func zones(in obj: Any) -> ZoneMinutes {
        var z = ZoneMinutes()
        func add(_ zone: String, _ minutes: Double) {
            let name = zone.lowercased()
            // Fitbit's names (fat burn, cardio, peak) or generic ones (moderate, vigorous, peak).
            // "Light" or "out of zone" time isn't a zone and doesn't count.
            if name.contains("peak") { z.peak += minutes }
            else if name.contains("cardio") || name.contains("vigorous") { z.cardio += minutes }
            else if name.contains("fat") || name.contains("moderate") { z.fatBurn += minutes }
        }
        func walk(_ v: Any) {
            if let list = v as? [Any] { list.forEach(walk); return }
            guard let o = v as? [String: Any] else { return }
            // {zone: "CARDIO", duration: "600s"}
            if let label = o.values.compactMap({ $0 as? String }).first(where: { Self.isZoneName($0) }),
               let minutes = o.compactMap({ Self.minutes(key: $0.key, value: $0.value) }).first {
                add(label, minutes)
                return
            }
            for (k, value) in o {
                // {cardioDuration: "600s"} or {peakMinutes: 4}
                if Self.isZoneName(k), let minutes = Self.minutes(key: k, value: value, keyless: true) { add(k, minutes) }
                else { walk(value) }
            }
        }
        walk(obj)
        return z
    }

    static func isZoneName(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["fat", "cardio", "peak", "moderate", "vigorous"].contains { l.contains($0) }
    }

    /// A duration in minutes from a key/value pair: "600s", {"seconds": 600}, or a number whose key names the unit.
    static func minutes(key: String, value: Any, keyless: Bool = false) -> Double? {
        let k = key.lowercased()
        let isDurationKey = keyless || ["duration", "minute", "second", "milli", "time"].contains { k.contains($0) }
        guard isDurationKey else { return nil }
        if let s = value as? String, s.hasSuffix("s"), let secs = Double(s.dropLast()) { return secs / 60 }
        if let o = value as? [String: Any], let secs = double(o["seconds"]) { return secs / 60 }
        guard let n = double(value) else { return nil }
        if k.contains("milli") { return n / 60_000 }
        if k.contains("minute") { return n }
        // durations are seconds unless the key says otherwise
        if k.contains("second") || k.contains("duration") { return n / 60 }
        return n > 1_440 ? n / 60 : n
    }

    /// The first number in an object, preferring keys that contain one of `prefer`.
    /// With `strict`, only a preferred key counts (so we never mistake an absolute value for a delta).
    static func number(in obj: [String: Any], prefer: [String], strict: Bool = false) -> Double? {
        var found: [(key: String, value: Double)] = []
        func walk(_ o: [String: Any], path: String) {
            for (k, v) in o where !["date", "year", "month", "day", "dataSource"].contains(k) {
                if let n = double(v) { found.append((key: path + k.lowercased(), value: n)) }
                else if let sub = v as? [String: Any] { walk(sub, path: path + k.lowercased() + ".") }
            }
        }
        walk(obj, path: "")
        found.sort { $0.key < $1.key }
        for p in prefer {
            if let hit = found.first(where: { $0.key.contains(p) }) { return hit.value }
        }
        return strict ? nil : found.first?.value
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func stageKind(_ raw: String?) -> SleepStageKind {
        switch raw?.uppercased() ?? "" {
        case let s where s.contains("DEEP"): return .deep
        case let s where s.contains("REM"): return .rem
        case let s where s.contains("AWAKE") || s.contains("WAKE") || s.contains("RESTLESS"): return .awake
        default: return .light     // LIGHT, ASLEEP (classic sleep logs)
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func instant(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }

    static func civil(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func civilObject(_ d: Date) -> [String: Any] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return ["date": ["year": c.year ?? 0, "month": c.month ?? 0, "day": c.day ?? 0]]
    }

    static func date(fromCivil v: Any?) -> Date? {
        guard let d = v as? [String: Any],
              let y = double(d["year"]), let m = double(d["month"]), let day = double(d["day"]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: Int(y), month: Int(m), day: Int(day)))
    }
}
