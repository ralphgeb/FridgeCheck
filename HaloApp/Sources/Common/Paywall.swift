import SwiftUI

/// Halo Plus. Without it, today's scores, key numbers and balance are free; earlier days, the
/// cards under Balance, cardio load, your own colors and app icons are locked. Buying goes through
/// the App Store once the subscription is set up there, and through a test checkout (Face ID,
/// nothing charged) until then; see PlusPurchase. Settings can turn the paywall off altogether.
enum Plus {
    static let key = "plus.active"
    static let sinceKey = "plus.since"
    /// Plus came from the App Store (managed there), not the test checkout.
    static let storeKey = "plus.store"

    static var isActive: Bool { UserDefaults.standard.bool(forKey: key) }
    static var fromStore: Bool { UserDefaults.standard.bool(forKey: storeKey) }
    /// True when Plus things are locked right now.
    static var locked: Bool { !isActive }

    /// "£0.99" in the UK, "$0.99" elsewhere.
    static var price: String {
        Locale.current.currency?.identifier == "GBP" ? "£0.99" : "$0.99"
    }
}

/// A locked card: the card itself still shows, lightly softened, so you can see what it holds,
/// with a Halo Plus badge over it (or, with `message`, a short line and an Unlock button). Tapping
/// anywhere on it opens Halo Plus.
struct PlusLocked: ViewModifier {
    var enabled = true
    var message: String? = nil
    var reason: String? = nil
    /// No badge (a second locked part next to one that already has it).
    var quiet = false
    @AppStorage(Plus.key) private var hasPlus = false
    @State private var showPlus = false

    func body(content: Content) -> some View {
        let locked = enabled && !hasPlus
        content
            .blur(radius: locked ? 2.2 : 0)
            .saturation(locked ? 0.85 : 1)
            .allowsHitTesting(!locked)
            .overlay {
                if locked {
                    ZStack {
                        LinearGradient(colors: [Theme.background.opacity(0.05), Theme.background.opacity(0.32)],
                                       startPoint: .top, endPoint: .bottom)
                        if let message { PlusCallout(message: message) } else if !quiet { LockBadge() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { showPlus = true }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message ?? "Locked. Part of Halo Plus")
                    .accessibilityHint("Opens Halo Plus")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: locked)
            .sheet(isPresented: $showPlus) { PlusSheet(reason: reason ?? message) }
    }
}

extension View {
    /// Locks the view behind Halo Plus (unless you have it).
    func plusLocked(_ enabled: Bool = true, message: String? = nil, reason: String? = nil, quiet: Bool = false) -> some View {
        modifier(PlusLocked(enabled: enabled, message: message, reason: reason, quiet: quiet))
    }
}

/// The badge on a locked card: a lock and "Halo Plus" on a frosted pill.
struct LockBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold))
            Text("Halo Plus").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// A locked chart's note: what Plus shows here, and a button to get it.
struct PlusCallout: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.background)
                .frame(width: 34, height: 34)
                .background(Theme.accent, in: Circle())
            Text(message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text("Unlock with Halo Plus · \(Plus.price)/month")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Theme.ink, in: Capsule())
                .foregroundStyle(Theme.background)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(24)
    }
}

/// What Halo Plus includes, then the checkout: the App Store's own when the subscription is set
/// up there, else the test checkout (the same steps, Face ID to confirm, nothing charged). Then a
/// welcome.
struct PlusSheet: View {
    /// Why it opened, shown under the title ("Earlier days are part of Halo Plus").
    var reason: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.offer
    @State private var showCheckout = false
    @State private var showPrivacy = false
    @State private var note: String?
    /// The sheet is as tall as what's in it, measured as it draws.
    @State private var height: CGFloat = 430

    enum Step { case offer, paying, done }

    var body: some View {
        VStack(spacing: 14) {
            LogoMark(progress: step == .done ? 1 : 0.8).frame(width: 52, height: 52)
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
        .animation(.smooth(duration: 0.25), value: note)
        .sensoryFeedback(.success, trigger: step == .done)
        .interactiveDismissDisabled(step == .paying)
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                PrivacyPolicyView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPrivacy = false } } }
            }
        }
        .sheet(isPresented: $showCheckout) {
            TestCheckoutSheet { bought in
                if bought { welcomeThenClose(fromStore: false) } else { step = .offer }
            }
        }
    }

    private var offer: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Halo Plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                Text(reason ?? "Every day, every card, made yours.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                perk("Every earlier day, and graphs by day, month and six months")
                perk("Heart zones, cardio load, trends and calories")
                perk("Your sleep bank, sleep numbers and schedule")
                perk("Your own colors, color sets and app icons")
            }
            .padding(.horizontal, 8)
            VStack(spacing: 8) {
                Button(action: subscribe) {
                    ZStack {
                        if step == .paying {
                            ProgressView().tint(Theme.background)
                        } else {
                            Text("Subscribe · \(Plus.price) a month").font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(Theme.background)
                }
                .buttonStyle(.plain)
                .disabled(step == .paying)
                if let note {
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
                Text("\(Plus.price) a month, renews automatically until cancelled. Cancel any time in Settings › Apple Account › Subscriptions.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                // what Apple asks every subscription to show: restore, terms of use and privacy
                HStack(spacing: 16) {
                    Button("Restore Purchases") { restore() }
                        .disabled(step == .paying)
                    Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    Button("Privacy") { showPrivacy = true }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
        }
    }

    /// The App Store's sheet when the subscription is there, else the test checkout.
    private func subscribe() {
        note = nil
        step = .paying
        Task {
            guard let product = await PlusPurchase.product() else {
                showCheckout = true
                return
            }
            switch await PlusPurchase.buy(product) {
            case .bought: welcomeThenClose(fromStore: true)
            case .cancelled: step = .offer
            case .pending:
                step = .offer
                note = "Waiting for approval. Plus turns on as soon as it\u{2019}s approved."
            case .failed(let why):
                step = .offer
                note = why
            }
        }
    }

    private func restore() {
        note = nil
        step = .paying
        Task {
            if await PlusPurchase.restore() {
                welcomeThenClose(fromStore: Plus.fromStore)
            } else {
                step = .offer
                note = "No Halo Plus purchase found for this Apple Account."
            }
        }
    }

    private func welcomeThenClose(fromStore: Bool) {
        if !Plus.isActive { PlusPurchase.activate(fromStore: fromStore) }
        step = .done
        Task {
            try? await Task.sleep(for: .milliseconds(1800))
            dismiss()
        }
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.bounce, value: step == .done)
            Text("Welcome to Halo Plus").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Everything is unlocked.").font(.system(size: 15)).foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 20)
    }

    private func perk(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: 18).padding(.top, 2)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.text)
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
        ["Ocean", "Sky", "Blush", "Forest", "Mono", "Light"].map { Icon(name: $0, alternate: "AppIcon-\($0)") }
}
