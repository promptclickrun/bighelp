import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesProjectClientTests {
    @Test func catalogProjectsNativeRegistryWithoutChangingIt() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        let result = try await client(transport).load(agentID: "research")
        #expect(result.activeWorkspaceID == "p_notes")
        #expect(result.workspaces.first?.folderCount == 1)
        #expect(transport.calls.map(\.operation) == [.projectsList])
        #expect(transport.calls.first?.payload == ["profile": .string("research")])
    }

    @Test func sessionUsesNativeDetailAndAssociationNotVisibleIDOrGlobalProject() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        transport.responses[.sessionDetail] = [detail()]
        transport.responses[.projectsForCwd] = [association(project: nil)]
        let adapter = client(transport, runtimeID: nil)
        let store = HermesWorkspaceStore(client: adapter)
        await store.load(agentID: "research", sessionID: "visible-chat")
        #expect(store.catalog?.activeWorkspaceID == "p_notes")
        #expect(store.workspaceID(forSessionID: "visible-chat") == nil)
        #expect(HermesWorkspaceSelectionPresentation.selectedName(store: store, sessionID: "visible-chat") == nil)
        #expect(transport.calls[1].payload == ["profile": .string("research"), "session_id": .string("native-row")])
        #expect(transport.calls[2].payload == ["profile": .string("research"), "cwd": .string("/workspace/notes")])
    }

    @Test func liveDraftUsesActivateAndCWDAssociationWithoutRESTDetailRow() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        transport.responses[.sessionActivate] = [activated()]
        transport.responses[.projectsForCwd] = [association(project: project())]

        let result = try await client(transport, storedID: nil).load(agentID: "research", sessionID: "visible-chat")

        #expect(result.sessionWorkspaceID == "p_notes")
        #expect(transport.calls.map(\.operation) == [.projectsList, .sessionActivate, .projectsForCwd])
        #expect(transport.calls[1].payload == [
            "profile": .string("research"), "session_id": .string("runtime-1"),
            "omit_messages": .boolean(true)
        ])
        #expect(!transport.calls.contains { $0.operation == .sessionDetail })
    }

    @Test func liveDraftRejectsActivateIdentityMismatchBeforeProjectAssociation() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        transport.responses[.sessionActivate] = [activated(profile: "writing")]

        await #expect(throws: WorkspaceClientError.invalidResponse) {
            try await client(transport, storedID: nil).load(agentID: "research", sessionID: "visible-chat")
        }
        #expect(!transport.calls.contains { $0.operation == .projectsForCwd })
        #expect(!transport.calls.contains { $0.operation == .sessionDetail })
    }

    @Test func persistedSessionWithoutLiveRuntimeRetainsRESTDetailAssociation() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        transport.responses[.sessionDetail] = [detail()]
        transport.responses[.projectsForCwd] = [association(project: project())]

        let result = try await client(transport, runtimeID: nil).load(agentID: "research", sessionID: "visible-chat")

        #expect(result.sessionWorkspaceID == "p_notes")
        #expect(transport.calls.map(\.operation) == [.projectsList, .sessionDetail, .projectsForCwd])
        #expect(!transport.calls.contains { $0.operation == .sessionActivate })
    }

    @Test func unresolvedSessionCannotPretendToHaveNativeWorkspaceState() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        let adapter = DirectHermesProjectClient(workspace: transport, owner: transport.owner!,
            currentOwner: { transport.owner }, resolveSession: { _ in nil })
        await #expect(throws: WorkspaceClientError.unavailable(.identityContextUnavailable)) {
            try await adapter.load(agentID: "research", sessionID: "visible-chat")
        }
        #expect(transport.calls.map(\.operation) == [.projectsList])
    }

    @Test func wrongProfileDetailIsRejectedBeforeAssociation() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        var wrong = detail()
        wrong["profile"] = .string("writing")
        transport.responses[.sessionDetail] = [wrong]
        await #expect(throws: WorkspaceClientError.invalidResponse) {
            try await client(transport, runtimeID: nil).load(agentID: "research", sessionID: "visible-chat")
        }
        #expect(!transport.calls.contains { $0.operation == .projectsForCwd })
    }

    @Test func movingSessionUsesExactStoredKeyAndNeverChangesGlobalDefault() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsGet] = [["project": .object(project())]]
        transport.responses[.sessionWorkspaceMove] = [["cwd": .string("/workspace/notes"), "branch": .string(""), "git_repo_root": .null]]
        transport.responses[.projectsList] = [catalog()]
        transport.responses[.sessionDetail] = [detail()]
        transport.responses[.projectsForCwd] = [association(project: project())]
        let result = try await client(transport).select(id: "p_notes", agentID: "research", sessionID: "visible-chat")
        #expect(result.sessionWorkspaceID == "p_notes")
        let move = try #require(transport.calls.first { $0.operation == .sessionWorkspaceMove })
        #expect(move.payload == ["profile": .string("research"), "session_key": .string("native-row"), "cwd": .string("/workspace/notes")])
        #expect(!transport.calls.contains { $0.operation == .projectsSetActive })
    }

    @Test func movingSessionUsesOfficialMoveAndProjectForCwdReadbackWhenRestDetailOmitsCWD() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsGet] = [["project": .object(project())]]
        transport.responses[.sessionWorkspaceMove] = [["cwd": .string("/workspace/notes"), "branch": .string(""), "git_repo_root": .null]]
        transport.responses[.projectsForCwd] = [association(project: project())]
        transport.responses[.projectsList] = [catalog()]

        let result = try await client(transport).select(id: "p_notes", agentID: "research", sessionID: "visible-chat")

        #expect(result.sessionWorkspaceID == "p_notes")
        #expect(transport.calls.map(\.operation) == [
            .projectsGet, .sessionWorkspaceMove, .projectsForCwd, .projectsList
        ])
        #expect(transport.calls[2].payload == [
            "profile": .string("research"), "cwd": .string("/workspace/notes")
        ])
    }

    @Test func movingSessionRejectsMismatchedOfficialProjectForCwdReadback() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsGet] = [["project": .object(project())]]
        transport.responses[.sessionWorkspaceMove] = [["cwd": .string("/workspace/notes"), "branch": .string(""), "git_repo_root": .null]]
        transport.responses[.projectsForCwd] = [association(project: project(id: "p_other"))]

        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client(transport).select(id: "p_notes", agentID: "research", sessionID: "visible-chat")
        }
        #expect(transport.calls.map(\.operation) == [
            .projectsGet, .sessionWorkspaceMove, .projectsForCwd
        ])
    }

    @Test func wrongMoveReceiptIsUnconfirmedWithoutFabricatedSelection() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsGet] = [["project": .object(project())]]
        transport.responses[.sessionWorkspaceMove] = [["cwd": .string("/other")]]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client(transport).select(id: "p_notes", agentID: "research", sessionID: "visible-chat")
        }
    }

    @Test func globalSelectionRequiresMatchingReadback() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsGet] = [["project": .object(project())]]
        transport.responses[.projectsSetActive] = [["active_id": .string("p_notes")]]
        transport.responses[.projectsList] = [catalog(active: nil)]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client(transport).select(id: "p_notes", agentID: "research", sessionID: nil)
        }
    }

    @Test func createRegistersExactPathAndVerifiesActiveProject() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsCreate] = [["project": .object(project())]]
        transport.responses[.projectsList] = [catalog()]
        let result = try await client(transport).create(name: "Notes", folderPath: "/workspace/notes", agentID: "research")
        #expect(result.activeWorkspaceID == "p_notes")
        #expect(transport.calls.first?.payload == [
            "profile": .string("research"), "name": .string("Notes"), "folders": .array([.string("/workspace/notes")]),
            "primary_path": .string("/workspace/notes"), "use": .boolean(true)
        ])
    }

    @Test func describeSetsOnlyTheDescriptionThroughHermesUpdate() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsUpdate] = [["project": .object(project())]]
        transport.responses[.projectsList] = [catalog()]
        _ = try await client(transport).describe(id: "p_notes", description: "  Plants and watering ", agentID: "research")
        #expect(transport.calls.first?.operation == .projectsUpdate)
        #expect(transport.calls.first?.payload == [
            "profile": .string("research"), "id": .string("p_notes"), "description": .string("Plants and watering")
        ])
    }

    @Test func archiveRemovesOnlyRegistrationFromActiveCatalog() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsArchive] = [catalog(active: nil, archived: true)]
        let result = try await client(transport).archive(id: "p_notes", agentID: "research")
        #expect(result.workspaces.isEmpty)
        #expect(transport.calls.map(\.operation) == [.projectsArchive])
        #expect(transport.calls.first?.payload == ["profile": .string("research"), "id": .string("p_notes"), "restore": .boolean(false)])
    }

    @Test func selectedFolderIsReadForExplicitNewSessionCWD() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        transport.responses[.projectsGet] = [["project": .object(project())]]
        #expect(try await client(transport).selectedFolderPath(agentID: "research") == "/workspace/notes")
        #expect(transport.calls.map(\.operation) == [.projectsList, .projectsGet])
    }

    @Test(arguments: [true, false])
    func staleProjectSelectionDoesNotBlockNativeAllocation(archived: Bool) async throws {
        let workspace = try SessionWorkspaceStub()
        let staleProject = project(archived: true)
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return DirectHermesSessionCatalogClientTests.profiles()
            case .projectsList:
                #expect(payload["profile"] == .string("alpha"))
                return ["projects": .array(archived ? [.object(staleProject)] : []),
                        "active_id": .string("p_notes")]
            case .sessionCreate:
                #expect(payload["profile"] == .string("alpha"))
                #expect(payload["cwd"] == nil, "A stale project must not override the host's creation defaults")
                return DirectHermesSessionCatalogClientTests.created(stored: "new-after-archive")
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let projects = DirectHermesProjectClient(workspace: workspace, owner: workspace.owner!,
            currentOwner: { workspace.owner }, resolveSession: { _ in nil })
        let sessions = DirectHermesSessionCatalogClientTests.client(workspace,
            folder: { try await projects.selectedFolderPath(agentID: $0) }, sink: { _ in })

        let created = try await sessions.createOrdinarySession(profileID: "alpha")

        #expect(created.coordinate.storedSessionID == "new-after-archive")
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1)
        #expect(!workspace.calls.contains { $0.operation == .projectsSetActive || $0.operation == .projectsGet })
    }

    /// A Windows host keeps projects in drive-letter or share folders. Refusing them failed every
    /// New Chat (and first Bot Chat) for an agent with a project, before anything reached the host (#563).
    @Test(arguments: [#"D:\Projects\notes"#, "D:/Projects/notes", #"\\nas\share\notes"#])
    func windowsProjectFolderStartsNewChatsInIt(folder: String) async throws {
        let workspace = try SessionWorkspaceStub()
        let windowsProject = project(folder: folder)
        // Hermes answers with the folder as Windows writes it (`os.path.abspath`).
        let started = folder.replacingOccurrences(of: "/", with: "\\")
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return DirectHermesSessionCatalogClientTests.profiles()
            case .projectsList: return ["projects": .array([.object(windowsProject)]), "active_id": .string("p_notes")]
            case .projectsGet: return ["project": .object(windowsProject)]
            case .sessionCreate:
                #expect(payload["cwd"] == .string(folder))
                return DirectHermesSessionCatalogClientTests.created(stored: "windows-chat", cwd: started)
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let projects = DirectHermesProjectClient(workspace: workspace, owner: workspace.owner!,
            currentOwner: { workspace.owner }, resolveSession: { _ in nil })
        let sessions = DirectHermesSessionCatalogClientTests.client(workspace,
            folder: { try await projects.selectedFolderPath(agentID: $0) }, sink: { _ in })

        let created = try await sessions.createOrdinarySession(profileID: "alpha")

        #expect(created.coordinate.storedSessionID == "windows-chat")
        #expect(workspace.calls.filter { $0.operation == .sessionCreate }.count == 1,
                "The chat starts in its project, not a second time without it")
    }

    /// A folder bighelp refuses says so in plain words, and no chat starts somewhere else.
    @Test func unusableProjectFolderSaysSoAndStartsNothing() async throws {
        let workspace = try SessionWorkspaceStub()
        let escaping = project(folder: #"D:\Projects\..\keys"#)
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return DirectHermesSessionCatalogClientTests.profiles()
            case .projectsList: return ["projects": .array([.object(escaping)]), "active_id": .string("p_notes")]
            case .projectsGet: return ["project": .object(escaping)]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let projects = DirectHermesProjectClient(workspace: workspace, owner: workspace.owner!,
            currentOwner: { workspace.owner }, resolveSession: { _ in nil })
        let sessions = DirectHermesSessionCatalogClientTests.client(workspace,
            folder: { try await projects.selectedFolderPath(agentID: $0) }, sink: { _ in })

        await #expect(throws: DirectHermesSessionError.projectFolderUnusable) {
            _ = try await sessions.createOrdinarySession(profileID: "alpha")
        }
        #expect(!workspace.calls.contains { $0.operation == .sessionCreate })
    }

    @Test func selectionArchivedBetweenListAndGetDoesNotChooseAnotherProject() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        transport.responses[.projectsGet] = [["project": .object(project(archived: true))]]

        #expect(try await client(transport).selectedFolderPath(agentID: "research") == nil)
        #expect(transport.calls.map(\.operation) == [.projectsList, .projectsGet])
    }

    @Test(arguments: ["project_not_found", "other", "owner_changed"])
    func selectedProjectDeletionRaceOnlyIgnoresExactNotFound(failure: String) async throws {
        let workspace = try SessionWorkspaceStub()
        let snapshot = catalog()
        workspace.handler = { operation, _ in
            switch operation {
            case .projectsList: return snapshot
            case .projectsGet:
                if failure == "owner_changed" { throw WorkspaceClientError.ownerChanged }
                throw WorkspaceClientError.rejected(code: failure)
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let projects = DirectHermesProjectClient(workspace: workspace, owner: workspace.owner!,
            currentOwner: { workspace.owner }, resolveSession: { _ in nil })
        if failure == "project_not_found" {
            #expect(try await projects.selectedFolderPath(agentID: "alpha") == nil)
        } else {
            await #expect(throws: failure == "owner_changed"
                ? WorkspaceClientError.ownerChanged : WorkspaceClientError.rejected(code: failure)) {
                _ = try await projects.selectedFolderPath(agentID: "alpha")
            }
        }
        #expect(workspace.calls.map(\.operation) == [.projectsList, .projectsGet])
    }

    @Test func unsupportedSuggestionsDoNotInvokeFilesystemOrScan() async throws {
        let transport = try ProjectPerformer()
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client(transport).folderSuggestions(parentPath: "/", prefix: "", offset: 0, limit: 100, agentID: "research")
        }
        #expect(transport.calls.isEmpty)
    }

    @Test func ownerReplacementRejectsLateProjectRead() async throws {
        let transport = try ProjectPerformer()
        transport.responses[.projectsList] = [catalog()]
        transport.replaceOwner = true
        await #expect(throws: WorkspaceClientError.ownerChanged) { try await client(transport).load(agentID: "research") }
    }

    private func client(_ transport: ProjectPerformer, storedID: String? = "native-row",
                        runtimeID: String? = "runtime-1") -> DirectHermesProjectClient {
        let owner = transport.owner!
        return .init(workspace: transport, owner: owner, currentOwner: { transport.owner }, resolveSession: { visible in
            guard visible == "visible-chat" else { return nil }
            return try? .init(owner: owner, profileID: "research", sessionID: visible,
                storedSessionID: storedID, runtimeSessionID: runtimeID)
        })
    }

    private func project(id: String = "p_notes", archived: Bool = false,
                         folder: String = "/workspace/notes") -> [String: BighelpJSONValue] {
        ["id": .string(id), "name": .string("Notes"), "description": .string("Synthetic notes"),
         "archived": .boolean(archived), "folders": .array([
            .object(["path": .string(folder), "label": .null, "is_primary": .boolean(true)])
         ])]
    }

    private func catalog(active: String? = "p_notes", archived: Bool = false) -> [String: BighelpJSONValue] {
        ["projects": .array([.object(project(archived: archived))]), "active_id": active.map(BighelpJSONValue.string) ?? .null]
    }

    private func detail() -> [String: BighelpJSONValue] {
        ["id": .string("native-row"), "profile": .string("research"), "cwd": .string("/workspace/notes")]
    }

    private func activated(runtime: String = "runtime-1", stored: String = "native-row",
                           profile: String = "research", cwd: String = "/workspace/notes") -> [String: BighelpJSONValue] {
        ["session_id": .string(runtime), "session_key": .string(stored),
         "info": .object(["profile_name": .string(profile), "cwd": .string(cwd)])]
    }

    private func association(project: [String: BighelpJSONValue]?) -> [String: BighelpJSONValue] {
        ["project": project.map(BighelpJSONValue.object) ?? .null, "cwd": .string("/workspace/notes"), "branch": .string("")]
    }
}

@MainActor
private final class ProjectPerformer: WorkspaceOperationPerforming {
    struct Call { let operation: WorkspaceOperation; let payload: [String: BighelpJSONValue] }
    var owner: WorkspaceOwner?
    var replaceOwner = false
    var capabilities: WorkspaceCapabilities {
        .init(owner: owner, values: [.projectsEdit: .available, .sessionWorkspaceEdit: .available])
    }
    var calls: [Call] = []
    var responses: [WorkspaceOperation: [[String: BighelpJSONValue]]] = [:]

    init() throws {
        owner = .init(authority: try .fixture(id: "project-test"), authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue], owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        calls.append(.init(operation: operation, payload: payload))
        guard let result = responses[operation]?.first else { throw WorkspaceClientError.invalidResponse }
        responses[operation]?.removeFirst()
        if replaceOwner { self.owner = .init(authority: owner.authority, authenticationGeneration: UUID(), connectionGeneration: UUID()) }
        return result
    }
}
