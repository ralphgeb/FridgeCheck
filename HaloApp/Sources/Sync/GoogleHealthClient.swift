import Foundation

/// Reads Fitbit data through the Google Health API (v4), which replaced the Fitbit Web API in 2026.
/// Reference: https://developers.google.com/health
///
/// Responses are parsed loosely ([String: Any]) on purpose: the API is new and adds fields often,
/// and several daily types name their value differently.
struct GoogleHealthClient {
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

    func fetchDays(_ count: Int) async throws -> [DayMetrics] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let from = cal.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        var days: [Date: DayMetrics] = [:]
        func edit(_ date: Date, _ change: (inout DayMetrics) -> Void) {
            let key = cal.startOfDay(for: date)
            guard key >= from else { return }
            var d = days[key] ?? DayMetrics(date: key)
            change(&d)
            days[key] = d
        }

        // Daily summaries, one value per day. Run them all at once.
        async let rhr = dailyValues("daily-resting-heart-rate", from: from)
        async let hrv = dailyValues("daily-heart-rate-variability", from: from, prefer: ["rmssd", "average", "milli"])
        async let spo2 = dailyValues("daily-oxygen-saturation", from: from, prefer: ["average", "percentage"])
        async let resp = dailyValues("daily-respiratory-rate", from: from, prefer: ["breath", "average", "rate"])
        async let temp = dailyValues("daily-sleep-temperature-derivations", from: from,
                                     prefer: ["relative", "deviation", "delta", "difference"], strict: true)
        async let vo2 = dailyValues("daily-vo2-max", from: from)
        async let steps = rollUp("steps", from: from, to: today)
        async let azm = rollUp("active-zone-minutes", from: from, to: today)
        async let kcal = rollUp("active-energy-burned", from: from, to: today)
        async let sleeps = sleepSessions(from: from)
        async let heart = heartRate(since: cal.date(byAdding: .day, value: -1, to: today) ?? today)

        // A missing type (not supported by the device, or no data) shouldn't break the others.
        for (date, v) in (try? await rhr) ?? [] { edit(date) { $0.restingHeartRate = v } }
        for (date, v) in (try? await hrv) ?? [] { edit(date) { $0.hrv = v } }
        for (date, v) in (try? await spo2) ?? [] { edit(date) { $0.spo2 = v } }
        for (date, v) in (try? await resp) ?? [] { edit(date) { $0.respiratoryRate = v } }
        for (date, v) in (try? await temp) ?? [] { edit(date) { $0.skinTempDelta = v } }
        for (date, v) in (try? await vo2) ?? [] { edit(date) { $0.vo2Max = v } }
        for (date, v) in (try? await steps) ?? [] { edit(date) { $0.steps = Int(v) } }
        for (date, v) in (try? await azm) ?? [] { edit(date) { $0.activeZoneMinutes = v } }
        for (date, v) in (try? await kcal) ?? [] { edit(date) { $0.activeCalories = v } }
        // Sleep belongs to the day you woke up on. If there are several (naps), keep the longest.
        for s in try await sleeps {
            edit(s.end) { d in
                if (d.sleep?.minutesAsleep ?? 0) < s.minutesAsleep { d.sleep = s }
            }
        }
        for sample in (try? await heart) ?? [] {
            edit(sample.time) { $0.heartRate.append(sample) }
        }

        return days.values.sorted { $0.date < $1.date }
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

    /// Daily totals for interval types (steps, Active Zone Minutes, calories).
    private func rollUp(_ type: String, from: Date, to: Date) async throws -> [(Date, Double)] {
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
                      let inner = point.first(where: { !$0.key.hasPrefix("civil") && $0.value is [String: Any] })?.value as? [String: Any],
                      let value = Self.number(in: inner, prefer: ["sum"]) else { continue }
                out.append((date, value))
            }
            guard let next = json["nextPageToken"] as? String, !next.isEmpty else { break }
            body["pageToken"] = next
        }
        return out
    }

    /// Main sleep sessions with their stages.
    private func sleepSessions(from: Date) async throws -> [SleepSession] {
        // The API only filters sleep by end time, and caps pages at 25.
        let filter = "sleep.interval.civil_end_time >= \"\(Self.civil(from))T00:00:00\""
        return try await list("sleep", filter: filter, pageSize: 25).compactMap { point in
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

    /// Heart rate readings, averaged into 5-minute buckets so charts stay light.
    private func heartRate(since: Date) async throws -> [HeartSample] {
        let filter = "heart_rate.sample_time.physical_time >= \"\(Self.iso.string(from: since))\""
        let raw: [HeartSample] = try await list("heart-rate", filter: filter, pageSize: 10000, maxPages: 6).compactMap { point in
            guard let hr = point["heartRate"] as? [String: Any],
                  let bpm = Self.double(hr["beatsPerMinute"]),
                  let time = Self.instant((hr["sampleTime"] as? [String: Any])?["physicalTime"]) else { return nil }
            return HeartSample(time: time, bpm: bpm)
        }
        let buckets = Dictionary(grouping: raw) { Int($0.time.timeIntervalSince1970 / 300) }
        return buckets.map { key, values in
            HeartSample(time: Date(timeIntervalSince1970: Double(key) * 300),
                        bpm: (values.reduce(0) { $0 + $1.bpm } / Double(values.count)).rounded())
        }
        .sorted { $0.time < $1.time }
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
