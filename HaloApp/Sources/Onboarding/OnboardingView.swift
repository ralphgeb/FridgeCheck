import SwiftUI

/// The first time Halo opens: the logo, then the band you use, a little about you and your
/// targets. Once a band is connected the app starts reading your data behind these screens.
struct OnboardingView: View {
    @EnvironmentObject private var store: HealthStore
    let finish: () -> Void
    @State private var page = 0
    @State private var forward = true

    var body: some View {
        NavigationStack {
            pages
                .toolbar(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
        .tint(Theme.ink)
        .sensoryFeedback(.selection, trigger: page)
    }

    private var pages: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Group {
                switch page {
                case 0: WelcomePage { go(1) }
                case 1: DevicePage { go(2) }
                case 2: YouPage()
                default: HowItWorksPage()
                }
            }
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
        }
        // the setup pages share one quiet bar: back, where you are, next
        .safeAreaInset(edge: .bottom) {
            if page > 0 {
                VStack(spacing: 14) {
                    PrivacyNote()
                    HStack {
                        Button { go(page - 1) } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(Theme.card, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back")
                        Spacer()
                        PageDots(count: 3, current: page - 1)
                        Spacer()
                        PillButton(title: page == 3 ? "Start" : "Next", enabled: page != 1 || store.source.isConnected) {
                            page == 3 ? finish() : go(page + 1)
                        }
                    }
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
    }

    private func go(_ p: Int) {
        forward = p > page
        withAnimation(.snappy(duration: 0.4)) { page = p }
    }
}

// MARK: Pages

/// The logo draws itself: the circle grows, then the ring fills to the mark, with the name below.
private struct WelcomePage: View {
    let next: () -> Void
    @State private var grown = false
    @State private var drawn = 0.0
    @State private var named = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            LogoMark(progress: drawn)
                .frame(width: 118, height: 118)
                .scaleEffect(grown ? 1 : 0.18)
                .opacity(grown ? 1 : 0)
            VStack(spacing: 6) {
                Text("Halo").font(.system(size: 31, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Your health app simplified").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 26)
            .opacity(named ? 1 : 0)
            .offset(y: named ? 0 : 10)
            Spacer()
            PillButton(title: "Get started", action: next)
                .opacity(named ? 1 : 0)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 24)
        .task {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { grown = true }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeInOut(duration: 1.1)) { drawn = 0.8 }
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.5)) { named = true }
        }
    }
}

private struct DevicePage: View {
    @EnvironmentObject private var store: HealthStore
    let skip: () -> Void
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        SetupPage(title: "Connect your device", subtitle: "Pick the band you wear and sign in. Halo only reads.") {
            CompactCard {
                ForEach(Array([DataSource.google, .whoop, .appleHealth].enumerated()), id: \.element) { i, s in
                    if i > 0 { Hairline() }
                    deviceRow(s)
                }
            }
            if let reason = store.source.unavailableReason {
                Text(reason).font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 10)
            }
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.accent).padding(.top, 10)
            }
            if !store.source.isConnected {
                Button("Not now, look around with sample data", action: skip)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
        }
    }

    private func deviceRow(_ s: DataSource) -> some View {
        let selected = store.source == s
        let connected = selected && s.isConnected
        return HStack(spacing: 12) {
            Image(systemName: s.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(selected ? Theme.ink : Theme.track, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .foregroundStyle(selected ? Theme.background : Theme.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.shortTitle).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
                Text(s.devices).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if connected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                    .accessibilityLabel("Connected")
            } else if selected && s.unavailableReason == nil {
                Button {
                    connect(s)
                } label: {
                    Group {
                        if connecting { ProgressView().controlSize(.small) } else { Text("Connect") }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.ink, in: Capsule())
                    .foregroundStyle(Theme.background)
                }
                .buttonStyle(.plain)
                .disabled(connecting)
            } else {
                Circle().strokeBorder(Theme.tertiary, lineWidth: 1.5).frame(width: 18, height: 18)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !selected else { return }
            error = nil
            Task { await store.switchSource(s) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func connect(_ s: DataSource) {
        connecting = true
        error = nil
        Task {
            do {
                try await s.connect()
                // the first read runs while you fill in the next pages
                Task { await store.accountChanged() }
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}

/// About you and your targets, on one page: two small groups with an icon on each row.
private struct YouPage: View {
    @EnvironmentObject private var store: HealthStore
    @AppStorage(WeekStart.key) private var weekStartsOnMonday = WeekStart.startsOnMonday

    var body: some View {
        SetupPage(title: "You and your targets", subtitle: "For your calories and heart-rate zones, and what a good day looks like.") {
            GroupLabel("About you")
            CompactCard {
                CompactRow("Sex", symbol: "person") {
                    MiniSegment(options: Profile.Sex.allCases.map { ($0, $0.title) }, selection: $store.profile.sex)
                }
                Hairline()
                CompactRow("Born", symbol: "calendar") {
                    NumberChip(text: String(store.profile.birthYear), value: Double(store.profile.birthYear),
                               unit: "", range: 1930...2012) { store.profile.birthYear = Int($0) }
                }
                Hairline()
                CompactRow("Height", symbol: "ruler") {
                    NumberChip(text: "\(Int(store.profile.heightCm)) cm", value: store.profile.heightCm,
                               unit: "cm", range: 120...220) { store.profile.heightCm = $0.rounded() }
                }
                Hairline()
                CompactRow("Weight", symbol: "scalemass") {
                    NumberChip(text: String(format: "%.1f kg", store.profile.weightKg), value: store.profile.weightKg,
                               unit: "kg", range: 35...200, decimals: true) { store.profile.weightKg = ($0 * 10).rounded() / 10 }
                }
            }
            GroupLabel("Your targets").padding(.top, 22)
            CompactCard {
                CompactRow("Sleep need", symbol: "moon") {
                    Menu {
                        Picker("Sleep need", selection: $store.targets.sleepNeedHours) {
                            ForEach(Array(stride(from: 6.0, through: 10.0, by: 0.25)), id: \.self) { h in
                                Text(Format.duration(h * 60)).tag(h)
                            }
                        }
                    } label: {
                        MenuLabel(text: Format.duration(store.targets.sleepNeedHours * 60))
                    }
                }
                Hairline()
                CompactRow("Steps", symbol: "figure.walk") {
                    NumberChip(text: Int(store.targets.steps).formatted(), value: store.targets.steps,
                               unit: "", range: 2_000...25_000) { store.targets.steps = ($0 / 100).rounded() * 100 }
                }
                Hairline()
                CompactRow("Active minutes", symbol: "heart") {
                    Menu {
                        Picker("Active minutes", selection: $store.targets.zoneMinutes) {
                            ForEach(Array(stride(from: 10.0, through: 120.0, by: 5.0)), id: \.self) { m in
                                Text("\(Int(m)) a day").tag(m)
                            }
                        }
                    } label: {
                        MenuLabel(text: "\(Int(store.targets.zoneMinutes)) a day")
                    }
                }
                Hairline()
                CompactRow("Cardio focus", symbol: "bolt.heart") {
                    Menu {
                        Picker("Cardio focus", selection: $store.targets.cardioFocus) {
                            ForEach(CardioFocus.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        MenuLabel(text: store.targets.cardioFocus.title)
                    }
                }
                Hairline()
                CompactRow("Week starts", symbol: "calendar.badge.clock") {
                    MiniSegment(options: [(true, "Mon"), (false, "Sun")], selection: $weekStartsOnMonday)
                }
            }
            .onChange(of: weekStartsOnMonday) { _, _ in store.refreshScores() }
            Text("You can change all of these later in Settings.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                .padding(.top, 10).padding(.horizontal, 4)
        }
    }
}

/// The last page: what Halo does, in four short lines.
private struct HowItWorksPage: View {
    private let points: [(symbol: String, title: String, text: String)] = [
        ("dot.radiowaves.left.and.right", "Your data, read directly",
         "Halo reads what your band already measures: sleep, heart rate, HRV and activity. It never writes or shares anything."),
        ("circle.circle", "Three clear scores",
         "Recovery, Effort and Sleep, each measured against your own last 30 days, not against anyone else."),
        ("chart.xyaxis.line", "Only what matters",
         "No AI summaries, no coaching scripts, no filler. Just the numbers and graphs that tell you how you're doing."),
        ("slider.horizontal.3", "Made to fit you",
         "Rearrange or hide cards, set your own targets, and choose the colors. Everything stays on this iPhone."),
    ]

    var body: some View {
        SetupPage(title: "How Halo works", subtitle: "Your health data, without the noise.") {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(points, id: \.title) { p in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: p.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 38, height: 38)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .foregroundStyle(Theme.ink)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(p.text).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: Pieces

/// A setup page: a small title, a line under it, then the content near the top.
private struct SetupPage<Content: View>: View {
    @EnvironmentObject private var store: HealthStore
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    if store.isSyncing {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Reading your data").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.card, in: Capsule())
                        .transition(.opacity)
                    }
                }
                .frame(height: 26)
                .animation(.easeInOut, value: store.isSyncing)
                Text(title).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.ink).padding(.top, 22)
                Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6).padding(.bottom, 22)
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct CompactCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A small label over a group of rows.
private struct GroupLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).haloLabel().padding(.horizontal, 4).padding(.bottom, 8)
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

private struct CompactRow<Trailing: View>: View {
    let title: String
    var symbol: String? = nil
    @ViewBuilder var trailing: Trailing

    init(_ title: String, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(Theme.track, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(Theme.ink)
            }
            Text(title).font(.system(size: 15)).foregroundStyle(Theme.ink)
            Spacer()
            trailing
        }
        .frame(minHeight: 46)
    }
}

/// A value you tap to type a new one: it turns into a field with the keyboard up, and the new
/// value is kept (within its range) when you tap Done or anywhere else.
private struct NumberChip: View {
    let text: String
    let value: Double
    let unit: String
    let range: ClosedRange<Double>
    var decimals = false
    let set: (Double) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                HStack(spacing: 4) {
                    TextField("", text: $draft)
                        .keyboardType(decimals ? .decimalPad : .numberPad)
                        .focused($focused)
                        .multilineTextAlignment(.trailing)
                        .font(Theme.number(15, weight: .medium))
                        .frame(width: 72)
                    if !unit.isEmpty {
                        Text(unit).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                }
            } else {
                Text(text).font(Theme.number(15, weight: .medium))
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(editing ? Theme.card : Theme.track, in: Capsule())
        .overlay(Capsule().strokeBorder(editing ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Capsule())
        .onTapGesture {
            guard !editing else { return }
            draft = decimals ? String(format: "%.1f", value) : String(Int(value))
            editing = true
            focused = true
        }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .onSubmit(commit)
        .accessibilityLabel(text)
        .accessibilityHint("Double-tap to type a new value")
    }

    private func commit() {
        guard editing else { return }
        if let v = Double(draft.replacingOccurrences(of: ",", with: ".")) {
            set(min(range.upperBound, max(range.lowerBound, v)))
        }
        editing = false
    }
}

/// Two or three small choices side by side.
private struct MiniSegment<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let value = options[i].0, title = options[i].1
                Button {
                    withAnimation(.snappy) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(selection == value ? Theme.ink : .clear, in: Capsule())
                        .foregroundStyle(selection == value ? Theme.background : Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.track, in: Capsule())
    }
}

private struct MenuLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 15, weight: .medium))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Theme.secondary)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Theme.ink : Theme.tertiary)
                    .frame(width: i == current ? 16 : 6, height: 6)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// Always above the buttons on the setup pages.
private struct PrivacyNote: View {
    var body: some View {
        // two lines, the lock beside the first
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("All your data is stored on this iPhone.")
                Text("Nothing goes to the cloud.")
            }
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
    }
}

/// A small, quiet capsule with an arrow: the only button on each page.
struct PillButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 20)
            .frame(height: 42)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .animation(.easeInOut, value: enabled)
    }
}

/// Halo's mark, as on the app icon: one thick ring filled to `progress` (0.8 on the icon), the rest
/// in the track grey, with the accent dot at the tip. Animates as `progress` changes.
struct LogoMark: View, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            // the icon's proportions: a 108 px stroke on a 299.5 px radius
            let line = side * 108 / 707
            let r = (side - line) / 2
            let a = Angle.degrees(-90 + 360 * progress).radians
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack {
                Circle().stroke(Theme.track, lineWidth: line).frame(width: 2 * r, height: 2 * r)
                Circle()
                    .trim(from: 0, to: max(0.0001, progress))
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 2 * r, height: 2 * r)
                    .opacity(progress > 0.001 ? 1 : 0)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: line * 0.56, height: line * 0.56)
                    .position(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}
