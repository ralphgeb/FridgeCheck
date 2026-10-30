import SwiftUI

/// Halo Plus. Without it, today's scores, key numbers and balance are free; earlier days, the
/// cards under Balance, cardio load, your own colors and app icons are locked. The purchase is a
/// test for now: nothing is charged. Settings can turn the paywall off altogether while testing.
enum Plus {
    static let key = "plus.active"
    static let sinceKey = "plus.since"
    /// Settings › Testing: show the paywall at all (off by default; turn on to try it).
    static let paywallKey = "plus.paywall"

    static var isActive: Bool { UserDefaults.standard.bool(forKey: key) }
    static var paywallOn: Bool { UserDefaults.standard.bool(forKey: paywallKey) }
    /// True when Plus things are locked right now.
    static var locked: Bool { paywallOn && !isActive }

    /// "£0.99" in the UK, "$0.99" elsewhere.
    static var price: String {
        Locale.current.currency?.identifier == "GBP" ? "£0.99" : "$0.99"
    }
}

/// A light veil over a whole card, so it still shows through blurred, with one lock in the middle;
/// tapping it opens Halo Plus.
struct PlusLocked: ViewModifier {
    var enabled = true
    @AppStorage(Plus.key) private var hasPlus = false
    @AppStorage(Plus.paywallKey) private var paywall = false
    @State private var showPlus = false

    func body(content: Content) -> some View {
        let locked = enabled && paywall && !hasPlus
        content
            .blur(radius: locked ? 5 : 0)
            .allowsHitTesting(!locked)
            .overlay {
                if locked {
                    ZStack {
                        Theme.background.opacity(0.45)
                        LockBadge()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { showPlus = true }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Locked. Halo Plus")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
                }
            }
            .sheet(isPresented: $showPlus) { PlusSheet() }
    }
}

extension View {
    /// Locks the view behind Halo Plus (when the paywall is on and Plus isn't).
    func plusLocked(_ enabled: Bool = true) -> some View { modifier(PlusLocked(enabled: enabled)) }
}

/// Just the padlock: soft white, with a shadow so it reads on light and dark cards.
struct LockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

/// What Halo Plus includes, and a test checkout: confirm, a moment of processing, then a
/// welcome. Nothing is charged; Settings can end the test subscription.
struct PlusSheet: View {
    /// Why it opened, shown under the title ("Earlier days are part of Halo Plus").
    var reason: String? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Plus.key) private var hasPlus = false
    @AppStorage(Plus.sinceKey) private var since = 0.0
    @State private var step = Step.offer
    /// The sheet is as tall as what's in it, measured as it draws.
    @State private var height: CGFloat = 430

    enum Step { case offer, confirm, paying, done }

    var body: some View {
        VStack(spacing: 14) {
            LogoMark(progress: 0.8).frame(width: 52, height: 52)
            if step == .done {
                welcome.transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                offer.transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: SheetHeightKey.self, value: g.size.height) })
        .onPreferenceChange(SheetHeightKey.self) { h in if h > 0 { height = h } }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .animation(.smooth(duration: 0.35), value: step)
        .sensoryFeedback(.success, trigger: step == .done)
        .interactiveDismissDisabled(step == .paying)
    }

    private var offer: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Halo Plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(reason ?? "Every day, every card, made yours.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                perk("Every earlier day, from the calendar and the graphs")
                perk("Heart zones, trends, cardio load and calories")
                perk("Your own colors, color sets and app icons")
            }
            .padding(.horizontal, 8)
            if step == .offer {
                VStack(spacing: 8) {
                    Button { withAnimation(.smooth) { step = .confirm } } label: {
                        Text("Subscribe · \(Plus.price) a month")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(Theme.background)
                    }
                    .buttonStyle(.plain)
                    Text("Cancel any time. Test purchase: nothing is charged.")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                .padding(.top, 14)
                .transition(.opacity)
            } else {
                confirm.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// The confirm step: what you're buying and the price, then one tap.
    private var confirm: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Halo Plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Monthly · renews automatically").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text("\(Plus.price)/mo").font(Theme.number(17, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            Button {
                step = .paying
                Task {
                    try? await Task.sleep(for: .milliseconds(1400))
                    hasPlus = true
                    since = Date.now.timeIntervalSince1970
                    step = .done
                    try? await Task.sleep(for: .milliseconds(1800))
                    dismiss()
                }
            } label: {
                ZStack {
                    if step == .paying {
                        ProgressView().tint(Theme.background)
                    } else {
                        Text("Confirm").font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(Theme.background)
            }
            .buttonStyle(.plain)
            .disabled(step == .paying)
            Text("Test purchase: you won\u{2019}t be charged.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            Button("Cancel") { withAnimation(.smooth) { step = .offer } }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(height: 32)
                .disabled(step == .paying)
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.bounce, value: step == .done)
            Text("Welcome to Halo Plus").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("Everything is unlocked.").font(.system(size: 15)).foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 20)
    }

    private func perk(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: 18).padding(.top, 2)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
    }
}

private struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Halo's icon in each color set's colors. nil is the main icon.
enum AppIcons {
    struct Icon { let name: String; let alternate: String?; var preview: String { "IconPreview-\(name)" } }
    static let all: [Icon] = [Icon(name: "Original", alternate: nil)] +
        ["Ocean", "Forest", "Mono", "Dusk", "Sand", "Light"].map { Icon(name: $0, alternate: "AppIcon-\($0)") }
}
