import SwiftUI

struct SleepView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let session = store.selectedDay.sleep {
                        hero(session)
                        Hypnogram(session: session).haloCard()
                        StageBreakdown(session: session)
                        stats(session)
                    } else {
                        Text("No sleep recorded for \(Format.dayTitle(store.selectedDate).lowercased()).")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                            .haloCard()
                    }
                    SleepWindowCard(week: store.week(endingOn: store.selectedDate),
                                    needHours: store.targets.sleepNeedHours, selected: store.selectedDate)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Sleep")
            .toolbar { SettingsButton(showSettings: $showSettings) }
            .refreshable { await store.sync() }
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

// MARK: - Sleep window

/// The last seven nights as vertical bars from bedtime to wake time, on one clock axis.
/// Lined-up bars mean a steady schedule, which is half of good sleep.
struct SleepWindowCard: View {
    let week: [DayScore]
    let needHours: Double
    let selected: Date

    var body: some View {
        let nights = week.compactMap { item in item.day.sleep.map { (date: item.day.date, session: $0) } }
        let starts = nights.map { ScoreEngine.minutesAfterEvening($0.session.start) }
        let ends = nights.map { ScoreEngine.minutesAfterEvening($0.session.end) }
        let lo = ((starts.min() ?? 240) / 60).rounded(.down) * 60
        let hi = ((ends.max() ?? 780) / 60).rounded(.up) * 60
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Last 7 nights").haloLabel()
                Spacer()
                Text("Average \(Format.duration(ScoreEngine.mean(nights.map { $0.session.minutesAsleep }) ?? 0))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                VStack {
                    Text(clock(lo)); Spacer(); Text(clock(hi))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 38, alignment: .leading)
                ForEach(Array(nights.enumerated()), id: \.offset) { i, n in
                    let isSelected = Calendar.current.isDate(n.date, inSameDayAs: selected)
                    GeometryReader { g in
                        let span = max(hi - lo, 1)
                        let y0 = g.size.height * CGFloat((starts[i] - lo) / span)
                        let y1 = g.size.height * CGFloat((ends[i] - lo) / span)
                        ZStack(alignment: .top) {
                            Capsule().fill(Theme.track).frame(width: 10)
                            Capsule()
                                .fill(isSelected ? Theme.accent : Theme.ink.opacity(n.session.minutesAsleep >= needHours * 60 ? 0.85 : 0.45))
                                .frame(width: 10, height: max(10, y1 - y0))
                                .offset(y: y0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 150)
            HStack(spacing: 8) {
                Spacer().frame(width: 38)
                ForEach(Array(nights.enumerated()), id: \.offset) { _, n in
                    Text(n.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .haloCard()
    }

    /// Minutes after 6 pm -> "11 pm"
    private func clock(_ m: Double) -> String {
        let h = (Int(m / 60) + 18) % 24
        let comps = DateComponents(hour: h)
        let date = Calendar.current.date(from: comps) ?? .now
        return date.formatted(.dateTime.hour())
    }
}
