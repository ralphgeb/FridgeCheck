import Foundation

/// Sleep stages, in Fitbit's names (Apple's "core" and Whoop's "slow wave" map onto light and deep).
enum SleepStageKind: String, Codable, CaseIterable, Identifiable {
    case awake, rem, light, deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .awake: return "Awake"
        case .rem: return "REM"
        case .light: return "Light"
        case .deep: return "Deep"
        }
    }

    /// Row in the hypnogram, top to bottom.
    var depth: Int {
        switch self {
        case .awake: return 0
        case .rem: return 1
        case .light: return 2
        case .deep: return 3
        }
    }
}

struct SleepStage: Codable, Hashable {
    var kind: SleepStageKind
    var start: Date
    var end: Date

    var minutes: Double { end.timeIntervalSince(start) / 60 }
}

struct SleepSession: Codable, Hashable {
    var start: Date
    var end: Date
    var minutesAsleep: Double
    var minutesAwake: Double
    var stages: [SleepStage]
    /// Minutes in each stage, for bands that share totals but no timeline (Whoop).
    var stageTotals: [SleepStageKind: Double]?

    var minutesInBed: Double { end.timeIntervalSince(start) / 60 }
    var efficiency: Double { minutesInBed > 0 ? min(1, minutesAsleep / minutesInBed) : 0 }

    func minutes(_ kind: SleepStageKind) -> Double {
        if stages.isEmpty, let stageTotals { return stageTotals[kind] ?? 0 }
        return stages.filter { $0.kind == kind }.reduce(0) { $0 + $1.minutes }
    }

    /// Times you woke for at least 5 minutes.
    var wakeUps: Int {
        stages.filter { $0.kind == .awake && $0.minutes >= 5 }.count
    }

    /// Minutes from getting into bed to the first sleep stage.
    var minutesToFallAsleep: Double {
        guard let first = stages.first(where: { $0.kind != .awake }) else { return 0 }
        return max(0, first.start.timeIntervalSince(start) / 60)
    }
}

/// One exercise session, as your band logged it.
struct Workout: Codable, Hashable, Identifiable {
    var id: String
    var kind: String            // Fitbit's name for it (e.g. "RUNNING"), or Halo's activity type from Apple Health
    var start: Date
    var end: Date
    var calories: Double?
    var averageHeartRate: Double?
    var distanceKm: Double?

    var minutes: Double { end.timeIntervalSince(start) / 60 }
    var isExample: Bool { id.hasPrefix("example-") }
}

struct HeartSample: Codable, Hashable {
    var time: Date
    var bpm: Double
}

/// Everything Halo knows about one day. The day is the calendar day you woke up on.
struct DayMetrics: Codable, Hashable, Identifiable {
    var date: Date                       // start of the day, local time
    var steps: Int?
    var activeCalories: Double?
    var activeZoneMinutes: Double?
    var zoneMinutes: ZoneMinutes?        // time in each heart-rate zone, as Fitbit reports it
    var heartLoad: Double?               // cardio load worked out from the day's heart rate
    var heartZones: ZoneMinutes?         // zone minutes worked out from the day's heart rate
    var restingHeartRate: Double?
    var hrv: Double?                     // milliseconds: RMSSD from Fitbit, SDNN from Apple Watch
    var spo2: Double?                    // percent
    var respiratoryRate: Double?         // breaths per minute
    var skinTempDelta: Double?           // °C from personal baseline
    var vo2Max: Double?
    var weightKg: Double?
    var sleep: SleepSession?
    var workouts: [Workout]?             // exercise sessions logged by Fitbit
    var heartRate: [HeartSample]         // intraday, kept for the most recent days only
    var hourlySteps: [Double]?           // 24 hours, from midnight; recent days only
    var hourlyCalories: [Double]?        // active calories per hour, the same way

    var id: Date { date }

    /// Cardio load for the day. Best from the heart rate itself (minute by minute, against your
    /// resting heart rate), then from Fitbit's zone minutes, then estimated from Active Zone Minutes.
    var cardioLoad: Double? {
        if let heartLoad { return heartLoad }
        if let z = zoneMinutes, z.total > 0 { return CardioLoad.fromZones(z) }
        return activeZoneMinutes.map(CardioLoad.fromActiveZoneMinutes)
    }

    /// Minutes in each zone: Fitbit's own count (it matches the Fitbit app), else from the heart rate.
    var zones: ZoneMinutes? {
        if let z = zoneMinutes, z.total > 0 { return z }
        return heartZones
    }

    init(date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
        self.heartRate = []
    }

    /// This day from a new sync, with anything the sync didn't bring back kept from what the app
    /// already had, so a type that fails or comes back empty never wipes a value.
    func filling(from old: DayMetrics?) -> DayMetrics {
        guard let old else { return self }
        var d = self
        d.steps = steps ?? old.steps
        d.activeCalories = activeCalories ?? old.activeCalories
        d.activeZoneMinutes = activeZoneMinutes ?? old.activeZoneMinutes
        d.zoneMinutes = zoneMinutes ?? old.zoneMinutes
        d.heartLoad = heartLoad ?? old.heartLoad
        d.heartZones = heartZones ?? old.heartZones
        d.restingHeartRate = restingHeartRate ?? old.restingHeartRate
        d.hrv = hrv ?? old.hrv
        d.spo2 = spo2 ?? old.spo2
        d.respiratoryRate = respiratoryRate ?? old.respiratoryRate
        d.skinTempDelta = skinTempDelta ?? old.skinTempDelta
        d.vo2Max = vo2Max ?? old.vo2Max
        d.weightKg = weightKg ?? old.weightKg
        d.sleep = sleep ?? old.sleep
        d.workouts = workouts ?? old.workouts
        if d.heartRate.isEmpty { d.heartRate = old.heartRate }
        d.hourlySteps = hourlySteps ?? old.hourlySteps
        d.hourlyCalories = hourlyCalories ?? old.hourlyCalories
        return d
    }
}

/// One day of a metric for the 1D graphs: readings (heart rate), hourly bars (steps, calories) or
/// a running total (cardio load, zone minutes).
struct DaySeries {
    enum Kind { case line, bars, running }
    let kind: Kind
    let points: [(time: Date, value: Double)]
    /// The day's value, as shown everywhere else.
    let headline: Double?
    let headlineLabel: String
    var reference: (label: String, value: Double)? = nil
}

/// The three scores, each 0...1. Nil when there isn't enough data.
struct Scores: Codable, Hashable {
    var recovery: Double?
    var effort: Double?
    var sleep: Double?
}

/// Minutes spent in each of Fitbit's heart-rate zones.
struct ZoneMinutes: Codable, Hashable {
    var fatBurn: Double = 0
    var cardio: Double = 0
    var peak: Double = 0

    var total: Double { fatBurn + cardio + peak }

    /// Harder minutes count for more: fat burn ×¼, cardio ×2, peak ×3.
    var points: Double { 0.25 * fatBurn + 2 * cardio + 3 * peak }
}

/// The user's targets (set in Settings).
struct Targets: Codable, Hashable {
    var sleepNeedHours: Double = 7.5
    var steps: Double = 10_000
    var cardioFocus: CardioFocus = .auto
    /// Daily heart zone minutes, with cardio counting double and peak triple.
    var zoneMinutes: Double = 30

    init() {}

    // Settings saved by an older version keep their values; new ones start at the default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sleepNeedHours = try c.decodeIfPresent(Double.self, forKey: .sleepNeedHours) ?? 7.5
        steps = try c.decodeIfPresent(Double.self, forKey: .steps) ?? 10_000
        cardioFocus = try c.decodeIfPresent(CardioFocus.self, forKey: .cardioFocus) ?? .auto
        zoneMinutes = try c.decodeIfPresent(Double.self, forKey: .zoneMinutes) ?? 30
    }
}

/// What this week's cardio load target is for. Auto picks one from your recovery and recent load.
enum CardioFocus: String, Codable, CaseIterable, Identifiable {
    case auto, maintain, build, recover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .maintain: return "Maintain"
        case .build: return "Build"
        case .recover: return "Recover"
        }
    }

    /// How the target compares with your recent weekly average.
    var factor: Double {
        switch self {
        case .auto, .maintain: return 1
        case .build: return 1.1
        case .recover: return 0.75
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Halo picks a focus each week."
        case .maintain: return "Similar to your recent weeks, to stay consistent."
        case .build: return "A little above your recent weeks, to build fitness safely."
        case .recover: return "Below your recent weeks, so your body can adapt."
        }
    }
}

/// Body details, used for resting calories (Mifflin-St Jeor).
struct Profile: Codable, Hashable {
    enum Sex: String, Codable, CaseIterable, Identifiable {
        case male, female
        var id: String { rawValue }
        var title: String { self == .male ? "Male" : "Female" }
    }

    var sex: Sex = .male
    var birthYear: Int = 1990
    var heightCm: Double = 178
    var weightKg: Double = 78

    var age: Int { max(14, Calendar.current.component(.year, from: .now) - birthYear) }

    /// Estimated maximum heart rate (Tanaka: 208 − 0.7 × age).
    var maxHeartRate: Double { 208 - 0.7 * Double(age) }

    /// Calories your body burns at rest in a full day.
    func restingCalories(weightKg w: Double? = nil) -> Double {
        let kg = w ?? weightKg
        let base = 10 * kg + 6.25 * heightCm - 5 * Double(age)
        return base + (sex == .male ? 5 : -161)
    }
}

/// One spoke of the Balance chart (0...1).
struct BalanceAxis: Codable, Hashable, Identifiable {
    let name: String
    let value: Double       // a score, 0...1, not the reading itself
    var detail: String? = nil   // the actual numbers behind it, like "74 bpm this week · usual 75"
    var id: String { name }

    /// Label on the radar itself, where space is tight.
    var short: String {
        switch name {
        case "Resting HR": return "RHR"
        case "Weekly cardio": return "Cardio"
        default: return name
        }
    }
}
