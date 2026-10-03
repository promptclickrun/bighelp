import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

enum BighelpLocalPersistenceError: Error, Equatable {
    case protectedDataUnavailable
}

protocol BighelpProtectedDataAvailabilityProviding: Sendable {
    var isProtectedDataAvailable: Bool { get }
}

struct BighelpSystemProtectedDataAvailability: BighelpProtectedDataAvailabilityProviding {
    var isProtectedDataAvailable: Bool {
        #if canImport(UIKit)
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIApplication.shared.isProtectedDataAvailable
            }
        }
        return DispatchQueue.main.sync {
            UIApplication.shared.isProtectedDataAvailable
        }
        #else
        true
        #endif
    }
}

enum BighelpProtectedDataAvailabilityNotification {
    static let didBecomeAvailable: Notification.Name = {
        #if canImport(UIKit)
        UIApplication.protectedDataDidBecomeAvailableNotification
        #else
        Notification.Name("BighelpProtectedDataDidBecomeAvailable")
        #endif
    }()
}

@inline(__always)
func requireBighelpProtectedData(
    _ availability: any BighelpProtectedDataAvailabilityProviding
) throws {
    guard availability.isProtectedDataAvailable else {
        throw BighelpLocalPersistenceError.protectedDataUnavailable
    }
}

enum BighelpLocalProtectionClass: Equatable, Sendable {
    case backgroundCompatible
    case privateVisual
}

protocol BighelpLocalFileProtecting: Sendable {
    func prepareDirectory(
        _ directory: URL,
        protection: BighelpLocalProtectionClass,
        fileManager: FileManager
    ) throws
    func write(
        _ data: Data,
        to file: URL,
        protection: BighelpLocalProtectionClass
    ) throws
    func apply(
        _ protection: BighelpLocalProtectionClass,
        to file: URL,
        fileManager: FileManager
    ) throws
}

struct BighelpLocalFileProtector: BighelpLocalFileProtecting {
    static func fileProtection(for protection: BighelpLocalProtectionClass) -> FileProtectionType {
        switch protection {
        case .backgroundCompatible: .completeUntilFirstUserAuthentication
        case .privateVisual: .complete
        }
    }

    static func writingOptions(for protection: BighelpLocalProtectionClass) -> Data.WritingOptions {
        switch protection {
        case .backgroundCompatible: .completeFileProtectionUntilFirstUserAuthentication
        case .privateVisual: .completeFileProtection
        }
    }

    func prepareDirectory(
        _ directory: URL,
        protection: BighelpLocalProtectionClass,
        fileManager: FileManager
    ) throws {
        let fileProtection = Self.fileProtection(for: protection)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: fileProtection]
        )
        try fileManager.setAttributes(
            [.protectionKey: fileProtection],
            ofItemAtPath: directory.bighelpFileSystemPath
        )
        try Self.excludeFromBackup(directory)
    }

    func write(
        _ data: Data,
        to file: URL,
        protection: BighelpLocalProtectionClass
    ) throws {
        try data.write(
            to: file,
            options: [.withoutOverwriting, Self.writingOptions(for: protection)]
        )
        try Self.excludeFromBackup(file)
    }

    func apply(
        _ protection: BighelpLocalProtectionClass,
        to file: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes(
            [.protectionKey: Self.fileProtection(for: protection)],
            ofItemAtPath: file.bighelpFileSystemPath
        )
        try Self.excludeFromBackup(file)
    }

    private static func excludeFromBackup(_ file: URL) throws {
        try (file as NSURL).setResourceValue(
            true,
            forKey: URLResourceKey.isExcludedFromBackupKey
        )
    }
}

enum BighelpMarketplaceRetirementMigration {
    static let defaultsKey = "loopdy.migrations.marketplace-retirement-v1"

    static func run(
        dataDirectory: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard !defaults.bool(forKey: defaultsKey) else { return }
        let root = dataDirectory.standardizedFileURL
        guard root.isFileURL,
              root.pathComponents.count >= 3,
              root.bighelpFileSystemPath != "/",
              root.bighelpFileSystemPath != NSHomeDirectory()
        else { throw CocoaError(.fileWriteNoPermission) }
        let marketplace = root.appending(path: "marketplace", directoryHint: .isDirectory)
        guard marketplace.deletingLastPathComponent().standardizedFileURL == root else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if fileManager.fileExists(atPath: marketplace.bighelpFileSystemPath) {
            try fileManager.removeItem(at: marketplace)
        }
        defaults.set(true, forKey: defaultsKey)
    }
}
