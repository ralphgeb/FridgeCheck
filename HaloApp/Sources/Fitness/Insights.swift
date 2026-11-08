import SwiftUI

// Activities read alongside everything else Halo keeps over the same days (sleep, recovery, HRV,
// steps, calories, cardio load), so a workout page and the Fitness tab can say what it meant, not
// just what it was. Works for every band: each line shows only when its data is there.

extension HealthStore {
    /// Every workout kept (the band's and the ones added by hand), oldest first.
    var allWorkouts: [Workout] {
        (days.flatMap { $0.workouts ?? [] } + manualWorkouts).sorted { $0.start < $1.start }
    }
}

/// One line of insight: a symbol, a short headline and a sentence.
struct InsightLine: Identifiable {
    let symbol: String
    let title: String
    let text: String
    var id: String { title + text }
}

/// A two-line stat in a grid.
struct InsightStat: Identifiable {
    let title: String
    let value: String
    var id: String { title }
}

private func signed(_ v: Double, _ unit: String, decimals: Bool = false) -> String {
    let n = decimals ? String(format: "%.1f", abs(v)) : "\(Int(abs(v).rounded()))"
    return "\(v >= 0 ? "+" : "−")\(n)\(unit)"
}

private struct InsightRows: View {
    let lines: [InsightLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(lines) { l in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: l.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent.opacity(0.16), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(l.text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - One workout, in depth

/// Below a workout's heart rate: more numbers, the band's own zones, how it compares with your
/// others of the same kind, the night and morning around it, and its share of the day and week.
struct WorkoutDeepDive: View {
    @EnvironmentObject private var store: HealthStore
    let workout: Workout
    /// The heart rate during it.
    let samples: [HeartSample]

    var body: some View {
        let type = store.activityType(workout)
        let ninetyDays = workout.start.addingTimeInterval(-90 * 86_400)
        let earlier = store.allWorkouts.filter {
            $0.id != workout.id && $0.start < workout.start && $0.start > ninetyDays && store.activityType($0) == type
        }
        VStack(alignment: .leading, spacing: 14) {
            let stats = moreStats(type)
            if !stats.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(stats) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s.title).haloLabel()
                            Text(s.value).font(Theme.number(20)).foregroundStyle(Theme.text)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .haloCard(padding: 14)
                    }
                }
            }
            if let zones = workout.bandZones, zones.reduce(0, +) > 0 {
                bandZones(zones)
            }
            section("Against your other \(type.title.lowercased())s", compare(earlier, type: type))
            section("Around it", around())
            section("Its share", share())
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ lines: [InsightLine]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).haloLabel()
                InsightRows(lines: lines)
            }
            .haloCard()
        }
    }

    // MARK: Numbers

    private func moreStats(_ type: ActivityType) -> [InsightStat] {
        var out: [InsightStat] = []
        let peak = workout.maxHeartRate ?? samples.map(\.bpm).max()
        if let peak { out.append(InsightStat(title: "Peak heart rate", value: "\(Int(peak)) bpm")) }
        if let strain = workout.strain { out.append(InsightStat(title: "Strain", value: String(format: "%.1f", strain))) }
        if let km = workout.distanceKm, km > 0.05, workout.minutes > 0 {
            if [.cycling, .indoorCycling].contains(type) {
                out.append(InsightStat(title: "Average speed", value: String(format: "%.1f km/h", km / (workout.minutes / 60))))
            } else {
                let pace = workout.minutes / km
                out.append(InsightStat(title: "Average pace", value: "\(Int(pace)):\(String(format: "%02d", Int((pace - Double(Int(pace))) * 60))) /km"))
            }
        }
        if let up = workout.elevationGainM, up >= 1 { out.append(InsightStat(title: "Climbed", value: "\(Int(up.rounded())) m")) }
        if let kcal = workout.calories, workout.minutes > 0 {
            out.append(InsightStat(title: "Burn rate", value: String(format: "%.1f kcal/min", kcal / workout.minutes)))
        }
        if let drop = heartRateRecovery() {
            out.append(InsightStat(title: "Recovery in 2 min", value: "−\(Int(drop)) bpm"))
        }
        if let avg = workout.averageHeartRate {
            let scale = store.zoneScale(for: store.day(workout.start) ?? DayMetrics(date: workout.start))
            let share = (avg - scale.resting) / max(scale.max - scale.resting, 1)
            out.append(InsightStat(title: "Of your heart's range", value: "\(Int((min(1, max(0, share)) * 100).rounded()))%"))
        }
        return out
    }

    /// How far your heart rate fell in the two minutes after you stopped: a sign of fitness.
    private func heartRateRecovery() -> Double? {
        let end = workout.end
        let lastMinutes = samples.filter { $0.time >= end.addingTimeInterval(-120) }.map(\.bpm)
        let after = store.heartSamples(from: end.addingTimeInterval(60), to: end.addingTimeInterval(180)).map(\.bpm)
        guard let top = lastMinutes.max(), let low = after.min(), top > low else { return nil }
        return top - low
    }

    /// Whoop's zones: shares of its max heart rate.
    private func bandZones(_ zones: [Double]) -> some View {
        let total = max(zones.reduce(0, +), 1)
        let names = ["Zone 0", "Zone 1", "Zone 2", "Zone 3", "Zone 4", "Zone 5"]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Time in each zone").haloLabel()
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { i, m in
                        if m > 0 {
                            Rectangle()
                                .fill(i >= 4 ? Theme.accent : Theme.ink.opacity(0.15 + 0.15 * Double(i)))
                                .frame(width: max(2, (g.size.width - 10) * CGFloat(m / total)))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 12)
            HStack(spacing: 0) {
                ForEach(Array(zones.enumerated()), id: \.offset) { i, m in
                    VStack(spacing: 2) {
                        Text("\(Int(m.rounded()))m").font(Theme.number(13, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(names[min(i, names.count - 1)]).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text("From your band: each zone is a share of the max heart rate it set for you.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .haloCard()
    }

    // MARK: Against the others

    private func compare(_ earlier: [Workout], type: ActivityType) -> [InsightLine] {
        var out: [InsightLine] = []
        let name = type.title.lowercased()
        out.append(InsightLine(symbol: "number", title: earlier.isEmpty ? "Your first \(name) in 90 days" : "Your \(ordinal(earlier.count + 1)) \(name) in 90 days",
                               text: earlier.isEmpty ? "Halo will compare the next ones with this." : "\(Format.duration(earlier.reduce(0) { $0 + $1.minutes } + workout.minutes)) of it altogether."))
        guard !earlier.isEmpty else { return out }
        let avgMinutes = earlier.reduce(0) { $0 + $1.minutes } / Double(earlier.count)
        if workout.minutes > (earlier.map(\.minutes).max() ?? .infinity) {
            out.append(InsightLine(symbol: "trophy", title: "Your longest in 90 days",
                                   text: "\(Format.duration(workout.minutes)), against \(Format.duration(avgMinutes)) usually."))
        } else if abs(workout.minutes - avgMinutes) >= 3 {
            out.append(InsightLine(symbol: "clock", title: "\(Format.duration(abs(workout.minutes - avgMinutes))) \(workout.minutes > avgMinutes ? "longer" : "shorter") than usual",
                                   text: "Your \(name)s last \(Format.duration(avgMinutes)) on average."))
        }
        let hrs = earlier.compactMap(\.averageHeartRate)
        if let hr = workout.averageHeartRate, let usual = ScoreEngine.mean(hrs), hrs.count >= 2 {
            let d = hr - usual
            out.append(InsightLine(symbol: "heart", title: abs(d) < 3 ? "A usual effort" : (d > 0 ? "Harder than usual" : "Easier than usual"),
                                   text: "Average \(Int(hr)) bpm, \(signed(d, " bpm")) on your usual \(Int(usual))."))
        }
        let kcals = earlier.compactMap(\.calories)
        if let kcal = workout.calories, let usual = ScoreEngine.mean(kcals), kcals.count >= 2, usual > 0 {
            out.append(InsightLine(symbol: "flame", title: "\(Int(kcal)) kcal",
                                   text: "\(signed((kcal / usual - 1) * 100, "%")) on what your \(name)s usually burn."))
        }
        if let km = workout.distanceKm, km > 0.05 {
            let paces = earlier.compactMap { w in w.distanceKm.flatMap { $0 > 0.05 ? w.minutes / $0 : nil } }
            if let usual = ScoreEngine.mean(paces), paces.count >= 2 {
                let pace = workout.minutes / km
                let faster = pace < usual
                out.append(InsightLine(symbol: "speedometer", title: faster ? "Quicker than usual" : "Steadier than usual",
                                       text: "\(Int((abs(1 - pace / usual) * 100).rounded()))% \(faster ? "faster" : "slower") per km than your average."))
            }
        }
        return out
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (1, let t) where t != 11: suffix = "st"
        case (2, let t) where t != 12: suffix = "nd"
        case (3, let t) where t != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    // MARK: The night and morning around it

    private func around() -> [InsightLine] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: workout.start)
        var out: [InsightLine] = []
        if let rec = store.scores(for: day).recovery {
            let hour = cal.component(.hour, from: workout.start)
            out.append(InsightLine(symbol: "sunrise", title: "You started the day at \(rec.percentText)",
                                   text: rec >= 0.67 ? "Well recovered: a good day to push, and you \(hour < 12 ? "went early" : "used it")." :
                                         rec >= 0.34 ? "A middling morning, so a steady session suited it." :
                                         "A low-recovery morning: hard sessions on days like this take longer to bounce back from."))
        }
        guard let next = cal.date(byAdding: .day, value: 1, to: day), let nextDay = store.day(next) else { return out }
        if let s = nextDay.sleep {
            let usual = ScoreEngine.mean(store.days.filter { $0.date < next && $0.date >= next.addingTimeInterval(-30 * 86_400) }
                .compactMap { $0.sleep?.minutesAsleep })
            let text = usual.map { u in
                let d = s.minutesAsleep - u
                return abs(d) < 10 ? "About your usual." : "\(Format.duration(abs(d))) \(d > 0 ? "more" : "less") than your usual \(Format.duration(u))."
            } ?? "Asleep \(Format.time(s.start)) to \(Format.time(s.end))."
            out.append(InsightLine(symbol: "moon", title: "Slept \(Format.duration(s.minutesAsleep)) that night", text: text))
        }
        if let hrv = nextDay.hrv, let base = store.baseline(.hrv, before: next), base > 0 {
            let d = (hrv / base - 1) * 100
            out.append(InsightLine(symbol: "waveform.path.ecg", title: "Next morning's HRV \(signed(d, "%"))",
                                   text: d < -8 ? "Your body was still working through it." :
                                         d > 8 ? "You bounced back above your usual." : "Right around your usual: well absorbed."))
        }
        if let rec = store.scores(for: next).recovery {
            out.append(InsightLine(symbol: "bolt.heart", title: "Recovery \(rec.percentText) the morning after", text:
                                    rec >= 0.67 ? "Fully ready again." : rec >= 0.34 ? "Partly recovered." : "Take it easier after sessions like this."))
        }
        return out
    }

    // MARK: Its share of the day and week

    private func share() -> [InsightLine] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: workout.start)
        guard let day = store.day(dayStart) else { return [] }
        var out: [InsightLine] = []
        if let kcal = workout.calories, let active = day.activeCalories, active > 0 {
            out.append(InsightLine(symbol: "flame", title: "\(Int((min(1, kcal / active) * 100).rounded()))% of the day's active calories",
                                   text: "\(Int(kcal)) of \(Int(active)) kcal burned on the move."))
        }
        if let hourly = day.hourlySteps {
            var steps = 0.0
            for h in 0..<min(24, hourly.count) {
                guard let from = cal.date(byAdding: .hour, value: h, to: dayStart) else { continue }
                let to = from.addingTimeInterval(3600)
                let overlap = min(to, workout.end).timeIntervalSince(max(from, workout.start))
                if overlap > 0 { steps += hourly[h] * overlap / 3600 }
            }
            if steps >= 200, let total = day.steps, total > 0 {
                out.append(InsightLine(symbol: "figure.walk", title: "About \(Int((steps / 100).rounded()) * 100) steps",
                                       text: "\(Int((min(1, steps / Double(total)) * 100).rounded()))% of the day's \(total.formatted())."))
            }
        }
        if samples.count >= 4, let dayLoad = day.cardioLoad, dayLoad > 0 {
            let scale = store.zoneScale(for: day)
            let load = CardioLoad.fromHeartRate(samples, resting: scale.resting, max: scale.max, maxGap: 300).load
            if load > 0 {
                let week = store.cardioWeek(endingOn: dayStart)
                out.append(InsightLine(symbol: "chart.bar.fill", title: "\(Int((min(1, load / dayLoad) * 100).rounded()))% of the day's cardio load",
                                       text: "About \(Int(load.rounded())) of \(Int(dayLoad.rounded())), and \(Int((min(1, load / max(week.target, 1)) * 100).rounded()))% of the week's target."))
            }
        }
        return out
    }
}

// MARK: - The Fitness tab

/// What your last two months of activity say, read across workouts, steps, cardio load, sleep and
/// recovery. Each line shows once there's enough to say it.
struct FitnessInsightsCard: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        let lines = insights()
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Insights · last 60 days").haloLabel()
                    Spacer()
                }
                InsightRows(lines: lines)
            }
            .haloCard()
        }
    }

    private func insights() -> [InsightLine] {
        let cal = Calendar.current
        let end = cal.startOfDay(for: store.selectedDate)
        let from = end.addingTimeInterval(-59 * 86_400)
        let days = store.days.filter { $0.date >= from && $0.date <= end }
        let workouts = store.allWorkouts.filter { $0.start >= from && $0.start < end.addingTimeInterval(86_400) }
        let workoutDays = Set(workouts.map { cal.startOfDay(for: $0.start) })
        var out: [InsightLine] = []

        // this month against last
        let monthStart = cal.dateInterval(of: .month, for: end)?.start ?? end
        let lastMonthStart = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let dayOfMonth = cal.component(.day, from: end)
        let thisMonth = store.allWorkouts.filter { $0.start >= monthStart && $0.start < end.addingTimeInterval(86_400) }
        let lastMonthSoFar = store.allWorkouts.filter {
            $0.start >= lastMonthStart && $0.start < (cal.date(byAdding: .day, value: dayOfMonth, to: lastMonthStart) ?? monthStart)
        }
        if !thisMonth.isEmpty || !lastMonthSoFar.isEmpty {
            let a = thisMonth.reduce(0) { $0 + $1.minutes }, b = lastMonthSoFar.reduce(0) { $0 + $1.minutes }
            out.append(InsightLine(symbol: "calendar", title: "\(thisMonth.count) workout\(thisMonth.count == 1 ? "" : "s") this month, \(Format.duration(a))",
                                   text: b > 0 ? "\(a >= b ? "Ahead of" : "Behind") last month by this date (\(lastMonthSoFar.count), \(Format.duration(b)))."
                                               : "Nothing by this date last month."))
        }

        // favourite activity
        let byType = Dictionary(grouping: workouts) { store.activityType($0) }
        if let fav = byType.max(by: { $0.value.reduce(0) { $0 + $1.minutes } < $1.value.reduce(0) { $0 + $1.minutes } }), fav.value.count >= 2 {
            out.append(InsightLine(symbol: fav.key.symbol, title: "\(fav.key.title) is your thing",
                                   text: "\(fav.value.count) sessions, \(Format.duration(fav.value.reduce(0) { $0 + $1.minutes })) in two months\(byType.count > 1 ? ", ahead of \(byType.count - 1) other kind\(byType.count == 2 ? "" : "s")" : "")."))
        }

        // busiest day of the week
        let loads = days.compactMap { d in d.cardioLoad.map { (weekday: cal.component(.weekday, from: d.date), load: $0) } }
        if loads.count >= 14 {
            let byDay = Dictionary(grouping: loads, by: { $0.weekday }).mapValues { ScoreEngine.mean($0.map { $0.load }) ?? 0 }
            if let top = byDay.max(by: { $0.value < $1.value }), let low = byDay.min(by: { $0.value < $1.value }), top.value > 0 {
                let name = cal.weekdaySymbols[top.key - 1], quiet = cal.weekdaySymbols[low.key - 1]
                out.append(InsightLine(symbol: "chart.bar.xaxis", title: "\(name)s are your big days",
                                       text: "Cardio load \(Int(top.value.rounded())) on average, against \(Int(low.value.rounded())) on \(quiet)s."))
            }
        }

        // the morning after a hard day
        let pairs = days.compactMap { d -> (load: Double, next: Double)? in
            guard let load = d.cardioLoad, let next = cal.date(byAdding: .day, value: 1, to: d.date),
                  let rec = store.scores(for: next).recovery, store.day(next) != nil else { return nil }
            return (load, rec)
        }
        if pairs.count >= 12 {
            let sorted = pairs.sorted { $0.load < $1.load }
            let third = sorted.count / 3
            let easy = ScoreEngine.mean(sorted.prefix(third).map { $0.next }) ?? 0
            let hard = ScoreEngine.mean(sorted.suffix(third).map { $0.next }) ?? 0
            out.append(InsightLine(symbol: "arrow.triangle.2.circlepath", title: "Hard days cost you \(max(0, Int(((easy - hard) * 100).rounded()))) points",
                                   text: "Next-morning recovery is \(hard.percentText) after your hardest days and \(easy.percentText) after your easiest."))
        }

        // sleep after workouts
        let nights = days.compactMap { d -> (worked: Bool, asleep: Double)? in
            guard let next = cal.date(byAdding: .day, value: 1, to: d.date), let s = store.day(next)?.sleep else { return nil }
            return (workoutDays.contains(d.date), s.minutesAsleep)
        }
        let afterWork = nights.filter { $0.worked }.map { $0.asleep }
        let afterRest = nights.filter { !$0.worked }.map { $0.asleep }
        if afterWork.count >= 4, afterRest.count >= 4, let a = ScoreEngine.mean(afterWork), let b = ScoreEngine.mean(afterRest) {
            let d = a - b
            out.append(InsightLine(symbol: "moon.stars", title: abs(d) < 8 ? "Workouts don't change your sleep" : "You sleep \(Format.duration(abs(d))) \(d > 0 ? "more" : "less") after a workout",
                                   text: "\(Format.duration(a)) after workout days, \(Format.duration(b)) after rest days."))
        }

        // steps on workout days
        let stepsWork = days.filter { workoutDays.contains($0.date) }.compactMap(\.steps)
        let stepsRest = days.filter { !workoutDays.contains($0.date) && $0.date < end }.compactMap(\.steps)
        if stepsWork.count >= 4, stepsRest.count >= 4,
           let a = ScoreEngine.mean(stepsWork.map(Double.init)), let b = ScoreEngine.mean(stepsRest.map(Double.init)), b > 0 {
            out.append(InsightLine(symbol: "figure.walk", title: "\(signed((a / b - 1) * 100, "%")) steps on workout days",
                                   text: "\(Int(a).formatted()) a day when you train, \(Int(b).formatted()) when you rest."))
        }

        // when you train
        if workouts.count >= 5 {
            let hours = workouts.map { cal.component(.hour, from: $0.start) }
            let parts: [(name: String, range: Range<Int>)] = [("mornings", 5..<12), ("afternoons", 12..<17), ("evenings", 17..<23)]
            if let best = parts.max(by: { p, q in hours.filter { p.range.contains($0) }.count < hours.filter { q.range.contains($0) }.count }) {
                let n = hours.filter { best.range.contains($0) }.count
                out.append(InsightLine(symbol: "clock", title: "A creature of \(best.name)",
                                       text: "\(Int((Double(n) / Double(hours.count) * 100).rounded()))% of your workouts start then."))
            }
        }

        // streaks of active days
        let activeDays = Set(days.filter { d in workoutDays.contains(d.date) || ScoreEngine.zonePoints(d) >= 30 }.map(\.date))
        var best = 0, run = 0, current = 0
        var d = from
        while d <= end {
            if activeDays.contains(d) { run += 1; best = max(best, run) } else { run = 0 }
            d = cal.date(byAdding: .day, value: 1, to: d) ?? end.addingTimeInterval(86_400)
        }
        current = run
        if best >= 3 {
            out.append(InsightLine(symbol: "flame.fill", title: current >= 2 ? "\(current) active days in a row" : "Best run: \(best) active days",
                                   text: current >= 2 ? "Your best in two months is \(best)." : "An active day is a workout or 30 active minutes."))
        }
        return out
    }
}
