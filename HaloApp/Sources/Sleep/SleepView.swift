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
                    Hypnogram(session: session).haloCard()
                    let night = store.heartSamples(from: session.start, to: session.end)
                    if night.count >= 6 { SleepHeartCard(session: session, samples: night) }
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

// MARK: - Sleep debt

/// Sleep missed against your need over the last two weeks: a bar per night above or below the line,
/// the running total, and when to go to bed tonight to start paying it back.
struct SleepDebtCard: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        let nights = store.nights(endingOn: store.selectedDate, count: 14)
        let lastWeek = Array(nights.suffix(7))
        let debt = ScoreEngine.sleepDebt(lastWeek)
        let need = store.targets.sleepNeedHours * 60
        let maxDev = max(60, nights.map { abs($0.balance) }.max() ?? 60)
        let bedtime = ScoreEngine.bedtime(days: store.days, endingOn: store.selectedDate, needHours: store.targets.sleepNeedHours)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sleep debt").haloLabel()
                Spacer()
                Text("Need \(Format.duration(need))").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(debt < 1 ? "None" : Format.duration(debt))
                    .font(Theme.number(36))
                    .foregroundStyle(debt >= 120 ? Theme.accent : Theme.ink)
                Text(debt < 1 ? "you're even this week" : "missed in the last 7 nights")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            // One point per night: above the line is extra sleep, below is sleep missed.
            let limit = max(1, (maxDev / 60 * 2).rounded(.up) / 2)
            Chart {
                ForEach(nights) { n in
                    AreaMark(x: .value("Night", n.date, unit: .day), yStart: .value("Need", 0.0), yEnd: .value("Hours", n.balance / 60))
                        .foregroundStyle(LinearGradient(stops: [
                            .init(color: Theme.ink.opacity(0.16), location: 0),
                            .init(color: Theme.ink.opacity(0.03), location: 0.5),
                            .init(color: Theme.accent.opacity(0.06), location: 0.5),
                            .init(color: Theme.accent.opacity(0.3), location: 1),
                        ], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Night", n.date, unit: .day), y: .value("Hours", n.balance / 60))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Night", n.date, unit: .day), y: .value("Hours", n.balance / 60))
                        .foregroundStyle(n.balance < 0 ? Theme.accent : Theme.ink)
                        .symbolSize(Calendar.current.isDate(n.date, inSameDayAs: store.selectedDate) ? 60 : 18)
                }
                RuleMark(y: .value("Need", 0.0))
                    .foregroundStyle(Theme.ink.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartYScale(domain: -limit...limit)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.day()).foregroundStyle(Theme.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [-limit, 0, limit]) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        let h = v.as(Double.self) ?? 0
                        Text(h == 0 ? "Need" : "\(h > 0 ? "+" : "−")\(Format.duration(abs(h) * 60))")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .frame(height: 130)
            Text("Above the line: more than you need. Below: sleep missed.")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heart rate by stage").haloLabel()
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
            HStack {
                Text(Format.time(session.start))
                Spacer()
                Text(Format.time(session.end))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.tertiary)
            .padding(.trailing, 28)

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
        }
        .haloCard()
        .sensoryFeedback(.selection, trigger: picked)
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

