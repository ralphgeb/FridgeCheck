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
    var isSample: Bool

    static let appGroup = "group.com.ralphgeb.halo"     // must match project.yml
    static let widgetKind = "HaloRings"
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
    }

    /// Built from sample data, for the widget gallery and first launch.
    static var sample: WidgetSnapshot {
        let days = SampleData.days()
        let today = days.last ?? DayMetrics(date: .now)
        let s = ScoreEngine.scores(for: today, history: days, targets: Targets())
        return WidgetSnapshot(date: .now, recovery: s.recovery, effort: s.effort, sleep: s.sleep,
                              minutesAsleep: today.sleep?.minutesAsleep, hrv: today.hrv,
                              restingHeartRate: today.restingHeartRate, steps: today.steps, isSample: true)
    }
}
