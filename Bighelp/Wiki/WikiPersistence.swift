import Foundation

struct WikiLocalState: Codable, Sendable {
    let owner: WikiOwner
    var connections: [WikiConnection]
    var saves: [WikiPendingSave]
}

/// Inert selection only: never a grant, document, token or operation journal.
struct WikiFolderPreference: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let folderPath: String
    /// Nil for legacy choices; a new explicit read-only choice survives reconnect.
    var readOnly: Bool? = nil
}

struct WikiPreferenceScope: Codable, Equatable, Sendable {
    let accountID: String
    let hostID: String
    let profileID: String
    init(_ owner: WikiOwner) {
        accountID = owner.accountID; hostID = owner.hostID; profileID = owner.profileID
    }
}

private struct WikiFolderPreferences: Codable {
    let scope: WikiPreferenceScope
    let folders: [WikiFolderPreference]
}

@MainActor
protocol WikiPersistence {
    func load(owner: WikiOwner) throws -> WikiLocalState?
    func save(_ state: WikiLocalState) throws
    func deleteAccount(accountID: String) throws
    func loadFolders(owner: WikiOwner) throws -> [WikiFolderPreference]
    func saveFolders(_ folders: [WikiFolderPreference], owner: WikiOwner) throws
    func signOut(accountID: String) throws
}

extension WikiPersistence {
    func signOut(accountID: String) throws { try deleteAccount(accountID: accountID) }
}

/// Lazy, OS-protected local state, never a credential store or a host path.
/// No I/O at initialization. Call restoreLocalState only on explicit Wiki use.
@MainActor
final class WikiLocalPersistence: WikiPersistence {
    private let directory: URL?
    private let preferencesDirectory: URL?
    private let protector: any BighelpLocalFileProtecting
    private let availability: any BighelpProtectedDataAvailabilityProviding
    private let maximumBytes = 40 * 1_024 * 1_024

    init(directory: URL? = nil, preferencesDirectory: URL? = nil,
         protector: any BighelpLocalFileProtecting = BighelpLocalFileProtector(),
         availability: any BighelpProtectedDataAvailabilityProviding = BighelpSystemProtectedDataAvailability()) {
        self.directory = directory
        self.preferencesDirectory = preferencesDirectory ?? directory?.appendingPathComponent("Preferences", isDirectory: true)
        self.protector = protector
        self.availability = availability
    }

    private func baseDirectory() throws -> URL {
        if let directory { return directory }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: false)
            .appendingPathComponent("Wiki", isDirectory: true)
    }

    private func accountDirectory(_ accountID: String) throws -> URL {
        try baseDirectory().appendingPathComponent(WikiLimits.digest(Data(accountID.utf8)), isDirectory: true)
    }

    private func file(_ owner: WikiOwner) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try accountDirectory(owner.accountID)
            .appendingPathComponent(WikiLimits.digest(encoder.encode(owner)) + ".json")
    }

    func load(owner: WikiOwner) throws -> WikiLocalState? {
        try requireBighelpProtectedData(availability)
        let url = try file(owner)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= maximumBytes else { throw WikiError.quota }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw WikiError.quota }
        let state = try JSONDecoder().decode(WikiLocalState.self, from: data)
        try validate(state)
        guard state.owner == owner else { throw WikiError.ownerChanged }
        return state
    }

    func save(_ state: WikiLocalState) throws {
        try requireBighelpProtectedData(availability)
        try validate(state)
        let data = try JSONEncoder().encode(state)
        guard data.count <= maximumBytes else { throw WikiError.quota }
        let url = try file(state.owner)
        try protector.prepareDirectory(url.deletingLastPathComponent(), protection: .privateVisual,
                                       fileManager: .default)
        let siblings = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                  includingPropertiesForKeys: [.fileSizeKey])
        guard siblings.count <= 64 else { throw WikiError.quota }
        var aggregateBytes = data.count
        for sibling in siblings where sibling != url {
            let size = try sibling.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumBytes
            guard size >= 0, size <= maximumBytes - aggregateBytes else { throw WikiError.quota }
            aggregateBytes += size
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent("pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try protector.write(data, to: temporary, protection: .privateVisual)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private func validate(_ state: WikiLocalState) throws {
        guard state.owner.isValid, state.connections.count <= WikiLimits.maxConnections,
              state.saves.count <= WikiLimits.maxPendingSaves,
              Set(state.connections.map(\.id)).count == state.connections.count,
              Set(state.saves.map(\.id)).count == state.saves.count,
              state.connections.allSatisfy({ $0.owner == state.owner }),
              state.saves.allSatisfy({
                  $0.document.owner == state.owner && $0.document.connection.owner == state.owner
                      && $0.document.originalBytes.count <= WikiLimits.editBytes
                      && Data($0.document.originalSource.utf8) == $0.document.originalBytes
                      && $0.bytes.count <= WikiLimits.editBytes && WikiLimits.digest($0.bytes) == $0.sha256
              }) else { throw WikiError.invalidResponse }
    }

    private func preferenceAccountDirectory(_ accountID: String) throws -> URL {
        let base: URL
        if let preferencesDirectory { base = preferencesDirectory }
        else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false).appendingPathComponent("LoopdyWikiPreferences", isDirectory: true)
        }
        return base.appendingPathComponent(WikiLimits.digest(Data(accountID.utf8)), isDirectory: true)
    }

    private func preferenceFile(_ owner: WikiOwner) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try preferenceAccountDirectory(owner.accountID).appendingPathComponent(
            "folders-" + WikiLimits.digest(encoder.encode(WikiPreferenceScope(owner))) + ".json")
    }

    private func accountFiles(_ accountID: String) throws -> [URL] {
        let directory = try accountDirectory(accountID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        // The live writer's scope quota must never prevent migration or cleanup
        // of existing history. Callers decode only one byte-bounded file at a time.
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
    }

    private func boundedData(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { throw WikiError.quota }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw WikiError.quota }
        return data
    }

    func loadFolders(owner: WikiOwner) throws -> [WikiFolderPreference] {
        try requireBighelpProtectedData(availability)
        guard owner.isValid else { throw WikiError.ownerChanged }
        let url = try preferenceFile(owner)
        if FileManager.default.fileExists(atPath: url.path) {
            let value = try JSONDecoder().decode(WikiFolderPreferences.self, from: boundedData(url, limit: 256 * 1_024))
            guard value.scope == WikiPreferenceScope(owner) else { throw WikiError.ownerChanged }
            try validateFolders(value.folders)
            return value.folders
        }
        // Migrate the newest matching authority snapshot once. An empty preferences
        // file is a tombstone: removed selections can never resurrect from old epochs.
        let files = try accountFiles(owner.accountID).filter { !$0.lastPathComponent.hasPrefix("folders-") && $0.pathExtension == "json" }
        let sorted = try files.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var folders: [WikiFolderPreference] = []
        for (file, _) in sorted {
            let state = try JSONDecoder().decode(WikiLocalState.self, from: boundedData(file, limit: maximumBytes))
            try validate(state)
            guard WikiPreferenceScope(state.owner) == WikiPreferenceScope(owner) else { continue }
            folders = folderPreferences(from: state)
            break
        }
        try saveFolders(folders, owner: owner)
        return folders
    }

    private func folderPreferences(from state: WikiLocalState) -> [WikiFolderPreference] {
        var paths = Set<String>()
        return state.connections.compactMap {
            guard let path = $0.root.folderPath, paths.insert(path).inserted else { return nil }
            return WikiFolderPreference(id: $0.id, name: $0.name, folderPath: path)
        }
    }

    private func validateFolders(_ folders: [WikiFolderPreference]) throws {
        guard folders.count <= WikiLimits.maxConnections,
              Set(folders.map(\.id)).count == folders.count,
              Set(folders.map(\.folderPath)).count == folders.count else { throw WikiError.quota }
        for folder in folders {
            try WikiLimits.validateFolderPath(folder.folderPath)
            guard !folder.name.isEmpty, folder.name.utf8.count <= 256 else { throw WikiError.invalidPath }
        }
    }

    func saveFolders(_ folders: [WikiFolderPreference], owner: WikiOwner) throws {
        try requireBighelpProtectedData(availability)
        guard owner.isValid else { throw WikiError.ownerChanged }
        try validateFolders(folders)
        let url = try preferenceFile(owner)
        let data = try JSONEncoder().encode(WikiFolderPreferences(scope: WikiPreferenceScope(owner), folders: folders))
        guard data.count <= 256 * 1_024 else { throw WikiError.quota }
        // Preferences are inert and bounded per scope, not by lifetime scope count.
        // A 65th retained host/profile must not strand account cleanup or migration.
        try protector.prepareDirectory(url.deletingLastPathComponent(), protection: .privateVisual, fileManager: .default)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try protector.write(data, to: temporary, protection: .privateVisual)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: url) }
    }

    func signOut(accountID: String) throws {
        try requireBighelpProtectedData(availability)
        let files = try accountFiles(accountID).filter { !$0.lastPathComponent.hasPrefix("folders-") }
        // Preserve newest choices from every host/profile before erasing any
        // journals. Sort metadata once; never retain decoded history in memory.
        let sorted = try files.filter { $0.pathExtension == "json" }.map {
            ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (file, _) in sorted {
            let state = try JSONDecoder().decode(WikiLocalState.self, from: boundedData(file, limit: maximumBytes))
            try validate(state)
            guard state.owner.accountID == accountID else { throw WikiError.ownerChanged }
            if FileManager.default.fileExists(atPath: try preferenceFile(state.owner).path) {
                // Validate existing choices, including intentional empty tombstones.
                _ = try loadFolders(owner: state.owner)
            } else {
                try saveFolders(folderPreferences(from: state), owner: state.owner)
            }
        }
        for file in files { try FileManager.default.removeItem(at: file) }
    }

    /// Explicit account deletion only; disconnecting a host does not discard drafts.
    func deleteAccount(accountID: String) throws {
        try requireBighelpProtectedData(availability)
        for url in [try accountDirectory(accountID), try preferenceAccountDirectory(accountID)] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
