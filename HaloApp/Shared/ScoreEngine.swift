import Foundation

/// Turns raw Fitbit data into Halo's three scores.
/// Every score compares you with your own recent baseline, not with population averages.
enum ScoreEngine {
    static let baselineDays = 30

    static func scores(for day: DayMetrics, history: [DayMetrics], targets: Targets) -> Scores {
        let past = history.filter { $0.date < day.date }.suffix(baselineDays)
        let sleep = sleepScore(day.sleep, previous: Array(past), targets: targets)
        return Scores(
            recovery: recoveryScore(day, previous: Array(past), sleep: sleep),
            effort: effortScore(day, targets: targets),
            sleep: sleep
        )
    }

    // MARK: Sleep

    /// Duration against your need (55%), restorative deep + REM share (20%),
    /// efficiency (15%) and bedtime consistency over the last week (10%).
    static func sleepScore(_ s: SleepSession?, previous: [DayMetrics], targets: Targets) -> Double? {
        guard let s, s.minutesAsleep > 60 else { return nil }
        let need = targets.sleepNeedHours * 60
        let duration = clamp(s.minutesAsleep / need)
        let restorative = clamp((s.minutes(.deep) + s.minutes(.rem)) / max(s.minutesAsleep, 1) / 0.40)
        let efficiency = clamp((s.efficiency - 0.75) / 0.20)

        let bedtimes = previous.suffix(7).compactMap { $0.sleep.map { minutesAfterEvening($0.start) } }
        let consistency: Double
        if bedtimes.count >= 3 {
            let mean = bedtimes.reduce(0, +) / Double(bedtimes.count)
            consistency = clamp(1 - abs(minutesAfterEvening(s.start) - mean) / 90)
        } else {
            consistency = 0.8
        }
        return clamp(0.55 * duration + 0.20 * restorative + 0.15 * efficiency + 0.10 * consistency)
    }

    /// Bedtime as minutes after 6 pm, so 23:30 and 00:30 sit next to each other.
    static func minutesAfterEvening(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        return m >= 18 * 60 ? m - 18 * 60 : m + 6 * 60
    }

    // MARK: Recovery

    /// HRV against your 30-day baseline (50%), resting heart rate against baseline (30%), sleep (20%).
    static func recoveryScore(_ day: DayMetrics, previous: [DayMetrics], sleep: Double?) -> Double? {
        var parts: [(value: Double, weight: Double)] = []
        if let hrv = day.hrv, let base = mean(previous.compactMap(\.hrv)) {
            // +/- 20% from baseline spans the whole range
            parts.append((clamp(0.5 + (hrv / base - 1) / 0.4), 0.5))
        }
        if let rhr = day.restingHeartRate, let base = mean(previous.compactMap(\.restingHeartRate)) {
            // a resting heart rate 7% under baseline is a full score, 7% over is zero
            parts.append((clamp(0.5 + (base / rhr - 1) / 0.14), 0.3))
        }
        if let sleep { parts.append((sleep, 0.2)) }
        guard parts.contains(where: { $0.weight >= 0.3 }) else { return nil }
        let total = parts.reduce(0) { $0 + $1.weight }
        return clamp(parts.reduce(0) { $0 + $1.value * $1.weight } / total)
    }

    // MARK: Effort

    /// Active Zone Minutes against your target (65%) and steps against your target (35%).
    static func effortScore(_ day: DayMetrics, targets: Targets) -> Double? {
        guard day.activeZoneMinutes != nil || day.steps != nil else { return nil }
        let azm = (day.activeZoneMinutes ?? 0) / max(targets.activeZoneMinutes, 1)
        let steps = Double(day.steps ?? 0) / max(targets.steps, 1)
        return clamp(0.65 * min(azm, 1) + 0.35 * min(steps, 1))
    }

    // MARK: Words

    static func headline(_ s: Scores) -> (title: String, detail: String) {
        guard let r = s.recovery else {
            return ("Waiting for data", "Wear your Fitbit to sleep and Halo will score your recovery in the morning.")
        }
        switch r {
        case 0.67...:
            return ("Primed", "Your body has bounced back. A good day for a hard session.")
        case 0.34..<0.67:
            return ("Steady", "You're recovered enough for normal training. Keep intensity moderate.")
        default:
            return ("Recharge", "Your body is still recovering. Go easy and protect tonight's sleep.")
        }
    }

    // MARK: Helpers

    static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
