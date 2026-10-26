import Foundation
import XCTest
@testable import Bighelp

/// A wake while the phone is locked (Background App Refresh, a Shortcut, the Watch) connects, but the
/// computer's saved workspace can't open: iOS keeps its files locked. That's a wait, not "could not be
/// opened". Once the phone is unlocked, coming back opens it, even though the wake's connection is
/// still the one in use and nothing about it changed (#628). Uses an isolated stock Hermes server.
final class NativeWorkspaceLockedWakeLiveTests: XCTestCase {
    /// The phone's lock, as the workspace's saved files see it.
    private final class PhoneLock: BighelpProtectedDataAvailabilityProviding, @unchecked Sendable {
        var isUnlocked = false
        var isProtectedDataAvailable: Bool { isUnlocked }
    }

    @MainActor
    func testWorkspaceLockedAtAWakeOpensWhenTheAppComesBack() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
            throw XCTSkip("Run with DirectHermesNativeProbe.py --ios-tests")
        }
        let pipe = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? pipe.close() }
        let config = try JSONDecoder().decode([String: String].self, from: pipe.readToEnd() ?? Data())
        guard config["isolated_fixture"] == "true",
              let address = config["address"], URL(string: address)?.host == "127.0.0.1" else {
            throw XCTSkip("Only the isolated loopback fixture is authorized")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "app.loopdy.locked-wake." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let hosts = BighelpHostRegistry(root: directory.appending(path: "hosts"), keychainService: suite,
            independentRoot: directory.appending(path: "independent"), defaults: preferences)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        hosts.useIndependentWorkspace()
        let (pendingID, hostWorkspace) = try hosts.makePendingWorkspace()
        defer { hosts.discardPending(pendingID) }
        try await hostWorkspace.connect(address: address,
            auth: .password(username: XCTUnwrap(config["username"]), password: XCTUnwrap(config["password"])),
            allowPrivateHTTP: true)
        let configured = try hosts.commit(pendingID, workspace: hostWorkspace, name: "Isolated locked-wake fixture")
        defer { try? hosts.remove(configured) }
        let connections = WorkspaceConnectionStore(hosts: hosts)
        let owner = try XCTUnwrap(connections.owner)
        let runtimeSuite = "app.loopdy.native-workspace." + owner.authority.cacheScopeID
        defer { UserDefaults(suiteName: runtimeSuite)?.removePersistentDomain(forName: runtimeSuite) }

        let lock = PhoneLock()
        let selection = NativeWorkspaceSelectionStore(connections: connections,
            settings: SettingsStore(defaults: preferences, legacyThemeLogoDirectory: directory.appending(path: "logos")),
            userIdentity: UserIdentityStore(defaults: preferences, avatarDirectory: directory.appending(path: "avatars")),
            directory: directory.appending(path: "runtime"), protectedData: lock)
        defer { selection.current?.retire() }

        // The wake, while locked: no workspace yet, and nothing to call a failure.
        await selection.synchronize()
        XCTAssertNil(selection.current)
        XCTAssertNil(selection.errorMessage, "A locked phone isn't a failure")

        // Unlocked and back in the app, on the same connection the wake made.
        lock.isUnlocked = true
        XCTAssertEqual(connections.owner, owner, "Nothing about the connection changed")
        await selection.refreshCurrentRuntimeForForeground()
        XCTAssertNotNil(selection.current, "Coming back opens the workspace")
        XCTAssertNil(selection.errorMessage)
    }
}
