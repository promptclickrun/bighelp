import Foundation
import Security

struct BighelpManagedEnrollmentRecord: Codable, Equatable {
    let accountScope: String
    let accountID: String
    let hostConnectionID: String
    let profile: String
    /// Exact raw bytes: re-encoding a recovered intent is NOT an idempotent retry.
    var creationBody: Data?
    var enrollmentID: String
    var grant: BighelpManagedGrant?
    var richLiveActivitySupported: Bool
    var enabled: Bool
    var revokePending: Bool
    var subscriptions: Set<String>
    /// Retained historical metadata, never authority for the BuzzKit provider.
    var retiredRelayState: Data? = nil
    /// The sealed-alert key this phone gave the host for this grant.
    var sealedRecipientKeyID: String? = nil
    /// The Peer chats choice the host last confirmed for this grant.
    var peerChatsAlert: Bool? = nil
    /// The workflow alert choices the host last confirmed for this grant.
    var workflowAlertsSent: [String: Bool]? = nil
    /// The Quiet Hours the host last confirmed for this grant, with the time zone sent.
    var quietHoursSent: BighelpQuietHours.Sent? = nil
}

extension BighelpManagedEnrollmentRecord {
    private enum CodingKeys: String, CodingKey {
        case accountScope, accountID, hostConnectionID, profile, creationBody, enrollmentID
        case grant, richLiveActivitySupported, enabled, revokePending, subscriptions, retiredRelayState
        case sealedRecipientKeyID, peerChatsAlert, quietHoursSent, workflowAlertsSent
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountScope = try values.decode(String.self, forKey: .accountScope)
        accountID = try values.decode(String.self, forKey: .accountID)
        hostConnectionID = try values.decode(String.self, forKey: .hostConnectionID)
        profile = try values.decode(String.self, forKey: .profile)
        creationBody = try values.decodeIfPresent(Data.self, forKey: .creationBody)
        enrollmentID = try values.decode(String.self, forKey: .enrollmentID)
        richLiveActivitySupported = try values.decode(Bool.self, forKey: .richLiveActivitySupported)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        revokePending = try values.decode(Bool.self, forKey: .revokePending)
        subscriptions = try values.decode(Set<String>.self, forKey: .subscriptions)
        retiredRelayState = try values.decodeIfPresent(Data.self, forKey: .retiredRelayState)
        sealedRecipientKeyID = try values.decodeIfPresent(String.self, forKey: .sealedRecipientKeyID)
        peerChatsAlert = try values.decodeIfPresent(Bool.self, forKey: .peerChatsAlert)
        workflowAlertsSent = try? values.decodeIfPresent([String: Bool].self, forKey: .workflowAlertsSent)
        quietHoursSent = try? values.decodeIfPresent(BighelpQuietHours.Sent.self, forKey: .quietHoursSent)
        if let raw = try values.decodeIfPresent(BighelpJSONValue.self, forKey: .grant),
           let object = raw.object, Self.isLegacyRelayGrant(object) {
            // The former provider used the same owners-v1 file but a different
            // grant. Preserve it; do not reinterpret it or replay its intent.
            retiredRelayState = try JSONEncoder().encode(BighelpJSONValue(from: decoder))
            grant = nil
            creationBody = nil
            enabled = false
            revokePending = false
        } else {
            grant = try values.decodeIfPresent(BighelpManagedGrant.self, forKey: .grant)
        }
        if retiredRelayState != nil {
            guard grant == nil, creationBody == nil, !enabled, !revokePending else {
                throw DirectHermesError.savedConnectionInvalid
            }
        }
    }

    private static func isLegacyRelayGrant(_ object: [String: BighelpJSONValue]) -> Bool {
        let strings = ["grantId", "hostKeyId", "hostPublicKey", "deviceId", "recipientPublicKey",
                       "recipientKeyId", "profile", "tenantId", "state"]
        let integers = ["recipientRevision", "authorizationEpoch", "createdAt", "expiresAt", "revision"]
        guard Set(object.keys) == Set(strings + integers + ["eventTypes"]),
              strings.allSatisfy({ object[$0]?.string != nil }),
              integers.allSatisfy({ (object[$0]?.integer ?? 0) > 0 }),
              let grantID = object["grantId"]?.string, ManagedNotificationValidation.uuid(grantID),
              let profile = object["profile"]?.string, ManagedNotificationValidation.profile(profile),
              let device = object["deviceId"]?.string, ManagedNotificationValidation.coordinate(device),
              let tenant = object["tenantId"]?.string, ManagedNotificationValidation.coordinate(tenant),
              let state = object["state"]?.string, ["issued", "active", "revoked"].contains(state),
              let created = object["createdAt"]?.integer, let expires = object["expiresAt"]?.integer,
              expires > created, expires - created <= 2_592_000, expires <= 9_999_999_999,
              let events = object["eventTypes"]?.array, !events.isEmpty,
              events.allSatisfy({ $0.string.map(["session.completed", "session.failed", "approval.required"].contains) == true }),
              Set(events.compactMap(\.string)).count == events.count,
              let hostKey = object["hostPublicKey"]?.string, let hostID = object["hostKeyId"]?.string,
              let recipientKey = object["recipientPublicKey"]?.string, let recipientID = object["recipientKeyId"]?.string else {
            return false
        }
        do {
            try ManagedNotificationValidation.publicKey(hostKey, keyID: hostID)
            try ManagedNotificationValidation.publicKey(recipientKey, keyID: recipientID)
            return true
        } catch { return false }
    }
}

struct BighelpManagedActivityOwner: Codable, Equatable {
    let accountScope: String
    let accountID: String
    let hostConnectionID: String
    let grantID: String
    let profile: String
    let storedSessionID: String
    let opaqueSessionID: String
    let nativeActivityID: String
    let relayActivityID: String
    /// Proven host turn only. Projection-generated turn IDs must never go here.
    let canonicalTurnID: String?
    let localTurnID: String
    let firstObservedAt: Int
    var remoteOwned: Bool
    var retired: Bool
}

/// One retained MainActor store per app composition. Atomic protected metadata;
/// no credentials or APNs tokens. Unknown/newer/corrupt snapshots fail closed.
@MainActor
final class BighelpManagedNotificationLedger {
    static var storageRoot: URL {
        URL.applicationSupportDirectory.appending(path: "LoopdyManagedNotifications", directoryHint: .isDirectory)
    }
    private struct Snapshot: Codable {
        var version = 1
        var enrollments: [String: BighelpManagedEnrollmentRecord] = [:]
        var activities: [String: BighelpManagedActivityOwner] = [:]
        /// Original pre-migration file bytes, retained even after fresh enrollment.
        var retiredRelaySnapshot: Data? = nil
    }
    private let root: URL
    private var snapshot: Snapshot
    init(root: URL = BighelpManagedNotificationLedger.storageRoot) throws {
        self.root = root
        if FileManager.default.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw DirectHermesError.savedConnectionInvalid }
        }
        let file = root.appending(path: "owners-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            try Self.requireRegular(file)
            let data = try Data(contentsOf: file)
            guard data.count <= 2_097_152 else { throw DirectHermesError.savedConnectionInvalid }
            var value = try JSONDecoder().decode(Snapshot.self, from: data)
            guard value.version == 1, value.enrollments.count <= 128, value.activities.count <= 256 else {
                throw DirectHermesError.savedConnectionInvalid
            }
            for (key, record) in value.enrollments {
                guard key == Self.key(scope: record.accountScope, host: record.hostConnectionID, profile: record.profile),
                      (record.creationBody?.count ?? 0) <= 16_384, record.subscriptions.count <= 512,
                      ManagedNotificationValidation.uuid(record.enrollmentID) else { throw DirectHermesError.savedConnectionInvalid }
                try record.grant?.validate()
            }
            for (key, owner) in value.activities {
                guard key == owner.relayActivityID, ManagedNotificationValidation.coordinate(key),
                      key == BighelpManagedActivityDriver.relayID(owner.nativeActivityID),
                      owner.opaqueSessionID == "native-" + ManagedNotificationValidation.digest(
                        [owner.accountScope, owner.hostConnectionID, owner.profile, owner.storedSessionID].joined(separator: "\0")),
                      ManagedNotificationValidation.uuid(owner.grantID), ManagedNotificationValidation.profile(owner.profile),
                      ManagedNotificationValidation.coordinate(owner.storedSessionID, maximum: 128),
                      owner.firstObservedAt > 0, owner.firstObservedAt <= 9_999_999_999,
                      !owner.localTurnID.isEmpty, owner.localTurnID.utf8.count <= 512,
                      owner.canonicalTurnID.map({ ManagedNotificationValidation.coordinate($0, maximum: 128) }) ?? true,
                      !owner.nativeActivityID.isEmpty, owner.nativeActivityID.utf8.count <= 512 else {
                    throw DirectHermesError.savedConnectionInvalid
                }
            }
            if value.retiredRelaySnapshot == nil,
               value.enrollments.values.contains(where: { $0.retiredRelayState != nil }) {
                value.retiredRelaySnapshot = data
            }
            snapshot = value
        } else { snapshot = Snapshot() }
    }
    /// Call only after the account eraser has removed storageRoot. This prevents
    /// the retained service from writing an old account's cached rows back later.
    /// Turn off notifications: forget every enrollment and Live Activity owner.
    func erase() throws {
        let file = root.appending(path: "owners-v1.json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        snapshot = Snapshot()
    }
    static func key(scope: String, host: String, profile: String) -> String {
        ManagedNotificationValidation.digest([scope, host, profile].joined(separator: "\0"))
    }
    func record(host: BighelpConfiguredHost, profile: String) -> BighelpManagedEnrollmentRecord? {
        guard let record = snapshot.enrollments[Self.key(scope: host.notificationScope, host: host.hostConnectionID, profile: profile)],
              record.retiredRelayState == nil else { return nil }
        return record
    }
    var enrollments: [BighelpManagedEnrollmentRecord] {
        snapshot.enrollments.values.filter { $0.retiredRelayState == nil }
    }
    var retiredRelayEnrollmentCount: Int {
        snapshot.enrollments.values.filter { $0.retiredRelayState != nil }.count
    }
    var activities: [BighelpManagedActivityOwner] { Array(snapshot.activities.values) }
    func activity(_ relayID: String) -> BighelpManagedActivityOwner? { snapshot.activities[relayID] }
    func save(_ record: BighelpManagedEnrollmentRecord) throws {
        var next = snapshot
        let key = Self.key(scope: record.accountScope, host: record.hostConnectionID, profile: record.profile)
        next.enrollments[key] = record
        try persist(next)
    }
    func save(_ owner: BighelpManagedActivityOwner) throws {
        var next = snapshot
        if let old = next.activities[owner.relayActivityID] {
            guard old.nativeActivityID == owner.nativeActivityID, old.grantID == owner.grantID,
                  old.accountScope == owner.accountScope, old.hostConnectionID == owner.hostConnectionID,
                  old.opaqueSessionID == owner.opaqueSessionID, old.profile == owner.profile,
                  old.storedSessionID == owner.storedSessionID, old.canonicalTurnID == owner.canonicalTurnID,
                  old.localTurnID == owner.localTurnID,
                  !old.retired || owner.retired else { throw DirectHermesError.secureStorageChanged }
        }
        next.activities[owner.relayActivityID] = owner
        try persist(next)
    }
    /// Preserve revocation tombstones even when the host credentials are removed.
    func retire(host: BighelpConfiguredHost) throws {
        var next = snapshot
        for (key, var record) in next.enrollments where record.accountScope == host.notificationScope && record.hostConnectionID == host.hostConnectionID {
            record.enabled = false
            record.revokePending = (record.grant != nil && record.grant?.state != "revoked") || record.creationBody != nil
            next.enrollments[key] = record
        }
        for (key, var owner) in next.activities where owner.accountScope == host.notificationScope && owner.hostConnectionID == host.hostConnectionID {
            owner.retired = true; next.activities[key] = owner
        }
        try persist(next)
    }
    func forgetRetiredActivity(_ id: String) throws {
        guard snapshot.activities[id]?.retired == true else { throw DirectHermesError.secureStorageChanged }
        var next = snapshot; next.activities[id] = nil; try persist(next)
    }
    func pruneExpiredRevocations(accountScope: String, now: Int) throws {
        var next = snapshot
        next.enrollments = next.enrollments.filter { _, record in
            !(record.accountScope == accountScope && record.grant?.state == "revoked" && !record.revokePending && record.creationBody == nil
                && (record.grant?.expiresAt ?? now) < now - 86_400)
        }
        if next.enrollments.count != snapshot.enrollments.count { try persist(next) }
    }
    private func persist(_ next: Snapshot) throws {
        guard next.enrollments.count <= 128, next.activities.count <= 256,
              next.enrollments.values.allSatisfy({ $0.subscriptions.count <= 512 }) else { throw DirectHermesError.tooManyRequests }
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw DirectHermesError.secureStorageChanged }
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        }
        var directory = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let file = root.appending(path: "owners-v1.json")
        if fm.fileExists(atPath: file.path) { try Self.requireRegular(file) }
        let data = try JSONEncoder().encode(next)
        guard data.count <= 2_097_152 else { throw DirectHermesError.messageTooLarge }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        snapshot = next
    }
    private static func requireRegular(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 2_097_152 else {
            throw DirectHermesError.savedConnectionInvalid
        }
    }
}

/// Exact registration/token and pending revocation bytes live only in Keychain.
struct BighelpManagedActivityRequest: Codable, Equatable {
    let owner: BighelpManagedActivityOwner
    var registrationBody: Data
    var coordinatorReference: String
    var pushToken: String
    var revision: Int
    var timestamp: Int
    var leaseExpires: Int
    var pendingRevocationBody: Data?
    var registrationConfirmed: Bool
}

@MainActor
final class BighelpManagedActivityKeychain {
    static let keychainService = "app.loopdy.mobile.managed-notification-activities"
    private let service: String
    init(service: String = BighelpManagedActivityKeychain.keychainService) { self.service = service }
    func load(_ id: String) throws -> BighelpManagedActivityRequest? {
        var query = self.query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 32_768 else {
            throw DirectHermesError.secureStorageUnavailable
        }
        let value = try JSONDecoder().decode(BighelpManagedActivityRequest.self, from: data)
        guard value.owner.relayActivityID == id, value.revision > 0, value.pushToken.utf8.count <= 512 else {
            throw DirectHermesError.savedConnectionInvalid
        }
        return value
    }
    func save(_ value: BighelpManagedActivityRequest) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 32_768 else { throw DirectHermesError.messageTooLarge }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let query = query(value.owner.relayActivityID)
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status != errSecSuccess {
            guard status == errSecDuplicateItem,
                  SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw DirectHermesError.secureStorageUnavailable
            }
        }
        guard try load(value.owner.relayActivityID) == value else { throw DirectHermesError.secureStorageUnavailable }
    }
    func remove(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DirectHermesError.secureStorageUnavailable }
        guard try load(id) == nil else { throw DirectHermesError.secureStorageUnavailable }
    }
    /// Every saved Live Activity registration, for Turn off notifications.
    func removeAll() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: kCFBooleanFalse as Any] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DirectHermesError.secureStorageUnavailable }
    }
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }
}
