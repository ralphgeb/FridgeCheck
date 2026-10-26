import Foundation

/// Cardio load: how hard your heart worked, not just for how long.
/// Each minute in a heart-rate zone earns load, and harder zones earn it at an accelerating rate
/// (Banister's training impulse, using the middle of each Fitbit zone as a share of heart-rate reserve).
enum CardioLoad {
    /// Load earned by one minute at a share of heart-rate reserve (0 = resting, 1 = max).
    static func perMinute(_ reserve: Double) -> Double {
        reserve <= 0 ? 0 : reserve * 0.64 * exp(1.92 * reserve)
    }

    /// Fitbit zones: fat burn is 40–59% of reserve, cardio 60–84%, peak 85% and up.
    static func fromZones(_ z: ZoneMinutes) -> Double {
        z.fatBurn * perMinute(0.5) + z.cardio * perMinute(0.72) + z.peak * perMinute(0.9)
    }

    /// Heart-rate zones as shares of heart-rate reserve (resting to max), as Fitbit sets them.
    static let fatBurnStart = 0.4, cardioStart = 0.6, peakStart = 0.85

    /// The bpm where a zone starts, for this resting and max heart rate.
    static func bpm(atReserve share: Double, resting: Double, max: Double) -> Double {
        resting + share * (max - resting)
    }

    /// Load and zone minutes worked out from heart-rate readings: each reading counts for the time
    /// until the next one (at most 5 minutes), and only time in a zone (40% of reserve and up) counts.
    static func fromHeartRate(_ samples: [HeartSample], resting: Double, max maxHR: Double) -> (load: Double, zones: ZoneMinutes) {
        let sorted = samples.sorted { $0.time < $1.time }
        let reserve = Swift.max(maxHR - resting, 1)
        var load = 0.0
        var z = ZoneMinutes()
        for (i, s) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1].time : s.time.addingTimeInterval(60)
            let minutes = Swift.min(next.timeIntervalSince(s.time), 300) / 60
            let x = (s.bpm - resting) / reserve
            guard x >= fatBurnStart, minutes > 0 else { continue }
            load += perMinute(Swift.min(x, 1.1)) * minutes
            if x >= peakStart { z.peak += minutes } else if x >= cardioStart { z.cardio += minutes } else { z.fatBurn += minutes }
        }
        return (load, z)
    }

    /// The same, as running totals through the day: load and Active Zone Minutes (fat burn once,
    /// cardio and peak twice) after each reading. For the day graphs.
    static func timeline(_ samples: [HeartSample], resting: Double, max maxHR: Double) -> [(time: Date, load: Double, azm: Double)] {
        let sorted = samples.sorted { $0.time < $1.time }
        let reserve = Swift.max(maxHR - resting, 1)
        var load = 0.0, azm = 0.0
        var out: [(time: Date, load: Double, azm: Double)] = []
        for (i, s) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1].time : s.time.addingTimeInterval(60)
            let minutes = Swift.min(next.timeIntervalSince(s.time), 300) / 60
            let x = (s.bpm - resting) / reserve
            if x >= fatBurnStart, minutes > 0 {
                load += perMinute(Swift.min(x, 1.1)) * minutes
                azm += (x >= cardioStart ? 2 : 1) * minutes
            }
            out.append((s.time, load, azm))
        }
        return out
    }

    /// Active Zone Minutes count fat-burn minutes once and cardio or peak minutes twice,
    /// which lands close to one unit of load per minute.
    static func fromActiveZoneMinutes(_ azm: Double) -> Double { azm * 0.95 }

    /// Weekly target until there are a few weeks of history (about 150 Active Zone Minutes).
    static let starterTarget = 150.0

    struct Week {
        let start: Date            // first day of the week (Monday or Sunday, from Settings)
        let load: Double           // from the start of the week up to the day shown
        let target: Double         // for the whole week
        let focus: CardioFocus     // never .auto: the focus Halo chose
        let baseline: Double?      // average of the four weeks before this one
        let days: [(date: Date, load: Double?)]   // all seven; nil for days still to come
        let daysElapsed: Int

        var progress: Double { target > 0 ? load / target : 0 }
        var remaining: Double { max(0, target - load) }
        /// Progress against where you'd be by now with an even spread over the week.
        var pace: Double { target > 0 ? load / (target * Double(daysElapsed) / 7) : 0 }
    }

    /// The calendar week containing `date` (up to `date`), with a target set from your recent weeks
    /// and your recovery.
    static func week(days: [DayMetrics], endingOn date: Date, chosen: CardioFocus, recovery: Double?) -> Week {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let start = WeekStart.start(of: day)
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        let window = (0..<7).compactMap { i -> (date: Date, load: Double?)? in
            guard let d = cal.date(byAdding: .day, value: i, to: start) else { return nil }
            return (date: d, load: d <= day ? (byDate[d]?.cardioLoad ?? 0) : nil)
        }
        let load = window.compactMap(\.load).reduce(0, +)
        let base = baseline(byDate: byDate, weekStart: start)

        var focus = chosen
        if focus == .auto {
            // Compare last week with your usual one (acute against chronic load).
            let lastWeek = weekTotal(byDate: byDate, start: cal.date(byAdding: .day, value: -7, to: start) ?? start)
            let ratio = base.map { (lastWeek ?? $0) / max($0, 1) } ?? 1
            let ready = recovery ?? 0.5
            if ready < 0.34 || ratio > 1.4 { focus = .recover }
            else if ready >= 0.6 && ratio < 1.05 { focus = .build }
            else { focus = .maintain }
        }
        let target = max(40, ((base ?? starterTarget) * focus.factor / 5).rounded() * 5)
        let elapsed = (cal.dateComponents([.day], from: start, to: day).day ?? 0) + 1
        return Week(start: start, load: load, target: target, focus: focus, baseline: base,
                    days: window, daysElapsed: min(7, max(1, elapsed)))
    }

    /// Average load of the four full weeks before `weekStart`. Needs two weeks with data.
    static func baseline(byDate: [Date: DayMetrics], weekStart: Date) -> Double? {
        let cal = Calendar.current
        let weeks = (1...4).compactMap { k in
            cal.date(byAdding: .day, value: -7 * k, to: weekStart).flatMap { weekTotal(byDate: byDate, start: $0) }
        }
        guard weeks.count >= 2 else { return nil }
        return weeks.reduce(0, +) / Double(weeks.count)
    }

    /// Total load of the seven days from `start`, if at least three of them have data.
    static func weekTotal(byDate: [Date: DayMetrics], start: Date) -> Double? {
        let cal = Calendar.current
        let loads = (0..<7).compactMap { i in cal.date(byAdding: .day, value: i, to: start).flatMap { byDate[$0]?.cardioLoad } }
        return loads.count >= 3 ? loads.reduce(0, +) : nil
    }

}
