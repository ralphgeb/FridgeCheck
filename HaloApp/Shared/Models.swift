import Foundation

/// Sleep stages as Fitbit reports them.
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

    var minutesInBed: Double { end.timeIntervalSince(start) / 60 }
    var efficiency: Double { minutesInBed > 0 ? min(1, minutesAsleep / minutesInBed) : 0 }

    func minutes(_ kind: SleepStageKind) -> Double {
        stages.filter { $0.kind == kind }.reduce(0) { $0 + $1.minutes }
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
    var zoneMinutes: ZoneMinutes?        // time in each heart-rate zone
    var restingHeartRate: Double?
    var hrv: Double?                     // RMSSD, milliseconds
    var spo2: Double?                    // percent
    var respiratoryRate: Double?         // breaths per minute
    var skinTempDelta: Double?           // °C from personal baseline
    var vo2Max: Double?
    var weightKg: Double?
    var sleep: SleepSession?
    var heartRate: [HeartSample]         // intraday, kept for the most recent days only

    var id: Date { date }

    /// Cardio load for the day: from time in heart-rate zones when Fitbit reports it,
    /// otherwise estimated from Active Zone Minutes.
    var cardioLoad: Double? {
        if let z = zoneMinutes, z.total > 0 { return CardioLoad.fromZones(z) }
        return activeZoneMinutes.map(CardioLoad.fromActiveZoneMinutes)
    }

    init(date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
        self.heartRate = []
    }
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
}

/// The user's targets (set in Settings).
struct Targets: Codable, Hashable {
    var sleepNeedHours: Double = 7.5
    var steps: Double = 10_000
    var cardioFocus: CardioFocus = .auto
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
    let value: Double
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
