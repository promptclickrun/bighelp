import Foundation
import Security

@MainActor
protocol DirectHermesCredentialVault {
    func load() throws -> DirectHermesSavedConnection?
    func save(_ connection: DirectHermesSavedConnection) throws
    func delete() throws
}

/// One immutable account/host coordinate, separate from every Link account key.
/// Production passes a scoped item name; the legacy default remains for direct
/// protocol harnesses. Endpoint and verified principal live with access/refresh
/// credentials. Items never synchronize, join an extension group, or migrate in
/// backups. Retired account owners cannot write them again.
@MainActor
final class DirectHermesKeychainVault: DirectHermesCredentialVault {
    private let service: String
    private let account: String
    private var isValid = true
    private var expectedIdentity: String?
    private var stagesUntilCommit = false
    private var stagedConnection: DirectHermesSavedConnection?
    private(set) var requiresRegistryReference = false

    func bindIdentity(_ identity: String) throws {
        guard expectedIdentity == nil || DirectHermesIdentity.matches(expectedIdentity, identity) else { throw DirectHermesError.identityChanged }
        expectedIdentity = identity
    }

    /// Retired owners cannot recreate credentials after account erasure.
    func invalidate() { isValid = false; stagedConnection = nil }
    private let maximumRecordBytes = 65_536
    /// Readable after the phone's first unlock, so a wake from the host's plugin can renew
    /// a rotating sign-in while the phone is locked. Still this device only, never synced.
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    /// Older builds saved sign-ins readable only while unlocked; they move over when read.
    private static let unlockedOnly = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    init() { service = "app.loopdy.mobile.direct-hermes"; account = "standalone-current-v1" }

    /// Allows focused checks to use a distinct, explicitly named Keychain service.
    init(service: String, account: String = "standalone-current-v1", expectedIdentity: String? = nil, stagesUntilCommit: Bool = false) {
        self.service = service
        self.account = account
        self.expectedIdentity = expectedIdentity
        self.stagesUntilCommit = stagesUntilCommit
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> DirectHermesSavedConnection? {
        guard isValid else { throw DirectHermesError.secureStorageChanged }
        if stagesUntilCommit { return stagedConnection }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              data.count <= maximumRecordBytes,
              let accessible = item[kSecAttrAccessible as String] as? String,
              [Self.accessibility, Self.unlockedOnly].contains(accessible),
              (item[kSecAttrSynchronizable as String] as? Bool ?? false) == false else {
            throw DirectHermesError.secureStorageUnavailable
        }
        if accessible == Self.unlockedOnly {
            // Best effort: it's read again next time if this doesn't take.
            _ = SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: Self.accessibility] as CFDictionary)
        }
        guard let connection = try? JSONDecoder().decode(DirectHermesSavedConnection.self, from: data) else {
            throw DirectHermesError.savedConnectionInvalid
        }
        try connection.validate()
        guard expectedIdentity == nil || DirectHermesIdentity.matches(connection.identity, expectedIdentity) else { throw DirectHermesError.identityChanged }
        return connection
    }

    func save(_ connection: DirectHermesSavedConnection) throws {
        guard isValid else { throw DirectHermesError.secureStorageChanged }
        try connection.validate()
        guard expectedIdentity == nil || DirectHermesIdentity.matches(connection.identity, expectedIdentity) else { throw DirectHermesError.identityChanged }
        let data: Data
        do { data = try JSONEncoder().encode(connection) }
        catch { throw DirectHermesError.savedConnectionInvalid }
        guard data.count <= maximumRecordBytes else { throw DirectHermesError.savedConnectionInvalid }
        if stagesUntilCommit { stagedConnection = connection; return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility,
            kSecAttrSynchronizable as String: false
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw DirectHermesError.secureStorageUnavailable }
        // Security.framework is external storage: read back the exact item before
        // accepting rotation, rather than trusting an OSStatus alone.
        guard try load() == connection else { throw DirectHermesError.secureStorageUnavailable }
    }

    /// Promote only after the verified host has a durable registry entry.
    /// This keeps authentication attempts out of Keychain, including rotations.
    func commitStagedCredentials() throws {
        guard isValid else { throw DirectHermesError.secureStorageChanged }
        guard stagesUntilCommit else { return }
        guard let connection = stagedConnection else { throw DirectHermesError.savedConnectionInvalid }
        stagesUntilCommit = false
        requiresRegistryReference = true
        do { try save(connection) }
        catch {
            let persistenceError = error
            // A failed readback may follow a successful write. Delete before
            // allowing the registry to roll its reference back.
            do { try delete(); requiresRegistryReference = false }
            catch { stagesUntilCommit = true; throw error }
            stagesUntilCommit = true
            throw persistenceError
        }
        stagedConnection = nil
    }

    /// Erases all entries for one account, including an interrupted setup whose
    /// credential was written before its host metadata could be committed.
    static func deleteAccountScope(service: String, scope: String) throws {
        let prefix = "host-v1.\(scope)."
        var list: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        list[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(list as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw DirectHermesError.secureStorageUnavailable
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { continue }
            try DirectHermesKeychainVault(service: service, account: account).delete()
        }
    }

    func delete() throws {
        if stagesUntilCommit && !requiresRegistryReference { stagedConnection = nil; return }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DirectHermesError.secureStorageUnavailable
        }
        let wasStaging = stagesUntilCommit
        stagesUntilCommit = false
        defer { stagesUntilCommit = wasStaging }
        guard try load() == nil else { throw DirectHermesError.secureStorageUnavailable }
        stagedConnection = nil
        requiresRegistryReference = false
    }
}
