import Charts
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool
    @State private var offset: CGFloat = 0
    @State private var reveal = 0.0

    private var collapse: Double {
        Double(min(1, max(0, offset / (DialsHeader.expandedHeight - DialsHeader.collapsedHeight))))
    }

    var body: some View {
        let day = store.selectedDay
        let scores = store.scores(for: store.selectedDate)
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 14) {
                    InsightCard(scores: scores)
                    keyMetrics(day)
                    WeekCard(week: store.week(endingOn: store.selectedDate), selected: store.selectedDate)
                    if !day.heartRate.isEmpty {
                        HeartRateCard(samples: day.heartRate, resting: day.restingHeartRate)
                    }
                    ActivityCard(day: day, targets: store.targets)
                    if store.isSample { SampleBanner { showSettings = true } }
                }
                .padding(.horizontal, 20)
                .padding(.top, DateBar.height + DialsHeader.expandedHeight + 18)
                .padding(.bottom, 32)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("today")).minY)
                })
            }
            .coordinateSpace(name: "today")
            .onPreferenceChange(ScrollOffsetKey.self) { offset = $0 }
            .scrollIndicators(.hidden)
            .refreshable { await store.sync() }

            // Pinned header: date bar + dials that collapse into bars.
            VStack(spacing: 0) {
                DateBar(showSettings: $showSettings)
                DialsHeader(scores: scores, collapse: collapse, reveal: reveal)
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
            }
            .background(Theme.background.opacity(min(1, collapse * 1.6)).ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).opacity(collapse > 0.98 ? 1 : 0)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: collapse > 0.98)
        .onAppear { replayReveal() }
        .onChange(of: store.selectedDate) { _, _ in replayReveal() }
    }

    private func replayReveal() {
        reveal = 0
        withAnimation(.spring(duration: 1.3, bounce: 0.12).delay(0.05)) { reveal = 1 }
    }

    private func keyMetrics(_ day: DayMetrics) -> some View {
        let hrvBase = store.baseline(\.hrv, before: day.date)
        let rhrBase = store.baseline(\.restingHeartRate, before: day.date)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            MetricTile(title: "HRV", value: day.hrv.map { "\(Int($0))" }, unit: "ms",
                       delta: delta(day.hrv, hrvBase), higherIsBetter: true)
            MetricTile(title: "Resting HR", value: day.restingHeartRate.map { "\(Int($0))" }, unit: "bpm",
                       delta: delta(day.restingHeartRate, rhrBase), higherIsBetter: false)
            MetricTile(title: "Asleep", value: day.sleep.map { Format.duration($0.minutesAsleep) }, unit: nil,
                       delta: nil, higherIsBetter: true)
            MetricTile(title: "Steps", value: day.steps.map { $0.formatted() }, unit: nil,
                       delta: nil, higherIsBetter: true)
        }
    }

    private func delta(_ value: Double?, _ base: Double?) -> Double? {
        guard let value, let base, base > 0 else { return nil }
        return value / base - 1
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Date bar

/// "Today" with arrows to step through days, and the settings button.
struct DateBar: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool
    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 4) {
            Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(!store.canGoBack)
            Text(Format.dayTitle(store.selectedDate))
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.numericText())
                .frame(minWidth: 110)
            Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!store.canGoForward)
            Spacer()
            if store.isSyncing { ProgressView().controlSize(.small).padding(.trailing, 8) }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 36, height: 36)
                    .background(Theme.card, in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .animation(.snappy, value: store.selectedDate)
    }
}

// MARK: - Cards

struct InsightCard: View {
    let scores: Scores

    var body: some View {
        let h = ScoreEngine.headline(scores)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("Today").haloLabel()
            }
            Text(h.title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink)
            Text(h.detail)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .haloCard()
    }
}

struct MetricTile: View {
    let title: String
    let value: String?
    let unit: String?
    let delta: Double?
    let higherIsBetter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).haloLabel()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "–").font(Theme.number(26)).foregroundStyle(Theme.ink)
                if let unit { Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary) }
            }
            if let delta {
                let good = (delta >= 0) == higherIsBetter
                HStack(spacing: 3) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text("\(Int(abs(delta) * 100))% vs baseline")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(abs(delta) < 0.03 ? Theme.secondary : (good ? Theme.ink : Theme.accent))
            } else {
                Text(" ").font(.system(size: 12))
            }
        }
        .haloCard(padding: 16)
    }
}

/// Last seven days, one row of slim bars per score. The selected day is the accent.
struct WeekCard: View {
    let week: [DayScore]
    let selected: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Last 7 days").haloLabel()
            ForEach(ScoreKind.allCases) { kind in
                HStack(alignment: .bottom, spacing: 0) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 76, alignment: .leading)
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(week) { item in
                            let v = kind.value(in: item.scores) ?? 0
                            let isSelected = Calendar.current.isDate(item.day.date, inSameDayAs: selected)
                            Capsule()
                                .fill(isSelected ? Theme.accent : Theme.ink.opacity(0.18 + 0.6 * v))
                                .frame(width: 8, height: max(4, 30 * v))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 30, alignment: .bottom)
                }
            }
            HStack(spacing: 6) {
                Spacer().frame(width: 76)
                ForEach(week) { item in
                    Text(item.day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .haloCard()
    }
}

struct HeartRateCard: View {
    let samples: [HeartSample]
    let resting: Double?

    var body: some View {
        let peak = samples.map(\.bpm).max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Heart rate").haloLabel()
                Spacer()
                Text("Peak \(Int(peak)) bpm").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            Chart {
                ForEach(samples, id: \.time) { s in
                    AreaMark(x: .value("Time", s.time), yStart: .value("Low", 40.0), yEnd: .value("BPM", s.bpm))
                        .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.16), Theme.ink.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.time), y: .value("BPM", s.bpm))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.monotone)
                }
                if let resting {
                    RuleMark(y: .value("Resting", resting))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Resting \(Int(resting))").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                }
            }
            .chartYScale(domain: 40...max(140, peak + 10))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [60.0, 100.0, 140.0]) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: 150)
        }
        .haloCard()
    }
}

struct ActivityCard: View {
    let day: DayMetrics
    let targets: Targets

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activity").haloLabel()
            progressRow("Active Zone Minutes", value: day.activeZoneMinutes ?? 0, target: targets.activeZoneMinutes,
                        text: "\(Int(day.activeZoneMinutes ?? 0)) / \(Int(targets.activeZoneMinutes))")
            progressRow("Steps", value: Double(day.steps ?? 0), target: targets.steps,
                        text: "\((day.steps ?? 0).formatted()) / \(Int(targets.steps).formatted())")
            if let kcal = day.activeCalories {
                HStack {
                    Text("Active calories").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("\(Int(kcal)) kcal").font(Theme.number(15, weight: .medium)).foregroundStyle(Theme.ink)
                }
            }
        }
        .haloCard()
    }

    private func progressRow(_ title: String, value: Double, target: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(text).font(Theme.number(15, weight: .medium)).foregroundStyle(Theme.ink)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.ink).frame(width: max(4, g.size.width * min(1, value / max(target, 1))))
                }
            }
            .frame(height: 5)
        }
    }
}

struct SampleBanner: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're seeing sample data").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Connect your Fitbit to see your own.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.tertiary)
            }
            .haloCard(padding: 16)
        }
        .buttonStyle(.plain)
    }
}
