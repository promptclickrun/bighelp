import Foundation
import Security

/// The sign-in a share sends with, copied by the app into the Keychain group it
/// already shares with its notification extension.
///
/// The app's own sign-in record is deliberately outside every group
/// (`DirectHermesCredentialVault`), so a share extension cannot read it. This copy is
/// read-only from here: the extension never renews and never writes it back, because
/// the rotating refresh token in it belongs to the app, and a rotation performed here
/// would leave the app holding a token the host has already spent.
struct ShareCredential: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// `Authorization: Bearer …`, plus a single-use socket ticket.
        case bearer
        /// A dashboard session token, used as the socket's `token` query item.
        case dashboard
    }

    var kind: Kind
    var baseURL: String
    var allowPrivateHTTP: Bool
    var accessToken: String?
    var refreshToken: String?
    var provider: String?
    var userID: String?

    static let service = "app.loopdy.mobile.share-send"
    static let account = "connection-v1"
    static let maximumBytes = 65_536

    /// Resolved by the build from the entitlement (`$(AppIdentifierPrefix)…`), which is
    /// why it is read out of the Info.plist rather than written here as a literal.
    static var keychainGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "BighelpNotificationKeychainGroup") as? String
    }

    static func load() -> ShareCredential? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let group = keychainGroup { query[kSecAttrAccessGroup as String] = group }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count <= maximumBytes,
              let record = try? JSONDecoder().decode(ShareCredential.self, from: data) else { return nil }
        return record
    }
}
