import Foundation
import Testing
@testable import Bighelp

struct DemoRepositoryTests {
    private struct ReplacingRepositoryFileProtection: BighelpLocalFileProtecting {
        let destination: URL
        let replacement: Data

        func prepareDirectory(_ directory: URL, protection: BighelpLocalProtectionClass, fileManager: FileManager) throws {
            try BighelpLocalFileProtector().prepareDirectory(directory, protection: protection, fileManager: fileManager)
        }
        func write(_ data: Data, to file: URL, protection: BighelpLocalProtectionClass) throws {
            try BighelpLocalFileProtector().write(data, to: file, protection: protection)
            try replacement.write(to: destination, options: .atomic)
        }
        func apply(_ protection: BighelpLocalProtectionClass, to file: URL, fileManager: FileManager) throws {
            try BighelpLocalFileProtector().apply(protection, to: file, fileManager: fileManager)
        }
    }

    @Test(arguments: [false, true])
    func replacementDuringTemporaryWriteCannotOverwriteANewerFile(raw: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "fixture-v1.json")
        let original = DemoRepository<[String]>(directory: directory, name: "fixture", seed: [])
        try original.save(["original"])
        let replacement = try DemoRepository<[String]>.encodeForSave(["newer"], schemaVersion: 3)
        let repository = DemoRepository<[String]>(
            directory: directory, name: "fixture", seed: [],
            fileProtection: ReplacingRepositoryFileProtection(destination: file, replacement: replacement)
        )
        #expect(throws: DemoRepositoryError.staleFileSnapshot) {
            if raw { try repository.saveEncoded(DemoRepository<[String]>.encodeForSave(["stale"])) }
            else { try repository.save(["stale"]) }
        }
        #expect(try Data(contentsOf: file) == replacement)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test func malformedRawCheckpointDoesNotAcquireAnEncoderWitness() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[String]>(directory: directory, name: "fixture", seed: [])
        try repository.save(["original"])
        #expect(throws: (any Error).self) {
            try repository.saveEncoded(Data("{\"schemaVersion\":1,\"value\":[".utf8))
        }
        #expect(try repository.load() == ["original"])
    }

    @Test func selectedRepositoryCanMigrateWithoutChangingOtherRepositoryVersions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DemoRepository<[String]>(directory: directory, name: "rooms", seed: [])
        try original.save(["preserved"])
        let upgraded = DemoRepository<[String]>(
            directory: directory, name: "rooms", seed: [],
            migrations: [DemoRepositoryMigration(fromVersion: 1) { $0 }],
            currentSchemaVersion: 2
        )
        #expect(try upgraded.load() == ["preserved"])
        let file = directory.appending(path: "rooms-v1.json")
        let upgradedData = try Data(contentsOf: file)
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 2, current: 1)) {
            try original.load()
        }

        #expect(try Data(contentsOf: file) == upgradedData)
        #expect(original.lastRecoveryBackupURL == nil)
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 2, current: 1)) {
            try original.save([])
        }
        #expect(try Data(contentsOf: file) == upgradedData)
        #expect(try upgraded.loadExistingPreservingSource() == ["preserved"])
    }

    @Test func repositoryChildrenInheritVersionAndSequentialMigrations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldChild = DemoRepository<[String]>(directory: directory, name: "child", seed: [])
        try oldChild.save(["child"])
        let parent = DemoRepository<[String]>(
            directory: directory, name: "parent", seed: [],
            migrations: [DemoRepositoryMigration(fromVersion: 1) { $0 }],
            currentSchemaVersion: 2
        )
        let child = parent.child(name: "child", seed: [String]())
        #expect(child.currentSchemaVersion == 2)
        #expect(try child.load() == ["child"])
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 2, current: 1)) {
            try oldChild.loadExistingPreservingSource()
        }
    }

    @Test func oldEncodedCheckpointCannotMasqueradeAsNewRepositoryVersion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[String]>(directory: directory, name: "rooms", seed: [],
                                                  currentSchemaVersion: 2)
        try repository.save(["committed"])
        let oldBytes = try DemoRepository<[String]>.encodeForSave(["stale"])
        #expect(throws: DemoRepositoryError.invalidSchemaVersion(1)) {
            try repository.saveEncoded(oldBytes)
        }
        #expect(throws: DemoRepositoryError.invalidSchemaVersion(1)) {
            try repository.saveEncoded(oldBytes, schemaVersion: 2)
        }
        #expect(try repository.load() == ["committed"])
    }

    @Test func fileSystemPathDecodesPercentEncoding() throws {
        let url = try #require(
            URL(string: "file:///tmp/Application%20Support/agents-v1.json")
        )

        #expect(url.bighelpFileSystemPath == "/tmp/Application Support/agents-v1.json")
    }

    @Test func corruptRepositoryRecoversSeedAndRetainsBackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("broken".utf8).write(to: directory.appending(path: "agents-v1.json"))
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [.defaultFixture]
        )

        #expect(try repository.load() == [.defaultFixture])
        let backupURL = try #require(repository.lastRecoveryBackupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path(percentEncoded: false)))
        #expect(repository.lastRecoveryErrorMessage != nil)
    }

    @Test func olderSchemaMigratesForwardWithoutReseeding() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "fixture-v1.json")
        try Data(
            """
            {
              "schemaVersion": 0,
              "value": {
                "legacyName": "Preserved"
              }
            }
            """.utf8
        ).write(to: fileURL)
        let migration = DemoRepositoryMigration(fromVersion: 0) { envelope in
            var migratedEnvelope = envelope
            guard
                var value = migratedEnvelope["value"] as? [String: Any],
                let name = value.removeValue(forKey: "legacyName") as? String
            else { throw MigrationFixtureError.invalidPayload }
            value["name"] = name
            migratedEnvelope["value"] = value
            return migratedEnvelope
        }
        let repository = DemoRepository<MigratedFixture>(
            directory: directory,
            name: "fixture",
            seed: MigratedFixture(name: "Seed"),
            migrations: [migration]
        )

        #expect(try repository.load() == MigratedFixture(name: "Preserved"))
        #expect(repository.lastRecoveryBackupURL == nil)
        #expect(repository.lastRecoveryErrorMessage == nil)

        let migratedData = try Data(contentsOf: fileURL)
        let migratedObject = try #require(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        let migratedValue = try #require(migratedObject["value"] as? [String: Any])
        #expect(migratedObject["schemaVersion"] as? Int == 1)
        #expect(migratedValue["name"] as? String == "Preserved")
    }

    @Test func newerSchemaIsPreservedInsteadOfBeingTreatedAsCorruption() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "fixture-v1.json")
        let originalData = Data(
            """
            {
              "schemaVersion": 2,
              "value": {
                "name": "Future"
              }
            }
            """.utf8
        )
        try originalData.write(to: fileURL)
        let repository = DemoRepository<MigratedFixture>(
            directory: directory,
            name: "fixture",
            seed: MigratedFixture(name: "Seed")
        )

        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 2, current: 1)) {
            try repository.load()
        }
        #expect(try Data(contentsOf: fileURL) == originalData)
        #expect(repository.lastRecoveryBackupURL == nil)
        #expect(repository.lastRecoveryErrorMessage == nil)
    }

    @Test func savedProfilesReloadFromAVersionedEnvelope() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [.defaultFixture]
        )

        try repository.save([.defaultFixture, .financeFixture])
        let reloaded = DemoRepository<[AgentProfile]>(directory: directory, name: "agents", seed: [])
        let data = try Data(contentsOf: directory.appending(path: "agents-v1.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(try reloaded.load() == [.defaultFixture, .financeFixture])
    }

    @Test func scopedRepositoriesKeepEachHermesHostsValuesSeparate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var selectedHostID: String? = "host-a"
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [],
            scopeID: { selectedHostID }
        )

        try repository.save([.defaultFixture])
        selectedHostID = "host-b"
        #expect(try repository.load().isEmpty)
        try repository.save([.financeFixture])
        selectedHostID = "host-a"
        #expect(try repository.load() == [.defaultFixture])
        selectedHostID = "host-b"
        #expect(try repository.load() == [.financeFixture])
    }

    @Test func scopedRepositoryRefusesAccessUntilAHostIsSelected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [],
            scopeID: { nil }
        )

        #expect(throws: DemoRepositoryError.missingScope) {
            try repository.load()
        }
        #expect(throws: DemoRepositoryError.missingScope) {
            try repository.save([.defaultFixture])
        }
    }

    @Test func failedHostCacheCleanupDefersCompletionAndAllowsASafeRetry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = isolatedDefaults()
        let legacyFile = directory.appending(path: "agents-v1.json")
        try Data("legacy".utf8).write(to: legacyFile)
        let fileManager = FailingOnceFileManager()

        BighelpHostCacheMigration.discardLegacyCachesForStartup(
            in: directory,
            defaults: defaults,
            fileManager: fileManager
        )

        #expect(FileManager.default.fileExists(atPath: legacyFile.path(percentEncoded: false)))
        #expect(defaults.integer(forKey: BighelpHostCacheMigration.defaultsKey) == 0)

        let scopedRepository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [.defaultFixture],
            scopeID: { "host-a" }
        )
        #expect(try scopedRepository.load() == [.defaultFixture])
        #expect(FileManager.default.fileExists(atPath: legacyFile.path(percentEncoded: false)))

        BighelpHostCacheMigration.discardLegacyCachesForStartup(
            in: directory,
            defaults: defaults,
            fileManager: fileManager
        )

        #expect(!FileManager.default.fileExists(atPath: legacyFile.path(percentEncoded: false)))
        #expect(
            defaults.integer(forKey: BighelpHostCacheMigration.defaultsKey)
                == BighelpHostCacheMigration.currentVersion
        )
    }

    @Test func build5MigrationDiscardsUnscopedHostCachesExactlyOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = isolatedDefaults()
        for name in BighelpHostCacheMigration.legacyRepositoryNames {
            try Data("legacy".utf8).write(
                to: directory.appending(path: "\(name)-v1.json")
            )
            let avatars = directory.appending(path: "\(name)-avatars")
            try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
            try Data([1]).write(to: avatars.appending(path: "avatar.png"))
        }
        defaults.set(Data([1]), forKey: "loopdy.models.recent")

        try BighelpHostCacheMigration.discardLegacyCachesIfNeeded(
            in: directory,
            defaults: defaults
        )

        for name in BighelpHostCacheMigration.legacyRepositoryNames {
            #expect(!FileManager.default.fileExists(
                atPath: directory.appending(path: "\(name)-v1.json").path(percentEncoded: false)
            ))
            #expect(!FileManager.default.fileExists(
                atPath: directory.appending(path: "\(name)-avatars").path(percentEncoded: false)
            ))
        }
        #expect(defaults.data(forKey: "loopdy.models.recent") == nil)
        #expect(
            defaults.integer(forKey: BighelpHostCacheMigration.defaultsKey)
                == BighelpHostCacheMigration.currentVersion
        )

        // Once marked complete, a new unscoped file is not touched: this
        // proves migration cannot delete future data on every app launch.
        let retained = directory.appending(path: "sessions-v1.json")
        try Data("new".utf8).write(to: retained)
        try BighelpHostCacheMigration.discardLegacyCachesIfNeeded(
            in: directory,
            defaults: defaults
        )
        #expect(FileManager.default.fileExists(atPath: retained.path(percentEncoded: false)))
    }

    @Test func lockedSaveThrowsTypedErrorWithoutTruncatingExistingRepository() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let availability = TestProtectedDataAvailability(isAvailable: true)
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [.defaultFixture],
            protectedDataAvailability: availability
        )

        try repository.save([.defaultFixture])
        let fileURL = directory.appending(path: "agents-v1.json")
        let originalData = try Data(contentsOf: fileURL)
        availability.isProtectedDataAvailable = false

        #expect(throws: BighelpLocalPersistenceError.protectedDataUnavailable) {
            try repository.save([.financeFixture])
        }
        #expect(try Data(contentsOf: fileURL) == originalData)
    }

    @Test @MainActor func saveCanRetryAfterProtectedDataBecomesAvailable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let availability = TestProtectedDataAvailability(isAvailable: false)
        let notificationCenter = NotificationCenter()
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [],
            protectedDataAvailability: availability
        )
        let retry = Task { @MainActor in
            try await repository.saveAfterProtectedDataBecomesAvailable(
                [.financeFixture],
                retryingAfterProtectedDataBecomesAvailableIn: notificationCenter
            )
        }

        try await Task.sleep(for: .milliseconds(25))
        availability.isProtectedDataAvailable = true
        notificationCenter.post(
            name: BighelpProtectedDataAvailabilityNotification.didBecomeAvailable,
            object: nil
        )
        try await retry.value

        #expect(try repository.load() == [.financeFixture])
    }

    @Test func savedRepositoryUsesBackgroundCompatibleDataProtection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let protection = RepositoryFileProtectionRecorder()
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [],
            fileProtection: protection
        )

        try repository.save([.defaultFixture])

        #expect(protection.events == [
            .prepare(.backgroundCompatible),
            .write(.backgroundCompatible),
            .apply(.backgroundCompatible),
        ])
        #expect(
            BighelpLocalFileProtector.writingOptions(for: .backgroundCompatible)
                .contains(.completeFileProtectionUntilFirstUserAuthentication)
        )
    }

    @Test func repeatedSaveWorksWhenDirectoryPathContainsSpaces() throws {
        let parentDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }
        let fileURLBackedDirectory = parentDirectory.appending(
            path: "Application Support",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: fileURLBackedDirectory,
            withIntermediateDirectories: true
        )
        let directory = try #require(URL(string: fileURLBackedDirectory.absoluteString))
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: []
        )

        try repository.save([.defaultFixture])
        #expect(FileManager.default.fileExists(
            atPath: fileURLBackedDirectory.appending(path: "agents-v1.json").path
        ))
        // The percent-encoded spelling on purpose: nothing may be written to a folder named "Application%20Support".
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "agents-v1.json").path()
        ))
        try repository.save([.financeFixture])

        #expect(try repository.load() == [.financeFixture])
    }

    @Test func orphanedAvatarCleanupKeepsReferencedFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [.defaultFixture]
        )
        try FileManager.default.createDirectory(
            at: repository.avatarsDirectory,
            withIntermediateDirectories: true
        )
        let retained = repository.avatarsDirectory.appending(path: "finance.png")
        let orphaned = repository.avatarsDirectory.appending(path: "removed.png")
        try Data([1]).write(to: retained)
        try Data([2]).write(to: orphaned)

        try repository.removeOrphanedAvatarFiles(keeping: ["finance.png"])

        #expect(FileManager.default.fileExists(atPath: retained.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: orphaned.path(percentEncoded: false)))
    }

    @Test func orphanedAvatarCleanupRetainsNestedDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[AgentProfile]>(
            directory: directory,
            name: "agents",
            seed: [.defaultFixture]
        )
        let nestedDirectory = repository.avatarsDirectory.appending(
            path: "archived",
            directoryHint: .isDirectory
        )
        let nestedFile = nestedDirectory.appending(path: "prior-avatar.png")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data([3]).write(to: nestedFile)

        try repository.removeOrphanedAvatarFiles(keeping: [])

        #expect(FileManager.default.fileExists(atPath: nestedDirectory.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: nestedFile.path(percentEncoded: false)))
    }
}

private struct MigratedFixture: Codable, Equatable {
    let name: String
}

private enum MigrationFixtureError: Error {
    case invalidPayload
}

private final class FailingOnceFileManager: FileManager, @unchecked Sendable {
    private var shouldFail = true

    override func removeItem(at URL: URL) throws {
        if shouldFail {
            shouldFail = false
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

private final class RepositoryFileProtectionRecorder: BighelpLocalFileProtecting, @unchecked Sendable {
    enum Event: Equatable {
        case prepare(BighelpLocalProtectionClass)
        case write(BighelpLocalProtectionClass)
        case apply(BighelpLocalProtectionClass)
    }

    var events: [Event] = []

    func prepareDirectory(
        _ directory: URL,
        protection: BighelpLocalProtectionClass,
        fileManager: FileManager
    ) throws {
        events.append(.prepare(protection))
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(
        _ data: Data,
        to file: URL,
        protection: BighelpLocalProtectionClass
    ) throws {
        events.append(.write(protection))
        try data.write(to: file, options: .withoutOverwriting)
    }

    func apply(
        _ protection: BighelpLocalProtectionClass,
        to file: URL,
        fileManager: FileManager
    ) throws {
        events.append(.apply(protection))
    }
}

private final class TestProtectedDataAvailability: BighelpProtectedDataAvailabilityProviding, @unchecked Sendable {
    var isProtectedDataAvailable: Bool

    init(isAvailable: Bool) {
        isProtectedDataAvailable = isAvailable
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BighelpTests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
