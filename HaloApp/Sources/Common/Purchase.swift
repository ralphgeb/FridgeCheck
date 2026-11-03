import LocalAuthentication
import StoreKit
import SwiftUI

/// Buying Halo Plus.
///
/// Once the subscription exists in App Store Connect (product `com.ralphgeb.halo.plus.monthly`),
/// Subscribe goes through the App Store: Apple's own sheet and Face ID, and in TestFlight Apple's
/// sandbox, so nothing is charged. Until then Halo shows a test checkout that works the same way
/// (the sheet, the price, Face ID or your passcode to confirm, Done) and charges nothing.
enum PlusPurchase {
    static let productID = "com.ralphgeb.halo.plus.monthly"

    enum Outcome: Equatable { case bought, cancelled, pending, failed(String) }

    /// The App Store's subscription, when it's set up.
    static func product() async -> Product? {
        try? await Product.products(for: [productID]).first
    }

    /// Buys through the App Store (its own sheet and Face ID).
    static func buy(_ product: Product) async -> Outcome {
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    return .failed("The App Store couldn\u{2019}t confirm the purchase.")
                }
                await transaction.finish()
                activate(fromStore: true)
                return .bought
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .cancelled
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func activate(fromStore: Bool) {
        let d = UserDefaults.standard
        d.set(Date.now.timeIntervalSince1970, forKey: Plus.sinceKey)
        d.set(fromStore, forKey: Plus.storeKey)
        d.set(true, forKey: Plus.key)
    }

    /// Checks what the App Store says you own: an App Store subscription that ended (or was
    /// refunded) ends Plus; a test one is left alone.
    static func refresh() async {
        var owned = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == productID, t.revocationDate == nil { owned = true }
        }
        let d = UserDefaults.standard
        if owned {
            if !d.bool(forKey: Plus.key) || !d.bool(forKey: Plus.storeKey) { activate(fromStore: true) }
        } else if d.bool(forKey: Plus.storeKey) {
            d.set(false, forKey: Plus.storeKey)
            d.set(false, forKey: Plus.key)
        }
    }

    /// Renewals, refunds and purchases made elsewhere (another device, Ask to Buy) while Halo runs.
    static func listen() async {
        for await result in StoreKit.Transaction.updates {
            if case .verified(let t) = result { await t.finish() }
            await refresh()
        }
    }

    /// Restore purchases: asks the App Store again (it may ask you to sign in).
    static func restore() async -> Bool {
        try? await AppStore.sync()
        await refresh()
        return Plus.isActive
    }

    // MARK: Confirming it's you

    enum Biometry {
        case faceID, touchID, opticID, passcode

        var name: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .opticID: return "Optic ID"
            case .passcode: return "Passcode"
            }
        }

        var symbol: String {
            switch self {
            case .faceID: return "faceid"
            case .touchID: return "touchid"
            case .opticID: return "opticid"
            case .passcode: return "lock.fill"
            }
        }
    }

    static var biometry: Biometry {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .passcode }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

    /// Face ID (or Touch ID, or the passcode when those fail), as the App Store asks before a
    /// purchase. A phone with no passcode at all is confirmed by the tap itself.
    static func confirmOwner() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: "Subscribe to Halo Plus for \(Plus.price) a month")
        } catch {
            return false
        }
    }
}

/// The checkout used until the subscription is in App Store Connect. It follows Apple's purchase
/// sheet step by step, in the system's own colors and type: App Store at the top, the app's icon,
/// the subscription and its terms, the account, a blue Subscribe button, then Face ID (the real
/// system prompt), Done, and "You're all set". It says Test where Apple's says Sandbox, and
/// nothing is charged.
struct TestCheckoutSheet: View {
    /// Called once: true when bought, false when cancelled.
    var onFinish: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var stage = Stage.ready
    @State private var finished = false
    @State private var allSet = false
    private let biometry = PlusPurchase.biometry

    enum Stage { case ready, authenticating, purchasing, done }

    /// The icon you're using (Settings › App icon), as on the Home Screen.
    private var iconName: String {
        let alternate = UIApplication.shared.alternateIconName?.replacingOccurrences(of: "AppIcon-", with: "")
        return "IconPreview-\(alternate ?? "Original")"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("App Store").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Cancel") { finish(false) }
                    .font(.system(size: 17))
                    .disabled(stage != .ready)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)

            Divider()

            HStack(alignment: .top, spacing: 14) {
                Image(iconName)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14.5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14.5, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Halo Plus").font(.system(size: 17, weight: .semibold))
                    Text("Halo").font(.system(size: 15)).foregroundStyle(.secondary)
                    Text("Subscription").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().padding(.leading, 20)

            VStack(alignment: .leading, spacing: 6) {
                Text("Starts today. \(Plus.price)/month.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Renews automatically every month until cancelled. Cancel at least a day before each renewal date in Settings › Apple Account › Subscriptions.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().padding(.leading, 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Account:").foregroundStyle(.secondary)
                    Text("Test account")
                }
                .font(.system(size: 15))
                Text("[Environment: Test]").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Spacer(minLength: 8)

            button
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .presentationDetents([.height(468)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(38)
        .interactiveDismissDisabled(stage != .ready)
        .animation(.smooth(duration: 0.25), value: stage)
        .sensoryFeedback(.success, trigger: stage == .done)
        .alert("You\u{2019}re all set.", isPresented: $allSet) {
            Button("OK") { finish(true) }
        } message: {
            Text("Your purchase was successful.\n[Environment: Test]")
        }
        .onDisappear { if !finished { finished = true; onFinish(false) } }
    }

    /// Subscribe, then what the App Store shows while it checks it's you and charges, then Done.
    @ViewBuilder
    private var button: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(stage == .done ? Color(uiColor: .secondarySystemFill) : Color.blue)
            switch stage {
            case .ready:
                Text("Subscribe").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            case .authenticating:
                HStack(spacing: 8) {
                    Image(systemName: biometry.symbol).font(.system(size: 18))
                    Text(biometry == .passcode ? "Confirming" : biometry.name).font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
            case .purchasing:
                ProgressView().tint(.white)
            case .done:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                    Text("Done").font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Color.blue)
            }
        }
        .frame(height: 50)
        .contentShape(Rectangle())
        .onTapGesture { if stage == .ready { subscribe() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func subscribe() {
        stage = .authenticating
        Task {
            guard await PlusPurchase.confirmOwner() else {
                stage = .ready
                return
            }
            stage = .purchasing
            try? await Task.sleep(for: .milliseconds(1200))
            stage = .done
            try? await Task.sleep(for: .milliseconds(700))
            allSet = true
        }
    }

    private func finish(_ bought: Bool) {
        guard !finished else { return }
        finished = true
        onFinish(bought)
        dismiss()
    }
}

/// Halo's privacy policy, linked from the Halo Plus sheet (as the App Store asks of subscriptions).
struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Halo is a personal health tracker for iPhone. It reads your health data from the source you connect (Fitbit through Google Health, Apple Health, or Whoop) with read-only access, and works out its scores on your iPhone.")
                section("What Halo reads", "Sleep, heart rate, heart rate variability, recovery, workouts, activity, vitals and weight, as allowed by the permissions you grant.")
                section("Where it goes", "Your health data stays on your iPhone. Halo has no servers that store it, no accounts, no analytics and no advertising, and never sells or shares your data.")
                section("Sign-in", "For Whoop, sign-in passes through a small service that swaps a sign-in code for an access token and stores nothing. Tokens are kept in your iPhone\u{2019}s Keychain.")
                section("Halo Plus", "Subscriptions are bought and managed by Apple through the App Store. Halo only learns whether your subscription is active.")
                section("Removing access", "Disconnect in Halo\u{2019}s Settings, revoke access in Google, Apple Health or Whoop, or delete the app to remove everything it stored.")
                section("Contact", "ralph.gebara@gmail.com")
            }
            .font(.system(size: 15))
            .padding(20)
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text).foregroundStyle(.secondary)
        }
    }
}
