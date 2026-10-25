import SwiftUI

/// Every tab is built the same way: a pinned date header (with optional extra pinned content,
/// like Today's dials) and a scrolling page that slides underneath it.
/// Tapping the date drops down a month calendar.
struct HaloPage<Pinned: View, Content: View>: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool
    /// Height of the pinned content below the date when the page is at the top.
    var pinnedHeight: CGFloat = 0
    @ViewBuilder var pinned: (_ scrollOffset: CGFloat) -> Pinned
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var showCalendar = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 14) { content() }
                    .padding(.horizontal, 20)
                    .padding(.top, DayHeader.height + pinnedHeight + 12)
                    .padding(.bottom, 32)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("page")).minY)
                    })
            }
            .coordinateSpace(name: "page")
            .modifier(TrackScrollOffset(offset: $offset))
            .scrollIndicators(.hidden)
            .refreshable { await store.sync() }

            VStack(spacing: 0) {
                DayHeader(showSettings: $showSettings, showCalendar: $showCalendar)
                pinned(offset)
            }
            .background(Theme.background.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).opacity(offset > 4 ? 1 : 0)
            }

            if showCalendar {
                VStack(spacing: 0) {
                    Color.clear.frame(height: DayHeader.height).allowsHitTesting(false)
                    MonthCalendar { date in
                        store.select(date)
                        withAnimation(.snappy) { showCalendar = false }
                    }
                    .background(Theme.background)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    Color.black.opacity(0.28)
                        .ignoresSafeArea(edges: .bottom)
                        .onTapGesture { withAnimation(.snappy) { showCalendar = false } }
                        .transition(.opacity)
                }
                .clipped()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: store.selectedDate)
    }
}

extension HaloPage where Pinned == EmptyView {
    init(showSettings: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self._showSettings = showSettings
        self.pinnedHeight = 0
        self.pinned = { _ in EmptyView() }
        self.content = content
    }
}

// MARK: - Header

/// "Sunday / 25 October" in the same style as the calendar app. Tap it for the month view.
struct DayHeader: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool
    @Binding var showCalendar: Bool
    static let height: CGFloat = 72

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                withAnimation(.snappy) { showCalendar.toggle() }
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

            Spacer()

            if store.isSyncing { ProgressView().controlSize(.small) }
            if !store.isTodaySelected {
                Button("Today") { withAnimation(.snappy) { store.select(.now) } }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.card, in: Capsule())
                    .foregroundStyle(Theme.ink)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
                    .background(Theme.card, in: Circle())
                    .foregroundStyle(Theme.ink)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .animation(.snappy, value: store.selectedDate)
    }
}

// MARK: - Month calendar

/// A month at a time; swipe left and right between months. Each day wears its three rings.
struct MonthCalendar: View {
    @EnvironmentObject private var store: HealthStore
    var onPick: (Date) -> Void
    @State private var month: Date = .now

    private var cal: Calendar { Calendar.current }

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
            .frame(height: 6 * 50)

            HStack(spacing: 14) {
                legend("Recovery", 1)
                legend("Effort", 0.72)
                legend("Sleep", 0.44)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .onAppear {
            month = cal.dateInterval(of: .month, for: store.selectedDate)?.start ?? store.selectedDate
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

    private func legend(_ title: String, _ opacity: Double) -> some View {
        HStack(spacing: 5) {
            Circle().stroke(Theme.ink.opacity(opacity), lineWidth: 2).frame(width: 9, height: 9)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }
}

struct MonthGrid: View {
    @EnvironmentObject private var store: HealthStore
    let month: Date
    var onPick: (Date) -> Void

    private var cal: Calendar { Calendar.current }

    var body: some View {
        let days = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let today = cal.startOfDay(for: .now)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(0..<(lead + days), id: \.self) { i in
                if i < lead {
                    Color.clear.frame(height: 46)
                } else {
                    let date = cal.date(byAdding: .day, value: i - lead, to: month) ?? month
                    let isFuture = date > today
                    let isSelected = cal.isDate(date, inSameDayAs: store.selectedDate)
                    let hasData = store.day(date) != nil
                    Button { onPick(date) } label: {
                        ZStack {
                            if hasData { TripleRing(scores: store.scores(for: date), lineWidth: 2.2, gap: 1.4) }
                            Text("\(i - lead + 1)")
                                .font(.system(size: 13, weight: isSelected || cal.isDate(date, inSameDayAs: today) ? .bold : .regular))
                                .foregroundStyle(isSelected ? Theme.accent : (hasData ? Theme.ink : Theme.tertiary))
                        }
                        .frame(width: 44, height: 44)
                        .background {
                            if isSelected { Circle().fill(Theme.accent.opacity(0.12)) }
                        }
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
