import Foundation

/// Reads Whoop data through the Whoop developer API (v2).
/// Reference: https://developer.whoop.com/api
///
/// What Whoop shares: each morning's recovery (HRV as RMSSD, like Fitbit; resting heart rate, SpO₂,
/// skin temperature), sleep with stage totals but no minute-by-minute stages, and workouts with
/// time in each heart-rate zone. No steps and no heart rate outside workouts, so Effort counts heart
/// zones alone and cardio load comes from the workouts' zones.
struct WhoopClient: HealthSource {
    let token: () async throws -> String
    private let base = "https://api.prod.whoop.com/developer/v2"

    enum APIError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let message): return "Whoop API error \(code): \(message)"
            }
        }
    }

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

        // Sleep starts the evening before, so ask from a day earlier.
        async let sleeps = attempt { try await records("activity/sleep", from: from.addingTimeInterval(-86_400)) }
        async let recoveries = attempt { try await records("recovery", from: from) }
        async let exercises = attempt { try await records("activity/workout", from: cal.date(byAdding: .day, value: -60, to: today) ?? from) }
        async let body = attempt { [try await object("user/measurement/body")] }

        // Sleep belongs to the day you woke up on. Naps are left out; the main sleep is what's scored.
        var wokeOn: [String: Date] = [:]
        let sleepResult = await sleeps
        for record in take("Sleep", sleepResult, unit: "nights") {
            guard record["nap"] as? Bool != true, let session = Self.sleep(record) else { continue }
            if let id = Self.string(record["id"]) { wokeOn[id] = session.end }
            let score = record["score"] as? [String: Any]
            edit(session.end) { d in
                if (d.sleep?.minutesAsleep ?? 0) < session.minutesAsleep {
                    d.sleep = session
                    d.respiratoryRate = Self.double(score?["respiratory_rate"])
                }
            }
        }

        // Recovery: the morning's HRV, resting heart rate, SpO₂ and skin temperature.
        var temps: [(Date, Double)] = []
        for record in take("Recovery", await recoveries) {
            guard record["score_state"] as? String == "SCORED", let score = record["score"] as? [String: Any],
                  let day = Self.string(record["sleep_id"]).flatMap({ wokeOn[$0] }) ?? Self.date(record["created_at"])
            else { continue }
            edit(day) { d in
                d.hrv = Self.double(score["hrv_rmssd_milli"])
                d.restingHeartRate = Self.double(score["resting_heart_rate"])
                d.spo2 = Self.double(score["spo2_percentage"])
            }
            if let t = Self.double(score["skin_temp_celsius"]) { temps.append((day, t)) }
        }
        for (day, delta) in Self.changeFromUsual(temps) { edit(day) { $0.skinTempDelta = delta } }

        // Workouts, with their time in each zone. Whoop's zones are shares of your maximum heart
        // rate; in Halo's terms (shares of heart-rate reserve) zone 2 is fat burn, 3 and 4 are cardio,
        // 5 is peak. Zone 1 is below Halo's zones.
        for record in take("Workouts", await exercises, unit: "sessions") {
            guard let w = Self.workout(record) else { continue }
            let zones = (record["score"] as? [String: Any])?["zone_durations"] as? [String: Any]
            func minutes(_ key: String) -> Double { (Self.double(zones?[key]) ?? 0) / 60_000 }
            edit(w.start) { d in
                var list = d.workouts ?? []
                guard !list.contains(where: { $0.id == w.id }) else { return }
                list.append(w)
                d.workouts = list.sorted { $0.start < $1.start }
                if zones != nil {
                    var z = d.zoneMinutes ?? ZoneMinutes()
                    z.fatBurn += minutes("zone_two_milli")
                    z.cardio += minutes("zone_three_milli") + minutes("zone_four_milli")
                    z.peak += minutes("zone_five_milli")
                    d.zoneMinutes = z
                }
                // Whoop only counts calories as a whole day, so active calories are the workouts'.
                if let kcal = w.calories { d.activeCalories = (d.activeCalories ?? 0) + kcal }
            }
        }

        for record in take("Weight", await body, unit: "reading") {
            if let kg = Self.double(record["weight_kilogram"]) { edit(today) { $0.weightKg = kg } }
        }

        if let line = Self.todayLine(days[today]) { report.append(line) }
        if case .failure(let error) = sleepResult { throw error }
        return (days.values.sorted { $0.date < $1.date }, report)
    }

    // MARK: Parsing

    private static func sleep(_ r: [String: Any]) -> SleepSession? {
        guard r["score_state"] as? String == "SCORED",
              let start = date(r["start"]), let end = date(r["end"]),
              let stages = ((r["score"] as? [String: Any])?["stage_summary"]) as? [String: Any] else { return nil }
        func minutes(_ key: String) -> Double { (double(stages[key]) ?? 0) / 60_000 }
        let light = minutes("total_light_sleep_time_milli")
        let deep = minutes("total_slow_wave_sleep_time_milli")
        let rem = minutes("total_rem_sleep_time_milli")
        let awake = minutes("total_awake_time_milli")
        guard light + deep + rem > 0 else { return nil }
        var s = SleepSession(start: start, end: end, minutesAsleep: light + deep + rem, minutesAwake: awake, stages: [])
        s.stageTotals = [.light: light, .deep: deep, .rem: rem, .awake: awake]
        return s
    }

    private static func workout(_ r: [String: Any]) -> Workout? {
        guard let id = string(r["id"]), let start = date(r["start"]), let end = date(r["end"]) else { return nil }
        let score = r["score"] as? [String: Any]
        return Workout(id: "whoop-\(id)",
                       kind: (r["sport_name"] as? String) ?? "workout",
                       start: start, end: end,
                       calories: double(score?["kilojoule"]).map { $0 / 4.184 },
                       averageHeartRate: double(score?["average_heart_rate"]),
                       distanceKm: double(score?["distance_meter"]).map { $0 / 1000 })
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    // MARK: HTTP

    /// Every record of a collection since `from`, following the pages.
    private func records(_ path: String, from: Date) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var next: String?
        for _ in 0..<40 {
            var comps = URLComponents(string: "\(base)/\(path)")!
            comps.queryItems = [.init(name: "start", value: Self.plain.string(from: from)), .init(name: "limit", value: "25")]
            if let next { comps.queryItems?.append(.init(name: "nextToken", value: next)) }
            let json = try await get(comps.url!)
            out += json["records"] as? [[String: Any]] ?? []
            next = json["next_token"] as? String
            if next?.isEmpty ?? true { break }
        }
        return out
    }

    private func object(_ path: String) async throws -> [String: Any] {
        try await get(URL(string: "\(base)/\(path)")!)
    }

    private func get(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw APIError.http(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
