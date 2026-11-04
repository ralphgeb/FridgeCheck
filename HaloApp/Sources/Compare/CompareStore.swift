import Foundation

/// Testing only (the Compare tab, to be removed after): the same days from Fitbit, Whoop and an
/// Apple Watch worn together, each kept apart, so Halo's scores can be set side by side. Fitbit
/// stays the main source for the rest of the app.
@MainActor
final class CompareStore: ObservableObject {
    enum Device: String, CaseIterable, Identifiable {
        case fitbit, whoop, watch
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fitbit: return "Fitbit"
            case .whoop: return "Whoop"
            case .watch: return "Apple Watch"
            }
        }
    }

    @Published private(set) var days: [Device: [DayMetrics]] = [:]
    @Published private(set) var reports: [Device: [SyncReportLine]] = [:]
    @Published private(set) var errors: [Device: String] = [:]
    @Published private(set) var syncing: Set<Device> = []
    @Published private(set) var lastSync: Date?

    init() {
        for d in Device.allCases { days[d] = Self.load(d) }
    }

    func isConnected(_ d: Device) -> Bool {
        switch d {
        case .fitbit: return GoogleAuth.shared.isConnected
        case .whoop: return WhoopAuth.shared.isConnected
        case .watch: return HealthKitClient.isConnected
        }
    }

    func connect(_ d: Device) async throws {
        switch d {
        case .fitbit: try await GoogleAuth.shared.connect()
        case .whoop:
            try await WhoopAuth.shared.connect()
            if HealthKitClient.isAvailable { try? await HealthKitClient.connectForWhoop() }
        case .watch: try await HealthKitClient.connect()
        }
    }

    /// Keeps the comparison up to date without being asked: after the app's own syncs, at most
    /// every ten minutes, each band reads only its recent days (the whole year once a day).
    func syncIfDue(main: HealthStore) async {
        guard (lastSync?.timeIntervalSinceNow ?? -.infinity) < -10 * 60, syncing.isEmpty else { return }
        await syncAll(main: main)
    }

    /// The days a band reads: the whole history the first time and about once a day, otherwise
    /// the last ten (enough to catch late scores and rescored nights).
    private func span(_ d: Device) -> Int {
        let key = "compare.lastFull.\(d.rawValue)"
        let last = UserDefaults.standard.double(forKey: key)
        if (days[d] ?? []).isEmpty || Date.now.timeIntervalSince1970 - last > 20 * 3600 {
            return HealthStore.historyDays
        }
        return 10
    }

    private func markFull(_ d: Device, _ count: Int) {
        if count == HealthStore.historyDays {
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "compare.lastFull.\(d.rawValue)")
        }
    }

    /// Reads every connected band. A band that's the app's main source comes from the main store.
    func syncAll(main: HealthStore) async {
        await withTaskGroup(of: Void.self) { group in
            for d in Device.allCases where isConnected(d) {
                group.addTask { await self.sync(d, main: main) }
            }
        }
        lastSync = .now
    }

    private func sync(_ d: Device, main: HealthStore) async {
        guard !syncing.contains(d) else { return }
        syncing.insert(d)
        defer { syncing.remove(d) }
        let maxHR = main.profile.maxHeartRate
        do {
            let count = span(d)
            switch d {
            case .fitbit:
                if main.source == .google && !main.showingSample {
                    if main.days.isEmpty { await main.sync() }
                    set(d, main.days, main.syncReport)
                } else {
                    let (list, report) = try await GoogleHealthClient(token: { try await GoogleAuth.shared.accessToken() }, heartSince: nil)
                        .fetchDays(count, maxHeartRate: maxHR)
                    set(d, merge(days[d] ?? [], list), report)
                    markFull(d, count)
                }
            case .whoop:
                if main.source == .whoop && !main.showingSample {
                    if main.days.isEmpty { await main.sync() }
                    set(d, main.days, main.syncReport)
                } else {
                    let client = WhoopClient(token: { try await WhoopAuth.shared.accessToken() },
                                             restingKcalPerDay: main.profile.restingCalories(),
                                             heartSince: nil, fillStepsFromPhone: false)
                    let (list, report) = try await client.fetchDays(count, maxHeartRate: maxHR)
                    set(d, merge(days[d] ?? [], list), report)
                    markFull(d, count)
                }
            case .watch:
                let (list, report) = try await HealthKitClient(scope: .watch).fetchDays(count, maxHeartRate: maxHR)
                set(d, merge(days[d] ?? [], list), report)
                markFull(d, count)
            }
            errors[d] = nil
        } catch {
            errors[d] = error.localizedDescription
        }
    }

    private func merge(_ old: [DayMetrics], _ new: [DayMetrics]) -> [DayMetrics] {
        var byDate = Dictionary(old.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        for n in new { byDate[n.date] = n.filling(from: byDate[n.date]) }
        return byDate.values.sorted { $0.date < $1.date }
    }

    private func set(_ d: Device, _ list: [DayMetrics], _ report: [SyncReportLine]) {
        // heart rate kept minute by minute becomes the 5-minute line the charts draw
        let ready = list.map { day -> DayMetrics in
            var day = day
            if day.heartRate.isEmpty, let m = day.minuteHeartRate {
                day.heartRate = GoogleHealthClient.fiveMinuteAverages(HeartMinutes.samples(m, day: day.date))
            }
            return day
        }.sorted { $0.date < $1.date }
        days[d] = ready
        reports[d] = report
        Self.save(d, ready)
    }

    // MARK: Reading

    func day(_ d: Device, _ date: Date) -> DayMetrics? {
        let key = Calendar.current.startOfDay(for: date)
        return days[d]?.first { $0.date == key }
    }

    /// Halo's own three scores from this band's data alone (Whoop's own scores left out).
    func haloScores(_ d: Device, _ date: Date, targets: Targets) -> Scores? {
        guard let list = days[d], let day = day(d, date) else { return nil }
        func plain(_ x: DayMetrics) -> DayMetrics { var x = x; x.bandRecovery = nil; x.bandSleepScore = nil; return x }
        let history = list.filter { $0.date < day.date }.suffix(ScoreEngine.baselineDays).map(plain) + [plain(day)]
        return ScoreEngine.scores(for: plain(day), history: history, targets: targets)
    }

    /// Everything for the last `count` days, as text to paste into a message.
    func text(days count: Int, targets: Targets, maxHeartRate: Double) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var lines = ["Halo compare · \(Date().formatted(.iso8601)) · max HR \(Int(maxHeartRate))"]
        func n(_ v: Double?, _ digits: Int = 0) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }
        func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))" } ?? "–" }
        for back in 0..<count {
            guard let date = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            lines.append("")
            lines.append("== \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())) ==")
            for d in Device.allCases {
                guard let x = day(d, date) else { lines.append("\(d.title): no data"); continue }
                let s = haloScores(d, date, targets: targets)
                var line = "\(d.title): Halo recovery \(pct(s?.recovery)) sleep \(pct(s?.sleep)) effort \(pct(s?.effort))"
                if x.bandRecovery != nil || x.bandSleepScore != nil {
                    line += " | own recovery \(pct(x.bandRecovery)) sleep \(pct(x.bandSleepScore))"
                    if let need = x.sleepNeedMinutes { line += " need \(Format.duration(need))" }
                }
                // what went into Halo's scores, to set them against each band's own
                let past = (days[d] ?? []).filter { $0.date < x.date }.suffix(ScoreEngine.baselineDays)
                let z = ScoreEngine.recoveryZ(x, previous: Array(past))
                line += " | z HRV \(n(z.hrv, 2)) RHR \(n(z.rhr, 2)) (\(past.count) days before)"
                if let sl = x.sleep {
                    let p = ScoreEngine.sleepParts(sl, previous: Array(past), targets: targets, need: x.sleepNeedMinutes)
                    line += " | sleep parts dur \(pct(p.duration)) deep \(pct(p.deep)) rem \(pct(p.rem)) eff \(pct(p.efficiency)) calm \(pct(p.calm)) cons \(pct(p.consistency))"
                }
                let sl = x.sleep
                line += " | asleep \(sl.map { Format.duration($0.minutesAsleep) } ?? "–")"
                if let sl { line += " (\(Format.time(sl.start))–\(Format.time(sl.end)), deep \(Int(sl.minutes(.deep))) rem \(Int(sl.minutes(.rem))) awake \(Int(sl.minutesAwake)))" }
                line += " | HRV \(n(x.hrv)) RHR \(n(x.restingHeartRate)) resp \(n(x.respiratoryRate, 1)) SpO2 \(n(x.spo2, 1)) temp \(n(x.skinTempDelta, 1))"
                line += " | steps \(x.steps.map(String.init) ?? "–") active kcal \(n(x.activeCalories)) load \(n(x.cardioLoad)) zones \(x.zones.map { "\(Int($0.fatBurn))/\(Int($0.cardio))/\(Int($0.peak))" } ?? "–")"
                line += " | HR readings \(x.heartRate.count) workouts \(x.workouts?.count ?? 0)"
                lines.append(line)
            }
        }
        for d in Device.allCases {
            lines.append("")
            lines.append("-- \(d.title) last sync --")
            if let e = errors[d] { lines.append("error: \(e)") }
            for r in reports[d] ?? [] { lines.append("\(r.name): \(r.result)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Saving

    private static func url(_ d: Device) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("compare-\(d.rawValue).json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()

    private static func load(_ d: Device) -> [DayMetrics] {
        guard let data = try? Data(contentsOf: url(d)) else { return [] }
        return (try? decoder.decode([DayMetrics].self, from: data)) ?? []
    }

    private static func save(_ d: Device, _ list: [DayMetrics]) {
        try? FileManager.default.createDirectory(at: url(d).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(list).write(to: url(d), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
