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
    var restingHeartRate: Double?
    var hrv: Double?                     // RMSSD, milliseconds
    var spo2: Double?                    // percent
    var respiratoryRate: Double?         // breaths per minute
    var skinTempDelta: Double?           // °C from personal baseline
    var vo2Max: Double?
    var sleep: SleepSession?
    var heartRate: [HeartSample]         // intraday, kept for the most recent days only

    var id: Date { date }

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

/// The user's targets (set in Settings).
struct Targets: Codable, Hashable {
    var sleepNeedHours: Double = 8
    var activeZoneMinutes: Double = 30
    var steps: Double = 10_000
}
