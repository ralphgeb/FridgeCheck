import Charts
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool
    @State private var reveal = 0.0

    var body: some View {
        let day = store.selectedDay
        let scores = store.scores(for: store.selectedDate)
        NavigationStack {
            HaloPage(showSettings: $showSettings, pinnedHeight: DialsHeader.expandedHeight) { offset in
                DialsHeader(scores: scores, collapse: collapse(offset), reveal: reveal)
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
            } content: {
                InsightCard(scores: scores, isToday: store.isTodaySelected)
                keyMetrics(day)
                TrendCard(week: store.week(endingOn: store.selectedDate), selected: store.selectedDate)
                if !day.heartRate.isEmpty {
                    HeartRateCard(samples: day.heartRate, resting: day.restingHeartRate)
                }
                CardioCard()
                CaloriesCard(day: day)
                BalanceCard(axes: store.balance(for: store.selectedDate))
                if store.isSample { SampleBanner { showSettings = true } }
            }
            .navigationDestination(for: Metric.self) { MetricDetailView(metric: $0) }
        }
        .onAppear { replayReveal() }
        .onChange(of: store.selectedDate) { _, _ in replayReveal() }
    }

    private func collapse(_ offset: CGFloat) -> Double {
        Double(min(1, max(0, offset / (DialsHeader.expandedHeight - DialsHeader.collapsedHeight))))
    }

    private func replayReveal() {
        reveal = 0
        withAnimation(.spring(duration: 1.3, bounce: 0.12).delay(0.05)) { reveal = 1 }
    }

    private func keyMetrics(_ day: DayMetrics) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach([Metric.hrv, .restingHeartRate, .steps, .sleepDuration]) { m in
                NavigationLink(value: m) { MetricTile(metric: m, day: day) }
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Cards

struct InsightCard: View {
    let scores: Scores
    let isToday: Bool

    var body: some View {
        let h = ScoreEngine.headline(scores)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text(isToday ? "Today" : "That day").haloLabel()
            }
            Text(h.title)
                .font(Theme.number(28))
                .foregroundStyle(Theme.ink)
            Text(h.detail)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .haloCard()
    }
}

/// A key number with its change against your baseline and a tiny 7-day trend. Tap for its graphs.
struct MetricTile: View {
    @EnvironmentObject private var store: HealthStore
    let metric: Metric
    let day: DayMetrics

    var body: some View {
        let value = metric.value(day, in: store)
        let base = store.baseline(metric, before: day.date)
        let trend = store.series(metric, days: 7, endingOn: day.date).map { $0.value }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(metric.shortTitle).haloLabel()
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map(metric.format) ?? "–").font(Theme.number(26)).foregroundStyle(Theme.ink)
                if !metric.unit.isEmpty, metric != .steps {
                    Text(metric.unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            HStack(alignment: .bottom) {
                deltaLabel(value: value, base: base)
                Spacer(minLength: 4)
                Sparkline(values: trend).frame(width: 44, height: 18)
            }
        }
        .haloCard(padding: 16)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func deltaLabel(value: Double?, base: Double?) -> some View {
        if let value, let base, base > 0 {
            let d = value / base - 1
            let good = metric.higherIsBetter.map { (d >= 0) == $0 }
            HStack(spacing: 2) {
                Image(systemName: d >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text("\(Int((abs(d) * 100).rounded()))%")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(abs(d) < 0.03 || good == nil ? Theme.secondary : (good == true ? Theme.ink : Theme.accent))
        } else {
            Text(" ").font(.system(size: 12))
        }
    }
}

/// Three lines, one per score, over the last seven days. Drag across to read any day.
struct TrendCard: View {
    let week: [DayScore]
    let selected: Date
    @State private var hidden: Set<ScoreKind> = []
    @State private var scrub: Date?

    private struct Point: Identifiable {
        let kind: ScoreKind
        let date: Date
        let value: Double
        var id: String { "\(kind.rawValue)-\(date.timeIntervalSince1970)" }
    }

    var body: some View {
        let points = week.flatMap { item in
            ScoreKind.allCases.compactMap { k in k.value(in: item.scores).map { Point(kind: k, date: item.day.date, value: $0 * 100) } }
        }
        let focus = scrub ?? selected
        let focusItem = week.first { Calendar.current.isDate($0.day.date, inSameDayAs: focus) }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Last 7 days").haloLabel()
                Spacer()
                Text(focusItem.map { Format.dayTitle($0.day.date) } ?? "")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            // Legend doubles as the readout and the on/off switch for each line.
            HStack(spacing: 8) {
                ForEach(ScoreKind.allCases) { k in
                    Button {
                        withAnimation(.snappy) { if hidden.contains(k) { hidden.remove(k) } else if hidden.count < 2 { hidden.insert(k) } }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Capsule().fill(Theme.ink.opacity(opacity(k))).frame(width: 12, height: 3)
                                Text(k.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                            }
                            Text(focusItem.flatMap { k.value(in: $0.scores) }.map { $0.percentText } ?? "–")
                                .font(Theme.number(20)).foregroundStyle(Theme.ink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(hidden.contains(k) ? 0.3 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            Chart {
                ForEach(points.filter { !hidden.contains($0.kind) }) { p in
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Score", p.value), series: .value("Kind", p.kind.title))
                        .foregroundStyle(Theme.ink.opacity(opacity(p.kind)))
                        .lineStyle(StrokeStyle(lineWidth: p.kind == .recovery ? 2.6 : 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value("Score", p.value))
                        .foregroundStyle(Calendar.current.isDate(p.date, inSameDayAs: focus) ? Theme.accent : Theme.ink.opacity(opacity(p.kind)))
                        .symbolSize(Calendar.current.isDate(p.date, inSameDayAs: focus) ? 42 : 14)
                }
                RuleMark(x: .value("Focus", focus, unit: .day))
                    .foregroundStyle(Theme.accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            .chartYScale(domain: 0...100)
            .chartXSelection(value: $scrub)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow)).foregroundStyle(Theme.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: 170)
        }
        .haloCard()
        .sensoryFeedback(.selection, trigger: scrub.map { Calendar.current.startOfDay(for: $0) })
    }

    private func opacity(_ k: ScoreKind) -> Double {
        switch k {
        case .recovery: return 1
        case .effort: return 0.55
        case .sleep: return 0.3
        }
    }
}

struct HeartRateCard: View {
    let samples: [HeartSample]
    let resting: Double?

    var body: some View {
        let peak = samples.map(\.bpm).max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Heart rate").haloLabel()
                Spacer()
                Text("Peak \(Int(peak)) bpm").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            Chart {
                ForEach(samples, id: \.time) { s in
                    AreaMark(x: .value("Time", s.time), yStart: .value("Low", 40.0), yEnd: .value("BPM", s.bpm))
                        .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.16), Theme.ink.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.time), y: .value("BPM", s.bpm))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.monotone)
                }
                if let resting {
                    RuleMark(y: .value("Resting", resting))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Resting \(Int(resting))").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                }
            }
            .chartYScale(domain: 40...max(140, peak + 10))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [60.0, 100.0, 140.0]) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: 150)
        }
        .haloCard()
    }
}

/// Cardio minutes this week against the weekly target, with a bar per day.
struct CardioCard: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        let week = store.week(endingOn: store.selectedDate)
        let total = week.compactMap(\.day.activeZoneMinutes).reduce(0, +)
        let target = store.targets.weeklyCardioMinutes
        let daily = store.targets.activeZoneMinutes
        let maxBar = max(daily * 1.6, week.compactMap(\.day.activeZoneMinutes).max() ?? 0)
        NavigationLink(value: Metric.activeZoneMinutes) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Weekly cardio").haloLabel()
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        Ring(progress: total / max(target, 1), lineWidth: 7)
                        VStack(spacing: 0) {
                            Text("\(Int(total))").font(Theme.number(22)).foregroundStyle(Theme.ink)
                            Text("of \(Int(target))").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(width: 84, height: 84)
                    HStack(alignment: .bottom, spacing: 7) {
                        ForEach(week) { item in
                            let v = item.day.activeZoneMinutes ?? 0
                            let isSelected = Calendar.current.isDate(item.day.date, inSameDayAs: store.selectedDate)
                            VStack(spacing: 6) {
                                Capsule()
                                    .fill(isSelected ? Theme.accent : Theme.ink.opacity(v >= daily ? 0.85 : 0.3))
                                    .frame(width: 8, height: max(4, 64 * v / max(maxBar, 1)))
                                Text(item.day.date.formatted(.dateTime.weekday(.narrow)))
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 84, alignment: .bottom)
                }
                Text(total >= target ? "Weekly target reached." : "\(Int(target - total)) cardio minutes to go this week.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .haloCard()
        }
        .buttonStyle(.plain)
    }
}

/// Active + resting = total, as one split bar.
struct CaloriesCard: View {
    @EnvironmentObject private var store: HealthStore
    let day: DayMetrics

    var body: some View {
        let resting = store.restingCalories(day)
        let active = day.activeCalories ?? 0
        let total = resting + active
        NavigationLink(value: Metric.totalCalories) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Calories").haloLabel()
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Int(total).formatted()).font(Theme.number(30)).foregroundStyle(Theme.ink)
                    Text(store.isTodaySelected ? "kcal so far" : "kcal").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                GeometryReader { g in
                    HStack(spacing: 3) {
                        Capsule().fill(Theme.ink).frame(width: max(4, (g.size.width - 3) * active / max(total, 1)))
                        Capsule().fill(Theme.ink.opacity(0.18))
                    }
                }
                .frame(height: 8)
                HStack {
                    legend("Active", active, Theme.ink)
                    Spacer()
                    legend("Resting", resting, Theme.ink.opacity(0.18))
                }
            }
            .haloCard()
        }
        .buttonStyle(.plain)
    }

    private func legend(_ title: String, _ v: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 12, height: 6)
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Text(Int(v).formatted()).font(Theme.number(14, weight: .medium)).foregroundStyle(Theme.ink)
        }
    }
}

/// Balance: how rounded your week is, as a radar. The weakest spoke wears the accent.
struct BalanceCard: View {
    let axes: [BalanceAxis]

    private func metric(for axis: BalanceAxis) -> Metric {
        switch axis.name {
        case "Sleep": return .sleepScore
        case "HRV": return .hrv
        case "Recovery": return .recovery
        case "Steps": return .steps
        case "Resting HR": return .restingHeartRate
        default: return .activeZoneMinutes
        }
    }

    var body: some View {
        let weakest = axes.min { $0.value < $1.value }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Balance").haloLabel()
                Spacer()
                Text(axes.overall.percentText).font(Theme.number(22)).foregroundStyle(Theme.ink)
                Text("/ 100").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            RadarChart(axes: axes)
                .frame(height: 260)
            if let weakest {
                Text("Your week is weakest on **\(weakest.name)**. Small wins there lift the whole shape.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 4) {
                ForEach(axes) { a in
                    NavigationLink(value: metric(for: a)) {
                        HStack {
                            Text(a.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                            Spacer()
                            Text(a.value.percentText).font(Theme.number(14, weight: .medium))
                                .foregroundStyle(a.id == weakest?.id ? Theme.accent : Theme.secondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .haloCard()
    }
}

struct SampleBanner: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're seeing sample data").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Connect your Fitbit to see your own.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.tertiary)
            }
            .haloCard(padding: 16)
        }
        .buttonStyle(.plain)
    }
}

/// Tiny trend line with the last point in the accent.
struct Sparkline: View {
    let values: [Double]
    var range: NormalRange? = nil

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let lo = min(values.min() ?? 0, range?.low ?? .infinity)
            let hi = max(values.max() ?? 1, range?.high ?? -.infinity)
            let span = max(hi - lo, 0.0001)
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat((v - lo) / span)) }
            if let range {
                ctx.fill(Path(CGRect(x: 0, y: y(range.high), width: size.width, height: y(range.low) - y(range.high))),
                         with: .color(Theme.track))
            }
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: y(v))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Theme.ink.opacity(0.7)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            if let last = values.last {
                let pt = CGPoint(x: size.width, y: y(last))
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)), with: .color(Theme.accent))
            }
        }
    }
}
