import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NativeWorkspaceSessionBridgeTests {
    @Test func retainedStreamMayCrossConnectionGenerationForSameAuthenticatedAuthority() throws {
        let authority = try WorkspaceAuthority.fixture(id: "bridge-rebind")
        let authentication = UUID()
        let previous = WorkspaceOwner(
            authority: authority, authenticationGeneration: authentication,
            connectionGeneration: UUID()
        )
        let current = WorkspaceOwner(
            authority: authority, authenticationGeneration: authentication,
            connectionGeneration: UUID()
        )
        let storedID = "stored-session"
        let record = SessionRecord(
            id: try DirectHermesSessionIdentity.appID(
                owner: previous, profileID: "default", anchorID: storedID
            ),
            kind: .direct, agentIDs: ["default"], title: "New chat",
            remoteStoredID: storedID
        )

        #expect(NativeWorkspaceSessionBridge.canRebindRetainedStream(
            streamOwner: previous, owner: current, record: record,
            profileID: "default", storedID: storedID, runtimeID: "runtime-session"
        ))
    }

    /// "Resolve or save the pending work in 1 profile session(s)" blocked deleting
    /// an agent over a leftover draft. A rename keeps the agent's chats, so a
    /// draft still holds it; a delete removes them, drafts included.
    @Test func aLeftoverDraftBlocksRenameButNotDelete() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bridge-delete-\(UUID().uuidString)")
        let suite = "bridge-delete-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let hosts = BighelpHostRegistry(root: root.appending(path: "hosts"), keychainService: suite,
                                        independentRoot: root.appending(path: "independent"), defaults: defaults)
        let authority = try WorkspaceAuthority.fixture(id: "bridge-delete")
        let bridge = try NativeWorkspaceSessionBridge(connections: WorkspaceConnectionStore(hosts: hosts),
                                                      authority: authority, directory: root.appending(path: "sessions"))
        var record = DirectHermesDraftStore.Record()
        record.draft = "Half a thought"
        record.owner = .init(hostIdentity: authority.cacheScopeID, profile: "sage", storedID: "stored-1", title: "Chat")
        try bridge.drafts.save(record, scope: "sage-stored-1")

        #expect(throws: NativeWorkspaceLifecycleError.protectedProfileState(profileID: "sage", sessionIDs: ["stored-1"])) {
            _ = try bridge.retireProfileSessions(profileID: "sage")
        }
        _ = try bridge.retireProfileSessions(profileID: "sage", discardingLocalWork: true)
        #expect(try bridge.profileSessionOwnership(profileID: "sage").isEmpty)
    }

    /// Each connection restores the saved creation records. One it refuses (2.6.30 saved such a Bot Chat
    /// record) was thrown and stopped every chat on that computer; now only that record goes.
    @Test func aSavedCreationRecordTheConnectionRefusesIsLeftOut() throws {
        let authority = try WorkspaceAuthority.fixture(id: "bridge-records")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        func record(_ profile: String, phase: DirectHermesSessionCreationState.Phase, stored: String? = nil,
                    scope: String? = nil) -> (String, DirectHermesSessionCreationState) {
            (Data(profile.utf8).base64EncodedString(), DirectHermesSessionCreationState(
                schemaVersion: 1, intentID: UUID().uuidString, scopeID: scope ?? authority.cacheScopeID,
                profileID: profile, purpose: .firstCanonical, connectionGeneration: UUID(), phase: phase,
                storedSessionID: stored))
        }
        let saved = Dictionary(uniqueKeysWithValues: [
            record("alpha", phase: .createRequested),
            record("beta", phase: .created, stored: "stored-without-runtime"),
            record("gamma", phase: .createRequested, scope: "another-computer"),
        ])
        let kept = NativeWorkspaceSessionBridge.restorableCreationStates(saved, scopeID: authority.cacheScopeID,
                                                                         owner: owner)
        #expect(kept.values.map(\.profileID) == ["alpha"])
    }

    /// A record that isn't this computer's no longer stops the computer's chats from opening at all.
    @Test func theBridgeStartsWithoutASavedRecordThatIsntThisComputers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bridge-records-\(UUID().uuidString)")
        let suite = "bridge-records-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let hosts = BighelpHostRegistry(root: root.appending(path: "hosts"), keychainService: suite,
                                        independentRoot: root.appending(path: "independent"), defaults: defaults)
        let authority = try WorkspaceAuthority.fixture(id: "bridge-records")
        let sessions = root.appending(path: "sessions")
        func record(_ profile: String, scope: String) -> DirectHermesSessionCreationState {
            DirectHermesSessionCreationState(schemaVersion: 1, intentID: UUID().uuidString, scopeID: scope,
                                             profileID: profile, purpose: .ordinary, connectionGeneration: UUID(),
                                             phase: .createRequested)
        }
        try DemoRepository<[String: DirectHermesSessionCreationState]>(
            directory: sessions, name: "native-session-creation", seed: [:]
        ).save([
            Data("alpha".utf8).base64EncodedString(): record("alpha", scope: authority.cacheScopeID),
            Data("beta".utf8).base64EncodedString(): record("beta", scope: "another-computer"),
        ])
        _ = try NativeWorkspaceSessionBridge(connections: WorkspaceConnectionStore(hosts: hosts),
                                             authority: authority, directory: sessions)
        let kept = try DemoRepository<[String: DirectHermesSessionCreationState]>(
            directory: sessions, name: "native-session-creation", seed: [:]
        ).loadExistingPreservingSource()
        #expect(kept?.values.map(\.profileID) == ["alpha"])
    }

    @Test func retainedStreamMayAttemptDurableResumeAcrossACompactionSuccessor() throws {
        let authority = try WorkspaceAuthority.fixture(id: "bridge-lineage")
        let authentication = UUID()
        let previous = WorkspaceOwner(authority: authority, authenticationGeneration: authentication,
                                      connectionGeneration: UUID())
        let current = WorkspaceOwner(authority: authority, authenticationGeneration: authentication,
                                     connectionGeneration: UUID())
        let record = SessionRecord(
            id: try DirectHermesSessionIdentity.appID(owner: previous, profileID: "default", anchorID: "lineage-root"),
            kind: .direct, agentIDs: ["default"], title: "Retained chat", remoteStoredID: "catalog-tip-2"
        )
        // Eligibility is not adoption: the bridge must still resume the exact
        // retained tip and validate the returned pair against catalog readback.
        #expect(NativeWorkspaceSessionBridge.canRebindRetainedStream(
            streamOwner: previous, owner: current, record: record,
            profileID: "default", storedID: "catalog-tip-1", runtimeID: "old-runtime"
        ))
    }

    @Test(arguments: ["authority", "authentication", "malformedIdentity", "foreignIdentity", "profile", "missingStored", "missingRuntime"])
    func retainedStreamRebindIsFencedAtEveryIdentityBoundary(_ boundary: String) throws {
        let authority = try WorkspaceAuthority.fixture(id: "bridge-rebind")
        let authentication = UUID()
        let previous = WorkspaceOwner(
            authority: authority, authenticationGeneration: authentication,
            connectionGeneration: UUID()
        )
        let current = WorkspaceOwner(
            authority: boundary == "authority"
                ? try .fixture(id: "other-authority") : authority,
            authenticationGeneration: boundary == "authentication" ? UUID() : authentication,
            connectionGeneration: UUID()
        )
        let storedID = "stored-session"
        let profileID = boundary == "profile" ? "other" : "default"
        let runtimeID = boundary == "missingRuntime" ? "" : "runtime-session"
        let identityOwner = boundary == "foreignIdentity"
            ? WorkspaceOwner(authority: try .fixture(id: "foreign-identity"),
                             authenticationGeneration: authentication, connectionGeneration: UUID())
            : previous
        let canonicalID = try DirectHermesSessionIdentity.appID(
            owner: identityOwner, profileID: "default", anchorID: storedID
        )
        let record = SessionRecord(
            id: boundary == "malformedIdentity" ? "native-session-v1:malformed" : canonicalID,
            kind: .direct, agentIDs: ["default"], title: "New chat",
            remoteStoredID: storedID
        )

        #expect(!NativeWorkspaceSessionBridge.canRebindRetainedStream(
            streamOwner: previous, owner: current, record: record,
            profileID: profileID,
            storedID: boundary == "missingStored" ? "" : storedID, runtimeID: runtimeID
        ))
    }

    @Test func staleExactRetainedCoordinateCanEnterProductionReentryPath() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = WorkspaceOwner(
            authority: try .direct(
                endpointIdentity: "https://bridge-stale.example.test",
                providerID: "fixture", userID: "bridge-stale-reentry"
            ),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        let id = try DirectHermesSessionIdentity.appID(
            owner: owner, profileID: "default", anchorID: "stored"
        )
        let coordinate = try WorkspaceSessionCoordinate(
            owner: owner, profileID: "default", sessionID: id,
            storedSessionID: "stored", runtimeSessionID: "runtime"
        )
        let record = SessionRecord(
            id: id, kind: .direct, agentIDs: ["default"], title: "Retained",
            remoteStoredID: "stored"
        )
        let client = try DirectHermesConversationClient(
            rpc: BridgeTestRPC(), hostIdentity: owner.cacheScopeID,
            profile: "default", runtimeID: "runtime", storedID: "stored",
            title: "Retained", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root), workspaceSession: coordinate
        )
        let model = ChatModel(
            conversationID: id, client: client, initialItems: [], sourceSession: record
        )
        client.model = model
        client.suspend()

        #expect(NativeWorkspaceSessionBridge.canReenterRetainedStream(
            record: record, retainedRecord: record, model: model, owner: owner,
            streamOwner: owner, client: client
        ))
        #expect(!NativeWorkspaceSessionBridge.canReturnToPreparedStream(
            record: record, model: model, owner: owner, streamOwner: owner,
            recoveredCoordinate: coordinate, client: client
        ))
    }

    @Test func failedDeferredHydrateRollbackMergesConcurrentLiveActivity() async throws {
        let id = "rollback-live-activity"
        let snapshot = ChatActivityEvent(
            eventID: "existing", sessionID: id, turnID: "turn",
            kind: .tool, lifecycle: .running, title: "Existing",
            summary: nil, detail: nil, occurredAt: 1, toolCallID: "existing"
        )
        let live = ChatActivityEvent(
            eventID: "live", sessionID: id, turnID: "turn",
            kind: .tool, lifecycle: .running, title: "Live during hydrate",
            summary: nil, detail: nil, occurredAt: 2, toolCallID: "live"
        )
        var rollback = SessionRecord(
            id: id, kind: .direct, agentIDs: ["default"], title: "Retained",
            activityEvents: [snapshot]
        )
        let model = ChatModel(
            conversationID: id, client: ConversationFixtureClient(), initialItems: [],
            initialActivityEvents: [snapshot], sourceSession: rollback
        )
        let gate = BridgeTestGate()
        let hydrate = Task { @MainActor in
            await gate.wait()
            throw BridgeTestFailure.hydrate
        }
        while !gate.isWaiting { await Task.yield() }
        #expect(model.acceptActivity(live) == .inserted)
        gate.release()
        await #expect(throws: BridgeTestFailure.self) { try await hydrate.value }

        rollback.activityEvents = NativeWorkspaceSessionBridge.mergingPostSnapshotActivity(
            rollback.activityEvents,
            current: model.activityLedger.allEvents
        )
        model.reconcileHydratedSession(rollback)
        #expect(model.activityLedger.allEvents.map(\.id) == [snapshot.id, live.id])
    }

    @Test func submissionStartedDuringAwaitBlocksCanonicalReentryContinuation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = BridgeTestRPC()
        let gate = BridgeTestGate()
        rpc.handler = { method, _ in
            guard method == "prompt.submit" else { throw DirectHermesError.invalidResponse }
            await gate.wait()
            throw DirectHermesError.rpcRejected(code: 4001)
        }
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Retained",
            epoch: "epoch", drafts: DirectHermesDraftStore(root: root)
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let send = Task { @MainActor in
            try await client.send(message: "Concurrent send", conversationID: client.conversationID)
        }
        while !gate.isWaiting { await Task.yield() }

        #expect(client.hasPendingSubmission)
        #expect(!NativeWorkspaceSessionBridge.canContinueCanonicalReentry(client))
        gate.release()
        await #expect(throws: DirectHermesConversationClient.RejectedPrompt.self) { try await send.value }
    }
}

private enum BridgeTestFailure: Error {
    case hydrate
}

@MainActor
private final class BridgeTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            isWaiting = true
            self.continuation = continuation
        }
    }

    func release() {
        isWaiting = false
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class BridgeTestRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var handler: (@MainActor (String, [String: BighelpJSONValue]) async throws -> BighelpJSONValue)?

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        guard let handler else { throw DirectHermesError.invalidResponse }
        return try await handler(method, params)
    }

    func disconnect() async {}
}
