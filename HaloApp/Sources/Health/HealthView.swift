import SwiftUI

/// Every metric, grouped, each compared with your own 30-day normal and opening into its graphs.
/// Edit turns rows (and the health monitor) on and off; the order stays as it is.
struct HealthView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool
    @State private var editing = false
    /// Hidden rows, by metric (and "monitor" for the health monitor card).
    @AppStorage("health.hidden") private var hiddenRaw = ""

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ id: String) {
        var h = hidden
        if h.contains(id) { h.remove(id) } else { h.insert(id) }
        withAnimation(.snappy) { hiddenRaw = h.sorted().joined(separator: ",") }
    }

    /// The round − / + used in edit mode.
    private func editButton(_ id: String) -> some View {
        let isHidden = hidden.contains(id)
        return Button { toggle(id) } label: {
            Image(systemName: isHidden ? "plus" : "minus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHidden ? Theme.background : Theme.ink)
                .frame(width: 24, height: 24)
                .background(isHidden ? Theme.ink : Theme.track, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isHidden ? "Show" : "Hide")
    }

    private let sections: [(title: String, metrics: [Metric])] = [
        ("Heart", [.hrv, .restingHeartRate, .vo2Max]),
        ("Overnight", [.respiratoryRate, .spo2, .skinTemp]),
        ("Activity", [.steps, .cardioLoad, .activeZoneMinutes, .activeCalories, .restingCalories, .totalCalories]),
        ("Body", [.weight]),
        ("Scores", [.recovery, .effort, .sleepScore]),
    ]

    private let monitored: [Metric] = [.hrv, .restingHeartRate, .respiratoryRate, .spo2, .skinTemp]

    var body: some View {
        NavigationStack {
            HaloPage(showSettings: $showSettings, title: "Health", editing: $editing) {
                if editing || !hidden.contains("monitor") {
                    HStack(alignment: .top, spacing: 10) {
                        if editing { editButton("monitor").padding(.top, 18) }
                        summary.opacity(hidden.contains("monitor") ? 0.35 : 1)
                    }
                }
                ForEach(sections, id: \.title) { section in
                    let rows = editing ? section.metrics : section.metrics.filter { !hidden.contains($0.rawValue) }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).haloLabel().padding(.leading, 4)
                            VStack(spacing: 0) {
                                ForEach(rows) { m in
                                    HStack(spacing: 0) {
                                        if editing { editButton(m.rawValue).padding(.leading, 14) }
                                        NavigationLink(value: m) { MetricRow(metric: m) }
                                            .buttonStyle(.plain)
                                            .disabled(editing)
                                            .opacity(hidden.contains(m.rawValue) ? 0.35 : 1)
                                    }
                                    if m != rows.last {
                                        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 18)
                                    }
                                }
                            }
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    }
                }
                Text("Normal ranges are your own: the middle of your last 30 days. Halo isn't a medical device.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .navigationDestination(for: Metric.self) { MetricDetailView(metric: $0) }
        }
    }

    private func monitorLabel(_ m: Metric) -> String {
        switch m {
        case .hrv: return "HRV"
        case .restingHeartRate: return "RHR"
        case .respiratoryRate: return "Breath"
        case .spo2: return "SpO₂"
        case .skinTemp: return "Temp"
        default: return m.shortTitle
        }
    }

    /// Like a health monitor: one dot per overnight vital, filled when it's in your normal range.
    private var summary: some View {
        let states: [Bool?] = monitored.map { m in
            guard let v = m.value(store.selectedDay, in: store),
                  let r = store.normalRange(m, before: store.selectedDate) else { return nil }
            return !m.isConcerning(v, range: r)
        }
        let measured = states.compactMap { $0 }
        let outside = measured.filter { !$0 }.count
        return VStack(alignment: .leading, spacing: 14) {
            Text("Health monitor").haloLabel()
            Text(measured.isEmpty ? "No vitals yet" : outside == 0 ? "All vitals in your normal range" : "\(outside) \(outside == 1 ? "vital" : "vitals") outside your range")
                .font(Theme.number(24))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                ForEach(Array(monitored.enumerated()), id: \.offset) { i, m in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 64) }
                    VitalGauge(metric: m, label: monitorLabel(m), state: states[i])
                }
            }
        }
        .haloCard()
    }
}

struct MetricRow: View {
    @EnvironmentObject private var store: HealthStore
    let metric: Metric

    var body: some View {
        let value = metric.value(store.selectedDay, in: store)
        let range = metric.showsRange ? store.normalRange(metric, before: store.selectedDate) : nil
        let outside = value.flatMap { v in range.map { metric.isConcerning(v, range: $0) } } ?? false
        let trend = store.series(metric, days: 30, endingOn: store.selectedDate).map { $0.value }
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
                if let range {
                    Text("Normal \(metric.format(range.low))–\(metric.format(range.high))")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else if let avg = ScoreEngine.mean(trend) {
                    Text("30-day average \(metric.format(avg))")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 8)
            Sparkline(values: trend, range: range).frame(width: 54, height: 22)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value.map(metric.format) ?? "–")
                    .font(Theme.number(19))
                    .foregroundStyle(outside ? Theme.accent : Theme.ink)
                Text(metric.unit.isEmpty ? " " : metric.unit).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            .frame(minWidth: 58, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// One vital in the health monitor: its value, and a short line whose middle is your baseline.
/// The ticks mark your normal range; the dot sits where today's reading falls.
struct VitalGauge: View {
    @EnvironmentObject private var store: HealthStore
    let metric: Metric
    let label: String
    let state: Bool?

    var body: some View {
        let value = metric.value(store.selectedDay, in: store)
        let range = store.normalRange(metric, before: store.selectedDate)
        let off = state == false
        // the normal range fills the middle 60% of the line
        let position: CGFloat? = value.flatMap { v in range.map { r in
            let mid = (r.low + r.high) / 2, half = max((r.high - r.low) / 2, 0.0001)
            return CGFloat(min(1, max(-1, (v - mid) / half * 0.6)))
        } }
        NavigationLink(value: metric) {
            VStack(spacing: 6) {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
                Text(value.map(metric.format) ?? "–").font(Theme.number(16, weight: .semibold))
                    .foregroundStyle(off ? Theme.accent : Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Canvas { ctx, size in
                    let w = size.width, y = size.height / 2
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: w, y: y))
                    ctx.stroke(line, with: .color(Theme.track), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    for t in [-0.6, 0.0, 0.6] {
                        let x = w / 2 + CGFloat(t) * w / 2
                        var tick = Path(); tick.move(to: CGPoint(x: x, y: y - (t == 0 ? 4 : 3))); tick.addLine(to: CGPoint(x: x, y: y + (t == 0 ? 4 : 3)))
                        ctx.stroke(tick, with: .color(Theme.ink.opacity(t == 0 ? 0.45 : 0.2)), lineWidth: 1)
                    }
                    if let position {
                        let x = w / 2 + position * w / 2
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(off ? Theme.accent : Theme.ink))
                    }
                }
                .frame(width: 38, height: 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(metric.title) \(value.map(metric.format) ?? "no data"), \(off ? "outside" : "within") your normal range")
    }
}
