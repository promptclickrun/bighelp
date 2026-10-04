import Foundation
import Darwin

@MainActor
protocol DirectHermesRPC: AnyObject {
    var onEvent: ((DirectHermesEvent) -> Void)? { get set }
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue
    func disconnect() async
}

struct DirectHermesEvent: Sendable {
    let type: String
    let sessionID: String?
    let payload: [String: BighelpJSONValue]
    let sequence: Int?
    /// The unmodified event parameters, including future envelope metadata.
    let parameters: [String: BighelpJSONValue]

    init(type: String, sessionID: String?, payload: [String: BighelpJSONValue], sequence: Int?,
         parameters: [String: BighelpJSONValue] = [:]) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.sequence = sequence
        self.parameters = parameters
    }
}

/// A live server→client request. The string ID is opaque and must be returned
/// unchanged; it is not interchangeable with a client-authored RPC ID.
struct DirectHermesServerRequest: Equatable, Sendable {
    let id: String
    let method: String
    let params: [String: BighelpJSONValue]

    var sessionID: String? { params["session_id"]?.string }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.method == rhs.method && lhs.params == rhs.params
    }
}

struct DirectHermesServerRequestCancellation: Equatable, Sendable {
    let id: String
    let method: String
    let reason: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.method == rhs.method && lhs.reason == rhs.reason
    }
}

/// A handler result is only framing. The transport never chooses an approval,
/// supplies a secret, or fabricates native window/terminal/preview content.
enum DirectHermesServerResponse: Equatable, Sendable {
    case result(BighelpJSONValue)
    case error(code: Int, message: String, data: BighelpJSONValue? = nil)
}

typealias DirectHermesServerRequestHandler =
    @MainActor @Sendable (DirectHermesServerRequest) async -> DirectHermesServerResponse

/// Validation is also applied when decoding a saved endpoint. Never trust a URL merely
/// because it came from local storage. No DNS resolution can authorize plaintext.
struct DirectHermesEndpoint: Codable, Equatable, Sendable {
    let baseURL: URL
    let allowPrivateHTTP: Bool
    var identity: String { baseURL.absoluteString }
    var isLiteralLoopback: Bool { Self.addressClass(host).loopback }
    var host: String {
        (baseURL.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    init(address: String, allowPrivateHTTP: Bool = false) throws {
        guard !address.isEmpty, address.utf8.count <= 2_048,
              address == address.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f }),
              !address.contains("\\") else { throw DirectHermesError.invalidEndpoint }
        var input = address
        if !input.contains("://") {
            // An unbracketed IPv6 literal without a path/port is unambiguous.
            var ipv6 = in6_addr()
            if inet_pton(AF_INET6, input, &ipv6) == 1 { input = "[\(input)]" }
            input = "https://" + input
        }
        guard var parts = URLComponents(string: input),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let rawHost = parts.host, !rawHost.isEmpty else { throw DirectHermesError.invalidEndpoint }
        let hostname = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !hostname.contains("%"), Self.validHost(hostname),
              parts.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw DirectHermesError.invalidEndpoint
        }
        // URLComponents may accept an empty port; the original authority must not.
        let authority = input.components(separatedBy: "://")[1].split(separator: "/", omittingEmptySubsequences: false)[0]
        guard !authority.hasSuffix(":"), !authority.contains("%") else { throw DirectHermesError.invalidEndpoint }
        let allowedPath = CharacterSet(charactersIn: "/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let path = parts.percentEncodedPath
        guard path.unicodeScalars.allSatisfy({ allowedPath.contains($0) }),
              !path.contains("//"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw DirectHermesError.invalidEndpoint
        }
        if scheme == "http", !(allowPrivateHTTP && Self.isPrivateNetworkHost(hostname)) {
            throw DirectHermesError.plaintextNotAllowed
        }
        parts.scheme = scheme
        parts.host = hostname.contains(":") ? "[\(hostname)]" : hostname
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        parts.percentEncodedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let url = parts.url else { throw DirectHermesError.invalidEndpoint }
        baseURL = url
        self.allowPrivateHTTP = allowPrivateHTTP
    }

    /// Only application-owned relative routes reach this method.
    func url(for route: String) throws -> URL {
        guard route.hasPrefix("/"), !route.hasPrefix("//"), !route.contains("?"),
              !route.contains("#"), !route.contains("%"), !route.contains("\\"),
              !route.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DirectHermesError.invalidEndpoint
        }
        parts.path += route
        guard let url = parts.url else { throw DirectHermesError.invalidEndpoint }
        return url
    }

    private static func validHost(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 { return true }
        // Refuse numeric aliases (127.1, integer/hex IPv4), invalid IPs, and ambiguous DNS.
        guard !host.contains(":"), host.utf8.count <= 253,
              !host.allSatisfy({ $0.isNumber || $0 == "." }),
              !host.lowercased().hasPrefix("0x") else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    /// Names that only resolve inside a private network (mDNS, home routers,
    /// ICANN's reserved .internal, company intranets, Tailscale's MagicDNS).
    /// Public DNS never serves them to a plain-HTTP port: a Tailscale Funnel name
    /// is public only over HTTPS. `.localhost` names always mean this device (RFC 6761).
    static let privateNameSuffixes = ["local", "lan", "internal", "home.arpa", "intranet", "corp", "localdomain", "private",
                                      "localhost", "ts.net", "beta.tailscale.net"]

    /// Plain HTTP stays on a network the person controls: this device, home or
    /// office Wi-Fi, a VPN or Tailscale. Public names and addresses need HTTPS.
    static func isPrivateNetworkHost(_ host: String) -> Bool {
        let host = host.lowercased()
        let addressClass = addressClass(host)
        if addressClass.loopback || addressClass.privateNetwork { return true }
        var v4 = in_addr(), v6 = in6_addr()
        guard inet_pton(AF_INET, host, &v4) != 1, inet_pton(AF_INET6, host, &v6) != 1 else { return false }
        // A single-label name ("hermes") never leaves the local resolver.
        if !host.contains(".") { return true }
        return privateNameSuffixes.contains { host.hasSuffix("." + $0) }
    }

    private static func addressClass(_ host: String) -> (loopback: Bool, privateNetwork: Bool) {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return withUnsafeBytes(of: v4) { bytes in
                let (a, b) = (bytes[0], bytes[1])
                let privateNetwork = a == 10                       // 10.0.0.0/8 (VPNs, offices)
                    || (a == 172 && (16...31).contains(b))         // 172.16.0.0/12
                    || (a == 192 && b == 168)                      // 192.168.0.0/16 (home Wi-Fi)
                    || (a == 100 && (64...127).contains(b))        // 100.64.0.0/10 (Tailscale, CGNAT)
                    || (a == 169 && b == 254)                      // link-local
                return (a == 127, privateNetwork)
            }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: v6) { bytes in
                let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
                // fc00::/7 unique local (includes Tailscale's fd7a:115c:a1e0::/48).
                return (loopback, bytes[0] & 0xfe == 0xfc)
            }
        }
        return (false, false)
    }

    private enum CodingKeys: String, CodingKey { case baseURL, allowPrivateHTTP }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(address: values.decode(String.self, forKey: .baseURL),
                      allowPrivateHTTP: values.decode(Bool.self, forKey: .allowPrivateHTTP))
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(baseURL.absoluteString, forKey: .baseURL)
        try values.encode(allowPrivateHTTP, forKey: .allowPrivateHTTP)
    }
}

enum DirectHermesAuthInput: Sendable {
    /// Use the same bootstrap as the host dashboard when no sign-in is configured.
    case dashboard
    case token(String)
    case password(username: String, password: String)
    /// Explicit selection is additive; the original password case still requires
    /// exactly one password-capable provider rather than guessing among providers.
    case passwordProvider(provider: String, username: String, password: String)
    /// nil deliberately opens the stock host's provider chooser.
    case browser(provider: String?)
}

struct DirectHermesAuthenticationProvider: Identifiable, Equatable, Sendable {
    let name: String
    let displayName: String
    let supportsPassword: Bool
    var id: String { name }
}

/// Host advertisement only. native_pkce does NOT establish that the iOS system
/// browser can reach a loopback listener; that composition requires runtime proof.
struct DirectHermesAuthenticationDiscovery: Equatable, Sendable {
    let authRequired: Bool
    let flows: [String]
    let providers: [DirectHermesAuthenticationProvider]
    var supportsNativePKCE: Bool { authRequired && flows.contains("native_pkce") }
    var passwordProviders: [DirectHermesAuthenticationProvider] {
        supportsNativePKCE ? providers.filter(\.supportsPassword) : []
    }
    var browserProviders: [DirectHermesAuthenticationProvider] {
        supportsNativePKCE ? providers : []
    }
}

enum DirectHermesStoredAuthentication: Codable, Equatable, Sendable {
    case bearer(accessToken: String, refreshToken: String?, expiresAt: Date?)
    case legacyLoopbackToken(String)
    case dashboardSession(token: String, automatic: Bool)
}

/// Contains secrets: encode ONLY into the device-local Keychain, never preferences/logs.
struct DirectHermesSavedConnection: Codable, Equatable, Sendable {
    var endpoint: DirectHermesEndpoint
    var authentication: DirectHermesStoredAuthentication
    var provider: String?
    var userID: String?
    let credentialEndpointIdentity: String
    let schemaVersion: Int

    init(endpoint: DirectHermesEndpoint, authentication: DirectHermesStoredAuthentication,
         provider: String? = nil, userID: String? = nil) {
        self.endpoint = endpoint
        self.authentication = authentication
        self.provider = provider
        self.userID = userID
        credentialEndpointIdentity = endpoint.identity
        schemaVersion = 1
    }

    /// Non-secret scope distinguishes different authenticated users at one host.
    var identity: String {
        if case .dashboardSession = authentication { return [endpoint.identity, "dashboard-session"].joined(separator: "\u{1f}") }
        return [endpoint.identity, provider ?? "legacy", userID ?? "loopback"].joined(separator: "\u{1f}")
    }

    var workspaceAuthority: WorkspaceAuthority? {
        switch authentication {
        case .dashboardSession:
            return try? .dashboard(endpointIdentity: endpoint.identity)
        case .bearer:
            guard let provider, let userID else { return nil }
            return try? .direct(endpointIdentity: endpoint.identity, providerID: provider, userID: userID)
        case .legacyLoopbackToken: return nil
        }
    }

    func validate() throws {
        guard schemaVersion == 1, endpoint.identity == credentialEndpointIdentity else {
            throw DirectHermesError.savedConnectionInvalid
        }
        switch authentication {
        case .dashboardSession(let token, _):
            guard provider == nil, userID == nil else { throw DirectHermesError.savedConnectionInvalid }
            try DirectHermesSecretValidation.validate(token)
        case .legacyLoopbackToken(let token):
            guard endpoint.isLiteralLoopback, endpoint.allowPrivateHTTP, provider == nil, userID == nil else {
                throw DirectHermesError.savedConnectionInvalid
            }
            try DirectHermesSecretValidation.validate(token)
        case .bearer(let accessToken, let refreshToken, _):
            try DirectHermesSecretValidation.validate(accessToken)
            if let refreshToken { try DirectHermesSecretValidation.validate(refreshToken) }
            guard let provider, !provider.isEmpty, let userID, !userID.isEmpty else {
                throw DirectHermesError.savedConnectionInvalid
            }
            try DirectHermesIdentity.validate(provider, maximumBytes: 128)
            try DirectHermesIdentity.validate(userID, maximumBytes: 512)
        }
    }
}

/// Only fixed, locally authored messages cross the presentation boundary. Never wrap
/// NSError.localizedDescription, server messages, URLs, cookies, or RPC error.data.
enum DirectHermesError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint, plaintextNotAllowed, invalidCredentials, authenticationRequired
    case unsupportedAuthentication, unsupportedHermesVersion, ambiguousPasswordProvider, authModeChanged, identityChanged
    case savedConnectionInvalid, secureStorageUnavailable, secureStorageChanged
    case redirectRefused, invalidResponse, messageTooLarge, tooManyRequests, notConnected
    case connectionFailed, tlsRequired, rateLimited, serverUnavailable
    case browserAuthenticationUnavailable, nativeTokenExchangeUncertain
    case invalidAccessCredentials, cloudflareAccessDenied, hostNameRefused
    case webPageInsteadOfHermes(throughCloudflare: Bool)
    case disconnected(outcomeUnknown: Bool)
    case timedOut(outcomeUnknown: Bool)
    case cancelled(outcomeUnknown: Bool)
    case rpcRejected(code: Int)

    var outcomeIsUnknown: Bool {
        switch self {
        case .nativeTokenExchangeUncertain: true
        case .disconnected(let unknown), .timedOut(let unknown), .cancelled(let unknown): unknown
        default: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTPS host address, optionally with a port and deployment path."
        case .plaintextNotAllowed: "Plain http:// only works on a private network, like home Wi-Fi, a VPN or Tailscale. Use https:// for this address."
        case .invalidCredentials: "The host rejected these credentials. Use a provider-issued access token or check your username and password."
        case .authenticationRequired: "Your host session has expired. Sign in again."
        case .unsupportedAuthentication: "This host does not support the selected sign-in method."
        case .unsupportedHermesVersion:
            "This version of Hermes isn't supported by this version of bighelp yet. Update bighelp from TestFlight, or run Hermes \(DirectHermesReleaseContract.supportedVersions.joined(separator: ", "))."
        case .ambiguousPasswordProvider: "Choose a password provider, use browser sign-in, or connect with a provider-issued access token."
        case .authModeChanged: "The host authentication mode changed. Sign in again; credentials were not sent using another mode."
        case .identityChanged: "The authenticated host account changed. Sign in again to keep chats separate."
        case .savedConnectionInvalid: "The saved host connection is invalid. Remove it and sign in again."
        case .secureStorageUnavailable: "The device could not access secure connection storage. Unlock the device and try again."
        case .secureStorageChanged: "The saved host connection changed. Reopen the current connection before continuing."
        case .redirectRefused: "The host redirected the connection. Enter its final HTTPS address instead."
        case .invalidAccessCredentials: "Enter the Cloudflare Access client ID and client secret from your service token."
        case .cloudflareAccessDenied: "Cloudflare Access didn't let bighelp through. Check the service token's client ID and secret, and that your Access policy allows it (Service Auth)."
        case .hostNameRefused:
            "Hermes turned bighelp away because it answers only to its local address. In Hermes, set dashboard.public_url to this https:// address and set up a Hermes sign-in, then restart Hermes."
        case .webPageInsteadOfHermes(let throughCloudflare):
            throughCloudflare
                ? "Cloudflare answered with a web page instead of Hermes. Check that your Access policy allows the service token (Service Auth) and that the tunnel sends this address to Hermes."
                : "This address answered with a web page instead of Hermes. Check the address and port."
        case .invalidResponse: "The host returned an unsupported or invalid response."
        case .messageTooLarge: "The host message exceeds this client's safe size limit."
        case .tooManyRequests: "Too many host requests are pending. Wait before trying again."
        case .notConnected: "The host is not connected. Reconnect before continuing."
        case .connectionFailed: "Could not connect to the host. Check its address, your VPN or Tailscale, and that Hermes is running."
        case .tlsRequired: "The secure connection could not be verified. Check the computer's HTTPS certificate."
        case .rateLimited: "The host is limiting sign-in attempts. Wait before trying again."
        case .serverUnavailable: "The host authentication service is unavailable. Try again later."
        case .browserAuthenticationUnavailable: "Browser sign-in could not start on this device. Keep bighelp in the foreground, or use a password or provider-issued access token."
        case .nativeTokenExchangeUncertain: "The host sign-in could not be confirmed. Start a new sign-in; the one-time code will not be reused."
        case .disconnected(let unknown), .timedOut(let unknown), .cancelled(let unknown):
            unknown ? "The connection ended before the host confirmed the action. It may have been accepted. Check the conversation before sending again." : "The host request did not complete. Reconnect or try again."
        case .rpcRejected(let code): "The host rejected this operation (code \(code))."
        }
    }
}

enum DirectHermesIdentity {
    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let lhs), .some(let rhs)): lhs.utf8.elementsEqual(rhs.utf8)
        default: false
        }
    }

    static func validate(_ value: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              value.utf8.elementsEqual(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw DirectHermesError.savedConnectionInvalid
        }
    }
}

enum DirectHermesSecretValidation {
    static func validate(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16_384,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw DirectHermesError.invalidCredentials
        }
    }
}

/// Pure decoding seam shared by production and focused protocol checks.
enum DirectHermesWire {
    static let maximumMessageBytes = 4 * 1_024 * 1_024
    static let maximumBatchCount = 4_096
    static let maximumMethodBytes = 256
    static let maximumRequestIDBytes = 1_024
    static let maximumCancellationReasonBytes = 4_096
    static let maximumServerResponseBytes = 2 * 1_024 * 1_024
    enum Message: Sendable {
        case event(DirectHermesEvent)
        case request(DirectHermesServerRequest)
        case result(id: String, value: BighelpJSONValue)
        case failure(id: String, code: Int)
    }

    static func decode(_ data: Data) throws -> [Message] {
        guard data.count <= maximumMessageBytes else { throw DirectHermesError.messageTooLarge }
        var messages: [Message] = []
        // JSON strings cannot contain literal newlines, so framing never splits a valid value.
        for line in data.split(separator: 0x0a) {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0d || $0 == 0x09 }) { continue }
            guard messages.count < maximumBatchCount else { throw DirectHermesError.messageTooLarge }
            try validateNesting(line)
            guard let value = try? JSONDecoder().decode(BighelpJSONValue.self, from: Data(line)),
                  let object = value.object, object["jsonrpc"]?.string == "2.0" else {
                throw DirectHermesError.invalidResponse
            }
            let methodValue = object["method"]
            let hasResponse = object["result"] != nil || object["error"] != nil
            if let methodValue {
                guard let method = methodValue.string, validMethod(method), !hasResponse else {
                    throw DirectHermesError.invalidResponse
                }
                if method == "event" {
                    guard object["id"] == nil,
                          let params = object["params"]?.object,
                          let type = params["type"]?.string,
                          !type.isEmpty, type.utf8.count <= maximumMethodBytes else {
                        throw DirectHermesError.invalidResponse
                    }
                    if let payload = params["payload"], payload.object == nil {
                        throw DirectHermesError.invalidResponse
                    }
                    if let session = params["session_id"], session != .null, session.string == nil {
                        throw DirectHermesError.invalidResponse
                    }
                    if let seq = params["seq"], seq.integer == nil {
                        throw DirectHermesError.invalidResponse
                    }
                    let event = DirectHermesEvent(
                        type: type,
                        sessionID: params["session_id"]?.string,
                        payload: params["payload"]?.object ?? [:],
                        sequence: params["seq"]?.integer,
                        parameters: params
                    )
                    if type == "request.cancel" { _ = try cancellation(in: event) }
                    messages.append(.event(event))
                } else {
                    guard let id = object["id"]?.string, validRequestID(id) else {
                        // Backend notifications use method "event". A different
                        // method without a string ID is not a server request.
                        throw DirectHermesError.invalidResponse
                    }
                    let params: [String: BighelpJSONValue]
                    switch object["params"] {
                    case nil, .some(.null): params = [:]
                    case .some(.object(let value)): params = value
                    default: throw DirectHermesError.invalidResponse
                    }
                    messages.append(.request(DirectHermesServerRequest(id: id, method: method, params: params)))
                }
            } else if let id = object["id"]?.string {
                guard validRequestID(id), object["params"] == nil else {
                    throw DirectHermesError.invalidResponse
                }
                if let error = object["error"]?.object, let code = error["code"]?.integer {
                    guard object["result"] == nil else { throw DirectHermesError.invalidResponse }
                    messages.append(.failure(id: id, code: code))
                } else if let result = object["result"], object["error"] == nil {
                    messages.append(.result(id: id, value: result))
                } else { throw DirectHermesError.invalidResponse }
            } else {
                // This client uses string IDs only; unknown notifications are not silently
                // reinterpreted as replies or events.
                throw DirectHermesError.invalidResponse
            }
        }
        guard !messages.isEmpty else { throw DirectHermesError.invalidResponse }
        return messages
    }

    static func validMethod(_ method: String) -> Bool {
        !method.isEmpty && method.utf8.count <= maximumMethodBytes
            && method.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func validRequestID(_ id: String) -> Bool {
        id.utf8.count <= maximumRequestIDBytes
    }

    /// The documented payload is exact. Matching both ID and method prevents a
    /// malformed cancellation from retiring a different pending prompt.
    static func cancellation(in event: DirectHermesEvent) throws -> DirectHermesServerRequestCancellation {
        guard event.type == "request.cancel",
              Set(event.payload.keys) == Set(["id", "method", "reason"]),
              let id = event.payload["id"]?.string, validRequestID(id),
              let method = event.payload["method"]?.string, validMethod(method),
              let reason = event.payload["reason"]?.string,
              reason.utf8.count <= maximumCancellationReasonBytes else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesServerRequestCancellation(id: id, method: method, reason: reason)
    }

    /// Pure response-framing seam used by the production writer. IDs are encoded
    /// from the original decoded String and are never regenerated or normalized.
    static func encodeServerResponse(id: String, response: DirectHermesServerResponse) throws -> String {
        guard validRequestID(id) else { throw DirectHermesError.invalidResponse }
        var object: [String: BighelpJSONValue] = [
            "jsonrpc": .string("2.0"), "id": .string(id),
        ]
        switch response {
        case .result(let value):
            object["result"] = value
        case .error(let code, let message, let data):
            guard !message.isEmpty, message.utf8.count <= maximumCancellationReasonBytes else {
                throw DirectHermesError.invalidResponse
            }
            var error: [String: BighelpJSONValue] = [
                "code": .integer(code), "message": .string(message),
            ]
            if let data { error["data"] = data }
            object["error"] = .object(error)
        }
        let value = BighelpJSONValue.object(object)
        try validateValueSize(value, limit: maximumServerResponseBytes)
        let data: Data
        do { data = try JSONEncoder().encode(value) }
        catch { throw DirectHermesError.invalidResponse }
        guard data.count <= maximumServerResponseBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw DirectHermesError.messageTooLarge
        }
        return text
    }

    /// Bound caller-owned values before JSONEncoder allocates the wire buffer.
    static func validateValueSize(_ value: BighelpJSONValue, limit: Int) throws {
        var remaining = limit
        func visit(_ value: BighelpJSONValue, depth: Int) throws {
            guard depth <= 64 else { throw DirectHermesError.messageTooLarge }
            remaining -= 2
            guard remaining >= 0 else { throw DirectHermesError.messageTooLarge }
            switch value {
            case .string(let text): remaining -= text.utf8.count
            case .object(let object):
                for (key, value) in object {
                    remaining -= key.utf8.count + 4
                    guard remaining >= 0 else { throw DirectHermesError.messageTooLarge }
                    try visit(value, depth: depth + 1)
                }
            case .array(let values):
                for value in values { try visit(value, depth: depth + 1) }
            default: remaining -= 8
            }
            guard remaining >= 0 else { throw DirectHermesError.messageTooLarge }
        }
        try visit(value, depth: 0)
    }

    static func validateNesting<T: Collection>(_ data: T) throws where T.Element == UInt8 {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { quoted = false }
            } else if byte == 0x22 { quoted = true }
            else if byte == 0x7b || byte == 0x5b {
                depth += 1
                if depth > 64 { throw DirectHermesError.messageTooLarge }
            } else if byte == 0x7d || byte == 0x5d { depth -= 1 }
        }
    }
}

/// Pure, bounded state seam for live server requests. A response remains
/// cancellable while queued and is retired immediately before its socket send.
struct DirectHermesServerRequestState: Sendable {
    enum Registration: Equatable, Sendable { case accepted, duplicate, atCapacity }
    private enum Phase: Sendable { case handling, responseQueued }
    private struct Entry: Sendable {
        let method: String
        var phase: Phase
    }

    static let maximumOpenRequests = 64
    // Swift String keys equate canonically equivalent Unicode. Protocol IDs
    // are opaque bytes, so those distinct requests must remain independent.
    private var entries: [Data: Entry] = [:]

    var count: Int { entries.count }

    func contains(id: String, method: String) -> Bool {
        entries[Data(id.utf8)]?.method == method
    }

    mutating func register(_ request: DirectHermesServerRequest) -> Registration {
        let key = Data(request.id.utf8)
        guard entries[key] == nil else { return .duplicate }
        guard entries.count < Self.maximumOpenRequests else { return .atCapacity }
        entries[key] = Entry(method: request.method, phase: .handling)
        return .accepted
    }

    mutating func stageResponse(id: String, method: String) -> Bool {
        let key = Data(id.utf8)
        guard var entry = entries[key], entry.method == method,
              case .handling = entry.phase else { return false }
        entry.phase = .responseQueued
        entries[key] = entry
        return true
    }

    mutating func beginSendingResponse(id: String, method: String) -> Bool {
        let key = Data(id.utf8)
        guard let entry = entries[key], entry.method == method,
              case .responseQueued = entry.phase else { return false }
        entries.removeValue(forKey: key)
        return true
    }

    mutating func cancel(_ cancellation: DirectHermesServerRequestCancellation) -> Bool {
        retire(id: cancellation.id, method: cancellation.method)
    }

    mutating func retire(id: String, method: String) -> Bool {
        let key = Data(id.utf8)
        guard entries[key]?.method == method else { return false }
        entries.removeValue(forKey: key)
        return true
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }
}
