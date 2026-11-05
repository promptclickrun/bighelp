import Foundation
import XCTest
@testable import Bighelp

/// Opening bighelp showed "Hermes workspace · Reconnecting to your selected host…" until the computer
/// answered: the workspace opened only with a live connection. Now it opens from what the phone saved
/// for the sign-in, and the connection comes up behind it, into the same workspace. Uses an isolated
/// stock Hermes server.
final class NativeWorkspaceSavedOpenLiveTests: XCTestCase {
    @MainActor
    func testASavedWorkspaceOpensBeforeItsComputerAnswers() async throws {
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
        let suite = "app.loopdy.saved-open." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        func registry() -> BighelpHostRegistry {
            let hosts = BighelpHostRegistry(root: directory.appending(path: "hosts"), keychainService: suite,
                independentRoot: directory.appending(path: "independent"), defaults: preferences)
            hosts.useIndependentWorkspace()
            return hosts
        }
        func selection(_ connections: WorkspaceConnectionStore) -> NativeWorkspaceSelectionStore {
            NativeWorkspaceSelectionStore(connections: connections,
                settings: SettingsStore(defaults: preferences, legacyThemeLogoDirectory: directory.appending(path: "logos")),
                userIdentity: UserIdentityStore(defaults: preferences, avatarDirectory: directory.appending(path: "avatars")),
                directory: directory.appending(path: "runtime"))
        }
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        // The first run: set up the computer and open its workspace once, which saves its agents.
        let first = registry()
        let (pendingID, hostWorkspace) = try first.makePendingWorkspace()
        try await hostWorkspace.connect(address: address,
            auth: .password(username: XCTUnwrap(config["username"]), password: XCTUnwrap(config["password"])),
            allowPrivateHTTP: true)
        let configured = try first.commit(pendingID, workspace: hostWorkspace, name: "Isolated saved-open fixture")
        defer { try? registry().remove(configured) }
        let firstConnections = WorkspaceConnectionStore(hosts: first)
        let owner = try XCTUnwrap(firstConnections.owner)
        let runtimeSuite = "app.loopdy.native-workspace." + owner.authority.cacheScopeID
        defer { UserDefaults(suiteName: runtimeSuite)?.removePersistentDomain(forName: runtimeSuite) }
        let firstSelection = selection(firstConnections)
        await firstSelection.synchronize()
        let savedAgents = try XCTUnwrap(firstSelection.current?.agents.profiles.map(\.id))
        XCTAssertFalse(savedAgents.isEmpty, "The computer's agents load once")
        firstSelection.current?.retire()
        hostWorkspace.suspendForPresentationExit()

        // The next launch: nothing has connected yet, and the workspace is already open with what was saved.
        let next = registry()
        let connections = WorkspaceConnectionStore(hosts: next)
        XCTAssertNil(connections.owner, "A launch doesn't connect before the app asks it to")
        XCTAssertEqual(connections.savedAuthority, owner.authority)
        let launch = selection(connections)
        launch.openSavedWorkspace()
        let opened = try XCTUnwrap(launch.current, "The home opens before the computer answers")
        await launch.synchronize()
        XCTAssertTrue(launch.current === opened, "Synchronizing while the connection is down keeps it open")
        defer { launch.current?.retire() }
        XCTAssertNil(launch.errorMessage)
        XCTAssertFalse(opened.isReady)
        XCTAssertEqual(opened.agents.profiles.map(\.id), savedAgents, "It shows the agents saved last time")

        // The connection comes up behind it, into the same workspace.
        await next.selectedWorkspace?.reconnect()
        XCTAssertEqual(connections.owner?.authority, owner.authority)
        await launch.synchronize()
        XCTAssertTrue(launch.current === opened, "Connecting refreshes the open workspace, never replaces it")
        XCTAssertTrue(opened.isReady)
    }
}
