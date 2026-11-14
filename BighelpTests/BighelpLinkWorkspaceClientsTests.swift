import Foundation
import AVFoundation
import CryptoKit
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct BighelpLinkWorkspaceClientsTests {

    @Test func skillsStoreRejectsDocumentCompletingAfterAccountReset() async {
        let client = DeferredSkillsAndToolsClient()
        let store = SkillsAndToolsStore(client: client)
        await store.load(agentID: "default")
        let loading = Task { await store.loadSkill(id: "weather", agentID: "default") }
        await client.waitUntilSkillLoadStarts()

        store.resetForAccountBoundary()
        client.resumeSkillLoad(with: HermesSkillDocument(
            agentID: "default",
            skillID: "weather",
            content: "---\nname: weather\ndescription: Old account.\n---\n\nOld.",
            sha256: String(repeating: "a", count: 64)
        ))

        #expect(await loading.value == nil)
        #expect(store.document == nil)
        #expect(store.errorMessage == nil)
        #expect(!store.isLoading)
    }

    @Test func skillsStoreRejectsDocumentCompletingAfterAgentSwitch() async {
        let client = DeferredSkillsAndToolsClient()
        let store = SkillsAndToolsStore(client: client)
        await store.load(agentID: "agent-a")
        let loading = Task { await store.loadSkill(id: "weather", agentID: "agent-a") }
        await client.waitUntilSkillLoadStarts()

        await store.load(agentID: "agent-b")
        client.resumeSkillLoad(with: HermesSkillDocument(
            agentID: "agent-a",
            skillID: "weather",
            content: "---\nname: weather\ndescription: Old agent.\n---\n\nOld.",
            sha256: String(repeating: "a", count: 64)
        ))

        #expect(await loading.value == nil)
        #expect(store.catalog?.agentID == "agent-b")
        #expect(store.document == nil)
    }

    @Test func workspaceCatalogListsAndSelectsHermesProjectsWithoutLeavingTheClientSurface() async throws {
        let messaging = WorkspaceMessagingStub { request in
            let selected = request.operation == .projectsSetActive
                ? request.payload["workspaceId"]?.string
                : "project-home"
            return try Self.result(for: request, payload: [
                "activeWorkspaceId": .string(selected ?? "project-home"),
                "workspaces": .array([
                    .object([
                        "id": .string("project-home"),
                        "name": .string("Home"),
                        "description": .string("Household workspace"),
                        "folderCount": .integer(2),
                        "isActive": .boolean(selected == "project-home"),
                    ]),
                    .object([
                        "id": .string("project-loopdy"),
                        "name": .string("bighelp"),
                        "description": .string("Product workspace"),
                        "folderCount": .integer(1),
                        "isActive": .boolean(selected == "project-loopdy"),
                    ]),
                ]),
            ])
        }
        let client = BighelpLinkHermesWorkspaceClient(messaging: messaging)

        let initial = try await client.load(agentID: "default")
        let selected = try await client.select(
            id: "project-loopdy",
            agentID: "research",
            sessionID: "loopdy-chat-0001"
        )

        #expect(initial.activeWorkspaceID == "project-home")
        #expect(selected.activeWorkspaceID == "project-loopdy")
        #expect(selected.workspaces.first(where: { $0.id == "project-loopdy" })?.isActive == true)
        #expect(messaging.requests.map(\.operation) == [.projectsList, .projectsSetActive])
        #expect(messaging.requests.first?.payload == ["agentId": .string("default")])
        #expect(messaging.requests.last?.payload == [
            "agentId": .string("research"),
            "workspaceId": .string("project-loopdy"),
            "sessionId": .string("loopdy-chat-0001"),
        ])
    }

    @Test func workspaceCatalogResolvesTheProjectAnchoredToTheExactSession() async throws {
        let messaging = WorkspaceMessagingStub { request in
            #expect(request.operation == .projectsList)
            #expect(request.payload == [
                "agentId": .string("default"),
                "sessionId": .string("session_workspace_exact_0001"),
            ])
            var payload = Self.workspaceCatalog(
                activeID: "project-home",
                rows: [
                    ("project-home", "Home", 1, true),
                    ("project-loopdy", "bighelp", 1, false),
                ]
            )
            payload["sessionWorkspaceId"] = .string("project-loopdy")
            return try Self.result(for: request, payload: payload)
        }
        let client = BighelpLinkHermesWorkspaceClient(messaging: messaging)

        let catalog = try await client.load(
            agentID: "default",
            sessionID: "session_workspace_exact_0001"
        )

        #expect(catalog.activeWorkspaceID == "project-home")
        #expect(catalog.sessionWorkspaceID == "project-loopdy")
    }

    @Test func workspaceManagerUsesExactCreateArchiveAndDirectoryOperations() async throws {
        let messaging = WorkspaceMessagingStub { request in
            switch request.operation {
            case .projectsCreate:
                #expect(request.payload == [
                    "agentId": .string("default"),
                    "name": .string("Bighelp Native"),
                    "folderPath": .string("/srv/workspaces/loopdy-native"),
                ])
                return try Self.result(for: request, payload: Self.workspaceCatalog(
                    activeID: "project-loopdy",
                    rows: [("project-loopdy", "Bighelp Native", 1, true)]
                ))
            case .projectsArchive:
                #expect(request.payload == [
                    "agentId": .string("default"),
                    "workspaceId": .string("project-loopdy"),
                ])
                return try Self.result(for: request, payload: Self.workspaceCatalog(
                    activeID: nil,
                    rows: []
                ))
            case .projectsListDirectory:
                #expect(request.payload == [
                    "agentId": .string("default"),
                    "parentPath": .string("/srv/workspaces"),
                    "prefix": .string("loo"),
                    "offset": .integer(0),
                    "limit": .integer(20),
                ])
                return try Self.result(for: request, payload: [
                    "parentPath": .string("/srv/workspaces"),
                    "folders": .array([.object([
                        "name": .string("loopdy-native"),
                        "path": .string("/srv/workspaces/loopdy-native"),
                    ])]),
                    "nextOffset": .null,
                ])
            default:
                Issue.record("Unexpected workspace manager operation: \(request.operation)")
                return try Self.result(for: request, payload: [:])
            }
        }
        let client = BighelpLinkHermesWorkspaceClient(messaging: messaging)

        let created = try await client.create(
            name: "Bighelp Native",
            folderPath: "/srv/workspaces/loopdy-native",
            agentID: "default"
        )
        let page = try await client.folderSuggestions(
            parentPath: "/srv/workspaces",
            prefix: "loo",
            offset: 0,
            limit: 20,
            agentID: "default"
        )
        let archived = try await client.archive(id: "project-loopdy", agentID: "default")

        #expect(created.activeWorkspaceID == "project-loopdy")
        #expect(page.parentPath == "/srv/workspaces")
        #expect(page.folders == [HermesWorkspaceFolderSuggestion(
            name: "loopdy-native",
            path: "/srv/workspaces/loopdy-native"
        )])
        #expect(page.nextOffset == nil)
        #expect(archived.workspaces.isEmpty)
        #expect(messaging.requests.map(\.operation) == [
            .projectsCreate,
            .projectsListDirectory,
            .projectsArchive,
        ])
    }

    @Test func workspaceStorePublishesTypedFolderSuggestionsAndAuthoritativeMutations() async throws {
        let messaging = WorkspaceMessagingStub { request in
            switch request.operation {
            case .projectsListDirectory:
                return try Self.result(for: request, payload: [
                    "parentPath": .string("/srv/workspaces"),
                    "folders": .array([.object([
                        "name": .string("loopdy-native"),
                        "path": .string("/srv/workspaces/loopdy-native"),
                    ])]),
                    "nextOffset": .null,
                ])
            case .projectsCreate:
                return try Self.result(for: request, payload: Self.workspaceCatalog(
                    activeID: "project-loopdy",
                    rows: [("project-loopdy", "Bighelp Native", 1, true)]
                ))
            case .projectsArchive:
                return try Self.result(for: request, payload: Self.workspaceCatalog(
                    activeID: nil,
                    rows: []
                ))
            default:
                Issue.record("Unexpected workspace store operation: \(request.operation)")
                return try Self.result(for: request, payload: [:])
            }
        }
        let store = HermesWorkspaceStore(
            client: BighelpLinkHermesWorkspaceClient(messaging: messaging)
        )

        await store.loadFolderSuggestions(
            typedPath: "/srv/workspaces/loo",
            agentID: "default"
        )
        let created = await store.create(
            name: "Bighelp Native",
            folderPath: "/srv/workspaces/loopdy-native",
            agentID: "default"
        )
        let archived = await store.archive(id: "project-loopdy", agentID: "default")

        #expect(store.folderSuggestions?.folders.map(\.path) == [
            "/srv/workspaces/loopdy-native",
        ])
        #expect(created)
        #expect(archived)
        #expect(store.catalog?.workspaces.isEmpty == true)
        #expect(!store.isLoadingFolderSuggestions)
        #expect(store.errorMessage == nil)
        #expect(messaging.requests.map(\.operation) == [
            .projectsListDirectory,
            .projectsCreate,
            .projectsArchive,
        ])
    }

    @Test func workspaceStoreCoalescesDuplicateLoadsForTheSameAgent() async {
        let client = SlowWorkspaceCatalogClient()
        let store = HermesWorkspaceStore(client: client)

        let firstLoad = Task { await store.load(agentID: "default") }
        await Task.yield()
        let duplicateLoad = Task { await store.load(agentID: "default") }

        await firstLoad.value
        await duplicateLoad.value

        #expect(client.loadCallCount == 1)
        #expect(store.catalog?.activeWorkspaceID == "loopdy")
        #expect(!store.isLoading)
    }

    @Test func overlappingCatalogLoadCannotLeaveEveryWorkspaceDisabled() async {
        let client = DeferredWorkspaceSelectionClient()
        let store = HermesWorkspaceStore(client: client)
        await store.load(agentID: "default", sessionID: "session_workspace_race")

        let selection = Task {
            await store.select(
                id: "home",
                agentID: "default",
                sessionID: "session_workspace_race"
            )
        }
        await client.waitUntilSelectionStarts()
        await store.load(agentID: "default", sessionID: "session_workspace_race")
        client.resumeSelection()
        _ = await selection.value

        #expect(store.selectingID == nil)
    }

    @Test func workspaceStoreRetainsTheExactWorkspaceSelectedForEachSession() async {
        let store = HermesWorkspaceStore(client: FixtureHermesWorkspaceClient())
        await store.load(agentID: "default")

        #expect(await store.select(
            id: "loopdy",
            agentID: "default",
            sessionID: "session_workspace_one"
        ))
        #expect(await store.select(
            id: "home",
            agentID: "default",
            sessionID: "session_workspace_two"
        ))

        #expect(store.workspaceID(forSessionID: "session_workspace_one") == "loopdy")
        #expect(store.workspaceID(forSessionID: "session_workspace_two") == "home")
        store.resetForAccountBoundary()
        #expect(store.workspaceID(forSessionID: "session_workspace_one") == nil)
    }

    @Test func restoredSessionWorkspaceReplacesStaleSelectionForReusedVisibleID() async {
        let store = HermesWorkspaceStore(client: FixtureHermesWorkspaceClient())
        await store.load(agentID: "default")
        #expect(await store.select(
            id: "home",
            agentID: "default",
            sessionID: "session_reused_visible_id"
        ))

        store.reconcileSessionWorkspace(
            id: "loopdy",
            sessionID: "session_reused_visible_id"
        )
        #expect(store.workspaceID(forSessionID: "session_reused_visible_id") == "loopdy")

        store.reconcileSessionWorkspace(
            id: nil,
            sessionID: "session_reused_visible_id"
        )
        #expect(store.workspaceID(forSessionID: "session_reused_visible_id") == nil)
    }

    @Test func restoredSessionWorkspaceCannotBeOverwrittenByAnOlderInflightLoad() async {
        let sessionID = "session_reopen_workspace_race"
        let client = DeferredWorkspaceCatalogClient()
        let store = HermesWorkspaceStore(client: client)
        let loading = Task {
            await store.load(agentID: "default", sessionID: sessionID)
        }
        await client.waitUntilLoadStarts()

        let restored = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["default"],
            title: "Restored chat",
            workspaceID: "project-current",
            workspaceName: "Current Project",
            isActive: true
        )
        SessionRestoreMetadataReconciler.reconcile(restored, workspaces: store)
        client.resumeLoad(with: HermesWorkspaceCatalog(
            activeWorkspaceID: "project-stale",
            sessionWorkspaceID: "project-stale",
            workspaces: [HermesWorkspaceSummary(
                id: "project-stale",
                name: "Stale Project",
                description: "An older response",
                folderCount: 1,
                isActive: true
            )]
        ))
        await loading.value

        #expect(store.workspaceID(forSessionID: sessionID) == "project-current")
        #expect(!store.isLoading)
    }

    @Test func workspacePresentationUsesTheExactSessionSelectionInsteadOfTheAgentDefault() async throws {
        let store = HermesWorkspaceStore(client: FixtureHermesWorkspaceClient())
        await store.load(agentID: "default")
        #expect(await store.select(
            id: "home",
            agentID: "default",
            sessionID: "session_workspace_presentation"
        ))

        let home = try #require(store.catalog?.workspaces.first { $0.id == "home" })
        let bighelp = try #require(store.catalog?.workspaces.first { $0.id == "loopdy" })

        #expect(store.catalog?.activeWorkspaceID == "loopdy")
        #expect(store.workspaceID(forSessionID: "session_workspace_presentation") == "home")
        #expect(HermesWorkspaceSelectionPresentation.isSelected(
            home,
            store: store,
            sessionID: "session_workspace_presentation"
        ))
        #expect(!HermesWorkspaceSelectionPresentation.isSelected(
            bighelp,
            store: store,
            sessionID: "session_workspace_presentation"
        ))
        #expect(HermesWorkspaceSelectionPresentation.selectedName(
            store: store,
            sessionID: "session_workspace_presentation"
        ) == "Home")
    }

    @Test func workspaceStoreReadsBackTheExactSessionAnchorBeforeReportingSelection() async throws {
        let messaging = WorkspaceMessagingStub { request in
            var payload = Self.workspaceCatalog(
                activeID: "project-loopdy",
                rows: [("project-loopdy", "bighelp", 1, true)]
            )
            if request.operation == .projectsList {
                payload["sessionWorkspaceId"] = .string("project-loopdy")
            }
            return try Self.result(for: request, payload: payload)
        }
        let store = HermesWorkspaceStore(
            client: BighelpLinkHermesWorkspaceClient(messaging: messaging)
        )

        let selected = await store.select(
            id: "project-loopdy",
            agentID: "default",
            sessionID: "session_workspace_verified_0001"
        )

        #expect(selected)
        #expect(store.workspaceID(forSessionID: "session_workspace_verified_0001") == "project-loopdy")
        #expect(messaging.requests.map(\.operation) == [.projectsSetActive, .projectsList])
        #expect(messaging.requests.last?.payload["sessionId"] == .string("session_workspace_verified_0001"))
    }

    @Test func workspaceStoreUsesAuthoritativeSelectionAnchorWithoutLegacyReadback() async throws {
        let client = SessionAnchoredWorkspaceSelectionClient()
        let store = HermesWorkspaceStore(client: client)

        let selected = await store.select(
            id: "project-loopdy",
            agentID: "default",
            sessionID: "session_workspace_direct_0001"
        )

        #expect(selected)
        #expect(client.scopedLoadCallCount == 0)
        #expect(store.workspaceID(forSessionID: "session_workspace_direct_0001") == "project-loopdy")
    }

    @Test func workspaceStoreRejectsASelectionHermesDoesNotConfirmForTheSession() async {
        let messaging = WorkspaceMessagingStub { request in
            var payload = Self.workspaceCatalog(
                activeID: "project-loopdy",
                rows: [("project-loopdy", "bighelp", 1, true)]
            )
            if request.operation == .projectsList {
                payload["sessionWorkspaceId"] = .null
            }
            return try Self.result(for: request, payload: payload)
        }
        let store = HermesWorkspaceStore(
            client: BighelpLinkHermesWorkspaceClient(messaging: messaging)
        )

        let selected = await store.select(
            id: "project-loopdy",
            agentID: "default",
            sessionID: "session_workspace_unconfirmed_0001"
        )

        #expect(!selected)
        #expect(store.workspaceID(forSessionID: "session_workspace_unconfirmed_0001") == nil)
        #expect(store.errorMessage == "That project could not be selected.")
    }

    @Test func authoritativeSessionWorkspaceClearRemovesTheLocalSelectionAndLabel() async {
        var sessionListCount = 0
        let messaging = WorkspaceMessagingStub { request in
            var payload = Self.workspaceCatalog(
                activeID: "project-home",
                rows: [
                    ("project-home", "Home", 1, true),
                    ("project-loopdy", "bighelp", 2, false),
                ]
            )
            if request.operation == .projectsList {
                sessionListCount += 1
                payload["sessionWorkspaceId"] = sessionListCount == 1
                    ? .string("project-loopdy")
                    : .null
            }
            return try Self.result(for: request, payload: payload)
        }
        let store = HermesWorkspaceStore(
            client: BighelpLinkHermesWorkspaceClient(messaging: messaging)
        )
        let sessionID = "session_workspace_cleared_0001"

        await store.load(agentID: "default", sessionID: sessionID)
        #expect(store.workspaceID(forSessionID: sessionID) == "project-loopdy")
        #expect(HermesWorkspaceSelectionPresentation.selectedName(
            store: store,
            sessionID: sessionID
        ) == "bighelp")

        await store.load(agentID: "default", sessionID: sessionID)

        #expect(store.workspaceID(forSessionID: sessionID) == nil)
        #expect(HermesWorkspaceSelectionPresentation.selectedName(
            store: store,
            sessionID: sessionID
        ) == nil)
    }

    private static func legacyGoalAliasCatalog(status: String = "none", corruption: String? = nil) -> [String: BighelpJSONValue] {
        let historical: [String: BighelpJSONValue] = [
            "storedId": .string("chat-collision"), "profile": .string("default"),
            "source": .string("loopdy"), "chatId": .null, "visibleId": .string("chat-collision"),
            "title": .string("Historical session"), "preview": .string(""),
            "messageCount": .integer(1), "isActive": .boolean(false),
            "startedAt": .integer(100), "lastActive": .integer(200),
        ]
        var current = historical
        current["storedId"] = .string("current-durable")
        current["visibleId"] = .string(corruption == "wrongVisible" ? "unrelated-visible" : "current-durable")
        current["chatId"] = .string("chat-collision")
        current["source"] = .string(corruption == "foreignSource" ? "local" : "loopdy")
        current["goal"] = .object([
            "version": .integer(1), "type": .string("session.goal"),
            "sessionId": .string(corruption == "wrongAlias" ? "unrelated-alias" : "chat-collision"),
            "storedSessionId": .string(corruption == "wrongStored" ? "unrelated-durable" : "current-durable"),
            "status": .string(corruption == "invalidState" ? "active" : status),
            "summary": status == "active" ? .string("Current goal") : .null,
            "updatedAt": .integer(1_788_000_000_000),
        ])
        return ["sessions": .array([.object(historical), .object(current)])]
    }

    private static func selection(
        _ provider: String,
        _ model: String,
        _ reasoning: String
    ) -> BighelpJSONValue {
        .object([
            "providerId": .string(provider),
            "modelId": .string(model),
            "reasoningEffort": .string(reasoning),
        ])
    }

    private static func summaryCard(title: String, body: String) -> BighelpJSONValue {
        .object([
            "schema": .string("loopdy.generative_ui"),
            "version": .integer(1),
            "component": .string("summary"),
            "title": .string(title),
            "body": .string(body),
        ])
    }

    private static func workspaceCatalog(
        activeID: String?,
        rows: [(id: String, name: String, folderCount: Int, isActive: Bool)]
    ) -> [String: BighelpJSONValue] {
        [
            "activeWorkspaceId": activeID.map(BighelpJSONValue.string) ?? .null,
            "workspaces": .array(rows.map { row in
                .object([
                    "id": .string(row.id),
                    "name": .string(row.name),
                    "description": .string(""),
                    "folderCount": .integer(row.folderCount),
                    "isActive": .boolean(row.isActive),
                ])
            }),
        ]
    }

    private static func task(
        id: String,
        enabled: Bool,
        schedule: String = "0 8 * * *",
        delivery: String = "loopdy",
        nextRunAt: BighelpJSONValue? = nil,
        lastStatus: BighelpJSONValue? = nil
    ) -> BighelpJSONValue {
        var value: [String: BighelpJSONValue] = [
            "id": .string(id),
            "agentId": .string("default"),
            "name": .string("Morning weather"),
            "instructions": .string("Summarize the weather."),
            "scheduleRequest": .string(schedule),
            "scheduleDisplay": .string(schedule),
            "delivery": .string(delivery),
            "enabled": .boolean(enabled),
        ]
        value["nextRunAt"] = nextRunAt
        value["lastStatus"] = lastStatus
        return .object(value)
    }

    private static func event(
        id: String,
        type: String,
        profile: String = "default",
        sessionID: BighelpJSONValue = .null,
        approvalID: BighelpJSONValue = .null,
        isRead: Bool = false,
        isPinned: Bool = false,
        detail: [String: BighelpJSONValue],
        createdAt: Int = 1_788_000_100
    ) -> BighelpJSONValue {
        .object([
            "eventId": .string(id),
            "type": .string(type),
            "profile": .string(profile),
            "sessionId": sessionID,
            "approvalId": approvalID,
            "isRead": .boolean(isRead),
            "isPinned": .boolean(isPinned),
            "detail": .object(detail),
            "createdAt": .integer(createdAt),
        ])
    }

    private static func result(
        for request: BighelpLinkWorkspaceRequest,
        payload: [String: BighelpJSONValue]
    ) throws -> BighelpLinkWorkspaceResult {
        let payloadData = try JSONEncoder().encode(BighelpJSONValue.object(payload))
        let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
        let object: [String: Any] = [
            "version": 1,
            "type": "workspace.result",
            "requestId": request.requestID,
            "operation": request.operation.rawValue,
            "status": "completed",
            "payload": payloadObject,
            "sentAt": 1_788_000_001,
        ]
        return try JSONDecoder().decode(
            BighelpLinkWorkspaceResult.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}

@MainActor
private final class AuthorityChangingAttachmentResolver: AgentAttachmentResolving {
    var action: @MainActor () -> Void = {}
    func resolve(agentID: String, storedID: String, items: [AgentAttachmentTextItem]) async throws -> [ResolvedAgentAttachmentItem] {
        action()
        return []
    }
}

@MainActor
private final class CountingAgentAttachmentResolver: AgentAttachmentResolving {
    private(set) var resolvedItemIDs: [[String]] = []

    func resolve(
        agentID: String,
        storedID: String,
        items: [AgentAttachmentTextItem]
    ) async throws -> [ResolvedAgentAttachmentItem] {
        resolvedItemIDs.append(items.map(\.id))
        return try items.map { item in
            ResolvedAgentAttachmentItem(
                id: item.id,
                text: "Rendered video attached.",
                attachments: [try ChatAttachment(
                    id: String(repeating: "d", count: 32),
                    fileName: "render.mov",
                    mimeType: "video/quicktime",
                    data: Data([0, 1, 2, 3])
                )]
            )
        }
    }
}

private final class WorkspaceMessagingStub: BighelpLinkWorkspaceMessaging {
    var supportsState = false
    var workspaceOwnerIdentity = "fixture-workspace"
    var onRequest: ((BighelpLinkWorkspaceRequest) -> Void)?
    func prepareSessionStateSupport() async throws -> Bool { supportsState }
    private let handler: (BighelpLinkWorkspaceRequest) throws -> BighelpLinkWorkspaceResult
    private(set) var requests: [BighelpLinkWorkspaceRequest] = []

    init(handler: @escaping (BighelpLinkWorkspaceRequest) throws -> BighelpLinkWorkspaceResult) {
        self.handler = handler
    }

    func performWorkspaceRequest(
        _ request: BighelpLinkWorkspaceRequest
    ) async throws -> BighelpLinkWorkspaceResult {
        requests.append(request)
        onRequest?(request)
        return try handler(request)
    }
}

@MainActor
private final class DeferredSessionMutationWorkspaceMessaging: BighelpLinkWorkspaceMessaging {
    private var requestsByStoredID: [String: BighelpLinkWorkspaceRequest] = [:]
    private var continuationsByStoredID: [
        String: CheckedContinuation<BighelpLinkWorkspaceResult, Error>
    ] = [:]

    func performWorkspaceRequest(
        _ request: BighelpLinkWorkspaceRequest
    ) async throws -> BighelpLinkWorkspaceResult {
        guard
            request.operation == .sessionUpdate,
            let storedID = request.payload["storedId"]?.string
        else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        requestsByStoredID[storedID] = request
        return try await withCheckedThrowingContinuation { continuation in
            continuationsByStoredID[storedID] = continuation
        }
    }

    func waitUntilRequestStarts(storedID: String) async {
        while requestsByStoredID[storedID] == nil { await Task.yield() }
    }

    func resume(storedID: String) {
        guard let request = requestsByStoredID[storedID] else {
            Issue.record("Missing deferred session mutation for \(storedID).")
            return
        }
        do {
            let payload: [String: BighelpJSONValue] = [
                "storedId": .string(storedID),
                "agentId": request.payload["agentId"] ?? .string("missing"),
                "updated": .boolean(true),
            ]
            let payloadData = try JSONEncoder().encode(BighelpJSONValue.object(payload))
            let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
            let object: [String: Any] = [
                "version": 1,
                "type": "workspace.result",
                "requestId": request.requestID,
                "operation": request.operation.rawValue,
                "status": "completed",
                "payload": payloadObject,
                "sentAt": 1_788_000_001,
            ]
            let result = try JSONDecoder().decode(
                BighelpLinkWorkspaceResult.self,
                from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
            continuationsByStoredID.removeValue(forKey: storedID)?.resume(returning: result)
        } catch {
            continuationsByStoredID.removeValue(forKey: storedID)?.resume(throwing: error)
        }
    }
}

private enum ControlledAgentMetadataError: Error {
    case unavailable
}

@MainActor
private final class ControlledFailingAgentMetadataStore: HermesAgentMetadataStoring {
    private var values: [String: AgentProfile]
    private var order: [String]
    private var baselineFailureCount: Int
    private var finalFailureCount: Int

    init(
        profiles: [AgentProfile] = [],
        baselineFailureCount: Int = 0,
        finalFailureCount: Int = 0
    ) {
        values = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        order = profiles.map(\.id)
        self.baselineFailureCount = baselineFailureCount
        self.finalFailureCount = finalFailureCount
    }

    func profiles() throws -> [AgentProfile] {
        order.compactMap { values[$0] }
    }

    func profile(id: String) throws -> AgentProfile? {
        values[id]
    }

    func save(_ profile: AgentProfile) throws {
        if finalFailureCount > 0 {
            finalFailureCount -= 1
            throw ControlledAgentMetadataError.unavailable
        }
        persist(profile)
    }

    func saveCanonicalBaseline(_ profile: AgentProfile) throws {
        if baselineFailureCount > 0 {
            baselineFailureCount -= 1
            throw ControlledAgentMetadataError.unavailable
        }
        persist(profile)
    }

    func replaceAll(_ profiles: [AgentProfile]) throws {
        values = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        order = profiles.map(\.id)
    }

    private func persist(_ profile: AgentProfile) {
        if values[profile.id] == nil {
            order.append(profile.id)
        }
        values[profile.id] = profile
    }
}

@MainActor
private final class DeferredSessionWorkspaceMessaging: BighelpLinkWorkspaceMessaging {
    private var listContinuations: [Int: CheckedContinuation<BighelpLinkWorkspaceResult, Error>] = [:]
    private var historyContinuations: [Int: CheckedContinuation<BighelpLinkWorkspaceResult, Error>] = [:]
    private(set) var listRequests: [BighelpLinkWorkspaceRequest] = []
    private(set) var historyRequests: [BighelpLinkWorkspaceRequest] = []

    func performWorkspaceRequest(
        _ request: BighelpLinkWorkspaceRequest
    ) async throws -> BighelpLinkWorkspaceResult {
        switch request.operation {
        case .sessionsList:
            listRequests.append(request)
            let index = listRequests.count
            return try await withCheckedThrowingContinuation { continuation in
                listContinuations[index] = continuation
            }
        case .sessionHistory:
            historyRequests.append(request)
            let index = historyRequests.count
            return try await withCheckedThrowingContinuation { continuation in
                historyContinuations[index] = continuation
            }
        default:
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
    }

    func waitUntilListStarts(count: Int) async {
        while listRequests.count < count { await Task.yield() }
    }

    func waitUntilHistoryStarts(count: Int) async {
        while historyRequests.count < count { await Task.yield() }
    }

    func resumeList(request index: Int, visibleID: String, storedID: String) {
        guard listRequests.indices.contains(index - 1) else {
            Issue.record("Missing deferred sessions.list request \(index).")
            return
        }
        let request = listRequests[index - 1]
        do {
            let result = try Self.result(for: request, payload: [
                "sessions": .array([.object([
                    "storedId": .string(storedID),
                    "profile": .string("default"),
                    "source": .string("loopdy"),
                    "chatId": .string(visibleID),
                    "visibleId": .string(visibleID),
                    "title": .string("Race session"),
                    "preview": .string("Preview"),
                    "messageCount": .integer(1),
                    "isActive": .boolean(false),
                    "startedAt": .integer(1_788_000_000),
                    "lastActive": .integer(1_788_000_100),
                ])]),
            ])
            listContinuations.removeValue(forKey: index)?.resume(returning: result)
        } catch {
            listContinuations.removeValue(forKey: index)?.resume(throwing: error)
        }
    }

    func resumeHistory(request index: Int, returnedStoredID: String, content: String) {
        guard historyRequests.indices.contains(index - 1) else {
            Issue.record("Missing deferred session.history request \(index).")
            return
        }
        let request = historyRequests[index - 1]
        do {
            let result = try Self.result(for: request, payload: [
                "storedId": .string(returnedStoredID),
                "agentId": .string("default"),
                "messages": .array([.object([
                    "id": .string("message-\(index)"),
                    "row_id": .integer(index),
                    "role": .string("assistant"),
                    "content": .string(content),
                ])]),
            ])
            historyContinuations.removeValue(forKey: index)?.resume(returning: result)
        } catch {
            historyContinuations.removeValue(forKey: index)?.resume(throwing: error)
        }
    }

    private static func result(
        for request: BighelpLinkWorkspaceRequest,
        payload: [String: BighelpJSONValue]
    ) throws -> BighelpLinkWorkspaceResult {
        let payloadData = try JSONEncoder().encode(BighelpJSONValue.object(payload))
        let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
        return try JSONDecoder().decode(
            BighelpLinkWorkspaceResult.self,
            from: JSONSerialization.data(withJSONObject: [
                "version": 1,
                "type": "workspace.result",
                "requestId": request.requestID,
                "operation": request.operation.rawValue,
                "status": "completed",
                "payload": payloadObject,
                "sentAt": 1_788_000_001,
            ], options: [.sortedKeys])
        )
    }
}

@MainActor
private final class SlowWorkspaceCatalogClient: HermesWorkspaceCatalogClient {
    private(set) var loadCallCount = 0

    func load(agentID _: String) async throws -> HermesWorkspaceCatalog {
        loadCallCount += 1
        try await Task.sleep(for: .milliseconds(50))
        return HermesWorkspaceCatalog(
            activeWorkspaceID: "loopdy",
            workspaces: [HermesWorkspaceSummary(
                id: "loopdy",
                name: "bighelp",
                description: "Product workspace",
                folderCount: 1,
                isActive: true
            )]
        )
    }

    func select(
        id _: String,
        agentID _: String,
        sessionID _: String?
    ) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func create(
        name _: String,
        folderPath _: String,
        agentID _: String
    ) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func archive(id _: String, agentID _: String) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func folderSuggestions(
        parentPath _: String,
        prefix _: String,
        offset _: Int,
        limit _: Int,
        agentID _: String
    ) async throws -> HermesWorkspaceFolderPage {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }
}

@MainActor
private final class SessionAnchoredWorkspaceSelectionClient: HermesWorkspaceCatalogClient {
    private(set) var scopedLoadCallCount = 0

    func load(agentID _: String) async throws -> HermesWorkspaceCatalog {
        catalog(sessionWorkspaceID: nil)
    }

    func load(agentID _: String, sessionID _: String?) async throws -> HermesWorkspaceCatalog {
        scopedLoadCallCount += 1
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func select(id: String, agentID _: String, sessionID _: String?) async throws -> HermesWorkspaceCatalog {
        catalog(sessionWorkspaceID: id)
    }

    func create(name _: String, folderPath _: String, agentID _: String) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func archive(id _: String, agentID _: String) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func folderSuggestions(
        parentPath _: String,
        prefix _: String,
        offset _: Int,
        limit _: Int,
        agentID _: String
    ) async throws -> HermesWorkspaceFolderPage {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    private func catalog(sessionWorkspaceID: String?) -> HermesWorkspaceCatalog {
        HermesWorkspaceCatalog(
            activeWorkspaceID: "project-loopdy",
            sessionWorkspaceID: sessionWorkspaceID,
            workspaces: [HermesWorkspaceSummary(
                id: "project-loopdy",
                name: "bighelp",
                description: "Product workspace",
                folderCount: 1,
                isActive: true
            )]
        )
    }
}

@MainActor
private final class DeferredWorkspaceSelectionClient: HermesWorkspaceCatalogClient {
    private var selectionContinuation: CheckedContinuation<HermesWorkspaceCatalog, Error>?
    private var selectionStartContinuations: [CheckedContinuation<Void, Never>] = []

    func load(agentID _: String) async throws -> HermesWorkspaceCatalog {
        catalog(sessionWorkspaceID: "loopdy")
    }

    func load(agentID _: String, sessionID _: String?) async throws -> HermesWorkspaceCatalog {
        catalog(sessionWorkspaceID: "loopdy")
    }

    func select(
        id _: String,
        agentID _: String,
        sessionID _: String?
    ) async throws -> HermesWorkspaceCatalog {
        try await withCheckedThrowingContinuation { continuation in
            selectionContinuation = continuation
            let waiters = selectionStartContinuations
            selectionStartContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSelectionStarts() async {
        guard selectionContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            selectionStartContinuations.append(continuation)
        }
    }

    func resumeSelection() {
        let continuation = selectionContinuation
        selectionContinuation = nil
        continuation?.resume(returning: catalog(sessionWorkspaceID: "home"))
    }

    func create(name _: String, folderPath _: String, agentID _: String) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func archive(id _: String, agentID _: String) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func folderSuggestions(
        parentPath _: String,
        prefix _: String,
        offset _: Int,
        limit _: Int,
        agentID _: String
    ) async throws -> HermesWorkspaceFolderPage {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    private func catalog(sessionWorkspaceID: String) -> HermesWorkspaceCatalog {
        HermesWorkspaceCatalog(
            activeWorkspaceID: "loopdy",
            sessionWorkspaceID: sessionWorkspaceID,
            workspaces: [
                HermesWorkspaceSummary(
                    id: "loopdy",
                    name: "bighelp",
                    description: "Product workspace",
                    folderCount: 1,
                    isActive: true
                ),
                HermesWorkspaceSummary(
                    id: "home",
                    name: "Home",
                    description: "Household workspace",
                    folderCount: 1,
                    isActive: false
                ),
            ]
        )
    }
}

@MainActor
private final class DeferredSkillsAndToolsClient: HermesSkillsAndToolsCatalogClient {
    private var skillContinuation: CheckedContinuation<HermesSkillDocument, Error>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func load(agentID: String) async throws -> HermesSkillsAndToolsCatalog {
        HermesSkillsAndToolsCatalog(
            agentID: agentID,
            skills: [],
            plugins: [],
            mcpServers: [],
            management: .init(canRead: true, canCreate: false, canUpdate: false, canImport: false)
        )
    }

    func skill(id: String, agentID: String) async throws -> HermesSkillDocument {
        try await withCheckedThrowingContinuation { continuation in
            skillContinuation = continuation
            let waiters = startContinuations
            startContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSkillLoadStarts() async {
        guard skillContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func resumeSkillLoad(with document: HermesSkillDocument) {
        let continuation = skillContinuation
        skillContinuation = nil
        continuation?.resume(returning: document)
    }
}

@MainActor
private final class DeferredWorkspaceCatalogClient: HermesWorkspaceCatalogClient {
    private var loadContinuation: CheckedContinuation<HermesWorkspaceCatalog, Error>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func load(agentID _: String) async throws -> HermesWorkspaceCatalog {
        try await load(agentID: "default", sessionID: nil)
    }

    func load(agentID _: String, sessionID _: String?) async throws -> HermesWorkspaceCatalog {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            let waiters = startContinuations
            startContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilLoadStarts() async {
        guard loadContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func resumeLoad(with catalog: HermesWorkspaceCatalog) {
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume(returning: catalog)
    }

    func select(
        id _: String,
        agentID _: String,
        sessionID _: String?
    ) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func create(
        name _: String,
        folderPath _: String,
        agentID _: String
    ) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func archive(id _: String, agentID _: String) async throws -> HermesWorkspaceCatalog {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func folderSuggestions(
        parentPath _: String,
        prefix _: String,
        offset _: Int,
        limit _: Int,
        agentID _: String
    ) async throws -> HermesWorkspaceFolderPage {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }
}

private struct SessionHistoryConversationStub: ConversationClient {
    func send(message _: String, conversationID _: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }

    func perform(action _: QuickAction, conversationID _: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }
}
