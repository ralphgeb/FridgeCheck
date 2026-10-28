import Foundation
import SwiftUI

/// The app's single source of truth: six months of days, their scores, targets, profile and sync state.
@MainActor
final class HealthStore: ObservableObject {
    @Published private(set) var days: [DayMetrics] = [] { didSet { rebuildIndex() } }
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    /// What the last sync got back for each kind of data (shown in Settings).
    @Published private(set) var syncReport: [SyncReportLine] = []
    @Published var selectedDate = Calendar.current.startOfDay(for: .now)
    @Published var targets: Targets { didSet { save(targets, Self.targetsKey); rebuildIndex(); publishWidget() } }
    @Published var profile: Profile { didSet { save(profile, Self.profileKey); publishWidget() } }
    /// Workout types you've changed by hand, by workout id. Kept across syncs.
    @Published var activityOverrides: [String: ActivityType] { didSet { save(activityOverrides, Self.overridesKey) } }

    /// Where the data comes from (set in Settings).
    @Published private(set) var source = DataSource.current

    /// The store the open app is showing, so background syncs update it rather than a second copy.
    static weak var foreground: HealthStore?

    /// Syncs the open app's store if there is one, else a fresh one (which saves for the app).
    static func syncAnywhere() async {
        if let store = foreground { await store.sync() } else { await HealthStore().sync() }
    }

    /// True while the chosen source isn't connected: the app runs on sample data.
    var isSample: Bool { !source.isConnected }

    private var byDate: [Date: DayMetrics] = [:]
    private var scoreCache: [Date: Scores] = [:]

    private static let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("days.json")
    private static let targetsKey = "targets.v3"
    private static let profileKey = "profile"
    private static let overridesKey = "activityOverrides"
    private static let lastSyncKey = "lastSync"
    private static let lastFullSyncKey = "lastFullSync"
    static let historyDays = 182
    static let recentDays = 10

    init() {
        targets = Self.load(Targets.self, Self.targetsKey) ?? Targets()
        profile = Self.load(Profile.self, Self.profileKey) ?? Profile()
        activityOverrides = Self.load([String: ActivityType].self, Self.overridesKey) ?? [:]
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        if isSample {
            days = SampleData.days(count: Self.historyDays)
        } else if let cached = Self.loadCache() {
            days = cached
        }
        rebuildIndex()
        publishWidget()
    }

    /// The days the app keeps on the phone, so it opens straight onto your data.
    private static func loadCache() -> [DayMetrics]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode([DayMetrics].self, from: data)
    }

    private static func saveCache(_ days: [DayMetrics]) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // readable after the first unlock, so a background refresh can update it with the phone locked
        try? JSONEncoder().encode(days).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// iOS sometimes syncs in the background (another copy of the store). Coming back to the app,
    /// pick up what it saved rather than waiting for a sync of our own.
    func reloadIfUpdatedElsewhere() {
        guard !isSyncing, !isSample,
              let saved = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date,
              saved > (lastSync ?? .distantPast),
              let cached = Self.loadCache() else { return }
        lastSync = saved
        days = cached
        publishWidget()
    }

    // MARK: Reading

    func day(_ date: Date) -> DayMetrics? { byDate[Calendar.current.startOfDay(for: date)] }

    var selectedDay: DayMetrics { day(selectedDate) ?? DayMetrics(date: selectedDate) }
    var isTodaySelected: Bool { Calendar.current.isDateInToday(selectedDate) }
    var firstDate: Date { days.first?.date ?? Calendar.current.startOfDay(for: .now) }

    func scores(for date: Date) -> Scores { scoreCache[Calendar.current.startOfDay(for: date)] ?? Scores() }

    /// The last `count` days ending on `date`, oldest first, with their scores.
    func week(endingOn date: Date, count: Int = 7) -> [DayScore] {
        let cal = Calendar.current
        return (0..<count).reversed().compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: date), let item = self.day(d) else { return nil }
            return DayScore(day: item, scores: scores(for: item.date))
        }
    }

    /// Daily values of a metric for the span ending on `date`, oldest first. Days without data are skipped.
    func series(_ metric: Metric, days count: Int, endingOn date: Date) -> [(date: Date, value: Double)] {
        let end = Calendar.current.startOfDay(for: date)
        guard let start = Calendar.current.date(byAdding: .day, value: -(count - 1), to: end) else { return [] }
        return days.filter { $0.date >= start && $0.date <= end }
            .compactMap { d in metric.value(d, in: self).map { (date: d.date, value: $0) } }
    }

    /// Your normal range for a metric: the 30 days before `date`.
    func normalRange(_ metric: Metric, before date: Date) -> NormalRange? {
        let end = Calendar.current.startOfDay(for: date)
        let values = days.filter { $0.date < end }.suffix(30).compactMap { metric.value($0, in: self) }
        return NormalRange(values: values, minimumBand: metric.minimumBand)
    }

    /// Mean of a metric over the 30 days before `date` (the personal baseline).
    func baseline(_ metric: Metric, before date: Date) -> Double? {
        let end = Calendar.current.startOfDay(for: date)
        return ScoreEngine.mean(days.filter { $0.date < end }.suffix(30).compactMap { metric.value($0, in: self) })
    }

    func balance(for date: Date) -> [BalanceAxis] {
        ScoreEngine.balance(days: days, endingOn: date, targets: targets) { self.scores(for: $0.date) }
    }

    /// Cardio load for the seven days ending on `date`, with this week's target and focus.
    func cardioWeek(endingOn date: Date) -> CardioLoad.Week {
        CardioLoad.week(days: days, endingOn: date, chosen: targets.cardioFocus, recovery: scores(for: date).recovery)
    }

    /// What went into one of the three scores on a day.
    func factors(_ kind: ScoreKind, on date: Date) -> [ScoreEngine.Factor] {
        guard let d = day(date) else { return [] }
        return ScoreEngine.factors(kind, day: d, history: Array(days.filter { $0.date < d.date }.suffix(ScoreEngine.baselineDays)) + [d], targets: targets)
    }

    // MARK: Fitness

    /// The day's workouts. Until Fitbit has logged one today, two examples show how they look.
    func activities(on date: Date) -> [Workout] {
        let real = day(date)?.workouts ?? []
        guard real.isEmpty, Calendar.current.isDateInToday(date) else { return real }
        let cal = Calendar.current
        let d = cal.startOfDay(for: date)
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d }
        return [
            Workout(id: "example-walk", kind: "WALKING", start: at(7, 40), end: at(8, 15), calories: 168, averageHeartRate: 104, distanceKm: 3.1),
            Workout(id: "example-strength", kind: "STRENGTH_TRAINING", start: at(12, 5), end: at(12, 50), calories: 286, averageHeartRate: 121, distanceKm: nil),
        ]
    }

    func activityType(_ w: Workout) -> ActivityType { activityOverrides[w.id] ?? ActivityType(rawValue: w.kind) ?? ActivityType(fitbit: w.kind) }

    func setActivityType(_ type: ActivityType, for w: Workout) { activityOverrides[w.id] = type }

    /// How ready you are to train today, 0...1: mostly recovery, some sleep, and a little less when
    /// the last seven days were much harder than your usual week.
    func readiness(for date: Date) -> Double? {
        let s = scores(for: date)
        guard let recovery = s.recovery else { return nil }
        var v = 0.7 * recovery + 0.3 * (s.sleep ?? recovery)
        let cal = Calendar.current
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        if let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: date)),
           let recent = CardioLoad.weekTotal(byDate: byDate, start: start),
           let usual = CardioLoad.baseline(byDate: byDate, weekStart: start), usual > 0 {
            let ratio = recent / usual
            if ratio > 1.3 { v -= min(0.15, (ratio - 1.3) * 0.3) }
        }
        return ScoreEngine.clamp(v)
    }

    /// Recompute every score, after a setting they depend on changes (like the first day of the week).
    func refreshScores() {
        rebuildIndex()
        objectWillChange.send()
        publishWidget()
    }

    /// One day of a metric, hour by hour or reading by reading, for the 1D graphs. Nil when the day
    /// has no intraday data (only the last two weeks keep it).
    func intraday(_ m: Metric, on date: Date) -> DaySeries? {
        guard let d = day(date) else { return nil }
        let cal = Calendar.current
        // hours that have started (today stops at the current hour)
        func hours(_ values: [Double]?) -> [(time: Date, value: Double)]? {
            guard let values else { return nil }
            var out: [(time: Date, value: Double)] = []
            for (h, v) in values.enumerated() {
                if let t = cal.date(byAdding: .hour, value: h, to: d.date), t <= .now { out.append((time: t, value: v)) }
            }
            return out
        }
        switch m {
        case .restingHeartRate:
            guard !d.heartRate.isEmpty else { return nil }
            return DaySeries(kind: .line, points: d.heartRate.map { (time: $0.time, value: $0.bpm) },
                             headline: d.restingHeartRate, headlineLabel: "Resting heart rate",
                             reference: d.restingHeartRate.map { (label: "Resting", value: $0) })
        case .steps:
            guard let h = hours(d.hourlySteps) else { return nil }
            return DaySeries(kind: .bars, points: h, headline: d.steps.map { Double($0) }, headlineLabel: "Steps")
        case .activeCalories:
            guard let h = hours(d.hourlyCalories) else { return nil }
            return DaySeries(kind: .bars, points: h, headline: d.activeCalories, headlineLabel: "Active calories")
        case .totalCalories:
            guard let h = hours(d.hourlyCalories) else { return nil }
            let restingPerHour = profile.restingCalories(weightKg: weight(on: d.date)) / 24
            return DaySeries(kind: .bars, points: h.map { (time: $0.time, value: $0.value + restingPerHour) },
                             headline: Metric.totalCalories.value(d, in: self), headlineLabel: "Total calories")
        case .cardioLoad, .activeZoneMinutes:
            guard !d.heartRate.isEmpty else { return nil }
            let line = CardioLoad.timeline(d.heartRate, resting: zoneScale(for: d).resting, max: profile.maxHeartRate)
            let pick: ((time: Date, load: Double, azm: Double)) -> Double = { m == .cardioLoad ? $0.load : $0.azm }
            let day = m == .cardioLoad ? d.cardioLoad : d.activeZoneMinutes
            // The shape comes from the heart rate kept for charts (5-minute averages); scaled so the
            // day ends on the same total as everywhere else.
            let raw = line.last.map(pick) ?? 0
            let scale = raw > 0 ? (day ?? raw) / raw : 1
            return DaySeries(kind: .running, points: line.map { (time: $0.time, value: pick($0) * scale) },
                             headline: day ?? raw, headlineLabel: m == .cardioLoad ? "Cardio load" : "Active Zone Minutes")
        default:
            return nil
        }
    }

    /// Heart rate readings between two times, across day boundaries (a night spans two days).
    func heartSamples(from start: Date, to end: Date) -> [HeartSample] {
        let cal = Calendar.current
        return [cal.startOfDay(for: start), cal.startOfDay(for: end)]
            .reduce(into: [Date]()) { if !$0.contains($1) { $0.append($1) } }
            .compactMap { day($0) }
            .flatMap(\.heartRate)
            .filter { $0.time >= start && $0.time <= end }
            .sorted { $0.time < $1.time }
    }

    func nights(endingOn date: Date, count: Int) -> [ScoreEngine.Night] {
        ScoreEngine.nights(days: days, endingOn: date, count: count, needHours: targets.sleepNeedHours)
    }

    /// Latest known weight on or before the day (scale data first, then Settings).
    func weight(on date: Date) -> Double {
        days.last { $0.date <= date && $0.weightKg != nil }?.weightKg ?? profile.weightKg
    }

    /// Resting calories for the day; today only counts the hours so far.
    func restingCalories(_ d: DayMetrics) -> Double {
        let full = profile.restingCalories(weightKg: weight(on: d.date))
        guard Calendar.current.isDateInToday(d.date) else { return full }
        let elapsed = Date().timeIntervalSince(d.date) / 86_400
        return full * min(1, max(0, elapsed))
    }

    // MARK: Day selection

    var canGoBack: Bool { selectedDate > firstDate }
    var canGoForward: Bool { !isTodaySelected }

    func select(_ date: Date) {
        let d = Calendar.current.startOfDay(for: date)
        selectedDate = min(Calendar.current.startOfDay(for: .now), max(firstDate, d))
    }

    func step(_ delta: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate) else { return }
        select(d)
    }

    // MARK: Sync

    func sync() async {
        guard !isSyncing else { return }
        guard source.isConnected else {
            days = SampleData.days(count: Self.historyDays)
            publishWidget()
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let reading = source
            // Six months once a day (and the first time); in between only the last ten days, which
            // is all that changes, so a sync takes seconds rather than a minute.
            let lastFull = UserDefaults.standard.object(forKey: Self.lastFullSyncKey) as? Date
            let full = days.isEmpty || lastFull.map { Date().timeIntervalSince($0) > 20 * 3600 } ?? true
            // Heart rate: only what came in after the last reading the app already has (with ten
            // minutes of overlap), not whole days again.
            let heartSince = days.compactMap { d in d.minuteHeartRate.flatMap { HeartMinutes.latest($0, day: d.date) } }
                .max().map { $0.addingTimeInterval(-10 * 60) }
            let (fresh, report) = try await reading.client(profile: profile, heartSince: heartSince)
                .fetchDays(full ? Self.historyDays : Self.recentDays, maxHeartRate: profile.maxHeartRate)
            // The source changed while this sync ran: its data belongs to the old one, so read the new one.
            guard reading == source else {
                isSyncing = false
                await sync()
                return
            }
            // Merge into what the app already has: days the sync didn't cover stay, anything a sync
            // didn't bring back for a day (a type that failed, or isn't in yet) keeps its value, and
            // new heart-rate minutes are laid over the stored ones.
            var merged = byDate
            for f in fresh { merged[f.date] = f.filling(from: byDate[f.date]) }
            // Each recent day's load, zone minutes and chart line are then worked out from all the
            // heart rate kept for it, always the same way, so they only change when readings arrive.
            let cal = Calendar.current
            let keepFrom = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: .now)) ?? .distantPast
            for (date, var d) in merged {
                guard date >= keepFrom else {
                    if d.minuteHeartRate != nil { d.minuteHeartRate = nil; merged[date] = d }
                    continue
                }
                let resting = GoogleHealthClient.restingHeartRate(on: date, in: merged)
                if let minutes = d.minuteHeartRate, minutes.contains(where: { $0 > 0 }) {
                    let samples = HeartMinutes.samples(minutes, day: date)
                    let worked = CardioLoad.fromHeartRate(samples, resting: resting, max: profile.maxHeartRate)
                    d.heartLoad = worked.load
                    d.heartZones = worked.zones
                    d.heartRate = GoogleHealthClient.fiveMinuteAverages(samples)
                } else if !d.heartRate.isEmpty {
                    // days stored before minutes were kept: their 5-minute averages
                    let worked = CardioLoad.fromHeartRate(d.heartRate, resting: resting, max: profile.maxHeartRate, maxGap: 300)
                    d.heartLoad = worked.load
                    d.heartZones = worked.zones
                }
                merged[date] = d
            }
            let cutoff = Calendar.current.date(byAdding: .day, value: -(Self.historyDays - 1),
                                               to: Calendar.current.startOfDay(for: .now)) ?? .distantPast
            let all = merged.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
            syncReport = report
            days = all
            lastError = nil
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: Self.lastSyncKey)
            if full { UserDefaults.standard.set(lastSync, forKey: Self.lastFullSyncKey) }
            Self.saveCache(all)
            publishWidget()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Read from another source. Its days replace the old ones rather than mixing with them:
    /// bands measure things differently (HRV above all), so baselines start again.
    func switchSource(_ new: DataSource) async {
        guard new != source else { return }
        DataSource.current = new
        source = new
        syncReport = []
        try? FileManager.default.removeItem(at: Self.cacheURL)
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        lastError = nil
        days = isSample ? SampleData.days(count: Self.historyDays) : []
        selectedDate = Calendar.current.startOfDay(for: .now)
        publishWidget()
        await sync()
    }

    /// Called after connecting or disconnecting the account.
    func accountChanged() async {
        selectedDate = Calendar.current.startOfDay(for: .now)
        if isSample {
            try? FileManager.default.removeItem(at: Self.cacheURL)
            lastSync = nil
            lastError = nil
        }
        await sync()
    }

    // MARK: Internals

    private func rebuildIndex() {
        byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        var cache: [Date: Scores] = [:]
        for (i, d) in days.enumerated() {
            // only the 30 days before each day matter for its baseline
            let history = Array(days[max(0, i - ScoreEngine.baselineDays)...i])
            cache[d.date] = ScoreEngine.scores(for: d, history: history, targets: targets)
        }
        scoreCache = cache
    }

    private func publishWidget() {
        let today = Calendar.current.startOfDay(for: .now)
        guard let d = day(today) ?? days.last else { return }
        let s = scores(for: d.date)
        WidgetSnapshot.save(WidgetSnapshot(date: d.date, recovery: s.recovery, effort: s.effort, sleep: s.sleep,
                                           minutesAsleep: d.sleep?.minutesAsleep, hrv: d.hrv,
                                           restingHeartRate: d.restingHeartRate, steps: d.steps,
                                           balance: balance(for: d.date), isSample: isSample))
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// One day with its scores, for lists and charts.
struct DayScore: Identifiable {
    let day: DayMetrics
    let scores: Scores
    var id: Date { day.date }
}
