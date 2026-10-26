import Charts
import SwiftUI

/// Fitbit's three heart-rate zones, as shares of heart-rate reserve (resting to max).
enum HeartZone: Int, CaseIterable, Identifiable, Hashable {
    case fatBurn, cardio, peak

    var id: Int { rawValue }
    var title: String { ["Fat burn", "Cardio", "Peak"][rawValue] }
    var start: Double { [CardioLoad.fatBurnStart, CardioLoad.cardioStart, CardioLoad.peakStart][rawValue] }
    var color: Color { [Theme.ink.opacity(0.32), Theme.ink.opacity(0.7), Theme.accent][rawValue] }
    func minutes(_ z: ZoneMinutes) -> Double { [z.fatBurn, z.cardio, z.peak][rawValue] }
}

/// The zone bpm limits for one day (they move with that day's resting heart rate).
struct ZoneScale {
    let resting: Double
    let max: Double

    func bpm(_ z: HeartZone) -> Double { CardioLoad.bpm(atReserve: z.start, resting: resting, max: max) }

    func zone(_ bpm: Double) -> HeartZone? { HeartZone.allCases.last { bpm >= self.bpm($0) } }

    func range(_ z: HeartZone) -> String {
        guard let next = HeartZone(rawValue: z.rawValue + 1) else { return "\(Int(bpm(z)))+ bpm" }
        return "\(Int(bpm(z)))–\(Int(bpm(next)) - 1) bpm"
    }

    /// Stretches of time spent in a zone (readings a few minutes apart join up).
    func stretches(_ samples: [HeartSample], in z: HeartZone) -> [Stretch] {
        var out: [Stretch] = []
        var current: [HeartSample] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            out.append(Stretch(start: first.time, end: last.time.addingTimeInterval(300),
                               average: current.map(\.bpm).reduce(0, +) / Double(current.count)))
            current = []
        }
        for s in samples.sorted(by: { $0.time < $1.time }) {
            if zone(s.bpm) == z {
                if let last = current.last, s.time.timeIntervalSince(last.time) > 6 * 60 { close() }
                current.append(s)
            } else {
                close()
            }
        }
        close()
        return out
    }

    struct Stretch: Identifiable {
        let start: Date
        let end: Date
        let average: Double
        var id: Date { start }
        var minutes: Double { end.timeIntervalSince(start) / 60 }
    }
}

extension HealthStore {
    func zoneScale(for d: DayMetrics) -> ZoneScale {
        ZoneScale(resting: d.restingHeartRate ?? baseline(.restingHeartRate, before: d.date) ?? 60, max: profile.maxHeartRate)
    }
}

/// Opens the heart zones page for a day.
struct ZonesRoute: Hashable {
    let date: Date
}

/// Which zone you were in, through the day, as one thin strip.
struct ZoneStrip: View {
    let samples: [HeartSample]
    let day: Date
    let scale: ZoneScale
    var only: HeartZone? = nil

    var body: some View {
        Canvas { ctx, size in
            let w = size.width / 86_400
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(Theme.track))
            for (i, s) in samples.enumerated() {
                guard let z = scale.zone(s.bpm), only == nil || only == z else { continue }
                let next = i + 1 < samples.count ? samples[i + 1].time : s.time.addingTimeInterval(300)
                let x0 = CGFloat(s.time.timeIntervalSince(day)) * w
                let x1 = CGFloat(min(next.timeIntervalSince(day), s.time.timeIntervalSince(day) + 300)) * w
                ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1.5, x1 - x0), height: size.height)), with: .color(z.color))
            }
        }
    }
}

struct HourLabels: View {
    var body: some View {
        HStack {
            ForEach(["12 am", "6 am", "12 pm", "6 pm"], id: \.self) { t in
                Text(t).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Theme.tertiary)
    }
}

/// The day's heart rate, the zone lines, which zone you were in through the day, and minutes per
/// zone so far. Tap for the full zones page.
struct HeartZonesCard: View {
    @EnvironmentObject private var store: HealthStore
    let day: DayMetrics

    var body: some View {
        let scale = store.zoneScale(for: day)
        let samples = day.heartRate
        let peakBPM = samples.map(\.bpm).max() ?? 0
        let minutes = day.zones ?? ZoneMinutes()
        NavigationLink(value: ZonesRoute(date: day.date)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(store.isTodaySelected ? "Heart rate zones · today" : "Heart rate zones").haloLabel()
                    Spacer()
                    Text("Peak \(Int(peakBPM)) bpm").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                ZoneChart(samples: samples, day: day.date, scale: scale, highlight: nil)
                    .frame(height: 140)
                ZoneStrip(samples: samples, day: day.date, scale: scale).frame(height: 10)
                HourLabels()
                ZoneBars(minutes: minutes, scale: scale, selected: nil)
                HStack {
                    Text("Cardio load \(Int((day.cardioLoad ?? 0).rounded()))")
                    Spacer()
                    Text("Zone minutes \(Int(ScoreEngine.zonePoints(day).rounded())) of \(Int(store.targets.zoneMinutes))")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            }
            .haloCard()
        }
        .buttonStyle(.plain)
    }
}

/// Heart rate over a day with a dashed line where each zone starts. With `highlight`, every
/// stretch spent in that zone is shaded.
struct ZoneChart: View {
    let samples: [HeartSample]
    let day: Date
    let scale: ZoneScale
    let highlight: HeartZone?

    var body: some View {
        let peakBPM = samples.map(\.bpm).max() ?? 0
        let top = max(scale.bpm(.peak) + 8, peakBPM + 8)
        let stretches = highlight.map { scale.stretches(samples, in: $0) } ?? []
        Chart {
            ForEach(stretches) { st in
                RectangleMark(xStart: .value("Start", st.start), xEnd: .value("End", st.end),
                              yStart: .value("Low", 40.0), yEnd: .value("High", top))
                    .foregroundStyle(Theme.accent.opacity(0.16))
            }
            ForEach(HeartZone.allCases) { z in
                RuleMark(y: .value("Zone", scale.bpm(z)))
                    .foregroundStyle(z.color.opacity(highlight == nil || highlight == z ? 0.9 : 0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 1) {
                        Text("\(z.title) \(Int(scale.bpm(z)))").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
            }
            ForEach(samples, id: \.time) { s in
                AreaMark(x: .value("Time", s.time), yStart: .value("Low", 40.0), yEnd: .value("BPM", s.bpm))
                    .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.14), Theme.ink.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.time), y: .value("BPM", s.bpm))
                    .foregroundStyle(Theme.ink)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Resting", scale.resting))
                .foregroundStyle(Theme.accent.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }
        .chartXScale(domain: day...day.addingTimeInterval(86_400))
        .chartYScale(domain: 40...top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

/// Minutes in each zone as bars. Tappable rows when `onPick` is set.
struct ZoneBars: View {
    let minutes: ZoneMinutes
    let scale: ZoneScale
    let selected: HeartZone?
    var onPick: ((HeartZone) -> Void)? = nil

    var body: some View {
        let longest = max(1, HeartZone.allCases.map { $0.minutes(minutes) }.max() ?? 1)
        VStack(spacing: 8) {
            ForEach(HeartZone.allCases.reversed()) { z in
                let dim = selected != nil && selected != z
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(z.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected == z ? Theme.accent : Theme.ink)
                        Text(scale.range(z)).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                    }
                    .frame(width: 84, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(z.color).frame(width: max(4, g.size.width * CGFloat(z.minutes(minutes) / longest)))
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int(z.minutes(minutes).rounded())) min")
                        .font(Theme.number(14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 52, alignment: .trailing)
                }
                .opacity(dim ? 0.4 : 1)
                .contentShape(Rectangle())
                .onTapGesture { onPick?(z) }
            }
        }
    }
}

/// A day's heart rate by zone: pick a day with the arrows and a zone to see when you were in it.
struct HeartZonesView: View {
    @EnvironmentObject private var store: HealthStore
    @Environment(\.openSettings) private var openSettings
    @State var date: Date
    @State private var zone: HeartZone? = .cardio

    private var daysWithHeartRate: [Date] { store.days.filter { !$0.heartRate.isEmpty }.map(\.date) }

    var body: some View {
        let day = store.day(date) ?? DayMetrics(date: date)
        let scale = store.zoneScale(for: day)
        let samples = day.heartRate
        let minutes = day.zones ?? ZoneMinutes()
        let stretches = zone.map { scale.stretches(samples, in: $0) } ?? []
        let previous = daysWithHeartRate.last { $0 < date }
        let next = daysWithHeartRate.first { $0 > date }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Format.dayTitle(date)).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("\(Int(minutes.total.rounded())) min in zones · load \(Int((day.cardioLoad ?? 0).rounded()))")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    RoundStepButton(symbol: "chevron.left", enabled: previous != nil, label: "Previous day") {
                        if let previous { withAnimation(.snappy) { date = previous } }
                    }
                    RoundStepButton(symbol: "chevron.right", enabled: next != nil, label: "Next day") {
                        if let next { withAnimation(.snappy) { date = next } }
                    }
                }
                .padding(.top, 4)

                Picker("Zone", selection: $zone) {
                    Text("All").tag(HeartZone?.none)
                    ForEach(HeartZone.allCases) { Text($0.title).tag(HeartZone?.some($0)) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 10) {
                    if samples.isEmpty {
                        Text("No heart rate for this day. Halo keeps it for the last two weeks.")
                            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ZoneChart(samples: samples, day: date, scale: scale, highlight: zone)
                            .frame(height: 200)
                            .animation(.snappy, value: zone)
                        ZoneStrip(samples: samples, day: date, scale: scale, only: zone).frame(height: 12)
                        HourLabels()
                    }
                }
                .haloCard()

                if let zone {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("In \(zone.title.lowercased())").haloLabel()
                            Spacer()
                            Text("\(stretches.count) \(stretches.count == 1 ? "stretch" : "stretches")")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        }
                        if stretches.isEmpty {
                            Text("You weren't in this zone \(Calendar.current.isDateInToday(date) ? "yet today" : "that day").")
                                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        }
                        ForEach(stretches) { st in
                            HStack {
                                Circle().fill(zone.color).frame(width: 7, height: 7)
                                Text("\(Format.time(st.start)) – \(Format.time(st.end))").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                                Spacer()
                                Text("avg \(Int(st.average)) bpm").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                Text("\(Int(st.minutes.rounded())) min").font(Theme.number(14, weight: .semibold)).foregroundStyle(Theme.ink)
                                    .frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                    .haloCard()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Minutes in each zone").haloLabel()
                    ZoneBars(minutes: minutes, scale: scale, selected: zone) { z in
                        withAnimation(.snappy) { zone = zone == z ? nil : z }
                    }
                }
                .haloCard()

                Text("Zones are set from your resting heart rate (\(Int(scale.resting)) bpm that day) and your estimated maximum (\(Int(scale.max)) bpm, from your age): fat burn starts at 40% of the way between them, cardio at 60%, peak at 85%. Minute totals come from your band when it has them.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .haloCard()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Heart rate zones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openSettings) { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
        }
        .sensoryFeedback(.selection, trigger: zone)
        .sensoryFeedback(.selection, trigger: date)
    }
}

/// A chevron in its own round bubble, for stepping back and forward.
struct RoundStepButton: View {
    let symbol: String
    let enabled: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40)
                .background(Theme.card, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
