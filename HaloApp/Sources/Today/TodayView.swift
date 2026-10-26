import Charts
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool
    @State private var reveal = 0.0
    /// Card order, saved between launches. Hold a card and drag it to move it.
    @AppStorage("today.cards") private var orderRaw = ""
    @State private var dropTarget: TodayCard?

    var body: some View {
        let scores = store.scores(for: store.selectedDate)
        NavigationStack {
            HaloPage(showSettings: $showSettings, pinnedHeight: DialsHeader.expandedHeight) { offset in
                DialsHeader(scores: scores, collapse: collapse(offset), reveal: reveal)
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
            } content: {
                ForEach(order.filter(isAvailable)) { card in
                    cardView(card)
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Theme.accent, lineWidth: 2)
                                .opacity(dropTarget == card ? 1 : 0)
                        }
                        .draggable(card.rawValue) {
                            Label(card.title, systemImage: "arrow.up.and.down")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first else { return false }
                            move(raw, onto: card)
                            return true
                        } isTargeted: { on in
                            withAnimation(.snappy) { dropTarget = on ? card : (dropTarget == card ? nil : dropTarget) }
                        }
                }
                Text("Hold any card to move it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 4)
                if store.isSample { SampleBanner { showSettings = true } }
            }
            .navigationDestination(for: Metric.self) { MetricDetailView(metric: $0) }
        }
        .onAppear { replayReveal() }
        .onChange(of: store.selectedDate) { _, _ in replayReveal() }
        .sensoryFeedback(.impact(weight: .light), trigger: orderRaw)
    }

    private var order: [TodayCard] {
        let saved = orderRaw.split(separator: ",").compactMap { TodayCard(rawValue: String($0)) }
        return saved + TodayCard.allCases.filter { !saved.contains($0) }
    }

    private func isAvailable(_ card: TodayCard) -> Bool {
        card != .heartRate || !store.selectedDay.heartRate.isEmpty
    }

    private func move(_ raw: String, onto target: TodayCard) {
        guard let card = TodayCard(rawValue: raw), card != target else { return }
        var cards = order
        guard let from = cards.firstIndex(of: card), let to = cards.firstIndex(of: target) else { return }
        cards.remove(at: from)
        // dropped on a card further down it lands below that card, further up above it
        cards.insert(card, at: to)
        withAnimation(.snappy) {
            orderRaw = cards.map(\.rawValue).joined(separator: ",")
            dropTarget = nil
        }
    }

    @ViewBuilder
    private func cardView(_ card: TodayCard) -> some View {
        let day = store.selectedDay
        switch card {
        case .insight: InsightCard(scores: store.scores(for: store.selectedDate), isToday: store.isTodaySelected)
        case .metrics: keyMetrics(day)
        case .trend: TrendCard(week: store.week(endingOn: store.selectedDate), selected: store.selectedDate)
        case .cardio: CardioLoadCard()
        case .heartRate: HeartRateCard(samples: day.heartRate, resting: day.restingHeartRate)
        case .calories: CaloriesCard(day: day)
        case .balance: BalanceCard(axes: store.balance(for: store.selectedDate))
        case .balanceSide: BalanceSideCard(axes: store.balance(for: store.selectedDate))
        }
    }

    private func collapse(_ offset: CGFloat) -> Double {
        Double(min(1, max(0, offset / (DialsHeader.expandedHeight - DialsHeader.collapsedHeight))))
    }

    private func replayReveal() {
        reveal = 0
        withAnimation(.spring(duration: 1.3, bounce: 0.12).delay(0.05)) { reveal = 1 }
    }

    private func keyMetrics(_ day: DayMetrics) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach([Metric.hrv, .restingHeartRate, .steps, .sleepDuration]) { m in
                NavigationLink(value: m) { MetricTile(metric: m, day: day) }
                    .buttonStyle(.plain)
            }
        }
    }
}

/// The cards on Today, in their default order.
enum TodayCard: String, CaseIterable, Identifiable {
    case insight, metrics, trend, cardio, heartRate, calories, balance, balanceSide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insight: return "Insight"
        case .metrics: return "Key numbers"
        case .trend: return "Last 7 days"
        case .cardio: return "Cardio load"
        case .heartRate: return "Heart rate"
        case .calories: return "Calories"
        case .balance: return "Balance"
        case .balanceSide: return "Balance B"
        }
    }
}

// MARK: - Cards

struct InsightCard: View {
    let scores: Scores
    let isToday: Bool

    var body: some View {
        let h = ScoreEngine.headline(scores)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text(isToday ? "Today" : "That day").haloLabel()
            }
            Text(h.title)
                .font(Theme.number(28))
                .foregroundStyle(Theme.ink)
            Text(h.detail)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .haloCard()
    }
}

/// A key number with its change against your baseline and a tiny 7-day trend. Tap for its graphs.
struct MetricTile: View {
    @EnvironmentObject private var store: HealthStore
    let metric: Metric
    let day: DayMetrics

    var body: some View {
        let value = metric.value(day, in: store)
        let base = store.baseline(metric, before: day.date)
        let trend = store.series(metric, days: 7, endingOn: day.date).map { $0.value }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(metric.shortTitle).haloLabel()
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map(metric.format) ?? "–").font(Theme.number(26)).foregroundStyle(Theme.ink)
                if !metric.unit.isEmpty, metric != .steps {
                    Text(metric.unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            HStack(alignment: .bottom) {
                deltaLabel(value: value, base: base)
                Spacer(minLength: 4)
                Sparkline(values: trend).frame(width: 44, height: 18)
            }
        }
        .haloCard(padding: 16)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func deltaLabel(value: Double?, base: Double?) -> some View {
        if let value, let base, base > 0 {
            let d = value / base - 1
            let good = metric.higherIsBetter.map { (d >= 0) == $0 }
            HStack(spacing: 2) {
                Image(systemName: d >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text("\(Int((abs(d) * 100).rounded()))%")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(abs(d) < 0.03 || good == nil ? Theme.secondary : (good == true ? Theme.ink : Theme.accent))
        } else {
            Text(" ").font(.system(size: 12))
        }
    }
}

/// Three lines, one per score, over the last seven days. Drag across to read any day.
struct TrendCard: View {
    let week: [DayScore]
    let selected: Date
    @State private var hidden: Set<ScoreKind> = []
    @State private var scrub: Date?

    private struct Point: Identifiable {
        let kind: ScoreKind
        let date: Date
        let value: Double
        var id: String { "\(kind.rawValue)-\(date.timeIntervalSince1970)" }
    }

    var body: some View {
        let points = week.flatMap { item in
            ScoreKind.allCases.compactMap { k in k.value(in: item.scores).map { Point(kind: k, date: item.day.date, value: $0 * 100) } }
        }
        let focus = scrub ?? selected
        let focusItem = week.first { Calendar.current.isDate($0.day.date, inSameDayAs: focus) }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Last 7 days").haloLabel()
                Spacer()
                Text(focusItem.map { Format.dayTitle($0.day.date) } ?? "")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            // Legend doubles as the readout and the on/off switch for each line.
            HStack(spacing: 8) {
                ForEach(ScoreKind.allCases) { k in
                    Button {
                        withAnimation(.snappy) { if hidden.contains(k) { hidden.remove(k) } else if hidden.count < 2 { hidden.insert(k) } }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Capsule().fill(Theme.ink.opacity(opacity(k))).frame(width: 12, height: 3)
                                Text(k.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                            }
                            Text(focusItem.flatMap { k.value(in: $0.scores) }.map { $0.percentText } ?? "–")
                                .font(Theme.number(20)).foregroundStyle(Theme.ink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(hidden.contains(k) ? 0.3 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            Chart {
                ForEach(points.filter { !hidden.contains($0.kind) }) { p in
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Score", p.value), series: .value("Kind", p.kind.title))
                        .foregroundStyle(Theme.ink.opacity(opacity(p.kind)))
                        .lineStyle(StrokeStyle(lineWidth: p.kind == .recovery ? 2.6 : 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value("Score", p.value))
                        .foregroundStyle(Calendar.current.isDate(p.date, inSameDayAs: focus) ? Theme.accent : Theme.ink.opacity(opacity(p.kind)))
                        .symbolSize(Calendar.current.isDate(p.date, inSameDayAs: focus) ? 42 : 14)
                }
                RuleMark(x: .value("Focus", focus, unit: .day))
                    .foregroundStyle(Theme.accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            .chartYScale(domain: 0...100)
            .chartXSelection(value: $scrub)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow)).foregroundStyle(Theme.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: 170)
        }
        .haloCard()
        .sensoryFeedback(.selection, trigger: scrub.map { Calendar.current.startOfDay(for: $0) })
    }

    private func opacity(_ k: ScoreKind) -> Double {
        switch k {
        case .recovery: return 1
        case .effort: return 0.55
        case .sleep: return 0.3
        }
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

/// Cardio load over the last seven days against a weekly target that adapts to you.
struct CardioLoadCard: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        let week = store.cardioWeek(endingOn: store.selectedDate)
        let dailyShare = week.target / 7
        let maxBar = max(dailyShare * 1.8, week.days.map(\.load).max() ?? 0)
        NavigationLink(value: Metric.cardioLoad) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("Cardio load").haloLabel()
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        Text(week.focus.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Theme.track, in: Capsule())
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        Ring(progress: week.progress, lineWidth: 7)
                        VStack(spacing: 0) {
                            Text("\(Int(week.load.rounded()))").font(Theme.number(22)).foregroundStyle(Theme.ink)
                            Text("of \(Int(week.target))").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(width: 84, height: 84)
                    // a bar per day; the dashed line is a day's share of the weekly target
                    ZStack(alignment: .bottom) {
                        GeometryReader { g in
                            let y = g.size.height - 18 - (g.size.height - 18) * CGFloat(dailyShare / max(maxBar, 1))
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: y))
                                p.addLine(to: CGPoint(x: g.size.width, y: y))
                            }
                            .stroke(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                        HStack(alignment: .bottom, spacing: 7) {
                            ForEach(week.days, id: \.date) { item in
                                let isSelected = Calendar.current.isDate(item.date, inSameDayAs: store.selectedDate)
                                VStack(spacing: 6) {
                                    Capsule()
                                        .fill(isSelected ? Theme.accent : Theme.ink.opacity(item.load >= dailyShare ? 0.85 : 0.3))
                                        .frame(width: 8, height: max(4, 66 * item.load / max(maxBar, 1)))
                                    Text(item.date.formatted(.dateTime.weekday(.narrow)))
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                                        .frame(height: 12)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: 84)
                }
                HStack(spacing: 0) {
                    figure("Today", store.selectedDay.cardioLoad.map { "\(Int($0.rounded()))" } ?? "–")
                    figure("To go", week.remaining < 1 ? "Done" : "\(Int(week.remaining.rounded()))")
                    figure("Usual week", week.baseline.map { "\(Int($0.rounded()))" } ?? "–")
                }
                Text("\(week.focus.title): \(week.focus.detail.prefix(1).lowercased() + week.focus.detail.dropFirst())")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .haloCard()
        }
        .buttonStyle(.plain)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).haloLabel()
            Text(value).font(Theme.number(17, weight: .medium)).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Active + resting = total, as one split bar.
struct CaloriesCard: View {
    @EnvironmentObject private var store: HealthStore
    let day: DayMetrics

    var body: some View {
        let resting = store.restingCalories(day)
        let active = day.activeCalories ?? 0
        let total = resting + active
        NavigationLink(value: Metric.totalCalories) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Calories").haloLabel()
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Int(total).formatted()).font(Theme.number(30)).foregroundStyle(Theme.ink)
                    Text(store.isTodaySelected ? "kcal so far" : "kcal").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                GeometryReader { g in
                    HStack(spacing: 3) {
                        Capsule().fill(Theme.ink).frame(width: max(4, (g.size.width - 3) * active / max(total, 1)))
                        Capsule().fill(Theme.ink.opacity(0.18))
                    }
                }
                .frame(height: 8)
                HStack {
                    legend("Active", active, Theme.ink)
                    Spacer()
                    legend("Resting", resting, Theme.ink.opacity(0.18))
                }
            }
            .haloCard()
        }
        .buttonStyle(.plain)
    }

    private func legend(_ title: String, _ v: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 12, height: 6)
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Text(Int(v).formatted()).font(Theme.number(14, weight: .medium)).foregroundStyle(Theme.ink)
        }
    }
}

/// What each Balance spoke means, and which graph it opens.
enum BalanceInfo {
    static func metric(_ axis: BalanceAxis) -> Metric {
        switch axis.name {
        case "Sleep": return .sleepScore
        case "HRV": return .hrv
        case "Recovery": return .recovery
        case "Steps": return .steps
        case "Resting HR": return .restingHeartRate
        default: return .cardioLoad
        }
    }

    static func detail(_ axis: BalanceAxis) -> String {
        switch axis.name {
        case "Sleep": return "Average sleep score over the week."
        case "HRV": return "Level against your baseline, and how steady it stayed."
        case "Recovery": return "Average recovery over the week."
        case "Steps": return "Daily average against your step target."
        case "Resting HR": return "The week against your baseline. Lower is better."
        default: return "Cardio load over the week against your target."
        }
    }
}

/// Picked spoke: what it is, its score, and a link to its graph.
struct BalanceDetail: View {
    let axis: BalanceAxis
    let isWeakest: Bool

    var body: some View {
        NavigationLink(value: BalanceInfo.metric(axis)) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(axis.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        if isWeakest {
                            Text("WEAKEST").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.accent)
                        }
                    }
                    Text(BalanceInfo.detail(axis)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(axis.value.percentText).font(Theme.number(22)).foregroundStyle(Theme.accent)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
            }
            .padding(12)
            .background(Theme.track, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One spoke as a row: name, a thin bar and the score. Tap to pick it on the radar.
struct BalanceRow: View {
    let axis: BalanceAxis
    let isMarked: Bool
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(compact ? axis.short : axis.name)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .foregroundStyle(isMarked ? Theme.accent : Theme.ink)
                Spacer()
                Text(axis.value.percentText).font(Theme.number(compact ? 13 : 14, weight: .semibold))
                    .foregroundStyle(isMarked ? Theme.accent : Theme.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(isMarked ? Theme.accent : Theme.ink.opacity(0.55))
                        .frame(width: max(3, g.size.width * CGFloat(axis.value)))
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, compact ? 3 : 5)
        .contentShape(Rectangle())
    }
}

/// Balance, layout A: the radar in the middle, spokes listed underneath.
struct BalanceCard: View {
    let axes: [BalanceAxis]
    @State private var picked: String?

    var body: some View {
        let weakest = axes.min { $0.value < $1.value }
        let marked = axes.first { $0.id == picked } ?? weakest
        VStack(alignment: .leading, spacing: 12) {
            BalanceHeader(axes: axes, layout: "A")
            RadarChart(axes: axes, highlight: picked)
                .frame(height: 230)
                .animation(.snappy, value: picked)
            if let marked { BalanceDetail(axis: marked, isWeakest: marked.id == weakest?.id) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 4) {
                ForEach(axes) { a in
                    BalanceRow(axis: a, isMarked: a.id == marked?.id)
                        .onTapGesture { withAnimation(.snappy) { picked = picked == a.id ? nil : a.id } }
                }
            }
        }
        .haloCard()
        .sensoryFeedback(.selection, trigger: picked)
    }
}

/// Balance, layout B: like the widget, the radar on the left and the grades on the right.
struct BalanceSideCard: View {
    let axes: [BalanceAxis]
    @State private var picked: String?

    var body: some View {
        let weakest = axes.min { $0.value < $1.value }
        let marked = axes.first { $0.id == picked } ?? weakest
        VStack(alignment: .leading, spacing: 12) {
            BalanceHeader(axes: axes, layout: "B")
            HStack(alignment: .center, spacing: 16) {
                RadarChart(axes: axes, showsLabels: false, highlight: picked)
                    .frame(width: 140, height: 140)
                    .animation(.snappy, value: picked)
                VStack(spacing: 2) {
                    ForEach(axes) { a in
                        BalanceRow(axis: a, isMarked: a.id == marked?.id, compact: true)
                            .onTapGesture { withAnimation(.snappy) { picked = picked == a.id ? nil : a.id } }
                    }
                }
            }
            if let marked { BalanceDetail(axis: marked, isWeakest: marked.id == weakest?.id) }
        }
        .haloCard()
        .sensoryFeedback(.selection, trigger: picked)
    }
}

struct BalanceHeader: View {
    let axes: [BalanceAxis]
    let layout: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Balance").haloLabel()
            Text(layout).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline))
            Spacer()
            Text(axes.overall.percentText).font(Theme.number(22)).foregroundStyle(Theme.ink)
            Text("/ 100").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
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

/// Tiny trend line with the last point in the accent.
struct Sparkline: View {
    let values: [Double]
    var range: NormalRange? = nil

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
            ctx.stroke(p, with: .color(Theme.ink.opacity(0.7)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            if let last = values.last {
                let pt = CGPoint(x: size.width, y: y(last))
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)), with: .color(Theme.accent))
            }
        }
    }
}
