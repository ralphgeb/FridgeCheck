import Foundation

/// Turns raw Fitbit data into Halo's three scores.
/// Every score compares you with your own recent baseline, not with population averages.
enum ScoreEngine {
    static let baselineDays = 30

    static func scores(for day: DayMetrics, history: [DayMetrics], targets: Targets) -> Scores {
        let past = history.filter { $0.date < day.date }.suffix(baselineDays)
        let sleep = sleepScore(day.sleep, previous: Array(past), targets: targets)
        let recovery = recoveryScore(day, previous: Array(past), sleep: sleep)
        let week = CardioLoad.week(days: Array(past) + [day], endingOn: day.date, chosen: targets.cardioFocus, recovery: recovery)
        return Scores(
            recovery: recovery,
            effort: effortScore(day, dailyLoadTarget: week.target / 7, targets: targets),
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

    /// Cardio load against a day's share of the weekly target (65%) and steps against your target (35%).
    static func effortScore(_ day: DayMetrics, dailyLoadTarget: Double, targets: Targets) -> Double? {
        guard day.cardioLoad != nil || day.steps != nil else { return nil }
        let load = (day.cardioLoad ?? 0) / max(dailyLoadTarget, 1)
        let steps = Double(day.steps ?? 0) / max(targets.steps, 1)
        return clamp(0.65 * min(load, 1) + 0.35 * min(steps, 1))
    }

    // MARK: Balance (the radar chart)

    /// Six spokes, each 0...1, describing the week ending on `date`.
    static func balance(days: [DayMetrics], endingOn date: Date, targets: Targets,
                        scores: (DayMetrics) -> Scores) -> [BalanceAxis] {
        let cal = Calendar.current
        let end = cal.startOfDay(for: date)
        guard let start = cal.date(byAdding: .day, value: -6, to: end) else { return [] }
        let week = days.filter { $0.date >= start && $0.date <= end }
        let before = days.filter { $0.date < start }.suffix(baselineDays)
        let weekScores = week.map(scores)

        // HRV: level against your baseline (60%) and how steady it was through the week (40%).
        var hrvValue = 0.0
        let hrvs = week.compactMap(\.hrv)
        if let m = mean(hrvs) {
            let base = mean(before.compactMap(\.hrv)) ?? m
            let level = clamp(0.5 + (m / base - 1) / 0.4)
            let sd = sqrt(hrvs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(hrvs.count))
            hrvValue = 0.6 * level + 0.4 * clamp(1 - (sd / m) / 0.25)
        }
        var rhrValue = 0.0
        if let m = mean(week.compactMap(\.restingHeartRate)) {
            let base = mean(before.compactMap(\.restingHeartRate)) ?? m
            rhrValue = clamp(0.5 + (base / m - 1) / 0.14)
        }
        let cardio = CardioLoad.week(days: days, endingOn: end, chosen: targets.cardioFocus,
                                     recovery: week.last.flatMap { scores($0).recovery })

        return [
            BalanceAxis(name: "Sleep", value: mean(weekScores.compactMap(\.sleep)) ?? 0),
            BalanceAxis(name: "HRV", value: hrvValue),
            BalanceAxis(name: "Recovery", value: mean(weekScores.compactMap(\.recovery)) ?? 0),
            BalanceAxis(name: "Steps", value: clamp((mean(week.compactMap { d in d.steps.map { Double($0) } }) ?? 0) / max(targets.steps, 1))),
            BalanceAxis(name: "Weekly cardio", value: clamp(cardio.progress)),
            BalanceAxis(name: "Resting HR", value: rhrValue),
        ]
    }

    // MARK: Sleep debt

    struct Night: Identifiable {
        let date: Date
        let asleep: Double       // minutes
        let need: Double         // minutes
        var balance: Double { asleep - need }   // negative = short
        var id: Date { date }
    }

    static func nights(days: [DayMetrics], endingOn date: Date, count: Int, needHours: Double) -> [Night] {
        let cal = Calendar.current
        let end = cal.startOfDay(for: date)
        return days.filter { $0.date <= end }.suffix(count).compactMap { d in
            d.sleep.map { Night(date: d.date, asleep: $0.minutesAsleep, need: needHours * 60) }
        }
    }

    /// Minutes of sleep missed across the nights (nights over your need pay some of it back).
    static func sleepDebt(_ nights: [Night]) -> Double {
        max(0, -nights.reduce(0) { $0 + $1.balance })
    }

    /// When to get into bed tonight: your usual wake time, minus your need, the time you
    /// usually take to fall asleep, and up to 30 minutes extra to pay back debt.
    static func bedtime(days: [DayMetrics], endingOn date: Date, needHours: Double) -> Date? {
        let recent = days.filter { $0.date <= Calendar.current.startOfDay(for: date) }.suffix(7).compactMap(\.sleep)
        guard recent.count >= 3 else { return nil }
        let wakes = recent.map { minutesAfterEvening($0.end) }.sorted()
        let usualWake = wakes[wakes.count / 2]
        let latency = mean(recent.map(\.minutesToFallAsleep)) ?? 10
        let debt = sleepDebt(nights(days: days, endingOn: date, count: 7, needHours: needHours))
        let bed = usualWake - needHours * 60 - latency - min(30, debt / 7)
        let startOfEvening = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: date) ?? date
        return startOfEvening.addingTimeInterval(bed * 60)
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
