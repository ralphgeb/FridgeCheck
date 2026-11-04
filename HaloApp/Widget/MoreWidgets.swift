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
                   families: [.systemMedium], url: "halo://sleep") { SleepBankWidgetView(snapshot: $0.snapshot) }
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
                   families: [.systemMedium, .systemLarge], url: "halo://health") { VitalsWidgetView(snapshot: $0.snapshot) }
    }
}

struct VitalsWidgetView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let vitals = snapshot.vitals ?? []
        let outside = vitals.filter(\.concerning).count
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 4) {
            HStack {
                WidgetLabel(text: "Vitals")
                Spacer()
                Text(outside == 0 ? "All in your normal" : "\(outside) outside your normal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(outside == 0 ? Theme.secondary : Theme.accent)
            }
            ForEach(vitals) { v in
                HStack(spacing: 8) {
                    Circle().fill(v.concerning ? Theme.accent : Theme.ink.opacity(0.25)).frame(width: 6, height: 6)
                    Text(v.name).font(.system(size: family == .systemLarge ? 14 : 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: family == .systemLarge ? 96 : 70, alignment: .leading)
                    Sparkline(points: v.points, highlight: v.concerning)
                        .frame(height: family == .systemLarge ? 26 : 14)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(v.value).font(Theme.number(family == .systemLarge ? 17 : 13, weight: .semibold))
                            .foregroundStyle(v.concerning ? Theme.accent : Theme.text)
                        Text(v.unit).font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.tertiary)
                    }
                    .frame(width: family == .systemLarge ? 76 : 58, alignment: .trailing)
                }
                if family == .systemLarge, v.id != vitals.last?.id {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
            }
            if vitals.isEmpty {
                Text("Vitals show after a night with the band on.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if family == .systemLarge { Spacer(minLength: 0) }
        }
    }
}

/// A tiny line of the last week, ending in a dot.
struct Sparkline: View {
    let points: [Double]
    var highlight = false

    var body: some View {
        Canvas { ctx, size in
            guard points.count >= 2, let lo = points.min(), let hi = points.max() else { return }
            let range = max(hi - lo, 0.0001)
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(points.count - 1),
                        y: size.height - 2 - (size.height - 4) * CGFloat((points[i] - lo) / range))
            }
            var path = Path()
            path.move(to: pt(0))
            for i in 1..<points.count { path.addLine(to: pt(i)) }
            ctx.stroke(path, with: .color(Theme.ink.opacity(0.55)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            let end = pt(points.count - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                     with: .color(highlight ? Theme.accent : Theme.ink))
        }
    }
}

// MARK: - Heart rate today

struct HeartTodayWidget: Widget {
    var body: some WidgetConfiguration {
        haloWidget(kind: WidgetSnapshot.heartKind, name: "Heart today",
                   description: "Your heart rate since midnight, over your resting line.",
                   families: [.systemSmall, .systemMedium], url: "halo://fitness") { HeartTodayWidgetView(snapshot: $0.snapshot) }
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

// MARK: - A week of rings

struct WeekRingsWidget: Widget {
    var body: some WidgetConfiguration {
        haloWidget(kind: WidgetSnapshot.weekKind, name: "Your week",
                   description: "Recovery, effort and sleep for each of the last seven days.",
                   families: [.systemMedium], url: "halo://today") { WeekRingsWidgetView(snapshot: $0.snapshot) }
    }
}

struct WeekRingsWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let week = snapshot.week ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WidgetLabel(text: "Your week")
                Spacer()
                HStack(spacing: 8) {
                    legend("Recovery", 1)
                    legend("Effort", 0.62)
                    legend("Sleep", 0.32)
                }
            }
            HStack(spacing: 0) {
                ForEach(week, id: \.date) { d in
                    let isToday = Calendar.current.isDateInToday(d.date)
                    VStack(spacing: 6) {
                        NestedRings(values: [d.recovery, d.effort, d.sleep])
                            .frame(width: 34, height: 34)
                        Text(d.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 9, weight: isToday ? .heavy : .semibold))
                            .foregroundStyle(isToday ? Theme.accent : Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func legend(_ name: String, _ opacity: Double) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Theme.ink.opacity(opacity)).frame(width: 5, height: 5)
            Text(name).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tertiary)
        }
    }
}

/// Three rings inside each other: recovery outside, effort, then sleep, each fuller as it scores
/// higher; a ring that met its mark turns the accent.
struct NestedRings: View {
    let values: [Double?]

    var body: some View {
        Canvas { ctx, size in
            let width: CGFloat = 3.4
            for (i, v) in values.enumerated() {
                let inset = CGFloat(i) * (width + 1.6) + width / 2
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                let track = Path(ellipseIn: rect)
                let shade = [1.0, 0.62, 0.32][i]
                ctx.stroke(track, with: .color(Theme.ink.opacity(0.08)), lineWidth: width)
                guard let v, v > 0 else { continue }
                var arc = Path()
                arc.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                           startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, v)), clockwise: false)
                let color = v >= 0.85 ? Theme.accent : Theme.ink.opacity(shade)
                ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
    }
}
