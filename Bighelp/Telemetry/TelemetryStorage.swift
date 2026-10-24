import Foundation
import Security

/// The random ID telemetry sends in place of a name. It lives in the Keychain on
/// this device only, is deleted when someone turns telemetry off, and is made
/// again when they turn it back on, so it can't link the two periods.
protocol TelemetryIdentityStore: Sendable {
    func load() -> String?
    /// A new lowercase UUID v4, saved; nil when the Keychain won't take it.
    func create() -> String?
    func delete()
}

struct KeychainTelemetryIdentityStore: TelemetryIdentityStore {
    private let service = "BighelpTelemetry"
    private let account = "install-id"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true,
                                                        kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary,
                                         &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8),
              TelemetryBatchEncoder.isUUIDv4(value) else { return nil }
        return value
    }

    func create() -> String? {
        delete()
        let value = TelemetryBatchEncoder.newID()
        let attributes = query.merging([
            // This device only: never in iCloud Keychain or a backup restored elsewhere.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: Data(value.utf8),
        ]) { $1 }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess ? value : nil
    }

    func delete() {
        SecItemDelete(query.merging([kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]) { $1 } as CFDictionary)
    }
}

/// Events that haven't gone yet, kept so a kill doesn't lose them all.
protocol TelemetryDiskStore: Sendable {
    func load() -> [TelemetryRecord]
    func save(_ records: [TelemetryRecord])
    func delete()
}

/// One small JSON file in Application Support, left out of backups. At most
/// `maximumBytes`; a bigger or damaged file is thrown away.
struct FileTelemetryDiskStore: TelemetryDiskStore {
    static let maximumBytes = 128 * 1_024
    let url: URL

    static var standard: FileTelemetryDiskStore {
        FileTelemetryDiskStore(url: URL.applicationSupportDirectory
            .appending(path: "BighelpTelemetry", directoryHint: .isDirectory).appending(path: "queue.json"))
    }

    func load() -> [TelemetryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard data.count <= Self.maximumBytes, let records = try? JSONDecoder().decode([TelemetryRecord].self, from: data) else {
            delete()
            return []
        }
        return records
    }

    func save(_ records: [TelemetryRecord]) {
        var kept = records
        var data = try? JSONEncoder().encode(kept)
        while let size = data?.count, size > Self.maximumBytes, !kept.isEmpty {
            kept.removeFirst(max(1, kept.count / 4))
            data = try? JSONEncoder().encode(kept)
        }
        guard let data, !kept.isEmpty else { return delete() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var file = url
            try? file.setResourceValues(excluded)
        } catch {}
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
