import SwiftUI
import WidgetKit

// The newer widgets: sleep bank, last night's stages, the five vitals, today's heart rate and a
// week of rings. All read the snapshot the app writes after each sync.

/// The one widget configuration they all share.
private func haloWidget<V: View>(kind: String, name: String, description: String, families: [WidgetFamily],
                                 url: String, @ViewBuilder view: @escaping (HaloEntry) -> V) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: HaloProvider()) { entry in
        view(entry)
            .containerBackground(for: .widget) { Theme.background }
            .widgetURL(URL(string: url))
    }
    .configurationDisplayName(name)
    .description(description)
    .supportedFamilies(families)
}

/// Small uppercase heading used on every widget.
private struct WidgetLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold)).tracking(0.8)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
    }
}

private func shortDuration(_ minutes: Double) -> String {
    let m = Int(abs(minutes).rounded())
    return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
}

// MARK: - Sleep bank (1 week)

struct SleepBankWidget: Widget {
    var body: some WidgetConfiguration {
        haloWidget(kind: WidgetSnapshot.sleepBankKind, name: "Sleep bank",
                   description: "The last seven nights against what you needed.",
                   families: [.systemMedium], url: "halo://sleep/bank") { SleepBankWidgetView(snapshot: $0.snapshot) }
    }
}

struct SleepBankWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let nights = snapshot.nights ?? []
        let balance = nights.reduce(0) { $0 + $1.asleep - $1.need }
        let biggest = max(60, nights.map { abs($0.asleep - $0.need) }.max() ?? 60)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetLabel(text: "Sleep bank · 7 nights")
                Text((balance < 0 ? "−" : "+") + shortDuration(balance))
                    .font(Theme.number(28, weight: .semibold))
                    .foregroundStyle(balance < 0 ? Theme.accent : Theme.text)
                    .minimumScaleFactor(0.7).lineLimit(1)
                Text(balance < 0 ? "Short of what you needed" : "Ahead of what you needed")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let last = nights.last {
                    Text("Last night \(shortDuration(last.asleep))")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                }
            }
            .frame(width: 118, alignment: .leading)
            // each night above or below what you needed, around a zero line
            HStack(alignment: .center, spacing: 6) {
                ForEach(nights, id: \.date) { n in
                    let diff = n.asleep - n.need
                    VStack(spacing: 4) {
                        GeometryReader { g in
                            let half = g.size.height / 2
                            let h = max(3, half * CGFloat(min(1, abs(diff) / biggest)))
                            ZStack(alignment: .top) {
                                Rectangle().fill(Theme.hairline).frame(height: 1).offset(y: half)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(diff < 0 ? Theme.accent : Theme.ink)
                                    .frame(height: h)
                                    .offset(y: diff < 0 ? half : half - h)
                            }
                        }
                        Text(n.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Sleep stages

struct SleepStagesWidget: Widget {
    var body: some WidgetConfiguration {
        haloWidget(kind: WidgetSnapshot.sleepStagesKind, name: "Sleep stages",
                   description: "Last night's deep, REM and light sleep, and when you woke.",
                   families: [.systemSmall, .systemMedium], url: "halo://sleep") { SleepStagesWidgetView(snapshot: $0.snapshot) }
    }
}

struct SleepStagesWidgetView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    static func color(_ k: SleepStageKind) -> Color {
        switch k {
        case .deep: return Theme.ink
        case .rem: return Theme.accent
        case .light: return Theme.ink.opacity(0.45)
        case .awake: return Theme.ink.opacity(0.16)
        }
    }

    var body: some View {
        if let n = snapshot.lastNight {
            if family == .systemMedium { medium(n) } else { small(n) }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz").font(.system(size: 22)).foregroundStyle(Theme.tertiary)
                Text("No sleep yet").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
    }

    struct Total: Identifiable {
        let kind: SleepStageKind
        let minutes: Double
        var id: SleepStageKind { kind }
    }

    private func totals(_ n: WidgetSnapshot.NightStages) -> [Total] {
        [Total(kind: .deep, minutes: n.deep), Total(kind: .rem, minutes: n.rem),
         Total(kind: .light, minutes: n.light), Total(kind: .awake, minutes: n.awake)]
    }

    /// The night's stages as one bar, longest-first share of each.
    private func shareBar(_ n: WidgetSnapshot.NightStages) -> some View {
        let all = totals(n)
        let sum = max(1, all.reduce(0) { $0 + $1.minutes })
        return GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(all) { t in
                    Capsule().fill(Self.color(t.kind))
                        .frame(width: max(2, (g.size.width - 6) * CGFloat(t.minutes / sum)))
                }
            }
        }
        .frame(height: 8)
    }

    private func small(_ n: WidgetSnapshot.NightStages) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetLabel(text: "Last night")
            Text(shortDuration(n.asleep)).font(Theme.number(26, weight: .semibold)).foregroundStyle(Theme.text)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text("\(n.start.formatted(date: .omitted, time: .shortened)) – \(n.end.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
            shareBar(n)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 3) {
                ForEach(totals(n).filter { $0.kind != .awake }) { t in
                    HStack(spacing: 4) {
                        Circle().fill(Self.color(t.kind)).frame(width: 6, height: 6)
                        Text("\(t.kind.title) \(shortDuration(t.minutes))").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
        }
    }

    private func medium(_ n: WidgetSnapshot.NightStages) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                WidgetLabel(text: "Last night")
                Spacer()
                Text(shortDuration(n.asleep)).font(Theme.number(16, weight: .semibold)).foregroundStyle(Theme.text)
                if let score = n.score {
                    Text("· \(Int((score * 100).rounded()))").font(Theme.number(16, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            if n.stages.isEmpty {
                // stage totals only (Whoop): the share of each
                Spacer(minLength: 0)
                shareBar(n).frame(height: 14)
                Spacer(minLength: 0)
            } else {
                hypnogram(n)
            }
            HStack(spacing: 10) {
                ForEach(totals(n)) { t in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(Self.color(t.kind)).frame(width: 6, height: 6)
                            Text(t.kind.title).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
                        }
                        Text(shortDuration(t.minutes)).font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Stages as lanes through the night: awake at the top, deep at the bottom.
    private func hypnogram(_ n: WidgetSnapshot.NightStages) -> some View {
        let order: [SleepStageKind] = [.awake, .rem, .light, .deep]
        let span = max(1, n.end.timeIntervalSince(n.start))
        return Canvas { ctx, size in
            let lane = size.height / CGFloat(order.count)
            for s in n.stages {
                guard let row = order.firstIndex(of: s.kind) else { continue }
                let x0 = CGFloat(s.start.timeIntervalSince(n.start) / span) * size.width
                let x1 = CGFloat(s.end.timeIntervalSince(n.start) / span) * size.width
                let rect = CGRect(x: x0, y: CGFloat(row) * lane + lane * 0.15, width: max(1.5, x1 - x0), height: lane * 0.7)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Self.color(s.kind)))
            }
        }
    }
}

// MARK: - Vitals

struct VitalsWidget: Widget {
    var body: some WidgetConfiguration {
        haloWidget(kind: WidgetSnapshot.vitalsKind, name: "Vitals",
                   description: "HRV, resting heart rate, breathing, SpO₂ and skin temperature against your normal.",
                   families: [.systemMedium], url: "halo://health") { VitalsWidgetView(snapshot: $0.snapshot) }
    }
}

/// Laid out like the Health monitor card: each vital's number, its name under it, and under that
/// a short line whose ticks are your normal range, with a dot where today sits.
struct VitalsWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let vitals = snapshot.vitals ?? []
        let outside = vitals.filter(\.concerning).count
        VStack(alignment: .leading, spacing: 10) {
            WidgetLabel(text: "Health monitor")
            Text(vitals.isEmpty ? "No vitals yet" : outside == 0 ? "All in your normal range" : "\(outside) outside your range")
                .font(Theme.number(17, weight: .semibold))
                .foregroundStyle(outside == 0 ? Theme.text : Theme.accent)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(Array(vitals.enumerated()), id: \.offset) { i, v in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 52) }
                    VStack(spacing: 5) {
                        Text(v.value).font(Theme.number(17, weight: .semibold))
                            .foregroundStyle(v.concerning ? Theme.accent : Theme.text)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(v.name).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        RangeTicks(position: v.gauge, highlight: v.concerning).frame(width: 34, height: 10)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// A short line: ticks at the edges of your normal range and its middle, a dot where today is.
struct RangeTicks: View {
    let position: Double?
    var highlight = false

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, y = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(line, with: .color(Theme.track), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for t in [-0.6, 0.0, 0.6] {
                let x = w / 2 + CGFloat(t) * w / 2
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: y - (t == 0 ? 4 : 3)))
                tick.addLine(to: CGPoint(x: x, y: y + (t == 0 ? 4 : 3)))
                ctx.stroke(tick, with: .color(Theme.ink.opacity(t == 0 ? 0.45 : 0.2)), lineWidth: 1)
            }
            if let position {
                let x = w / 2 + CGFloat(position) * w / 2
                ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
                         with: .color(highlight ? Theme.accent : Theme.ink))
            }
        }
    }
}

// MARK: - Heart rate today

struct HeartTodayWidget: Widget {
    var body: some WidgetConfiguration {
        haloWidget(kind: WidgetSnapshot.heartKind, name: "Heart today",
                   description: "Your heart rate since midnight, over your resting line.",
                   families: [.systemSmall, .systemMedium], url: "halo://today/zones") { HeartTodayWidgetView(snapshot: $0.snapshot) }
    }
}

struct HeartTodayWidgetView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let slots = snapshot.heartToday ?? []
        let readings = slots.compactMap { $0 }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                WidgetLabel(text: "Heart today")
                Spacer()
                if let peak = readings.max() {
                    Text("Peak \(Int(peak))").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(readings.last.map { "\(Int($0))" } ?? "–").font(Theme.number(family == .systemMedium ? 26 : 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("bpm latest").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            HeartDayShape(slots: slots, resting: snapshot.restingForChart)
        }
    }
}

/// The day's heart rate as a soft accent wash over a thin line, with the resting line dashed.
struct HeartDayShape: View {
    let slots: [Double?]
    let resting: Double?

    var body: some View {
        Canvas { ctx, size in
            let values = slots.compactMap { $0 }
            guard values.count >= 2, let hi = values.max() else {
                ctx.draw(Text("No readings yet").font(.system(size: 10)).foregroundColor(Theme.tertiary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let lo = min(values.min() ?? 40, resting ?? 200) - 4
            let range = max(hi - lo, 1)
            let n = CGFloat(max(1, slots.count - 1))
            func y(_ v: Double) -> CGFloat { size.height - size.height * CGFloat((v - lo) / range) }
            var line = Path(), area = Path()
            var started = false, lastX: CGFloat = 0
            for (i, v) in slots.enumerated() {
                guard let v else { continue }
                let p = CGPoint(x: size.width * CGFloat(i) / n, y: y(v))
                if !started {
                    line.move(to: p)
                    area.move(to: CGPoint(x: p.x, y: size.height))
                    area.addLine(to: p)
                    started = true
                } else {
                    line.addLine(to: p)
                    area.addLine(to: p)
                }
                lastX = p.x
            }
            area.addLine(to: CGPoint(x: lastX, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.45), Theme.accent.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            if let resting {
                var r = Path()
                r.move(to: CGPoint(x: 0, y: y(resting)))
                r.addLine(to: CGPoint(x: size.width, y: y(resting)))
                ctx.stroke(r, with: .color(Theme.ink.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }
}

