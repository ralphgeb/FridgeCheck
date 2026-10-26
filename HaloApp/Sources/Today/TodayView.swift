import Charts
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool
    @State private var reveal = 0.0
    @State private var path = NavigationPath()

    // Edit mode: drag cards to reorder them, minus to hide one, plus to bring it back.
    @AppStorage("today.cards.v3") private var orderRaw = ""
    @AppStorage("today.hidden") private var hiddenRaw = ""
    @State private var editing = false
    @State private var dragging: TodayCard?
    @State private var dragOffset: CGFloat = 0
    @State private var dragShift: CGFloat = 0     // drag already used up by swapping past cards
    @State private var heights: [TodayCard: CGFloat] = [:]
    private let spacing: CGFloat = 14              // HaloPage's gap between cards

    var body: some View {
        let scores = store.scores(for: store.selectedDate)
        NavigationStack(path: $path) {
            HaloPage(showSettings: $showSettings, pinnedHeight: DialsHeader.expandedHeight, editing: $editing) { offset in
                DialsHeader(scores: scores, collapse: collapse(offset), reveal: reveal)
                    .padding(.horizontal, 20)
                    // each ring (or bar, once scrolled) opens its own page
                    .overlay {
                        HStack(spacing: 0) {
                            ForEach([Metric.recovery, .effort, .sleepScore]) { m in
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { if !editing { path.append(m) } }
                                    .accessibilityLabel(m.title)
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
            } content: {
                ForEach(visible) { card in
                    editableCard(card)
                }
                if editing {
                    hiddenSection
                } else if store.isSample {
                    SampleBanner { showSettings = true }
                }
            }
            .onPreferenceChange(CardHeightsKey.self) { heights = $0 }
            .navigationDestination(for: Metric.self) { MetricDetailView(metric: $0) }
            .navigationDestination(for: ZonesRoute.self) { HeartZonesView(date: $0.date) }
        }
        .onAppear { replayReveal() }
        .onChange(of: store.selectedDate) { _, _ in replayReveal() }
        .onChange(of: editing) { _, on in if !on { dragging = nil; dragOffset = 0 } }
        .sensoryFeedback(.impact(weight: .light), trigger: orderRaw)
        .sensoryFeedback(.selection, trigger: hiddenRaw)
        .sensoryFeedback(.impact(weight: .medium), trigger: dragging)
    }

    // MARK: Order and hiding

    private var order: [TodayCard] {
        let saved = orderRaw.split(separator: ",").compactMap { TodayCard(rawValue: String($0)) }
        return saved + TodayCard.allCases.filter { !saved.contains($0) }
    }

    private var hidden: Set<TodayCard> {
        Set(hiddenRaw.split(separator: ",").compactMap { TodayCard(rawValue: String($0)) })
    }

    private var visible: [TodayCard] { order.filter { isAvailable($0) && !hidden.contains($0) } }

    private func isAvailable(_ card: TodayCard) -> Bool {
        card != .heartRate || !store.selectedDay.heartRate.isEmpty
    }

    private func setHidden(_ card: TodayCard, _ hide: Bool) {
        var h = hidden
        if hide { h.insert(card) } else { h.remove(card) }
        withAnimation(.snappy) { hiddenRaw = TodayCard.allCases.filter(h.contains).map(\.rawValue).joined(separator: ",") }
    }

    /// Swaps two cards in the saved order.
    private func swap(_ a: TodayCard, _ b: TodayCard) {
        var cards = order
        guard let i = cards.firstIndex(of: a), let j = cards.firstIndex(of: b) else { return }
        cards.swapAt(i, j)
        orderRaw = cards.map(\.rawValue).joined(separator: ",")
    }

    // MARK: Editing

    @ViewBuilder
    private func editableCard(_ card: TodayCard) -> some View {
        let isDragged = dragging == card
        cardView(card)
            .allowsHitTesting(!editing)
            .background(GeometryReader { g in Color.clear.preference(key: CardHeightsKey.self, value: [card: g.size.height]) })
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(isDragged ? Theme.accent : Theme.hairline, lineWidth: isDragged ? 2 : 1)
                }
            }
            .overlay(alignment: .topLeading) {
                if editing {
                    CornerButton(symbol: "minus", label: "Hide \(card.title)") { setHidden(card, true) }
                        .offset(x: -8, y: -8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .trailing) {
                if editing {
                    // the handle: drag it and the card follows your finger straight away
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isDragged ? Theme.accent : Theme.secondary)
                        .frame(width: 40, height: 40)
                        .background(Theme.background.opacity(0.92), in: Circle())
                        .frame(width: 56, height: 64)
                        .contentShape(Rectangle())
                        .gesture(handleDrag(card))
                        .padding(.trailing, 4)
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(isDragged ? 1.03 : 1)
            .shadow(color: .black.opacity(isDragged ? 0.18 : 0), radius: 18, y: 10)
            .offset(y: isDragged ? dragOffset : 0)
            .zIndex(isDragged ? 1 : 0)
            .animation(isDragged ? nil : .snappy, value: orderRaw)
            .animation(.snappy, value: dragging)
            .accessibilityAction(named: "Move up") { moveByOne(card, -1) }
            .accessibilityAction(named: "Move down") { moveByOne(card, 1) }
    }

    private func handleDrag(_ card: TodayCard) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { drag in
                if dragging != card { dragging = card; dragShift = 0 }
                follow(card, translation: drag.translation.height)
            }
            .onEnded { _ in drop() }
    }

    private func drop() {
        withAnimation(.snappy) {
            dragging = nil
            dragOffset = 0
            dragShift = 0
        }
    }

    /// Keeps the dragged card under the finger, swapping it past a neighbour once it's
    /// more than halfway over it.
    private func follow(_ card: TodayCard, translation: CGFloat) {
        var offset = translation - dragShift
        let list = visible
        guard let i = list.firstIndex(of: card) else { return }
        if offset > 0, i + 1 < list.count {
            let h = heights[list[i + 1]] ?? 120
            if offset > h / 2 + spacing / 2 {
                swap(card, list[i + 1])
                dragShift += h + spacing
                offset -= h + spacing
            }
        } else if offset < 0, i > 0 {
            let h = heights[list[i - 1]] ?? 120
            if -offset > h / 2 + spacing / 2 {
                swap(card, list[i - 1])
                dragShift -= h + spacing
                offset += h + spacing
            }
        }
        dragOffset = offset
    }

    private func moveByOne(_ card: TodayCard, _ step: Int) {
        let list = visible
        guard let i = list.firstIndex(of: card), list.indices.contains(i + step) else { return }
        withAnimation(.snappy) { swap(card, list[i + step]) }
    }

    /// Cards you've turned off, faded, each with a plus to bring it back.
    @ViewBuilder
    private var hiddenSection: some View {
        let off = order.filter { hidden.contains($0) && isAvailable($0) }
        if !off.isEmpty {
            Text("Hidden").haloLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            ForEach(off) { card in
                cardView(card)
                    .allowsHitTesting(false)
                    .opacity(0.38)
                    .overlay(alignment: .topLeading) {
                        CornerButton(symbol: "plus", label: "Show \(card.title)") { setHidden(card, false) }
                            .offset(x: -8, y: -8)
                    }
            }
        } else {
            Text("Tap the minus on a card to hide it. Hidden cards wait here.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                .padding(.top, 6)
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
        case .heartRate: HeartZonesCard(day: day)
        case .calories: CaloriesCard(day: day)
        case .balance: BalanceSideCard(axes: store.balance(for: store.selectedDate))
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
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach([Metric.hrv, .restingHeartRate, .steps, .sleepDuration]) { m in
                NavigationLink(value: m) { MetricTile(metric: m, day: day) }
                    .buttonStyle(.plain)
            }
        }
    }
}

/// The round minus or plus on a card's corner in edit mode.
struct CornerButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 26, height: 26)
                .background(symbol == "minus" ? Theme.ink : Theme.accent, in: Circle())
                .overlay(Circle().stroke(Theme.background, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct CardHeightsKey: PreferenceKey {
    static var defaultValue: [TodayCard: CGFloat] = [:]
    static func reduce(value: inout [TodayCard: CGFloat], nextValue: () -> [TodayCard: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The cards on Today, in their default order.
enum TodayCard: String, CaseIterable, Identifiable {
    case insight, metrics, heartRate, trend, balance, cardio, calories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insight: return "Insight"
        case .metrics: return "Key numbers"
        case .trend: return "Last 7 days"
        case .cardio: return "Cardio load"
        case .heartRate: return "Heart rate zones"
        case .calories: return "Calories"
        case .balance: return "Balance"
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
        // compact: label, number and change on the left, the week's trend on the right
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metric.shortTitle).haloLabel()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value.map(metric.format) ?? "–").font(Theme.number(21)).foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if !metric.unit.isEmpty, metric != .steps {
                        Text(metric.unit).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                }
                deltaLabel(value: value, base: base)
            }
            Spacer(minLength: 0)
            Sparkline(values: trend).frame(width: 38, height: 22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(abs(d) < 0.03 || good == nil ? Theme.secondary : (good == true ? Theme.ink : Theme.accent))
        } else {
            Text(" ").font(.system(size: 11))
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

/// Cardio load over the last seven days against a weekly target that adapts to you.
struct CardioLoadCard: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        let week = store.cardioWeek(endingOn: store.selectedDate)
        let dailyShare = week.target / 7
        let maxBar = max(dailyShare * 1.8, week.days.compactMap(\.load).max() ?? 0)
        NavigationLink(value: Metric.cardioLoad) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("Cardio load · this week").haloLabel()
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
                                let load = item.load ?? 0
                                VStack(spacing: 6) {
                                    // days still to come are an empty outline
                                    Capsule()
                                        .fill(isSelected ? Theme.accent : Theme.ink.opacity(item.load == nil ? 0 : (load >= dailyShare ? 0.85 : 0.3)))
                                        .overlay(Capsule().stroke(Theme.ink.opacity(item.load == nil ? 0.15 : 0), lineWidth: 1))
                                        .frame(width: 8, height: item.load == nil ? 8 : max(4, 66 * load / max(maxBar, 1)))
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
        case "HRV": return "Scores 70 at your usual level, more when higher and steady."
        case "Recovery": return "Average recovery over the week."
        case "Steps": return "Daily average against your step target."
        case "Resting HR": return "Scores 70 at your usual; lower than usual scores higher."
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
                    Text(axis.detail ?? BalanceInfo.detail(axis)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(BalanceInfo.detail(axis)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(axis.value.percentText).font(Theme.number(22)).foregroundStyle(Theme.accent)
                    Text("score").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
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

/// Balance: like the widget, the radar on the left and the grades on the right.
/// Tap a grade to light up its spoke.
struct BalanceSideCard: View {
    let axes: [BalanceAxis]
    @State private var picked: String?

    var body: some View {
        let weakest = axes.min { $0.value < $1.value }
        let marked = axes.first { $0.id == picked } ?? weakest
        VStack(alignment: .leading, spacing: 12) {
            BalanceHeader(axes: axes)
            HStack(alignment: .center, spacing: 14) {
                RadarChart(axes: axes, showsLabels: false, highlight: picked)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .animation(.snappy, value: picked)
                VStack(spacing: 1) {
                    ForEach(axes) { a in
                        BalanceRow(axis: a, isMarked: a.id == marked?.id, compact: true)
                            .onTapGesture { withAnimation(.snappy) { picked = picked == a.id ? nil : a.id } }
                    }
                }
                .frame(width: 104)
            }
            if let marked { BalanceDetail(axis: marked, isWeakest: marked.id == weakest?.id) }
        }
        .haloCard()
        .sensoryFeedback(.selection, trigger: picked)
    }
}

struct BalanceHeader: View {
    let axes: [BalanceAxis]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Balance · this week").haloLabel()
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
                    Text("Connect Fitbit or Apple Health in Settings to see your own.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
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
