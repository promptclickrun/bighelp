import Foundation
import Security

/// A speech server the person runs themselves: where it lives, and the key its handshake carries.
///
/// Both live on the device, not on the computer, so this works against any Hermes host with no
/// plugin support, and the key never crosses the network to the agent. Settings › Voice edits it.
struct SpeechServerConfiguration: Equatable, Sendable {
    let url: URL
    let key: String
    /// Whether the server's own model holds the conversation and hands work to Hermes (the
    /// snappy arrangement), or the server is a voice only and every sentence is a request.
    let converses: Bool
}

enum SpeechServerSettings {
    static let addressKey = "bighelp.voice.speech-server.address"
    static let conversesKey = "bighelp.voice.speech-server.converses"
    static let maximumAddressBytes = 512
    static let maximumKeyBytes = 1_024

    static func configuration(defaults: UserDefaults = .standard,
                              vault: SpeechServerKeyVault = SpeechServerKeyVault()) -> SpeechServerConfiguration? {
        guard let address = defaults.string(forKey: addressKey), let url = serverURL(from: address) else { return nil }
        // A server that has never been told otherwise is assumed to have a model of its own: that is
        // the arrangement worth having, and the one Conduit's local voice uses.
        let converses = defaults.object(forKey: conversesKey) as? Bool ?? true
        return SpeechServerConfiguration(url: url, key: (try? vault.load()) ?? "", converses: converses)
    }

    /// Saves what can be saved. An address that isn't a WebSocket URL is stored as typed so the
    /// field doesn't lose it, but no call starts from it until it is fixed.
    @discardableResult
    static func save(address: String, key: String, converses: Bool? = nil,
                     defaults: UserDefaults = .standard,
                     vault: SpeechServerKeyVault = SpeechServerKeyVault()) -> Bool {
        if let converses { defaults.set(converses, forKey: conversesKey) }
        let trimmed = String(address.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumAddressBytes))
        defaults.set(trimmed, forKey: addressKey)
        // An empty field means "not typed here", never "forget the key": Remove key is its own
        // action, so a Keychain read that failed can't quietly delete what the person saved.
        let trimmedKey = String(key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumKeyBytes))
        if !trimmedKey.isEmpty { try? vault.save(trimmedKey) }
        return serverURL(from: trimmed) != nil
    }

    /// Only an explicit Remove key deletes it.
    static func removeKey(vault: SpeechServerKeyVault = SpeechServerKeyVault()) {
        try? vault.delete()
    }

    /// What a person types, as a WebSocket URL: `ws://box:8765/v1/realtime`, `box:8765` (private
    /// network, so plain `ws://`), or an `http(s)` address copied from a server's own documentation.
    /// Userinfo is refused: a key belongs in the handshake, not in a URL that gets logged.
    static func serverURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= maximumAddressBytes else { return nil }
        if !text.contains("://") { text = "ws://" + text }
        guard var parts = URLComponents(string: text) else { return nil }
        switch parts.scheme?.lowercased() {
        case "ws", "wss": break
        case "http": parts.scheme = "ws"
        case "https": parts.scheme = "wss"
        default: return nil
        }
        guard let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}

/// The server's key in the Keychain, next to the app's other credentials: device-only, and read
/// back before it is trusted.
struct SpeechServerKeyVault {
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private let service: String
    private let account: String

    init(service: String = "app.loopdy.mobile.speech-server", account: String = "current-v1") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              data.count <= SpeechServerSettings.maximumKeyBytes,
              let key = String(data: data, encoding: .utf8) else { throw SpeechServerSettingsError.unavailable }
        return key
    }

    func save(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= SpeechServerSettings.maximumKeyBytes,
              let data = key.data(using: .utf8) else { throw SpeechServerSettingsError.invalidKey }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: Self.accessibility,
                                         kSecAttrSynchronizable as String: false]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (name, value) in attributes { item[name] = value }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw SpeechServerSettingsError.unavailable }
        // Security.framework is external storage: read back the exact value before trusting it.
        guard try load() == key else { throw SpeechServerSettingsError.unavailable }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SpeechServerSettingsError.unavailable }
    }
}

enum SpeechServerSettingsError: Error, LocalizedError {
    case unavailable
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .unavailable: "The speech server's key couldn't be read from this device's Keychain."
        case .invalidKey: "That key can't be saved."
        }
    }
}
