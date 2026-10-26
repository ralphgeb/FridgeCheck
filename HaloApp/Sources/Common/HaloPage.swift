import SwiftUI

/// Every tab is built the same way: a pinned header (with optional extra pinned content, like
/// Today's dials) and a scrolling page that slides underneath it.
///
/// Today's header is the date. Tapping it, or pulling the page down, slides a month calendar
/// down from under the date, pushing everything below it down too. Health and Sleep have a
/// plain title instead.
struct HaloPage<Pinned: View, Content: View>: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool
    var title: String? = nil
    /// Height of the pinned content below the header when the page is at the top.
    var pinnedHeight: CGFloat = 0
    /// When set, the header shows an Edit / Done button (Today only).
    var editing: Binding<Bool>? = nil
    @ViewBuilder var pinned: (_ scrollOffset: CGFloat) -> Pinned
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var showCalendar = false
    @State private var calendarHeight: CGFloat = 420
    /// Pull this far and let go to open the calendar. The page resists as you pull, so it's short.
    private let pullDistance: CGFloat = 34

    private var hasCalendar: Bool { title == nil }

    /// How much of the calendar shows: all of it when open, or as much as you've pulled.
    private var reveal: CGFloat {
        guard hasCalendar else { return 0 }
        let pull = max(0, -offset)
        return showCalendar ? calendarHeight + pull : min(pull, calendarHeight)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 14) { content() }
                    .padding(.horizontal, 20)
                    .padding(.top, DayHeader.height + pinnedHeight + 12 + (showCalendar ? calendarHeight : 0))
                    .padding(.bottom, 32)
                    // never wider than the screen, so the page only ever moves up and down
                    .containerRelativeFrame(.horizontal)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("page")).minY)
                    })
            }
            .coordinateSpace(name: "page")
            .modifier(TrackScrollOffset(offset: $offset))
            .modifier(PullToOpen(enabled: hasCalendar && editing?.wrappedValue != true, offset: offset, distance: pullDistance, isOpen: $showCalendar))
            // swiping up with the calendar open folds it away first, taking the page up with it
            .onChange(of: offset) { _, y in
                if showCalendar, y > 6 { withAnimation(HaloPageMotion.close) { showCalendar = false } }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            VStack(spacing: 0) {
                DayHeader(title: title, showSettings: $showSettings, showCalendar: $showCalendar, editing: editing)
                if hasCalendar {
                    // the calendar's bottom edge leads, so it slides down out of the header
                    MonthCalendar { date in
                        store.select(date)
                        withAnimation(HaloPageMotion.close) { showCalendar = false }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: CalendarHeightKey.self, value: g.size.height)
                    })
                    .frame(height: reveal, alignment: .bottom)
                    .clipped()
                    .allowsHitTesting(showCalendar)
                }
                pinned(offset)
            }
            .background(Theme.background.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).opacity(offset > 4 || showCalendar ? 1 : 0)
            }
            // with the calendar open, a swipe up anywhere on it (or the header) folds it away;
            // sideways swipes still change the month
            .simultaneousGesture(
                DragGesture(minimumDistance: 14).onEnded { v in
                    guard showCalendar, v.translation.height < -24, abs(v.translation.height) > abs(v.translation.width) else { return }
                    withAnimation(HaloPageMotion.close) { showCalendar = false }
                }
            )
            .onPreferenceChange(CalendarHeightKey.self) { if $0 > 0 { calendarHeight = $0 } }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: store.selectedDate)
        .sensoryFeedback(.impact(weight: .light), trigger: showCalendar)
    }
}

extension HaloPage where Pinned == EmptyView {
    init(showSettings: Binding<Bool>, title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self._showSettings = showSettings
        self.title = title
        self.pinnedHeight = 0
        self.pinned = { _ in EmptyView() }
        self.content = content
    }
}

private struct CalendarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Opens the calendar when you pull the page down and let go. While you pull, the calendar is
/// already sliding out by as much as you've pulled; letting go past `distance` finishes the
/// slide smoothly. (iOS 17 can't tell when you let go, so there it opens at the distance.)
private struct PullToOpen: ViewModifier {
    let enabled: Bool
    let offset: CGFloat
    let distance: CGFloat
    @Binding var isOpen: Bool
    @State private var armed = true
    @State private var furthest: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onChange(of: offset) { _, y in furthest = max(furthest, -y) }
                .onScrollPhaseChange { old, new in
                    if new == .interacting { furthest = 0 }
                    if old == .interacting, new != .interacting {
                        if enabled, !isOpen, furthest > distance {
                            withAnimation(HaloPageMotion.open) { isOpen = true }
                        }
                        furthest = 0
                    }
                }
        } else {
            content.onChange(of: offset) { _, y in
                if enabled, y < -distance, armed, !isOpen {
                    armed = false
                    withAnimation(HaloPageMotion.open) { isOpen = true }
                } else if y >= -2 {
                    armed = true
                }
            }
        }
    }
}

enum HaloPageMotion {
    static let open = Animation.smooth(duration: 0.42)
    static let close = Animation.smooth(duration: 0.34)
}

// MARK: - Header

/// "Sunday / 25 October" in the same style as the calendar app, or a plain title.
struct DayHeader: View {
    @EnvironmentObject private var store: HealthStore
    var title: String? = nil
    @Binding var showSettings: Bool
    @Binding var showCalendar: Bool
    var editing: Binding<Bool>? = nil
    static let height: CGFloat = 72

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: -1) {
                    Text(title).font(.system(size: 30, weight: .bold))
                    Text(Format.dayTitle(store.selectedDate))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .contentTransition(.numericText())
                }
                .foregroundStyle(Theme.ink)
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    withAnimation(showCalendar ? HaloPageMotion.close : HaloPageMotion.open) { showCalendar.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: -5) {
                        HStack(spacing: 6) {
                            Text(store.selectedDate.formatted(.dateTime.weekday(.wide)))
                                .font(.system(size: 22, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.tertiary)
                                .rotationEffect(.degrees(showCalendar ? 180 : 0))
                        }
                        Text(store.selectedDate.formatted(.dateTime.day().month(.wide)))
                            .font(.system(size: 30, weight: .thin))
                    }
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Format.dayTitle(store.selectedDate)). Show calendar")
            }

            Spacer()

            if store.isSyncing { ProgressView().controlSize(.small) }
            if !store.isTodaySelected || showCalendar {
                Button("Today") {
                    withAnimation(.snappy) {
                        store.select(.now)
                        showCalendar = false
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Theme.card, in: Capsule())
                .foregroundStyle(Theme.ink)
            }
            if let editing {
                Button(editing.wrappedValue ? "Done" : "Edit") {
                    withAnimation(.snappy) {
                        editing.wrappedValue.toggle()
                        showCalendar = false
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(editing.wrappedValue ? Theme.ink : Theme.card, in: Capsule())
                .foregroundStyle(editing.wrappedValue ? Theme.background : Theme.ink)
            }
            SettingsButton(showSettings: $showSettings)
        }
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .animation(.snappy, value: store.selectedDate)
    }
}

/// The gear in a round bubble, top right of every page.
struct SettingsButton: View {
    @Binding var showSettings: Bool

    var body: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .background(Theme.card, in: Circle())
                .foregroundStyle(Theme.ink)
        }
        .accessibilityLabel("Settings")
    }
}

// MARK: - Month calendar

/// A month at a time; swipe left and right between months. Each day wears its three rings.
struct MonthCalendar: View {
    @EnvironmentObject private var store: HealthStore
    var onPick: (Date) -> Void
    @State private var month: Date = .now

    private var cal: Calendar { WeekStart.calendar }

    private var months: [Date] {
        let first = cal.dateInterval(of: .month, for: store.firstDate)?.start ?? store.firstDate
        let last = cal.dateInterval(of: .month, for: .now)?.start ?? .now
        var out: [Date] = []
        var m = first
        while m <= last {
            out.append(m)
            guard let next = cal.date(byAdding: .month, value: 1, to: m) else { break }
            m = next
        }
        return out
    }

    var body: some View {
        let all = months
        VStack(spacing: 10) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Spacer()
                Button { shift(-1, in: all) } label: { Image(systemName: "chevron.left") }
                    .disabled(month == all.first)
                    .accessibilityLabel("Previous month")
                Button { shift(1, in: all) } label: { Image(systemName: "chevron.right") }
                    .disabled(month == all.last)
                    .padding(.leading, 18)
                    .accessibilityLabel("Next month")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { s in
                    Text(s)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            TabView(selection: $month) {
                ForEach(all, id: \.self) { m in
                    MonthGrid(month: m, onPick: onPick).tag(m)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 6 * 56)

            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach([1.0, 0.55, 0.15], id: \.self) { o in Circle().fill(Theme.ink.opacity(o)).frame(width: 4, height: 4) }
                }
                Text("Recovery · Effort · Sleep. Darker is closer to target.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .onAppear {
            month = cal.dateInterval(of: .month, for: store.selectedDate)?.start ?? store.selectedDate
        }
        .onChange(of: store.selectedDate) { _, d in
            month = cal.dateInterval(of: .month, for: d)?.start ?? d
        }
    }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    private func shift(_ delta: Int, in all: [Date]) {
        guard let i = all.firstIndex(of: month) else { return }
        let j = min(max(0, i + delta), all.count - 1)
        withAnimation(.snappy) { month = all[j] }
    }
}

struct MonthGrid: View {
    @EnvironmentObject private var store: HealthStore
    let month: Date
    var onPick: (Date) -> Void

    private var cal: Calendar { WeekStart.calendar }

    var body: some View {
        let days = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let today = cal.startOfDay(for: .now)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(0..<(lead + days), id: \.self) { i in
                if i < lead {
                    Color.clear.frame(height: 52)
                } else {
                    let date = cal.date(byAdding: .day, value: i - lead, to: month) ?? month
                    let isFuture = date > today
                    let isSelected = cal.isDate(date, inSameDayAs: store.selectedDate)
                    let hasData = store.day(date) != nil
                    let isToday = cal.isDate(date, inSameDayAs: today)
                    let scores = store.scores(for: date)
                    Button { onPick(date) } label: {
                        VStack(spacing: 4) {
                            Text("\(i - lead + 1)")
                                .font(.system(size: 15, weight: isSelected || isToday ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Theme.background : (hasData ? Theme.ink : Theme.tertiary))
                                .frame(width: 34, height: 34)
                                .background {
                                    if isSelected { Circle().fill(Theme.ink) }
                                    else if isToday { Circle().stroke(Theme.accent, lineWidth: 1.5) }
                                }
                            // Recovery, Effort, Sleep: faint when far from target, solid when it's met
                            HStack(spacing: 3) {
                                ForEach(ScoreKind.allCases) { k in
                                    Circle()
                                        .fill(Theme.ink.opacity(hasData ? 0.1 + 0.9 * min(1, max(0, k.value(in: scores) ?? 0)) : 0))
                                        .frame(width: 4, height: 4)
                                }
                            }
                        }
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isFuture || !hasData)
                    .opacity(isFuture ? 0.3 : 1)
                    .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Scroll tracking

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Reports how far a ScrollView has scrolled. iOS 18 reads it from the scroll view itself;
/// iOS 17 falls back to the preference set inside the content.
struct TrackScrollOffset: ViewModifier {
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in
                offset = v
            }
        } else {
            content.onPreferenceChange(ScrollOffsetKey.self) { offset = $0 }
        }
    }
}
