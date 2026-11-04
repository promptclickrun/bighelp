import CryptoKit
import Foundation
import Security

enum BighelpRelayTrustError: Error, Equatable {
    case invalidSenderKey
    case invalidSenderKeySet
    case keychain(OSStatus)
}

protocol BighelpNotificationRecipientKeyLoading: AnyObject {
    func load() throws -> Data?
}

final class BighelpNotificationRecipientKeyStore: BighelpNotificationRecipientKeyLoading {
    private let accessGroup: String?
    /// The content key for sealed notifications (managed alerts v2).
    static let sealedAlertAccount = "sealed-alerts-p256-v2"
    private let service = "app.loopdy.mobile.link-push"
    private let account: String

    init(accessGroup: String? = BighelpNotificationKeychainAccess.group, account: String = "p256-agreement-v1") {
        self.accessGroup = accessGroup
        self.account = account
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BighelpRelayTrustError.keychain(status)
        }
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BighelpRelayTrustError.keychain(status)
        }
        return data
    }

    func save(_ value: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemAdd(
            baseQuery.merging(attributes) { _, replacement in replacement } as CFDictionary,
            nil
        )
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else {
            throw BighelpRelayTrustError.keychain(status)
        }
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        guard updated == errSecSuccess else {
            throw BighelpRelayTrustError.keychain(updated)
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

enum BighelpNotificationKeychainAccess {
    static var group: String? {
        Bundle.main.object(forInfoDictionaryKey: "BighelpNotificationKeychainGroup") as? String
    }
}

enum BighelpNotificationBase64URL {
    static func encode(_ value: Data) -> String {
        value.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeCanonical(_ value: String) -> Data? {
        guard
            !value.isEmpty,
            value.count % 4 != 1,
            value.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            })
        else { return nil }
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard
            let decoded = Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)),
            encode(decoded) == value
        else { return nil }
        return decoded
    }
}
