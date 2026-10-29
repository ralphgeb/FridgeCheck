import Foundation

/// Turns raw Fitbit data into Halo's three scores.
/// Every score compares you with your own recent baseline, not with population averages.
enum ScoreEngine {
    static let baselineDays = 30

    static func scores(for day: DayMetrics, history: [DayMetrics], targets: Targets) -> Scores {
        let past = history.filter { $0.date < day.date }.suffix(baselineDays)
        let sleep = sleepScore(day.sleep, previous: Array(past), targets: targets)
        let recovery = recoveryScore(day, previous: Array(past), sleep: sleep)
        return Scores(
            recovery: recovery,
            effort: effortScore(day, targets: targets),
            sleep: sleep
        )
    }

    // MARK: Sleep

    /// What goes into the sleep score, each 0...1.
    struct SleepParts {
        let duration: Double        // time asleep against your need
        let deep: Double            // deep sleep share against 20% of the night
        let rem: Double             // REM share against 23%
        let efficiency: Double      // time asleep out of time in bed: 85% starts counting, 97% is full
        let calm: Double            // time awake in the night: 5 minutes or less is full, an hour is none
        let consistency: Double     // bedtime against your usual one
        var restorative: Double { (deep + rem) / 2 }
    }

    static func sleepParts(_ s: SleepSession, previous: [DayMetrics], targets: Targets) -> SleepParts {
        let need = targets.sleepNeedHours * 60
        let asleep = max(s.minutesAsleep, 1)
        // half your need asleep scores nothing, all of it full marks
        let duration = clamp((s.minutesAsleep / need - 0.5) / 0.5)
        let deep = clamp(s.minutes(.deep) / asleep / 0.20)
        let rem = clamp(s.minutes(.rem) / asleep / 0.23)
        let efficiency = clamp((s.efficiency - 0.85) / 0.12)
        let awake = s.stages.isEmpty ? s.minutesAwake : s.minutes(.awake)
        let calm = clamp(1 - max(0, awake - 5) / 55)

        // Bedtime against your usual one (the median of the last week, so one late night doesn't
        // move it): within 15 minutes is full marks, then it fades out over the next 90.
        let bedtimes = previous.suffix(7).compactMap { $0.sleep.map { minutesAfterEvening($0.start) } }
        let consistency: Double
        if bedtimes.count >= 3, let usual = median(bedtimes) {
            consistency = clamp(1 - (abs(minutesAfterEvening(s.start) - usual) - 15) / 90)
        } else {
            consistency = 0.8
        }
        return SleepParts(duration: duration, deep: deep, rem: rem, efficiency: efficiency, calm: calm, consistency: consistency)
    }

    /// Duration against your need (40%), deep and REM (25%), efficiency (15%), a calm night (10%)
    /// and a steady bedtime (10%). The total is curved so only a near-perfect night reaches the
    /// 90s, as with Fitbit, Whoop and Bevel: a full, steady night with normal stages lands in the 80s.
    static func sleepScore(_ s: SleepSession?, previous: [DayMetrics], targets: Targets) -> Double? {
        guard let s, s.minutesAsleep > 60 else { return nil }
        let p = sleepParts(s, previous: previous, targets: targets)
        let raw = 0.40 * p.duration + 0.25 * p.restorative + 0.15 * p.efficiency + 0.10 * p.calm + 0.10 * p.consistency
        return clamp(pow(clamp(raw), 1.8))
    }

    /// Bedtime as minutes after 6 pm, so 23:30 and 00:30 sit next to each other.
    static func minutesAfterEvening(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        return m >= 18 * 60 ? m - 18 * 60 : m + 6 * 60
    }

    // MARK: Recovery

    /// How this morning's HRV and resting heart rate compare with your last 30 days, in your own
    /// day-to-day spread (z-scores: +1 is a good day for you, -1 a poor one). Nil without a baseline.
    static func recoveryZ(_ day: DayMetrics, previous: [DayMetrics]) -> (hrv: Double?, rhr: Double?) {
        // HRV on a log scale: it swings by percentages, not by milliseconds
        let logs = previous.compactMap(\.hrv).filter { $0 > 0 }.map { log($0) }
        var zh: Double?
        if let hrv = day.hrv, hrv > 0, logs.count >= 3, let m = mean(logs) {
            let sd = logs.count >= 7 ? max(0.08, standardDeviation(logs)) : 0.15
            zh = (log(hrv) - m) / sd
        }
        let rhrs = previous.compactMap(\.restingHeartRate)
        var zr: Double?
        if let rhr = day.restingHeartRate, rhrs.count >= 3, let m = mean(rhrs) {
            let sd = rhrs.count >= 7 ? max(1.5, standardDeviation(rhrs)) : 2.5
            zr = (m - rhr) / sd
        }
        return (zh, zr)
    }

    /// A z-score as a 0...1 level. A usual morning for you is about 67%, the edge of green, as in
    /// Whoop and Bevel; one spread better is about 86%, one worse about 41%.
    static func recoveryLevel(_ z: Double) -> Double { 1 / (1 + exp(-(1.1 * z + 0.7))) }

    /// HRV (70%) and resting heart rate (30%) against your own normal, then last night's sleep
    /// (a quarter of the score).
    static func recoveryScore(_ day: DayMetrics, previous: [DayMetrics], sleep: Double?) -> Double? {
        let z = recoveryZ(day, previous: previous)
        let parts = [(z.hrv, 0.7), (z.rhr, 0.3)].compactMap { v, w in v.map { ($0, w) } }
        guard !parts.isEmpty else { return nil }
        let combined = parts.reduce(0) { $0 + $1.0 * $1.1 } / parts.reduce(0) { $0 + $1.1 }
        let body = recoveryLevel(combined)
        guard let sleep else { return clamp(body) }
        return clamp(0.75 * body + 0.25 * sleep)
    }

    // MARK: Effort

    /// Today only, filling up from midnight. Half is steps against your step target; half is
    /// heart zone minutes against your daily target, where a fat-burn minute counts a quarter, a cardio
    /// minute double and a peak minute triple, so harder effort fills it faster.
    static func effortScore(_ day: DayMetrics, targets: Targets) -> Double? {
        guard day.steps != nil || day.zones != nil || day.activeZoneMinutes != nil else { return nil }
        // Bands that don't count steps (Whoop): heart zones alone.
        if day.steps == nil { return clamp(effortZonesPart(day, targets)) }
        return clamp(0.5 * effortStepsPart(day, targets) + 0.5 * effortZonesPart(day, targets))
    }

    static func effortStepsPart(_ day: DayMetrics, _ targets: Targets) -> Double {
        min(1, Double(day.steps ?? 0) / max(targets.steps, 1))
    }

    /// Zone points so far today: from zone minutes, or Active Zone Minutes (which count the same way).
    static func zonePoints(_ day: DayMetrics) -> Double {
        day.zones?.points ?? day.activeZoneMinutes ?? 0
    }

    static func effortZonesPart(_ day: DayMetrics, _ targets: Targets) -> Double {
        min(1, zonePoints(day) / max(targets.zoneMinutes, 1))
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

        // Being exactly at your usual level scores 70; better climbs to 100, worse falls away.
        // HRV: level against your baseline (60%) and how steady it was through the week (40%).
        var hrvValue = 0.0, hrvDetail: String?
        let hrvs = week.compactMap(\.hrv)
        if let m = mean(hrvs) {
            let base = mean(before.compactMap(\.hrv)) ?? m
            let level = clamp(0.7 + (m / base - 1) / 0.25)
            let sd = sqrt(hrvs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(hrvs.count))
            hrvValue = 0.6 * level + 0.4 * clamp(1 - (sd / m) / 0.25)
            hrvDetail = "\(Int(m.rounded())) ms this week · usual \(Int(base.rounded())) · \(sd / m < 0.1 ? "steady" : "up and down")"
        }
        var rhrValue = 0.0, rhrDetail: String?
        if let m = mean(week.compactMap(\.restingHeartRate)) {
            let base = mean(before.compactMap(\.restingHeartRate)) ?? m
            rhrValue = clamp(0.7 + (base / m - 1) / 0.08)
            let change = Int(((m / base - 1) * 100).rounded())
            rhrDetail = "\(Int(m.rounded())) bpm this week · usual \(Int(base.rounded()))" + (change == 0 ? "" : " (\(change > 0 ? "+" : "")\(change)%)")
        }
        let cardio = CardioLoad.week(days: days, endingOn: end, chosen: targets.cardioFocus,
                                     recovery: week.last.flatMap { scores($0).recovery })
        let sleep = mean(weekScores.compactMap(\.sleep))
        let recovery = mean(weekScores.compactMap(\.recovery))
        let steps = mean(week.compactMap { d in d.steps.map { Double($0) } })

        return [
            BalanceAxis(name: "Sleep", value: sleep ?? 0,
                        detail: sleep.map { "Sleep score \(Int(($0 * 100).rounded())) on average" }),
            BalanceAxis(name: "HRV", value: hrvValue, detail: hrvDetail),
            BalanceAxis(name: "Recovery", value: recovery ?? 0,
                        detail: recovery.map { "Recovery \(Int(($0 * 100).rounded())) on average" }),
            BalanceAxis(name: "Steps", value: clamp((steps ?? 0) / max(targets.steps, 1)),
                        detail: steps.map { "\(Int($0.rounded()).formatted()) a day · target \(Int(targets.steps).formatted())" }),
            BalanceAxis(name: "Weekly cardio", value: clamp(cardio.pace),
                        detail: "Load \(Int(cardio.load.rounded())) of \(Int(cardio.target)) · day \(cardio.daysElapsed) of 7"),
            BalanceAxis(name: "Resting HR", value: rhrValue, detail: rhrDetail),
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

    // MARK: What goes into each score

    /// One thing a score takes into account: today's value, what it's compared with,
    /// how well it did (0...1) and how much it counts.
    struct Factor: Identifiable {
        let name: String
        let value: String
        let note: String
        let level: Double?
        let weight: String
        var id: String { name }
    }

    static func factors(_ kind: ScoreKind, day: DayMetrics, history: [DayMetrics], targets: Targets) -> [Factor] {
        let past = Array(history.filter { $0.date < day.date }.suffix(baselineDays))
        let sleep = sleepScore(day.sleep, previous: past, targets: targets)
        switch kind {
        case .recovery:
            let hrvBase = mean(past.compactMap(\.hrv)), rhrBase = mean(past.compactMap(\.restingHeartRate))
            let z = recoveryZ(day, previous: past)
            return [
                Factor(name: "Heart rate variability", value: day.hrv.map { "\(Int($0)) ms" } ?? "–",
                       note: hrvBase.map { "Your normal \(Int($0.rounded())) ms. Higher means more recovered." } ?? "Needs a few nights of data.",
                       level: z.hrv.map(recoveryLevel), weight: "Counts most"),
                Factor(name: "Resting heart rate", value: day.restingHeartRate.map { "\(Int($0)) bpm" } ?? "–",
                       note: rhrBase.map { "Your normal \(Int($0.rounded())) bpm. Lower means more recovered." } ?? "Needs a few days of data.",
                       level: z.rhr.map(recoveryLevel), weight: "Counts some"),
                Factor(name: "Last night's sleep", value: sleep.map { "\(Int(($0 * 100).rounded()))" } ?? "–",
                       note: "Your sleep score.", level: sleep, weight: "A quarter"),
            ]
        case .effort:
            let z = day.zones
            let detail = z.map { "Moderate \(Int($0.fatBurn.rounded())) ×¼, cardio \(Int($0.cardio.rounded())) ×2, peak \(Int($0.peak.rounded())) ×3. " } ?? ""
            return [
                Factor(name: "Steps", value: (day.steps ?? 0).formatted(),
                       note: "Target \(Int(targets.steps).formatted()).", level: effortStepsPart(day, targets), weight: "Half"),
                Factor(name: "Heart zone minutes", value: "\(Int(zonePoints(day).rounded()))",
                       note: "\(detail)Target \(Int(targets.zoneMinutes)).", level: effortZonesPart(day, targets), weight: "Half"),
            ]
        case .sleep:
            guard let s = day.sleep else { return [] }
            let need = targets.sleepNeedHours * 60
            let p = sleepParts(s, previous: past, targets: targets)
            let deep = s.minutes(.deep), rem = s.minutes(.rem)
            let asleep = max(s.minutesAsleep, 1)
            let awake = s.stages.isEmpty ? s.minutesAwake : s.minutes(.awake)
            let bedtimes = past.suffix(7).compactMap { $0.sleep.map { minutesAfterEvening($0.start) } }
            let usual = median(bedtimes)
            return [
                Factor(name: "Time asleep", value: Format.duration(s.minutesAsleep),
                       note: "Your need is \(Format.duration(need)).", level: p.duration, weight: "Counts most"),
                Factor(name: "Deep and REM", value: "\(Int((deep / asleep * 100).rounded()))% · \(Int((rem / asleep * 100).rounded()))%",
                       note: "The restoring stages. Full marks at 20% deep and 23% REM.", level: p.restorative, weight: "Counts some"),
                Factor(name: "Efficiency", value: "\(Int((s.efficiency * 100).rounded()))%",
                       note: "Time asleep out of time in bed.", level: p.efficiency, weight: "Counts a little"),
                Factor(name: "Calm night", value: "\(Int(awake.rounded())) min awake",
                       note: "Time awake after falling asleep. 5 minutes or less is full marks.", level: p.calm, weight: "Counts a little"),
                Factor(name: "Steady bedtime", value: Format.time(s.start),
                       note: usual.map { "Your usual is around \(Format.time(eveningTime($0, on: day.date)))." } ?? "Needs a few nights of data.",
                       level: usual.map { _ in p.consistency }, weight: "Counts a little"),
            ]
        }
    }

    /// Minutes after 6 pm back to a clock time on the evening before `day`.
    static func eveningTime(_ minutes: Double, on day: Date) -> Date {
        let evening = Calendar.current.date(byAdding: .hour, value: -6, to: Calendar.current.startOfDay(for: day)) ?? day
        return evening.addingTimeInterval(minutes * 60)
    }

    // MARK: Words

    static func headline(_ s: Scores) -> (title: String, detail: String) {
        guard let r = s.recovery else {
            return ("Waiting for data", "Wear your band to sleep and Halo will score your recovery in the morning.")
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

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted(), n = v.count
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1, let m = mean(values) else { return 0 }
        return (values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)).squareRoot()
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
