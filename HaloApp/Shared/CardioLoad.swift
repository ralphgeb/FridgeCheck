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
    /// Load starts a little below the zones, like Google's: a brisk walk adds a few points, sitting
    /// adds none. (At this share a minute is worth about a third of a moderate minute.)
    static let loadStart = 0.3

    /// The bpm where a zone starts, for this resting and max heart rate.
    static func bpm(atReserve share: Double, resting: Double, max: Double) -> Double {
        resting + share * (max - resting)
    }

    /// Each reading's share of heart-rate reserve and the minutes it counts for: the time until the
    /// next reading (at most `maxGap`), and only when the time in a zone lasts. A reading in a zone
    /// needs a neighbour in a zone within a few minutes, so a lone spike (standing up, a flight of
    /// stairs) adds nothing. Raw readings use a 2-minute cap; the 5-minute averages kept for charts
    /// stand for 5 minutes each.
    static func credited(_ samples: [HeartSample], resting: Double, max maxHR: Double,
                         maxGap: TimeInterval = 120) -> [(time: Date, minutes: Double, x: Double)] {
        let sorted = samples.sorted { $0.time < $1.time }
        let reserve = Swift.max(maxHR - resting, 1)
        let xs = sorted.map { ($0.bpm - resting) / reserve }
        let near = maxGap + 60
        func inZone(_ j: Int, nearTo i: Int) -> Bool {
            j >= 0 && j < sorted.count && xs[j] >= loadStart && abs(sorted[j].time.timeIntervalSince(sorted[i].time)) <= near
        }
        return sorted.indices.map { i in
            let s = sorted[i]
            let next = i + 1 < sorted.count ? sorted[i + 1].time : s.time.addingTimeInterval(60)
            let minutes = Swift.min(next.timeIntervalSince(s.time), maxGap) / 60
            let lasts = xs[i] >= loadStart && (inZone(i - 1, nearTo: i) || inZone(i + 1, nearTo: i))
            return (s.time, lasts ? minutes : 0, xs[i])
        }
    }

    /// Load and zone minutes worked out from heart-rate readings.
    static func fromHeartRate(_ samples: [HeartSample], resting: Double, max maxHR: Double,
                              maxGap: TimeInterval = 120) -> (load: Double, zones: ZoneMinutes) {
        var load = 0.0
        var z = ZoneMinutes()
        for r in credited(samples, resting: resting, max: maxHR, maxGap: maxGap) where r.minutes > 0 {
            load += perMinute(Swift.min(r.x, 1.1)) * r.minutes
            if r.x >= peakStart { z.peak += r.minutes }
            else if r.x >= cardioStart { z.cardio += r.minutes }
            else if r.x >= fatBurnStart { z.fatBurn += r.minutes }
        }
        return (load, z)
    }

    /// The same, as running totals through the day: load and Active Zone Minutes (moderate once,
    /// cardio and peak twice) after each reading. For the day graphs.
    static func timeline(_ samples: [HeartSample], resting: Double, max maxHR: Double,
                         maxGap: TimeInterval = 300) -> [(time: Date, load: Double, azm: Double)] {
        var load = 0.0, azm = 0.0
        return credited(samples, resting: resting, max: maxHR, maxGap: maxGap).map { r in
            if r.minutes > 0 {
                load += perMinute(Swift.min(r.x, 1.1)) * r.minutes
                if r.x >= fatBurnStart { azm += (r.x >= cardioStart ? 2 : 1) * r.minutes }
            }
            return (r.time, load, azm)
        }
    }

    /// Active Zone Minutes count moderate minutes once and cardio or peak minutes twice,
    /// which lands close to one unit of load per minute.
    static func fromActiveZoneMinutes(_ azm: Double) -> Double { azm * 0.95 }

    /// The weekly target never goes below this, and it's the target until there are a few weeks of
    /// history.
    static let minimumTarget = 210.0

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
        let target = max(minimumTarget, ((base ?? minimumTarget) * focus.factor / 5).rounded() * 5)
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
