import Charts
import SwiftUI

/// The vitals Halo tracks, each compared with your own 30-day range.
enum Vital: String, CaseIterable, Identifiable {
    case hrv, restingHeartRate, respiratoryRate, spo2, skinTemp, vo2Max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hrv: return "Heart rate variability"
        case .restingHeartRate: return "Resting heart rate"
        case .respiratoryRate: return "Respiratory rate"
        case .spo2: return "Blood oxygen"
        case .skinTemp: return "Skin temperature"
        case .vo2Max: return "Cardio fitness"
        }
    }

    var unit: String {
        switch self {
        case .hrv: return "ms"
        case .restingHeartRate: return "bpm"
        case .respiratoryRate: return "br/min"
        case .spo2: return "%"
        case .skinTemp: return "°C"
        case .vo2Max: return "VO₂ max"
        }
    }

    var keyPath: KeyPath<DayMetrics, Double?> {
        switch self {
        case .hrv: return \.hrv
        case .restingHeartRate: return \.restingHeartRate
        case .respiratoryRate: return \.respiratoryRate
        case .spo2: return \.spo2
        case .skinTemp: return \.skinTempDelta
        case .vo2Max: return \.vo2Max
        }
    }

    var about: String {
        switch self {
        case .hrv: return "The variation between heartbeats while you sleep. Higher than your normal usually means you've recovered well."
        case .restingHeartRate: return "Your lowest steady heart rate. A rise of a few beats can be an early sign of stress, illness or fatigue."
        case .respiratoryRate: return "Breaths per minute while you sleep. It's very stable, so a change is worth noticing."
        case .spo2: return "How much oxygen your blood carries overnight. Most people sit between 95% and 100%."
        case .skinTemp: return "Change from your personal baseline overnight. A jump can come before you feel unwell."
        case .vo2Max: return "An estimate of how well your body uses oxygen during exercise. It moves slowly, over weeks."
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .skinTemp: return (v >= 0 ? "+" : "−") + String(format: "%.1f", abs(v))
        case .spo2, .respiratoryRate: return String(format: "%.1f", v)
        default: return "\(Int(v.rounded()))"
        }
    }

    /// How far from the mean still counts as normal, at least this wide.
    var minimumBand: Double {
        switch self {
        case .hrv: return 6
        case .restingHeartRate: return 2
        case .respiratoryRate: return 0.6
        case .spo2: return 1
        case .skinTemp: return 0.5
        case .vo2Max: return 2
        }
    }
}

/// Your normal range for a vital: mean ± 1.5 standard deviations of the last 30 days.
struct VitalRange {
    let low: Double
    let high: Double

    init?(values: [Double], minimumBand: Double) {
        guard values.count >= 5, let mean = ScoreEngine.mean(values) else { return nil }
        let sd = sqrt(values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
        let band = max(1.5 * sd, minimumBand)
        low = mean - band
        high = mean + band
    }

    func contains(_ v: Double) -> Bool { v >= low && v <= high }
}

struct HealthView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    summary
                    VStack(spacing: 0) {
                        ForEach(Vital.allCases) { vital in
                            NavigationLink(value: vital) { VitalRow(vital: vital, info: info(vital)) }
                                .buttonStyle(.plain)
                            if vital != Vital.allCases.last { Divider().overlay(Theme.hairline).padding(.leading, 18) }
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Text("Ranges are your own: the middle of your last 30 days. Halo isn't a medical device.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Health")
            .toolbar { SettingsButton(showSettings: $showSettings) }
            .navigationDestination(for: Vital.self) { VitalDetailView(vital: $0) }
            .refreshable { await store.sync() }
        }
    }

    struct Info {
        let value: Double?
        let range: VitalRange?
        let history: [(date: Date, value: Double)]
        var inRange: Bool? { value.flatMap { v in range.map { $0.contains(v) } } }
    }

    private func info(_ vital: Vital) -> Info {
        let date = store.selectedDate
        let past = store.days.filter { $0.date < date }.suffix(30).compactMap { $0[keyPath: vital.keyPath] }
        let history = store.days.filter { $0.date <= date }.suffix(30).compactMap { d in d[keyPath: vital.keyPath].map { (date: d.date, value: $0) } }
        return Info(value: store.day(date)?[keyPath: vital.keyPath],
                    range: VitalRange(values: past, minimumBand: vital.minimumBand),
                    history: history)
    }

    /// Like a monitor: one dot per vital, filled when it's in your normal range.
    private var summary: some View {
        let infos = Vital.allCases.map { info($0) }
        let measured = infos.filter { $0.inRange != nil }
        let outside = measured.filter { $0.inRange == false }.count
        return VStack(alignment: .leading, spacing: 14) {
            Text(Format.dayTitle(store.selectedDate)).haloLabel()
            Text(measured.isEmpty ? "No vitals yet" : outside == 0 ? "All vitals in your normal range" : "\(outside) \(outside == 1 ? "vital" : "vitals") outside your range")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Array(infos.enumerated()), id: \.offset) { _, i in
                    Circle()
                        .fill(i.inRange == nil ? Theme.track : (i.inRange == true ? Theme.ink : Theme.accent))
                        .frame(width: 10, height: 10)
                }
                Spacer()
                Text("\(measured.count - outside) of \(measured.count)").font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .haloCard()
    }
}

struct VitalRow: View {
    let vital: Vital
    let info: HealthView.Info

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(vital.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
                if let r = info.range {
                    Text("Normal \(vital.format(r.low))–\(vital.format(r.high))")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else {
                    Text("Building your range").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 8)
            Sparkline(values: info.history.map { $0.value }, range: info.range)
                .frame(width: 54, height: 22)
            VStack(alignment: .trailing, spacing: 2) {
                Text(info.value.map(vital.format) ?? "–")
                    .font(Theme.number(19))
                    .foregroundStyle(info.inRange == false ? Theme.accent : Theme.ink)
                Text(vital.unit).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            .frame(minWidth: 52, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Tiny trend line, with the normal range as a faint band.
struct Sparkline: View {
    let values: [Double]
    let range: VitalRange?

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
            ctx.stroke(p, with: .color(Theme.ink.opacity(0.7)), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            if let last = values.last {
                let pt = CGPoint(x: size.width, y: y(last))
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)), with: .color(Theme.accent))
            }
        }
    }
}

struct VitalDetailView: View {
    @EnvironmentObject private var store: HealthStore
    let vital: Vital

    var body: some View {
        let points = store.days.compactMap { d in d[keyPath: vital.keyPath].map { (date: d.date, value: $0) } }
        let range = VitalRange(values: points.dropLast().suffix(30).map { $0.value }, minimumBand: vital.minimumBand)
        let latest = points.last
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(latest.map { Format.dayTitle($0.date) } ?? "No data").haloLabel()
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(latest.map { vital.format($0.value) } ?? "–").font(Theme.number(54)).foregroundStyle(Theme.ink)
                        Text(vital.unit).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                    if let r = range {
                        Text("Your normal range is \(vital.format(r.low))–\(vital.format(r.high)) \(vital.unit)")
                            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    }
                }
                .haloCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Last \(points.count) days").haloLabel()
                    Chart {
                        if let r = range, let first = points.first, let last = points.last {
                            RectangleMark(xStart: .value("Start", first.date), xEnd: .value("End", last.date),
                                          yStart: .value("Low", r.low), yEnd: .value("High", r.high))
                                .foregroundStyle(Theme.track)
                        }
                        ForEach(points, id: \.date) { p in
                            LineMark(x: .value("Day", p.date), y: .value(vital.title, p.value))
                                .foregroundStyle(Theme.ink)
                                .interpolationMethod(.monotone)
                            if p.date == latest?.date {
                                PointMark(x: .value("Day", p.date), y: .value(vital.title, p.value))
                                    .foregroundStyle(Theme.accent)
                                    .symbolSize(60)
                            }
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing) { _ in
                            AxisGridLine().foregroundStyle(Theme.hairline)
                            AxisValueLabel().foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(height: 220)
                }
                .haloCard()

                Text(vital.about)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .haloCard()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(vital.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Gear button used in the navigation bars.
struct SettingsButton: ToolbarContent {
    @Binding var showSettings: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .tint(Theme.ink)
                .accessibilityLabel("Settings")
        }
    }
}
