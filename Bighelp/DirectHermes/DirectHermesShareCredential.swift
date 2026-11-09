import Foundation
import Security

/// The narrower copy of the sign-in that the share extension sends with.
///
/// The app's own record is deliberately outside every Keychain group so that no extension
/// can read it. A share sheet has no other way to authenticate, so this writes a second
/// item into the group the app already shares with its notification extension — an
/// existing group, so nothing new has to be registered for the new bundle ID. It holds
/// only what one send needs.
///
/// The extension reads it and never writes it back. A rotation performed from the sheet
/// would spend the app's rotating refresh token and leave the app signed out, so the app
/// owns this item entirely and re-copies it on every save and rotation.
enum DirectHermesShareCredential {
    static let primaryService = "app.loopdy.mobile.direct-hermes"
    static let service = "app.loopdy.mobile.share-send"
    static let account = "connection-v1"
    private static let maximumBytes = 65_536

    /// Mirrors `ShareCredential` in the BighelpShare target. The two are separate
    /// targets, so the shape is duplicated on purpose — it is the whole wire between them.
    private struct Record: Codable {
        enum Kind: String, Codable { case bearer, dashboard }
        let kind: Kind
        let baseURL: String
        let allowPrivateHTTP: Bool
        let accessToken: String?
        let refreshToken: String?
        let provider: String?
        let userID: String?
    }

    /// Resolved by the build from `keychain-access-groups` (`$(AppIdentifierPrefix)…`).
    private static var group: String? {
        Bundle.main.object(forInfoDictionaryKey: "BighelpNotificationKeychainGroup") as? String
    }

    /// Called from the vault's save so a rotated sign-in reaches the sheet too.
    static func store(_ connection: DirectHermesSavedConnection) {
        // An unsigned simulator copy has no group and no extension to serve.
        guard let group, let record = record(for: connection),
              let data = try? JSONEncoder().encode(record), data.count <= maximumBytes else { return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The sheet can run while the phone is locked, like the notification extension.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            kSecAttrSynchronizable as String: false,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                _ = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        // Best effort: a share simply asks the person to open the app when this did not take.
    }

    static func clear() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func record(for connection: DirectHermesSavedConnection) -> Record? {
        switch connection.authentication {
        case .bearer(let accessToken, let refreshToken, _):
            return Record(kind: .bearer, baseURL: connection.endpoint.baseURL.absoluteString,
                          allowPrivateHTTP: connection.endpoint.allowPrivateHTTP,
                          accessToken: accessToken, refreshToken: refreshToken,
                          provider: connection.provider, userID: connection.userID)
        case .dashboardSession(let token, _):
            return Record(kind: .dashboard, baseURL: connection.endpoint.baseURL.absoluteString,
                          allowPrivateHTTP: connection.endpoint.allowPrivateHTTP,
                          accessToken: token, refreshToken: nil,
                          provider: connection.provider, userID: connection.userID)
        case .legacyLoopbackToken(let token):
            // A loopback token is also the socket's `token` query item, so the sheet reads
            // it the same way as a dashboard session.
            return Record(kind: .dashboard, baseURL: connection.endpoint.baseURL.absoluteString,
                          allowPrivateHTTP: connection.endpoint.allowPrivateHTTP,
                          accessToken: token, refreshToken: nil,
                          provider: connection.provider, userID: connection.userID)
        }
    }
}
