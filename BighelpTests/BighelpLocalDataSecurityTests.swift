import Foundation
import Security
import Testing
@testable import Bighelp

struct BighelpLocalDataSecurityTests {
    @Test func protectedLocalFilesAndDirectoriesAreExcludedFromDeviceBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BighelpLocalDataSecurityTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "pending-frame.json")
        let protector = BighelpLocalFileProtector()

        try protector.prepareDirectory(
            directory,
            protection: .backgroundCompatible,
            fileManager: .default
        )
        try protector.write(
            Data("encrypted pending frame".utf8),
            to: file,
            protection: .backgroundCompatible
        )
        try protector.apply(.backgroundCompatible, to: file, fileManager: .default)

        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let fileValues = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)
        #expect(fileValues.isExcludedFromBackup == true)
    }

    @Test func corruptRepositoryRecoveryBackupsRemainExcludedFromDeviceBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BighelpLocalDataSecurityTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appending(path: "sessions-v1.json"))

        let repository = DemoRepository<[String]>(
            directory: directory,
            name: "sessions",
            seed: []
        )

        _ = try repository.load()

        let backupURL = try #require(repository.lastRecoveryBackupURL)
        let values = try backupURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

}

struct BighelpMarketplaceRetirementMigrationTests {
    @Test func purgesRetiredMarketplaceDataOnceWithoutRemovingCustomThemes() throws {
        let suiteName = "BighelpMarketplaceRetirementMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BighelpMarketplaceRetirementMigrationTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marketplace = directory.appending(path: "marketplace", directoryHint: .isDirectory)
        let customThemeLogos = directory.appending(path: "custom-theme-logos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: marketplace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customThemeLogos, withIntermediateDirectories: true)
        try Data("private account receipt".utf8).write(
            to: marketplace.appending(path: "install-receipts-v1.json")
        )
        try Data("retired catalog".utf8).write(
            to: marketplace.appending(path: "catalog-cache-v1.json")
        )
        let logo = Data([0x89, 0x50, 0x4E, 0x47])
        try logo.write(to: customThemeLogos.appending(path: "saved-theme.png"))
        let themes = Data("{\"schemaVersion\":1,\"themes\":[]}".utf8)
        defaults.set(themes, forKey: "loopdy.appearance.customThemes")
        defaults.set("custom.saved-theme", forKey: "loopdy.appearance.theme")

        try BighelpMarketplaceRetirementMigration.run(
            dataDirectory: directory,
            defaults: defaults
        )

        #expect(!FileManager.default.fileExists(atPath: marketplace.path))
        #expect(try Data(contentsOf: customThemeLogos.appending(path: "saved-theme.png")) == logo)
        #expect(defaults.data(forKey: "loopdy.appearance.customThemes") == themes)
        #expect(defaults.string(forKey: "loopdy.appearance.theme") == "custom.saved-theme")
        #expect(defaults.bool(forKey: BighelpMarketplaceRetirementMigration.defaultsKey))

        try FileManager.default.createDirectory(at: marketplace, withIntermediateDirectories: true)
        try Data("new sentinel".utf8).write(to: marketplace.appending(path: "sentinel"))
        try BighelpMarketplaceRetirementMigration.run(
            dataDirectory: directory,
            defaults: defaults
        )
        #expect(FileManager.default.fileExists(atPath: marketplace.appending(path: "sentinel").path))
    }
}

struct BighelpLinkAccountRetirementTests {
    /// Phones that once used the retired bighelp account lose its leftover
    /// pairing choices once, and keep everything else.
    @Test func removesTheRetiredAccountsSettingsOnce() {
        let defaults = UserDefaults(suiteName: "link-retirement-\(UUID().uuidString)")!
        defaults.set("host-1", forKey: "loopdy.link.selected-host-id")
        defaults.set("host-1", forKey: "loopdy.link.primary-host-id")
        defaults.set(Data([1]), forKey: "loopdy.link.socket.v1.device-1")
        defaults.set(true, forKey: "loopdy.settings.nerd-mode")

        var deleted: [String] = []
        BighelpLinkAccountRetirement.run(defaults: defaults) { deleted.append($0); return errSecItemNotFound }

        #expect(deleted == ["app.loopdy.mobile.link", "app.loopdy.mobile.direct.v1"])
        #expect(defaults.object(forKey: "loopdy.link.selected-host-id") == nil)
        #expect(defaults.object(forKey: "loopdy.link.primary-host-id") == nil)
        #expect(defaults.object(forKey: "loopdy.link.socket.v1.device-1") == nil)
        #expect(defaults.bool(forKey: "loopdy.settings.nerd-mode"))
        #expect(defaults.bool(forKey: BighelpLinkAccountRetirement.defaultsKey))

        defaults.set("host-2", forKey: "loopdy.link.selected-host-id")
        BighelpLinkAccountRetirement.run(defaults: defaults) { _ in errSecSuccess }
        #expect(defaults.string(forKey: "loopdy.link.selected-host-id") == "host-2")
    }

    /// A locked keychain leaves the account's keys; the next launch tries again.
    @Test func aLockedKeychainRetriesNextLaunch() {
        let defaults = UserDefaults(suiteName: "link-retirement-\(UUID().uuidString)")!
        BighelpLinkAccountRetirement.run(defaults: defaults) { _ in errSecInteractionNotAllowed }
        #expect(!defaults.bool(forKey: BighelpLinkAccountRetirement.defaultsKey))
        var attempts = 0
        BighelpLinkAccountRetirement.run(defaults: defaults) { _ in attempts += 1; return errSecSuccess }
        #expect(attempts == 2)
        #expect(defaults.bool(forKey: BighelpLinkAccountRetirement.defaultsKey))
    }
}
