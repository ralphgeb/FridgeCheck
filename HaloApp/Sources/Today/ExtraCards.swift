import SwiftUI

/// Every day's heart rate of the last week or two laid over each other, midnight to midnight, each
/// as a see-through layer filled down to the bottom: where days overlap the layers stack up and
/// get more solid, so your usual rhythm is the deepest part. The day shown is a line on top.
struct HeartOverlayCard: View {
    @EnvironmentObject private var store: HealthStore
    @AppStorage("today.overlayDays") private var span = 7

    var body: some View {
        let end = store.selectedDate
        let days = store.days.filter { $0.date <= end && $0.date > end.addingTimeInterval(-Double(span) * 86_400) && !$0.heartRate.isEmpty }
        let others = days.filter { $0.date != end }
        let today = days.first { $0.date == end }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Heart rate · your rhythm").haloLabel()
                Spacer()
                SpanSwitch(values: [7, 14], labels: ["1W", "2W"], selection: $span)
            }
            if days.count < 2 {
                Text("Builds up as days of heart rate come in.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Canvas { ctx, size in
                    let all = days.flatMap { $0.heartRate.map(\.bpm) }
                    let lo = (all.min() ?? 40) - 3, hi = (all.max() ?? 160) + 3
                    func path(_ d: DayMetrics, closed: Bool = false) -> Path {
                        var p = Path()
                        var last: Date?
                        for s in d.heartRate.sorted(by: { $0.time < $1.time }) {
                            let x = size.width * CGFloat(s.time.timeIntervalSince(d.date) / 86_400)
                            let y = size.height * (1 - CGFloat((s.bpm - lo) / max(hi - lo, 1)))
                            // a gap of more than half an hour (band off) breaks the line
                            if let l = last, s.time.timeIntervalSince(l) < 1800 { p.addLine(to: CGPoint(x: x, y: y)) }
                            else { p.move(to: CGPoint(x: x, y: y)) }
                            last = s.time
                        }
                        return closed ? Self.fill(p, height: size.height) : p
                    }
                    // each earlier day a faint layer; stacked, they're most solid where days agree
                    let layer = min(0.16, 0.9 / Double(max(others.count, 1)))
                    for d in others {
                        ctx.fill(path(d, closed: true), with: .color(Theme.ink.opacity(layer)))
                    }
                    for d in others {
                        ctx.stroke(path(d), with: .color(Theme.ink.opacity(layer * 1.6)),
                                   style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
                    }
                    if let today {
                        ctx.stroke(path(today), with: .color(Theme.accent),
                                   style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(height: 150)
                HourLabels()
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.ink.opacity(0.3)).frame(width: 14, height: 8)
                        Text("Earlier days, deeper where they overlap")
                    }
                    HStack(spacing: 5) {
                        Capsule().fill(Theme.accent).frame(width: 14, height: 2)
                        Text(store.isTodaySelected ? "Today" : Format.dayTitle(end))
                    }
                    Spacer()
                    Text("\(days.count) days")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            }
        }
        .haloCard()
        .sensoryFeedback(.selection, trigger: span)
    }
}

extension HeartOverlayCard {
    /// A day's line closed down to the bottom, one piece per stretch of readings.
    static func fill(_ line: Path, height: CGFloat) -> Path {
        var out = Path()
        var first: CGPoint?
        var last: CGPoint?
        line.forEach { element in
            switch element {
            case .move(let p):
                if let f = first, let l = last {
                    out.addLine(to: CGPoint(x: l.x, y: height))
                    out.addLine(to: CGPoint(x: f.x, y: height))
                    out.closeSubpath()
                }
                out.move(to: p)
                first = p
                last = p
            case .line(let p):
                out.addLine(to: p)
                last = p
            default:
                break
            }
        }
        if let f = first, let l = last {
            out.addLine(to: CGPoint(x: l.x, y: height))
            out.addLine(to: CGPoint(x: f.x, y: height))
            out.closeSubpath()
        }
        return out
    }
}

/// Each night of the last two weeks as a bar from falling asleep to waking, on one clock from
/// 8 pm to noon, with your usual bedtime and wake-up marked: how regular your nights are, at a
/// glance. Nights with stages show them.
struct SleepRhythmCard: View {
    @EnvironmentObject private var store: HealthStore

    private static let windowStart = 20.0   // 8 pm, the evening before
    private static let windowHours = 16.0   // to noon

    var body: some View {
        let end = store.selectedDate
        let nights = store.days.filter { $0.date <= end }.suffix(14).compactMap { d in d.sleep.map { (date: d.date, sleep: $0) } }
        let usualBed = Self.circularMean(nights.map { Self.hour($0.sleep.start, on: $0.date) })
        let usualWake = Self.circularMean(nights.map { Self.hour($0.sleep.end, on: $0.date) })
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sleep rhythm · 2 weeks").haloLabel()
                Spacer()
                if let usualBed, let usualWake {
                    Text("\(Self.clock(usualBed)) – \(Self.clock(usualWake))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            if nights.count < 3 {
                Text("Shows once there are a few nights.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Canvas { ctx, size in
                    let row = size.height / CGFloat(nights.count)
                    func x(_ h: Double) -> CGFloat { size.width * CGFloat((h - Self.windowStart) / Self.windowHours) }
                    for mark in [usualBed, usualWake].compactMap({ $0 }) {
                        var p = Path()
                        p.move(to: CGPoint(x: x(mark), y: 0))
                        p.addLine(to: CGPoint(x: x(mark), y: size.height))
                        ctx.stroke(p, with: .color(Theme.accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    for (i, n) in nights.enumerated() {
                        let y = CGFloat(i) * row + row * 0.2
                        let h = row * 0.6
                        let a = x(Self.hour(n.sleep.start, on: n.date)), b = x(Self.hour(n.sleep.end, on: n.date))
                        let isShown = n.date == end
                        if n.sleep.stages.isEmpty {
                            ctx.fill(Path(roundedRect: CGRect(x: a, y: y, width: max(2, b - a), height: h), cornerRadius: h / 2),
                                     with: .color(isShown ? Theme.ink : Theme.ink.opacity(0.4)))
                        } else {
                            ctx.fill(Path(roundedRect: CGRect(x: a, y: y, width: max(2, b - a), height: h), cornerRadius: h / 2),
                                     with: .color(Theme.ink.opacity(0.08)))
                            for st in n.sleep.stages where st.kind != .awake {
                                let sa = x(Self.hour(st.start, on: n.date)), sb = x(Self.hour(st.end, on: n.date))
                                let color: Color = st.kind == .deep ? Theme.ink : (st.kind == .rem ? Theme.accent : Theme.ink.opacity(0.4))
                                ctx.fill(Path(CGRect(x: sa, y: y, width: max(1, sb - sa), height: h)),
                                         with: .color(isShown ? color : color.opacity(0.7)))
                            }
                        }
                    }
                }
                .frame(height: CGFloat(nights.count) * 11)
                HStack {
                    ForEach(["8 pm", "midnight", "4 am", "8 am", "noon"], id: \.self) { t in
                        Text(t).frame(maxWidth: .infinity, alignment: t == "8 pm" ? .leading : (t == "noon" ? .trailing : .center))
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                // what the colours mean
                HStack(spacing: 12) {
                    legend(Theme.ink, "Deep")
                    legend(Theme.accent, "REM")
                    legend(Theme.ink.opacity(0.4), "Light")
                    HStack(spacing: 5) {
                        Rectangle().fill(Theme.accent.opacity(0.7)).frame(width: 1, height: 10)
                        Text("Usual times")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                if !nights.contains(where: { !$0.sleep.stages.isEmpty }) {
                    Text("Your band shares each night's times, not its stages, so nights are one bar.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .haloCard()
    }

    private func legend(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
            Text(name)
        }
    }

    /// Hours on the night's clock: 8 pm the evening before is 20, midnight 24, 7 am 31.
    static func hour(_ t: Date, on day: Date) -> Double {
        let h = t.timeIntervalSince(Calendar.current.startOfDay(for: day)) / 3600 + 24
        return min(windowStart + windowHours, max(windowStart, h))
    }

    /// The usual time, on that same clock (it never wraps within the window).
    static func circularMean(_ hours: [Double]) -> Double? {
        hours.isEmpty ? nil : hours.reduce(0, +) / Double(hours.count)
    }

    static func clock(_ h: Double) -> String {
        let total = Int((h.truncatingRemainder(dividingBy: 24) * 60).rounded())
        let date = Calendar.current.date(bySettingHour: total / 60 % 24, minute: total % 60, second: 0, of: .now) ?? .now
        return Format.time(date)
    }
}

/// A two-way 1W / 2W style switch, as on the Balance card.
struct SpanSwitch: View {
    let values: [Int]
    let labels: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(values.indices), id: \.self) { i in
                Button { selection = values[i] } label: {
                    Text(labels[i])
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 32, height: 22)
                        .background(selection == values[i] ? Theme.ink : .clear, in: Capsule())
                        .foregroundStyle(selection == values[i] ? Theme.background : Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.track, in: Capsule())
    }
}
