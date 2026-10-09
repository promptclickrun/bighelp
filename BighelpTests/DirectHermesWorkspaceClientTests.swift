import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesWorkspaceClientTests {
    @Test(arguments: [5062, 5061, 5063])
    func onlyProjectGetNotFoundHasRecoverableSelectionMeaning(code: Int) async throws {
        let authority = try WorkspaceAuthority.fixture(id: "project-read-refusal")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = WorkspaceTransportStub()
        transport.failure = .rpcRejected(code: code)
        let client = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
            capabilities: .init(owner: owner), currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.rejected(code: code == 5062 ? "project_not_found" : nil)) {
            _ = try await client.perform(.projectsGet, payload: ["profile": .string("alpha"), "id": .string("p")], owner: owner)
        }
        await #expect(throws: WorkspaceClientError.rejected(code: nil)) {
            _ = try await client.perform(.projectsList, payload: ["profile": .string("alpha")], owner: owner)
        }
    }

    @Test func nativeCreationOptionsRouteWithoutSelectiveFlags() throws {
        for operation in [WorkspaceOperation.profilesCreate, .profilesClone] {
            let payload: [String: BighelpJSONValue] = [
                "name": .string("new-agent"), "clone_from": .string("source"),
                "no_skills": .boolean(false), "clone_all": .boolean(false),
                "mirror_credentials": .boolean(false), "no_alias": .boolean(true)
            ]
            #expect(try DirectHermesWorkspaceClient.route(operation, payload: payload) == .rpc("profiles.create", payload))
            #expect(throws: WorkspaceClientError.invalidRequest) {
                try DirectHermesWorkspaceClient.route(operation,
                    payload: payload.merging(["clone_skills": .boolean(true)]) { _, value in value })
            }
        }
    }
    @Test func fastModeUsesExplicitSessionOrDefaultScope() throws {
        let session: [String: BighelpJSONValue] = [
            "profile": .string("studio"), "session_id": .string("runtime-chat"),
            "key": .string("fast"), "value": .string("on"), "scope": .string("session")
        ]
        #expect(try DirectHermesWorkspaceClient.route(.configSet, payload: session) == .rpc("config.set", session))
        let defaults: [String: BighelpJSONValue] = [
            "profile": .string("studio"), "key": .string("fast"),
            "value": .string("off"), "scope": .string("global")
        ]
        #expect(try DirectHermesWorkspaceClient.route(.configSet, payload: defaults) == .rpc("config.set", defaults))
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.configSet, payload: ["key": .string("fast"), "value": .string("on")])
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.configSet, payload: session.merging(["scope": .string("global")]) { _, new in new })
        }
    }

    @Test func firstCanonicalBirthUsesExplicitNativeRegistryAndPersistenceOperations() throws {
        let lookup: [String: BighelpJSONValue] = [
            "profile": .string("studio"), "title": .string("Bot Chat"), "include_hidden": .boolean(true),
        ]
        #expect(try DirectHermesWorkspaceClient.route(.nativeSessionList, payload: lookup) == .rpc("session.list", lookup))
        let create: [String: BighelpJSONValue] = [
            "profile": .string("studio"), "title": .string("Bot Chat"),
            "hidden": .boolean(true), "follow_profile_config": .boolean(true),
            "cwd": .string("/workspace/notes"), "cwd_explicit": .boolean(true), "source": .string("bighelp"),
        ]
        #expect(try DirectHermesWorkspaceClient.route(.sessionCreate, payload: create) == .rpc("session.create", create))
        let title: [String: BighelpJSONValue] = ["session_id": .string("live"), "title": .string("Bot Chat")]
        #expect(try DirectHermesWorkspaceClient.route(.sessionTitle, payload: title) == .rpc("session.title", title))
    }

    @Test func canonicalResumeUsesNativeCoordinatesAndTheBighelpSource() throws {
        let payload: [String: BighelpJSONValue] = [
            "profile": .string("studio"), "session_id": .string("canonical"),
            "defer_history": .boolean(true), "omit_messages": .boolean(true), "source": .string("bighelp"),
        ]
        #expect(try DirectHermesWorkspaceClient.route(.sessionResume, payload: payload) == .rpc("session.resume", payload))
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.sessionResume,
                payload: payload.merging(["cwd": .string("/elsewhere")]) { _, value in value })
        }
    }

    @Test func nativeGroupsNeverReceiveClientPersonOrLinkMetadata() throws {
        let payload: [String: BighelpJSONValue] = [
            "room_id": .string("room"), "event_id": .string("event"),
            "payload": .object(["text": .string("Hello"), "thread_id": .string("main")]),
        ]
        #expect(try DirectHermesWorkspaceClient.route(.groupsSend, payload: payload) == .rpc("groups.send", payload))
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.groupsSend,
                payload: payload.merging(["groupsResultVersion": .integer(1)]) { _, value in value })
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.groupsSend,
                payload: payload.merging(["person": .string("Local display")]) { _, value in value })
        }
    }

    @Test func processScopedRoutesRejectAnIgnoredProfileSelector() {
        for operation in [WorkspaceOperation.memoryGet, .webhooksList, .systemStatus, .logsList] {
            #expect(throws: WorkspaceClientError.invalidRequest) {
                try DirectHermesWorkspaceClient.route(operation, payload: ["profile": .string("foreign")])
            }
        }
    }

    @Test func arbitraryConfigurationAndTraversalAreRejectedBeforeNetworking() {
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.configSet,
                payload: ["key": .string("approval_mode"), "value": .string("off")])
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.configSet,
                payload: ["key": .string("model"), "value": .string("model-id")])
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.sessionHistory,
                payload: ["session_id": .string("../env"), "profile": .string("default")])
        }
    }

    @Test func bareToolsetArrayIsWrappedWithoutInventingPagination() async throws {
        let authority = try WorkspaceAuthority.fixture(id: "test-host")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = WorkspaceTransportStub()
        transport.result = .array([.object(["name": .string("terminal")])])
        let client = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
                                                 capabilities: .init(owner: owner), currentOwner: { owner })
        let result = try await client.perform(.toolsetsList, payload: ["profile": .string("studio")], owner: owner)
        #expect(result == ["toolsets": transport.result])
        #expect(transport.httpRequests.first?.path == "/api/tools/toolsets")
        #expect(transport.httpRequests.first?.query == [URLQueryItem(name: "profile", value: "studio")])
    }

    @Test func existingDashboardSessionEnvelopesRemainSupportedWithoutFabricatingPagination() async throws {
        let authority = try WorkspaceAuthority.fixture(id: "test-host")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = WorkspaceTransportStub()
        let row: BighelpJSONValue = .object(["id": .string("stored-session"), "profile": .string("studio"), "started_at": .integer(1700000000)])
        let client = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
                                                capabilities: .init(owner: owner), currentOwner: { owner })
        transport.result = .object(["sessions": .array([row]), "total": .integer(1), "limit": .integer(100), "offset": .integer(0)])
        let list = try await client.perform(.sessionsList, payload: ["profile": .string("studio"), "limit": .integer(100), "offset": .integer(0)], owner: owner)
        #expect(list["sessions"] == .array([row]))
        #expect(list["has_more"] == nil)
        #expect(list["total"] == .integer(1))
        transport.result = row
        let detail = try await client.perform(.sessionDetail, payload: ["profile": .string("studio"), "session_id": .string("stored-session")], owner: owner)
        #expect(detail == row.object)
        transport.result = .object(["sessions": .array([.object(["id": .string("foreign"), "profile": .string("another-profile")])]), "total": .integer(1), "limit": .integer(100), "offset": .integer(0)])
        await #expect(throws: WorkspaceClientError.invalidResponse) {
            try await client.perform(.sessionsList, payload: ["profile": .string("studio")], owner: owner)
        }
    }

    @Test func officialSessionListEnvelopeIsNormalizedForNativeCatalogConsumers() async throws {
        let authority = try WorkspaceAuthority.fixture(id: "test-host")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = WorkspaceTransportStub()
        let row: BighelpJSONValue = .object([
            "id": .string("stored-session"),
            "source": .string("api_server"),
            "started_at": .string("2026-09-13T12:00:00Z"),
        ])
        transport.result = .object([
            "object": .string("list"),
            "data": .array([row]),
            "limit": .integer(100),
            "offset": .integer(0),
            "has_more": .boolean(false),
        ])
        let client = DirectHermesWorkspaceClient(
            rpc: transport, http: transport, owner: owner,
            capabilities: .init(owner: owner), currentOwner: { owner }
        )

        let result = try await client.perform(
            .sessionsList,
            payload: ["profile": .string("studio"), "limit": .integer(100), "offset": .integer(0)],
            owner: owner
        )

        #expect(result["sessions"]?.array == [
            .object([
                "id": .string("stored-session"),
                "source": .string("api_server"),
                "started_at": .string("2026-09-13T12:00:00Z"),
                "profile": .string("studio"),
            ])
        ])
        #expect(result["limit"]?.integer == 100)
        #expect(result["offset"]?.integer == 0)
        #expect(result["has_more"]?.boolean == false)
        #expect(result["total"] == nil)
    }

    @Test func officialSessionDetailEnvelopeIsNormalizedWithRequestedProfileContext() async throws {
        let authority = try WorkspaceAuthority.fixture(id: "test-host")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = WorkspaceTransportStub()
        transport.result = .object([
            "object": .string("hermes.session"),
            "session": .object([
                "id": .string("stored-session"),
                "cwd": .string("/workspace/notes"),
            ]),
        ])
        let client = DirectHermesWorkspaceClient(
            rpc: transport, http: transport, owner: owner,
            capabilities: .init(owner: owner), currentOwner: { owner }
        )

        let result = try await client.perform(
            .sessionDetail,
            payload: ["profile": .string("studio"), "session_id": .string("stored-session")],
            owner: owner
        )

        #expect(result["id"]?.string == "stored-session")
        #expect(result["cwd"]?.string == "/workspace/notes")
        #expect(result["profile"]?.string == "studio")
        #expect(result["object"] == nil)
    }

    @Test func directCommandCatalogLoadsOfficialSkillsForImmediateSlashFiltering() async throws {
        let authority = try WorkspaceAuthority.fixture(id: "test-host")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = WorkspaceTransportStub()
        let helpPair: BighelpJSONValue = .array([.string("/help"), .string("Show available commands")])
        let pluginPair: BighelpJSONValue = .array([.string("/lint"), .string("Lint the current project")])
        let skillPair: BighelpJSONValue = .array([.string("/calendar-sync"), .string("Synchronize a calendar")])
        transport.result = .object([
            "pairs": .array([helpPair, pluginPair, skillPair]),
            "canon": .object([
                "/help": .string("/help"), "/h": .string("/help"),
            ]),
            "commands": .object([
                "/help": .object(["argument_mode": .string("options")]),
                "/lint": .object(["argument_mode": .string("text")]),
            ]),
            "categories": .array([
                .object(["name": .string("Info"), "pairs": .array([helpPair])]),
                .object(["name": .string("Plugin commands"), "pairs": .array([pluginPair])]),
            ]),
            // Skill IDs are returned by Hermes as the slash key. Keep this
            // exact invocation ID so autocomplete does not silently rewrite it.
            "skills": .object([
                "/calendar-sync": .object([
                    "usage": .integer(0), "origin": .string("local"),
                ])
            ]),
            "skill_count": .integer(1),
            "warning": .string(""),
        ])
        let workspace = DirectHermesWorkspaceClient(
            rpc: transport, http: transport, owner: owner,
            capabilities: .init(owner: owner), currentOwner: { owner }
        )
        let client = DirectHermesSlashCommandCatalogClient(
            workspace: workspace, owner: owner, currentOwner: { owner }
        )
        let model = SlashCommandCatalogModel(sessionID: "visible-session", agentID: "studio", client: client)

        await model.loadIfNeeded(for: "/")

        #expect(transport.rpcRequests.count == 1)
        #expect(transport.rpcRequests.first?.method == "commands.catalog")
        #expect(transport.rpcRequests.first?.params == [
            "session_id": .string("visible-session"), "profile": .string("studio")
        ])
        #expect(model.commands.map(\.name) == ["help", "lint", "calendar-sync"])
        #expect(model.commands.first?.aliases == ["h"])
        #expect(model.commands.first?.argumentMode == .options)
        #expect(model.commands[1].source == .plugin)
        #expect(model.commands[2].name == "calendar-sync")
        #expect(model.commands[2].source == .skill)
        #expect(model.commands[2].category == "Skills")
        #expect(model.index.suggestions(for: "/").map(\.name) == ["help", "lint", "calendar-sync"])
        #expect(model.index.suggestions(for: "/calendar").map(\.name) == ["calendar-sync"])
    }

    @Test func oneUnusableCatalogEntryDoesNotHideTheOtherCommands() async throws {
        let authority = try WorkspaceAuthority.fixture(id: "test-host")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = WorkspaceTransportStub()
        let longDescription = String(repeating: "Route work across several apps. ", count: 12)
        transport.result = .object([
            "pairs": .array([
                .array([.string("/help"), .string("Show available commands")]),
                // A skill whose author wrote a long description.
                .array([.string("/wordy-skill"), .string(longDescription)]),
                .array([.string("/multi-line"), .string("First line\nSecond line")]),
                // Names the composer can't insert are left out.
                .array([.string("no-slash"), .string("Missing its slash")]),
                .array([.string("/has space"), .string("Space in the name")]),
                .array([.string("/empty-description"), .string("")]),
            ]),
            "skills": .object([
                "/wordy-skill": .object(["usage": .integer(0), "origin": .string("local")]),
            ]),
            "warning": .string(""),
        ])
        let workspace = DirectHermesWorkspaceClient(
            rpc: transport, http: transport, owner: owner,
            capabilities: .init(owner: owner), currentOwner: { owner }
        )
        let client = DirectHermesSlashCommandCatalogClient(
            workspace: workspace, owner: owner, currentOwner: { owner }
        )
        let model = SlashCommandCatalogModel(sessionID: "visible-session", agentID: "studio", client: client)

        await model.loadIfNeeded(for: "/")

        #expect(model.errorMessage == nil)
        #expect(model.commands.map(\.name) == ["help", "wordy-skill", "multi-line", "empty-description"])
        let wordy = try #require(model.commands.first { $0.name == "wordy-skill" })
        #expect(wordy.description.count == DirectHermesSlashCommandCatalogClient.maximumDescriptionLength)
        #expect(wordy.description.hasSuffix("…"))
        #expect(wordy.source == .skill)
        #expect(model.commands.first { $0.name == "multi-line" }?.description == "First line Second line")
        #expect(model.commands.first { $0.name == "empty-description" }?.description == "Command")
    }

    @Test func replacedOwnerCannotCommitOrRetryAnOldResult() async throws {
        let authority = try WorkspaceAuthority.fixture(id: "test-host")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        var current: WorkspaceOwner? = owner
        let transport = WorkspaceTransportStub()
        transport.onRequest = { current = nil }
        let client = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
                                                 capabilities: .init(owner: owner), currentOwner: { current })
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await client.perform(.groupsStop, payload: ["room_id": .string("room")], owner: owner)
        }
        #expect(transport.rpcCount == 1)
    }
}

@MainActor
private final class WorkspaceTransportStub: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    struct RPCRequest {
        let method: String
        let params: [String: BighelpJSONValue]
    }

    var onEvent: ((DirectHermesEvent) -> Void)?
    var onRequest: (() -> Void)?
    var result: BighelpJSONValue = .object([:])
    var failure: DirectHermesError?
    var httpRequests: [DirectHermesHTTPRequest] = []
    var rpcRequests: [RPCRequest] = []
    var rpcCount = 0
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        rpcCount += 1
        rpcRequests.append(RPCRequest(method: method, params: params))
        onRequest?()
        if let failure { throw failure }
        return result
    }
    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        httpRequests.append(request)
        onRequest?()
        return result
    }
    func disconnect() async {}
}
