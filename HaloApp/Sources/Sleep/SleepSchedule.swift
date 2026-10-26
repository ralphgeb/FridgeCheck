import Charts
import SwiftUI

/// Opens the sleep schedule page.
struct SleepScheduleRoute: Hashable {}

/// Bedtimes and wake times over a span: their averages, how much they wander, and how much you
/// slept. A steady schedule is half of good sleep, so this is what the page is about.
struct SleepSchedule {
    struct Night: Identifiable {
        let date: Date           // the day you woke up
        let bed: Double          // minutes after 6 pm the evening before
        let wake: Double
        let asleep: Double       // minutes
        var id: Date { date }
    }

    let nights: [Night]

    init(days: [DayMetrics]) {
        nights = days.compactMap { d in
            d.sleep.map { Night(date: d.date, bed: ScoreEngine.minutesAfterEvening($0.start),
                                wake: ScoreEngine.minutesAfterEvening($0.end), asleep: $0.minutesAsleep) }
        }
    }

    var averageBed: Double? { ScoreEngine.mean(nights.map(\.bed)) }
    var averageWake: Double? { ScoreEngine.mean(nights.map(\.wake)) }
    var averageAsleep: Double? { ScoreEngine.mean(nights.map(\.asleep)) }

    /// How far bedtime and wake time typically stray from their averages, in minutes.
    var bedSpread: Double? { Self.spread(nights.map(\.bed)) }
    var wakeSpread: Double? { Self.spread(nights.map(\.wake)) }

    /// 100 for clockwork, 0 when bed and wake times wander by an hour or more.
    var consistency: Double? {
        guard let b = bedSpread, let w = wakeSpread else { return nil }
        return ScoreEngine.clamp(1 - (b + w) / 2 / 60)
    }

    /// Weekends against weekdays: how much later the middle of your sleep falls ("social jet lag").
    var weekendShift: Double? {
        let cal = Calendar.current
        let mid = { (n: Night) in (n.bed + n.wake) / 2 }
        let weekend = nights.filter { [1, 7].contains(cal.component(.weekday, from: $0.date)) }.map(mid)
        let weekday = nights.filter { ![1, 7].contains(cal.component(.weekday, from: $0.date)) }.map(mid)
        guard let a = ScoreEngine.mean(weekend), let b = ScoreEngine.mean(weekday) else { return nil }
        return a - b
    }

    /// One bar per week (average bedtime to average wake), for the long spans.
    var weeks: [Night] {
        let groups = Dictionary(grouping: nights) { WeekStart.start(of: $0.date) }
        return groups.compactMap { start, ns in
            guard let b = ScoreEngine.mean(ns.map(\.bed)), let w = ScoreEngine.mean(ns.map(\.wake)),
                  let a = ScoreEngine.mean(ns.map(\.asleep)) else { return nil }
            return Night(date: start, bed: b, wake: w, asleep: a)
        }
        .sorted { $0.date < $1.date }
    }

    static func spread(_ v: [Double]) -> Double? {
        guard v.count >= 2, let m = ScoreEngine.mean(v) else { return nil }
        return sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count))
    }

    /// "11:12 pm" for a number of minutes after 6 pm.
    static func clock(_ minutes: Double) -> String {
        Format.time(ScoreEngine.eveningTime(minutes, on: Calendar.current.startOfDay(for: .now)))
    }
}

/// The schedule chart: a bar per night (or week) from bedtime down to wake time, with dashed
/// lines at your average bedtime and wake time. Earlier is higher, like a clock face read down.
struct ScheduleChart: View {
    let bars: [SleepSchedule.Night]
    let schedule: SleepSchedule
    let needMinutes: Double
    var weekly = false
    var selected: Date? = nil

    /// Every night for a week, every 7th night for a month, the first week of each month after that.
    private var xMarks: [Date] {
        if weekly { return bars.map(\.date).filter { Calendar.current.component(.day, from: $0) <= 7 } }
        if bars.count <= 7 { return bars.map(\.date) }
        return bars.map(\.date).enumerated().filter { $0.offset % 7 == bars.count % 7 }.map(\.element)
    }

    private func xLabel(_ d: Date) -> String {
        if weekly { return d.formatted(.dateTime.month(.abbreviated)) }
        if bars.count <= 7 { return d.formatted(.dateTime.weekday(.narrow)) }
        return "\(Calendar.current.component(.day, from: d)) \(d.formatted(.dateTime.month(.abbreviated)))"
    }

    var body: some View {
        let lo = ((bars.map(\.bed).min() ?? 240) / 60).rounded(.down) * 60
        let hi = ((bars.map(\.wake).max() ?? 780) / 60).rounded(.up) * 60
        Chart {
            ForEach(bars) { n in
                let isSelected = selected.map { Calendar.current.isDate($0, inSameDayAs: n.date) } ?? false
                BarMark(x: .value("Night", n.date, unit: weekly ? .weekOfYear : .day),
                        yStart: .value("Bed", -n.bed), yEnd: .value("Wake", -n.wake), width: .ratio(0.5))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.ink.opacity(n.asleep >= needMinutes ? 0.8 : 0.4))
                    .cornerRadius(5)
            }
            if let bed = schedule.averageBed {
                RuleMark(y: .value("Average bedtime", -bed))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Bed \(SleepSchedule.clock(bed))").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
            }
            if let wake = schedule.averageWake {
                RuleMark(y: .value("Average wake", -wake))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .annotation(position: .bottom, alignment: .leading, spacing: 2) {
                        Text("Wake \(SleepSchedule.clock(wake))").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
            }
        }
        .chartYScale(domain: -(hi + 30)...(-(lo - 30)))
        .chartYAxis {
            AxisMarks(position: .trailing, values: Array(stride(from: -hi, through: -lo, by: 120))) { v in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    Text(SleepSchedule.clock(-(v.as(Double.self) ?? 0)))
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xMarks) { v in
                AxisValueLabel {
                    Text(v.as(Date.self).map(xLabel) ?? "").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

/// On the Sleep page: the last seven nights with average lines and how steady they were.
struct SleepScheduleCard: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        let week = store.week(endingOn: store.selectedDate).map(\.day)
        let schedule = SleepSchedule(days: week)
        NavigationLink(value: SleepScheduleRoute()) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Sleep schedule · 7 nights").haloLabel()
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                ScheduleChart(bars: schedule.nights, schedule: schedule, needMinutes: store.targets.sleepNeedHours * 60,
                              selected: store.selectedDate)
                    .frame(height: 170)
                ScheduleFigures(schedule: schedule)
            }
            .haloCard()
        }
        .buttonStyle(.plain)
    }
}

struct ScheduleFigures: View {
    let schedule: SleepSchedule

    var body: some View {
        HStack(spacing: 0) {
            figure("Consistency", schedule.consistency.map { "\(Int(($0 * 100).rounded()))" } ?? "–",
                   accent: (schedule.consistency ?? 1) < 0.5)
            figure("Bedtime ±", schedule.bedSpread.map { Format.duration($0) } ?? "–")
            figure("Asleep", schedule.averageAsleep.map { Format.duration($0) } ?? "–")
        }
    }

    private func figure(_ title: String, _ value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).haloLabel()
            Text(value).font(Theme.number(17, weight: .medium)).foregroundStyle(accent ? Theme.accent : Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The full sleep schedule: 1W to 6M, averages, how steady you are, and weekends against weekdays.
struct SleepScheduleView: View {
    @EnvironmentObject private var store: HealthStore
    @Environment(\.openSettings) private var openSettings
    @State private var span: ChartSpan = .month

    var body: some View {
        let end = store.selectedDate
        let start = Calendar.current.date(byAdding: .day, value: -(span.days - 1), to: end) ?? end
        let days = store.days.filter { $0.date >= start && $0.date <= end }
        let schedule = SleepSchedule(days: days)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.range(start, end)).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("\(schedule.nights.count) nights").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 4)

                Picker("Range", selection: $span) {
                    ForEach(ChartSpan.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    ScheduleChart(bars: span.isWeekly ? schedule.weeks : schedule.nights, schedule: schedule,
                                  needMinutes: store.targets.sleepNeedHours * 60, weekly: span.isWeekly, selected: span.isWeekly ? nil : end)
                        .frame(height: 260)
                        .animation(.snappy, value: span)
                    HStack(spacing: 14) {
                        legend(Theme.accent, "Average bedtime")
                        legend(Theme.ink.opacity(0.6), "Average wake")
                        Spacer()
                    }
                    Text(span.isWeekly ? "Each bar is a week: average bedtime down to average wake time."
                                       : "Each bar is a night, darker when you slept your need.")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                .haloCard()

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    tile("Average bedtime", schedule.averageBed.map(SleepSchedule.clock) ?? "–",
                         schedule.bedSpread.map { "Varies by ±\(Format.duration($0))" })
                    tile("Average wake", schedule.averageWake.map(SleepSchedule.clock) ?? "–",
                         schedule.wakeSpread.map { "Varies by ±\(Format.duration($0))" })
                    tile("Average asleep", schedule.averageAsleep.map { Format.duration($0) } ?? "–",
                         "Need \(Format.duration(store.targets.sleepNeedHours * 60))")
                    tile("Weekends", schedule.weekendShift.map { shift in
                        abs(shift) < 10 ? "Same" : "\(Format.duration(abs(shift))) \(shift > 0 ? "later" : "earlier")"
                    } ?? "–", "Middle of your sleep vs weekdays")
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Consistency").haloLabel()
                        Spacer()
                        Text(schedule.consistency.map { "\(Int(($0 * 100).rounded()))" } ?? "–")
                            .font(Theme.number(28)).foregroundStyle((schedule.consistency ?? 1) < 0.5 ? Theme.accent : Theme.ink)
                        Text("/ 100").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(Theme.ink.opacity(0.7))
                                .frame(width: max(4, g.size.width * CGFloat(schedule.consistency ?? 0)))
                        }
                    }
                    .frame(height: 6)
                    Text("How close your bedtime and wake time stay to their averages. Going to bed and getting up within about 30 minutes of the same time every day, weekends included, helps you fall asleep faster and wake up clearer.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .haloCard()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Sleep schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openSettings) { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
        }
        .sensoryFeedback(.selection, trigger: span)
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 12, height: 1.5)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }

    private func tile(_ title: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).haloLabel()
            Text(value).font(Theme.number(22)).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .haloCard(padding: 14)
    }
}
