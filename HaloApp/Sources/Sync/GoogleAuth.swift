import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Signs in to Google (which now owns Fitbit data) with OAuth 2.0 + PKCE,
/// and keeps a fresh access token for the Google Health API.
///
/// Setup: Google Cloud console > enable "Google Health API" > OAuth consent screen
/// (add yourself as a test user) > Credentials > OAuth client ID of type iOS with
/// bundle ID com.ralphgeb.halo. Put the client ID in project.yml.
@MainActor
final class GoogleAuth: ObservableObject {
    static let shared = GoogleAuth()

    @Published private(set) var isConnected = false

    static let scopes = [
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
    ]

    private static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let account = "tokens"

    private var session: ASWebAuthenticationSession?
    private var anchor: AnchorProvider?
    private var tokens: Tokens?

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiry: Date
    }

    enum AuthError: LocalizedError {
        case notConfigured, cancelled, noCode, tokenExchange(String), notConnected

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Add your Google iOS client ID in project.yml first."
            case .cancelled: return "Sign-in was cancelled."
            case .noCode: return "Google didn't return a sign-in code."
            case .tokenExchange(let m): return "Google sign-in failed: \(m)"
            case .notConnected: return "Connect your Fitbit account in Settings."
            }
        }
    }

    private init() {
        if let data = Keychain.load(account: Self.account),
           let t = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = t
            isConnected = t.refreshToken != nil
        }
    }

    // MARK: Configuration (from Info.plist, filled in by project.yml)

    var clientID: String { Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? "" }
    var isConfigured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") && !clientID.hasPrefix("REPLACE_ME") }
    private var callbackScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    private var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    // MARK: Sign in / out

    func connect() async throws {
        guard isConfigured else { throw AuthError.notConfigured }
        let verifier = Self.randomURLSafe(64)
        let state = Self.randomURLSafe(24)
        var comps = URLComponents(url: Self.authURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "consent"),
        ]
        guard let url = comps.url else { throw AuthError.notConfigured }

        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
        let anchor = AnchorProvider(window: window)
        self.anchor = anchor
        let scheme = callbackScheme
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
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
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.noCode }

        try await exchange([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        isConnected = true
    }

    func disconnect() {
        if let token = tokens?.refreshToken ?? tokens?.accessToken,
           let url = URL(string: "https://oauth2.googleapis.com/revoke?token=\(token)") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            let request = req
            Task.detached { _ = try? await URLSession.shared.data(for: request) }
        }
        tokens = nil
        Keychain.delete(account: Self.account)
        isConnected = false
    }

    /// A valid access token, refreshed when it has less than a minute left.
    func accessToken() async throws -> String {
        guard let t = tokens else { throw AuthError.notConnected }
        if t.expiry.timeIntervalSinceNow > 60 { return t.accessToken }
        guard let refresh = t.refreshToken else { throw AuthError.notConnected }
        try await exchange([
            "client_id": clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        guard let fresh = tokens?.accessToken else { throw AuthError.notConnected }
        return fresh
    }

    // MARK: Token endpoint

    private func exchange(_ form: [String: String]) async throws {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            let message = json["error_description"] as? String ?? json["error"] as? String ?? "unknown error"
            if json["error"] as? String == "invalid_grant" { disconnect() }   // refresh token revoked or expired
            throw AuthError.tokenExchange(message)
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let t = Tokens(accessToken: access,
                       refreshToken: json["refresh_token"] as? String ?? tokens?.refreshToken,
                       expiry: Date().addingTimeInterval(expiresIn))
        tokens = t
        if let data = try? JSONEncoder().encode(t) { Keychain.save(data, account: Self.account) }
    }

    // MARK: PKCE

    private static func randomURLSafe(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(rng.next() % UInt64(chars.count))] })
    }

    private static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tells the sign-in sheet which window to appear over.
final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) { self.window = window }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}
