import Foundation
import WidgetKit

/// What the widget shows. The app writes it to the App Group after every sync.
struct WidgetSnapshot: Codable, Hashable {
    var date: Date
    var recovery: Double?
    var effort: Double?
    var sleep: Double?
    var minutesAsleep: Double?
    var hrv: Double?
    var restingHeartRate: Double?
    var steps: Int?
    var readiness: Double?
    var bedtime: Date?               // suggested for tonight
    var balance: [BalanceAxis]
    var isSample: Bool

    static let appGroup = "group.com.ralphgeb.halo"     // must match project.yml
    static let widgetKind = "HaloRings"
    static let balanceKind = "HaloBalance"
    static let forecastKind = "HaloForecast"
    private static let key = "widgetSnapshot"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard load() != snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)   // only when something changed
        WidgetCenter.shared.reloadTimelines(ofKind: balanceKind)
        WidgetCenter.shared.reloadTimelines(ofKind: forecastKind)
    }

    /// Built from sample data, for the widget gallery and first launch.
    static var sample: WidgetSnapshot {
        let days = SampleData.days()
        let today = days.last ?? DayMetrics(date: .now)
        let targets = Targets()
        let s = ScoreEngine.scores(for: today, history: days, targets: targets)
        let balance = ScoreEngine.balance(days: days, endingOn: today.date, targets: targets) {
            ScoreEngine.scores(for: $0, history: days, targets: targets)
        }
        return WidgetSnapshot(date: .now, recovery: s.recovery, effort: s.effort, sleep: s.sleep,
                              minutesAsleep: today.sleep?.minutesAsleep, hrv: today.hrv,
                              restingHeartRate: today.restingHeartRate, steps: today.steps,
                              readiness: s.recovery.map { 0.7 * $0 + 0.3 * (s.sleep ?? $0) },
                              bedtime: ScoreEngine.bedtime(days: days, endingOn: today.date, needHours: targets.sleepNeedHours),
                              balance: balance, isSample: true)
    }
}
