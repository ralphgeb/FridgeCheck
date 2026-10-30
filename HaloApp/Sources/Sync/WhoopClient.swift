import Foundation

/// Reads Whoop data through the Whoop developer API (v2).
/// Reference: https://developer.whoop.com/api
///
/// Whoop doesn't count in calendar days. Its "day" is a physiological cycle that starts when you
/// fall asleep (lately: when you wake up) and ends at the next one, so it's rarely 24 hours. Recovery, the night's
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
/// each heart-rate zone, and each cycle's strain, energy and steps. No heart rate outside workouts
/// (not even through Apple Health), so:
///  - cardio load: each workout's time in Whoop's zones, turned into Halo's zones and load as the
///    same heart rate would be on a Fitbit, plus the rest of the day's strain, turned into load
///    with a scale learnt from your own workouts (capped: everyday movement, not training)
///  - steps: Whoop's count for each cycle; this iPhone's (through Apple Health) fills days without
///    one, and gives the hour-by-hour chart, if you turn Apple Health on
///  - heart-rate charts: the readings Whoop writes to Apple Health, if you turn that on
///
/// Every record is kept on the phone (`WhoopLedger`); a sync reads only what's new.
struct WhoopClient: HealthSource {
    let token: () async throws -> String
    /// Your resting calories for a full day (from your profile), to split a cycle's energy into
    /// resting and active.
    let restingKcalPerDay: Double
    private let base = "https://api.prod.whoop.com/developer/v2"

    /// Where the heart-rate readings the app already has end (only newer ones are read).
    var heartSince: Date? = nil

    /// Also read Apple Health (set in Settings): the heart rate Whoop writes there, and the
    /// iPhone's steps for days without Whoop's.
    /// Days of Whoop history Halo reads and keeps: about three months.
    static let monthsKept = 92

    static let appleHealthKey = "whoop.appleHealth"
    /// The signed-in Whoop account's name and email, shown in Settings › Sources.
    static let accountKey = "whoop.account"
    static var usesAppleHealth: Bool { UserDefaults.standard.bool(forKey: appleHealthKey) }

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
        // Whoop: today back three months is plenty (enough for 30-day baselines and the weekly
        // cardio target); asking for less keeps each sync quick
        let span = min(count, Self.monthsKept)
        let from = cal.date(byAdding: .day, value: -(span - 1), to: today) ?? today
        var ledger = WhoopLedger.load()
        var report: [SyncReportLine] = []
        if ledger.hasSteps != true || ledger.hasScores != true || ledger.hasFullRange != true {
            ledger.coveredFrom = nil
            ledger.hasSteps = true
            ledger.hasScores = true
            ledger.hasFullRange = true
        }

        // What to ask for. The first time (or further back than the phone has): everything from a
        // day before `from` (a cycle starts the evening before the day it's filed under). After
        // that, only from two days before the newest record: Whoop rescores the last night or two,
        // and today's cycle grows all day. Twice a day (the store's full pass) two weeks, to pick up
        // edits and deletions.
        let backfill = ledger.coveredFrom.map { from < $0 } ?? true
        let since: Date
        // newest record more than two weeks old: don't trust what's kept, read the whole span again
        let stale = (ledger.latestStart ?? .distantPast) < (cal.date(byAdding: .day, value: -14, to: today) ?? today)
        if backfill || stale {
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
        async let profile = attempt { [try await object("user/profile/basic")] }
        async let phoneSteps = attempt { () async throws -> [HealthKitClient.PhoneSteps] in
            guard Self.usesAppleHealth else { return [] }
            return [try await HealthKitClient.phoneSteps(from: from)]
        }
        // Heart rate for the charts: only what's newer than the readings the app has, at most two weeks.
        let twoWeeks = cal.date(byAdding: .day, value: -13, to: today) ?? today
        let heartFrom = max(heartSince ?? twoWeeks, twoWeeks)
        async let heart = attempt { () async throws -> [HeartSample] in
            guard Self.usesAppleHealth else { return [] }
            return try await HealthKitClient.heartRate(from: heartFrom)
        }

        // what came back, with the dates it covers and how many Whoop hasn't scored yet, so a
        // short answer (a new account, or another one than in the Whoop app) is easy to see
        func line(_ name: String, _ list: [[String: Any]], kept: Int, unit: String) -> SyncReportLine {
            let starts = list.compactMap { Self.date($0["start"]) ?? Self.date($0["created_at"]) }
            let span = starts.min().map { a in
                let b = starts.max() ?? a
                let f = Date.FormatStyle().day().month(.abbreviated)
                return a == b ? " (\(a.formatted(f)))" : " (\(a.formatted(f)) – \(b.formatted(f)))"
            } ?? ""
            let unscored = list.filter { ($0["score_state"] as? String).map { $0 != "SCORED" } ?? false }.count
            return SyncReportLine(name: name,
                                  result: "\(list.count) read\(span) · \(kept) \(unit) kept" + (unscored > 0 ? " · \(unscored) not scored yet" : ""),
                                  ok: kept > 0)
        }
        report.append(SyncReportLine(name: "Asked Whoop for", result: "\(since.formatted(Date.FormatStyle().day().month(.abbreviated).year())) to today", ok: true))
        func failed(_ name: String, _ error: Error) {
            report.append(SyncReportLine(name: name, result: error.localizedDescription, ok: false))
        }

        // Each collection is laid over what's kept. One that fails leaves the kept records as they were.
        var allComplete = true
        switch await cycleRecords {
        case .success(let (list, complete)):
            ledger.merge(list.compactMap(Self.cycle), into: \.cycles, id: { $0.id }, start: { $0.start }, prunedFrom: complete ? since : nil)
            allComplete = allComplete && complete
            report.append(line("Cycles", list, kept: ledger.cycles.count, unit: "days"))
        case .failure(let error): failed("Cycles", error); allComplete = false
        }
        let sleepResult = await sleepRecords
        switch sleepResult {
        case .success(let (list, complete)):
            ledger.merge(list.compactMap(Self.sleep), into: \.sleeps, id: { $0.id }, start: { $0.start }, prunedFrom: complete ? since : nil)
            allComplete = allComplete && complete
            report.append(line("Sleep", list, kept: ledger.sleeps.values.filter { !$0.nap }.count, unit: "nights"))
        case .failure(let error): failed("Sleep", error); allComplete = false
        }
        switch await recoveryRecords {
        case .success(let (list, _)):
            ledger.merge(list.compactMap(Self.recovery), into: \.recoveries, id: { $0.cycleId }, start: { _ in nil }, prunedFrom: nil)
            report.append(line("Recovery", list, kept: ledger.recoveries.count, unit: "mornings"))
        case .failure(let error): failed("Recovery", error); allComplete = false
        }
        switch await workoutRecords {
        case .success(let (list, complete)):
            ledger.merge(list.compactMap(Self.workout), into: \.workouts, id: { $0.id }, start: { $0.start }, prunedFrom: complete ? since : nil)
            allComplete = allComplete && complete
            report.append(line("Workouts", list, kept: ledger.workouts.count, unit: "sessions"))
        case .failure(let error): failed("Workouts", error); allComplete = false
        }
        // how Whoop paged each kind of record, to see where a short answer comes from
        for (path, name) in [("cycle", "Cycles"), ("activity/sleep", "Sleep"), ("recovery", "Recovery"), ("activity/workout", "Workouts")] {
            if let n = await MainActor.run(body: { Self.pageNotes[path] }) {
                report.append(SyncReportLine(name: "\(name) detail", result: n, ok: true))
            }
        }
        report.append(SyncReportLine(name: "This iPhone's date", result: Date().formatted(Date.FormatStyle().day().month(.abbreviated).year().hour().minute()), ok: true))

        // which Whoop account this is, to check it's the one in the Whoop app
        switch await profile {
        case .success(let list):
            if let p = list.first {
                let name = [p["first_name"], p["last_name"]].compactMap { $0 as? String }.joined(separator: " ")
                let account = [name.isEmpty ? nil : name, p["email"] as? String].compactMap { $0 }.joined(separator: " · ")
                UserDefaults.standard.set(account, forKey: Self.accountKey)
                report.insert(SyncReportLine(name: "Whoop account", result: account.isEmpty ? "Unknown" : account, ok: true), at: 0)
            }
        case .failure(let error):
            report.insert(SyncReportLine(name: "Whoop account", result: error.localizedDescription, ok: false), at: 0)
        }
        if case .success(let list) = await body, let b = list.first {
            ledger.maxHeartRate = Self.double(b["max_heart_rate"]) ?? ledger.maxHeartRate
            ledger.weightKg = Self.double(b["weight_kilogram"]) ?? ledger.weightKg
        }
        if allComplete { ledger.coveredFrom = min(ledger.coveredFrom ?? since, since) }
        // keep only the three months Halo uses
        let keepFrom = from.addingTimeInterval(-2 * 86_400)
        ledger.cycles = ledger.cycles.filter { $0.value.start >= keepFrom }
        ledger.sleeps = ledger.sleeps.filter { $0.value.start >= keepFrom }
        ledger.workouts = ledger.workouts.filter { $0.value.start >= keepFrom }
        ledger.recoveries = ledger.recoveries.filter { ledger.cycles[$0.key] != nil || ($0.value.created ?? .now) >= keepFrom }
        if let error = ledger.save() {
            report.append(SyncReportLine(name: "Whoop records", result: "Couldn't save: \(error)", ok: false))
        }

        var days = Self.days(from: ledger, between: from, and: today, restingKcalPerDay: restingKcalPerDay,
                             maxHeartRate: maxHeartRate, report: &report)

        let whoopStepDays = days.values.filter { $0.steps != nil }.count
        report.append(SyncReportLine(name: "Steps (Whoop)", result: whoopStepDays == 0 ? "No data" : "\(whoopStepDays) days", ok: whoopStepDays > 0))

        switch await phoneSteps {
        case .success(let list):
            if let steps = list.first {
                // Whoop's own count first (it's on your wrist all day); the phone fills days without it.
                for (date, v) in steps.daily where date >= from && days[date]?.steps == nil {
                    days[date, default: DayMetrics(date: date)].steps = Int(v.rounded())
                }
                Self.applyHourly(steps.hourly, to: &days, from: from, \.hourlySteps)
                report.append(SyncReportLine(name: "Steps (iPhone)", result: steps.daily.isEmpty ? "No data" : "\(steps.daily.count) days", ok: !steps.daily.isEmpty))
            }
        case .failure(let error):
            report.append(SyncReportLine(name: "Steps (iPhone)", result: error.localizedDescription, ok: false))
        }

        // Whoop writes heart rate to Apple Health (during sleep and workouts, at least). It's only for
        // the charts: load and zones come from Whoop's own zones, as above.
        if Self.usesAppleHealth {
            switch await heart {
            case .success(let readings):
                for (day, minutes) in HeartMinutes.buckets(readings) where day >= from {
                    days[day, default: DayMetrics(date: day)].minuteHeartRate = minutes
                }
                report.append(SyncReportLine(name: "Heart rate (Apple Health)",
                                             result: readings.isEmpty ? "Nothing new" : "\(readings.count) readings", ok: true))
            case .failure(let error):
                report.append(SyncReportLine(name: "Heart rate (Apple Health)", result: error.localizedDescription, ok: false))
            }
        }

        // last night as Whoop scored it, to check against the Whoop app
        if let s = ledger.sleeps.values.filter({ !$0.nap }).max(by: { $0.end < $1.end }) {
            let rec = ledger.recoveries.values.first { $0.sleepId == s.id }?.score
            let parts = [
                s.inBed.map { "in bed \(Format.duration($0))" },
                "awake \(Format.duration(s.awake))",
                s.noData.flatMap { $0 >= 1 ? "no data \(Format.duration($0))" : nil },
                "light \(Format.duration(s.light)) · deep \(Format.duration(s.deep)) · REM \(Format.duration(s.rem))",
                s.need.map { "need \(Format.duration($0))" },
                s.performance.map { "sleep \(Int($0.rounded()))%" },
                rec.map { "recovery \(Int($0.rounded()))%" },
            ].compactMap { $0 }
            report.append(SyncReportLine(name: "Last night (Whoop)", result: parts.joined(separator: " · "), ok: true))
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
        for s in nights {
            wokeOnBySleep[s.id] = s.end
            // Hours of sleep as the Whoop app counts them: time in bed less time awake. Anything the
            // stage totals leave out (time the band couldn't read) counts as light sleep.
            let staged = s.light + s.deep + s.rem
            let asleep = max(staged, (s.inBed ?? 0) - s.awake)
            let light = s.light + (asleep - staged)
            var session = SleepSession(start: s.start, end: s.end, minutesAsleep: asleep,
                                       minutesAwake: s.awake, stages: [])
            session.stageTotals = [.light: light, .deep: s.deep, .rem: s.rem, .awake: s.awake]
            edit(s.end) { d in
                if (d.sleep?.minutesAsleep ?? 0) < session.minutesAsleep {
                    d.sleep = session
                    d.respiratoryRate = s.respiratoryRate
                    // Whoop's own sleep score and need, so Halo shows what the Whoop app does
                    d.bandSleepScore = s.performance.map { $0 / 100 }
                    d.sleepNeedMinutes = s.need
                }
            }
        }

        // Cycles, each filed under the day you woke up on. Without a scored sleep nearby (the band
        // was off overnight), the day it mostly covers: half a day after it started.
        let cycles = ledger.cycles.values.sorted { $0.start < $1.start }
        var dayOfCycle: [String: Date] = [:]
        for c in cycles {
            // Whoop has started its days both ways (falling asleep, and lately waking up), so match
            // either: a cycle that starts near a wake-up is that morning's day; one that starts near
            // falling asleep is the day that sleep ends on.
            let woke = nights.first { abs($0.end.timeIntervalSince(c.start)) < 3 * 3600 }?.end
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

        // Steps: Whoop counts them per cycle, filed with the rest of the cycle.
        for c in cycles {
            guard let steps = c.steps, let day = dayOfCycle[c.id] else { continue }
            edit(day) { $0.steps = ($0.steps ?? 0) + Int(steps.rounded()) }
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
                d.bandRecovery = r.score.map { $0 / 100 } ?? d.bandRecovery
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
        // Steps (added to the API in September 2026) grow through the current cycle, so they're
        // read whatever the score state.
        let steps = double(r["step_count"]) ?? double((r["score"] as? [String: Any])?["step_count"])
        return .init(id: id, start: start, end: date(r["end"]), kilojoule: double(score?["kilojoule"]),
                     strain: double(score?["strain"]), averageHeartRate: double(score?["average_heart_rate"]),
                     maxHeartRate: double(score?["max_heart_rate"]), steps: steps)
    }

    /// Only scored sleep: one still being scored is read again on the next sync.
    private static func sleep(_ r: [String: Any]) -> WhoopLedger.Sleep? {
        guard r["score_state"] as? String == "SCORED",
              let id = string(r["id"]), let start = date(r["start"]), let end = date(r["end"]),
              let score = r["score"] as? [String: Any],
              let stages = score["stage_summary"] as? [String: Any] else { return nil }
        func minutes(_ key: String) -> Double { (double(stages[key]) ?? 0) / 60_000 }
        // what Whoop says you needed: baseline + debt + recent strain + recent naps (negative)
        let needParts = (score["sleep_needed"] as? [String: Any]).map { n in
            ["baseline_milli", "need_from_sleep_debt_milli", "need_from_recent_strain_milli", "need_from_recent_nap_milli"]
                .compactMap { double(n[$0]) }.reduce(0, +) / 60_000
        }
        let s = WhoopLedger.Sleep(id: id, cycleId: string(r["cycle_id"]), start: start, end: end,
                                  nap: r["nap"] as? Bool ?? false,
                                  light: minutes("total_light_sleep_time_milli"),
                                  deep: minutes("total_slow_wave_sleep_time_milli"),
                                  rem: minutes("total_rem_sleep_time_milli"),
                                  awake: minutes("total_awake_time_milli"),
                                  respiratoryRate: double(score["respiratory_rate"]),
                                  inBed: stages["total_in_bed_time_milli"].flatMap(double).map { $0 / 60_000 },
                                  noData: stages["total_no_data_time_milli"].flatMap(double).map { $0 / 60_000 },
                                  performance: double(score["sleep_performance_percentage"]),
                                  need: needParts.flatMap { $0 > 60 ? $0 : nil })
        return s.light + s.deep + s.rem > 0 ? s : nil
    }

    private static func recovery(_ r: [String: Any]) -> WhoopLedger.Recovery? {
        guard r["score_state"] as? String == "SCORED", let cycle = string(r["cycle_id"]),
              let score = r["score"] as? [String: Any] else { return nil }
        return .init(cycleId: cycle, sleepId: string(r["sleep_id"]), created: date(r["created_at"]),
                     hrv: double(score["hrv_rmssd_milli"]), restingHeartRate: double(score["resting_heart_rate"]),
                     spo2: double(score["spo2_percentage"]), skinTemp: double(score["skin_temp_celsius"]),
                     score: double(score["recovery_score"]))
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
    /// What each collection's paging looked like on the last sync, for the sync report: pages,
    /// newest and oldest record, whether Whoop said there was more.
    @MainActor static var pageNotes: [String: String] = [:]

    private func records(_ path: String, from: Date) async throws -> ([[String: Any]], Bool) {
        var out: [[String: Any]] = []
        var next: String?
        var pages = 0
        func note(_ more: Bool) async {
            let starts = out.compactMap { Self.date($0["start"]) ?? Self.date($0["created_at"]) }
            let f = Date.FormatStyle().day().month(.abbreviated).year(.twoDigits)
            let span = starts.isEmpty ? "none" : "newest \(starts.max()!.formatted(f)), oldest \(starts.min()!.formatted(f))"
            let text = "\(pages) page\(pages == 1 ? "" : "s") · \(out.count) records · \(span)\(more ? " · more left" : "")"
            await MainActor.run { Self.pageNotes[path] = text }
        }
        for _ in 0..<80 {
            var comps = URLComponents(string: "\(base)/\(path)")!
            // Both ends: with only a start, Whoop answered with just the few days after it, so a
            // first sync came back with a handful of records and later ones kept asking from there.
            let end = Date().addingTimeInterval(86_400)
            comps.queryItems = [.init(name: "start", value: Self.plain.string(from: from)),
                                .init(name: "end", value: Self.plain.string(from: end)),
                                .init(name: "limit", value: "25")]
            if let next { comps.queryItems?.append(.init(name: "nextToken", value: next)) }
            let json = try await get(comps.url!)
            pages += 1
            out += json["records"] as? [[String: Any]] ?? []
            // Whoop names it next_token; accept nextToken too
            next = (json["next_token"] as? String) ?? (json["nextToken"] as? String)
            if next?.isEmpty ?? true {
                await note(false)
                return (out, true)
            }
        }
        await note(true)
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
