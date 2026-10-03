import Foundation
import Testing
@testable import Bighelp

@Suite(.serialized)
@MainActor
struct IndependentHostScopeTests {
    @Test func savedCloudChatSelectionCannotSelectChatTransportOnLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("link", forKey: "loopdy.hosts.connection-mode.v2")
        fixture.registry.restoreConnectionSelection(deviceID: "existing-cloud-device", authorizationEpoch: 7)
        #expect(fixture.registry.connectionMode == .independent)
        #expect(fixture.registry.canConfigureHosts)
        #expect(fixture.registry.accountID == nil)
        fixture.registry.bind(deviceID: "different-cloud-device", authorizationEpoch: 8)
        #expect(fixture.registry.connectionMode == .independent)
        #expect(fixture.registry.accountID == nil)
    }

    @Test func freshInstallCanPrepareHostAuthenticationWithoutAccountOrFakeIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.registry.restoreConnectionSelection(deviceID: nil, authorizationEpoch: nil)
        #expect(fixture.registry.connectionMode == .independent)
        #expect(fixture.registry.canConfigureHosts)
        #expect(fixture.registry.accountID == nil)
        #expect(!fixture.registry.isAccountReady)
        let pending = try fixture.registry.makePendingWorkspace()
        #expect(!pending.1.isConnected)
        #expect(pending.1.savedConnection == nil)
        #expect(throws: DirectHermesError.secureStorageChanged) {
            try fixture.registry.commit(pending.0, workspace: pending.1, name: "Not authenticated")
        }
        #expect(fixture.registry.hosts.isEmpty)
        fixture.registry.discardPending(pending.0)
    }

    @Test func independentSelectionAndCredentialsSurviveCloudAccountChangesAndErasure() throws {
        let fixture = try Fixture(useProductionCredentialService: true)
        defer { fixture.cleanup() }
        fixture.registry.restoreConnectionSelection(deviceID: nil, authorizationEpoch: nil)
        let saved = try fixture.seedHost(userID: "independent-person", mode: .independent)
        let selected = fixture.registry.selectedHostID
        fixture.registry.bind(deviceID: "cloud-device", authorizationEpoch: 2)
        fixture.registry.bind(deviceID: nil, authorizationEpoch: nil)
        #expect(fixture.registry.connectionMode == .independent)
        #expect(fixture.registry.selectedHostID == selected)
        #expect(fixture.registry.accountID == nil)
        #expect(try fixture.registry.credentialVault(for: saved.host).load() == saved.connection)
        #expect(FileManager.default.fileExists(atPath: fixture.metadataFile(mode: .independent).path))
    }

    @Test func legacyAccountHostsAreNotAdoptedByMatchingAddressOrNewNativeScope() throws {
        let fixture = try Fixture(useProductionCredentialService: true)
        defer { fixture.cleanup() }
        fixture.registry.bind(deviceID: "legacy-device", authorizationEpoch: 1)
        let saved = try fixture.seedHost(userID: "legacy-person", mode: .link)
        let legacyFile = fixture.metadataFile(mode: .link)
        let original = try Data(contentsOf: legacyFile)
        fixture.registry.bind(deviceID: nil, authorizationEpoch: nil)
        #expect(fixture.registry.connectionMode == .independent)
        #expect(fixture.registry.hosts.isEmpty)
        #expect(fixture.registry.selectedHostID == nil)
        #expect(try Data(contentsOf: legacyFile) == original)
        let legacyVault = DirectHermesKeychainVault(
            service: fixture.service, account: "host-v1.\(saved.host.accountScope).\(saved.host.id.uuidString)"
        )
        #expect(try legacyVault.load() == saved.connection)
        let independent = try fixture.seedHost(userID: "different-person", mode: .independent)
        #expect(independent.host.endpoint == saved.host.endpoint)
        #expect(fixture.registry.hosts == [independent.host])
        #expect(!DirectHermesIdentity.matches(independent.host.principalIdentity, saved.host.principalIdentity))
    }

    @Test func explicitHostRemovalDoesNotSelectAnotherAuthority() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.registry.restoreConnectionSelection(deviceID: nil, authorizationEpoch: nil)
        let first = try fixture.seedHost(userID: "first", mode: .independent)
        let second = try fixture.seedHost(userID: "second", mode: .independent)
        #expect(fixture.registry.selectedHostID == second.host.id)
        try fixture.registry.remove(second.host)
        #expect(fixture.registry.selectedHostID == nil)
        #expect(fixture.registry.selectedWorkspace == nil)
        #expect(fixture.registry.hosts == [first.host])
    }

    /// Renaming changes only the name people see; it's saved, and the address,
    /// sign-in and selection stay as they were.
    @Test func renamingAHostKeepsItsConnection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.registry.restoreConnectionSelection(deviceID: nil, authorizationEpoch: nil)
        let saved = try fixture.seedHost(userID: "person", mode: .independent)
        try fixture.registry.rename(saved.host.id, to: "  Studio Mac  ")
        #expect(fixture.registry.hosts.first?.name == "Studio Mac")
        #expect(fixture.registry.hosts.first?.endpoint == saved.host.endpoint)
        #expect(fixture.registry.hosts.first?.principalIdentity == saved.host.principalIdentity)
        #expect(fixture.registry.selectedHostID == saved.host.id)
        fixture.registry.retryLoading()
        #expect(fixture.registry.hosts.first?.name == "Studio Mac", "The name survives a relaunch")
        #expect(throws: (any Error).self) { try fixture.registry.rename(saved.host.id, to: "   ") }
        #expect(fixture.registry.hosts.first?.name == "Studio Mac")
    }

    @Test func nativeMetadataCannotClaimACloudAccountIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.registry.restoreConnectionSelection(deviceID: nil, authorizationEpoch: nil)
        let saved = try fixture.seedHost(userID: "person", mode: .independent)
        let file = fixture.metadataFile(mode: .independent)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var hosts = try #require(document["hosts"] as? [[String: Any]])
        hosts[0]["accountID"] = "forged-cloud-device"
        document["hosts"] = hosts
        let forged = try JSONSerialization.data(withJSONObject: document)
        try forged.write(to: file)
        fixture.registry.retryLoading()
        #expect(!fixture.registry.storageIsReadable)
        #expect(!fixture.registry.canConfigureHosts)
        #expect(try Data(contentsOf: file) == forged)
        #expect(saved.host.accountID == nil)
    }

    @MainActor private final class Fixture {
        let directory: URL
        let linkedRoot: URL
        let independentRoot: URL
        let registry: BighelpHostRegistry
        let service: String
        let defaults: UserDefaults
        private let suite: String
        private var vaults: [any DirectHermesCredentialVault] = []
        private var scopes: [BighelpHostConnectionMode: String] = [:]

        init(useProductionCredentialService: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "native-host-test-\(UUID().uuidString)")
            linkedRoot = directory.appending(path: "linked", directoryHint: .isDirectory)
            independentRoot = directory.appending(path: "independent", directoryHint: .isDirectory)
            suite = "loopdy.tests.host-scopes.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            service = useProductionCredentialService ? "app.loopdy.mobile.direct-hermes"
                : "app.loopdy.tests.host-scopes.\(UUID().uuidString)"
            registry = BighelpHostRegistry(root: linkedRoot, keychainService: service,
                                         independentRoot: independentRoot, defaults: defaults)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func seedHost(userID: String, mode: BighelpHostConnectionMode) throws
            -> (host: BighelpConfiguredHost, connection: DirectHermesSavedConnection) {
            let scope = try #require(registry.accountScope)
            scopes[mode] = scope
            let endpoint = try DirectHermesEndpoint(address: "https://host.example")
            let connection = DirectHermesSavedConnection(
                endpoint: endpoint,
                authentication: .bearer(accessToken: UUID().uuidString, refreshToken: nil, expiresAt: nil),
                provider: "basic", userID: userID
            )
            let host = BighelpConfiguredHost(
                id: UUID(), accountScope: scope, accountID: registry.accountID,
                endpoint: endpoint, principalIdentity: connection.identity, name: userID,
                connectionMode: mode == .independent ? .independent : nil
            )
            let vault = registry.credentialVault(for: host)
            try vault.save(connection)
            vaults.append(vault)
            struct Snapshot: Encodable {
                let version: Int
                let hosts: [BighelpConfiguredHost]
                let selected: UUID
            }
            let root = mode == .independent ? independentRoot : linkedRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(Snapshot(version: mode == .independent ? 2 : 1,
                                              hosts: registry.hosts + [host], selected: host.id))
                .write(to: root.appending(path: scope + ".json"))
            registry.retryLoading()
            #expect(registry.storageIsReadable)
            return (host, connection)
        }

        func metadataFile(mode: BighelpHostConnectionMode) -> URL {
            let root = mode == .independent ? independentRoot : linkedRoot
            return root.appending(path: (scopes[mode] ?? "missing") + ".json")
        }

        func cleanup() {
            for vault in vaults { try? vault.delete() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
