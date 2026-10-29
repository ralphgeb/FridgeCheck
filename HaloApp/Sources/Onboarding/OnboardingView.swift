import SwiftUI

/// The first time Halo opens: the logo, then the band you use, a little about you and your
/// targets. Once a band is connected the app starts reading your data behind these screens.
struct OnboardingView: View {
    @EnvironmentObject private var store: HealthStore
    let finish: () -> Void
    @State private var page = 0
    @State private var forward = true

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Group {
                switch page {
                case 0: WelcomePage { go(1) }
                case 1: DevicePage { go(2) }
                case 2: AboutYouPage()
                default: TargetsPage()
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
        .tint(Theme.ink)
        .sensoryFeedback(.selection, trigger: page)
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

private struct AboutYouPage: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        SetupPage(title: "A little about you", subtitle: "For your calories and heart-rate zones.") {
            CompactCard {
                CompactRow("Sex") {
                    MiniSegment(options: Profile.Sex.allCases.map { ($0, $0.title) }, selection: $store.profile.sex)
                }
                Hairline()
                CompactRow("Born") {
                    MiniStepper(text: String(store.profile.birthYear),
                                minus: { store.profile.birthYear = max(1930, store.profile.birthYear - 1) },
                                plus: { store.profile.birthYear = min(2012, store.profile.birthYear + 1) })
                }
                Hairline()
                CompactRow("Height") {
                    MiniStepper(text: "\(Int(store.profile.heightCm)) cm",
                                minus: { store.profile.heightCm = max(120, store.profile.heightCm - 1) },
                                plus: { store.profile.heightCm = min(220, store.profile.heightCm + 1) })
                }
                Hairline()
                CompactRow("Weight") {
                    MiniStepper(text: String(format: "%.1f kg", store.profile.weightKg),
                                minus: { store.profile.weightKg = max(35, store.profile.weightKg - 0.5) },
                                plus: { store.profile.weightKg = min(200, store.profile.weightKg + 0.5) })
                }
            }
        }
    }
}

private struct TargetsPage: View {
    @EnvironmentObject private var store: HealthStore
    @AppStorage(WeekStart.key) private var weekStartsOnMonday = WeekStart.startsOnMonday

    var body: some View {
        SetupPage(title: "Your targets", subtitle: "What a good day looks like. Change them any time in Settings.") {
            CompactCard {
                CompactRow("Sleep") {
                    MiniStepper(text: Format.duration(store.targets.sleepNeedHours * 60),
                                minus: { store.targets.sleepNeedHours = max(6, store.targets.sleepNeedHours - 0.25) },
                                plus: { store.targets.sleepNeedHours = min(10, store.targets.sleepNeedHours + 0.25) })
                }
                Hairline()
                CompactRow("Steps") {
                    MiniStepper(text: Int(store.targets.steps).formatted(),
                                minus: { store.targets.steps = max(2_000, store.targets.steps - 500) },
                                plus: { store.targets.steps = min(25_000, store.targets.steps + 500) })
                }
                Hairline()
                CompactRow("Zone minutes") {
                    MiniStepper(text: "\(Int(store.targets.zoneMinutes)) a day",
                                minus: { store.targets.zoneMinutes = max(10, store.targets.zoneMinutes - 5) },
                                plus: { store.targets.zoneMinutes = min(120, store.targets.zoneMinutes + 5) })
                }
                Hairline()
                CompactRow("Cardio focus") {
                    Menu {
                        Picker("Cardio focus", selection: $store.targets.cardioFocus) {
                            ForEach(CardioFocus.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        MenuLabel(text: store.targets.cardioFocus.title)
                    }
                }
                Hairline()
                CompactRow("Week starts") {
                    MiniSegment(options: [(true, "Mon"), (false, "Sun")], selection: $weekStartsOnMonday)
                }
            }
            .onChange(of: weekStartsOnMonday) { _, _ in store.refreshScores() }
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

private struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

private struct CompactRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(Theme.ink)
            Spacer()
            trailing
        }
        .frame(minHeight: 46)
    }
}

/// − value +, small and quiet.
private struct MiniStepper: View {
    let text: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            round("minus", minus)
            Text(text)
                .font(Theme.number(15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 64)
                .contentTransition(.numericText())
            round("plus", plus)
        }
    }

    private func round(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Theme.track, in: Circle())
                .foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
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
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            Text("All your data is stored on this iPhone. Nothing goes to the cloud.")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Theme.accent)
        .multilineTextAlignment(.center)
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
