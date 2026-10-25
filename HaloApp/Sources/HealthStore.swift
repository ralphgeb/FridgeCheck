import Foundation
import SwiftUI

/// The app's single source of truth: the last few weeks of days, the scores, and sync state.
@MainActor
final class HealthStore: ObservableObject {
    @Published private(set) var days: [DayMetrics] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published var selectedDate = Calendar.current.startOfDay(for: .now)
    @Published var targets: Targets { didSet { saveTargets() } }

    /// True while no Fitbit account is connected: the app runs on sample data.
    var isSample: Bool { !GoogleAuth.shared.isConnected }

    private static let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("days.json")
    private static let targetsKey = "targets"
    private static let lastSyncKey = "lastSync"
    static let historyDays = 35

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.targetsKey),
           let t = try? JSONDecoder().decode(Targets.self, from: data) {
            targets = t
        } else {
            targets = Targets()
        }
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        if isSample {
            days = SampleData.days(count: Self.historyDays)
        } else if let data = try? Data(contentsOf: Self.cacheURL),
                  let cached = try? JSONDecoder().decode([DayMetrics].self, from: data) {
            days = cached
        }
        publishWidget()
    }

    // MARK: Reading

    func day(_ date: Date) -> DayMetrics? {
        days.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    var selectedDay: DayMetrics { day(selectedDate) ?? DayMetrics(date: selectedDate) }

    func scores(for date: Date) -> Scores {
        guard let d = day(date) else { return Scores() }
        return ScoreEngine.scores(for: d, history: days, targets: targets)
    }

    /// The last `count` days ending on `date`, oldest first, with their scores.
    func week(endingOn date: Date, count: Int = 7) -> [DayScore] {
        let cal = Calendar.current
        return (0..<count).reversed().compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: date), let item = self.day(d) else { return nil }
            return DayScore(day: item, scores: ScoreEngine.scores(for: item, history: days, targets: targets))
        }
    }

    /// Mean of a metric over the 30 days before `date` (the personal baseline).
    func baseline(_ metric: KeyPath<DayMetrics, Double?>, before date: Date) -> Double? {
        let values = days.filter { $0.date < Calendar.current.startOfDay(for: date) }.suffix(30).compactMap { $0[keyPath: metric] }
        return ScoreEngine.mean(values)
    }

    var canGoBack: Bool { days.first.map { $0.date < selectedDate } ?? false }
    var canGoForward: Bool { selectedDate < Calendar.current.startOfDay(for: .now) }

    func step(_ delta: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate) else { return }
        selectedDate = min(Calendar.current.startOfDay(for: .now), d)
    }

    // MARK: Sync

    func sync() async {
        guard !isSyncing else { return }
        guard GoogleAuth.shared.isConnected else {
            days = SampleData.days(count: Self.historyDays)
            publishWidget()
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let client = GoogleHealthClient(token: { try await GoogleAuth.shared.accessToken() })
            let fresh = try await client.fetchDays(Self.historyDays)
            days = fresh
            lastError = nil
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: Self.lastSyncKey)
            try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(fresh).write(to: Self.cacheURL, options: .atomic)
            publishWidget()
        } catch {
            lastError = error.localizedDescription
        }
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

    // MARK: Widget

    private func publishWidget() {
        let today = Calendar.current.startOfDay(for: .now)
        guard let d = day(today) ?? days.last else { return }
        let s = ScoreEngine.scores(for: d, history: days, targets: targets)
        WidgetSnapshot.save(WidgetSnapshot(date: d.date, recovery: s.recovery, effort: s.effort, sleep: s.sleep,
                                           minutesAsleep: d.sleep?.minutesAsleep, hrv: d.hrv,
                                           restingHeartRate: d.restingHeartRate, steps: d.steps, isSample: isSample))
    }

    private func saveTargets() {
        if let data = try? JSONEncoder().encode(targets) { UserDefaults.standard.set(data, forKey: Self.targetsKey) }
        publishWidget()
    }
}

/// One day with its scores, for lists and charts.
struct DayScore: Identifiable {
    let day: DayMetrics
    let scores: Scores
    var id: Date { day.date }
}
