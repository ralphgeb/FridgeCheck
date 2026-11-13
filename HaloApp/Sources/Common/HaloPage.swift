import Observation
import SwiftUI

/// Where a page has scrolled to. Kept apart from the page itself, so a scroll only redraws the
/// few things that follow it (the header, the rings, the calendar's reveal), never the cards.
@Observable
final class PageScroll {
    var offset: CGFloat = 0
    /// The offset when the header last showed or hid (read only while scrolling, never drawn).
    @ObservationIgnored var lastTurn: CGFloat = 0
}

/// Draws `content` from the scroll position: only this redraws as the page moves.
struct OffsetReader<V: View>: View {
    let scroll: PageScroll
    @ViewBuilder let content: (CGFloat) -> V
    var body: some View { content(scroll.offset) }
}

/// Calls back as the page scrolls, without the page itself redrawing.
private struct OnScroll: ViewModifier {
    let scroll: PageScroll
    let action: (_ old: CGFloat, _ new: CGFloat) -> Void
    func body(content: Content) -> some View {
        content.onChange(of: scroll.offset) { old, new in action(old, new) }
    }
}

/// Every tab is built the same way: a pinned header (with optional extra pinned content, like
/// Today's dials) and a scrolling page that slides underneath it.
///
/// Tapping the page's tab again scrolls it back to the top; tapping once more from the top goes back
/// to today. On the pages with a title (Fitness, Health, Sleep) the header slides up out of the way
/// as you scroll down, so the cards get the whole screen, and comes back as soon as you scroll up.
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
    /// When set, the header shows an Edit / Done button (Today and Health).
    var editing: Binding<Bool>? = nil
    @ViewBuilder var pinned: (_ scrollOffset: CGFloat) -> Pinned
    @ViewBuilder var content: () -> Content

    @State private var scroll = PageScroll()
    /// Read only in actions (gestures, taps, callbacks), never while drawing the page.
    private var offset: CGFloat { scroll.offset }
    @State private var showCalendar = false
    /// 0 closed, 1 open. Animated, while everything that depends on the scroll position is worked
    /// out fresh every frame, so the opening slide and the page springing back never fight.
    @State private var openness: Double = 0
    @State private var calendarHeight: CGFloat = 420
    @State private var dragging = false
    @State private var dragIsVertical: Bool?
    /// Asks the scroll view to jump to an offset (iOS 18), used to fold the calendar away invisibly.
    @State private var scrollRequest: CGFloat?
    /// The header slides away while you scroll down, and comes back as soon as you scroll up
    /// (titled pages only), as in Scout: all the way or not at all, never half.
    @State private var headerHidden = false
    /// The status bar's height: the header slides past it too, right off the screen.
    @State private var topInset: CGFloat = 0
    /// The scroll view's width: the page is laid out to exactly this, so turning the screen
    /// lays it out again straight away (a relative frame kept the old width after a rotation).
    @State private var pageWidth: CGFloat = 0
    /// iOS's status bar runs across the top (the iPhone Duo opened up, held upright): the page
    /// goes up into it, its header clear of the clock and battery on the right.
    @Environment(\.statusBand) private var statusBand
    private var statusAcrossTop: Bool { statusBand > 0 }
    private var topPad: CGFloat { statusAcrossTop ? 10 : 0 }
    /// Counts taps on this page's tab while it's already showing.
    @Environment(\.tabReselect) private var reselect
    /// The iPhone Duo opened up: the cards go in two columns.
    @Environment(\.wideLayout) private var wide
    /// Pulling the page stretches it with resistance; the calendar comes out this much faster.
    private let pullGain: CGFloat = 2.4
    /// How much calendar a pull has to show before letting go opens it.
    private let openAfter: CGFloat = 44
    /// How far a pull has to go before letting go syncs (titled pages, or Today with the calendar out).
    private var refreshAfter: CGFloat { PullToRefreshHint.threshold }
    /// Sample data is softened and labelled, except in screenshots of the app (a launch flag).
    private var softened: Bool { store.showingSample && !Distribution.isScreenshots }
    private var pullRefreshes: Bool { editing?.wrappedValue != true && (!store.showingSample || Distribution.isScreenshots) }

    private var hasCalendar: Bool { title == nil }
    private var calendarEnabled: Bool { hasCalendar && editing?.wrappedValue != true }
    /// Titled pages hide their header while scrolling down (not while editing).
    private var hidesHeader: Bool { !hasCalendar && editing?.wrappedValue != true }
    private var headerHeight: CGFloat { DayHeader.height + pinnedHeight }
    /// How far the header goes up when hidden: its own height and the status bar's, so none of it
    /// is left showing.
    private var hiddenShift: CGFloat { headerHeight + topInset + 12 }
    private func setOpen(_ open: Bool, _ animation: Animation?) {
        withAnimation(animation) {
            showCalendar = open
            openness = open ? 1 : 0
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                Color.clear.frame(height: 0).id("halo.top")
                (wide ? AnyLayout(ColumnsLayout(columns: 2, spacing: 16)) : AnyLayout(VStackLayout(spacing: 14))) { content() }
                    // sample data is plainly not yours: softened, and not tappable
                    .blur(radius: softened ? 5 : 0)
                    .saturation(softened ? 0.3 : 1)
                    .allowsHitTesting(!softened)
                    .padding(.horizontal, wide ? 28 : 20)
                    .modifier(CalendarGap(base: DayHeader.height + pinnedHeight + 12 + topPad, scroll: scroll,
                                          pullGain: pullGain, revealsOnPull: calendarEnabled,
                                          calendarHeight: calendarHeight,
                                          open: hasCalendar ? calendarHeight : 0,
                                          progress: openness))
                    .padding(.bottom, 32)
                    // never wider than the screen, so the page only ever moves up and down
                    .frame(width: pageWidth > 0 ? pageWidth : nil)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("page")).minY)
                    })
                }
            }
            .coordinateSpace(name: "page")
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            .modifier(TrackScrollOffset(offset: Binding(get: { scroll.offset }, set: { scroll.offset = $0 })))
            .modifier(ScrollToRequest(y: $scrollRequest))
            .modifier(ScrollRelease(scroll: scroll, onRelease: { furthestPull in
                // let go of a pull: open if it showed enough of the calendar
                guard calendarEnabled, !dragging, !showCalendar else { return }
                if furthestPull * pullGain > openAfter { setOpen(true, HaloPageMotion.open) }
            }, onPullEnd: { furthestPull in
                // a long pull syncs: on the titled pages, and on Today once the calendar is out
                guard pullRefreshes, !dragging, furthestPull > refreshAfter,
                      !hasCalendar || (showCalendar && openness > 0.9) else { return }
                Task { await store.sync() }
            }, onSettle: {
                // the page has stopped moving after being scrolled up under the calendar: fold it
                // away now, never while the scroll is still gliding (that's what made it judder)
                guard calendarEnabled, !dragging, showCalendar, offset > 30 else { return }
                closeAfterScroll()
            }))
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: reselect) { _, _ in reselected(proxy) }
            }

            VStack(spacing: 0) {
                DayHeader(title: title, showSettings: $showSettings, showCalendar: $showCalendar, editing: editing)
                    .padding(.top, topPad)
                if hasCalendar {
                    // the calendar's bottom edge leads, so it slides down out of the header
                    MonthCalendar { date in
                        store.select(date)
                        setOpen(false, HaloPageMotion.close)
                    }
                    // on a wide screen the month keeps a phone's proportions
                    .frame(maxWidth: wide ? 560 : .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: CalendarHeightKey.self, value: g.size.height)
                    })
                    .modifier(CalendarReveal(scroll: scroll, pullGain: pullGain, revealsOnPull: calendarEnabled,
                                             calendarHeight: calendarHeight, progress: openness))
                    .overlay(alignment: .top) {
                        if showCalendar && pullRefreshes {
                            OffsetReader(scroll: scroll) { y in PullToRefreshHint(pull: max(0, -y)) }
                        }
                    }
                    .allowsHitTesting(showCalendar && !dragging)
                }
                // the rings see no scroll while the calendar is out, until the page has gone up
                // past it, so they only fold into a line once they reach the top
                let folded = hasCalendar ? calendarHeight * CGFloat(openness) : 0
                OffsetReader(scroll: scroll) { y in pinned(y - folded) }
                    .blur(radius: softened ? 5 : 0)
                    .saturation(softened ? 0.3 : 1)
            }
            .background(Theme.background.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) {
                let calendarOut = showCalendar
                let hidden = headerHidden
                OffsetReader(scroll: scroll) { y in
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        .opacity((y > 4 || calendarOut) && !hidden ? 1 : 0)
                }
            }
            .overlay(alignment: .bottom) {
                if !hasCalendar && pullRefreshes {
                    OffsetReader(scroll: scroll) { y in
                        PullToRefreshHint(pull: max(0, -y))
                            .alignmentGuide(.bottom) { d in d[.top] }
                    }
                    .allowsHitTesting(false)
                }
            }
            .offset(y: headerHidden ? -hiddenShift : 0)
            .opacity(headerHidden ? 0 : 1)
            .animation(.snappy(duration: 0.32), value: headerHidden)
            // drag down anywhere on the header (date, rings) to pull the calendar out, and up on
            // the calendar to push it back: it follows your finger. Sideways swipes change the month.
            .simultaneousGesture(headerDrag)
            .onPreferenceChange(CalendarHeightKey.self) { if $0 > 0 { calendarHeight = $0 } }
            // the header's buttons (date, Today, Edit) open and close it too
            .onChange(of: showCalendar) { _, open in
                guard !dragging, (openness > 0.5) != open else { return }
                withAnimation(open ? HaloPageMotion.open : HaloPageMotion.close) { openness = open ? 1 : 0 }
            }

            // over the softened sample data, on every page: what it is and what's happening
            if softened {
                SampleBanner { showSettings = true }
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                    .padding(.horizontal, 20)
                    .padding(.top, DayHeader.height + pinnedHeight * 0.35)
                    .transition(.opacity)
            }

        }
        // the status bar keeps a plain background once the header has gone, so the time and battery
        // stay readable over the cards
        .overlay(alignment: .top) {
            if hidesHeader {
                Theme.background
                    .frame(height: statusAcrossTop ? statusBand : topInset)
                    .offset(y: statusAcrossTop ? 0 : -topInset)
                    .opacity(headerHidden ? 1 : 0)
                    .animation(.snappy(duration: 0.32), value: headerHidden)
                    .allowsHitTesting(false)
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { topInset = g.safeAreaInsets.top }
                .onChange(of: g.safeAreaInsets.top) { _, v in topInset = v }
        }
        // full screen, so the reader sees the status bar's inset
        .ignoresSafeArea())
        .modifier(OnScroll(scroll: scroll) { old, new in followScroll(from: old, to: new) })
        .onChange(of: editing?.wrappedValue) { _, _ in headerHidden = false }
        .background(Theme.background.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: statusAcrossTop ? .top : [])
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: store.selectedDate)
        .sensoryFeedback(.impact(weight: .light), trigger: showCalendar)
        .sensoryFeedback(.impact(weight: .light), trigger: reselect)
    }

    /// Scout's way: near the top (or editing) the header always shows; a clear move down the page
    /// hides it, a clear move up brings it back, and small wobbles are ignored.
    private func followScroll(from old: CGFloat, to y: CGFloat) {
        guard hidesHeader else {
            if headerHidden { headerHidden = false }
            scroll.lastTurn = y
            return
        }
        let delta = y - scroll.lastTurn
        let hide: Bool
        if y < headerHeight {
            hide = false
        } else if delta > 8 {
            hide = true
        } else if delta < -8 {
            hide = false
        } else {
            return
        }
        scroll.lastTurn = y
        // only a real change redraws the page
        if hide != headerHidden { headerHidden = hide }
    }

    /// The tab was tapped again: back to the top first (closing the calendar), then to today.
    private func reselected(_ proxy: ScrollViewProxy) {
        if showCalendar {
            setOpen(false, HaloPageMotion.close)
            withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo("halo.top", anchor: .top) }
        } else if offset > 4 {
            headerHidden = false
            withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo("halo.top", anchor: .top) }
        } else if !store.isTodaySelected {
            withAnimation(.snappy) { store.select(.now) }
        }
    }

    private var headerDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                guard calendarEnabled, offset <= 2 else { return }
                if dragIsVertical == nil { dragIsVertical = abs(v.translation.height) > abs(v.translation.width) }
                guard dragIsVertical == true else { return }
                dragging = true
                let start = showCalendar ? calendarHeight : 0
                // follow the finger exactly: no animation while dragging
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { openness = Double(min(calendarHeight, max(0, start + v.translation.height)) / calendarHeight) }
            }
            .onEnded { v in
                defer { dragIsVertical = nil; dragging = false }
                guard dragging else { return }
                // a short pull or a flick is enough either way; otherwise it settles back
                let start = showCalendar ? calendarHeight : 0
                let projected = Double((start + v.predictedEndTranslation.height) / calendarHeight)
                let open = showCalendar ? !(openness < 0.75 || projected < 0.5) : (openness > 0.18 || projected > 0.5)
                setOpen(open, open ? HaloPageMotion.open : HaloPageMotion.close)
            }
    }

    /// Folds the calendar away after the page has been scrolled up under it. If the calendar is
    /// already scrolled out of sight, the swap is invisible: the gap closes and the page jumps back
    /// by the same amount. If part of it still shows, the page is first moved back to the top while
    /// the calendar is set to show exactly that part (nothing on screen moves), and then it slides
    /// shut from there.
    private func closeAfterScroll() {
        guard #available(iOS 18, *) else {
            setOpen(false, HaloPageMotion.close)
            return
        }
        var t = Transaction()
        t.disablesAnimations = true
        if offset >= calendarHeight {
            withTransaction(t) {
                showCalendar = false
                openness = 0
                scrollRequest = offset - calendarHeight
            }
        } else {
            withTransaction(t) {
                openness = Double(max(0, (calendarHeight - offset) / calendarHeight))
                scrollRequest = 0
            }
            DispatchQueue.main.async { setOpen(false, HaloPageMotion.close) }
        }
    }
}

extension HaloPage where Pinned == EmptyView {
    init(showSettings: Binding<Bool>, title: String? = nil, editing: Binding<Bool>? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self._showSettings = showSettings
        self.title = title
        self.editing = editing
        self.pinnedHeight = 0
        self.pinned = { _ in EmptyView() }
        self.content = content
    }
}

/// The calendar's visible height, blended between closed and open by an animated progress.
/// Because progress is the only animated value, the scroll position can change mid-animation
/// (the page springing back after a pull) without the slide stuttering.
private struct CalendarReveal: ViewModifier, Animatable {
    let scroll: PageScroll
    let pullGain: CGFloat
    let revealsOnPull: Bool
    let calendarHeight: CGFloat
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // how much shows closed (as much as you've pulled, sped up) and open (all of it, less how
        // far the page has scrolled up); progress blends the two
        let offset = scroll.offset
        let pull = max(0, -offset)
        let closed = revealsOnPull ? min(pull * pullGain, calendarHeight) : 0
        let open = max(0, calendarHeight - max(0, offset)) + pull
        return content
            .frame(height: max(0, closed + (open - closed) * CGFloat(progress)), alignment: .bottom)
            .clipped()
    }
}

/// The matching gap at the top of the page, so it stays attached under the calendar.
private struct CalendarGap: ViewModifier, Animatable {
    let base: CGFloat
    let scroll: PageScroll
    let pullGain: CGFloat
    let revealsOnPull: Bool
    let calendarHeight: CGFloat
    let open: CGFloat
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // room for the calendar; while you pull, the stretch already moves the page by the pull,
        // so only the difference is added. Only read while pulling, so a normal scroll doesn't
        // redraw the page.
        let closed: CGFloat
        if revealsOnPull {
            let pull = max(0, -scroll.offset)
            closed = max(0, min(pull * pullGain, calendarHeight) - pull)
        } else {
            closed = 0
        }
        return content.padding(.top, base + max(0, closed + (open - closed) * CGFloat(progress)))
    }
}

private struct CalendarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Calls back when a finger lets go of the scroll view, with how far the page was pulled down past
/// the top during that touch, and again when the page has come to rest after the touch. (iOS 17
/// can't tell either, so there it calls back as soon as the page is pulled 30 points, or scrolled
/// up 60.)
private struct ScrollRelease: ViewModifier {
    let scroll: PageScroll
    let onRelease: (_ furthestPull: CGFloat) -> Void
    /// The pull is over (the finger is off); on iOS 17, once the page has sprung back.
    var onPullEnd: (_ furthestPull: CGFloat) -> Void = { _ in }
    let onSettle: () -> Void
    @State private var furthest: CGFloat = 0
    @State private var furthestAny: CGFloat = 0
    @State private var armed = true
    @State private var touched = false

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onChange(of: scroll.offset) { _, y in if -y > furthest { furthest = -y } }
                .onScrollPhaseChange { old, new in
                    if new == .interacting { furthest = 0; touched = true }
                    if old == .interacting, new != .interacting {
                        // the pull's end first, so it sees whether the calendar was out before this pull
                        onPullEnd(furthest)
                        onRelease(furthest)
                        furthest = 0
                    }
                    if new == .idle, touched {
                        touched = false
                        onSettle()
                    }
                }
        } else {
            content.onChange(of: scroll.offset) { _, y in
                if -y > furthestAny { furthestAny = -y }
                if y > -2, furthestAny > 0 {
                    onPullEnd(furthestAny)
                    furthestAny = 0
                }
                if armed, y < -30 {
                    armed = false
                    onRelease(max(0, -y))
                } else if armed, y > 60 {
                    armed = false
                    onSettle()
                } else if abs(y) < 2 {
                    armed = true
                }
            }
        }
    }
}

/// Lets the page jump the scroll view to an offset (iOS 18 and later).
private struct ScrollToRequest: ViewModifier {
    @Binding var y: CGFloat?

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.modifier(ScrollPositionBridge(y: $y))
        } else {
            content
        }
    }
}

@available(iOS 18, *)
private struct ScrollPositionBridge: ViewModifier {
    @Binding var y: CGFloat?
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: y) { _, value in
                guard let value else { return }
                position.scrollTo(y: value)
                y = nil
            }
    }
}

enum HaloPageMotion {
    static let open = Animation.smooth(duration: 0.42)
    static let close = Animation.smooth(duration: 0.34)
}

/// How many times the showing tab has been tapped again (each page reads its own tab's count).
private struct TabReselectKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var tabReselect: Int {
        get { self[TabReselectKey.self] }
        set { self[TabReselectKey.self] = newValue }
    }
}

// MARK: - Header

/// "Sunday / 25 October" in the same style as the calendar app, or a plain title.
struct DayHeader: View {
    @EnvironmentObject private var store: HealthStore
    @Environment(\.wideLayout) private var wide
    @Environment(\.statusBand) private var statusBand
    private var statusAcrossTop: Bool { statusBand > 0 }
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
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Format.dayTitle(store.selectedDate)). Show calendar")
            }

            Spacer()

            // what's on screen is what the app already had; this says newer data is on its way
            if store.isSyncing {
                // just the spinner when a long date and the buttons leave no room for the word
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Syncing").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    ProgressView().controlSize(.mini).padding(.horizontal, 8)
                }
                .foregroundStyle(Theme.secondary)
                .frame(height: 26)
                .background(Theme.card, in: Capsule())
                .accessibilityLabel("Syncing")
                .transition(.opacity)
            }
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
        .padding(.leading, wide ? 28 : 20)
        .padding(.trailing, (wide ? 28 : 20) + (statusAcrossTop ? 48 : 0))
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
                    .foregroundStyle(Theme.text)
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
                        .font(.system(size: 11, weight: .medium))
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
                    Circle().fill(Theme.ink.opacity(0.18)).frame(width: 5, height: 5)
                    Circle().fill(Theme.ink.opacity(0.6)).frame(width: 5, height: 5)
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                }
                Text("Recovery · Effort · Sleep. Darker is closer; accent is target met.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            // the one place on Today a pull can't open anything new, so it syncs
            if store.source.isConnected || Distribution.isScreenshots {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                    if store.isSyncing {
                        Text("Syncing…")
                    } else if let d = store.lastSync {
                        Text("Pull down to refresh · updated \(d.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Pull down to refresh")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity)
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
    /// A score this high counts as the day's target met.
    static let targetMet = 0.85
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
                                // days to come and days without data stay readable, just quieter
                                .foregroundStyle(isSelected ? Theme.background : (hasData ? Theme.text : Theme.text.opacity(isFuture ? 0.45 : 0.55)))
                                .frame(width: 34, height: 34)
                                .background {
                                    if isSelected { Circle().fill(Theme.ink) }
                                    else if isToday { Circle().stroke(Theme.accent, lineWidth: 1.5) }
                                }
                            // Recovery, Effort, Sleep: light grey far from target, darker as it gets
                            // closer, and the accent once the target's met
                            HStack(spacing: 3) {
                                ForEach(ScoreKind.allCases) { k in
                                    let v = min(1, max(0, k.value(in: scores) ?? 0))
                                    Circle()
                                        .fill(!hasData ? Color.clear : (v >= Self.targetMet ? Theme.accent : Theme.ink.opacity(0.12 + 0.6 * v)))
                                        .frame(width: 5, height: 5)
                                }
                            }
                        }
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isFuture || !hasData)

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

/// The little arrow that turns as you pull, and says when letting go will sync.
struct PullToRefreshHint: View {
    @EnvironmentObject private var store: HealthStore
    let pull: CGFloat
    static let threshold: CGFloat = 70

    var body: some View {
        let threshold = Self.threshold
        let progress = min(1, pull / threshold)
        let ready = pull > threshold
        HStack(spacing: 6) {
            if store.isSyncing {
                ProgressView().controlSize(.mini)
                Text("Syncing")
            } else {
                Image(systemName: "arrow.down")
                    .rotationEffect(.degrees(ready ? 180 : 0))
                    .animation(.snappy(duration: 0.2), value: ready)
                Text(ready ? "Release to refresh" : "Pull to refresh")
                    .contentTransition(.opacity)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(ready ? Theme.text : Theme.secondary)
        .opacity(pull < 12 ? 0 : Double(progress))
        .frame(maxWidth: .infinity)
        .frame(height: max(0, pull))
        .clipped()
        .sensoryFeedback(.impact(weight: .medium), trigger: ready) { old, new in new && !old }
    }
}
