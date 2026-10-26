import Charts
import SwiftUI

/// The graph page for any metric: 1W and 1M show each day; 3M and 6M show one vertical line per week
/// (lowest to highest day) with a dot at the week's average. The dotted accent line is the average.
/// Drag across the chart to read a value; the arrows step back and forward a whole span.
struct MetricDetailView: View {
    @EnvironmentObject private var store: HealthStore
    @Environment(\.openSettings) private var openSettings
    let metric: Metric
    @State private var span: ChartSpan = .week
    @State private var scrub: Date?
    /// Last day shown. Starts on the day picked in the app.
    @State private var endDate: Date?

    private struct Week: Identifiable {
        let start: Date
        let low: Double
        let high: Double
        let average: Double
        var id: Date { start }
    }

    private var end: Date { endDate ?? store.selectedDate }
    private var start: Date { Calendar.current.date(byAdding: .day, value: -(span.days - 1), to: end) ?? end }
    private var canGoBack: Bool { start > store.firstDate }
    private var canGoForward: Bool { !Calendar.current.isDateInToday(end) }

    var body: some View {
        let points = store.series(metric, days: span.days, endingOn: end)
        let previous = previousAverage()
        let weeks = weekly(points)
        let average = ScoreEngine.mean(points.map { $0.value })
        let range = metric.showsRange ? store.normalRange(metric, before: end) : nil

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                periodBar
                readout(points: points, weeks: weeks, average: average, previous: previous)

                Picker("Range", selection: $span) {
                    ForEach(ChartSpan.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    chart(points: points, weeks: weeks, range: range, average: average)
                        .frame(height: 240)
                        .animation(.snappy, value: span)
                    legend(range: range, average: average)
                }
                .haloCard()

                stats(points: points, range: range)

                if let kind = metric.scoreKind {
                    FactorsCard(factors: store.factors(kind, on: end), day: end)
                }

                Text(metric.about)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .haloCard()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .sensoryFeedback(.selection, trigger: span)
        .sensoryFeedback(.selection, trigger: endDate)
    }

    /// The dates on show, with a round button either side to step a whole span back or forward.
    private var periodBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.range(start, end))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(canGoForward ? "\(span.days) days" : "\(span.days) days to today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            stepButton("chevron.left", enabled: canGoBack, label: "Previous \(span.name)") { shift(-1) }
            stepButton("chevron.right", enabled: canGoForward, label: "Next \(span.name)") { shift(1) }
        }
        .padding(.top, 4)
    }

    private func stepButton(_ symbol: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40)
                .background(Theme.card, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func shift(_ direction: Int) {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .day, value: direction * span.days, to: end) else { return }
        let today = cal.startOfDay(for: .now)
        withAnimation(.snappy) {
            scrub = nil
            endDate = min(today, max(next, cal.date(byAdding: .day, value: span.days - 1, to: store.firstDate) ?? next))
        }
    }

    private func legend(range: NormalRange?, average: Double?) -> some View {
        HStack(spacing: 14) {
            if let average {
                HStack(spacing: 5) {
                    Rectangle().fill(Theme.accent).frame(width: 12, height: 1.5).mask(dashes)
                    Text("Average \(metric.format(average))")
                }
            }
            if range != nil, !span.isWeekly {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.track).frame(width: 12, height: 8)
                    Text("Your normal")
                }
            }
            if span.isWeekly {
                HStack(spacing: 5) {
                    Capsule().fill(Theme.ink.opacity(0.22)).frame(width: 4, height: 12)
                    Text("Week low to high")
                }
            }
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.secondary)
    }

    private var dashes: some View {
        HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Rectangle().frame(width: 3) } }
    }

    // MARK: Readout

    private func readout(points: [(date: Date, value: Double)], weeks: [Week], average: Double?, previous: Double?) -> some View {
        var label = "Average"
        var value = average
        if let scrub {
            if span.isWeekly, let w = weeks.last(where: { $0.start <= scrub }) {
                label = "Week of \(w.start.formatted(.dateTime.day().month(.abbreviated)))"
                value = w.average
            } else if let p = points.min(by: { abs($0.date.timeIntervalSince(scrub)) < abs($1.date.timeIntervalSince(scrub)) }) {
                label = Format.dayTitle(p.date)
                value = p.value
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).haloLabel()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.map(metric.format) ?? "–").font(Theme.number(48)).foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                if !metric.unit.isEmpty { Text(metric.unit).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.secondary) }
            }
            if scrub == nil, let average, let previous, previous != 0 {
                let d = average / previous - 1
                let good = metric.higherIsBetter.map { (d >= 0) == $0 }
                Text("\(d >= 0 ? "Up" : "Down") \(Int((abs(d) * 100).rounded()))% on the previous \(span.name)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(abs(d) < 0.02 || good == nil ? Theme.secondary : (good == true ? Theme.ink : Theme.accent))
            } else {
                Text(" ").font(.system(size: 13))
            }
        }
        .padding(.top, 8)
        .animation(.snappy, value: scrub)
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(points: [(date: Date, value: Double)], weeks: [Week], range: NormalRange?, average: Double?) -> some View {
        let isSelected: (Date) -> Bool = { Calendar.current.isDate($0, inSameDayAs: scrub ?? end) }
        if points.isEmpty {
            Text("No data for this \(span.name).").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if span.isWeekly {
            Chart {
                ForEach(weeks) { w in
                    let on = scrub.map { $0 >= w.start && $0 < w.start.addingTimeInterval(7 * 86_400) } ?? false
                    RuleMark(x: .value("Week", w.start, unit: .weekOfYear),
                             yStart: .value("Low", w.low), yEnd: .value("High", w.high))
                        .foregroundStyle(on ? Theme.accent.opacity(0.5) : Theme.ink.opacity(0.22))
                        .lineStyle(StrokeStyle(lineWidth: span == .threeMonths ? 9 : 6, lineCap: .round))
                    PointMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Average", w.average))
                        .foregroundStyle(on ? Theme.accent : Theme.ink)
                        .symbolSize(span == .threeMonths ? 36 : 22)
                }
                if let average { averageLine(average) }
            }
            .chartXSelection(value: $scrub)
            .chartYScale(domain: .automatic(includesZero: metric.style == .bar))
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated)).foregroundStyle(Theme.tertiary)
                }
            }
            .chartYAxis { yAxis }
        } else {
            Chart {
                if let range, let first = points.first, let last = points.last {
                    RectangleMark(xStart: .value("Start", first.date, unit: .day), xEnd: .value("End", last.date, unit: .day),
                                  yStart: .value("Low", range.low), yEnd: .value("High", range.high))
                        .foregroundStyle(Theme.track)
                }
                ForEach(points, id: \.date) { p in
                    if metric.style == .bar {
                        BarMark(x: .value("Day", p.date, unit: .day), y: .value(metric.title, p.value), width: .ratio(0.55))
                            .foregroundStyle(isSelected(p.date) ? Theme.accent : Theme.ink.opacity(0.85))
                            .cornerRadius(4)
                    } else {
                        LineMark(x: .value("Day", p.date, unit: .day), y: .value(metric.title, p.value))
                            .foregroundStyle(Theme.ink)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Day", p.date, unit: .day), y: .value(metric.title, p.value))
                            .foregroundStyle(isSelected(p.date) ? Theme.accent : Theme.ink)
                            .symbolSize(isSelected(p.date) ? 60 : (span == .week ? 24 : 0))
                    }
                }
                if let average { averageLine(average) }
            }
            .chartXSelection(value: $scrub)
            .chartYScale(domain: .automatic(includesZero: metric.style == .bar))
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: span == .week ? 1 : 7)) { _ in
                    AxisValueLabel(format: span == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .chartYAxis { yAxis }
        }
    }

    private func averageLine(_ average: Double) -> some ChartContent {
        RuleMark(y: .value("Average", average))
            .foregroundStyle(Theme.accent)
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
    }

    private var yAxis: some AxisContent {
        // time asleep reads in hours, one line per hour
        AxisMarks(position: .trailing, values: metric == .sleepDuration ? AxisMarkValues.stride(by: 60) : AxisMarkValues.automatic) { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel {
                if let v = value.as(Double.self) {
                    Text(metric == .sleepDuration ? "\(Int((v / 60).rounded()))h" : metric.format(v))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }


    // MARK: Stats

    private func stats(points: [(date: Date, value: Double)], range: NormalRange?) -> some View {
        let values = points.map { $0.value }
        return HStack(spacing: 12) {
            stat("Lowest", values.min())
            stat("Highest", values.max())
            if let range {
                stat("Normal", nil, text: "\(metric.format(range.low))–\(metric.format(range.high))")
            } else {
                stat(metric.style == .bar ? "Total" : "Days", metric.style == .bar ? values.reduce(0, +) : nil,
                     text: metric.style == .bar ? nil : "\(values.count)")
            }
        }
    }

    private func stat(_ title: String, _ value: Double?, text: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).haloLabel()
            Text(text ?? value.map(metric.format) ?? "–")
                .font(Theme.number(17)).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .haloCard(padding: 14)
    }

    // MARK: Data

    private func weekly(_ points: [(date: Date, value: Double)]) -> [Week] {
        let cal = WeekStart.calendar
        let groups = Dictionary(grouping: points) { cal.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? $0.date }
        return groups.compactMap { start, items in
            let v = items.map { $0.value }
            guard let lo = v.min(), let hi = v.max(), let avg = ScoreEngine.mean(v) else { return nil }
            return Week(start: start, low: lo, high: hi, average: avg)
        }
        .sorted { $0.start < $1.start }
    }

    /// Average of the span just before this one, for the "up 4%" line.
    private func previousAverage() -> Double? {
        guard let before = Calendar.current.date(byAdding: .day, value: -span.days, to: end) else { return nil }
        return ScoreEngine.mean(store.series(metric, days: span.days, endingOn: before).map { $0.value })
    }
}

// MARK: - What goes into a score

/// The things a score takes into account, each with today's value, what it's compared with,
/// how well it did and how much it counts. Words, not a formula.
struct FactorsCard: View {
    let factors: [ScoreEngine.Factor]
    let day: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("What goes into it").haloLabel()
                Spacer()
                Text(Format.dayTitle(day)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            if factors.isEmpty {
                Text("No data for this day.").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            ForEach(factors) { f in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(f.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(f.weight.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6)
                            .foregroundStyle(Theme.tertiary)
                        Spacer()
                        Text(f.value).font(Theme.number(16, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill((f.level ?? 0) < 0.34 ? Theme.accent : Theme.ink.opacity(0.7))
                                .frame(width: max(3, g.size.width * CGFloat(f.level ?? 0)))
                        }
                    }
                    .frame(height: 4)
                    Text(f.note).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if f.id != factors.last?.id { Divider().overlay(Theme.hairline) }
            }
        }
        .haloCard()
    }
}

/// Opens Settings from anywhere (set by the root view).
private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openSettings: () -> Void {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}
