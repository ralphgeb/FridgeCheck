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
/// each heart-rate zone, and each cycle's strain and energy. No steps and no heart rate outside
/// workouts (not even through Apple Health), so:
///  - cardio load: each workout's time in Whoop's zones, turned into Halo's zones and load as the
///    same heart rate would be on a Fitbit, plus the rest of the day's strain, turned into load
///    with a scale learnt from your own workouts (capped: everyday movement, not training)
///  - steps: from this iPhone through Apple Health, if you turn that on
///
/// Every record is kept on the phone (`WhoopLedger`); a sync reads only what's new.
struct WhoopClient: HealthSource {
    let token: () async throws -> String
    /// Your resting calories for a full day (from your profile), to split a cycle's energy into
    /// resting and active.
    let restingKcalPerDay: Double
    private let base = "https://api.prod.whoop.com/developer/v2"

    /// Steps from the iPhone's own counter, through Apple Health (set in Settings).
    static let phoneStepsKey = "whoop.phoneSteps"
    static var usesPhoneSteps: Bool { UserDefaults.standard.bool(forKey: phoneStepsKey) }

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
        var ledger = WhoopLedger.load()
        var report: [SyncReportLine] = []

        // What to ask for. The first time (or further back than the phone has): everything from a
        // day before `from` (a cycle starts the evening before the day it's filed under). After
        // that, only from two days before the newest record: Whoop rescores the last night or two,
        // and today's cycle grows all day. Twice a day (the store's full pass) two weeks, to pick up
        // edits and deletions.
        let backfill = ledger.coveredFrom.map { from < $0 } ?? true
        let since: Date
        if backfill || ledger.latestStart == nil {
            since = from.addingTimeInterval(-86_400)
        } else {
            let recent = (ledger.latestStart ?? today).addingTimeInterval(-2 * 86_400)
            since = count >= 30 ? min(recent, cal.date(byAdding: .day, value: -14, to: today) ?? recent) : recent
        }

        async let cycleRecords = collection("cycle", from: since)
        async let sleepRecords = collection("activity/sleep", from: since)
        async let recoveryRecords = collection("recovery", from: since)
        async let workoutRecords = collection("activity/workout", from: since)
        async let body = attempt { [try await object("user/measurement/body")] }
        async let phoneSteps = attempt { () async throws -> [HealthKitClient.PhoneSteps] in
            guard Self.usesPhoneSteps else { return [] }
            return [try await HealthKitClient.phoneSteps(from: from)]
        }

        func line(_ name: String, _ read: Int, kept: Int, unit: String) -> SyncReportLine {
            SyncReportLine(name: name, result: "\(read) read · \(kept) \(unit) kept", ok: kept > 0)
        }
        func failed(_ name: String, _ error: Error) {
            report.append(SyncReportLine(name: name, result: error.localizedDescription, ok: false))
        }

        // Each collection is laid over what's kept. One that fails leaves the kept records as they were.
        var allComplete = true
        switch await cycleRecords {
        case .success(let (list, complete)):
            ledger.merge(list.compactMap(Self.cycle), into: \.cycles, id: { $0.id }, start: { $0.start }, prunedFrom: complete ? since : nil)
            allComplete = allComplete && complete
            report.append(line("Cycles", list.count, kept: ledger.cycles.count, unit: "days"))
        case .failure(let error): failed("Cycles", error); allComplete = false
        }
        let sleepResult = await sleepRecords
        switch sleepResult {
        case .success(let (list, complete)):
            ledger.merge(list.compactMap(Self.sleep), into: \.sleeps, id: { $0.id }, start: { $0.start }, prunedFrom: complete ? since : nil)
            allComplete = allComplete && complete
            report.append(line("Sleep", list.count, kept: ledger.sleeps.values.filter { !$0.nap }.count, unit: "nights"))
        case .failure(let error): failed("Sleep", error); allComplete = false
        }
        switch await recoveryRecords {
        case .success(let (list, _)):
            ledger.merge(list.compactMap(Self.recovery), into: \.recoveries, id: { $0.cycleId }, start: { _ in nil }, prunedFrom: nil)
            report.append(line("Recovery", list.count, kept: ledger.recoveries.count, unit: "mornings"))
        case .failure(let error): failed("Recovery", error); allComplete = false
        }
        switch await workoutRecords {
        case .success(let (list, complete)):
            ledger.merge(list.compactMap(Self.workout), into: \.workouts, id: { $0.id }, start: { $0.start }, prunedFrom: complete ? since : nil)
            allComplete = allComplete && complete
            report.append(line("Workouts", list.count, kept: ledger.workouts.count, unit: "sessions"))
        case .failure(let error): failed("Workouts", error); allComplete = false
        }
        if case .success(let list) = await body, let b = list.first {
            ledger.maxHeartRate = Self.double(b["max_heart_rate"]) ?? ledger.maxHeartRate
            ledger.weightKg = Self.double(b["weight_kilogram"]) ?? ledger.weightKg
        }
        if allComplete { ledger.coveredFrom = min(ledger.coveredFrom ?? since, since) }
        if let error = ledger.save() {
            report.append(SyncReportLine(name: "Whoop records", result: "Couldn't save: \(error)", ok: false))
        }

        var days = Self.days(from: ledger, between: from, and: today, restingKcalPerDay: restingKcalPerDay,
                             maxHeartRate: maxHeartRate, report: &report)

        switch await phoneSteps {
        case .success(let list):
            if let steps = list.first {
                for (date, v) in steps.daily where date >= from {
                    days[date, default: DayMetrics(date: date)].steps = Int(v.rounded())
                }
                Self.applyHourly(steps.hourly, to: &days, from: from, \.hourlySteps)
                report.append(SyncReportLine(name: "Steps (iPhone)", result: steps.daily.isEmpty ? "No data" : "\(steps.daily.count) days", ok: !steps.daily.isEmpty))
            }
        case .failure(let error):
            report.append(SyncReportLine(name: "Steps (iPhone)", result: error.localizedDescription, ok: false))
        }

        if let line = Self.todayLine(days[today]) { report.append(line) }
        // Nothing read and nothing kept: say why rather than showing an empty app.
        if ledger.isEmpty, case .failure(let error) = sleepResult { throw error }
        return (days.values.sorted { $0.date < $1.date }, report)
    }

    // MARK: Days from the records

    /// Every day from `from` to `today`, worked out from all the kept records.
    ///
    /// Whoop doesn't count in calendar days. Each cycle (and the recovery, sleep, strain and energy
    /// that belong to it) is filed under the day you woke up on, as described at the top.
    static func days(from ledger: WhoopLedger, between from: Date, and today: Date, restingKcalPerDay: Double,
                     maxHeartRate: Double, report: inout [SyncReportLine]) -> [Date: DayMetrics] {
        let cal = Calendar.current
        var days: [Date: DayMetrics] = [:]
        func edit(_ date: Date, _ change: (inout DayMetrics) -> Void) {
            let key = cal.startOfDay(for: date)
            guard key >= from else { return }
            var d = days[key] ?? DayMetrics(date: key)
            change(&d)
            days[key] = d
        }

        // Sleep: the main sleep of each cycle (naps don't start a cycle and aren't scored here).
        // It belongs to the day you woke up on.
        let nights = ledger.sleeps.values.filter { !$0.nap }.sorted { $0.start < $1.start }
        var wokeOnBySleep: [String: Date] = [:]
        var wokeOnByCycle: [String: Date] = [:]
        for s in nights {
            wokeOnBySleep[s.id] = s.end
            if let c = s.cycleId { wokeOnByCycle[c] = s.end }
            var session = SleepSession(start: s.start, end: s.end, minutesAsleep: s.light + s.deep + s.rem,
                                       minutesAwake: s.awake, stages: [])
            session.stageTotals = [.light: s.light, .deep: s.deep, .rem: s.rem, .awake: s.awake]
            edit(s.end) { d in
                if (d.sleep?.minutesAsleep ?? 0) < session.minutesAsleep {
                    d.sleep = session
                    d.respiratoryRate = s.respiratoryRate
                }
            }
        }

        // Cycles, each filed under the day its sleep ended: the sleep that names the cycle, else the
        // one that began within three hours of it. Without a scored sleep (the band was off
        // overnight), the day it mostly covers: half a day after it started.
        let cycles = ledger.cycles.values.sorted { $0.start < $1.start }
        var dayOfCycle: [String: Date] = [:]
        for c in cycles {
            let woke = wokeOnByCycle[c.id]
                ?? nights.first { abs($0.start.timeIntervalSince(c.start)) < 3 * 3600 }?.end
                ?? c.start.addingTimeInterval(12 * 3600)
            dayOfCycle[c.id] = cal.startOfDay(for: woke)
        }
        func cycleDay(_ t: Date) -> Date {
            cycles.last { t >= $0.start && t < ($0.end ?? .distantFuture) }.flatMap { dayOfCycle[$0.id] } ?? cal.startOfDay(for: t)
        }

        // Energy: Whoop measures a cycle's total (resting and active together), over the cycle's
        // own length. Active calories are that total less your resting calories for the same span.
        for c in cycles {
            guard let kj = c.kilojoule, let day = dayOfCycle[c.id] else { continue }
            let hours = (c.end ?? .now).timeIntervalSince(c.start) / 3600
            let active = kj / 4.184 - restingKcalPerDay * hours / 24
            // Two cycles can land on one day (a night without the band): their energy adds up.
            edit(day) { $0.activeCalories = ($0.activeCalories ?? 0) + max(0, active) }
        }

        // Recovery: worked out when you wake, from the sleep that started the cycle.
        var temps: [(Date, Double)] = []
        for r in ledger.recoveries.values {
            let day = r.sleepId.flatMap { wokeOnBySleep[$0] } ?? dayOfCycle[r.cycleId] ?? r.created
            guard let day else { continue }
            edit(day) { d in
                d.hrv = r.hrv ?? d.hrv
                d.restingHeartRate = r.restingHeartRate ?? d.restingHeartRate
                d.spo2 = r.spo2 ?? d.spo2
            }
            if let t = r.skinTemp { temps.append((cal.startOfDay(for: day), t)) }
        }
        for (day, delta) in changeFromUsual(temps) { edit(day) { $0.skinTempDelta = delta } }

        // Resting heart rate for each day's zones: the morning's, else the latest before it.
        func resting(_ day: Date) -> Double { restingHeartRate(on: day, in: days) }
        let whoopMax = ledger.maxHeartRate ?? maxHeartRate

        // Workouts go to the cycle they happened in, with their time in each zone turned into
        // Halo's zones and load.
        var workoutLoad: [Date: Double] = [:]
        var calibration: [(strain: Double, load: Double)] = []
        for w in ledger.workouts.values.sorted(by: { $0.start < $1.start }) {
            let day = cycleDay(w.start)
            var worked: (load: Double, zones: ZoneMinutes)?
            if let zones = w.zones {
                worked = CardioLoad.fromWhoopZones(zones, resting: resting(day), whoopMax: whoopMax, max: maxHeartRate)
                if let strain = w.strain { calibration.append((strain, worked!.load)) }
            }
            edit(day) { d in
                var list = d.workouts ?? []
                list.append(Workout(id: "whoop-\(w.id)", kind: w.sport, start: w.start, end: w.end,
                                    calories: w.kilojoule.map { $0 / 4.184 }, averageHeartRate: w.averageHeartRate,
                                    distanceKm: w.distanceMeter.map { $0 / 1000 }))
                d.workouts = list
                if let worked {
                    var z = d.zoneMinutes ?? ZoneMinutes()
                    z.fatBurn += worked.zones.fatBurn
                    z.cardio += worked.zones.cardio
                    z.peak += worked.zones.peak
                    d.zoneMinutes = z
                }
            }
            if let worked { workoutLoad[day, default: 0] += worked.load }
        }

        // The day's load: its workouts, plus whatever more the day's strain says your heart did
        // outside them (up to an everyday amount).
        let scale = CardioLoad.whoopStrainScale(calibration)
        var strainLoad: [Date: Double] = [:]
        for c in cycles {
            guard let strain = c.strain, let day = dayOfCycle[c.id] else { continue }
            strainLoad[day, default: 0] += CardioLoad.loadFromStrain(strain, scale: scale)
        }
        for day in Set(workoutLoad.keys).union(strainLoad.keys) {
            let workouts = workoutLoad[day] ?? 0
            let everyday = min(CardioLoad.whoopEverydayCap, max(0, (strainLoad[day] ?? 0) - workouts))
            edit(day) { d in
                d.heartLoad = workouts + everyday
                if let z = d.zoneMinutes { d.activeZoneMinutes = z.fatBurn + 2 * (z.cardio + z.peak) }
                else { d.activeZoneMinutes = 0; d.zoneMinutes = ZoneMinutes() }
            }
        }
        report.append(SyncReportLine(name: "Strain to load",
                                     result: calibration.count >= 3
                                        ? "learnt from \(calibration.count) workouts (\(String(format: "%.2f", scale)))"
                                        : "default until 3 workouts with zones",
                                     ok: true))

        if let kg = ledger.weightKg { edit(today) { $0.weightKg = kg } }
        return days
    }

    // MARK: Parsing

    private static func cycle(_ r: [String: Any]) -> WhoopLedger.Cycle? {
        guard let id = string(r["id"]), let start = date(r["start"]) else { return nil }
        let score = r["score_state"] as? String == "SCORED" ? r["score"] as? [String: Any] : nil
        return .init(id: id, start: start, end: date(r["end"]), kilojoule: double(score?["kilojoule"]),
                     strain: double(score?["strain"]), averageHeartRate: double(score?["average_heart_rate"]),
                     maxHeartRate: double(score?["max_heart_rate"]))
    }

    /// Only scored sleep: one still being scored is read again on the next sync.
    private static func sleep(_ r: [String: Any]) -> WhoopLedger.Sleep? {
        guard r["score_state"] as? String == "SCORED",
              let id = string(r["id"]), let start = date(r["start"]), let end = date(r["end"]),
              let score = r["score"] as? [String: Any],
              let stages = score["stage_summary"] as? [String: Any] else { return nil }
        func minutes(_ key: String) -> Double { (double(stages[key]) ?? 0) / 60_000 }
        let s = WhoopLedger.Sleep(id: id, cycleId: string(r["cycle_id"]), start: start, end: end,
                                  nap: r["nap"] as? Bool ?? false,
                                  light: minutes("total_light_sleep_time_milli"),
                                  deep: minutes("total_slow_wave_sleep_time_milli"),
                                  rem: minutes("total_rem_sleep_time_milli"),
                                  awake: minutes("total_awake_time_milli"),
                                  respiratoryRate: double(score["respiratory_rate"]))
        return s.light + s.deep + s.rem > 0 ? s : nil
    }

    private static func recovery(_ r: [String: Any]) -> WhoopLedger.Recovery? {
        guard r["score_state"] as? String == "SCORED", let cycle = string(r["cycle_id"]),
              let score = r["score"] as? [String: Any] else { return nil }
        return .init(cycleId: cycle, sleepId: string(r["sleep_id"]), created: date(r["created_at"]),
                     hrv: double(score["hrv_rmssd_milli"]), restingHeartRate: double(score["resting_heart_rate"]),
                     spo2: double(score["spo2_percentage"]), skinTemp: double(score["skin_temp_celsius"]))
    }

    private static func workout(_ r: [String: Any]) -> WhoopLedger.Workout? {
        guard let id = string(r["id"]), let start = date(r["start"]), let end = date(r["end"]) else { return nil }
        let score = r["score_state"] as? String == "SCORED" ? r["score"] as? [String: Any] : nil
        let zones = (score?["zone_durations"] as? [String: Any]).map { z in
            ["zero", "one", "two", "three", "four", "five"].map { (double(z["zone_\($0)_milli"]) ?? 0) / 60_000 }
        }
        return .init(id: id, sport: (r["sport_name"] as? String) ?? "workout", start: start, end: end,
                     kilojoule: double(score?["kilojoule"]), strain: double(score?["strain"]),
                     averageHeartRate: double(score?["average_heart_rate"]), maxHeartRate: double(score?["max_heart_rate"]),
                     distanceMeter: double(score?["distance_meter"]), zones: zones)
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

    /// Every record of a collection since `from`, following the pages, and whether that was all of
    /// them (a very long backfill stops at 80 pages).
    private func records(_ path: String, from: Date) async throws -> ([[String: Any]], Bool) {
        var out: [[String: Any]] = []
        var next: String?
        for _ in 0..<80 {
            var comps = URLComponents(string: "\(base)/\(path)")!
            comps.queryItems = [.init(name: "start", value: Self.plain.string(from: from)), .init(name: "limit", value: "25")]
            if let next { comps.queryItems?.append(.init(name: "nextToken", value: next)) }
            let json = try await get(comps.url!)
            out += json["records"] as? [[String: Any]] ?? []
            next = json["next_token"] as? String
            if next?.isEmpty ?? true { return (out, true) }
        }
        return (out, false)
    }

    private func collection(_ path: String, from: Date) async -> Result<([[String: Any]], Bool), Error> {
        do { return .success(try await records(path, from: from)) } catch { return .failure(error) }
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
