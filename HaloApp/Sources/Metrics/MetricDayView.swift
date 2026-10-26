import Charts
import SwiftUI

/// The 1D view of a graph page: one day, midnight to midnight. Heart rate reading by reading with
/// your resting line, steps and calories hour by hour, cardio load and zone minutes as a running
/// total, and sleep as its stages. Drag across the chart to read a moment.
struct MetricDayView: View {
    @EnvironmentObject private var store: HealthStore
    let metric: Metric
    let day: Date
    @Binding var scrub: Date?

    var body: some View {
        if metric == .sleepDuration {
            sleep
        } else if let series = store.intraday(metric, on: day) {
            readout(series)
            VStack(alignment: .leading, spacing: 12) {
                chart(series).frame(height: 240)
                legend(series)
            }
            .haloCard()
            stats(series)
        } else {
            Text(Calendar.current.isDateInToday(day) || day > Date.now.addingTimeInterval(-14 * 86_400)
                 ? "No hour-by-hour data for this day yet."
                 : "Hour-by-hour data is kept for the last two weeks.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 240)
                .haloCard()
        }
    }

    // MARK: Sleep

    @ViewBuilder
    private var sleep: some View {
        let session = store.day(day)?.sleep
        VStack(alignment: .leading, spacing: 4) {
            Text("Time asleep").haloLabel()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.map { Format.duration($0.minutesAsleep) } ?? "–").font(Theme.number(48)).foregroundStyle(Theme.ink)
            }
            Text(session.map { "\(Format.time($0.start)) – \(Format.time($0.end))" } ?? " ")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 8)
        if let session, !session.stages.isEmpty {
            Hypnogram(session: session).haloCard()
        } else {
            Text(session == nil ? "No sleep recorded for this day." : "Your band shares stage totals for this night, not when each stage happened.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .haloCard()
        }
    }

    // MARK: Readout

    private func nearest(_ s: DaySeries, to t: Date) -> (time: Date, value: Double)? {
        if s.kind == .bars {
            return s.points.last { $0.time <= t }
        }
        return s.points.min { abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t)) }
    }

    private func readout(_ s: DaySeries) -> some View {
        var label = s.headlineLabel
        var value = s.headline
        if let scrub, let p = nearest(s, to: scrub) {
            switch s.kind {
            case .bars:
                let end = p.time.addingTimeInterval(3600)
                label = "\(Format.time(p.time)) – \(Format.time(end))"
            case .line: label = Format.time(p.time)
            case .running: label = "By \(Format.time(p.time))"
            }
            value = p.value
        }
        let unit = metric == .restingHeartRate ? "bpm" : metric.unit
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).haloLabel()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.map(metric.format) ?? "–").font(Theme.number(48)).foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                if !unit.isEmpty { Text(unit).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.secondary) }
            }
            Text(Calendar.current.isDateInToday(day) ? "So far today" : Format.dayTitle(day))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 8)
        .animation(.snappy, value: scrub)
    }

    // MARK: Chart

    private func chart(_ s: DaySeries) -> some View {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_400)
        let picked = scrub.flatMap { nearest(s, to: $0) }
        return Chart {
            if let ref = s.reference {
                RuleMark(y: .value(ref.label, ref.value))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
            ForEach(s.points, id: \.time) { p in
                switch s.kind {
                case .bars:
                    BarMark(x: .value("Hour", p.time, unit: .hour), y: .value(metric.title, p.value), width: .ratio(0.7))
                        .foregroundStyle(picked?.time == p.time ? Theme.accent : Theme.ink.opacity(0.85))
                        .cornerRadius(3)
                case .line:
                    LineMark(x: .value("Time", p.time), y: .value(metric.title, p.value))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                case .running:
                    AreaMark(x: .value("Time", p.time), y: .value(metric.title, p.value))
                        .foregroundStyle(Theme.ink.opacity(0.08))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.time), y: .value(metric.title, p.value))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let picked, s.kind != .bars {
                PointMark(x: .value("Time", picked.time), y: .value(metric.title, picked.value))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(60)
            }
        }
        .chartXScale(domain: start...end)
        .chartXSelection(value: $scrub)
        .chartYScale(domain: .automatic(includesZero: s.kind != .line))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(metric.format(v)).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
    }

    private func legend(_ s: DaySeries) -> some View {
        HStack(spacing: 14) {
            switch s.kind {
            case .line: Text("Heart rate through the day")
            case .bars: Text("Each bar is an hour")
            case .running: Text("Running total through the day")
            }
            if let ref = s.reference {
                HStack(spacing: 5) {
                    Rectangle().fill(Theme.accent).frame(width: 12, height: 1.5)
                    Text("\(ref.label) \(metric.format(ref.value))")
                }
            }
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.secondary)
    }

    // MARK: Stats

    private func stats(_ s: DaySeries) -> some View {
        let values = s.points.map(\.value)
        return HStack(spacing: 12) {
            switch s.kind {
            case .line:
                stat("Lowest", values.min().map(metric.format))
                stat("Highest", values.max().map(metric.format))
                stat("Average", ScoreEngine.mean(values).map(metric.format))
            case .bars:
                let busiest = s.points.max { $0.value < $1.value }
                stat("Busiest hour", busiest.flatMap { $0.value > 0 ? Format.time($0.time) : nil })
                stat("Most in an hour", busiest.map { metric.format($0.value) })
                stat("Active hours", "\(s.points.filter { $0.value >= (metric == .steps ? 250 : 20) }.count)")
            case .running:
                // the hour that added the most
                let byHour = Dictionary(grouping: s.points) { Calendar.current.component(.hour, from: $0.time) }
                    .mapValues { ($0.map(\.value).max() ?? 0) - ($0.map(\.value).min() ?? 0) }
                let top = byHour.max { $0.value < $1.value }
                let firstMove = s.points.first { $0.value > 0 }
                stat("Total", s.headline.map(metric.format))
                stat("Biggest hour", top.flatMap { h in
                    h.value > 0 ? Calendar.current.date(bySettingHour: h.key, minute: 0, second: 0, of: day).map(Format.time) : nil
                })
                stat("First in zone", firstMove.map { Format.time($0.time) })
            }
        }
    }

    private func stat(_ title: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).haloLabel().lineLimit(1).minimumScaleFactor(0.7)
            Text(text ?? "–")
                .font(Theme.number(17)).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .haloCard(padding: 14)
    }
}
