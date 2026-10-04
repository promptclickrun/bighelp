import Foundation
import AVFoundation
import XCTest
@testable import Bighelp

final class DirectHermesManagementLiveTests: XCTestCase {
    /// What Settings › System and Fleet read, against a stock host as it ships: a git install far
    /// behind, its gateway stopped (Hermes sends nulls for the gateway's state then).
    @MainActor
    func testHostOperationsReadsAgainstIsolatedStockHost() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
            throw XCTSkip("Requires the disposable stock-host fixture.")
        }
        let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard config["fixture_only"] == "true", config["address"]?.hasPrefix("http://127.0.0.1:") == true else {
            throw XCTSkip("This probe is restricted to its disposable loopback host.")
        }
        let vault = DirectHermesKeychainVault(service: "app.loopdy.management-proof." + UUID().uuidString)
        defer { try? vault.delete() }
        let transport = try await DirectHermesClient.connect(address: XCTUnwrap(config["address"]),
            auth: .token(XCTUnwrap(config["token"])), allowPrivateHTTP: true, vault: vault)
        let owner = WorkspaceOwner(authority: try XCTUnwrap(transport.savedConnection.workspaceAuthority),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        let current: @MainActor () -> WorkspaceOwner? = { owner }
        let operations = DirectHermesHostOperationsClient(rpc: transport, http: transport, owner: owner, currentOwner: current)
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Overview", { _ = try await operations.overview(profileID: "default") }),
            ("System statistics", { _ = try await operations.systemStats() }),
            ("Egress state", { _ = try await operations.egressStatus() }),
            ("Update check", { _ = try await operations.checkForUpdate(force: true) }),
            ("Update receipt", { _ = try await operations.latestUpdateReceipt() }),
            ("Checkpoints", { _ = try await operations.checkpoints() }),
            ("Gateway migration plan", { _ = try await operations.gatewayMigrationPlan() }),
            ("Shell hooks", { _ = try await operations.shellHooks() }),
        ]
        for (name, check) in checks {
            do {
                try await check()
                print("HOST_OPERATIONS_READ_PASS \(name)")
            } catch {
                XCTFail("\(name) failed: \(String(reflecting: error))")
            }
        }
    }

    @MainActor
    func testReadOnlyManagementAgainstIsolatedStockHost() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
            throw XCTSkip("Requires the disposable stock-host fixture.")
        }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let data = try input.readToEnd() ?? Data()
        try input.close()
        let config = try JSONDecoder().decode([String: String].self, from: data)
        guard config["fixture_only"] == "true", config["address"]?.hasPrefix("http://127.0.0.1:") == true else {
            throw XCTSkip("This probe is restricted to its disposable loopback host.")
        }
        let vault = DirectHermesKeychainVault(service: "app.loopdy.management-proof." + UUID().uuidString)
        defer { try? vault.delete() }
        let transport = try await DirectHermesClient.connect(address: XCTUnwrap(config["address"]),
            auth: .token(XCTUnwrap(config["token"])), allowPrivateHTTP: true, vault: vault)
        let owner = WorkspaceOwner(authority: try XCTUnwrap(transport.savedConnection.workspaceAuthority),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        let current: @MainActor () -> WorkspaceOwner? = { owner }
        let mcp = DirectHermesMCPClient(http: transport, rpc: transport, owner: owner, profileID: "default", currentOwner: current)
        let plugins = DirectHermesPluginLifecycleClient(http: transport, owner: owner, currentOwner: current)
        let toolsets = DirectHermesToolsetClient(http: transport, owner: owner, profileID: "default", currentOwner: current)
        let memory = DirectHermesMemoryClient(rpc: transport, http: transport, owner: owner, currentOwner: current)
        let projects = DirectHermesProjectLifecycleClient(rpc: transport, http: transport, owner: owner, currentOwner: current)
        let operations = DirectHermesHostOperationsClient(rpc: transport, http: transport, owner: owner, currentOwner: current)
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("MCP catalog", { _ = try await mcp.load() }),
            ("MCP cached runtime", {
                let configured = try await mcp.load()
                _ = try await mcp.cachedRuntimeStatus(configuredServers: configured.servers)
            }),
            ("Plugin catalog", { _ = try await plugins.load() }),
            ("Toolsets", { _ = try await toolsets.load() }),
            ("Memory provider state", { _ = try await memory.memoryStatus() }),
            ("Curator state", { _ = try await memory.curatorStatus() }),
            ("Project overview", { _ = try await projects.overview(profileID: "default") }),
            ("System statistics", { _ = try await operations.systemStats() }),
            ("Egress state", { _ = try await operations.egressStatus() })
        ]
        for (name, check) in checks {
            do {
                try await check()
                print("NATIVE_MANAGEMENT_READ_PASS \(name)")
            } catch {
                XCTFail("\(name) failed native decoding/request: \(String(reflecting: type(of: error)))")
            }
        }
        let prior = try await memory.curatorStatus()
        let changed = try await memory.setCuratorPaused(!prior.isPaused)
        XCTAssertEqual(changed.isPaused, !prior.isPaused)
        let restored = try await memory.setCuratorPaused(prior.isPaused)
        XCTAssertEqual(restored.isPaused, prior.isPaused)
        print("NATIVE_MANAGEMENT_MUTATION_PASS Curator pause and restore")
        let files = DirectHermesManagedFilesClient(http: transport, binaryHTTP: transport,
            owner: owner, currentOwner: current)
        let scope = try await files.workspaceScope()
        let expectedRoot = try XCTUnwrap(config["workspace_path"])
        XCTAssertEqual(Data(scope.root.utf8), Data(expectedRoot.utf8))
        let payload = Data("bighelp confined workspace round trip\n".utf8)
        let uploaded = try await files.upload(bytes: payload, fileName: "scope-proof.txt",
            mimeType: "text/plain", to: scope.root)
        let downloaded = try await files.download(uploaded)
        XCTAssertEqual(downloaded.bytes, payload)
        let workspace = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
            capabilities: .init(owner: owner, values: [.filesRead: .available]), currentOwner: current)
        let artifacts = WorkspaceArtifactsStore(hostName: "Disposable fixture", owner: owner,
            scope: scope, performer: workspace, scopeValidator: { try await files.workspaceScope() },
            isCurrent: { current() == owner })
        await artifacts.refresh()
        XCTAssertNil(artifacts.errorMessage)
        XCTAssertTrue(artifacts.files.contains { Data($0.path.utf8) == Data(uploaded.path.utf8) })
        try await files.delete(uploaded)
        let remaining = try await files.list()
        XCTAssertFalse(remaining.files.contains { Data($0.path.utf8) == Data(uploaded.path.utf8) })
        print("NATIVE_MANAGEMENT_MUTATION_PASS Configured workspace upload, download, Artifacts and delete")
        let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let source = stagingDirectory.appendingPathComponent("bounded-stream.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let output = try FileHandle(forWritingTo: source)
        let chunk = Data(repeating: 0x5a, count: 64 * 1_024)
        for _ in 0..<12 { try output.write(contentsOf: chunk) }
        try output.close()
        let streamed = try await files.upload(localFile: source, byteCount: chunk.count * 12,
            fileName: "bounded-stream.bin", mimeType: "application/octet-stream", to: scope.root)
        XCTAssertEqual(streamed.byteCount, chunk.count * 12)
        try await files.delete(streamed)
        print("NATIVE_MANAGEMENT_MUTATION_PASS File-backed multipart upload with incremental hash readback and cleanup")
        let logs = DirectHermesLogsClient(http: transport, workspace: workspace, owner: owner, currentOwner: current)
        let logPage = try await logs.read(HermesLogQuery())
        XCTAssertLessThanOrEqual(logPage.entries.count, HermesLogQuery.initialLineLimit)
        print("NATIVE_MANAGEMENT_READ_PASS Bounded stock logs")
        let maintenance = DirectHermesSessionMaintenanceClient(rpc: transport, http: transport, owner: owner,
            currentOwner: current,
            resolveClosableRuntime: { _ in throw DirectHermesError.invalidResponse },
            reconcileClosedRuntime: { _ in throw DirectHermesError.invalidResponse })
        let ownershipReview = try await maintenance.prepareOwnerBackfill(profileID: "default")
        let ownershipResult = try await maintenance.ownerBackfill(reviewed: ownershipReview)
        XCTAssertEqual(ownershipResult.profileID, "default")
        XCTAssertEqual(ownershipResult.stampedRows, 0)
        XCTAssertEqual(ownershipResult.remainingUnownedRows, 0)
        print("NATIVE_MANAGEMENT_MUTATION_PASS Empty-profile owner backfill and idempotent verification")
        // A valid, silent PCM fixture exercises AVPlayer through the real
        // authenticated HEAD/Range path without playing household content.
        var wave = Data()
        func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
        func dword(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
        wave.append(Data("RIFF".utf8)); dword(16_036); wave.append(Data("WAVEfmt ".utf8))
        dword(16); word(1); word(1); dword(8_000); dword(16_000); word(2); word(16)
        wave.append(Data("data".utf8)); dword(16_000); wave.append(Data(repeating: 0, count: 16_000))
        let audio = try await files.upload(bytes: wave, fileName: "native-playback-proof.wav", mimeType: "audio/x-wav", to: scope.root)
        let playback = DirectHermesManagedMediaPlayback(file: audio, reader: files)
        defer { playback.retire() }
        await playback.start()
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline && playback.errorMessage == nil {
            if playback.isReady && playback.player.currentTime().seconds > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(playback.errorMessage)
        XCTAssertTrue(playback.isReady, "AVPlayer must decode the real ranged audio asset.")
        XCTAssertGreaterThan(playback.player.currentTime().seconds, 0)
        playback.retire()
        try await files.delete(audio)
        print("NATIVE_MANAGEMENT_MUTATION_PASS Authenticated native AVPlayer range playback and cleanup")
        await transport.disconnect()
    }
}
