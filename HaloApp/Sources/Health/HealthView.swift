import SwiftUI

/// Every metric, grouped, each compared with your own 30-day normal and opening into its graphs.
struct HealthView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool

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
            HaloPage(showSettings: $showSettings) {
                summary
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).haloLabel().padding(.leading, 4)
                        VStack(spacing: 0) {
                            ForEach(section.metrics) { m in
                                NavigationLink(value: m) { MetricRow(metric: m) }
                                    .buttonStyle(.plain)
                                if m != section.metrics.last {
                                    Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 18)
                                }
                            }
                        }
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
            return r.contains(v)
        }
        let measured = states.compactMap { $0 }
        let outside = measured.filter { !$0 }.count
        return VStack(alignment: .leading, spacing: 14) {
            Text("Health monitor").haloLabel()
            Text(measured.isEmpty ? "No vitals yet" : outside == 0 ? "All vitals in your normal range" : "\(outside) \(outside == 1 ? "vital" : "vitals") outside your range")
                .font(Theme.number(24))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Array(monitored.enumerated()), id: \.offset) { i, m in
                    let state = states[i]
                    VStack(spacing: 6) {
                        Circle()
                            .fill(state == nil ? Theme.track : (state == true ? Theme.ink : Theme.accent))
                            .frame(width: 10, height: 10)
                        Text(monitorLabel(m))
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
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
        let outside = value.flatMap { v in range.map { !$0.contains(v) } } ?? false
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
