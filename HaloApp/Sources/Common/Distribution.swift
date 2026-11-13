import Foundation

/// Where this copy of Halo came from. The same build goes to TestFlight and the App Store, so it's
/// worked out at run time: a TestFlight install carries a sandbox receipt, an App Store one doesn't.
enum Distribution {
    static let isTestFlight: Bool = {
        #if DEBUG || targetEnvironment(simulator)
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()
}
