import Foundation

/// Reads Whoop data through the Whoop developer API (v2).
/// Reference: https://developer.whoop.com/api
///
/// Whoop doesn't count in calendar days. Its "day" is a physiological cycle that starts when you
/// fall asleep and ends when you next fall asleep, so it's rarely 24 hours. Recovery, the night's
/// sleep, strain and calories all belong to a cycle. Halo files each cycle under the calendar day
/// you woke up on (the day its sleep ended), which is the day Halo already gives a night's sleep:
///
///   Mon 23:10 fall asleep ─ cycle starts ─ Tue 06:45 wake (recovery) ─ … ─ Tue 23:30 fall asleep
///   └──────────────────────────── Halo's Tuesday ───────────────────────────┘
///
/// So a workout at 00:30 before you've slept stays on the day it belongs to (as in the Whoop app),
/// and a cycle's calories are measured over the cycle's own length.
///
/// What Whoop shares: each morning's recovery (HRV as RMSSD, like Fitbit; resting heart rate, SpO₂,
/// skin temperature), sleep with stage totals but no minute-by-minute stages, workouts with time in
/// each heart-rate zone, and each cycle's energy. No steps and no heart rate outside workouts, so
/// Effort counts heart zones alone and cardio load comes from the workouts' zones.
struct WhoopClient: HealthSource {
    let token: () async throws -> String
    /// Your resting calories for a full day (from your profile), to split a cycle's energy into
    /// resting and active.
    let restingKcalPerDay: Double
    private let base = "https://api.prod.whoop.com/developer/v2"

    enum APIError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let message): return "Whoop API error \(code): \(message)"
            }
        }
    }

    /// One physiological cycle and the calendar day Halo files it under.
    private struct Cycle {
        let id: String
        let start: Date
        let end: Date?          // nil while you're in it
        let day: Date
        let kilojoule: Double?

        func contains(_ t: Date) -> Bool { t >= start && t < (end ?? .distantFuture) }
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

        // A cycle starts the evening before the day it's filed under, so ask from a day earlier.
        let since = from.addingTimeInterval(-86_400)
        async let cycleRecords = attempt { try await records("cycle", from: since) }
        async let sleeps = attempt { try await records("activity/sleep", from: since) }
        async let recoveries = attempt { try await records("recovery", from: since) }
        async let exercises = attempt { try await records("activity/workout", from: cal.date(byAdding: .day, value: -60, to: today) ?? since) }
        async let body = attempt { [try await object("user/measurement/body")] }

        // Sleep: the main sleep of each cycle (naps don't start a cycle and aren't scored).
        // It belongs to the day you woke up on.
        var wokeOnBySleep: [String: Date] = [:]
        var wokeOnByCycle: [String: Date] = [:]
        var nights: [(start: Date, end: Date)] = []
        let sleepResult = await sleeps
        let sleepRecords = take("Sleep", sleepResult, unit: "nights")
        for record in sleepRecords where record["nap"] as? Bool != true {
            guard let session = Self.sleep(record) else { continue }
            if let id = Self.string(record["id"]) { wokeOnBySleep[id] = session.end }
            if let id = Self.string(record["cycle_id"]) { wokeOnByCycle[id] = session.end }
            nights.append((session.start, session.end))
            let score = record["score"] as? [String: Any]
            edit(session.end) { d in
                if (d.sleep?.minutesAsleep ?? 0) < session.minutesAsleep {
                    d.sleep = session
                    d.respiratoryRate = Self.double(score?["respiratory_rate"])
                }
            }
        }

        // Cycles, each filed under the day its sleep ended: the sleep that names the cycle, else the
        // one that began within three hours of it. Without a scored sleep (the band was off
        // overnight), the day it mostly covers: half a day after it started.
        let cycles: [Cycle] = take("Cycles", await cycleRecords).compactMap { r in
            guard let id = Self.string(r["id"]), let start = Self.date(r["start"]) else { return nil }
            let day = wokeOnByCycle[id]
                ?? nights.first { abs($0.start.timeIntervalSince(start)) < 3 * 3600 }?.end
                ?? start.addingTimeInterval(12 * 3600)
            return Cycle(id: id, start: start, end: Self.date(r["end"]), day: cal.startOfDay(for: day),
                         kilojoule: Self.double((r["score"] as? [String: Any])?["kilojoule"]))
        }
        func cycleDay(_ t: Date) -> Date { cycles.first { $0.contains(t) }?.day ?? t }

        // Energy: Whoop measures a cycle's total (resting and active together), over the cycle's
        // own length. Active calories are that total less your resting calories for the same span.
        for c in cycles {
            guard let kj = c.kilojoule else { continue }
            let hours = (c.end ?? .now).timeIntervalSince(c.start) / 3600
            let active = kj / 4.184 - restingKcalPerDay * hours / 24
            // Two cycles can land on one day (a night without the band): their energy adds up.
            edit(c.day) { $0.activeCalories = ($0.activeCalories ?? 0) + max(0, active) }
        }

        // Recovery: worked out when you wake, from the sleep that started the cycle.
        var temps: [(Date, Double)] = []
        for record in take("Recovery", await recoveries) {
            guard record["score_state"] as? String == "SCORED", let score = record["score"] as? [String: Any] else { continue }
            let day = Self.string(record["sleep_id"]).flatMap { wokeOnBySleep[$0] }
                ?? Self.string(record["cycle_id"]).flatMap { id in cycles.first { $0.id == id }?.day }
                ?? Self.date(record["created_at"])
            guard let day else { continue }
            edit(day) { d in
                d.hrv = Self.double(score["hrv_rmssd_milli"])
                d.restingHeartRate = Self.double(score["resting_heart_rate"])
                d.spo2 = Self.double(score["spo2_percentage"])
            }
            if let t = Self.double(score["skin_temp_celsius"]) { temps.append((cal.startOfDay(for: day), t)) }
        }
        for (day, delta) in Self.changeFromUsual(temps) { edit(day) { $0.skinTempDelta = delta } }

        // Workouts go to the cycle they happened in, with their time in each zone. Whoop's zones are
        // shares of your maximum heart rate; in Halo's terms (shares of heart-rate reserve) zone 2 is
        // fat burn, 3 and 4 are cardio, 5 is peak. Zone 1 is below Halo's zones.
        for record in take("Workouts", await exercises, unit: "sessions") {
            guard let w = Self.workout(record) else { continue }
            let zones = (record["score"] as? [String: Any])?["zone_durations"] as? [String: Any]
            func minutes(_ key: String) -> Double { (Self.double(zones?[key]) ?? 0) / 60_000 }
            edit(cycleDay(w.start)) { d in
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
