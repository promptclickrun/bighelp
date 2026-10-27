import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NewChatCoordinatorTests {
    @Test func presentationHookRunsBeforeEachReplacementWithoutWaitingForAllocation() async throws {
        let client = DeferredNewChatSessionCatalogClient()
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.defaultFixture]),
                                         profiles: [.defaultFixture])
        let state = AppState()
        state.activateConversation(id: "outgoing", source: .sessions)
        let catalog = SessionCatalogStore(client: client)
        let coordinator = NewChatCoordinator(appState: state, agents: agents, catalog: catalog, prepare: { _ in true })
        var replacements: [(next: String, previous: String?)] = []
        let start = Task {
            try await coordinator.start(beforePresentation: { next, previous in
                #expect(state.activeConversationID == previous, "Snapshot capture precedes route replacement")
                replacements.append((next, previous))
            })
        }
        await client.waitUntilCreateStarts()
        let local = state.activeConversationID
        #expect(replacements.count == 1, "The effect starts with the local canvas, before Hermes answers")
        #expect(replacements.first?.previous == "outgoing")
        client.finishCreation()
        _ = try await start.value
        #expect(replacements.count == 2)
        #expect(replacements.last?.previous == local)
        #expect(replacements.last?.next == "session-shared")
    }

    @Test func newChatPresentsLocalCanvasBeforeAuthoritativeAllocationFinishes() async throws {
        let client = DeferredNewChatSessionCatalogClient()
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture]),
            profiles: [.defaultFixture]
        )
        let state = AppState()
        let catalog = SessionCatalogStore(client: client)
        var presentedRoute: AppRoute?
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { route in
                presentedRoute = route
                return true
            }
        )

        let start = Task { try await coordinator.start() }
        await client.waitUntilCreateStarts()

        guard case .chat(let presentationID)? = presentedRoute else {
            Issue.record("New Chat did not present a local canvas while Hermes allocation was pending")
            client.finishCreation()
            _ = try await start.value
            return
        }
        #expect(presentationID.hasPrefix("local-draft:"))
        #expect(catalog.session(id: presentationID) != nil)
        #expect(state.path == [.chat(conversationID: presentationID)])

        client.finishCreation()
        let outcome = try await start.value
        #expect(outcome == .opened(sessionID: "session-shared", agentID: "default"))
        #expect(state.path == [.chat(conversationID: "session-shared")])
        #expect(catalog.session(id: presentationID) == nil)
    }

    @Test func failedNewChatAllocationRetainsLocalDraftForRetry() async throws {
        let client = DeferredNewChatSessionCatalogClient()
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture]),
            profiles: [.defaultFixture]
        )
        let state = AppState()
        let catalog = SessionCatalogStore(client: client)
        var presentationID: String?
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { route in
                guard case .chat(let id) = route else { return false }
                presentationID = id
                catalog.updateDraft("Keep this while Hermes reconnects", for: id)
                return true
            }
        )

        let start = Task { try await coordinator.start() }
        await client.waitUntilCreateStarts()
        client.failCreation()
        do {
            _ = try await start.value
            Issue.record("Expected authoritative New Chat allocation to fail")
        } catch NewChatAllocationError.unavailable {
        }

        guard let presentationID else {
            Issue.record("Missing local presentation draft")
            return
        }
        #expect(presentationID.hasPrefix("local-draft:"))
        #expect(catalog.session(id: presentationID)?.draft == "Keep this while Hermes reconnects")
        #expect(state.path == [.chat(conversationID: presentationID)])
    }

    @Test func allocationCompletionDoesNotHijackNavigationAfterLeavingLocalCanvas() async throws {
        let client = DeferredNewChatSessionCatalogClient()
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture]),
            profiles: [.defaultFixture]
        )
        let state = AppState()
        let catalog = SessionCatalogStore(client: client)
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { _ in true }
        )

        let start = Task { try await coordinator.start() }
        await client.waitUntilCreateStarts()
        guard case .chat(let presentationID)? = state.path.last else {
            Issue.record("New Chat did not present its local route")
            client.finishCreation()
            _ = try await start.value
            return
        }
        state.select(.sessions)
        client.finishCreation()

        let outcome = try await start.value
        #expect(outcome == .opened(sessionID: "session-shared", agentID: "default"))
        #expect(state.path.isEmpty)
        #expect(catalog.session(id: presentationID) == nil)
        #expect(catalog.session(id: "session-shared") != nil)
    }

    @Test func creatingAnotherLocalCanvasKeepsEarlierDraftForRecovery() {
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient())
        let first = catalog.createLocalPresentationDraft(agentID: "default")
        catalog.updateDraft("Keep this draft", for: first.id)
        let second = catalog.createLocalPresentationDraft(agentID: "finance")

        #expect(first.id != second.id)
        #expect(catalog.session(id: first.id)?.draft == "Keep this draft")
        #expect(catalog.session(id: second.id)?.draft.isEmpty == true)
    }

    @Test func pendingLocalCanvasKeepsComposerEditableButDoesNotSend() {
        let model = ChatModel(
            conversationID: "local-draft:pending-send",
            client: NativeWorkspaceUnavailableClient(),
            initialItems: [],
            initialDraft: "Keep this until Hermes allocates the chat"
        )

        #expect(!model.canSend)
        #expect(!model.isComposerInputDisabled)
        #expect(model.isComposerAttachmentInputDisabled)
    }

    @Test func newChatActionExpandsItsHitAreaWithoutGrowingTheVisibleControl() {
        let presentation = SpectrumAction.hitTargetPresentation

        #expect(presentation.visualSize == BighelpTokens.primaryActionSize)
        #expect(presentation.minimumHeight == BighelpTokens.primaryActionSize)
        #expect(presentation.expandsHorizontally)
    }

    @Test func repeatedNewChatTapsShareOneSessionCreation() async throws {
        let client = DeferredNewChatSessionCatalogClient()
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture]),
            profiles: [.defaultFixture]
        )
        let state = AppState()
        let catalog = SessionCatalogStore(client: client)
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { route in featureStore.prepare(route) }
        )

        let first = Task { try await coordinator.start() }
        await client.waitUntilCreateStarts()
        let repeatedTap = Task { try await coordinator.start() }
        await Task.yield()

        #expect(client.createCallCount == 1)
        client.finishCreation()
        let firstOutcome = try await first.value
        let repeatedOutcome = try await repeatedTap.value

        #expect(firstOutcome == .opened(sessionID: "session-shared", agentID: "default"))
        #expect(repeatedOutcome == firstOutcome)
        #expect(client.createCallCount == 1)
        #expect(catalog.session(id: "session-shared") != nil)
    }

    @Test func newChatNavigatesBeforeWorkspaceBindingFinishes() async throws {
        let workspaceClient = DeferredInitialWorkspaceCatalogClient()
        let workspaces = HermesWorkspaceStore(client: workspaceClient)
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture]),
            profiles: [.defaultFixture]
        )
        let state = AppState()
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            hermesWorkspaces: workspaces,
            prepare: { route in featureStore.prepare(route) }
        )

        let start = Task { try await coordinator.start() }
        await workspaceClient.waitUntilInitialLoadStarts()

        guard case .chat(let visibleSessionID)? = state.path.last else {
            Issue.record("New chat did not become visible while workspace binding was pending")
            workspaceClient.finishInitialLoad()
            _ = try await start.value
            return
        }
        #expect(catalog.session(id: visibleSessionID) != nil)

        workspaceClient.finishInitialLoad()
        let outcome = try await start.value
        #expect(outcome == .opened(sessionID: visibleSessionID, agentID: "default"))
        #expect(workspaces.workspaceID(forSessionID: visibleSessionID) == "loopdy")
    }

    @Test func workspaceBindingFailureAfterLocalNavigationDoesNotFailTheNewChat() async throws {
        let workspaces = HermesWorkspaceStore(client: FailingInitialWorkspaceCatalogClient())
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture]),
            profiles: [.defaultFixture]
        )
        let state = AppState()
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            hermesWorkspaces: workspaces,
            prepare: { route in featureStore.prepare(route) }
        )

        let outcome = try await coordinator.start()

        #expect(outcome == .opened(sessionID: "session-1", agentID: "default"))
        #expect(state.path == [.chat(conversationID: "session-1")])
        #expect(catalog.session(id: "session-1") != nil)
    }

    @Test func newChatUsesSelectedAgentAndPersistsPreviousDraft() async throws {
        let harness = try await NewChatHarness(selectedAgentID: "finance")
        let previous = try await harness.catalog.createDirect(agentID: "default")
        harness.catalog.updateDraft("Do not lose this", for: previous.id)
        harness.state.path = [.chat(conversationID: previous.id)]

        let outcome = try await harness.coordinator.start(explicitAgentID: nil)

        guard case .opened(let sessionID, let agentID) = outcome else {
            Issue.record("Expected a resolved session")
            return
        }
        #expect(agentID == "finance")
        #expect(harness.catalog.session(id: sessionID)?.agentIDs == ["finance"])
        #expect(harness.catalog.session(id: previous.id)?.draft == "Do not lose this")
        #expect(harness.state.path == [.chat(conversationID: sessionID)])
        if case .chat? = harness.featureStore.preparedModel(
            for: .chat(conversationID: sessionID)
        ) {
            // The route was prepared before the coordinator activated it.
        } else {
            Issue.record("Opened session was not prepared")
        }
    }

    @Test func cachedNewChatDoesNotStartASecondAgentDirectoryRefresh() async throws {
        let client = CountingAgentDirectoryClient()
        let agents = AgentDirectoryStore(client: client, profiles: [.defaultFixture])
        let state = AppState()
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { route in featureStore.prepare(route) }
        )

        let outcome = try await coordinator.start()
        #expect(outcome == .opened(sessionID: "session-1", agentID: "default"))
        for _ in 0..<8 { await Task.yield() }
        #expect(client.listCalls == 0)
    }

    @Test func newChatFallsBackToDefaultWithoutASelectedAgent() async throws {
        let harness = try await NewChatHarness(selectedAgentID: nil)

        let outcome = try await harness.coordinator.start(explicitAgentID: nil)

        #expect(outcome == .opened(sessionID: "session-1", agentID: "default"))
    }

    @Test func newChatPinsTheSelectedHermesWorkspaceToTheCreatedSession() async throws {
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture]),
            profiles: [.defaultFixture]
        )
        let state = AppState()
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let workspaces = HermesWorkspaceStore(client: FixtureHermesWorkspaceClient())
        await workspaces.load(agentID: "default")
        #expect(await workspaces.select(id: "loopdy", agentID: "default"))
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            hermesWorkspaces: workspaces,
            prepare: { route in featureStore.prepare(route) }
        )

        let outcome = try await coordinator.start()

        #expect(outcome == .opened(sessionID: "session-1", agentID: "default"))
        #expect(workspaces.workspaceID(forSessionID: "session-1") == "loopdy")
        #expect(catalog.session(id: "session-1")?.workspaceID == "loopdy")
        #expect(catalog.session(id: "session-1")?.workspaceName == "bighelp")
    }

    @Test func newChatCreatesLocalCanvasBeforeLoadingAndBindingProjectCatalog() async throws {
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture]),
            profiles: [.defaultFixture]
        )
        let state = AppState()
        let workspaces = HermesWorkspaceStore(client: FixtureHermesWorkspaceClient())
        let client = ProjectAwareSessionCatalogClient {
            workspaces.catalogAgentID == "default"
                && workspaces.catalog?.activeWorkspaceID == "loopdy"
        }
        let catalog = SessionCatalogStore(client: client)
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            hermesWorkspaces: workspaces,
            prepare: { route in featureStore.prepare(route) }
        )

        let outcome = try await coordinator.start()

        #expect(outcome == .opened(sessionID: "session-project-loaded", agentID: "default"))
        #expect(!client.catalogWasLoadedBeforeCreate)
        #expect(workspaces.workspaceID(forSessionID: "session-project-loaded") == "loopdy")
    }

    @Test func newChatWithoutResolvableAgentDoesNotCreateASession() async throws {
        let harness = try await NewChatHarness(
            selectedAgentID: nil,
            profiles: [.financeFixture]
        )

        let outcome = try await harness.coordinator.start(explicitAgentID: nil)

        #expect(outcome == .needsAgentSelection)
        #expect(harness.catalog.recentSummaries.isEmpty)
        #expect(harness.state.path.isEmpty)
    }

    @Test func explicitUnavailableAgentDoesNotFallBackToAnotherProfile() async throws {
        let harness = try await NewChatHarness(selectedAgentID: "default")

        let outcome = try await harness.coordinator.start(explicitAgentID: "unavailable")

        #expect(outcome == .needsAgentSelection)
        #expect(harness.catalog.recentSummaries.isEmpty)
        #expect(harness.state.path.isEmpty)
    }

    @Test func newChatRefreshesTheCanonicalRemoteDirectoryBeforeResolvingTheDefault() async throws {
        let remoteDefault = AgentProfile(
            id: "juno",
            name: "Juno",
            role: "Default agent",
            summary: "The live Hermes default agent.",
            instructions: "Help with everyday work.",
            avatarFileName: nil,
            isDefault: true
        )
        let client = CanonicalRemoteAgentDirectoryClient(profiles: [remoteDefault])
        let agents = AgentDirectoryStore(
            client: client,
            profiles: []
        )
        let state = AppState()
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { route in featureStore.prepare(route) }
        )

        let outcome = try await coordinator.start(explicitAgentID: nil)

        #expect(outcome == .opened(sessionID: "session-1", agentID: "juno"))
        #expect(client.requestCount == 1)
        #expect(agents.profiles == [remoteDefault])
    }

    @Test func newChatUsesCachedSelectedAgentWhenCanonicalDirectoryLoadFails() async throws {
        let client = FailingCanonicalRemoteAgentDirectoryClient()
        let agents = AgentDirectoryStore(
            client: client,
            profiles: [.defaultFixture, .financeFixture]
        )
        agents.select("finance")
        let state = AppState()
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { route in featureStore.prepare(route) }
        )

        let outcome = try await coordinator.start()

        #expect(outcome == .opened(sessionID: "session-1", agentID: "finance"))
        #expect(catalog.session(id: "session-1")?.agentIDs == ["finance"])
    }

    @Test func newChatFallsBackToSeededDefaultWhenCanonicalDirectoryLoadFails() async throws {
        let client = FailingCanonicalRemoteAgentDirectoryClient()
        let agents = AgentDirectoryStore(
            client: client,
            profiles: [.bighelpLinkDefault]
        )
        let state = AppState()
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { route in featureStore.prepare(route) }
        )

        let outcome = try await coordinator.start(explicitAgentID: nil)

        #expect(outcome == .opened(sessionID: "session-1", agentID: "default"))
        #expect(catalog.session(id: "session-1")?.agentIDs == ["default"])
    }
}

@MainActor
private final class DeferredInitialWorkspaceCatalogClient: HermesWorkspaceCatalogClient {
    private var initialLoadContinuation: CheckedContinuation<Void, Never>?
    private var initialLoadStartedContinuation: CheckedContinuation<Void, Never>?
    private var initialLoadStarted = false
    private var shouldDeferInitialLoad = true
    private var workspaceIDsBySession: [String: String] = [:]

    func load(agentID: String) async throws -> HermesWorkspaceCatalog {
        if shouldDeferInitialLoad {
            shouldDeferInitialLoad = false
            initialLoadStarted = true
            initialLoadStartedContinuation?.resume()
            initialLoadStartedContinuation = nil
            await withCheckedContinuation { continuation in
                initialLoadContinuation = continuation
            }
        }
        return catalog(sessionID: nil)
    }

    func load(agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        if sessionID == nil {
            return try await load(agentID: agentID)
        }
        return catalog(sessionID: sessionID)
    }

    func select(
        id: String,
        agentID: String,
        sessionID: String?
    ) async throws -> HermesWorkspaceCatalog {
        if let sessionID {
            workspaceIDsBySession[sessionID] = id
        }
        return catalog(sessionID: sessionID)
    }

    func create(
        name: String,
        folderPath: String,
        agentID: String
    ) async throws -> HermesWorkspaceCatalog {
        catalog(sessionID: nil)
    }

    func archive(id: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        catalog(sessionID: nil)
    }

    func folderSuggestions(
        parentPath: String,
        prefix: String,
        offset: Int,
        limit: Int,
        agentID: String
    ) async throws -> HermesWorkspaceFolderPage {
        HermesWorkspaceFolderPage(parentPath: parentPath, folders: [], nextOffset: nil)
    }

    func waitUntilInitialLoadStarts() async {
        guard !initialLoadStarted else { return }
        await withCheckedContinuation { continuation in
            initialLoadStartedContinuation = continuation
        }
    }

    func finishInitialLoad() {
        initialLoadContinuation?.resume()
        initialLoadContinuation = nil
    }

    private func catalog(sessionID: String?) -> HermesWorkspaceCatalog {
        HermesWorkspaceCatalog(
            activeWorkspaceID: "loopdy",
            sessionWorkspaceID: sessionID.flatMap { workspaceIDsBySession[$0] },
            workspaces: [
                HermesWorkspaceSummary(
                    id: "loopdy",
                    name: "bighelp",
                    description: "bighelp workspace",
                    folderCount: 1,
                    isActive: true
                ),
            ]
        )
    }
}

@MainActor
private final class FailingInitialWorkspaceCatalogClient: HermesWorkspaceCatalogClient {
    func load(agentID: String) async throws -> HermesWorkspaceCatalog {
        throw URLError(.networkConnectionLost)
    }

    func load(agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        throw URLError(.networkConnectionLost)
    }

    func select(id: String, agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        throw URLError(.networkConnectionLost)
    }

    func create(name: String, folderPath: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        throw URLError(.networkConnectionLost)
    }

    func archive(id: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        throw URLError(.networkConnectionLost)
    }

    func folderSuggestions(
        parentPath: String,
        prefix: String,
        offset: Int,
        limit: Int,
        agentID: String
    ) async throws -> HermesWorkspaceFolderPage {
        throw URLError(.networkConnectionLost)
    }
}

@MainActor
private final class DeferredNewChatSessionCatalogClient: SessionCatalogClient {
    private var continuation: CheckedContinuation<SessionRecord, Error>?
    private(set) var createCallCount = 0

    func list() async throws -> [SessionRecord] { [] }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        createCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilCreateStarts() async {
        while createCallCount == 0 { await Task.yield() }
    }

    func finishCreation() {
        continuation?.resume(returning: SessionRecord(
            id: "session-shared",
            kind: .direct,
            agentIDs: ["default"],
            title: "New chat"
        ))
        continuation = nil
    }

    func failCreation() {
        continuation?.resume(throwing: NewChatAllocationError.unavailable)
        continuation = nil
    }
}

private enum NewChatAllocationError: Error {
    case unavailable
}

@MainActor
private final class ProjectAwareSessionCatalogClient: SessionCatalogClient {
    private let isProjectCatalogLoaded: () -> Bool
    private(set) var catalogWasLoadedBeforeCreate = false

    init(isProjectCatalogLoaded: @escaping () -> Bool) {
        self.isProjectCatalogLoaded = isProjectCatalogLoaded
    }

    func list() async throws -> [SessionRecord] { [] }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        catalogWasLoadedBeforeCreate = isProjectCatalogLoaded()
        return SessionRecord(
            id: "session-project-loaded",
            kind: kind,
            agentIDs: agentIDs,
            title: "New chat"
        )
    }
}

@MainActor
private final class NewChatHarness {
    let state = AppState()
    let catalog: SessionCatalogStore
    let featureStore: ShellFeatureStore
    let coordinator: NewChatCoordinator

    init(
        selectedAgentID: String?,
        profiles: [AgentProfile] = [.defaultFixture, .financeFixture]
    ) async throws {
        let defaults = isolatedDefaults()
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: profiles),
            defaults: defaults
        )
        try await agents.load()
        if let selectedAgentID {
            agents.select(selectedAgentID)
        }

        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog)
        self.catalog = catalog
        self.featureStore = featureStore
        coordinator = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { route in featureStore.prepare(route) }
        )
    }
}

@MainActor
private final class CanonicalRemoteAgentDirectoryClient: AgentDirectoryClient {
    let profiles: [AgentProfile]
    private(set) var requestCount = 0

    init(profiles: [AgentProfile]) {
        self.profiles = profiles
    }

    func list() async throws -> [AgentProfile] {
        requestCount += 1
        return profiles
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        fatalError("Unused by this fixture")
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        fatalError("Unused by this fixture")
    }
}

@MainActor
private final class FailingCanonicalRemoteAgentDirectoryClient: AgentDirectoryClient {
    func list() async throws -> [AgentProfile] {
        throw CanonicalDirectoryLoadError.unavailable
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        fatalError("Unused by this fixture")
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        fatalError("Unused by this fixture")
    }
}

private enum CanonicalDirectoryLoadError: Error, Equatable {
    case unavailable
}

@MainActor
private final class CountingAgentDirectoryClient: AgentDirectoryClient {
    private(set) var listCalls = 0

    func list() async throws -> [AgentProfile] {
        listCalls += 1
        return [.defaultFixture]
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        throw CocoaError(.featureUnsupported)
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        throw CocoaError(.featureUnsupported)
    }
}
