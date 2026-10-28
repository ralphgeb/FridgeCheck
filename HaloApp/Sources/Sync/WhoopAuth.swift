import AuthenticationServices
import Foundation
import UIKit

/// Signs in to Whoop and keeps a fresh access token for the Whoop API.
///
/// Whoop needs the app's client secret to hand out tokens, so sign-in goes through Halo's own
/// small service (HaloApp/whoop-worker, a Cloudflare Worker) which holds the secret and stores
/// nothing. Its address goes in project.yml (WHOOP_AUTH_URL).
@MainActor
final class WhoopAuth: ObservableObject {
    static let shared = WhoopAuth()

    @Published private(set) var isConnected = false

    private static let account = "whoop.tokens"
    private var session: ASWebAuthenticationSession?
    private var anchor: AnchorProvider?
    private var tokens: GoogleAuth.Tokens?

    enum AuthError: LocalizedError {
        case notConfigured, cancelled, noCode(String?), tokenExchange(String), notConnected

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Whoop sign-in isn't set up yet."
            case .cancelled: return "Sign-in was cancelled."
            case .noCode(let reason): return "Whoop didn't return a sign-in code\(reason.map { ": \($0)" } ?? ".")"
            case .tokenExchange(let m): return "Whoop sign-in failed: \(m)"
            case .notConnected: return "Connect your Whoop account in Settings."
            }
        }
    }

    private init() {
        if let data = Keychain.load(account: Self.account),
           let t = try? JSONDecoder().decode(GoogleAuth.Tokens.self, from: data) {
            tokens = t
            isConnected = t.refreshToken != nil
        }
    }

    /// Halo's sign-in service (from Info.plist, filled in by project.yml).
    var service: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "WhoopAuthURL") as? String)
            .flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil }
    }
    var isConfigured: Bool { service != nil }

    // MARK: Sign in / out

    func connect() async throws {
        guard let service else { throw AuthError.notConfigured }
        let state = UUID().uuidString
        var comps = URLComponents(url: service.appendingPathComponent("login"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "state", value: state)]
        guard let url = comps.url else { throw AuthError.notConfigured }

        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
        let anchor = AnchorProvider(window: window)
        self.anchor = anchor
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "halo") { url, error in
                if let url {
                    cont.resume(returning: url)
                } else if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(throwing: AuthError.cancelled)
                }
            }
            s.presentationContextProvider = anchor
            session = s
            s.start()
        }
        session = nil
        self.anchor = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard item("state") == state, let code = item("code") else {
            throw AuthError.noCode(item("error_description") ?? item("error"))
        }
        try await exchange(["code": code])
        isConnected = true
    }

    func disconnect() {
        tokens = nil
        Keychain.delete(account: Self.account)
        isConnected = false
        WhoopLedger.clear()
    }

    /// A valid access token, refreshed when it has less than a minute left. Whoop retires a refresh
    /// token once it's used, so the sync's parallel requests share one refresh instead of racing.
    func accessToken() async throws -> String {
        if let refreshing { try await refreshing.value }
        guard let t = tokens else { throw AuthError.notConnected }
        if t.expiry.timeIntervalSinceNow > 60 { return t.accessToken }
        guard let refresh = t.refreshToken else { throw AuthError.notConnected }
        let task = Task { try await exchange(["refresh_token": refresh]) }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
        guard let fresh = tokens?.accessToken else { throw AuthError.notConnected }
        return fresh
    }
    private var refreshing: Task<Void, Error>?

    // MARK: Token exchange, through Halo's service

    private func exchange(_ body: [String: String]) async throws {
        guard let service else { throw AuthError.notConfigured }
        var req = URLRequest(url: service.appendingPathComponent("token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            let message = json["error_description"] as? String ?? json["error"] as? String ?? "unknown error"
            if json["error"] as? String == "invalid_grant" { disconnect() }   // refresh token revoked or expired
            throw AuthError.tokenExchange(message)
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        // Whoop hands out a new refresh token each time and retires the old one.
        let t = GoogleAuth.Tokens(accessToken: access,
                                  refreshToken: json["refresh_token"] as? String ?? tokens?.refreshToken,
                                  expiry: Date().addingTimeInterval(expiresIn))
        tokens = t
        if let data = try? JSONEncoder().encode(t) { Keychain.save(data, account: Self.account) }
    }
}
