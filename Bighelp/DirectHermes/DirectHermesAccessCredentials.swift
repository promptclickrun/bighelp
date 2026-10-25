import Foundation
import Security

/// Credentials for whatever guards a Hermes address before Hermes itself:
/// a Cloudflare Access service token (for a Cloudflare Tunnel), or a proxy's
/// username and password (HTTP basic auth on nginx, Caddy, Traefik and the
/// like). bighelp sends them on every request and socket to that exact address,
/// and nowhere else.
struct DirectHermesAccessCredentials: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case cloudflareAccess
        case basic
    }

    let kind: Kind
    /// The Cloudflare client ID, or the proxy username.
    let clientID: String
    /// The Cloudflare client secret, or the proxy password.
    let clientSecret: String

    /// A Cloudflare Access service token.
    init(clientID: String, clientSecret: String) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.valid(id), Self.valid(secret) else { throw DirectHermesError.invalidAccessCredentials }
        kind = .cloudflareAccess
        self.clientID = id
        self.clientSecret = secret
    }

    /// A proxy's username and password. Passwords keep their spaces.
    init(username: String, password: String) throws {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, user.utf8.count <= 256, !user.contains(":"),
              !user.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !password.isEmpty, password.utf8.count <= 512,
              !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesError.invalidAccessCredentials
        }
        kind = .basic
        clientID = user
        clientSecret = password
    }

    var headers: [String: String] {
        switch kind {
        case .cloudflareAccess:
            ["CF-Access-Client-Id": clientID, "CF-Access-Client-Secret": clientSecret]
        case .basic:
            ["Authorization": "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()]
        }
    }

    /// Basic auth may also go to a plain-HTTP address on a private network the
    /// person allowed, like their Hermes session. Cloudflare Access is HTTPS only.
    func canSend(to endpoint: DirectHermesEndpoint) -> Bool {
        endpoint.baseURL.scheme == "https"
            || (kind == .basic && endpoint.allowPrivateHTTP
                && DirectHermesEndpoint.isPrivateNetworkHost(endpoint.host))
    }

    /// Header-safe: printable ASCII, no spaces, bounded.
    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
    }

    private enum CodingKeys: String, CodingKey { case kind, clientID, clientSecret }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .clientID)
        let secret = try values.decode(String.self, forKey: .clientSecret)
        // Items saved before basic auth have no kind: they are Cloudflare Access tokens.
        switch try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .cloudflareAccess {
        case .cloudflareAccess: try self.init(clientID: id, clientSecret: secret)
        case .basic: try self.init(username: id, password: secret)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(clientID, forKey: .clientID)
        try values.encode(clientSecret, forKey: .clientSecret)
    }
}

/// A header a reverse proxy in front of Hermes wants (Pangolin, nginx rules
/// and the like), such as `X-Access-Id` and `X-Access-Secret`.
/// Sent with every request and socket to that one address, never elsewhere.
struct DirectHermesCustomHeader: Codable, Equatable, Hashable, Sendable {
    let name: String
    let value: String

    enum Problem: LocalizedError, Equatable {
        case invalidName(String)
        case reserved(String)
        case invalidValue(String)
        case duplicate(String)
        case tooMany

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                "“\(name)” isn't a valid header name. Use letters, numbers and dashes, like X-Access-Id."
            case .reserved(let name):
                "bighelp sets \(name) itself. For a proxy's username and password or a Cloudflare Access service token, use those options instead."
            case .invalidValue(let name):
                "The value for \(name) can't be empty, contain line breaks, or be longer than 4,096 characters."
            case .duplicate(let name):
                "\(name) is listed twice."
            case .tooMany:
                "Add up to 16 custom headers."
            }
        }
    }

    init(name: String, value: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isToken(name), name.utf8.count <= 128 else { throw Problem.invalidName(name) }
        guard !Self.isReserved(name) else { throw Problem.reserved(name) }
        guard !value.isEmpty, value.utf8.count <= 4_096,
              value.unicodeScalars.allSatisfy({ $0.value == 0x09 || (0x20...0x7e).contains($0.value) || $0.value >= 0x80 })
        else { throw Problem.invalidValue(name) }
        self.name = name
        self.value = value
    }

    /// Validates a whole list: names unique (headers ignore case), at most 16.
    static func list(_ pairs: [(name: String, value: String)]) throws -> [DirectHermesCustomHeader] {
        let filled = pairs.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
            || !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard filled.count <= 16 else { throw Problem.tooMany }
        var seen = Set<String>()
        return try filled.map { pair in
            let header = try DirectHermesCustomHeader(name: pair.name, value: pair.value)
            guard seen.insert(header.name.lowercased()).inserted else { throw Problem.duplicate(header.name) }
            return header
        }
    }

    /// RFC 9110 token characters.
    private static func isToken(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
        }
    }

    /// What bighelp, Hermes sign-in, HTTP itself or the other access options own.
    static func isReserved(_ name: String) -> Bool {
        let lower = name.lowercased()
        let exact: Set<String> = [
            "host", "authorization", "proxy-authorization", "cookie", "content-type", "content-length",
            "content-encoding", "transfer-encoding", "connection", "upgrade", "keep-alive", "te", "expect",
            "accept", "accept-encoding", "cache-control", "range", "if-match", "if-none-match", "origin",
        ]
        return exact.contains(lower) || lower.hasPrefix("sec-") || lower.hasPrefix("x-loopdy-")
            || lower.hasPrefix("x-hermes-") || lower.hasPrefix("cf-access-")
    }
}

/// Device-local Keychain storage, one item per host address. While a host is
/// being set up its credentials are staged in memory (used for requests) and
/// only saved once a connection succeeds. The Keychain service name predates
/// basic auth and stays, so saved tokens keep working.
///
/// iOS wakes bighelp while the phone is locked (widget refresh, a sign-in renewal
/// push), so items are readable after the first unlock, like the sign-in, and a
/// read the Keychain refuses is never kept: the next read tries again.
final class DirectHermesAccessCredentialStore: @unchecked Sendable {
    static let shared = DirectHermesAccessCredentialStore()

    private let service: String
    private let lock = NSLock()
    /// Keychain reads by address; `.some(nil)` records "none saved". Refused reads aren't kept.
    private var cache: [String: DirectHermesAccessCredentials?] = [:]
    private var staged: [String: DirectHermesAccessCredentials] = [:]
    /// Custom headers, kept apart from the gate credentials above (their own Keychain items).
    private var headerCache: [String: [DirectHermesCustomHeader]] = [:]
    private var stagedHeaders: [String: [DirectHermesCustomHeader]] = [:]
    private var headerService: String { service + ".custom-headers" }

    init(service: String = "app.loopdy.mobile.cloudflare-access") {
        self.service = service
    }

    #if DEBUG
    var serviceForTesting: String { service }
    /// Reads fail the way they do on a locked phone.
    var keychainLockedForTesting = false
    #endif

    /// Only for the exact address, and never over the open internet in plain HTTP.
    func credentials(for endpoint: DirectHermesEndpoint) -> DirectHermesAccessCredentials? {
        guard endpoint.baseURL.scheme == "https" || endpoint.allowPrivateHTTP else { return nil }
        let key = endpoint.identity
        let known: DirectHermesAccessCredentials?? = lock.withLock {
            if let value = staged[key] { return .some(value) }
            return cache[key]
        }
        let value: DirectHermesAccessCredentials?
        if let known {
            value = known
        } else {
            guard let read = load(key) else { return nil }
            value = read
            lock.withLock { cache[key] = .some(value) }
        }
        guard let value, value.canSend(to: endpoint) else { return nil }
        return value
    }

    /// Everything sent to this address: custom headers, then the gate credential.
    func headers(for endpoint: DirectHermesEndpoint) -> [String: String] {
        var headers: [String: String] = [:]
        for header in customHeaders(for: endpoint) { headers[header.name] = header.value }
        for (field, value) in credentials(for: endpoint)?.headers ?? [:] { headers[field] = value }
        return headers
    }

    /// Like basic auth: HTTPS, or plain HTTP only on a private network the person allowed.
    func customHeaders(for endpoint: DirectHermesEndpoint) -> [DirectHermesCustomHeader] {
        guard Self.mayCarrySecrets(endpoint) else { return [] }
        let key = endpoint.identity
        if let value = lock.withLock({ stagedHeaders[key] ?? headerCache[key] }) { return value }
        guard let value = loadHeaders(key) else { return [] }
        lock.withLock { headerCache[key] = value }
        return value
    }

    func savedCustomHeaders(for endpoint: DirectHermesEndpoint) -> [DirectHermesCustomHeader] {
        Self.mayCarrySecrets(endpoint) ? loadHeaders(endpoint.identity) ?? [] : []
    }

    func stageCustomHeaders(_ headers: [DirectHermesCustomHeader]?, for endpoint: DirectHermesEndpoint) {
        lock.withLock { stagedHeaders[endpoint.identity] = headers }
    }

    /// Saves right away (editing a connected host); the next connection uses them.
    func replace(access: DirectHermesAccessCredentials?, customHeaders: [DirectHermesCustomHeader],
                 for endpoint: DirectHermesEndpoint) throws {
        let key = endpoint.identity
        if let access { try save(access, key) } else { SecItemDelete(query(key) as CFDictionary) }
        try saveHeaders(customHeaders, key)
        lock.withLock {
            staged[key] = nil
            cache[key] = .some(access)
            stagedHeaders[key] = nil
            headerCache[key] = customHeaders
        }
    }

    static func mayCarrySecrets(_ endpoint: DirectHermesEndpoint) -> Bool {
        endpoint.baseURL.scheme == "https"
            || (endpoint.allowPrivateHTTP && DirectHermesEndpoint.isPrivateNetworkHost(endpoint.host))
    }

    func hasSavedCredentials(for endpoint: DirectHermesEndpoint) -> Bool {
        savedCredentials(for: endpoint) != nil
    }

    func savedCredentials(for endpoint: DirectHermesEndpoint) -> DirectHermesAccessCredentials? {
        guard let value = load(endpoint.identity) ?? nil, value.canSend(to: endpoint) else { return nil }
        return value
    }

    /// Use these for a host being set up; nil stops using staged values.
    func stage(_ credentials: DirectHermesAccessCredentials?, for endpoint: DirectHermesEndpoint) {
        lock.withLock { staged[endpoint.identity] = credentials }
    }

    /// Saves a staged token once its connection worked.
    func commitStaged(for endpoint: DirectHermesEndpoint) throws {
        let key = endpoint.identity
        if let headers = lock.withLock({ stagedHeaders[key] }) {
            try saveHeaders(headers, key)
            lock.withLock {
                stagedHeaders[key] = nil
                headerCache[key] = headers
            }
        }
        guard let value = lock.withLock({ staged[key] }) else { return }
        try save(value, key)
        lock.withLock {
            staged[key] = nil
            cache[key] = .some(value)
        }
    }

    func remove(for endpoint: DirectHermesEndpoint) {
        let key = endpoint.identity
        SecItemDelete(query(key) as CFDictionary)
        SecItemDelete(query(key, service: headerService) as CFDictionary)
        lock.withLock {
            staged[key] = nil
            cache[key] = .some(nil)
            stagedHeaders[key] = nil
            headerCache[key] = []
        }
    }

    // MARK: Keychain

    private func query(_ account: String, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    /// Readable after the phone's first unlock, never synced or restored to another device.
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    private enum KeychainRead {
        case saved(Data)
        case none
        /// The Keychain refused the read, as it does on a locked phone for an item saved readable only while unlocked.
        case refused
    }

    private func read(_ account: String, service: String, maximumBytes: Int) -> KeychainRead {
        var request = query(account, service: service)
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        var status = SecItemCopyMatching(request as CFDictionary, &result)
        #if DEBUG
        if keychainLockedForTesting { status = errSecInteractionNotAllowed }
        #endif
        if status == errSecItemNotFound { return .none }
        guard status == errSecSuccess, let item = result as? [String: Any] else { return .refused }
        guard let data = item[kSecValueData as String] as? Data, data.count <= maximumBytes else { return .none }
        if item[kSecAttrAccessible as String] as? String != Self.accessibility {
            // Older builds saved items readable only while unlocked. Best effort: it's read again next time.
            _ = SecItemUpdate(query(account, service: service) as CFDictionary,
                              [kSecAttrAccessible as String: Self.accessibility] as CFDictionary)
        }
        return .saved(data)
    }

    /// `nil` when the Keychain refused the read; `.some(nil)` when nothing usable is saved.
    private func load(_ account: String) -> DirectHermesAccessCredentials?? {
        switch read(account, service: service, maximumBytes: 4_096) {
        case .refused: nil
        case .none: .some(nil)
        case .saved(let data): .some(try? JSONDecoder().decode(DirectHermesAccessCredentials.self, from: data))
        }
    }

    /// `nil` when the Keychain refused the read.
    private func loadHeaders(_ account: String) -> [DirectHermesCustomHeader]? {
        switch read(account, service: headerService, maximumBytes: 131_072) {
        case .refused: return nil
        case .none: return []
        case .saved(let data):
            guard let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
            return (try? DirectHermesCustomHeader.list(pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil })) ?? []
        }
    }

    private func saveHeaders(_ headers: [DirectHermesCustomHeader], _ account: String) throws {
        guard !headers.isEmpty else {
            SecItemDelete(query(account, service: headerService) as CFDictionary)
            return
        }
        guard let data = try? JSONEncoder().encode(headers.map { [$0.name, $0.value] }) else {
            throw DirectHermesError.secureStorageUnavailable
        }
        try write(data, query: query(account, service: headerService))
    }

    private func save(_ credentials: DirectHermesAccessCredentials, _ account: String) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { throw DirectHermesError.secureStorageUnavailable }
        try write(data, query: query(account))
    }

    private func write(_ data: Data, query: [String: Any]) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DirectHermesError.secureStorageUnavailable }
    }
}
