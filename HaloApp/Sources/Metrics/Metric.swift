import SwiftUI

/// Every number Halo can graph. Tiles, lists and the graph page all read from here.
enum Metric: String, CaseIterable, Identifiable, Hashable {
    case recovery, effort, sleepScore
    case hrv, restingHeartRate, vo2Max
    case respiratoryRate, spo2, skinTemp
    case sleepDuration
    case steps, cardioLoad, activeZoneMinutes, activeCalories, restingCalories, totalCalories
    case weight

    var id: String { rawValue }

    enum Style { case line, bar }

    var title: String {
        switch self {
        case .recovery: return "Recovery"
        case .effort: return "Effort"
        case .sleepScore: return "Sleep score"
        case .hrv: return "Heart rate variability"
        case .restingHeartRate: return "Resting heart rate"
        case .vo2Max: return "Cardio fitness"
        case .respiratoryRate: return "Respiratory rate"
        case .spo2: return "Blood oxygen"
        case .skinTemp: return "Skin temperature"
        case .sleepDuration: return "Time asleep"
        case .steps: return "Steps"
        case .cardioLoad: return "Cardio load"
        case .activeZoneMinutes: return "Active Zone Minutes"
        case .activeCalories: return "Active calories"
        case .restingCalories: return "Resting calories"
        case .totalCalories: return "Total calories"
        case .weight: return "Weight"
        }
    }

    /// The ring a score metric belongs to, for its "what goes into it" breakdown.
    var scoreKind: ScoreKind? {
        switch self {
        case .recovery: return .recovery
        case .effort: return .effort
        case .sleepScore: return .sleep
        default: return nil
        }
    }

    var shortTitle: String {
        switch self {
        case .hrv: return "HRV"
        case .restingHeartRate: return "Resting HR"
        case .sleepDuration: return "Asleep"
        case .cardioLoad: return "Cardio load"
        case .activeZoneMinutes: return "AZM"
        default: return title
        }
    }

    var unit: String {
        switch self {
        case .recovery, .effort, .sleepScore: return "%"
        case .hrv: return "ms"
        case .restingHeartRate: return "bpm"
        case .vo2Max: return "VO₂ max"
        case .respiratoryRate: return "br/min"
        case .spo2: return "%"
        case .skinTemp: return "°C"
        case .sleepDuration: return ""
        case .steps: return "steps"
        case .cardioLoad: return ""
        case .activeZoneMinutes: return "min"
        case .activeCalories, .restingCalories, .totalCalories: return "kcal"
        case .weight: return "kg"
        }
    }

    var style: Style {
        switch self {
        case .steps, .cardioLoad, .activeZoneMinutes, .activeCalories, .restingCalories, .totalCalories, .sleepDuration: return .bar
        default: return .line
        }
    }

    /// Whether a rise is good news (drives arrow colors).
    var higherIsBetter: Bool? {
        switch self {
        case .restingHeartRate: return false
        case .skinTemp, .weight, .respiratoryRate, .restingCalories: return nil
        default: return true
        }
    }

    /// Show the personal normal range on the graph.
    var showsRange: Bool {
        switch self {
        case .hrv, .restingHeartRate, .respiratoryRate, .spo2, .skinTemp: return true
        default: return false
        }
    }

    /// The smallest normal-range half-width that makes sense for this metric.
    var minimumBand: Double {
        switch self {
        case .hrv: return 6
        case .restingHeartRate: return 2
        case .respiratoryRate: return 0.6
        case .spo2: return 1
        case .skinTemp: return 0.5
        default: return 0
        }
    }

    var about: String {
        switch self {
        case .recovery: return "How ready your body is today. Set once, in the morning, from last night: your heart rate variability and resting heart rate against your own last 30 days, and how well you slept. It doesn't change as the day goes on."
        case .effort: return "How much you've done today. It starts at zero at midnight and fills up as you move: today's cardio load against today's target, and your steps. Today's target is a day's share of this week's cardio load target, higher when you're well recovered and lower when you're not. Cardio load is the week; Effort is just today."
        case .sleepScore: return "How well last night restored you: time asleep against your need, the share in deep and REM sleep, how much of your time in bed you slept, and how close your bedtime was to your usual one."
        case .hrv: return "The variation between heartbeats while you sleep. Higher than your normal usually means you've recovered well."
        case .restingHeartRate: return "Your lowest steady heart rate. A rise of a few beats can be an early sign of stress, illness or fatigue."
        case .vo2Max: return "An estimate of how well your body uses oxygen during exercise. It moves slowly, over weeks."
        case .respiratoryRate: return "Breaths per minute while you sleep. It's very stable, so a change is worth noticing."
        case .spo2: return "How much oxygen your blood carries overnight. Most people sit between 95% and 100%."
        case .skinTemp: return "Change from your personal baseline overnight. A jump can come before you feel unwell."
        case .sleepDuration: return "Time actually asleep, not counting time awake in bed."
        case .steps: return "Every step your Fitbit counted during the day."
        case .cardioLoad: return "How hard your heart worked. Every minute your heart rate is in one of Fitbit's zones adds to it, and harder minutes add more: about 1 a minute in fat burn, 2 in cardio and 3 in peak. So 30 minutes of running in the cardio zone is about 55. It adds up over the week, from Monday or Sunday (set in Settings), towards a target based on your last four weeks: Maintain keeps it level, Build adds 10%, Recover lowers it when your recovery is low or you've been doing much more than usual."
        case .activeZoneMinutes: return "Minutes in your fat-burn, cardio or peak heart-rate zones. Cardio and peak minutes count double."
        case .activeCalories: return "Energy burned by moving, on top of what your body uses at rest."
        case .restingCalories: return "Energy your body uses at rest, worked out from your height, weight, age and sex."
        case .totalCalories: return "Active plus resting calories: everything you burned in the day."
        case .weight: return "From your Fitbit-connected scale or the weight in Settings."
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .recovery, .effort, .sleepScore: return "\(Int((v * 100).rounded()))"
        case .skinTemp: return (v >= 0 ? "+" : "−") + String(format: "%.1f", abs(v))
        case .spo2, .respiratoryRate, .weight: return String(format: "%.1f", v)
        case .sleepDuration: return Format.duration(v)
        case .steps, .activeCalories, .restingCalories, .totalCalories: return Int(v.rounded()).formatted()
        default: return "\(Int(v.rounded()))"
        }
    }

    /// The day's value. Scores and calories come from the store, everything else from the day.
    @MainActor
    func value(_ d: DayMetrics, in store: HealthStore) -> Double? {
        switch self {
        case .recovery: return store.scores(for: d.date).recovery
        case .effort: return store.scores(for: d.date).effort
        case .sleepScore: return store.scores(for: d.date).sleep
        case .hrv: return d.hrv
        case .restingHeartRate: return d.restingHeartRate
        case .vo2Max: return d.vo2Max
        case .respiratoryRate: return d.respiratoryRate
        case .spo2: return d.spo2
        case .skinTemp: return d.skinTempDelta
        case .sleepDuration: return d.sleep?.minutesAsleep
        case .steps: return d.steps.map { Double($0) }
        case .cardioLoad: return d.cardioLoad
        case .activeZoneMinutes: return d.activeZoneMinutes
        case .activeCalories: return d.activeCalories
        case .restingCalories: return store.restingCalories(d)
        case .totalCalories: return d.activeCalories.map { $0 + store.restingCalories(d) }
        case .weight: return d.weightKg
        }
    }
}

/// Graph time spans.
enum ChartSpan: String, CaseIterable, Identifiable {
    case week = "1W", month = "1M", threeMonths = "3M", sixMonths = "6M"

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .threeMonths: return 91
        case .sixMonths: return 182
        }
    }

    /// Long spans are drawn as one vertical line per week (lowest to highest day, dot at the average).
    var isWeekly: Bool { self == .threeMonths || self == .sixMonths }

    var name: String {
        switch self {
        case .week: return "week"
        case .month: return "month"
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        }
    }
}

/// Your normal range: mean ± 1.5 standard deviations of the last 30 days.
struct NormalRange {
    let low: Double
    let high: Double

    init?(values: [Double], minimumBand: Double) {
        guard values.count >= 5, let mean = ScoreEngine.mean(values) else { return nil }
        let sd = sqrt(values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
        let band = max(1.5 * sd, minimumBand)
        low = mean - band
        high = mean + band
    }

    func contains(_ v: Double) -> Bool { v >= low && v <= high }
}
