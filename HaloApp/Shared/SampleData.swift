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
            d.spo2 = (96.4 + rng.next(-0.8, 0.8) * 10).rounded() / 10
            d.respiratoryRate = ((14.6 + rng.next(-0.6, 0.6)) * 10).rounded() / 10
            d.skinTempDelta = ((rng.next(-0.4, 0.4)) * 10).rounded() / 10
            d.vo2Max = (46 + 2 * sin(Double(offset) / 40)).rounded()
            d.weightKg = ((78.5 + 1.2 * sin(Double(offset) / 25) + rng.next(-0.3, 0.3)) * 10).rounded() / 10
            d.steps = Int(rng.next(weekend ? 5_000 : 7_500, weekend ? 14_000 : 12_500))
            d.activeZoneMinutes = rng.next(8, 62).rounded()
            d.activeCalories = rng.next(380, 920).rounded()
            d.sleep = sleep(wakingOn: date, rng: &rng, weekend: weekend)
            return d
        }
        .map { day in
            var day = day
            if cal.isDate(day.date, inSameDayAs: today) {
                day.heartRate = heartRate(for: today, until: end, rng: &rng)
                // today is still in progress
                day.steps = Int(Double(day.steps ?? 0) * 0.62)
                day.activeZoneMinutes = 21
            }
            return day
        }
    }

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

    static func heartRate(for day: Date, until end: Date, rng: inout SeededRandom) -> [HeartSample] {
        var out: [HeartSample] = []
        var t = day
        while t < end {
            let h = Calendar.current.component(.hour, from: t)
            var bpm: Double
            switch h {
            case 0..<7: bpm = 52
            case 7..<9: bpm = 74
            case 12..<13: bpm = 96       // lunchtime walk
            case 17..<18: bpm = 128      // workout
            default: bpm = 70
            }
            out.append(HeartSample(time: t, bpm: (bpm + rng.next(-6, 6)).rounded()))
            t = t.addingTimeInterval(10 * 60)
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
