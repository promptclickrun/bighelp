import CryptoKit
import Foundation
import Security

/// Device-local trust accepted during authenticated account-to-host enrollment.
/// Never decoded from a push payload or treated as permission to execute a task.
struct BighelpNotificationHostGrant: Codable, Equatable, Sendable {
    let accountID: String
    let hostConnectionID: String
    let grantID: String
    let tenantID: String
    let deviceID: String
    let profileID: String
    let hostKeyID: String
    let hostPublicKey: String
    let createdAt: Int
    let expiresAt: Int
    let revision: Int
    let eventTypes: [String]

    init(accountID: String, hostConnectionID: String, grantID: String, tenantID: String, deviceID: String,
         profileID: String, hostKeyID: String, hostPublicKey: String, createdAt: Int, expiresAt: Int,
         revision: Int, eventTypes: [String] = ["session.completed", "session.failed"]) {
        self.accountID = accountID; self.hostConnectionID = hostConnectionID; self.grantID = grantID
        self.tenantID = tenantID; self.deviceID = deviceID; self.profileID = profileID
        self.hostKeyID = hostKeyID; self.hostPublicKey = hostPublicKey
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.revision = revision
        self.eventTypes = eventTypes
    }

    func validate() throws {
        guard Self.coordinate(accountID), Self.coordinate(hostConnectionID),
              Self.coordinate(tenantID), Self.coordinate(deviceID), Self.coordinate(profileID),
              UUID(uuidString: grantID)?.uuidString.lowercased() == grantID,
              createdAt > 0, expiresAt > createdAt,
              expiresAt <= 9_999_999_999, expiresAt - createdAt <= 2_678_400,
              revision > 0, revision <= 9_007_199_254_740_991,
              !eventTypes.isEmpty, Set(eventTypes).count == eventTypes.count,
              Set(eventTypes).isSubset(of: ["session.completed", "session.failed", "approval.required"]),
              let publicBytes = BighelpNotificationBase64URL.decodeCanonical(hostPublicKey),
              publicBytes.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: publicBytes)) != nil,
              BighelpNotificationBase64URL.encode(Data(SHA256.hash(data: publicBytes))) == hostKeyID
        else { throw BighelpRelayTrustError.invalidSenderKeySet }
    }

    func matches(tenantID: String, deviceID: String, senderKeyID: String, issuedAt: Int) -> Bool {
        (try? validate()) != nil && self.tenantID == tenantID && self.deviceID == deviceID
            && hostKeyID == senderKeyID && createdAt <= issuedAt && issuedAt <= expiresAt
    }

    func authorizes(tenantID: String, deviceID: String, senderKeyID: String,
                    issuedAt: Int, eventID: String, eventType: String = "session.completed") -> Bool {
        let prefix = grantID + ":"
        guard eventID.hasPrefix(prefix) else { return false }
        let digest = eventID.dropFirst(prefix.count)
        return digest.utf8.count == 64
            && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && matches(tenantID: tenantID, deviceID: deviceID, senderKeyID: senderKeyID, issuedAt: issuedAt)
            && eventTypes.contains(eventType)
    }

    private static func coordinate(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 180 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || [45, 46, 58, 95].contains($0)
        }
    }
}

protocol BighelpNotificationHostTrustLoading: AnyObject {
    func load() throws -> [BighelpNotificationHostGrant]
}

/// Shares public trust material with the notification extension using the
/// existing device-only notification Keychain group, not App Group preferences.
final class BighelpNotificationHostTrustStore: BighelpNotificationHostTrustLoading {
    private struct Snapshot: Codable {
        let version: Int
        let grants: [BighelpNotificationHostGrant]
    }
    static let keychainService = "app.loopdy.mobile.notification-host-trust"
    private static let mutationLock = NSLock()
    private let accessGroup: String?
    private let service: String
    private let keychainAccount = "host-grants-v1"

    init(accessGroup: String? = BighelpNotificationKeychainAccess.group,
         service: String = BighelpNotificationHostTrustStore.keychainService) {
        self.accessGroup = accessGroup
        self.service = service
    }

    func load() throws -> [BighelpNotificationHostGrant] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BighelpRelayTrustError.keychain(status)
        }
        guard data.count <= 262_144,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1, snapshot.grants.count <= 128,
              Set(snapshot.grants.map(\.grantID)).count == snapshot.grants.count else {
            throw BighelpRelayTrustError.invalidSenderKeySet
        }
        for grant in snapshot.grants { try grant.validate() }
        return snapshot.grants
    }

    func upsert(_ grant: BighelpNotificationHostGrant) throws {
        try grant.validate()
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        var grants = try load()
        if let index = grants.firstIndex(where: { $0.grantID == grant.grantID }) {
            let old = grants[index]
            if old == grant { return }
            guard old.accountID == grant.accountID, old.hostConnectionID == grant.hostConnectionID,
                  old.tenantID == grant.tenantID, old.deviceID == grant.deviceID,
                  old.profileID == grant.profileID, old.hostKeyID == grant.hostKeyID,
                  old.hostPublicKey == grant.hostPublicKey, grant.revision > old.revision else {
                throw BighelpRelayTrustError.invalidSenderKeySet
            }
            grants[index] = grant
        } else {
            guard grants.count < 128 else { throw BighelpRelayTrustError.invalidSenderKeySet }
            grants.append(grant)
        }
        try save(grants)
    }

    func remove(accountID: String) throws {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let original = try load()
        let filtered = original.filter { $0.accountID != accountID }
        if original != filtered { try save(filtered) }
    }

    func remove(grantID: String, accountID: String) throws {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let original = try load()
        let filtered = original.filter { !($0.accountID == accountID && $0.grantID == grantID) }
        if original != filtered { try save(filtered) }
    }

    func removeAll() throws {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BighelpRelayTrustError.keychain(status)
        }
    }

    private func save(_ grants: [BighelpNotificationHostGrant]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(Snapshot(version: 1, grants: grants))
        guard data.count <= 262_144 else { throw BighelpRelayTrustError.invalidSenderKeySet }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw BighelpRelayTrustError.keychain(status) }
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        guard updated == errSecSuccess else { throw BighelpRelayTrustError.keychain(updated) }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
