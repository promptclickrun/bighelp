import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesSessionCatalogClientTests {
    @Test(arguments: [false, true])
    func globalInventoryAssignsOnlyReplayProvenOwnerRegardlessOfProfileOrder(reversed: Bool) async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.activeSessions = [Self.activeSession(stored: "shared", status: "working")]
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.ownershipProfiles(reversed: reversed)
            case .sessionsList:
                let profile = try #require(payload["profile"]?.string)
                return Self.ownershipPage([Self.session(id: "shared", profile: profile)])
            case .sessionEvents: return Self.ownershipReplay(profile: "beta", stored: "shared")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        let records = try await client.list()
        #expect(records.count == 2)
        #expect(records.first { $0.agentIDs == ["alpha"] }?.isActive == false)
        #expect(records.first { $0.agentIDs == ["beta"] }?.isActive == true)
        let mappings = try client.activeSessionMappings()
        #expect(mappings.count == 1)
        #expect(mappings.first?.profileID == "beta")
        #expect(workspace.calls.filter { $0.operation == .nativeSessionActiveList }.count == 2)
        #expect(workspace.calls.filter { $0.operation == .nativeSessionActiveList }.allSatisfy { $0.payload.isEmpty })
        Self.expectReadOnlyDiscovery(workspace)
    }

    @Test func duplicateStoredKeysCanHaveIndependentlyProvenRuntimes() async throws {
        let workspace = try SessionWorkspaceStub()
        var beta = try #require(Self.activeSession(stored: "shared", status: "working").object)
        beta["id"] = .string("runtime-beta")
        workspace.activeSessions = [Self.activeSession(stored: "shared", status: "working"), .object(beta)]
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.ownershipProfiles()
            case .sessionsList:
                return Self.ownershipPage([Self.session(id: "shared", profile: try #require(payload["profile"]?.string))])
            case .sessionEvents:
                let runtime = try #require(payload["session_id"]?.string)
                return Self.ownershipReplay(profile: runtime == "runtime-beta" ? "beta" : "alpha", stored: "shared", runtime: runtime)
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        #expect(try await client.list().filter(\.isActive).count == 2)
        let mappings = try client.activeSessionMappings()
        #expect(Set(mappings.map(\.profileID)) == ["alpha", "beta"])
        #expect(Set(mappings.map(\.runtimeID)) == ["runtime-live", "runtime-beta"])
        Self.expectReadOnlyDiscovery(workspace)
    }

    @Test(arguments: ["missing-profile", "wrong-profile", "missing-key", "wrong-key", "wrong-runtime", "count", "sequence", "truncated", "conflicting-owner", "empty", "retired"])
    func unprovenReplayNeverPoisonsSavedRowsOrInventsDrafts(defect: String) async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.activeSessions = [Self.activeSession(stored: "shared", status: "working")]
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.ownershipProfiles()
            case .sessionsList: return Self.ownershipPage([])
            case .sessionEvents:
                var replay = Self.ownershipReplay(profile: "beta", stored: "shared")
                var events = try #require(replay["events"]?.array)
                var event = try #require(events[0].object)
                var info = try #require(event["payload"]?.object)
                switch defect {
                case "missing-profile": info["profile_name"] = nil
                case "wrong-profile": info["profile_name"] = .string("not-authorized")
                case "missing-key": info["stored_session_id"] = nil
                case "wrong-key": info["stored_session_id"] = .string("other")
                case "wrong-runtime": event["session_id"] = .string("other")
                case "count": replay["count"] = .integer(2)
                case "sequence": event["seq"] = .integer(2)
                case "truncated": replay["truncated"] = .boolean(true)
                case "conflicting-owner":
                    var conflicting = event
                    conflicting["seq"] = .integer(2)
                    conflicting["payload"] = .object(["profile_name": .string("alpha"), "stored_session_id": .string("shared")])
                    events.append(.object(conflicting))
                    replay["count"] = .integer(2); replay["latest_seq"] = .integer(2)
                case "retired": event["type"] = .string("session.reclaimed")
                default: break
                }
                event["payload"] = .object(info)
                events[0] = .object(event)
                if defect == "empty" { events = []; replay["count"] = .integer(0); replay["latest_seq"] = .integer(0) }
                replay["events"] = .array(events)
                return replay
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        // A REST match in only alpha is still not runtime ownership evidence.
        let replayHandler = workspace.handler
        workspace.handler = { operation, payload in
            if operation == .sessionsList {
                return Self.ownershipPage(payload["profile"] == .string("alpha") ? [Self.session(id: "shared")] : [])
            }
            return try await replayHandler(operation, payload)
        }
        let client = Self.client(workspace)
        let records = try await client.list()
        #expect(records.count == 1)
        #expect(records.first?.agentIDs == ["alpha"])
        #expect(records.first?.isActive == false)
        #expect(try client.activeSessionMappings().isEmpty)
        #expect(try client.attachedSession(try #require(records.first)) == nil)
        Self.expectReadOnlyDiscovery(workspace)
    }

    @Test func acknowledgedOwnIdleDraftSurvivesEmptyReplayAndCatalog() async throws {
        let workspace = try SessionWorkspaceStub()
        var active = try #require(Self.activeSession(stored: "ordinary", status: "idle", count: 0).object)
        active["id"] = .string("runtime")
        workspace.activeSessions = [.object(active)]
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.ownershipProfiles()
            case .sessionsList: return Self.ownershipPage([])
            case .sessionCreate:
                var response = Self.created(stored: "ordinary")
                response["info"] = .object(["profile_name": .string("alpha"), "model": .string("chosen-model"), "lazy": .boolean(false)])
                return response
            case .sessionEvents: return Self.ownershipEmptyReplay()
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { _ in })
        let created = try await client.createOrdinarySession(profileID: "alpha")
        let boundary = workspace.calls.count
        let records = try await client.list()
        #expect(records.map(\.id) == [created.record.id])
        let attached = try #require(try client.attachedSession(created.record))
        #expect(attached.coordinate == created.coordinate)
        #expect(attached.durability == .draft)
        #expect(attached.record.sessionRuntime == created.record.sessionRuntime)
        #expect(try client.activeSessionMappings().first?.profileID == "alpha")
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1)
        #expect(workspace.calls.dropFirst(boundary).allSatisfy { [.profilesList, .sessionsList, .nativeSessionActiveList, .sessionEvents].contains($0.operation) })
    }

    @Test(arguments: ["epoch", "owner", "gone", "changed-key"])
    func discoveryFenceRejectsChangedOwnershipCoordinates(change: String) async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.activeSessions = nil
        var inventoryReads = 0
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.ownershipProfiles()
            case .sessionsList: return Self.ownershipPage([])
            case .nativeSessionActiveList:
                inventoryReads += 1
                if inventoryReads == 2 {
                    if change == "epoch" { workspace.replayEpoch = "new-process" }
                    if change == "owner" { workspace.owner = nil }
                }
                return ["sessions": .array(inventoryReads == 2 && change == "gone" ? [] : [Self.activeSession(stored: inventoryReads == 2 && change == "changed-key" ? "other" : "shared", status: "working")])]
            case .sessionEvents:
                #expect(payload["session_id"] == .string("runtime-live"))
                return Self.ownershipReplay(profile: "beta", stored: "shared")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        if change == "owner" {
            await #expect(throws: WorkspaceClientError.ownerChanged) { try await client.list() }
        } else {
            #expect(try await client.list().isEmpty)
            #expect(try client.activeSessionMappings().isEmpty)
        }
        Self.expectReadOnlyDiscovery(workspace)
    }

    @Test(arguments: ["starting", "idle"])
    func replayProvenForeignDraftDoesNotClaimOnlyPersistedProfile(status: String) async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.activeSessions = [Self.activeSession(stored: "shared", status: status, count: 0)]
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.ownershipProfiles()
            case .sessionsList:
                return Self.ownershipPage(payload["profile"] == .string("alpha") ? [Self.session(id: "shared")] : [])
            case .sessionEvents: return Self.ownershipReplay(profile: "beta", stored: "shared")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        let rows = try await client.list()
        let saved = try #require(rows.first { $0.agentIDs == ["alpha"] })
        #expect(!saved.isActive)
        #expect(try client.attachedSession(saved) == nil)
        if status == "starting" {
            let draft = try #require(rows.first { $0.agentIDs == ["beta"] })
            let attached = try #require(try client.attachedSession(draft))
            #expect(attached.durability == .draft)
            #expect(!draft.hasAcceptedMessage)
            #expect(draft.items.isEmpty)
            #expect(attached.coordinate.runtimeSessionID == "runtime-live")
        } else {
            #expect(rows.count == 1)
            #expect(try client.activeSessionMappings().isEmpty)
        }
        Self.expectReadOnlyDiscovery(workspace)
    }

    @Test func duplicateRuntimeSnapshotDegradesWithoutDiscardingSavedRows() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.activeSessions = [Self.activeSession(stored: "shared", status: "working"),
                                    Self.activeSession(stored: "other", status: "working")]
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionsList: return Self.ownershipPage([Self.session(id: "shared")])
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        let rows = try await client.list()
        #expect(rows.count == 1)
        #expect(rows.first?.isActive == false)
        #expect(try client.activeSessionMappings().isEmpty)
        Self.expectReadOnlyDiscovery(workspace)
    }

    @Test(arguments: [false, true])
    func retainedReceiptSurvivesReadFailureButNotAnObservedEpochChange(changedEpoch: Bool) async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate: return Self.created(stored: "ordinary")
            case .sessionsList: return Self.ownershipPage([])
            case .nativeSessionActiveList: throw WorkspaceClientError.invalidResponse
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { _ in })
        let draft = try await client.createOrdinarySession(profileID: "alpha")
        workspace.activeSessions = nil
        if changedEpoch { workspace.replayEpoch = "new-process" }
        let rows = try await client.list()
        #expect(rows.map(\.id) == [draft.record.id])
        #expect(try client.activeSessionMappings().isEmpty == changedEpoch)
        #expect((try client.attachedSession(draft.record) == nil) == changedEpoch)
        #expect(try client.pendingCreation(profileID: "alpha")?.phase == .complete)
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1)
    }

    @Test func newerCreateReceiptWinsOverSuspendedDiscovery() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.activeSessions = [Self.activeSession(stored: "ordinary", status: "working")]
        var client: DirectHermesSessionCatalogClient!
        var created: DirectHermesResolvedSession?
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionsList: return Self.ownershipPage([])
            case .sessionCreate: return Self.created(stored: "ordinary")
            case .sessionEvents:
                // Reenter while list is awaiting runtime ownership evidence.
                created = try await client.createOrdinarySession(profileID: "alpha")
                return Self.ownershipReplay(profile: "alpha", stored: "ordinary")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        client = Self.client(workspace, sink: { _ in })
        let rows = try await client.list()
        let draft = try #require(created)
        #expect(rows.map(\.id) == [draft.record.id])
        #expect(try client.coordinate(for: draft.record.id).runtimeSessionID == "runtime")
        #expect(try client.activeSessionMappings().map(\.runtimeID) == ["runtime"])
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1)
    }

    @Test(arguments: [1, 2])
    func optionalEpochFailureDoesNotRevokeAcknowledgedActivation(failingRead: Int) async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate: return Self.created(stored: "ordinary")
            case .sessionActivate: return Self.attached(stored: "ordinary")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { _ in })
        let draft = try await client.createOrdinarySession(profileID: "alpha")
        var reads = 0
        workspace.epochHandler = {
            reads += 1
            if reads == failingRead { throw WorkspaceClientError.transportUnavailable }
            return Self.ownershipEmptyReplay()
        }
        let resolved = try? await client.resolveSession(draft.record)
        #expect(resolved?.coordinate.runtimeSessionID == "runtime")
        #expect(try client.attachedSession(draft.record)?.coordinate.runtimeSessionID == "runtime")
        #expect(try client.activeSessionMappings().map(\.runtimeID) == ["runtime"])
        #expect(workspace.calls.filter { $0.operation == .sessionActivate }.count == 1)
        #expect(!workspace.calls.contains { $0.operation == .sessionResume })
    }

    @Test(arguments: [1, 2])
    func oneAvailableEpochKeepsNewReceiptUsable(failingRead: Int) async throws {
        let workspace = try SessionWorkspaceStub()
        var reads = 0
        workspace.epochHandler = {
            reads += 1
            if reads == failingRead { throw WorkspaceClientError.transportUnavailable }
            return Self.ownershipEmptyReplay()
        }
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate: return Self.created(stored: "ordinary")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { _ in })
        let draft = try await client.createOrdinarySession(profileID: "alpha")
        #expect(try client.attachedSession(draft.record)?.coordinate.runtimeSessionID == "runtime")
        #expect(try client.activeSessionMappings().map(\.runtimeID) == ["runtime"])
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1)
    }

    @Test func explicitReattachmentRevokesOnlyExactRuntimeThenResumesDurableSession() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate: return Self.created(stored: "ordinary")
            case .sessionResume:
                #expect(payload["profile"] == .string("alpha"))
                #expect(payload["session_id"] == .string("ordinary"))
                var reply = Self.attached(stored: "ordinary")
                reply["session_id"] = .string("replacement-runtime")
                return reply
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { _ in })
        let draft = try await client.createOrdinarySession(profileID: "alpha")
        #expect(throws: WorkspaceClientError.ownerChanged) {
            try client.invalidateRuntimeBinding(draft.record, runtimeID: "unrelated-runtime")
        }
        #expect(try client.attachedSession(draft.record) != nil)
        try client.invalidateRuntimeBinding(draft.record, runtimeID: "runtime")
        #expect(try client.attachedSession(draft.record) == nil)
        workspace.replayEpoch = "replacement-process"
        let recovered = try await client.resolveSession(draft.record)
        #expect(recovered.record.id == draft.record.id)
        #expect(recovered.coordinate.storedSessionID == "ordinary")
        #expect(recovered.coordinate.runtimeSessionID == "replacement-runtime")
        #expect(try client.activeSessionMappings().map(\.runtimeID) == ["replacement-runtime"])
        #expect(workspace.calls.filter { $0.operation == .sessionResume }.count == 1)
        #expect(!workspace.calls.contains { $0.operation == .sessionActivate })
    }

    @Test func suspendedDiscoveryDoesNotResurrectRevokedReceipt() async throws {
        let workspace = try SessionWorkspaceStub()
        var active = try #require(Self.activeSession(stored: "ordinary", status: "idle").object)
        active["id"] = .string("runtime")
        workspace.activeSessions = [.object(active)]
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate: return Self.created(stored: "ordinary")
            case .sessionsList: return Self.ownershipPage([Self.session(id: "ordinary")])
            case .sessionActivate: return Self.attached(stored: "compressed-successor")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { _ in })
        let draft = try await client.createOrdinarySession(profileID: "alpha")
        var reads = 0
        var observedRevocation = false
        workspace.epochHandler = {
            reads += 1
            if reads == 2 {
                await #expect(throws: WorkspaceClientError.invalidResponse) {
                    try await client.resolveSession(draft.record)
                }
                observedRevocation = try client.activeSessionMappings().isEmpty
            }
            return Self.ownershipEmptyReplay()
        }
        let rows = try await client.list()
        #expect(observedRevocation)
        #expect(rows.map(\.id) == [draft.record.id], "The local draft survives, not its revoked attachment")
        #expect(try client.attachedSession(draft.record) == nil)
        #expect(try client.activeSessionMappings().isEmpty)
    }

    @Test func olderInventoryCannotRevokeNewerAcknowledgedReceipt() async throws {
        let workspace = try SessionWorkspaceStub()
        var client: DirectHermesSessionCatalogClient!
        var draft: DirectHermesResolvedSession?
        var active = try #require(Self.activeSession(stored: "obsolete-key", status: "idle").object)
        active["id"] = .string("runtime")
        workspace.activeSessions = nil
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate: return Self.created(stored: "ordinary")
            case .sessionActivate: return Self.attached(stored: "ordinary")
            case .sessionsList: return Self.ownershipPage([])
            case .nativeSessionActiveList:
                _ = try await client.resolveSession(try #require(draft).record)
                return ["sessions": .array([.object(active)])]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        client = Self.client(workspace, sink: { _ in })
        draft = try await client.createOrdinarySession(profileID: "alpha")
        let record = try #require(draft).record
        let rows = try await client.list()
        #expect(rows.map(\.id) == [record.id])
        #expect(try client.attachedSession(record)?.coordinate.runtimeSessionID == "runtime")
        #expect(try client.activeSessionMappings().map(\.sessionKey) == ["ordinary"])
    }

    @Test func contradictoryActivationEchoInvalidatesRatherThanLaundersReceipt() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate: return Self.created(stored: "ordinary")
            case .sessionActivate: return Self.attached(stored: "ordinary", profile: "beta")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { _ in })
        let draft = try await client.createOrdinarySession(profileID: "alpha")
        await #expect(throws: WorkspaceClientError.invalidResponse) { try await client.resolveSession(draft.record) }
        #expect(try client.activeSessionMappings().isEmpty)
        #expect(try client.attachedSession(draft.record) == nil)
        #expect(try client.pendingCreation(profileID: "alpha")?.phase == .complete)
        #expect(!workspace.calls.contains { $0.operation == .sessionResume || $0.operation == .sessionDetail })
    }

    @Test func processGlobalActiveRouteDoesNotRequireGuessedProfile() throws {
        #expect(try DirectHermesWorkspaceClient.route(.nativeSessionActiveList, payload: [:]) == .rpc("session.active_list", [:]))
    }

    static func ownershipProfiles(reversed: Bool = false) -> [String: BighelpJSONValue] {
        let names = reversed ? ["beta", "alpha"] : ["alpha", "beta"]
        return ["profiles": .array(names.map { .object(["name": .string($0), "display_name": .string($0), "canonical_session": .null]) })]
    }

    static func ownershipPage(_ rows: [BighelpJSONValue]) -> [String: BighelpJSONValue] {
        ["sessions": .array(rows), "total": .integer(rows.count), "offset": .integer(0), "limit": .integer(100)]
    }

    static func ownershipEmptyReplay(epoch: String = "fixture-process") -> [String: BighelpJSONValue] {
        ["events": .array([]), "count": .integer(0), "latest_seq": .integer(0), "truncated": .boolean(false), "epoch": .string(epoch), "open_requests": .array([])]
    }

    static func ownershipReplay(profile: String, stored: String, runtime: String = "runtime-live") -> [String: BighelpJSONValue] {
        ["events": .array([.object(["type": .string("session.info"), "session_id": .string(runtime), "seq": .integer(1),
                                    "payload": .object(["profile_name": .string(profile), "stored_session_id": .string(stored)])])]),
         "count": .integer(1), "latest_seq": .integer(1), "truncated": .boolean(false), "epoch": .string("fixture-process"),
         // These are data, never requests to answer or dispatch during discovery.
         "open_requests": .array([.object(["id": .string("do-not-answer")])])]
    }

    static func expectReadOnlyDiscovery(_ workspace: SessionWorkspaceStub) {
        #expect(workspace.calls.allSatisfy { [.profilesList, .sessionsList, .nativeSessionActiveList, .sessionEvents].contains($0.operation) })
    }

    @Test(arguments: ["idle", "starting", "waiting", "working", "streaming", "resuming"])
    func unopenedSavedSessionUsesReplayProvenLiveStatus(status: String) async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.activeSessions = nil
        workspace.handler = { operation, payload in
            if operation.rawValue == "session.active_list" {
                #expect(payload.isEmpty)
                return ["sessions": .array([Self.activeSession(stored: "saved-live", status: status)])]
            }
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionsList:
                var row = try #require(Self.session(id: "saved-live").object)
                row["pinned"] = .boolean(true)
                return ["sessions": .array([.object(row)]), "total": .integer(1),
                        "offset": .integer(0), "limit": .integer(100)]
            case .sessionEvents: return Self.ownershipReplay(profile: "alpha", stored: "saved-live")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        let record = try #require(try await client.list().first)
        #expect(record.isActive == (status != "idle"))
        #expect(record.isPinned)
        #expect(record.items.isEmpty)
        #expect(record.catalogPreview == "A real preview")
        #expect(record.remoteStoredID == "saved-live")
        #expect(workspace.calls.filter { $0.operation.rawValue == "session.active_list" }.count == 2)
        #expect(!workspace.calls.contains { $0.operation.rawValue == "session.status" })
        if status != "idle" {
            let attached = try #require(try client.attachedSession(record))
            #expect(attached.coordinate.runtimeSessionID == "runtime-live")
        }
    }

    /// Hermes stamps an open session "last active: now" when it's resumed, without any new message.
    /// Only real work moves a saved chat up the list; otherwise several chats opened at once all
    /// showed the same recent time (Hermes Desktop shows the saved one).
    @Test(arguments: ["idle", "working"])
    func anOpenedChatKeepsItsSavedTimeUntilItWorks(status: String) async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.activeSessions = nil
        workspace.handler = { operation, _ in
            if operation.rawValue == "session.active_list" {
                return ["sessions": .array([Self.activeSession(stored: "saved-live", status: status)])]
            }
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionsList:
                return ["sessions": .array([Self.session(id: "saved-live")]), "total": .integer(1),
                        "offset": .integer(0), "limit": .integer(100)]
            case .sessionEvents: return Self.ownershipReplay(profile: "alpha", stored: "saved-live")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let record = try #require(try await Self.client(workspace).list().first)
        #expect(record.updatedAt == Date(timeIntervalSince1970: status == "idle" ? 2 : 3))
    }

    @Test func liveSessionBeforeItsFirstSavedMessageAppearsWithoutHydratingChat() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.activeSessions = [Self.activeSession(stored: "remote-new", status: "streaming", count: 0)]
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionEvents: return Self.ownershipReplay(profile: "alpha", stored: "remote-new")
            case .sessionsList: return ["sessions": .array([]), "total": .integer(0),
                                       "offset": .integer(0), "limit": .integer(100)]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        let record = try #require(try await client.list().first)
        #expect(record.isActive)
        #expect(!record.hasAcceptedMessage)
        #expect(record.items.isEmpty)
        #expect(record.remoteStoredID == "remote-new")
        let attached = try #require(try client.attachedSession(record))
        #expect(attached.coordinate.runtimeSessionID == "runtime-live")
        #expect(!workspace.calls.contains { $0.operation == .sessionResume || $0.operation == .sessionHistory })
    }

    @Test func newChatReusesLoadedProfileWithoutAnotherDiscoveryRequest() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: Self.profiles()
            case .sessionsList: ["sessions": .array([]), "total": .integer(0),
                                 "offset": .integer(0), "limit": .integer(100)]
            case .sessionCreate: Self.created(stored: "ordinary")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { _ in })
        _ = try await client.list()
        let count = workspace.calls.filter { $0.operation == .profilesList }.count
        let created = try await client.createOrdinarySession(profileID: "alpha")
        #expect(workspace.calls.filter { $0.operation == .profilesList }.count == count)
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1)
        let beforeAttach = workspace.calls.count
        let resolved = try client.attachedSession(created.record)
        let attached = try #require(resolved)
        #expect(attached.coordinate == created.coordinate)
        #expect(workspace.calls.count == beforeAttach)
        workspace.owner = nil
        #expect(throws: WorkspaceClientError.self) { try client.attachedSession(created.record) }
    }

    @Test func pagedCatalogUsesProfileScopeAndNeverFabricatesPreviewMessagesOrRunningState() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            if operation == .profilesList { return Self.profiles() }
            #expect(operation == .sessionsList)
            #expect(payload["profile"] == .string("alpha"))
            #expect(payload["limit"] == .integer(100))
            let offset = try #require(payload["offset"]?.integer)
            let count = offset == 0 ? 100 : 1
            return ["sessions": .array((offset..<(offset + count)).map { Self.session(id: "s-\($0)") }),
                    "total": .integer(101), "offset": .integer(offset), "limit": .integer(100)]
        }
        let client = Self.client(workspace)
        let records = try await client.list()
        #expect(records.count == 101)
        #expect(records.allSatisfy { $0.items.isEmpty && !$0.isActive })
        #expect(records.first?.catalogPreview == "A real preview")
        #expect(records.first?.remoteStoredID == "s-0")
        let decoded = try DirectHermesSessionIdentity.decode(records[0].id, owner: workspace.owner!)
        #expect(decoded.profileID == "alpha")
        #expect(decoded.anchorID == "s-0")
        #expect(workspace.calls.filter { $0.operation == .sessionsList }.count == 2)
    }

    @Test func catalogRehydratesProjectAssociationFromAuthoritativeSessionCWD() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList:
                return Self.profiles()
            case .sessionsList:
                return ["sessions": .array([
                    Self.session(id: "assigned", cwd: "/workspace"),
                    Self.session(id: "same-cwd", cwd: "/workspace"),
                ]), "total": .integer(2), "offset": .integer(0), "limit": .integer(100)]
            case .projectsForCwd:
                #expect(payload == ["profile": .string("alpha"), "cwd": .string("/workspace")])
                return ["cwd": .string("/workspace"), "project": .object(Self.project(id: "loopdy", name: "bighelp"))]
            default:
                throw WorkspaceClientError.invalidRequest
            }
        }

        let records = try await Self.client(workspace).list()

        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.workspaceID == "loopdy" && $0.workspaceName == "bighelp" })
        #expect(workspace.calls.filter { $0.operation == .projectsForCwd }.count == 1)
    }

    @Test func catalogKeepsSessionUnassignedWhenHermesProjectReadbackIsNull() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList:
                return Self.profiles()
            case .sessionsList:
                return ["sessions": .array([Self.session(id: "unassigned", cwd: "/outside")]),
                        "total": .integer(1), "offset": .integer(0), "limit": .integer(100)]
            case .projectsForCwd:
                return ["cwd": .string("/outside"), "project": .null]
            default:
                throw WorkspaceClientError.invalidRequest
            }
        }

        let records = try await Self.client(workspace).list()

        #expect(records.count == 1)
        #expect(records[0].workspaceID == nil)
        #expect(records[0].workspaceName == nil)
    }

    @Test func staleSessionCWDDoesNotDiscardValidProjectAssignments() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList:
                return Self.profiles()
            case .sessionsList:
                return ["sessions": .array([
                    Self.session(id: "stale", cwd: "/deleted-worktree"),
                    Self.session(id: "assigned", cwd: "/workspace"),
                ]), "total": .integer(2), "offset": .integer(0), "limit": .integer(100)]
            case .projectsForCwd:
                let cwd = try #require(payload["cwd"]?.string)
                if cwd == "/deleted-worktree" {
                    return ["cwd": .string("/current-launch-dir"),
                            "project": .object(Self.project(id: "wrong-fallback", name: "Wrong fallback"))]
                }
                return ["cwd": .string(cwd), "project": .object(Self.project(id: "loopdy", name: "bighelp"))]
            default:
                throw WorkspaceClientError.invalidRequest
            }
        }

        let records = try await Self.client(workspace).list()

        #expect(records.count == 2)
        #expect(records.first(where: { $0.remoteStoredID == "stale" })?.workspaceID == nil)
        #expect(records.first(where: { $0.remoteStoredID == "assigned" })?.workspaceID == "loopdy")
    }

    @Test func exactUTF8IdentitiesAndColdAnchorsDoNotAlias() throws {
        let owner = try SessionWorkspaceStub().owner!
        let composed = try DirectHermesSessionIdentity.appID(owner: owner, profileID: "\u{00E9}", anchorID: "native:id")
        let decomposed = try DirectHermesSessionIdentity.appID(owner: owner, profileID: "e\u{0301}", anchorID: "native:id")
        #expect(composed != decomposed)
        #expect(try DirectHermesSessionIdentity.decode(composed, owner: owner).anchorID == "native:id")
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesSessionIdentity.decode(composed + "=", owner: owner)
        }
        let foreign = WorkspaceOwner(authority: try .fixture(id: "foreign"),
                                     authenticationGeneration: UUID(), connectionGeneration: UUID())
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesSessionIdentity.decode(composed, owner: foreign)
        }
    }

    @Test func canonicalRegistryIDResumesExactlyAndKnownRuntimeActivatesWithoutCreation() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles(canonical: "root", resolved: "tip")
            case .sessionResume:
                #expect(payload == ["profile": .string("alpha"), "session_id": .string("root"),
                                    "defer_history": .boolean(true), "omit_messages": .boolean(true),
                                    "source": .string("bighelp")])
                return Self.attached(stored: "tip")
            case .sessionActivate:
                #expect(payload["session_id"] == .string("runtime"))
                #expect(payload["profile"] == .string("alpha"))
                #expect(payload["omit_messages"] == .boolean(true))
                return Self.attached(stored: "tip")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        guard case .resolved(let first) = try await client.resolveCanonicalChat(profileID: "alpha") else {
            Issue.record("Expected the registered canonical session")
            return
        }
        #expect(first.coordinate.storedSessionID == "tip")
        #expect(first.coordinate.runtimeSessionID == "runtime")
        #expect(first.canonicalRegistryID == "root")
        #expect(try DirectHermesSessionIdentity.decode(first.record.id, owner: workspace.owner!).anchorID == "root")
        _ = try await client.resolveCanonicalChat(profileID: "alpha")
        #expect(workspace.calls.filter { $0.operation == .sessionResume }.count == 1)
        #expect(workspace.calls.filter { $0.operation == .sessionActivate }.count == 1)
        #expect(!workspace.calls.contains { $0.operation == .sessionCreate })
    }

    @Test func emptyRegistryIsNotCreationAndKnownMissingCanonicalNeverCreatesReplacement() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: Self.profiles()
            case .nativeSessionList: ["sessions": .array([])]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        #expect(try await client.resolveCanonicalChat(profileID: "alpha") == .notCreated(profileID: "alpha"))
        await #expect(throws: DirectHermesSessionError.canonicalMissing(profileID: "alpha", knownID: "known")) {
            try await client.resolveCanonicalChat(profileID: "alpha", previouslyKnownID: "known")
        }
        #expect(!workspace.calls.contains { $0.operation == .sessionCreate })
    }

    @Test func lazyActivationWithoutProfileEchoRequiresExactKnownNativePair() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles(canonical: "root")
            case .sessionResume: return Self.attached(stored: "root")
            case .sessionActivate:
                return ["session_id": .string("runtime"), "session_key": .string("root"),
                        "running": .boolean(false), "info": .object(["lazy": .boolean(true), "model": .string("launch-fallback")])]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        _ = try await client.resolveCanonicalChat(profileID: "alpha")
        guard case .resolved(let resolved) = try await client.resolveCanonicalChat(profileID: "alpha") else {
            Issue.record("Expected existing canonical identity")
            return
        }
        #expect(resolved.coordinate.runtimeSessionID == "runtime")
        #expect(resolved.record.sessionRuntime?.model == "model")
        #expect(!workspace.calls.contains { $0.operation == .sessionDetail || $0.operation == .sessionCreate })
    }

    @Test func coldProfileScopedResumeReceiptDoesNotLaunderRESTIntoRuntimeOwnership() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles(canonical: "root")
            case .sessionResume:
                return ["session_id": .string("runtime"), "session_key": .string("tip"),
                        "info": .object(["lazy": .boolean(true)])]
            case .sessionDetail:
                #expect(payload == ["profile": .string("alpha"), "session_id": .string("tip")])
                return ["id": .string("tip"), "profile": .string("foreign")]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let result = try await Self.client(workspace).resolveCanonicalChat(profileID: "alpha")
        guard case .resolved(let resolved) = result else { Issue.record("Expected scoped resume receipt"); return }
        #expect(resolved.coordinate.profileID == "alpha")
        #expect(resolved.coordinate.runtimeSessionID == "runtime")
        #expect(!workspace.calls.contains { $0.operation == .sessionDetail })
        #expect(!workspace.calls.contains { $0.operation == .sessionCreate })
    }

    @Test func ordinaryDraftUsesExplicitCWDOnlyAndDoesNotBecomeCanonical() async throws {
        let workspace = try SessionWorkspaceStub()
        var state: DirectHermesSessionCreationState?
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate:
                #expect(payload == ["profile": .string("alpha"), "source": .string("bighelp")])
                return Self.created(stored: "ordinary")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { state = $0 })
        let created = try await client.createOrdinarySession(profileID: "alpha")
        #expect(created.durability == .draft)
        #expect(created.canonicalRegistryID == nil)
        #expect(!created.record.hasAcceptedMessage)
        #expect(state?.requestedCWD == nil)
        #expect(!workspace.calls.contains { $0.operation == .sessionTitle || $0.operation == .promptSubmit })
    }

    @Test func firstBirthPersistsBeforeCreateAndTitleThenRequiresRegistryReadback() async throws {
        let workspace = try SessionWorkspaceStub()
        var states: [DirectHermesSessionCreationState] = []
        var titled = false
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles()
            case .nativeSessionList:
                #expect(payload["title"] == .string("Bot Chat"))
                return ["sessions": .array(titled ? [Self.registry("created")] : [])]
            case .sessionCreate:
                #expect(states.last?.phase == .createRequested)
                #expect(payload == ["profile": .string("alpha"), "title": .string("Bot Chat"),
                                    "hidden": .boolean(true), "follow_profile_config": .boolean(true),
                                    "cwd": .string("/approved/work"), "cwd_explicit": .boolean(true),
                                    "source": .string("bighelp")])
                return Self.created(stored: "created", cwd: "/approved/work")
            case .sessionTitle:
                #expect(states.last?.phase == .titleRequested)
                #expect(payload == ["session_id": .string("runtime"), "title": .string("Bot Chat")])
                titled = true
                return ["pending": .boolean(false), "title": .string("Bot Chat")]
            case .sessionResume: return Self.attached(stored: "created")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, folder: { _ in "/approved/work" }, sink: { states.append($0) })
        let resolved = try await client.createFirstCanonicalChat(profileID: "alpha")
        #expect(resolved.coordinate.storedSessionID == "created")
        #expect(resolved.canonicalRegistryID == "created")
        #expect(resolved.durability == .persisted)
        #expect(states.map(\.phase) == [.createRequested, .created, .titleRequested, .awaitingRegistry, .canonicalResolved])
        #expect(!workspace.calls.contains { $0.operation == .promptSubmit })
    }

    @Test func missingDurableSinkPreventsCreateAndFailedSinkDoesNotDispatch() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: Self.profiles()
            case .nativeSessionList: ["sessions": .array([])]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        await #expect(throws: DirectHermesSessionError.creationPersistenceRequired) {
            try await Self.client(workspace).createFirstCanonicalChat(profileID: "alpha")
        }
        await #expect(throws: SessionFixtureError.disk) {
            try await Self.client(workspace, sink: { _ in throw SessionFixtureError.disk })
                .createFirstCanonicalChat(profileID: "alpha")
        }
        #expect(!workspace.calls.contains { $0.operation == .sessionCreate || $0.operation == .sessionTitle })
    }

    @Test func unknownCreateReceiptIsRetainedAcrossClientRestoreAndNeverReplayed() async throws {
        let workspace = try SessionWorkspaceStub()
        var retained: DirectHermesSessionCreationState?
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: Self.profiles()
            case .nativeSessionList: ["sessions": .array([])]
            case .sessionCreate: throw WorkspaceClientError.outcomeUnknown
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let first = Self.client(workspace, sink: { retained = $0 })
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await first.createFirstCanonicalChat(profileID: "alpha")
        }
        let saved = try #require(retained)
        let restored = try JSONDecoder().decode(DirectHermesSessionCreationState.self, from: JSONEncoder().encode(saved))
        let authority = try #require(workspace.owner?.authority)
        workspace.owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let second = Self.client(workspace, sink: { _ in })
        try second.restoreCreationState(restored)
        await #expect(throws: DirectHermesSessionError.creationUnconfirmed(profileID: "alpha")) {
            try await second.createFirstCanonicalChat(profileID: "alpha")
        }
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1)
        #expect(!workspace.calls.contains { $0.operation == .sessionTitle })
    }

    @Test func unconfirmedOrdinaryNewChatDoesNotBlockTheNextOneEvenAfterRestore() async throws {
        let workspace = try SessionWorkspaceStub()
        var retained: DirectHermesSessionCreationState?
        var failCreate = true
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .nativeSessionList: return ["sessions": .array([])]
            case .sessionCreate:
                if failCreate { throw WorkspaceClientError.outcomeUnknown }
                return Self.created(stored: "second")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let first = Self.client(workspace, sink: { retained = $0 })
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await first.createOrdinarySession(profileID: "alpha")
        }
        let saved = try #require(retained)
        #expect(saved.purpose == .ordinary && saved.phase == .createRequested)

        // The saved unfinished attempt is restored on the next launch, and a new
        // chat for the same agent still starts.
        let restored = try JSONDecoder().decode(DirectHermesSessionCreationState.self, from: JSONEncoder().encode(saved))
        let authority = try #require(workspace.owner?.authority)
        workspace.owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let second = Self.client(workspace, sink: { retained = $0 })
        try second.restoreCreationState(restored)
        failCreate = false
        let session = try await second.createOrdinarySession(profileID: "alpha")
        #expect(session.record.agentIDs == ["alpha"])
        #expect(retained?.phase == .complete)
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 2)
    }

    @Test func titleConflictAdoptsOnlyExactRegistryWinnerWithoutIntroOrSecondCreate() async throws {
        let workspace = try SessionWorkspaceStub()
        var conflict = false
        var state: DirectHermesSessionCreationState?
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .nativeSessionList: return ["sessions": .array(conflict ? [Self.registry("winner")] : [])]
            case .sessionCreate: return Self.created(stored: "losing-draft")
            case .sessionTitle:
                conflict = true
                throw WorkspaceClientError.rejected(code: "4022")
            case .sessionResume: return Self.attached(stored: "winner")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { state = $0 })
        let resolved = try await client.createFirstCanonicalChat(profileID: "alpha")
        #expect(resolved.canonicalRegistryID == "winner")
        #expect(resolved.coordinate.storedSessionID == "winner")
        #expect(state?.storedSessionID == "losing-draft")
        #expect(state?.canonicalRegistryID == "winner")
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1)
        #expect(!workspace.calls.contains { $0.operation == .promptSubmit || $0.operation == .sessionDelete })
    }

    @Test func lateOwnerChangeRejectsCatalogWithoutPublishingForeignBinding() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, _ in
            if operation == .profilesList { return Self.profiles() }
            workspace.owner = nil
            return ["sessions": .array([Self.session(id: "stored")]), "total": .integer(1),
                    "limit": .integer(100), "offset": .integer(0)]
        }
        let client = Self.client(workspace)
        await #expect(throws: WorkspaceClientError.ownerChanged) { try await client.list() }
    }

    @Test func resolvingExistingSessionPreservesLocalDraftAndNeverSendsAppID() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionsList:
                return ["sessions": .array([Self.session(id: "stored")]), "total": .integer(1),
                        "limit": .integer(100), "offset": .integer(0)]
            case .sessionResume:
                #expect(payload["session_id"] == .string("stored"))
                return Self.attached(stored: "stored")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        var record = try #require(try await client.list().first)
        record.draft = "Keep this unsent text"
        record.remoteSource = "direct-hermes"
        let resolved = try await client.resolveSession(record)
        #expect(resolved.record.draft == "Keep this unsent text")
        #expect(resolved.record.remoteSource == "tui")
        #expect(resolved.coordinate.sessionID == record.id)
    }

    @Test func flagsAndDeleteUseNativeStoredIDAndExactAcknowledgements() async throws {
        let workspace = try SessionWorkspaceStub()
        var pinned = false
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionsList:
                return ["sessions": .array([Self.session(id: "stored")]), "total": .integer(1),
                        "limit": .integer(100), "offset": .integer(0)]
            case .sessionUpdate:
                #expect(payload["session_id"] == .string("stored"))
                #expect(payload["profile"] == .string("alpha"))
                pinned = true
                return ["ok": .boolean(true), "title": .string("Session"), "pinned": .boolean(true)]
            case .sessionDetail:
                var detail = try #require(Self.session(id: "stored").object)
                detail["pinned"] = .integer(pinned ? 1 : 0)
                return detail
            case .sessionDelete:
                #expect(payload == ["session_id": .string("stored"), "profile": .string("alpha")])
                return ["ok": .boolean(true), "already_absent": .boolean(true)]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        let record = try #require(try await client.list().first)
        try await client.setPinned(record, pinned: true)
        await #expect(throws: DirectHermesSessionError.nativeRowDeletionOnly) {
            try await client.delete(record)
        }
        let deleted = try await client.deleteNativeRow(record)
        #expect(deleted.rowID == "stored")
        #expect(deleted.mayRetainOtherHistory)
        #expect(throws: WorkspaceClientError.invalidRequest) { try client.coordinate(for: record.id) }
    }

    /// Hermes keeps a chat you had open running for a while after you archive
    /// it. Refreshing used to bring the chat back until Hermes closed it.
    @Test(arguments: ["idle", "working"])
    func anArchivedChatStaysGoneWhileHermesStillHasItOpen(status: String) async throws {
        let workspace = try SessionWorkspaceStub()
        var archived = false
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionsList: return Self.ownershipPage(archived ? [] : [Self.session(id: "stored")])
            case .sessionResume: return Self.attached(stored: "stored")
            case .sessionUpdate:
                archived = true
                return ["ok": .boolean(true), "archived": .boolean(true)]
            case .sessionDetail:
                var detail = try #require(Self.session(id: "stored").object)
                detail["archived"] = .integer(archived ? 1 : 0)
                return detail
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { _ in })
        let record = try #require(try await client.list().first)
        #expect(try await client.resolveSession(record).coordinate.runtimeSessionID == "runtime")
        var open = try #require(Self.activeSession(stored: "stored", status: status).object)
        open["id"] = .string("runtime")
        workspace.activeSessions = [.object(open)]

        try await client.archive(record)
        #expect(try await client.list().isEmpty)
        #expect(try await client.list().isEmpty, "Still gone on the next refresh")

        // Unarchived somewhere else: Hermes lists it again, so it's back.
        archived = false
        #expect(try await client.list().map(\.id) == [record.id])
    }

    @Test func unknownTitleResultRetainsReceiptAndNeverRepeatsTheMutation() async throws {
        let workspace = try SessionWorkspaceStub()
        var retained: DirectHermesSessionCreationState?
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return Self.profiles()
            case .nativeSessionList: return ["sessions": .array([])]
            case .sessionCreate: return Self.created(stored: "created")
            case .sessionTitle: throw WorkspaceClientError.outcomeUnknown
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace, sink: { retained = $0 })
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client.createFirstCanonicalChat(profileID: "alpha")
        }
        #expect(retained?.phase == .titleRequested)
        #expect(retained?.storedSessionID == "created")
        await #expect(throws: DirectHermesSessionError.creationUnconfirmed(profileID: "alpha")) {
            try await client.createFirstCanonicalChat(profileID: "alpha")
        }
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1)
        #expect(workspace.calls.filter { $0.operation == .sessionTitle }.count == 1)
    }

    @Test func metadataTargetsStaySeparateFromNonCompressionTranscriptContinuation() async throws {
        @MainActor final class FixtureState {
            var latestCatalogID = "catalog-tip-1"
            var pinned = false
        }
        let workspace = try SessionWorkspaceStub()
        let state = FixtureState()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionsList:
                var row = try #require(Self.session(id: state.latestCatalogID).object)
                row["_lineage_root_id"] = .string("root")
                row["_lineage_ids"] = .array(state.latestCatalogID == "catalog-tip-1"
                    ? [.string("root"), .string("catalog-tip-1")]
                    : [.string("root"), .string("catalog-tip-1"), .string("catalog-tip-2")])
                return ["sessions": .array([.object(row)]), "total": .integer(1),
                        "limit": .integer(100), "offset": .integer(0)]
            case .sessionHistory:
                return ["session_id": .string("unrelated-continuation"), "profile": .string("alpha"),
                        "messages": .array([]),
                        "pagination": .object(["offset": payload["offset"]!, "limit": payload["limit"]!,
                                               "order": payload["order"]!, "returned": .integer(0)])]
            case .sessionUpdate:
                if payload["title"] != nil {
                    #expect(payload["session_id"] == .string("catalog-tip-2"))
                    return ["ok": .boolean(true), "title": .string("Renamed")]
                }
                #expect(payload["session_id"] == .string("root"))
                state.pinned = true
                return ["ok": .boolean(true), "title": .string("Root"), "pinned": .boolean(true)]
            case .sessionDetail:
                return ["id": payload["session_id"]!, "profile": .string("alpha"),
                        "title": .string("Renamed"), "pinned": .boolean(state.pinned)]
            case .sessionDelete:
                #expect(payload["session_id"] == .string("catalog-tip-2"))
                return ["ok": .boolean(true)]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        let first = try #require(try await client.list().first)
        state.latestCatalogID = "catalog-tip-2"
        let second = try #require(try await client.list().first)
        #expect(first.id == second.id)
        #expect(first.remoteStoredID == "catalog-tip-1")
        #expect(second.remoteStoredID == "catalog-tip-2")
        let hydrated = try await client.hydrate(second)
        #expect(hydrated.remoteStoredID == "unrelated-continuation")
        try await client.rename(hydrated, title: "Renamed")
        try await client.setPinned(hydrated, pinned: true)
        await #expect(throws: DirectHermesSessionError.nativeRowDeletionOnly) { try await client.delete(hydrated) }
        let deleted = try await client.deleteNativeRow(hydrated)
        #expect(deleted.rowID == "catalog-tip-2")
        #expect(deleted.mayRetainOtherHistory)
    }

    @Test func canonicalPinUsesRegistryIdentityAndRenameIsNotAgentDisplayRename() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles(canonical: "canonical-root", resolved: "tip")
            case .sessionResume: return Self.attached(stored: "tip")
            case .sessionUpdate:
                #expect(payload["session_id"] == .string("canonical-root"))
                return ["ok": .boolean(true), "title": .string("Bot Chat"), "pinned": .boolean(true)]
            case .sessionDetail:
                return ["id": .string("canonical-root"), "profile": .string("alpha"), "pinned": .boolean(true)]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = Self.client(workspace)
        guard case .resolved(let resolved) = try await client.resolveCanonicalChat(profileID: "alpha") else {
            Issue.record("Expected canonical")
            return
        }
        try await client.setPinned(resolved.record, pinned: true)
        await #expect(throws: WorkspaceClientError.unavailable(.policyRestricted)) {
            try await client.rename(resolved.record, title: "Not an agent display rename")
        }
        #expect(!workspace.calls.contains { $0.operation == .sessionTitle })
    }

    /// Without a source Hermes labels the chat "tui" and tells the agent it's in a terminal: no files,
    /// no cards, reminders can't reach anyone. Reopened chats must keep the same label.
    @Test func chatsTellHermesTheyComeFromBighelp() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles(canonical: "root", resolved: "tip")
            case .sessionCreate:
                #expect(payload["source"] == .string("bighelp"))
                return Self.created(stored: "fresh", cwd: "/workspace")
            case .sessionResume:
                #expect(payload["source"] == .string("bighelp"))
                return Self.attached(stored: "tip")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let sessions = Self.client(workspace, folder: { _ in nil }, sink: { _ in })

        _ = try await sessions.createOrdinarySession(profileID: "alpha")
        #expect(workspace.calls.contains { $0.operation == .sessionCreate })
        #expect(DirectHermesReleaseContract.resumeParameters(profile: "alpha", storedID: "tip")["source"]
                == .string("bighelp"))
    }

    /// A project's folder is a deliberate pick. Sent without `cwd_explicit`, Hermes put an agent's own
    /// configured folder first, the chat came back outside the project and every new chat was refused.
    @Test func projectFolderIsSentAsADeliberatePick() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate:
                #expect(payload["cwd"] == .string("/workspace/notes"))
                #expect(payload["cwd_explicit"] == .boolean(true))
                return Self.created(stored: "in-project", cwd: "/workspace/notes")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let sessions = Self.client(workspace, folder: { _ in "/workspace/notes" }, sink: { _ in })

        let created = try await sessions.createOrdinarySession(profileID: "alpha")

        #expect(created.coordinate.storedSessionID == "in-project")
        #expect(created.cwd == "/workspace/notes")
    }

    /// Released Hermes (0.21.5 and older) rejects the flag as an unknown field (4000); the plain request works there.
    @Test func olderHermesWithoutTheFolderFlagStillStartsTheChat() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate:
                // Hermes 0.21.5 and older refuse fields they don't know with JSON-RPC error 4000.
                if payload["cwd_explicit"] != nil { throw DirectHermesError.rpcRejected(code: 4000) }
                #expect(payload["cwd"] == .string("/workspace/notes"))
                return Self.created(stored: "older-host", cwd: "/workspace/notes")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let sessions = Self.client(workspace, folder: { _ in "/workspace/notes" }, sink: { _ in })

        let created = try await sessions.createOrdinarySession(profileID: "alpha")

        #expect(created.coordinate.storedSessionID == "older-host")
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 2)
    }

    /// A project whose folder is gone from the computer must not lock its agent out of new chats.
    /// Hermes starts such a chat somewhere else; start it again without the project instead.
    @Test func missingProjectFolderStartsTheChatWithoutTheProject() async throws {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles()
            case .sessionCreate:
                if workspace.calls.filter({ $0.operation == .sessionCreate }).count == 1 {
                    #expect(payload["cwd"] == .string("/workspace/gone"))
                    return Self.created(stored: "fell-back", cwd: "/host/launch")
                }
                #expect(payload["cwd"] == nil, "The retry lets the agent's own default folder apply")
                return Self.created(stored: "without-project")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let sessions = Self.client(workspace, folder: { _ in "/workspace/gone" }, sink: { _ in })

        let created = try await sessions.createOrdinarySession(profileID: "alpha")

        #expect(created.coordinate.storedSessionID == "without-project")
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 2)
    }

    /// These used to fall through to "New chat could not be opened. Try again." with no reason.
    @Test func sessionErrorsSayWhatWentWrong() {
        #expect(DirectHermesSessionError.workspaceNotConfirmed.localizedDescription.contains("project"))
        #expect(DirectHermesSessionError.creationUnconfirmed(profileID: "alpha").localizedDescription
            .contains("didn't finish"))
    }

    static func client(_ workspace: SessionWorkspaceStub,
                       folder: DirectHermesSessionCatalogClient.SelectedFolderPath? = nil,
                       sink: DirectHermesSessionCatalogClient.CreationStateChange? = nil) -> DirectHermesSessionCatalogClient {
        DirectHermesSessionCatalogClient(workspace: workspace, owner: workspace.owner!,
                                         currentOwner: { workspace.owner }, selectedFolderPath: folder,
                                         onCreationStateChange: sink, now: { Date(timeIntervalSince1970: 100) })
    }

    static func profiles(canonical: String? = nil, resolved: String? = nil) -> [String: BighelpJSONValue] {
        ["profiles": .array([.object([
            "name": .string("alpha"), "display_name": .string("Alpha"),
            "canonical_session": canonical.map { .object([
                "id": .string($0), "resolved_id": .string(resolved ?? $0), "title": .string("Bot Chat"),
            ]) } ?? .null,
        ])])]
    }

    static func session(id: String, profile: String = "alpha", cwd: String? = nil) -> BighelpJSONValue {
        var value: [String: BighelpJSONValue] = ["id": .string(id), "profile": .string(profile), "source": .string("tui"),
                 "_lineage_root_id": .string(id), "_lineage_ids": .array([.string(id)]),
                 "title": .string("Session"), "started_at": .number(1), "last_active": .number(2),
                 "message_count": .integer(2), "is_active": .boolean(true), "pinned": .boolean(false),
                 "archived": .boolean(false), "preview": .string("A real preview")]
        if let cwd { value["cwd"] = .string(cwd) }
        return .object(value)
    }

    static func activeSession(stored: String, status: String, count: Int = 2) -> BighelpJSONValue {
        .object([
            "id": .string("runtime-live"), "session_key": .string(stored),
            "title": .string("Remote work"), "preview": .string("Live preview"),
            "started_at": .number(1), "last_active": .number(3), "message_count": .integer(count),
            "model": .string("model"), "status": .string(status), "current": .boolean(false),
        ])
    }

    static func project(id: String, name: String) -> [String: BighelpJSONValue] {
        ["id": .string(id), "name": .string(name), "description": .string("Project"),
         "archived": .boolean(false), "folders": .array([
             .object(["path": .string("/workspace"), "label": .string("Workspace"), "is_primary": .boolean(true)])
         ])]
    }
    static func registry(_ id: String) -> BighelpJSONValue {
        .object(["id": .string(id), "resolved_id": .string(id), "title": .string("Bot Chat")])
    }
    static func attached(stored: String, profile: String = "alpha") -> [String: BighelpJSONValue] {
        ["session_id": .string("runtime"), "session_key": .string(stored), "resumed": .string(stored),
         "running": .boolean(false), "info": .object(["profile_name": .string(profile), "model": .string("model")])]
    }
    static func created(stored: String, cwd: String = "/host/default") -> [String: BighelpJSONValue] {
        ["session_id": .string("runtime"), "stored_session_id": .string(stored),
         "message_count": .integer(0), "messages": .array([]),
         "info": .object(["profile_name": .string("alpha"), "model": .string("model"),
                          "cwd": .string(cwd), "lazy": .boolean(true)])]
    }
}

enum SessionFixtureError: Error { case disk }

@MainActor
final class SessionWorkspaceStub: WorkspaceOperationPerforming {
    struct Call {
        let operation: WorkspaceOperation
        let payload: [String: BighelpJSONValue]
    }
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner) }
    var calls: [Call] = []
    // Ordinary fixtures have no remote live sessions. Nil delegates the
    // documented active-list operation to a scenario-specific handler.
    var activeSessions: [BighelpJSONValue]? = []
    var replayEpoch = "fixture-process"
    var epochHandler: (@MainActor () async throws -> [String: BighelpJSONValue])?
    var handler: @MainActor (WorkspaceOperation, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] = { _, _ in
        throw WorkspaceClientError.invalidRequest
    }
    init() throws {
        owner = WorkspaceOwner(authority: try .fixture(id: "native-session-test"),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
    }
    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard owner == self.owner else { throw WorkspaceClientError.ownerChanged }
        // The real client refuses fields its routes don't list before anything
        // reaches Hermes; a stub that skipped this once hid a new-chat failure.
        _ = try DirectHermesWorkspaceClient.route(operation, payload: payload)
        calls.append(.init(operation: operation, payload: payload))
        if operation == .sessionEvents, payload["session_id"] == .string("") {
            if let epochHandler { return try await epochHandler() }
            return DirectHermesSessionCatalogClientTests.ownershipEmptyReplay(epoch: replayEpoch)
        }
        if operation.rawValue == "session.active_list", let activeSessions {
            return ["sessions": .array(activeSessions)]
        }
        do {
            return try await handler(operation, payload)
        } catch {
            // Handlers throw what Hermes raises; callers see the client's translation.
            throw DirectHermesWorkspaceClient.workspaceError(error, for: operation)
        }
    }
}
