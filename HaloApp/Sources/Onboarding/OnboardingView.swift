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
                case 1: DevicePage(back: { go(0) }) { go(2) }
                case 2: AboutYouPage(back: { go(1) }) { go(3) }
                default: TargetsPage(back: { go(2) }) { finish() }
                }
            }
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
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
                .frame(width: 168, height: 168)
                .scaleEffect(grown ? 1 : 0.18)
                .opacity(grown ? 1 : 0)
            VStack(spacing: 8) {
                Text("Halo").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Your health simplified").font(.system(size: 18)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 36)
            .opacity(named ? 1 : 0)
            .offset(y: named ? 0 : 12)
            Spacer()
            OnboardingButton(title: "Get started", action: next)
                .opacity(named ? 1 : 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
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
    let back: () -> Void
    let next: () -> Void
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        OnboardingPage(title: "Connect your device",
                       subtitle: "Halo reads your data from the app your band already uses. Pick yours and sign in.",
                       back: back) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach([DataSource.google, .whoop, .appleHealth]) { s in
                        DeviceTile(source: s, selected: store.source == s, connected: store.source == s && s.isConnected) {
                            error = nil
                            Task { await store.switchSource(s) }
                        }
                    }
                    if let reason = store.source.unavailableReason {
                        Text(reason).font(.system(size: 14)).foregroundStyle(Theme.secondary).padding(.top, 6)
                    } else if !store.source.isConnected {
                        Button {
                            connecting = true
                            error = nil
                            Task {
                                do {
                                    try await store.source.connect()
                                    // the first read runs while you fill in the next pages
                                    Task { await store.accountChanged() }
                                } catch {
                                    self.error = error.localizedDescription
                                }
                                connecting = false
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if connecting { ProgressView() }
                                Text(store.source.connectTitle).font(.system(size: 16, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Theme.track, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(Theme.ink)
                        }
                        .buttonStyle(.plain)
                        .disabled(connecting)
                        .padding(.top, 6)
                    }
                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Theme.accent)
                    }
                }
            }
            .scrollIndicators(.hidden)
        } footer: {
            OnboardingButton(title: "Next", enabled: store.source.isConnected, action: next)
            Button("Not now, look around with sample data", action: next)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .opacity(store.source.isConnected ? 0 : 1)
                .disabled(store.source.isConnected)
        }
    }
}

private struct AboutYouPage: View {
    let back: () -> Void
    let next: () -> Void

    var body: some View {
        OnboardingPage(title: "A little about you",
                       subtitle: "For your calories and heart-rate zones: your maximum heart rate comes from your age.",
                       back: back) {
            OnboardingForm { AboutYouFields() }
        } footer: {
            OnboardingButton(title: "Next", action: next)
        }
    }
}

private struct TargetsPage: View {
    let back: () -> Void
    let done: () -> Void

    var body: some View {
        OnboardingPage(title: "Your targets",
                       subtitle: "What a good day looks like for you. You can change these any time in Settings.",
                       back: back) {
            OnboardingForm { TargetsFields() }
        } footer: {
            OnboardingButton(title: "Start using Halo", action: done)
        }
    }
}

// MARK: Pieces

/// A page with a title, its content, the privacy note and the buttons at the bottom.
private struct OnboardingPage<Content: View, Footer: View>: View {
    @EnvironmentObject private var store: HealthStore
    let title: String
    let subtitle: String
    let back: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Theme.card, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
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
            .foregroundStyle(Theme.ink)
            .animation(.easeInOut, value: store.isSyncing)
            Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.ink).padding(.top, 18)
            Text(subtitle).font(.system(size: 16)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8).padding(.bottom, 18)
            content
            Spacer(minLength: 12)
            PrivacyNote().padding(.bottom, 14)
            VStack(spacing: 12) { footer }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }
}

/// Settings-style rows on the welcome pages.
private struct OnboardingForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Section { content }.listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
        .frame(maxHeight: 380)
    }
}

/// Always on the setup pages.
private struct PrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 12)).padding(.top, 2)
            Text("All your data is stored on this iPhone. Nothing goes to the cloud.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct DeviceTile: View {
    let source: DataSource
    let selected: Bool
    let connected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 14) {
                Image(systemName: source.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(selected ? Theme.ink : Theme.track, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .foregroundStyle(selected ? Theme.background : Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.shortTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(source.devices).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if connected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                        .accessibilityLabel("Connected")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? Theme.ink : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct OnboardingButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(Theme.background)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
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
