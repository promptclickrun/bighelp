import CryptoKit
import Foundation
import Testing
@testable import Bighelp

@MainActor
struct WikiNativeTests {
    @Test(arguments: [false, true])
    func historicalJournalsBeyondScopeQuotaCanBeErased(deletingAccount: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-many-scopes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let owners = try seedHistoricalWikiScopes(persistence, accountID: "many-scopes", deviceID: "device")
        let unrelated = WikiConnectionProbe().owner
        try persistence.save(WikiLocalState(owner: unrelated, connections: [], saves: []))
        try persistence.saveFolders([WikiFolderPreference(id: UUID(), name: "Private", folderPath: "/private")], owner: unrelated)
        // A deliberate removal must win over a retained historical connection.
        try persistence.saveFolders([], owner: owners[0])
        let services = OptionalReferenceServices(workspace: BighelpLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: persistence)
        services.bind(owner: owners[0], accountID: nil, currentOwner: { owners[0] })
        try services.eraseAccountData(preservingWikiFolders: !deletingAccount)
        for (index, owner) in owners.enumerated() {
            #expect(try persistence.load(owner: owner) == nil)
            #expect(try persistence.loadFolders(owner: owner).map(\.folderPath)
                == (deletingAccount || index == 0 ? [] : ["/notes"]))
        }
        #expect(try persistence.load(owner: unrelated) != nil)
        #expect(try persistence.loadFolders(owner: unrelated).map(\.folderPath) == ["/private"])
    }

    @Test(arguments: [false, true])
    func signOutRetainsNewestEpochBeyondJournalQuota(readBeforeCleanup: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-many-epochs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let root = WikiConnectionProbe().root
        var owners: [WikiOwner] = []
        for index in 0..<65 {
            let owner = WikiOwner(accountID: "many-epochs", hostID: "host", profileID: "default",
                deviceID: "device", authorizationEpoch: String(index + 1))
            owners.append(owner)
            try persistence.save(WikiLocalState(owner: owner,
                connections: [WikiConnection(owner: owner, name: "Epoch-\(index)", root: root)], saves: []))
            // Explicit modification dates avoid filesystem timestamp ties.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))],
                ofItemAtPath: historicalWikiFile(directory: directory, owner: owner).path)
        }
        if readBeforeCleanup {
            #expect(try persistence.loadFolders(owner: owners[0]).map(\.name) == ["Epoch-64"])
        }
        try persistence.signOut(accountID: "many-epochs")
        for owner in owners {
            #expect(try persistence.load(owner: owner) == nil)
            #expect(try persistence.loadFolders(owner: owner).map(\.name) == ["Epoch-64"])
        }
    }

    @Test(arguments: ["corrupt", "oversized", "invalidState"])
    func historicalCleanupFailsWithoutErasingAnyJournalWhenDataIsInvalid(damage: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-corrupt-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let owners = try seedHistoricalWikiScopes(persistence, accountID: "damaged-history", deviceID: "device")
        // Existing tombstones must not bypass journal validation during cleanup.
        for owner in owners { try persistence.saveFolders([], owner: owner) }
        let damaged = try historicalWikiFile(directory: directory, owner: owners[0])
        let original = try Data(contentsOf: damaged)
        switch damage {
        case "oversized":
            let handle = try FileHandle(forWritingTo: damaged)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 40 * 1_024 * 1_024 + 1)
        case "invalidState":
            var state = try JSONDecoder().decode(WikiLocalState.self, from: original)
            state.connections.append(state.connections[0])
            try JSONEncoder().encode(state).write(to: damaged)
        default: try Data("not JSON".utf8).write(to: damaged)
        }
        #expect(throws: (any Error).self) { try persistence.signOut(accountID: "damaged-history") }
        for owner in owners {
            #expect(FileManager.default.fileExists(atPath: try historicalWikiFile(directory: directory, owner: owner).path))
        }
        try original.write(to: damaged)
        try persistence.signOut(accountID: "damaged-history")
        for owner in owners {
            #expect(try persistence.load(owner: owner) == nil)
            #expect(try persistence.loadFolders(owner: owner).isEmpty)
        }
    }

    private func historicalWikiFile(directory: URL, owner: WikiOwner) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try directory.appendingPathComponent(WikiLimits.digest(Data(owner.accountID.utf8)))
            .appendingPathComponent(WikiLimits.digest(encoder.encode(owner)) + ".json")
    }

    private func seedHistoricalWikiScopes(_ persistence: WikiLocalPersistence, accountID: String,
                                         deviceID: String) throws -> [WikiOwner] {
        // The existing writer accepts a 65th snapshot when it sees 64 siblings.
        // These are real persisted private operation journals, not a persistence mock.
        try (0..<65).map { index in
            let owner = WikiOwner(accountID: accountID, hostID: "host-\(index)", profileID: "default",
                deviceID: deviceID, authorizationEpoch: "1")
            let root = WikiConnectionProbe().root
            let connection = WikiConnection(owner: owner, name: "Notes-\(index)", root: root)
            let source = "private draft \(index)"
            let bytes = Data(source.utf8)
            let document = try WikiDocument(connection: connection, path: "note.md",
                bytes: WikiBytes(data: bytes, revision: "wiki-v1:\(root.generation):\(WikiLimits.digest(bytes))"))
            let save = WikiPendingSave(operationId: "private-operation-\(index)", document: document,
                workingSource: source, sha256: WikiLimits.digest(bytes), phase: .prepared, nextOffset: 0)
            try persistence.save(WikiLocalState(owner: owner, connections: [connection], saves: [save]))
            return owner
        }
    }

    @Test func preferencePreparationGuardsDirectReadsAndEveryMutationAfterRestore() async throws {
        let client = WikiConnectionProbe()
        let memory = WikiConnectionMemory()
        let store = WikiStore(owner: nil, client: nil, persistence: memory)
        var blocked = false
        store.setContext(owner: client.owner, client: client, preparePreferences: {
            if blocked { throw WikiError.quota }
        })
        let connection = try await store.connect(name: "Retained", folderPath: "/notes")
        let folders = memory.folders
        blocked = true
        #expect(throws: WikiError.quota) { try store.restoreLocalState() }
        #expect(throws: WikiError.quota) { try store.renameFolder(id: connection.id, name: "Lost") }
        #expect(throws: WikiError.quota) { try store.removeFolder(id: connection.id) }
        #expect(throws: WikiError.quota) { try store.disconnect(connection) }
        #expect(throws: WikiError.quota) { try store.connect(name: "Lost", root: client.root) }
        do { _ = try await store.connect(name: "Lost", folderPath: "/notes"); Issue.record("Expected preparation failure") }
        catch { #expect(error as? WikiError == .quota) }
        do { try await store.discoverRoots(); Issue.record("Expected preparation failure") }
        catch { #expect(error as? WikiError == .quota) }
        #expect(client.connectPaths == ["/notes"])
        #expect(memory.folders == folders)
        #expect(store.savedFolders == folders)
        #expect(store.connections == [connection])
        blocked = false
        try store.renameFolder(id: connection.id, name: "Recovered")
        #expect(memory.folders.first?.name == "Recovered")
        try store.removeFolder(id: connection.id)
        #expect(memory.folders.isEmpty)
    }

    @Test func unconfiguredWikiStoreIsInertAndOptional() {
        let store = WikiStore(owner: nil, client: nil)
        #expect(store.connections.isEmpty)
        #expect(!store.isLoading)
    }

    @Test func oldHostOperationNegotiationShowsPluginUpdateInstruction() {
        let failure = WikiError.safe(BighelpLinkLiveSocketError.hostUpdateRequired)
        #expect(failure == .remote("UNSUPPORTED_OPERATION"))
        #expect(failure.localizedDescription.contains("Update its bighelp plugin"))
    }

    @Test func preparedWikiConnectPreservesHostUpdateRequiredWithoutFallback() async throws {
        let owner = WikiConnectionProbe().owner
        let messaging = WikiOldHostMessaging()
        let client = WikiLinkClient(owner: owner, workspace: BighelpLinkWorkspaceClient(messaging: messaging),
                                    currentOwner: { owner })
        do { _ = try await client.connect(folderPath: "/notes"); Issue.record("Old host must reject connect") }
        catch { #expect(WikiError.safe(error) == .remote("UNSUPPORTED_OPERATION")) }
        #expect(messaging.preparedCalls == 1)
        #expect(messaging.unpreparedCalls == 0)
    }

    @Test func folderConnectionRegistersAndInfersName() async throws {
        let client = WikiConnectionProbe()
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        let connection = try await store.connect(name: "", folderPath: "/notes")
        #expect(client.connectPaths == ["/notes"])
        #expect(connection.name == "Notes")
        #expect(connection.readOnly)
        #expect(connection.root.folderPath == "/notes")
        #expect(store.connections == [connection])
    }

    @Test func authenticatedWritableFolderConnectEnablesEditingByDefault() async throws {
        let root = WikiRoot(wikiId: "notes", name: "Notes", writable: true, sourceKind: "files",
            generation: String(repeating: "a", count: 32), folderPath: "/notes")
        let client = WikiConnectionProbe(root: root)
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        let connection = try await store.connect(name: "", folderPath: "/notes")
        #expect(connection.allowsEditing, "Account-authorized folder Save connects read and write")
    }

    @Test func savedFolderReconnectsWithCurrentAuthorityAfterAccountEpochChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-selection-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = WikiConnectionProbe()
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let legacy = WikiConnection(owner: previous.owner, name: "My notes", root: previous.root)
        // Seed the existing on-disk format: migration must keep the selection,
        // not the old authority, across a fresh store and authorization epoch.
        try persistence.save(WikiLocalState(owner: previous.owner, connections: [legacy], saves: []))
        let currentOwner = WikiOwner(accountID: previous.owner.accountID, hostID: previous.owner.hostID,
            profileID: previous.owner.profileID, deviceID: "replacement-device", authorizationEpoch: "2")
        let freshRoot = WikiRoot(wikiId: "fresh-notes", name: "Notes", writable: true, sourceKind: "files",
            generation: String(repeating: "b", count: 32), folderPath: "/notes")
        let current = WikiConnectionProbe(owner: currentOwner, root: freshRoot)
        let store = WikiStore(owner: currentOwner, client: current,
            persistence: WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable()))
        try store.restoreLocalState()
        #expect(store.connections.isEmpty, "Retained selection is not an active authority handle")
        #expect(store.pendingSaves.isEmpty)
        try await store.discoverRoots()
        #expect(current.connectPaths == ["/notes"], "Reconnect retained folder using current authenticated client")
        let restored = try #require(store.connections.first)
        #expect(restored.owner == currentOwner)
        #expect(restored.root == freshRoot)
        #expect(restored.name == "My notes")
        #expect(restored.allowsEditing)
        store.setContext(owner: nil, client: nil)
        #expect(store.connections.isEmpty)
        #expect(store.authorizedRoots.isEmpty)
        #expect(store.document == nil)
    }

    @Test(arguments: ["generated", "mirror", "export", "unknown"])
    func nonFileSourcesRemainReadOnly(sourceKind: String) async throws {
        let root = WikiRoot(wikiId: "notes", name: "Notes", writable: true, sourceKind: sourceKind,
            generation: String(repeating: "a", count: 32), folderPath: "/notes")
        let client = WikiConnectionProbe(root: root)
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        #expect(try await !store.connect(name: "", folderPath: "/notes").allowsEditing)
    }

    @Test func reconnectReplacesOldGrantAndKeepsExplicitReadOnlyChoice() async throws {
        let root = WikiRoot(wikiId: "notes", name: "Notes", writable: true, sourceKind: "files",
            generation: String(repeating: "b", count: 32), folderPath: "/notes")
        let client = WikiConnectionProbe(root: root)
        client.listedRoot = WikiRoot(wikiId: "notes", name: "Notes", writable: false, sourceKind: "files",
            generation: String(repeating: "a", count: 32), folderPath: "/notes")
        let memory = WikiConnectionMemory()
        let store = WikiStore(owner: client.owner, client: client, persistence: memory)
        _ = try await store.connect(name: "Chosen", folderPath: "/notes", readOnly: true)
        store.setContext(owner: client.owner, client: client)
        try await store.discoverRoots()
        #expect(store.authorizedRoots == [root])
        #expect(store.connections.first?.readOnly == true)
        #expect(store.connections.first?.root.generation == root.generation)
    }

    @Test func preferenceWriteFailureDoesNotPublishOrForgetSelections() async throws {
        let client = WikiConnectionProbe()
        let memory = WikiConnectionMemory()
        let store = WikiStore(owner: client.owner, client: client, persistence: memory)
        memory.failFolderSave = true
        do { _ = try await store.connect(name: "Notes", folderPath: "/notes"); Issue.record("Expected failed persistence") }
        catch { #expect(error as? WikiError == .quota) }
        #expect(store.connections.isEmpty)
        #expect(store.savedFolders.isEmpty)
        memory.failFolderSave = false
        let connection = try await store.connect(name: "Notes", folderPath: "/notes")
        memory.failFolderSave = true
        do { try store.removeFolder(id: connection.id); Issue.record("Expected failed removal") }
        catch { #expect(error as? WikiError == .quota) }
        #expect(store.connections == [connection])
        #expect(store.savedFolders.count == 1)
        do { try store.renameFolder(id: connection.id, name: "Lost"); Issue.record("Expected failed rename") }
        catch { #expect(error as? WikiError == .quota) }
        #expect(store.savedFolders.first?.name == "Notes")
    }

    @Test func folderPreferencesAreIsolatedAndRemovalDoesNotResurrectLegacyState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-preferences-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = WikiConnectionProbe()
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let legacy = WikiConnection(owner: client.owner, name: "Old name", root: client.root)
        try persistence.save(WikiLocalState(owner: client.owner, connections: [legacy], saves: []))
        let store = WikiStore(owner: client.owner, client: client, persistence: persistence)
        try await store.discoverRoots()
        try store.renameFolder(id: legacy.id, name: "Renamed")
        #expect(try persistence.loadFolders(owner: client.owner).first?.name == "Renamed")
        for other in [
            WikiOwner(accountID: "other", hostID: client.owner.hostID, profileID: client.owner.profileID, deviceID: "d", authorizationEpoch: "1"),
            WikiOwner(accountID: client.owner.accountID, hostID: "other", profileID: client.owner.profileID, deviceID: "d", authorizationEpoch: "1"),
            WikiOwner(accountID: client.owner.accountID, hostID: client.owner.hostID, profileID: "other", deviceID: "d", authorizationEpoch: "1")
        ] {
            let otherClient = WikiConnectionProbe(owner: other)
            let otherStore = WikiStore(owner: other, client: otherClient, persistence: persistence)
            try await otherStore.discoverRoots()
            #expect(otherStore.savedFolders.isEmpty)
            #expect(otherClient.connectPaths.isEmpty)
        }
        try store.removeFolder(id: legacy.id)
        let reopened = WikiStore(owner: client.owner, client: client, persistence: persistence)
        try await reopened.discoverRoots()
        #expect(reopened.savedFolders.isEmpty)
        #expect(reopened.connections.isEmpty)
        #expect(client.connectPaths == ["/notes"])
    }

    @Test func failedReconnectRetainsRetryablePreferenceAndRemovalFencesLateResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = WikiConnectionProbe()
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let folder = WikiFolderPreference(id: UUID(), name: "Notes", folderPath: "/notes")
        try persistence.saveFolders([folder], owner: client.owner)
        let store = WikiStore(owner: client.owner, client: client, persistence: persistence)
        client.failConnect = true
        do { try await store.discoverRoots(); Issue.record("Expected unavailable folder") } catch { }
        #expect(store.savedFolders == [folder])
        #expect(store.connections.isEmpty)
        client.failConnect = false
        try await store.discoverRoots()
        #expect(store.connections.count == 1)
        store.setContext(owner: client.owner, client: client)
        client.suspend = true
        let reconnect = Task { try await store.discoverRoots() }
        for _ in 0..<100 where client.pending == nil { await Task.yield() }
        let pending = try #require(client.pending)
        try store.removeFolder(id: folder.id)
        pending.resume(returning: client.root)
        try await reconnect.value
        #expect(store.connections.isEmpty)
        #expect(try persistence.loadFolders(owner: client.owner).isEmpty)
    }

    @Test func referenceErasurePreservesOnlyFolderChoicesThenDeletesThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-eraser-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = WikiConnectionProbe()
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let legacy = WikiConnection(owner: client.owner, name: "Retained", root: client.root)
        let source = "private draft"
        let document = try WikiDocument(connection: legacy, path: "note.md",
            bytes: WikiBytes(data: Data(source.utf8), revision: "wiki-v1:\(client.root.generation):\(WikiLimits.digest(Data(source.utf8)))"))
        let save = WikiPendingSave(operationId: "private-operation", document: document, workingSource: source,
            sha256: WikiLimits.digest(Data(source.utf8)), phase: .prepared, nextOffset: 0)
        try persistence.save(WikiLocalState(owner: client.owner, connections: [legacy], saves: [save]))
        let references = OptionalReferenceServices(workspace: BighelpLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: persistence)
        references.bind(owner: client.owner, accountID: client.owner.accountID, currentOwner: { client.owner })
        try references.eraseAccountData(preservingWikiFolders: true)
        #expect(references.wiki.owner == nil)
        #expect(references.wiki.connections.isEmpty)
        #expect(references.wiki.pendingSaves.isEmpty)
        #expect(references.wikiClient == nil)
        #expect(try persistence.load(owner: client.owner) == nil)
        #expect(try persistence.loadFolders(owner: client.owner).map(\.name) == ["Retained"])
        references.bind(owner: client.owner, accountID: client.owner.accountID, currentOwner: { client.owner })
        try references.eraseAccountData()
        #expect(try persistence.loadFolders(owner: client.owner).isEmpty)
    }

    @Test func ownerReplacementRejectsLateFolderRegistration() async throws {
        let client = WikiConnectionProbe()
        client.suspend = true
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        let operation = Task { try await store.connect(name: "", folderPath: "/notes") }
        for _ in 0..<100 where client.pending == nil { await Task.yield() }
        let pending = try #require(client.pending)
        store.setContext(owner: nil, client: nil)
        pending.resume(returning: client.root)
        do { _ = try await operation.value; Issue.record("Late connection must fail") }
        catch { }
        #expect(store.connections.isEmpty)
        #expect(store.authorizedRoots.isEmpty)
    }

    @Test func wikiReferenceKeepsSourcePathAndCleanTitle() throws {
        let client = WikiConnectionProbe()
        let connection = WikiConnection(owner: client.owner, name: "Notes", root: client.root)
        let bytes = Data("# Plan\nNested source\n".utf8)
        let document = try WikiDocument(connection: connection, path: "nested/plan.md",
            bytes: WikiBytes(data: bytes, revision: "wiki-v1:\(client.root.generation):\(WikiLimits.digest(bytes))"))
        let snapshot = try #require(ReferenceWikiAdapter.options(for: document).first).snapshot
        #expect(snapshot.title == "plan.md")
        #expect(snapshot.selectedContent.contains("Wiki source path (JSON):"))
        #expect(snapshot.selectedContent.contains("nested"))
        #expect(snapshot.selectedContent.hasSuffix("# Plan\nNested source\n"))
    }

    @Test func emptyWikiReferenceBrowseIncludesNestedFilesAndRevalidatesLocationOnly() async throws {
        let client = WikiConnectionProbe()
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        _ = try await store.connect(name: "", folderPath: "/notes")
        let owner = ReferenceHubOwner(accountID: client.owner.accountID, hostID: client.owner.hostID,
            deviceID: try #require(client.owner.deviceID), authorizationEpoch: "1", sessionID: "fixture-session",
            agentID: client.owner.profileID, recipientIDs: ["default"])
        let adapter = ReferenceWikiAdapter(store: store, client: client, owner: client.owner,
            connections: store.connections, ownerIsCurrent: { $0 == owner })
        let page = try await adapter.provider.search(owner, .wiki, "")
        #expect(page.results.map(\.title) == ["plan.md", "paper.pdf"])
        let result = try #require(page.results.first(where: { $0.title == "paper.pdf" }))
        let preview = try await adapter.provider.resolve(owner, result)
        #expect(preview.sourceKindLabel.contains("contents not included"))
        let snapshot = try #require(preview.options.first).snapshot
        let metadata = try JSONDecoder().decode([String: BighelpJSONValue].self, from: Data(snapshot.selectedContent.utf8))
        #expect(metadata["sourcePath"]?.string == "/notes/nested/paper.pdf")
        #expect(client.readCalls == 0)
        client.fileSize = 2_048
        let changed = try await adapter.provider.revalidate(owner, snapshot)
        #expect(!changed.hasSameContent(as: snapshot))
        #expect(client.readCalls == 0)
    }

    @Test func hostFilenameSearchFindsFilesOutsideInitialCatalogWithoutBodyMatches() async throws {
        let client = WikiConnectionProbe()
        let revision = "wiki-v1:\(client.root.generation):\(WikiLimits.digest(Data("host-name-only".utf8)))"
        client.hostNameMatches = [
            WikiSearchMatch(path: "beyond-initial-catalog/name-only.md", title: "name-only.md", snippet: nil, revision: revision),
            WikiSearchMatch(path: "beyond-initial-catalog/name-only.pdf", title: "name-only.pdf", snippet: nil, revision: revision)
        ]
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        _ = try await store.connect(name: "", folderPath: "/notes")
        let owner = ReferenceHubOwner(accountID: client.owner.accountID, hostID: client.owner.hostID,
            deviceID: try #require(client.owner.deviceID), authorizationEpoch: "1", sessionID: "fixture-session",
            agentID: client.owner.profileID, recipientIDs: ["default"])
        let adapter = ReferenceWikiAdapter(store: store, client: client, owner: client.owner,
            connections: store.connections, ownerIsCurrent: { $0 == owner })
        // The initial listing contains only plan.md/paper.pdf; content search
        // returns no matches. Both results must come from host filename search.
        let page = try await adapter.provider.search(owner, .wiki, "name-only")
        #expect(page.results.map(\.title) == ["name-only.md", "name-only.pdf"])
        #expect(client.searchModes == [.name, .content])
        #expect(client.readCalls == 0)
    }

    @Test func legacyRootDecodesAndMatchesSameGrantWithNewPathMetadata() throws {
        let root = WikiConnectionProbe().root
        var legacy = root
        legacy.folderPath = nil
        let decoded = try JSONDecoder().decode(WikiRoot.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.folderPath == nil)
        #expect(decoded.matchesGrant(root))
        var different = root
        different.folderPath = "/other"
        #expect(!root.matchesGrant(different))
        #expect(BighelpLinkWorkspaceOperation.wikiConnect.requiresHostCapability)
        #expect(BighelpLinkWorkspaceOperation.wikiConnect.requiredCapability == "wiki.v1")
    }
}

private final class WikiSelectionAvailability: BighelpProtectedDataAvailabilityProviding, @unchecked Sendable {
    var isProtectedDataAvailable = true
}

private struct WikiSelectionAvailable: BighelpProtectedDataAvailabilityProviding {
    var isProtectedDataAvailable: Bool { true }
}

@MainActor private final class WikiConnectionMemory: WikiPersistence {
    var folders: [WikiFolderPreference] = []
    var failFolderSave = false
    func loadFolders(owner: WikiOwner) throws -> [WikiFolderPreference] { folders }
    func saveFolders(_ folders: [WikiFolderPreference], owner: WikiOwner) throws {
        if failFolderSave { throw WikiError.quota }
        self.folders = folders
    }
    func load(owner: WikiOwner) throws -> WikiLocalState? { nil }
    func save(_ state: WikiLocalState) throws { }
    func deleteAccount(accountID: String) throws { }
}

@MainActor private final class WikiConnectionProbe: WikiClientProtocol {
    let owner: WikiOwner
    let root: WikiRoot
    init(owner: WikiOwner = WikiOwner(accountID: "fixture-account", hostID: "fixture-host", profileID: "default",
                                      deviceID: "fixture-device", authorizationEpoch: "1"),
         root: WikiRoot = WikiRoot(wikiId: "notes", name: "Notes", writable: false, sourceKind: "files",
                                  generation: String(repeating: "a", count: 32), folderPath: "/notes")) {
        self.owner = owner
        self.root = root
    }
    var listedRoot: WikiRoot?
    var connectPaths: [String] = []
    var fileSize = 1_024
    var readCalls = 0
    var hostNameMatches: [WikiSearchMatch] = []
    var searchModes: [WikiSearchMode] = []
    var failConnect = false
    var suspend = false
    var pending: CheckedContinuation<WikiRoot, Never>?
    func connect(folderPath: String) async throws -> WikiRoot {
        connectPaths.append(folderPath)
        if failConnect { throw WikiError.unavailable }
        if suspend { return await withCheckedContinuation { pending = $0 } }
        return root
    }
    func resolve(folderPath: String) async throws -> WikiRoot { throw WikiError.unavailable }
    func roots() async throws -> [WikiRoot] { [listedRoot ?? root] }
    func folderSuggestions(parentPath: String, prefix: String, offset: Int) async throws -> HermesWorkspaceFolderPage { throw WikiError.unavailable }
    func list(root: WikiRoot, path: String, offset: Int, revision: String?) async throws -> WikiDirectory {
        let entries = path.isEmpty
            ? [WikiEntry(name: "nested", path: "nested", kind: "directory", size: nil)]
            : [WikiEntry(name: "plan.md", path: "nested/plan.md", kind: "file", size: 20),
               WikiEntry(name: "paper.pdf", path: "nested/paper.pdf", kind: "file", size: fileSize)]
        return WikiDirectory(wikiId: root.wikiId, path: path, parent: WikiNavigation.parent(of: path),
            revision: "wiki-v1:\(root.generation):\(WikiLimits.digest(Data(String(fileSize).utf8)))",
            offset: offset, limit: 100, total: entries.count, entries: entries, nextOffset: nil)
    }
    func read(root: WikiRoot, path: String) async throws -> WikiBytes { readCalls += 1; throw WikiError.unavailable }
    func search(root: WikiRoot, query: String, mode: WikiSearchMode, offset: Int) async throws -> WikiSearchPage {
        searchModes.append(mode)
        return WikiSearchPage(wikiId: root.wikiId, query: query, mode: mode,
            matches: mode == .name ? hostNameMatches : [], nextOffset: nil, isComplete: true, indexedAt: nil)
    }
    func image(root: WikiRoot, path: String) async throws -> WikiBytes { throw WikiError.unavailable }
    func begin(_ save: WikiPendingSave) async throws -> WikiSaveResponse { throw WikiError.unavailable }
    func chunk(operationID: String, offset: Int, data: Data) async throws -> WikiSaveResponse { throw WikiError.unavailable }
    func commit(operationID: String) async throws -> WikiSaveResponse { throw WikiError.unavailable }
    func status(operationID: String) async throws -> WikiSaveResponse { throw WikiError.unavailable }
}

@MainActor private final class WikiOldHostMessaging: BighelpLinkWorkspaceMessaging {
    var preparedCalls = 0
    var unpreparedCalls = 0
    func performWorkspaceRequest(_ request: BighelpLinkWorkspaceRequest) async throws -> BighelpLinkWorkspaceResult {
        unpreparedCalls += 1
        throw WikiError.unavailable
    }
    func performPreparedWorkspaceRequest(_ request: BighelpLinkWorkspaceRequest) async throws -> BighelpLinkWorkspaceResult {
        preparedCalls += 1
        throw BighelpLinkLiveSocketError.hostUpdateRequired
    }
}
