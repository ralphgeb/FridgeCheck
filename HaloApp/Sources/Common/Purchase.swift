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

/// The test checkout, laid out like the App Store's subscription sheet: what you're buying, the
/// price and renewal terms, the account, then Face ID to confirm and a Done tick. Nothing is charged.
struct TestCheckoutSheet: View {
    /// Called once: true when bought, false when cancelled.
    var onFinish: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var stage = Stage.ready
    @State private var finished = false
    private let biometry = PlusPurchase.biometry

    enum Stage { case ready, confirming, done }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Subscription").font(.system(size: 17, weight: .semibold))
                Text("TEST")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.orange)
                Spacer()
                Button { finish(false) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(stage != .ready)
                .accessibilityLabel("Cancel")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    LogoMark(progress: 0.8)
                        .padding(10)
                        .frame(width: 60, height: 60)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Halo Plus").font(.system(size: 17, weight: .semibold))
                        Text("Halo").font(.system(size: 14)).foregroundStyle(.secondary)
                        Text("Subscription").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                divider
                row("Price", "\(Plus.price) per month")
                divider
                Text("Starts today and renews each month until you cancel it in Settings. Test purchase: nothing is charged.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                divider
                row("Account", "Test account")
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)

            confirmArea
                .frame(height: 110)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .foregroundStyle(Color.primary)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .presentationDetents([.height(470)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(stage != .ready)
        .animation(.smooth(duration: 0.3), value: stage)
        .sensoryFeedback(.success, trigger: stage == .done)
        .onDisappear { if !finished { finished = true; onFinish(false) } }
    }

    @ViewBuilder
    private var confirmArea: some View {
        switch stage {
        case .ready:
            VStack(spacing: 10) {
                Button(action: confirm) {
                    HStack(spacing: 8) {
                        Image(systemName: biometry.symbol).font(.system(size: 18, weight: .medium))
                        Text(biometry == .passcode ? "Subscribe" : "Subscribe with \(biometry.name)")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Text("You\u{2019}ll be asked to confirm with \(biometry.name).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .transition(.opacity)
        case .confirming:
            VStack(spacing: 10) {
                Image(systemName: biometry.symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.blue)
                    .symbolEffect(.pulse, isActive: true)
                Text("Confirming\u{2026}").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        case .done:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.blue)
                    .symbolEffect(.bounce, value: stage == .done)
                Text("Done").font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private var divider: some View {
        Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 16)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 15)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 15, weight: .medium))
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private func confirm() {
        stage = .confirming
        Task {
            // a beat for the sheet to settle, as the App Store does before Face ID
            try? await Task.sleep(for: .milliseconds(350))
            guard await PlusPurchase.confirmOwner() else {
                stage = .ready
                return
            }
            // the "store" answering
            try? await Task.sleep(for: .milliseconds(900))
            stage = .done
            try? await Task.sleep(for: .milliseconds(1100))
            finish(true)
        }
    }

    private func finish(_ bought: Bool) {
        guard !finished else { return }
        finished = true
        onFinish(bought)
        dismiss()
    }
}
