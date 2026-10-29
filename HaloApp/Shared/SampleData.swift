import Foundation

/// Realistic made-up data, used until a Fitbit account is connected and for widget previews.
/// It's deterministic, so the screens look the same every time.
enum SampleData {
    static func days(count: Int = 182, endingOn end: Date = .now) -> [DayMetrics] {
        var rng = SeededRandom(seed: 42)
        let cal = Calendar.current
        let today = cal.startOfDay(for: end)
        return (0..<count).reversed().compactMap { offset -> DayMetrics? in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            var d = DayMetrics(date: date)
            let weekday = cal.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            let wave = sin(Double(offset) / 4.5)

            d.hrv = (58 + 9 * wave + rng.next(-6, 6)).rounded()
            d.restingHeartRate = (54 - 2.5 * wave + rng.next(-1.5, 1.5)).rounded()
            d.spo2 = ((96.4 + rng.next(-0.8, 0.8)) * 10).rounded() / 10
            d.respiratoryRate = ((14.6 + rng.next(-0.6, 0.6)) * 10).rounded() / 10
            d.skinTempDelta = ((rng.next(-0.4, 0.4)) * 10).rounded() / 10
            d.vo2Max = (46 + 2 * sin(Double(offset) / 40)).rounded()
            d.weightKg = ((78.5 + 1.2 * sin(Double(offset) / 25) + rng.next(-0.3, 0.3)) * 10).rounded() / 10
            d.steps = Int(rng.next(weekend ? 5_000 : 7_500, weekend ? 14_000 : 12_500))
            // a harder session every few days, easy days in between
            let hard = (offset % 3 == 0) || rng.next(0, 1) > 0.8
            d.zoneMinutes = ZoneMinutes(fatBurn: rng.next(5, 25).rounded(),
                                        cardio: (hard ? rng.next(10, 30) : rng.next(0, 4)).rounded(),
                                        peak: (hard ? rng.next(0, 5) : 0).rounded())
            if let z = d.zoneMinutes { d.activeZoneMinutes = z.fatBurn + 2 * (z.cardio + z.peak) }
            d.activeCalories = rng.next(380, 920).rounded()
            d.sleep = sleep(wakingOn: date, rng: &rng, weekend: weekend)
            if hard, offset > 0 {
                let kinds = ["RUNNING", "STRENGTH_TRAINING", "CYCLING", "SWIMMING"]
                let kind = kinds[offset % kinds.count]
                let start = cal.date(bySettingHour: 18, minute: 10, second: 0, of: date) ?? date
                let minutes = Double(d.zoneMinutes.map { $0.cardio + $0.peak + 15 } ?? 40)
                d.workouts = [Workout(id: "sample-\(offset)", kind: kind, start: start, end: start.addingTimeInterval(minutes * 60),
                                      calories: (minutes * 9.5).rounded(), averageHeartRate: 138,
                                      distanceKm: kind == "RUNNING" ? (minutes / 5.6 * 10).rounded() / 10 : nil)]
            }
            return d
        }
        .map { day in
            var day = day
            if cal.isDate(day.date, inSameDayAs: today) {
                // today is still in progress
                day.steps = Int(Double(day.steps ?? 0) * 0.62)
                day.zoneMinutes = ZoneMinutes(fatBurn: 9, cardio: 4, peak: 0)
                day.activeZoneMinutes = 17
            }
            return day
        }
        .withHeartRate(until: end, rng: &rng)
        .withHours(until: end)
    }

    /// How a typical day's activity spreads over its 24 hours: nothing asleep, a morning
    /// commute, a lunchtime walk, an evening workout.
    static let dayShape: [Double] = [0, 0, 0, 0, 0, 0, 0.3, 1.6, 1.4, 0.7, 0.6, 0.8,
                                     1.7, 1.0, 0.6, 0.6, 0.9, 1.6, 2.4, 1.2, 0.8, 0.5, 0.25, 0.05]

    /// One night: about 7h 20m with realistic 90-minute cycles.
    static func sleep(wakingOn day: Date, rng: inout SeededRandom, weekend: Bool) -> SleepSession {
        let cal = Calendar.current
        let bedHour = weekend ? 23.6 : 23.0
        let bed = cal.date(byAdding: .minute, value: Int((bedHour - 24) * 60 + rng.next(-25, 25)), to: day) ?? day
        var t = bed
        var stages: [SleepStage] = []
        func add(_ kind: SleepStageKind, _ minutes: Double) {
            let end = t.addingTimeInterval(max(1, minutes) * 60)
            stages.append(SleepStage(kind: kind, start: t, end: end))
            t = end
        }
        add(.awake, rng.next(6, 14))
        let cycles = 5
        for c in 0..<cycles {
            let late = Double(c) / Double(cycles - 1)          // 0 early night, 1 morning
            add(.light, rng.next(22, 34))
            add(.deep, rng.next(10, 34) * (1 - late * 0.85))
            add(.light, rng.next(14, 26))
            add(.rem, rng.next(8, 14) + late * rng.next(10, 22))
            if rng.next(0, 1) > 0.55 { add(.awake, rng.next(2, 9)) }
        }
        add(.awake, rng.next(3, 8))
        let asleep = stages.filter { $0.kind != .awake }.reduce(0) { $0 + $1.minutes }
        let awake = stages.filter { $0.kind == .awake }.reduce(0) { $0 + $1.minutes }
        return SleepSession(start: bed, end: t, minutesAsleep: asleep.rounded(), minutesAwake: awake.rounded(), stages: stages)
    }

    /// Heart rate every 5 minutes from `start` to `end`. Asleep, it follows the sleep stages:
    /// lowest in deep sleep, higher and more variable in REM and when awake.
    static func heartRate(from start: Date, until end: Date, nights: [SleepSession], rng: inout SeededRandom) -> [HeartSample] {
        var out: [HeartSample] = []
        var t = start
        while t < end {
            var bpm: Double
            var spread = 6.0
            if let stage = nights.lazy.flatMap(\.stages).first(where: { $0.start <= t && t < $0.end }) {
                switch stage.kind {
                case .deep: bpm = 49; spread = 1.5
                case .light: bpm = 53; spread = 2.5
                case .rem: bpm = 58; spread = 4
                case .awake: bpm = 63; spread = 4
                }
            } else {
                switch Calendar.current.component(.hour, from: t) {
                case 7..<9: bpm = 76
                case 12..<13: bpm = 96       // lunchtime walk
                case 17..<18: bpm = 132      // workout
                default: bpm = 72
                }
            }
            out.append(HeartSample(time: t, bpm: (bpm + rng.next(-spread, spread)).rounded()))
            t = t.addingTimeInterval(5 * 60)
        }
        return out
    }
}

private extension Array where Element == DayMetrics {
    /// Intraday heart rate for yesterday and today (like a real sync, which keeps only recent days).
    func withHeartRate(until end: Date, rng: inout SeededRandom) -> [DayMetrics] {
        let nights = suffix(2).compactMap(\.sleep)
        var out = self
        let profile = Profile()
        for i in out.indices.suffix(2) {
            let start = out[i].date
            let stop = Swift.min(end, start.addingTimeInterval(86_400))
            out[i].heartRate = SampleData.heartRate(from: start, until: stop, nights: nights, rng: &rng)
            let (load, zones) = CardioLoad.fromHeartRate(out[i].heartRate, resting: out[i].restingHeartRate ?? 55, max: profile.maxHeartRate, maxGap: 300)
            out[i].heartLoad = load
            out[i].heartZones = zones
        }
        return out
    }

    /// Steps and active calories hour by hour for the last two weeks, spread over the day's shape.
    /// Today only fills the hours so far.
    func withHours(until end: Date) -> [DayMetrics] {
        var out = self
        let hourNow = Calendar.current.component(.hour, from: end)
        for i in out.indices.suffix(14) {
            let today = Calendar.current.isDate(out[i].date, inSameDayAs: end)
            let shape = SampleData.dayShape.enumerated().map { h, w in !today || h <= hourNow ? w : 0 }
            let total = Swift.max(shape.reduce(0, +), 0.001)
            out[i].hourlySteps = shape.map { (Double(out[i].steps ?? 0) * $0 / total).rounded() }
            out[i].hourlyCalories = shape.map { ((out[i].activeCalories ?? 0) * $0 / total).rounded() }
        }
        return out
    }
}

/// Small deterministic random generator (so sample data doesn't change between launches).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }

    mutating func next(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * next()
    }
}
