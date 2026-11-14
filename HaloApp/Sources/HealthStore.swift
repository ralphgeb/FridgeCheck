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
    /// Activities you added by hand (the band missed them). Kept on the phone, apart from any source.
    @Published private(set) var manualWorkouts: [Workout] { didSet { save(manualWorkouts, Self.manualKey) } }

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
    /// True while the days on screen are sample data: before connecting, and after connecting
    /// until the first sync brings your own. Your data never mixes with them.
    @Published private(set) var showingSample = false

    private var byDate: [Date: DayMetrics] = [:]
    private var scoreCache: [Date: Scores] = [:]

    /// Each source keeps its own days on the phone, so switching between them is instant (the
    /// new one shows what it had, then catches up) and their numbers never mix.
    private static func cacheURL(_ s: DataSource) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("days-\(s.rawValue).json")
    }
    private var cacheURL: URL { Self.cacheURL(source) }
    /// Where all sources' days used to be kept, before each had its own.
    private static let oldCacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("days.json")
    private static let targetsKey = "targets.v3"
    private static let profileKey = "profile"
    private static let overridesKey = "activityOverrides"
    private static let manualKey = "manualWorkouts"
    private var lastSyncKey: String { "lastSync.\(source.rawValue)" }
    private var lastFullSyncKey: String { "lastFullSync.\(source.rawValue)" }
    private static let cleanCacheKey = "cache.noSample.v1"
    /// A year of days (or as much as the band has).
    static let historyDays = 365
    static let recentDays = 10
    /// The first sync's quick pass: enough for this week's graphs and a start on baselines.
    static let firstPassDays = 14

    init() {
        targets = Self.load(Targets.self, Self.targetsKey) ?? Targets()
        profile = Self.load(Profile.self, Self.profileKey) ?? Profile()
        activityOverrides = Self.load([String: ActivityType].self, Self.overridesKey) ?? [:]
        manualWorkouts = Self.load([Workout].self, Self.manualKey) ?? []
        // the one file all sources used to share becomes the current source's
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.oldCacheURL.path) {
            if !fm.fileExists(atPath: Self.cacheURL(DataSource.current).path) {
                try? fm.moveItem(at: Self.oldCacheURL, to: Self.cacheURL(DataSource.current))
            } else {
                try? fm.removeItem(at: Self.oldCacheURL)
            }
        }
        lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        // Days saved while sample data could still mix into a Whoop sync are read again from Whoop.
        if DataSource.current == .whoop, !UserDefaults.standard.bool(forKey: Self.cleanCacheKey) {
            try? FileManager.default.removeItem(at: cacheURL)
            UserDefaults.standard.removeObject(forKey: lastFullSyncKey)
        }
        UserDefaults.standard.set(true, forKey: Self.cleanCacheKey)
        if isSample {
            days = SampleData.days(count: Self.historyDays)
            showingSample = true
        } else if let cached = Self.loadCache(cacheURL) {
            days = cached
        }
        rebuildIndex()
        publishWidget()
    }

    /// The days the app keeps on the phone, so it opens straight onto your data. A day that can't
    /// be read is skipped rather than losing all of them.
    private static func loadCache(_ url: URL) -> [DayMetrics]? {
        guard let data = try? Data(contentsOf: url),
              let list = try? decoder.decode([LossyDay].self, from: data) else { return nil }
        let days = list.compactMap(\.day)
        return days.isEmpty ? nil : days
    }

    /// Saves the days; returns why not if it couldn't. (A single odd number, like a value that
    /// isn't a number at all, used to make the whole save fail silently, so the app opened empty.)
    @discardableResult
    /// Lays a sync's fresh days over the stored ones and works out each recent day's load, zones
    /// and chart line from all its heart rate, then saves. Days the sync didn't cover stay, and
    /// anything a sync didn't bring back for a day (a type that failed, or isn't in yet) keeps its
    /// value. Runs off the main thread.
    nonisolated private static func merge(base: [Date: DayMetrics], fresh: [DayMetrics], maxHeartRate: Double,
                                          loadFromHeart: Bool, historyDays: Int, saveTo url: URL) -> ([DayMetrics], String?) {
        var merged = base
        for f in fresh { merged[f.date] = f.filling(from: base[f.date]) }
        let cal = Calendar.current
        let keepFrom = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: .now)) ?? .distantPast
        for (date, var d) in merged {
            guard date >= keepFrom else {
                if d.minuteHeartRate != nil { d.minuteHeartRate = nil; merged[date] = d }
                continue
            }
            let resting = GoogleHealthClient.restingHeartRate(on: date, in: merged)
            // Whoop's heart rate (through Apple Health) covers sleep and workouts only, so its
            // load and zones come from Whoop's own zones; the readings are for the charts.
            if let minutes = d.minuteHeartRate, minutes.contains(where: { $0 > 0 }) {
                let samples = HeartMinutes.samples(minutes, day: date)
                if loadFromHeart {
                    let worked = CardioLoad.fromHeartRate(samples, resting: resting, max: maxHeartRate)
                    d.heartLoad = worked.load
                    d.heartZones = worked.zones
                }
                d.heartRate = GoogleHealthClient.fiveMinuteAverages(samples)
            } else if loadFromHeart, !d.heartRate.isEmpty {
                // days stored before minutes were kept: their 5-minute averages
                let worked = CardioLoad.fromHeartRate(d.heartRate, resting: resting, max: maxHeartRate, maxGap: 300)
                d.heartLoad = worked.load
                d.heartZones = worked.zones
            }
            merged[date] = d
        }
        let cutoff = cal.date(byAdding: .day, value: -(historyDays - 1), to: cal.startOfDay(for: .now)) ?? .distantPast
        let all = merged.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        return (all, saveCache(all, to: url))
    }

    nonisolated private static func saveCache(_ days: [DayMetrics], to url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // readable after the first unlock, so a background refresh can update it with the phone locked
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            try encoder.encode(days).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()

    private struct LossyDay: Decodable {
        let day: DayMetrics?
        init(from decoder: Decoder) throws { day = try? DayMetrics(from: decoder) }
    }

    /// iOS sometimes syncs in the background (another copy of the store). Coming back to the app,
    /// pick up what it saved rather than waiting for a sync of our own.
    func reloadIfUpdatedElsewhere() {
        guard !isSyncing, !isSample,
              let saved = UserDefaults.standard.object(forKey: lastSyncKey) as? Date,
              saved > (lastSync ?? .distantPast),
              let cached = Self.loadCache(cacheURL) else { return }
        lastSync = saved
        showingSample = false
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
            .compactMap { d in metric.value(d, in: self).flatMap { $0.isFinite ? (date: d.date, value: $0) : nil } }
    }

    /// Your normal range for a metric: the 30 days before `date`.
    func normalRange(_ metric: Metric, before date: Date) -> NormalRange? {
        let end = Calendar.current.startOfDay(for: date)
        let values = days.filter { $0.date < end }.suffix(30).compactMap { metric.value($0, in: self) }.filter(\.isFinite)
        return NormalRange(values: values, minimumBand: metric.minimumBand)
    }

    /// Mean of a metric over the 30 days before `date` (the personal baseline).
    func baseline(_ metric: Metric, before date: Date) -> Double? {
        let end = Calendar.current.startOfDay(for: date)
        return ScoreEngine.mean(days.filter { $0.date < end }.suffix(30).compactMap { metric.value($0, in: self) }.filter(\.isFinite))
    }

    func balance(for date: Date, span: Int = 7) -> [BalanceAxis] {
        ScoreEngine.balance(days: days, endingOn: date, targets: targets, span: span) { self.scores(for: $0.date) }
    }

    /// Cardio load for the seven days ending on `date`, with this week's target and focus.
    func cardioWeek(endingOn date: Date) -> CardioLoad.Week {
        CardioLoad.week(days: days, endingOn: date, chosen: .auto, recovery: scores(for: date).recovery)
    }

    /// What went into one of the three scores on a day.
    func factors(_ kind: ScoreKind, on date: Date) -> [ScoreEngine.Factor] {
        guard let d = day(date) else { return [] }
        return ScoreEngine.factors(kind, day: d, history: Array(days.filter { $0.date < d.date }.suffix(ScoreEngine.baselineDays)) + [d], targets: targets)
    }

    // MARK: Fitness

    /// The day's workouts, as the band logged them.
    func activities(on date: Date) -> [Workout] {
        let added = manualWorkouts.filter { Calendar.current.isDate($0.start, inSameDayAs: date) }
        return ((day(date)?.workouts ?? []) + added).sorted { $0.start < $1.start }
    }

    /// Adds an activity the band missed, at the time it happened. Its average heart rate comes
    /// from the day's readings, when there are some.
    func addWorkout(_ type: ActivityType, start: Date, minutes: Double, calories: Double?) {
        let end = start.addingTimeInterval(minutes * 60)
        let readings = (day(start)?.heartRate ?? []).filter { $0.time >= start && $0.time <= end }.map(\.bpm)
        manualWorkouts.append(Workout(id: "manual-\(UUID().uuidString)", kind: type.rawValue, start: start, end: end,
                                      calories: calories, averageHeartRate: ScoreEngine.mean(readings), distanceKm: nil))
    }

    func removeWorkout(_ w: Workout) { manualWorkouts.removeAll { $0.id == w.id } }

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

    /// Whether the last two weeks have nights with their stages (Whoop shares totals only).
    var hasSleepStages: Bool {
        let from = Calendar.current.date(byAdding: .day, value: -14, to: selectedDate) ?? selectedDate
        return days.contains { $0.date >= from && $0.date <= selectedDate && !($0.sleep?.stages.isEmpty ?? true) }
    }

    /// Whether at least two of the last two weeks' days have heart rate (Whoop without Apple
    /// Health has none).
    var hasHeartRateDays: Bool {
        let from = Calendar.current.date(byAdding: .day, value: -14, to: selectedDate) ?? selectedDate
        return days.filter { $0.date >= from && $0.date <= selectedDate && !$0.heartRate.isEmpty }.count >= 2
    }

    func nights(endingOn date: Date, count: Int) -> [ScoreEngine.Night] {
        ScoreEngine.nights(days: days, endingOn: date, count: count, needHours: targets.sleepNeedHours)
    }

    /// Latest known weight on or before the day (scale data first, then Settings).
    func weight(on date: Date) -> Double {
        days.last { $0.date <= date && $0.weightKg != nil }?.weightKg ?? profile.weightKg
    }

    /// A running total through the day, from 0 at midnight, one value per hour so far (all 24 for
    /// an earlier day): steps and calories as they build up. nil without hour-by-hour data.
    func runningTotal(_ m: Metric, on date: Date) -> [Double]? {
        guard let d = day(date) else { return nil }
        let cal = Calendar.current
        let hoursSoFar = cal.isDateInToday(d.date) ? min(24, max(0, Date.now.timeIntervalSince(d.date) / 3600)) : 24
        let count = max(1, Int(hoursSoFar.rounded(.up)))
        let restingPerHour = profile.restingCalories(weightKg: weight(on: d.date)) / 24
        func running(_ hourly: [Double]?, plus extra: Double) -> [Double]? {
            guard let hourly, !hourly.isEmpty else { return nil }
            var out = [0.0]
            var total = 0.0
            for h in 0..<count {
                let share = min(1, hoursSoFar - Double(h))      // the hour we're in counts in part for resting
                total += (h < hourly.count ? hourly[h] : 0) + extra * max(0, share)
                out.append(total)
            }
            return out
        }
        switch m {
        case .steps: return running(d.hourlySteps, plus: 0)
        case .activeCalories: return running(d.hourlyCalories, plus: 0)
        case .totalCalories: return running(d.hourlyCalories, plus: restingPerHour)
        case .restingCalories: return running([Double](repeating: 0, count: 24), plus: restingPerHour)
        default: return nil
        }
    }

    /// Steps yesterday up to the same time of day as now (or the whole day before an earlier day).
    func stepsSameTimeDayBefore(_ date: Date) -> Double? {
        let cal = Calendar.current
        guard let before = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: date)) else { return nil }
        guard cal.isDateInToday(date) else { return day(before)?.steps.map { Double($0) } }
        guard let running = runningTotal(.steps, on: before) else { return nil }
        let hours = Date.now.timeIntervalSince(cal.startOfDay(for: .now)) / 3600
        let i = min(23, Int(hours)), part = hours - Double(i)
        return running[i] + (running[i + 1] - running[i]) * part
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

    /// Asks for Halo Plus (earlier days are part of it); RootView shows the sheet.
    @Published var showPlus = false
    /// Where a widget tap asked to go inside its tab ("/bank", "/zones"…); the tab takes it and clears it.
    @Published var deepLink: String?

    func select(_ date: Date) {
        let today = Calendar.current.startOfDay(for: .now)
        let d = min(today, max(firstDate, Calendar.current.startOfDay(for: date)))
        // without Halo Plus, only today: an earlier day opens Halo Plus instead
        if d < today && Plus.locked {
            showPlus = true
            return
        }
        selectedDate = d
    }

    /// Back to today when earlier days lock again (the paywall turned on, or Plus ended).
    func enforcePlus() {
        if Plus.locked && !isTodaySelected { selectedDate = Calendar.current.startOfDay(for: .now) }
    }

    func step(_ delta: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate) else { return }
        select(d)
    }

    // MARK: Sync

    /// `days` asks for that many days back instead of the usual (ten, or the year once a day).
    func sync(days override: Int? = nil) async {
        guard !isSyncing else { return }
        guard source.isConnected else {
            days = SampleData.days(count: Self.historyDays)
            showingSample = true
            publishWidget()
            return
        }
        // sample days are never a base for your own: start from nothing
        let base = showingSample ? [:] : byDate
        let stored = showingSample ? [] : days
        // The first time for this source: the last two weeks first, so your own days (and a week's
        // graphs) are up in seconds, then the rest of the year behind them.
        if stored.isEmpty && override == nil {
            await sync(days: Self.firstPassDays)
            if !showingSample, !days.isEmpty { await sync(days: Self.historyDays) }
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let reading = source
            // Six months once a day (and the first time); in between only the last ten days, which
            // is all that changes, so a sync takes seconds rather than a minute.
            let lastFull = UserDefaults.standard.object(forKey: lastFullSyncKey) as? Date
            let full = stored.isEmpty || lastFull.map { Date().timeIntervalSince($0) > 20 * 3600 } ?? true
            // Heart rate: only what came in after the last reading the app already has (with ten
            // minutes of overlap), not whole days again.
            let heartSince = stored.compactMap { d in d.minuteHeartRate.flatMap { HeartMinutes.latest($0, day: d.date) } }
                .max().map { $0.addingTimeInterval(-10 * 60) }
            let count = override ?? (full ? Self.historyDays : Self.recentDays)
            let (fresh, report) = try await reading.client(profile: profile, heartSince: heartSince)
                .fetchDays(count, maxHeartRate: profile.maxHeartRate)
            // The source changed while this sync ran: its data belongs to the old one, so read the new one.
            guard reading == source else {
                isSyncing = false
                await sync()
                return
            }
            // Merging, working out the heart-rate figures and saving take a moment with a year of
            // days: done away from the main thread, so the app never freezes while it syncs
            // (opening the calendar mid-sync used to hang it).
            let maxHeartRate = profile.maxHeartRate
            let loadFromHeart = reading != .whoop
            let url = cacheURL
            let keep = Self.historyDays
            let (all, saveError) = await Task.detached(priority: .userInitiated) {
                Self.merge(base: base, fresh: fresh, maxHeartRate: maxHeartRate,
                           loadFromHeart: loadFromHeart, historyDays: keep, saveTo: url)
            }.value
            // The source changed while it ran: its data belongs to the old one.
            guard reading == source else {
                isSyncing = false
                await sync()
                return
            }
            syncReport = report + [SyncReportLine(name: "Kept on this iPhone",
                                                  result: saveError.map { "Couldn't save: \($0)" } ?? "\(all.count) days",
                                                  ok: saveError == nil)]
            // only what changed is set, so a sync that found nothing new doesn't redraw every page
            if showingSample { showingSample = false }
            if all != days { days = all }
            if lastError != nil { lastError = nil }
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: lastSyncKey)
            if count >= Self.historyDays { UserDefaults.standard.set(lastSync, forKey: lastFullSyncKey) }
            publishWidget()
            await HaloNotifications.afterSync(self)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Read from another source. Each keeps its own days (bands measure things differently, HRV
    /// above all, so they never mix): the new one shows what it already had straight away, then
    /// catches up with only what's new.
    func switchSource(_ new: DataSource) async {
        guard new != source else { return }
        DataSource.current = new
        source = new
        syncReport = []
        lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        lastError = nil
        if isSample {
            days = SampleData.days(count: Self.historyDays)
            showingSample = true
        } else {
            days = Self.loadCache(cacheURL) ?? []
            showingSample = false
        }
        selectedDate = Calendar.current.startOfDay(for: .now)
        publishWidget()
        await sync()
    }

    /// Deletes everything Halo keeps on the phone: the saved days, the Whoop records and the sync
    /// history. Then reads it all again, or, with `startOver`, also signs out of every source and
    /// goes back to the welcome screens.
    func deleteAllData(startOver: Bool) async {
        for s in DataSource.allCases {
            try? FileManager.default.removeItem(at: Self.cacheURL(s))
            for key in ["lastSync.\(s.rawValue)", "lastFullSync.\(s.rawValue)"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        WhoopLedger.clear()
        syncReport = []
        lastError = nil
        lastSync = nil
        selectedDate = Calendar.current.startOfDay(for: .now)
        if startOver {
            for s in DataSource.allCases { s.disconnect() }
            UserDefaults.standard.set(false, forKey: "onboarded")
        }
        days = isSample ? SampleData.days(count: Self.historyDays) : []
        showingSample = isSample
        publishWidget()
        await sync()
    }

    /// Called after connecting or disconnecting the account.
    func accountChanged() async {
        selectedDate = Calendar.current.startOfDay(for: .now)
        if isSample {
            try? FileManager.default.removeItem(at: cacheURL)
            lastSync = nil
            lastError = nil
        }
        await sync()
    }

    // MARK: Internals

    private func rebuildIndex() {
        // each band's sleep stages against its own normal (Apple Watch calls less of the night deep)
        ScoreEngine.stageNorms = source == .appleHealth ? .appleWatch : .standard
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
        var snap = WidgetSnapshot(date: d.date, recovery: s.recovery, effort: s.effort, sleep: s.sleep,
                                  minutesAsleep: d.sleep?.minutesAsleep, hrv: d.hrv,
                                  restingHeartRate: d.restingHeartRate, steps: d.steps,
                                  balance: balance(for: d.date), isSample: isSample)
        snap.fill(days: days, targets: targets) { self.scores(for: $0.date) }
        snap.vitals = widgetVitals(on: d.date)
        WidgetSnapshot.save(snap)
    }

    /// The five overnight vitals for the widget: today's value, where it sits in your normal, and
    /// the last week as a line.
    private func widgetVitals(on date: Date) -> [WidgetSnapshot.Vital] {
        let names: [(Metric, String)] = [(.hrv, "HRV"), (.restingHeartRate, "RHR"), (.respiratoryRate, "Breath"),
                                         (.spo2, "SpO₂"), (.skinTemp, "Temp")]
        return names.compactMap { metric, name in
            let points = series(metric, days: 7, endingOn: date).map(\.value)
            guard let v = points.last else { return nil }
            let range = normalRange(metric, before: date)
            let position = range.map { v < $0.low ? -1 : (v > $0.high ? 1 : 0) }
            let gauge = range.map { r -> Double in
                let mid = (r.low + r.high) / 2, half = max((r.high - r.low) / 2, 0.0001)
                return min(1, max(-1, (v - mid) / half * 0.6))
            }
            return WidgetSnapshot.Vital(name: name, value: metric.format(v), unit: metric == .skinTemp ? "°" : metric.unit,
                                        position: position, concerning: range.map { metric.isConcerning(v, range: $0) } ?? false,
                                        points: points, gauge: gauge)
        }
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
