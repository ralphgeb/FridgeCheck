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

    /// Active Zone Minutes count fat-burn minutes once and cardio or peak minutes twice,
    /// which lands close to one unit of load per minute.
    static func fromActiveZoneMinutes(_ azm: Double) -> Double { azm * 0.95 }

    /// Weekly target until there are a few weeks of history (about 150 Active Zone Minutes).
    static let starterTarget = 150.0

    struct Week {
        let load: Double           // the last seven days, including today
        let target: Double
        let focus: CardioFocus     // never .auto: the focus Halo chose
        let baseline: Double?      // average week over the four before this one
        let days: [(date: Date, load: Double)]

        var progress: Double { target > 0 ? load / target : 0 }
        var remaining: Double { max(0, target - load) }
    }

    /// The seven days ending on `date`, with a target set from your recent weeks and today's recovery.
    static func week(days: [DayMetrics], endingOn date: Date, chosen: CardioFocus, recovery: Double?) -> Week {
        let cal = Calendar.current
        let end = cal.startOfDay(for: date)
        let base = baseline(days: days, before: end)
        let start = cal.date(byAdding: .day, value: -6, to: end) ?? end
        let window = (0..<7).compactMap { i -> (date: Date, load: Double)? in
            guard let d = cal.date(byAdding: .day, value: i, to: start) else { return nil }
            return (date: d, load: days.first { $0.date == d }?.cardioLoad ?? 0)
        }
        let load = window.reduce(0) { $0 + $1.load }

        var focus = chosen
        if focus == .auto {
            // Compare the last full week with your usual one (acute against chronic load).
            let lastWeek = sum(days: days, endingOn: cal.date(byAdding: .day, value: -1, to: end) ?? end)
            let ratio = base.map { lastWeek / max($0, 1) } ?? 1
            let ready = recovery ?? 0.5
            if ready < 0.34 || ratio > 1.4 { focus = .recover }
            else if ready >= 0.6 && ratio < 1.05 { focus = .build }
            else { focus = .maintain }
        }
        let target = max(40, ((base ?? starterTarget) * focus.factor / 5).rounded() * 5)
        return Week(load: load, target: target, focus: focus, baseline: base, days: window)
    }

    /// Average weekly load over the four weeks before `end`'s week. Needs two weeks with data.
    static func baseline(days: [DayMetrics], before end: Date) -> Double? {
        let cal = Calendar.current
        let weeks = (1...4).compactMap { k -> Double? in
            guard let e = cal.date(byAdding: .day, value: -7 * k, to: end),
                  let s = cal.date(byAdding: .day, value: -6, to: e) else { return nil }
            let inWeek = days.filter { $0.date >= s && $0.date <= e }
            guard inWeek.filter({ $0.cardioLoad != nil }).count >= 3 else { return nil }
            return inWeek.compactMap(\.cardioLoad).reduce(0, +)
        }
        guard weeks.count >= 2 else { return nil }
        return weeks.reduce(0, +) / Double(weeks.count)
    }

    static func sum(days: [DayMetrics], endingOn date: Date) -> Double {
        let cal = Calendar.current
        let end = cal.startOfDay(for: date)
        guard let start = cal.date(byAdding: .day, value: -6, to: end) else { return 0 }
        return days.filter { $0.date >= start && $0.date <= end }.compactMap(\.cardioLoad).reduce(0, +)
    }
}
