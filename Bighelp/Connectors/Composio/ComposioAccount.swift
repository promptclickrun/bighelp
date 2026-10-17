import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Composio Connect's sign-in, as its OAuth metadata publishes it
/// (`connect.composio.dev/.well-known/oauth-authorization-server`): public clients
/// with PKCE, registered on the fly, and refresh tokens. The account is the
/// person's own Composio account; bighelp holds no Composio key of its own here.
enum ComposioOAuth {
    static let resource = URL(string: "https://connect.composio.dev/mcp")!
    static let authorizeURL = URL(string: "https://connect.composio.dev/oauth/authorize")!
    static let tokenURL = URL(string: "https://login.composio.dev/oauth2/token")!
    static let registrationURL = URL(string: "https://login.composio.dev/oauth2/register")!
    static let callbackScheme = "loopdy"
    static let redirectURI = "loopdy://composio-auth"
    static let scope = "openid profile email offline_access"
    static let maximumResponseBytes = 65_536

    static func isComposio(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, let host = url.host else { return false }
        return ["connect.composio.dev", "login.composio.dev"].contains(host)
    }

    /// A PKCE verifier (RFC 7636): 43–128 unreserved characters.
    static func makeVerifier() -> String { base64URL(Data((0..<48).map { _ in UInt8.random(in: 0...255) })) }

    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizeURL(clientID: String, verifier: String, state: String) -> URL {
        var parts = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "resource", value: resource.absoluteString),
        ]
        return parts.url!
    }

    /// The code from Composio's return to `loopdy://composio-auth`, if it answers this sign-in.
    static func code(from callback: URL, state: String) throws -> String {
        guard callback.scheme == callbackScheme, callback.host == "composio-auth",
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw ComposioError.signInFailed
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if value("error") != nil { throw ComposioError.signInCancelled }
        guard value("state") == state, let code = value("code"), isToken(code, maximum: 2_048) else {
            throw ComposioError.signInFailed
        }
        return code
    }

    /// `application/x-www-form-urlencoded`, escaping everything but unreserved characters
    /// (URLComponents leaves `&`, `=` and `+` alone, which a form body can't).
    static func formBody(_ form: [String: String]) -> String {
        // Byte checks, not CharacterSet: a CharacterSet check once passed in the simulator and failed on iPhone.
        func escape(_ text: String) -> String {
            text.utf8.map { byte in
                switch byte {
                case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, 0x2d, 0x2e, 0x5f, 0x7e: String(UnicodeScalar(byte))
                default: String(format: "%%%02X", byte)
                }
            }.joined()
        }
        return form.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&")
    }

    /// Printable token characters only, within a size bound.
    static func isToken(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f }
    }
}

enum ComposioError: Error, Equatable {
    case signInCancelled
    case signInFailed
    case signedOut
    case unavailable
    case invalidResponse
    /// Composio answered a tool call with an error of its own.
    case refused(String)
}

/// The saved sign-in. Never shown, logged or sent anywhere but Composio.
struct ComposioCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    let clientID: String
    var accessToken: String
    var refreshToken: String?
    var accessExpiresAt: Date
    /// The account's email, for "Signed in as".
    var email: String?

    var description: String { "ComposioCredential(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "<redacted>"]) }

    func isValid() -> Bool {
        ComposioOAuth.isToken(clientID, maximum: 256) && ComposioOAuth.isToken(accessToken, maximum: 16_384)
            && (refreshToken.map { ComposioOAuth.isToken($0, maximum: 16_384) } ?? true)
            && accessExpiresAt.timeIntervalSince1970.isFinite && (email?.utf8.count ?? 0) <= 320
    }

    /// A token answer: `access_token`, `token_type` Bearer, optional `refresh_token`, `expires_in`
    /// and `id_token` (read for the email only).
    static func decode(_ data: Data, clientID: String, previous: ComposioCredential?, now: Date) throws -> ComposioCredential {
        guard data.count <= ComposioOAuth.maximumResponseBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              (object["token_type"] as? String)?.lowercased() == "bearer" else { throw ComposioError.invalidResponse }
        let seconds = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
        let refresh = object["refresh_token"] as? String ?? previous?.refreshToken
        let email = (object["id_token"] as? String).flatMap(Self.email(fromIDToken:)) ?? previous?.email
        let credential = ComposioCredential(clientID: clientID, accessToken: access, refreshToken: refresh,
                                            accessExpiresAt: now.addingTimeInterval(min(max(seconds, 60), 86_400 * 30)),
                                            email: email)
        guard credential.isValid() else { throw ComposioError.invalidResponse }
        return credential
    }

    /// The `email` claim of an ID token, for display only (the token itself is never trusted here).
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts[1].utf8.count <= 8_192 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = claims["email"] as? String, email.contains("@"), email.utf8.count <= 320 else { return nil }
        return email
    }
}

/// Where the sign-in is kept.
@MainActor
protocol ComposioCredentialVault: AnyObject {
    func load() -> ComposioCredential?
    func save(_ credential: ComposioCredential) throws
    func remove()
}

/// iCloud Keychain: one sign-in that follows the person to their other devices,
/// readable after the first unlock so it works from the background too.
@MainActor
final class ComposioKeychainVault: ComposioCredentialVault {
    private let service = "app.bighelp.composio.v1"
    private let account = "connect"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    func load() -> ComposioCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 65_536,
              let credential = try? JSONDecoder().decode(ComposioCredential.self, from: data),
              credential.isValid() else { return nil }
        return credential
    }

    func save(_ credential: ComposioCredential) throws {
        guard credential.isValid() else { throw ComposioError.invalidResponse }
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecAttrSynchronizable as String] = kCFBooleanTrue
            add.merge(attributes) { _, new in new }
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ComposioError.unavailable }
        } else if status != errSecSuccess {
            throw ComposioError.unavailable
        }
    }

    func remove() { SecItemDelete(query as CFDictionary) }
}

/// Sends one HTTPS request to Composio and returns at most `maximumBytes`.
protocol ComposioHTTP: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}

/// No cookies or shared cache; Composio's hosts only.
struct ComposioURLSessionHTTP: ComposioHTTP {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard ComposioOAuth.isComposio(request.url) else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, ComposioOAuth.isComposio(http.url) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return (data, http)
    }
}

/// The person's Composio sign-in: register bighelp as a public client, sign in on
/// Composio's own page, keep the tokens fresh. One sign-in serves every computer.
@MainActor
@Observable
final class ComposioAccount {
    /// One Composio sign-in for the app, on every computer (and, through iCloud Keychain, every device).
    static let shared = ComposioAccount(vault: ComposioKeychainVault())

    private(set) var credential: ComposioCredential?

    @ObservationIgnored private let vault: any ComposioCredentialVault
    @ObservationIgnored private let http: any ComposioHTTP
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var refreshing: Task<ComposioCredential, any Error>?

    var isSignedIn: Bool { credential != nil }
    var email: String? { credential?.email }

    init(vault: any ComposioCredentialVault, http: any ComposioHTTP = ComposioURLSessionHTTP(),
         now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.http = http
        self.now = now
        credential = vault.load()
    }

    /// Picks up a sign-in another device saved (iCloud Keychain) or removed.
    func reload() { credential = vault.load() }

    /// Registers bighelp with Composio for this sign-in (public client, no secret).
    func register() async throws -> String {
        var request = URLRequest(url: ComposioOAuth.registrationURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "bighelp", "redirect_uris": [ComposioOAuth.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none", "scope": ComposioOAuth.scope,
        ])
        let (data, response) = try await http.send(request, maximumBytes: ComposioOAuth.maximumResponseBytes)
        guard (200...201).contains(response.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = object["client_id"] as? String, ComposioOAuth.isToken(clientID, maximum: 256) else {
            throw ComposioError.signInFailed
        }
        return clientID
    }

    /// Trades the code from Composio's page for tokens and saves them.
    func finishSignIn(code: String, verifier: String, clientID: String) async throws {
        let data = try await token([
            "grant_type": "authorization_code", "code": code, "redirect_uri": ComposioOAuth.redirectURI,
            "client_id": clientID, "code_verifier": verifier, "resource": ComposioOAuth.resource.absoluteString,
        ])
        let saved = try ComposioCredential.decode(data, clientID: clientID, previous: nil, now: now())
        try vault.save(saved)
        credential = saved
    }

    /// A token that is good for at least another minute, refreshed when needed.
    func accessToken() async throws -> String {
        guard let current = credential ?? vault.load() else { throw ComposioError.signedOut }
        if current.accessExpiresAt.timeIntervalSince(now()) > 60 { return current.accessToken }
        return try await refresh(current).accessToken
    }

    /// Composio refused the token: refresh once, then give up.
    func tokenRejected() async throws -> String {
        guard let current = credential ?? vault.load() else { throw ComposioError.signedOut }
        return try await refresh(current).accessToken
    }

    #if DEBUG
    /// Demo runs sign in without Composio.
    func finishSignIn(demo saved: ComposioCredential) async throws {
        try vault.save(saved)
        credential = saved
    }
    #endif

    func signOut() {
        refreshing?.cancel()
        refreshing = nil
        vault.remove()
        credential = nil
    }

    private func refresh(_ current: ComposioCredential) async throws -> ComposioCredential {
        if let refreshing { return try await refreshing.value }
        let task = Task { @MainActor [weak self] () throws -> ComposioCredential in
            guard let self else { throw CancellationError() }
            // Another device may have refreshed already; its rotated token arrives through iCloud Keychain.
            let latest = vault.load() ?? current
            guard let refreshToken = latest.refreshToken else { throw ComposioError.signedOut }
            let data = try await token([
                "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": latest.clientID,
                "resource": ComposioOAuth.resource.absoluteString,
            ])
            let saved = try ComposioCredential.decode(data, clientID: latest.clientID, previous: latest, now: now())
            try vault.save(saved)
            credential = saved
            return saved
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            return try await task.value
        } catch ComposioError.refused {
            signOut()
            throw ComposioError.signedOut
        }
    }

    private func token(_ form: [String: String]) async throws -> Data {
        var request = URLRequest(url: ComposioOAuth.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(ComposioOAuth.formBody(form).utf8)
        let (data, response) = try await http.send(request, maximumBytes: ComposioOAuth.maximumResponseBytes)
        if (400...499).contains(response.statusCode) { throw ComposioError.refused("sign-in") }
        guard response.statusCode == 200 else { throw ComposioError.unavailable }
        return data
    }
}

/// Composio's own sign-in page, returning to `loopdy://composio-auth`.
@MainActor
final class ComposioSignInBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn(account: ComposioAccount) async throws {
        let clientID = try await account.register()
        let verifier = ComposioOAuth.makeVerifier()
        let state = ComposioOAuth.base64URL(Data((0..<24).map { _ in UInt8.random(in: 0...255) }))
        let callback = try await open(ComposioOAuth.authorizeURL(clientID: clientID, verifier: verifier, state: state))
        let code = try ComposioOAuth.code(from: callback, state: state)
        try await account.finishSignIn(code: code, verifier: verifier, clientID: clientID)
    }

    private func open(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: ComposioOAuth.callbackScheme,
                                                     completionHandler: Self.completion(continuation))
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { continuation.resume(throwing: ComposioError.signInFailed) }
        }
    }

    /// AuthenticationServices may call back on its own queue (an XPC queue on the Mac), so
    /// this must not be main-actor isolated.
    nonisolated private static func completion(
        _ continuation: CheckedContinuation<URL, any Error>
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { url, error in
            if let url { continuation.resume(returning: url); return }
            let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            continuation.resume(throwing: cancelled ? ComposioError.signInCancelled : ComposioError.signInFailed)
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return active?.keyWindow ?? active?.windows.first ?? ASPresentationAnchor()
        }
    }
}
