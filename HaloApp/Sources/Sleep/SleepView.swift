import Charts
import SwiftUI

struct SleepView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool

    var body: some View {
        NavigationStack {
            HaloPage(showSettings: $showSettings, title: "Sleep") {
                if let session = store.selectedDay.sleep {
                    NavigationLink(value: Metric.sleepDuration) { hero(session) }
                        .buttonStyle(.plain)
                    // Some bands (Whoop) share stage totals but not when each stage happened.
                    if !session.stages.isEmpty { Hypnogram(session: session).haloCard() }
                    let night = store.heartSamples(from: session.start, to: session.end)
                    if night.count >= 6 { SleepHeartCard(session: session, samples: night) }
                    else { OvernightHeartCard(day: store.selectedDay) }
                    StageBreakdown(session: session)
                } else {
                    Text("No sleep recorded for \(Format.dayTitle(store.selectedDate).lowercased()).")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .haloCard()
                }
                SleepDebtCard()
                if let session = store.selectedDay.sleep { stats(session) }
                SleepScheduleCard()
            }
            .navigationDestination(for: Metric.self) { MetricDetailView(metric: $0) }
            .navigationDestination(for: SleepScheduleRoute.self) { _ in SleepScheduleView() }
        }
    }

    private func hero(_ s: SleepSession) -> some View {
        let score = store.scores(for: store.selectedDate).sleep
        let need = store.targets.sleepNeedHours * 60
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Time asleep").haloLabel()
                Text(Format.duration(s.minutesAsleep)).font(Theme.number(44)).foregroundStyle(Theme.ink)
                Text("\(Format.time(s.start)) – \(Format.time(s.end))")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                Text(s.minutesAsleep >= need ? "Need met" : "\(Format.duration(need - s.minutesAsleep)) short of your need")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(s.minutesAsleep >= need ? Theme.ink : Theme.accent)
            }
            Spacer()
            ZStack {
                Ring(progress: score ?? 0, lineWidth: 8)
                VStack(spacing: 0) {
                    Text(score?.percentText ?? "–").font(Theme.number(24))
                    Text("Score").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .foregroundStyle(Theme.ink)
            }
            .frame(width: 92, height: 92)
        }
        .haloCard()
    }

    private func stats(_ s: SleepSession) -> some View {
        let day = store.selectedDay
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            stat("Efficiency", "\(Int((s.efficiency * 100).rounded()))%")
            stat("Woke up", "\(s.wakeUps)×")
            stat("Fell asleep in", Format.duration(s.minutesToFallAsleep))
            stat("Deep + REM", Format.duration(s.minutes(.deep) + s.minutes(.rem)))
            stat("Breathing", day.respiratoryRate.map { String(format: "%.1f", $0) } ?? "–", unit: "br/min")
            stat("Overnight HRV", day.hrv.map { "\(Int($0))" } ?? "–", unit: "ms")
        }
    }

    private func stat(_ title: String, _ value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).haloLabel()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.number(24)).foregroundStyle(Theme.ink)
                if let unit { Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary) }
            }
        }
        .haloCard(padding: 16)
    }
}

// MARK: - Sleep bank

/// Sleep bank: over the last 30 nights, where your last seven nights stood against your need
/// each morning. Above the line is sleep in hand, below is debt. Drag across it to read a night.
struct SleepDebtCard: View {
    @EnvironmentObject private var store: HealthStore
    @State private var picked: Date?

    private struct Point: Identifiable {
        let date: Date
        let bank: Double        // minutes: the last seven nights against your need
        var id: Date { date }
    }

    private func points() -> [Point] {
        let nights = store.nights(endingOn: store.selectedDate, count: 37)
        let cal = Calendar.current
        return nights.suffix(30).map { n in
            let from = cal.date(byAdding: .day, value: -6, to: n.date) ?? n.date
            let week = nights.filter { $0.date >= from && $0.date <= n.date }
            return Point(date: n.date, bank: week.reduce(0) { $0 + $1.balance })
        }
    }

    var body: some View {
        let list = points()
        let need = store.targets.sleepNeedHours * 60
        let shown = picked.flatMap { d in list.first { Calendar.current.isDate($0.date, inSameDayAs: d) } } ?? list.last
        let bank = shown?.bank ?? 0
        let bedtime = ScoreEngine.bedtime(days: store.days, endingOn: store.selectedDate, needHours: store.targets.sleepNeedHours)
        let top = max(1, ((list.map(\.bank).max() ?? 0) / 60).rounded(.up))
        let bottom = min(-1, ((list.map(\.bank).min() ?? 0) / 60).rounded(.down))
        // where the need line sits in the line's own height, so it turns accent below it
        let hi = list.map(\.bank).max() ?? 0, lo = list.map(\.bank).min() ?? 0
        let zero = hi > lo ? min(1, max(0, hi / (hi - lo))) : (hi >= 0 ? 1 : 0)
        let step: Double = top - bottom > 4 ? 2 : 1
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sleep bank").haloLabel()
                Spacer()
                Text("Need \(Format.duration(need))").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(abs(bank) < 1 ? "Even" : "\(bank > 0 ? "+" : "−")\(Format.duration(abs(bank)))")
                        .font(Theme.number(36))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text(shown.map { picked == nil ? "Last 7 nights, to \(Format.dayTitle($0.date).lowercased())" : "7 nights to \($0.date.formatted(.dateTime.day().month()))" } ?? "Last 7 nights")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text(bank >= 0 ? "In hand" : "Debt")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(bank >= 0 ? Theme.ink : Theme.accent)
            }
            Chart {
                ForEach(list) { p in
                    AreaMark(x: .value("Night", p.date, unit: .day), yStart: .value("Need", 0.0), yEnd: .value("Bank", p.bank / 60))
                        .foregroundStyle(LinearGradient(stops: [
                            .init(color: Theme.ink.opacity(0.14), location: 0),
                            .init(color: Theme.ink.opacity(0.02), location: zero),
                            .init(color: Theme.accent.opacity(0.04), location: zero),
                            .init(color: Theme.accent.opacity(0.22), location: 1),
                        ], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Night", p.date, unit: .day), y: .value("Bank", p.bank / 60))
                        .foregroundStyle(LinearGradient(stops: [
                            .init(color: Theme.ink, location: 0), .init(color: Theme.ink, location: zero),
                            .init(color: Theme.accent, location: zero), .init(color: Theme.accent, location: 1),
                        ], startPoint: .top, endPoint: .bottom))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                // hollow beads, one per night; the one shown is bigger and glows
                ForEach(list) { p in
                    let isShown = p.date == shown?.date
                    PointMark(x: .value("Night", p.date, unit: .day), y: .value("Bank", p.bank / 60))
                        .symbol {
                            Circle()
                                .strokeBorder(p.bank < 0 ? Theme.accent : Theme.ink, lineWidth: isShown ? 2.5 : 1.5)
                                .background(Circle().fill(Theme.card))
                                .frame(width: isShown ? 12 : 6, height: isShown ? 12 : 6)
                                .shadow(color: (p.bank < 0 ? Theme.accent : Theme.ink).opacity(isShown ? 0.55 : 0), radius: 6)
                        }
                }
                RuleMark(y: .value("Need", 0.0))
                    .foregroundStyle(Theme.ink.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                if picked != nil, let shown {
                    RuleMark(x: .value("Night", shown.date, unit: .day))
                        .foregroundStyle(Theme.ink.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: bottom...top)
            .chartXSelection(value: $picked)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Theme.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: Array(stride(from: (bottom / step).rounded(.up) * step, through: top, by: step))) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        let h = v.as(Double.self) ?? 0
                        Text(h == 0 ? "0h" : "\(h > 0 ? "+" : "−")\(Int(abs(h)))h")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .frame(height: 170)
            .sensoryFeedback(.selection, trigger: shown?.date)
            Text("Each point is your last seven nights against your need. Drag across to read a night.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            if let bedtime {
                HStack(spacing: 10) {
                    Image(systemName: "bed.double").foregroundStyle(Theme.accent)
                    Text("Tonight, aim for bed by **\(Format.time(bedtime))**")
                        .font(.system(size: 14)).foregroundStyle(Theme.ink)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.track, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .haloCard()
    }
}

// MARK: - Hypnogram

/// Stage-by-stage graph of the night: one lane per stage, joined by thin steps.
/// Awake is the accent, so wake-ups stand out at a glance.
struct Hypnogram: View {
    let session: SleepSession
    private let lanes = SleepStageKind.allCases.sorted { $0.depth < $1.depth }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stages").haloLabel()
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lanes) { k in
                        Text(k.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                            .frame(height: 34, alignment: .center)
                    }
                }
                Canvas { ctx, size in draw(in: &ctx, size: size) }
                    .frame(height: 34 * CGFloat(lanes.count))
            }
            HStack {
                Text(Format.time(session.start))
                Spacer()
                Text(Format.time(session.start.addingTimeInterval(session.end.timeIntervalSince(session.start) / 2)))
                Spacer()
                Text(Format.time(session.end))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.tertiary)
            .padding(.leading, 44)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stages from \(Format.time(session.start)) to \(Format.time(session.end))")
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let total = session.end.timeIntervalSince(session.start)
        guard total > 0 else { return }
        let laneH = size.height / CGFloat(lanes.count)
        func x(_ d: Date) -> CGFloat { size.width * CGFloat(d.timeIntervalSince(session.start) / total) }
        func y(_ k: SleepStageKind) -> CGFloat { laneH * (CGFloat(k.depth) + 0.5) }

        // faint lane guides
        for i in 0..<lanes.count {
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: laneH * (CGFloat(i) + 0.5)))
            guide.addLine(to: CGPoint(x: size.width, y: laneH * (CGFloat(i) + 0.5)))
            ctx.stroke(guide, with: .color(Theme.hairline), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
        // steps between stages
        var connector = Path()
        for (a, b) in zip(session.stages, session.stages.dropFirst()) {
            connector.move(to: CGPoint(x: x(b.start), y: y(a.kind)))
            connector.addLine(to: CGPoint(x: x(b.start), y: y(b.kind)))
        }
        ctx.stroke(connector, with: .color(Theme.ink.opacity(0.25)), lineWidth: 1)
        // stage blocks
        let blockH: CGFloat = 12
        for s in session.stages {
            let rect = CGRect(x: x(s.start), y: y(s.kind) - blockH / 2, width: max(2, x(s.end) - x(s.start)), height: blockH)
            let color: Color = s.kind == .awake ? Theme.accent : Theme.ink.opacity(0.35 + 0.2 * Double(s.kind.depth))
            ctx.fill(Path(roundedRect: rect, cornerRadius: blockH / 2), with: .color(color))
        }
    }
}

// MARK: - Heart rate by stage

/// Overnight heart rate with the sleep stages underneath. Tap a stage to light up
/// every part of the night spent in it, and see your heart rate there.
struct SleepHeartCard: View {
    let session: SleepSession
    let samples: [HeartSample]
    @State private var picked: SleepStageKind?

    private let order: [SleepStageKind] = [.deep, .light, .rem, .awake]

    private func inStage(_ k: SleepStageKind) -> [HeartSample] {
        let spans = session.stages.filter { $0.kind == k }
        return samples.filter { s in spans.contains { $0.start <= s.time && s.time < $0.end } }
    }

    var body: some View {
        let low = samples.min { $0.bpm < $1.bpm }
        let lo = (samples.map(\.bpm).min() ?? 40) - 6
        let hi = (samples.map(\.bpm).max() ?? 80) + 4
        let pickedSpans = picked.map { k in session.stages.filter { $0.kind == k } } ?? []
        let pickedSamples = picked.map(inStage) ?? []
        // Some bands (Whoop) share the night's heart rate but not when each stage happened.
        let hasStages = !session.stages.isEmpty
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(hasStages ? "Heart rate by stage" : "Heart rate overnight").haloLabel()
                Spacer()
                if let low {
                    Text("Lowest \(Int(low.bpm)) at \(Format.time(low.time))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            Chart {
                ForEach(Array(pickedSpans.enumerated()), id: \.offset) { _, st in
                    RectangleMark(xStart: .value("Start", st.start), xEnd: .value("End", st.end),
                                  yStart: .value("Low", lo), yEnd: .value("High", hi))
                        .foregroundStyle(Theme.accent.opacity(0.16))
                }
                ForEach(samples, id: \.time) { s in
                    LineMark(x: .value("Time", s.time), y: .value("BPM", s.bpm))
                        .foregroundStyle(Theme.ink.opacity(picked == nil ? 1 : 0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                ForEach(pickedSamples, id: \.time) { s in
                    PointMark(x: .value("Time", s.time), y: .value("BPM", s.bpm))
                        .foregroundStyle(Theme.accent)
                        .symbolSize(10)
                }
            }
            .chartXScale(domain: session.start...session.end)
            .chartYScale(domain: lo...hi)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: 140)
            .animation(.snappy, value: picked)

            // the stages as one strip, on the same time axis
            if hasStages {
            Canvas { ctx, size in
                let total = session.end.timeIntervalSince(session.start)
                guard total > 0 else { return }
                for st in session.stages {
                    let x0 = size.width * CGFloat(st.start.timeIntervalSince(session.start) / total)
                    let x1 = size.width * CGFloat(st.end.timeIntervalSince(session.start) / total)
                    let lane = CGFloat(st.kind.depth) / 3
                    let h = size.height * (0.35 + 0.65 * lane)
                    let color: Color = st.kind == picked ? Theme.accent
                        : Theme.ink.opacity(picked == nil ? 0.2 + 0.18 * Double(st.kind.depth) : 0.12)
                    ctx.fill(Path(CGRect(x: x0, y: size.height - h, width: max(1, x1 - x0), height: h)), with: .color(color))
                }
            }
            .frame(height: 22)
            .padding(.trailing, 28)   // lines up with the chart, which keeps room for its axis labels
            }
            HStack {
                Text(Format.time(session.start))
                Spacer()
                Text(Format.time(session.end))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.tertiary)
            .padding(.trailing, 28)

            if hasStages {
            HStack(spacing: 8) {
                ForEach(order) { k in
                    let bpm = ScoreEngine.mean(inStage(k).map(\.bpm))
                    Button {
                        withAnimation(.snappy) { picked = picked == k ? nil : k }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(k.title).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(picked == k ? Theme.accent : Theme.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(bpm.map { "\(Int($0.rounded()))" } ?? "–").font(Theme.number(18)).foregroundStyle(Theme.ink)
                                Text("bpm").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.secondary)
                            }
                            Text(Format.duration(session.minutes(k))).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(picked == k ? Theme.accent.opacity(0.12) : Theme.track,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(picked.map(note) ?? "Tap a stage to see where it falls in the night.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    nightStat("Lowest", samples.map(\.bpm).min())
                    nightStat("Average", ScoreEngine.mean(samples.map(\.bpm)))
                    nightStat("Highest", samples.map(\.bpm).max())
                }
            }
        }
        .haloCard()
        .sensoryFeedback(.selection, trigger: picked)
    }

    private func nightStat(_ title: String, _ bpm: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(bpm.map { "\(Int($0.rounded()))" } ?? "–").font(Theme.number(18)).foregroundStyle(Theme.ink)
                Text("bpm").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func note(_ k: SleepStageKind) -> String {
        switch k {
        case .deep: return "Deep sleep comes early in the night, and your heart rate is at its lowest and steadiest."
        case .light: return "Light sleep fills most of the night, between the deeper and dreaming stages."
        case .rem: return "REM gets longer towards morning. Heart rate rises and varies, like when you're awake."
        case .awake: return "Short wake-ups are normal. Most you won't remember."
        }
    }
}

/// For nights without heart-rate readings: what the band worked out overnight.
struct OvernightHeartCard: View {
    @EnvironmentObject private var store: HealthStore
    let day: DayMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Heart overnight").haloLabel()
            HStack(spacing: 8) {
                stat("Resting", day.restingHeartRate.map { "\(Int($0.rounded()))" }, "bpm")
                stat("HRV", day.hrv.map { "\(Int($0.rounded()))" }, "ms")
                stat("Breathing", day.respiratoryRate.map { String(format: "%.1f", $0) }, "/min")
            }
            if store.source == .whoop && !WhoopClient.usesAppleHealth {
                Text("To see the night's heart rate, turn on Use Apple Health too in Settings › Sources. Whoop writes its readings there.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .haloCard()
    }

    private func stat(_ title: String, _ value: String?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–").font(Theme.number(18)).foregroundStyle(Theme.ink)
                Text(unit).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Stage breakdown

struct StageBreakdown: View {
    let session: SleepSession

    /// Typical share of a night for adults (rough guide).
    private func typical(_ k: SleepStageKind) -> String {
        switch k {
        case .awake: return "under 10%"
        case .rem: return "20–25%"
        case .light: return "50–60%"
        case .deep: return "13–23%"
        }
    }

    private func color(_ k: SleepStageKind) -> Color {
        k == .awake ? Theme.accent : Theme.ink.opacity(0.35 + 0.2 * Double(k.depth))
    }

    var body: some View {
        let order: [SleepStageKind] = [.deep, .light, .rem, .awake]
        let total = max(1, order.reduce(0) { $0 + session.minutes($1) })
        VStack(alignment: .leading, spacing: 14) {
            Text("Breakdown").haloLabel()
            GeometryReader { g in
                HStack(spacing: 3) {
                    ForEach(order) { k in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(color(k))
                            .frame(width: max(3, (g.size.width - 9) * CGFloat(session.minutes(k) / total)))
                    }
                }
            }
            .frame(height: 10)
            ForEach(order) { k in
                HStack {
                    Circle().fill(color(k)).frame(width: 8, height: 8)
                    Text(k.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(typical(k)).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Text(Format.duration(session.minutes(k))).font(Theme.number(14, weight: .medium)).foregroundStyle(Theme.ink)
                    Text("\(Int((session.minutes(k) / total * 100).rounded()))%")
                        .font(Theme.number(13, weight: .regular)).foregroundStyle(Theme.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .haloCard()
    }
}

