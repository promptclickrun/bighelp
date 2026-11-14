import Foundation
import Darwin

extension URL {
    var bighelpFileSystemPath: String {
        path(percentEncoded: false)
    }
}

/// Repository authority changes only after the previous host's in-memory
/// stores have been cleared. This prevents teardown persistence from following
/// `selectedHostID` early and writing old-host state into the new host's files.
final class BighelpHostRepositoryScope {
    var hostID: String?

    init(hostID: String? = nil) {
        self.hostID = hostID
    }
}

enum DemoRepositoryError: Error, Equatable {
    case invalidSchemaVersion(Int)
    case unsupportedSchemaVersion(found: Int, current: Int)
    case missingMigration(fromVersion: Int)
    case migrationFailed(fromVersion: Int)
    case missingScope
    case staleFileSnapshot
}

/// Constructed only by the typed encoder or after strict raw-byte validation.
struct DemoRepositoryPreparedEncoding: Sendable {
    fileprivate let data: Data
    fileprivate let schemaVersion: Int
    var byteCount: Int { data.count }
}

private struct DemoRepositoryFileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    static func read(_ url: URL) throws -> Self? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &value) } ?? -2
        }
        if result != 0 {
            if result == -1, errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        guard value.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        return Self(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                    modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
                    changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
    }
}

private struct DemoRepositoryFileWitness: Sendable {
    let identity: DemoRepositoryFileIdentity?
    let schemaVersion: Int?

    private struct Version: Decodable { let schemaVersion: Int }

    static func read(_ url: URL) throws -> Self {
        guard let before = try DemoRepositoryFileIdentity.read(url) else {
            return Self(identity: nil, schemaVersion: nil)
        }
        let version = try JSONDecoder().decode(Version.self, from: Data(contentsOf: url)).schemaVersion
        guard try DemoRepositoryFileIdentity.read(url) == before else {
            throw DemoRepositoryError.staleFileSnapshot
        }
        return Self(identity: before, schemaVersion: version)
    }

    func validate(at url: URL, currentVersion: Int) throws {
        guard try DemoRepositoryFileIdentity.read(url) == identity else {
            throw DemoRepositoryError.staleFileSnapshot
        }
        if let schemaVersion {
            guard schemaVersion >= 0 else { throw DemoRepositoryError.invalidSchemaVersion(schemaVersion) }
            guard schemaVersion <= currentVersion else {
                throw DemoRepositoryError.unsupportedSchemaVersion(found: schemaVersion, current: currentVersion)
            }
        }
    }
}

/// Transforms one repository envelope version into the next before Codable decoding.
struct DemoRepositoryMigration {
    let fromVersion: Int
    let migrate: ([String: Any]) throws -> [String: Any]
}

final class DemoRepository<Value: Codable> {
    private struct CheckpointHandle: Codable {
        let kind: String
        let id: UUID
    }

    private struct PreparedCheckpoint {
        let id: UUID
        let epoch: UUID
        let url: URL
        let encoding: DemoRepositoryPreparedEncoding
        let previous: DemoRepositoryFileWitness
    }

    private var checkpointEpoch = UUID()
    private var preparedCheckpoint: PreparedCheckpoint?
    /// The file as this repository last wrote it, or last read it without changing it. While
    /// that same file is on disk its schema version is known, so a save need not read the
    /// whole file back to check it: a catalog of thousands of chats is megabytes.
    private var knownFile: DemoRepositoryFileWitness?

    /// Whether the file on disk is still the one this repository last wrote or read.
    var holdsKnownFile: Bool {
        guard let identity = knownFile?.identity, let url = try? resolvedFileURL() else { return false }
        return (try? DemoRepositoryFileIdentity.read(url)) == identity
    }
    private struct Envelope<Payload: Codable>: Codable {
        let schemaVersion: Int
        let value: Payload
    }

    private struct EnvelopeVersion: Decodable {
        let schemaVersion: Int
    }

    var avatarsDirectory: URL {
        (try? resolvedDirectory())?.appending(
            path: "\(name)-avatars",
            directoryHint: .isDirectory
        ) ?? directory.appending(
            path: "unavailable-\(name)-avatars",
            directoryHint: .isDirectory
        )
    }

    /// The folder this repository's file is in, for an owner that keeps sibling files there.
    func scopedDirectory() throws -> URL {
        try resolvedDirectory()
    }

    func scopedAvatarsDirectory() throws -> URL {
        try resolvedDirectory().appending(
            path: "\(name)-avatars",
            directoryHint: .isDirectory
        )
    }
    private(set) var lastRecoveryBackupURL: URL?
    private(set) var lastRecoveryErrorMessage: String?

    private let directory: URL
    private let name: String
    private let seed: Value
    private let fileManager: FileManager
    private let fileProtection: any BighelpLocalFileProtecting
    private let protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding
    private let migrationsByVersion: [Int: DemoRepositoryMigration]
    private let scopeID: (() -> String?)?
    let currentSchemaVersion: Int

    init(
        directory: URL,
        name: String,
        seed: Value,
        fileManager: FileManager = .default,
        fileProtection: any BighelpLocalFileProtecting = BighelpLocalFileProtector(),
        protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding = BighelpSystemProtectedDataAvailability(),
        migrations: [DemoRepositoryMigration] = [],
        scopeID: (() -> String?)? = nil,
        currentSchemaVersion: Int = 1
    ) {
        precondition(currentSchemaVersion > 0)
        self.directory = directory
        self.name = name
        self.seed = seed
        self.fileManager = fileManager
        self.fileProtection = fileProtection
        self.protectedDataAvailability = protectedDataAvailability
        self.scopeID = scopeID
        self.currentSchemaVersion = currentSchemaVersion
        var migrationsByVersion = [
            0: DemoRepositoryMigration(fromVersion: 0) { $0 }
        ]
        for migration in migrations {
            migrationsByVersion[migration.fromVersion] = migration
        }
        self.migrationsByVersion = migrationsByVersion
    }

    /// A sibling uses the same scope and protected-file policy. Callers choose
    /// fixed names (never raw session IDs) and commit their manifest last.
    func child<Child: Codable>(name: String, seed: Child) -> DemoRepository<Child> {
        DemoRepository<Child>(
            directory: directory, name: name, seed: seed, fileManager: fileManager,
            fileProtection: fileProtection, protectedDataAvailability: protectedDataAvailability,
            migrations: Array(migrationsByVersion.values), scopeID: scopeID,
            currentSchemaVersion: currentSchemaVersion
        )
    }

    /// Capture this before preparing an asynchronous checkpoint and validate it
    /// again before adoption. It also partitions in-memory caches by host.
    func storageScopeIdentifier() throws -> String {
        _ = try resolvedDirectory() // Validate the same host authority as writes.
        return scopeID?().map { "host:\($0)" } ?? "unscoped"
    }

    /// Unlike load(), this read never creates a seed, migrates in place, or
    /// recovers by replacing an unreadable source. Used for immutable content
    /// and non-destructive adoption of the legacy session repository.
    func loadExistingPreservingSource() throws -> Value? {
        try loadExistingPreservingSourceWithByteCount()?.value
    }

    func loadExistingPreservingSourceWithByteCount() throws -> (value: Value, byteCount: Int)? {
        try requireBighelpProtectedData(protectedDataAvailability)
        let fileURL = try resolvedFileURL()
        guard fileManager.fileExists(atPath: fileURL.bighelpFileSystemPath) else { return nil }
        let identity = try? DemoRepositoryFileIdentity.read(fileURL)
        let data = try Data(contentsOf: fileURL)
        let version = try JSONDecoder().decode(EnvelopeVersion.self, from: data).schemaVersion
        guard version >= 0 else { throw DemoRepositoryError.invalidSchemaVersion(version) }
        guard version <= currentSchemaVersion else {
            throw DemoRepositoryError.unsupportedSchemaVersion(found: version, current: currentSchemaVersion)
        }
        if let identity, (try? DemoRepositoryFileIdentity.read(fileURL)) == identity {
            knownFile = DemoRepositoryFileWitness(identity: identity, schemaVersion: version)
        }
        let decoded = version < currentSchemaVersion
            ? try migratedData(data, fromVersion: version) : data
        return (
            try JSONDecoder().decode(Envelope<Value>.self, from: decoded).value,
            decoded.count
        )
    }

    /// Only remove an explicitly retired child after its owner's replacement
    /// manifest has committed. Never used to retire the legacy session source.
    func removeExistingFile() throws {
        try requireBighelpProtectedData(protectedDataAvailability)
        let fileURL = try resolvedFileURL()
        guard fileManager.fileExists(atPath: fileURL.bighelpFileSystemPath) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    func load() throws -> Value {
        let fileURL = try resolvedFileURL()
        guard fileManager.fileExists(atPath: fileURL.bighelpFileSystemPath) else {
            try save(seed)
            return seed
        }

        let data = try Data(contentsOf: fileURL)
        let storedVersion: Int
        do {
            storedVersion = try JSONDecoder()
                .decode(EnvelopeVersion.self, from: data)
                .schemaVersion
        } catch {
            return try recoverFromCorruption(error)
        }

        guard storedVersion >= 0 else {
            return try recoverFromCorruption(
                DemoRepositoryError.invalidSchemaVersion(storedVersion)
            )
        }
        guard storedVersion <= currentSchemaVersion else {
            throw DemoRepositoryError.unsupportedSchemaVersion(
                found: storedVersion,
                current: currentSchemaVersion
            )
        }

        let decodedData: Data
        if storedVersion < currentSchemaVersion {
            decodedData = try migratedData(data, fromVersion: storedVersion)
        } else {
            decodedData = data
        }

        let value: Value
        do {
            value = try JSONDecoder().decode(Envelope<Value>.self, from: decodedData).value
        } catch {
            if storedVersion < currentSchemaVersion {
                throw DemoRepositoryError.migrationFailed(fromVersion: storedVersion)
            }
            return try recoverFromCorruption(error)
        }

        if storedVersion < currentSchemaVersion {
            try save(value)
        }
        return value
    }

    func save(_ value: Value) throws {
        try persist(value)
    }

    /// Pure encoding may run away from the UI actor. The owner must validate
    /// its account/revision again before committing these prepared bytes.
    static func encodeForSave(_ value: Value) throws -> Data {
        try encodeForSave(value, schemaVersion: 1)
    }

    static func encodeForSave(_ value: Value, schemaVersion: Int) throws -> Data {
        guard schemaVersion > 0 else { throw DemoRepositoryError.invalidSchemaVersion(schemaVersion) }
        return try JSONEncoder().encode(Envelope(schemaVersion: schemaVersion, value: value))
    }

    static func prepareEncoding(_ value: Value, schemaVersion: Int) throws -> DemoRepositoryPreparedEncoding {
        DemoRepositoryPreparedEncoding(data: try encodeForSave(value, schemaVersion: schemaVersion),
                                       schemaVersion: schemaVersion)
    }

    @MainActor
    func prepareCheckpoint(_ value: Value) async throws -> Data where Value: Sendable {
        try requireBighelpProtectedData(protectedDataAvailability)
        let url = try resolvedFileURL()
        let epoch = checkpointEpoch
        let version = currentSchemaVersion
        // Full JSON work stays off the actor. Adoption checks the exact file
        // observed here again, including after the temporary write completes.
        let prepared = try await Task.detached(priority: .utility) {
            let encoding = try DemoRepository<Value>.prepareEncoding(value, schemaVersion: version)
            let previous = try DemoRepositoryFileWitness.read(url)
            try previous.validate(at: url, currentVersion: version)
            return (encoding, previous)
        }.value
        try Task.checkCancellation()
        guard checkpointEpoch == epoch, try resolvedFileURL() == url else {
            throw DemoRepositoryError.staleFileSnapshot
        }
        let id = UUID()
        preparedCheckpoint = PreparedCheckpoint(id: id, epoch: epoch, url: url,
                                                encoding: prepared.0, previous: prepared.1)
        return try JSONEncoder().encode(CheckpointHandle(kind: "prepared-repository-checkpoint-v1", id: id))
    }

    func discardPreparedCheckpoint() {
        checkpointEpoch = UUID()
        preparedCheckpoint = nil
    }

    private func persist(_ value: Value) throws {
        try savePreparedEncoding(Self.prepareEncoding(value, schemaVersion: currentSchemaVersion))
    }

    func saveEncoded(_ data: Data) throws {
        if data.count <= 256, let handle = try? JSONDecoder().decode(CheckpointHandle.self, from: data),
           handle.kind == "prepared-repository-checkpoint-v1" {
            guard let prepared = preparedCheckpoint, prepared.id == handle.id,
                  prepared.epoch == checkpointEpoch, try resolvedFileURL() == prepared.url else {
                throw DemoRepositoryError.staleFileSnapshot
            }
            try persistPrepared(prepared.encoding, previous: prepared.previous)
            preparedCheckpoint = nil
            return
        }
        try saveEncoded(data, schemaVersion: currentSchemaVersion)
    }

    func saveEncoded(_ data: Data, schemaVersion: Int) throws {
        guard schemaVersion == currentSchemaVersion else { throw DemoRepositoryError.invalidSchemaVersion(schemaVersion) }
        let encodedVersion = try JSONDecoder().decode(EnvelopeVersion.self, from: data).schemaVersion
        guard encodedVersion == currentSchemaVersion else {
            throw DemoRepositoryError.invalidSchemaVersion(encodedVersion)
        }
        try savePreparedEncoding(DemoRepositoryPreparedEncoding(data: data, schemaVersion: encodedVersion))
    }

    func savePreparedEncoding(_ encoding: DemoRepositoryPreparedEncoding) throws {
        try requireBighelpProtectedData(protectedDataAvailability)
        let previous: DemoRepositoryFileWitness
        if holdsKnownFile, let knownFile {
            previous = knownFile
        } else {
            previous = try DemoRepositoryFileWitness.read(resolvedFileURL())
        }
        try persistPrepared(encoding, previous: previous)
    }

    private func persistPrepared(_ encoding: DemoRepositoryPreparedEncoding,
                                 previous: DemoRepositoryFileWitness) throws {
        guard encoding.schemaVersion == currentSchemaVersion else {
            throw DemoRepositoryError.invalidSchemaVersion(encoding.schemaVersion)
        }
        let directory = try resolvedDirectory()
        let fileURL = try resolvedFileURL()
        try requireBighelpProtectedData(protectedDataAvailability)
        try previous.validate(at: fileURL, currentVersion: currentSchemaVersion)
        try fileProtection.prepareDirectory(
            directory,
            protection: .backgroundCompatible,
            fileManager: fileManager
        )
        let temporaryURL = directory.appending(
            path: ".\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        do {
            try fileProtection.write(
                encoding.data,
                to: temporaryURL,
                protection: .backgroundCompatible
            )
            // Apply every throwing protection/backup operation before the
            // commit. A protection failure must not report a failed save after
            // a newer canonical send intent has already replaced the old one.
            try fileProtection.apply(
                .backgroundCompatible,
                to: temporaryURL,
                fileManager: fileManager
            )
            try previous.validate(at: fileURL, currentVersion: currentSchemaVersion)
            if fileManager.fileExists(atPath: fileURL.bighelpFileSystemPath) {
                _ = try fileManager.replaceItemAt(
                    fileURL, withItemAt: temporaryURL, options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        knownFile = DemoRepositoryFileWitness(identity: try? DemoRepositoryFileIdentity.read(fileURL),
                                              schemaVersion: encoding.schemaVersion)
    }

    /// Retries a protected write after iOS reports that protected data is
    /// available again. Callers own any account-generation or revision guard;
    /// this method only waits for the OS availability transition.
    @MainActor
    func saveAfterProtectedDataBecomesAvailable(
        _ value: Value,
        retryingAfterProtectedDataBecomesAvailableIn notificationCenter: NotificationCenter = .default
    ) async throws {
        do {
            try persist(value)
            return
        } catch BighelpLocalPersistenceError.protectedDataUnavailable {
            for await _ in notificationCenter.notifications(
                named: BighelpProtectedDataAvailabilityNotification.didBecomeAvailable
            ) {
                guard protectedDataAvailability.isProtectedDataAvailable else { continue }
                try persist(value)
                return
            }
        }
    }

    func removeOrphanedAvatarFiles(keeping fileNames: Set<String>) throws {
        let avatarsDirectory = try resolvedDirectory().appending(
            path: "\(name)-avatars",
            directoryHint: .isDirectory
        )
        try requireBighelpProtectedData(protectedDataAvailability)
        try fileProtection.prepareDirectory(
            avatarsDirectory,
            protection: .privateVisual,
            fileManager: fileManager
        )
        let validFileNames = Set(fileNames.filter { fileName in
            !fileName.isEmpty && URL(fileURLWithPath: fileName).lastPathComponent == fileName
        })
        let files = try fileManager.contentsOfDirectory(
            at: avatarsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for file in files {
            let resourceValues = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            guard !validFileNames.contains(file.lastPathComponent) else { continue }
            try fileManager.removeItem(at: file)
        }
    }

    private func recoveryBackupURL() -> URL {
        let directory = (try? resolvedDirectory()) ?? directory
        return directory.appending(
            path: "\(name)-v1-corrupt-\(UUID().uuidString).json"
        )
    }

    private func migratedData(_ data: Data, fromVersion: Int) throws -> Data {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DemoRepositoryError.migrationFailed(fromVersion: fromVersion)
        }
        guard var envelope = object as? [String: Any] else {
            throw DemoRepositoryError.migrationFailed(fromVersion: fromVersion)
        }
        var version = fromVersion

        while version < currentSchemaVersion {
            guard let migration = migrationsByVersion[version] else {
                throw DemoRepositoryError.missingMigration(fromVersion: version)
            }
            do {
                envelope = try migration.migrate(envelope)
            } catch {
                throw DemoRepositoryError.migrationFailed(fromVersion: version)
            }
            version += 1
            envelope["schemaVersion"] = version
        }

        do {
            return try JSONSerialization.data(withJSONObject: envelope)
        } catch {
            throw DemoRepositoryError.migrationFailed(fromVersion: version - 1)
        }
    }

    private func recoverFromCorruption(_ error: any Error) throws -> Value {
        let fileURL = try resolvedFileURL()
        try requireBighelpProtectedData(protectedDataAvailability)
        let backupURL = recoveryBackupURL()
        try fileManager.moveItem(at: fileURL, to: backupURL)
        try fileProtection.apply(
            .backgroundCompatible,
            to: backupURL,
            fileManager: fileManager
        )
        lastRecoveryBackupURL = backupURL
        lastRecoveryErrorMessage = "Unreadable repository data was moved to a recovery backup: \(error.localizedDescription)"
        try save(seed)
        return seed
    }

    private func resolvedDirectory() throws -> URL {
        guard let scopeID else { return directory }
        guard let scope = scopeID(),
              !scope.isEmpty,
              scope.utf8.count <= 96,
              scope.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
              })
        else { throw DemoRepositoryError.missingScope }
        return directory
            .appending(path: "hermes-hosts", directoryHint: .isDirectory)
            .appending(path: scope, directoryHint: .isDirectory)
    }

    private func resolvedFileURL() throws -> URL {
        try resolvedDirectory().appending(path: "\(name)-v1.json", directoryHint: .notDirectory)
    }
}

/// Build 5 removes readable host-derived data that was persisted before local
/// repositories had a host authority. Those files cannot be attributed safely
/// after more than one Hermes host has been paired, so migration intentionally
/// discards them instead of guessing which host owned them.
enum BighelpHostCacheMigration {
    static let currentVersion = 1
    static let defaultsKey = "loopdy.host-cache-migration-version"
    static let legacyRepositoryNames = ["agents", "sessions", "bot-mode-rooms"]

    /// Startup treats cleanup failure as recoverable. Scoped repositories never
    /// read these files, and the unset marker makes the next launch retry.
    static func discardLegacyCachesForStartup(
        in directory: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        try? discardLegacyCachesIfNeeded(
            in: directory,
            defaults: defaults,
            fileManager: fileManager
        )
    }

    static func discardLegacyCachesIfNeeded(
        in directory: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard defaults.integer(forKey: defaultsKey) < currentVersion else { return }
        for name in legacyRepositoryNames {
            let file = directory.appending(path: "\(name)-v1.json", directoryHint: .notDirectory)
            let avatars = directory.appending(path: "\(name)-avatars", directoryHint: .isDirectory)
            for target in [file, avatars]
            where fileManager.fileExists(atPath: target.bighelpFileSystemPath) {
                try fileManager.removeItem(at: target)
            }
        }
        defaults.removeObject(forKey: "loopdy.models.recent")
        defaults.set(currentVersion, forKey: defaultsKey)
    }
}
