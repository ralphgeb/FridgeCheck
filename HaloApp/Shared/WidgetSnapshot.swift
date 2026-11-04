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
    var balance: [BalanceAxis]
    var isSample: Bool
    // For the newer widgets (optional, so a snapshot saved before them still reads)
    /// The last seven nights against each night's need, oldest first.
    var nights: [Night]? = nil
    /// Last night: when it started and ended, its stages in order, and minutes in each.
    var lastNight: NightStages? = nil
    /// HRV, resting heart rate, breathing, SpO₂ and skin temperature against your normal.
    var vitals: [Vital]? = nil
    /// Today's heart rate, one reading per 15 minutes from midnight (nil where there's none).
    var heartToday: [Double?]? = nil
    var restingForChart: Double? = nil
    /// The last seven days' three scores, oldest first.
    var week: [DayScores]? = nil

    struct Night: Codable, Hashable {
        var date: Date
        var asleep: Double      // minutes
        var need: Double        // minutes
    }

    struct NightStages: Codable, Hashable {
        var start: Date
        var end: Date
        var stages: [Stage]
        var deep: Double
        var light: Double
        var rem: Double
        var awake: Double
        var score: Double?
        var asleep: Double
    }

    struct Stage: Codable, Hashable {
        var kind: SleepStageKind
        var start: Date
        var end: Date
    }

    struct Vital: Codable, Hashable, Identifiable {
        var name: String
        var value: String
        var unit: String
        /// -1 under your normal, 0 inside it, 1 over it (nil: not enough days yet)
        var position: Int?
        var concerning: Bool
        var points: [Double]
        var id: String { name }
    }

    struct DayScores: Codable, Hashable {
        var date: Date
        var recovery: Double?
        var effort: Double?
        var sleep: Double?
    }

    static let appGroup = "group.com.ralphgeb.halo"     // must match project.yml
    static let widgetKind = "HaloRings"
    static let balanceKind = "HaloBalance"
    static let sleepBankKind = "HaloSleepBank"
    static let sleepStagesKind = "HaloSleepStages"
    static let vitalsKind = "HaloVitals"
    static let heartKind = "HaloHeart"
    static let weekKind = "HaloWeek"
    static var allKinds: [String] { [widgetKind, balanceKind, sleepBankKind, sleepStagesKind, vitalsKind, heartKind, weekKind] }
    private static let key = "widgetSnapshot"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard load() != snapshot, let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key)
        // only when something changed
        for kind in allKinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
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
        var snap = WidgetSnapshot(date: .now, recovery: s.recovery, effort: s.effort, sleep: s.sleep,
                                  minutesAsleep: today.sleep?.minutesAsleep, hrv: today.hrv,
                                  restingHeartRate: today.restingHeartRate, steps: today.steps,
                                  balance: balance, isSample: true)
        snap.fill(days: days, targets: targets) { ScoreEngine.scores(for: $0, history: days, targets: targets) }
        return snap
    }

    /// Fills in the newer widgets' parts from the days (the vitals come from the app, which knows
    /// each one's normal range).
    mutating func fill(days: [DayMetrics], targets: Targets, scores: (DayMetrics) -> Scores) {
        let cal = Calendar.current
        let end = cal.startOfDay(for: date)
        let recent = days.filter { $0.date <= end }.suffix(7)
        nights = recent.compactMap { d in
            d.sleep.map { Night(date: d.date, asleep: $0.minutesAsleep, need: d.sleepNeedMinutes ?? targets.sleepNeedHours * 60) }
        }
        week = recent.map { d in
            let s = scores(d)
            return DayScores(date: d.date, recovery: s.recovery, effort: s.effort, sleep: s.sleep)
        }
        if let d = days.last(where: { $0.date <= end && $0.sleep != nil }), let s = d.sleep {
            lastNight = NightStages(start: s.start, end: s.end,
                                    stages: s.stages.map { Stage(kind: $0.kind, start: $0.start, end: $0.end) },
                                    deep: s.minutes(.deep), light: s.minutes(.light), rem: s.minutes(.rem),
                                    awake: s.stages.isEmpty ? s.minutesAwake : s.minutes(.awake),
                                    score: scores(d).sleep, asleep: s.minutesAsleep)
        }
        if let today = days.last(where: { $0.date == end }) {
            var slots = [Double?](repeating: nil, count: 96)
            for (i, group) in Dictionary(grouping: today.heartRate, by: { Int($0.time.timeIntervalSince(end) / 900) }) where i >= 0 && i < 96 {
                slots[i] = ScoreEngine.mean(group.map(\.bpm))
            }
            heartToday = slots.contains { $0 != nil } ? slots : nil
            restingForChart = today.restingHeartRate ?? days.last { $0.restingHeartRate != nil }?.restingHeartRate
        }
    }
}
