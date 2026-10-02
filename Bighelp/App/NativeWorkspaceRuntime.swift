import Foundation
import Observation

/// Owns one native refresh independently of the SwiftUI task that requested it.
/// The owner can explicitly cancel this work when its host is suspended or
/// retired; view navigation cancellation does not cancel the refresh itself.
@MainActor
final class NativeWorkspaceRefreshFlight {
    private var current: (id: UUID, task: Task<Void, Never>)?

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        if let current {
            await current.task.value
            return
        }

        let id = UUID()
        let task = Task { @MainActor in
            await operation()
        }
        current = (id: id, task: task)
        await task.value
        if current?.id == id { current = nil }
    }

    /// An invalidation that arrives during an older request must run once after
    /// that request, not join an outcome whose snapshot may predate the event.
    func runAfterCurrent(_ operation: @escaping @MainActor () async -> Void) async {
        while let previous = current {
            guard !Task.isCancelled else { return }
            await previous.task.value
            if current?.id == previous.id { current = nil }
        }
        guard !Task.isCancelled else { return }
        await run(operation)
    }

    func cancel() {
        let task = current?.task
        // Clear the admission before cancelling so a new foreground request
        // can start immediately. The old task's completion guard cannot clear
        // a replacement flight because its token is no longer current.
        current = nil
        task?.cancel()
    }
}

@MainActor
private final class NativeWorkspaceRefreshErrorBox {
    var error: (any Error)?
}

@MainActor
@Observable
final class NativeWorkspaceRuntime {
    let authority: WorkspaceAuthority
    let appState = AppState()
    let agents: AgentDirectoryStore
    let defaults: any AgentRuntimeDefaultsClient
    let sessions: SessionCatalogStore
    let scheduledTasks: ScheduledTasksStore
    @ObservationIgnored private var widgetPublisher: BighelpWidgetSnapshotPublisher?
    let rooms: BotModeRoomStore
    let projects: HermesWorkspaceStore
    let projectGitClient: any ProjectGitClient
    let personalities: PersonalityStore
    let skillsAndTools: SkillsAndToolsStore
    let unavailable = NativeWorkspaceUnavailableClient()
    let features: ShellFeatureStore
    let newChat: NewChatCoordinator
    let bridge: NativeWorkspaceSessionBridge
    private(set) var isRefreshing = false
    private(set) var isReady = false
    private(set) var isSuspended = false
    private var unrecoveredActiveChatID: String?
    private(set) var errorMessage: String?
    private(set) var optionalFeatureMessage: String?
    @ObservationIgnored private let connections: WorkspaceConnectionStore
    @ObservationIgnored private let stockGitBox: WorkspaceOwnedClientBox<any ProjectGitClient>
    @ObservationIgnored private let agentRepository: DemoRepository<[AgentProfile]>
    @ObservationIgnored private let resetClients: [@MainActor () -> Void]
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private let refreshFlight = NativeWorkspaceRefreshFlight()
    @ObservationIgnored private let activeSessionsFlight = NativeWorkspaceRefreshFlight()
    @ObservationIgnored private let transportRecoveryFlight = NativeWorkspaceRefreshFlight()
    @ObservationIgnored private let scheduledTasksFlight = NativeWorkspaceRefreshFlight()
    @ObservationIgnored private var invalidations: NativeWorkspaceInvalidationCoordinator?
    @ObservationIgnored private let resumeProgress: NativeSessionResumeProgressCoordinator
    @ObservationIgnored private weak var observedPromptStore: DirectHermesPromptStore?
    @ObservationIgnored private let promptObserverID = UUID()

    init(connections: WorkspaceConnectionStore, authority: WorkspaceAuthority,
         settings: SettingsStore, userIdentity: UserIdentityStore, directory: URL) throws {
        guard authority.kind == .direct else { throw WorkspaceClientError.ownerChanged }
        self.connections = connections
        self.authority = authority
        let scope = authority.cacheScopeID
        let root = directory.appending(path: scope, directoryHint: .isDirectory)
        guard let preferences = UserDefaults(suiteName: "app.loopdy.native-workspace." + scope) else {
            throw DirectHermesError.secureStorageUnavailable
        }
        let bridge = try NativeWorkspaceSessionBridge(connections: connections, authority: authority, directory: root)
        self.bridge = bridge
        let resumeProgress = NativeSessionResumeProgressCoordinator()
        self.resumeProgress = resumeProgress
        let agentReadCache = DirectHermesAgentReadCache()
        let directoryBox = WorkspaceOwnedClientBox<any AgentDirectoryClient>(
            connections: connections, authority: authority
        ) { workspace, owner, current in
            DirectHermesAgentDirectoryClient(workspace: workspace, owner: owner, currentOwner: current, readCache: agentReadCache)
        }
        agentRepository = DemoRepository(directory: root, name: "native-agents", seed: [])
        let savedAgents = try agentRepository.loadExistingPreservingSource() ?? []
        let agents = AgentDirectoryStore(
            client: WorkspaceAgentDirectoryProxy(box: directoryBox), defaults: preferences, profiles: savedAgents,
            avatarDirectoryProvider: { [agentRepository] in try? agentRepository.scopedAvatarsDirectory() },
            currentHostID: { scope }
        )
        self.agents = agents
        let defaultsBox = WorkspaceOwnedClientBox<any AgentRuntimeDefaultsClient>(
            connections: connections, authority: authority
        ) { workspace, owner, current in
            DirectHermesAgentRuntimeDefaultsClient(workspace: workspace, owner: owner, currentOwner: current)
        }
        let defaults = WorkspaceAgentDefaultsProxy(box: defaultsBox)
        self.defaults = defaults
        let modelCache = DirectHermesModelCatalogCache()
        let controlsBox = WorkspaceOwnedClientBox<DirectHermesSessionControlClient>(
            connections: connections, authority: authority
        ) { workspace, owner, current in
            DirectHermesSessionControlClient(workspace: workspace, owner: owner, currentOwner: current,
                                             resolveSession: { [weak bridge] in bridge?.currentCoordinate(for: $0) }, modelCache: modelCache)
        }
        let sessionControls = WorkspaceSessionControlProxy(box: controlsBox)
        let projectBox = WorkspaceOwnedClientBox<any HermesWorkspaceCatalogClient>(
            connections: connections, authority: authority
        ) { workspace, owner, current in
            DirectHermesProjectClient(workspace: workspace, owner: owner, currentOwner: current,
                                      resolveSession: { [weak bridge] in bridge?.currentCoordinate(for: $0) })
        }
        let projects = HermesWorkspaceStore(client: WorkspaceProjectsProxy(box: projectBox))
        self.projects = projects
        let gitBox = WorkspaceOwnedClientBox<any ProjectGitClient>(
            connections: connections, authority: authority, contextSensitive: true
        ) { [weak connections, weak bridge, weak projects] _, owner, current in
            guard let connections, connections.owner == owner,
                  let selected = connections.hosts.selectedWorkspace,
                  selected.connectionGeneration == owner.connectionGeneration,
                  let direct = selected.nativeClient,
                  let hostName = connections.selectedDirectHost?.name else {
                throw WorkspaceClientError.ownerChanged
            }
            return NativeStockGitCoordinator.makeProjectGitClient(
                hostName: hostName, rpc: direct, http: direct, owner: owner, currentOwner: current,
                resolveVisibleSession: { [weak bridge, weak projects] visibleID in
                    guard let coordinate = bridge?.currentCoordinate(for: visibleID), coordinate.owner == owner,
                          let projectID = projects?.workspaceID(forSessionID: visibleID) else { return nil }
                    return NativeStockGitVisibleSession(coordinate: coordinate, projectID: projectID)
                })
        }
        stockGitBox = gitBox
        projectGitClient = WorkspaceProjectGitProxy(box: gitBox)
        bridge.selectedFolderPath = { [weak connections, weak bridge] profile in
            guard let connections, let owner = connections.owner, owner.authority == authority,
                  let workspace = connections.workspace else { throw WorkspaceClientError.ownerChanged }
            let client = DirectHermesProjectClient(
                workspace: workspace, owner: owner, currentOwner: { [weak connections] in connections?.owner },
                resolveSession: { [weak bridge] in bridge?.currentCoordinate(for: $0) }
            )
            return try await client.selectedFolderPath(agentID: profile)
        }
        let scheduleBox = WorkspaceOwnedClientBox<any ScheduledTasksClient>(
            connections: connections, authority: authority, contextSensitive: true
        ) { [weak connections] workspace, owner, current in
            DirectHermesScheduledTasksClient(workspace: workspace, owner: owner, currentOwner: current,
                                             servingProfileID: workspace.nativeContext?.servingProfileID,
                                             http: connections?.hosts.selectedWorkspace?.nativeClient)
        }
        let scheduledTasks = ScheduledTasksStore(client: WorkspaceScheduledTasksProxy(box: scheduleBox), initialAgentID: nil)
        self.scheduledTasks = scheduledTasks
        let roomRepository = DemoRepository<[BotModeRoom]>(
            directory: root, name: BotModeRoomCacheSchema.repositoryName, seed: [],
            migrations: BotModeRoomCacheSchema.migrations, currentSchemaVersion: BotModeRoomCacheSchema.currentVersion
        )
        let rooms = BotModeRoomStore(client: unavailable, repository: roomRepository, executionEnabled: false)
        self.rooms = rooms
        let repository = SessionContentRepository(directory: root, name: "native-sessions-v2", currentSchemaVersion: 2)
        let sessions = SessionCatalogStore(
            client: bridge, repository: repository, forkClient: unavailable,
            nativeFork: { [weak bridge] record, itemID in
                guard let bridge else { throw WorkspaceClientError.ownerChanged }
                return try await bridge.fork(record: record, throughItemID: itemID)
            },
            defaults: preferences, currentHostID: { scope }, defaultActivityVisibility: { settings.chatActivityVisibility }
        )
        self.sessions = sessions
        bridge.onSessionContextChange = { [weak connections, weak sessions] owner, snapshot in
            guard connections?.owner == owner, owner.authority == authority else { return }
            sessions?.reconcileSessionContext(snapshot)
        }
        bridge.onSessionLivenessChange = { [weak connections, weak sessions] owner, id, isActive in
            guard connections?.owner == owner, owner.authority == authority else { return }
            sessions?.reconcileNativeSessionLiveness(id: id, isActive: isActive)
        }
        personalities = PersonalityStore(client: WorkspacePersonalityProxy { [weak connections, weak agents] in
            guard let connections, let owner = connections.owner, owner.authority == authority,
                  let workspace = connections.workspace,
                  let profile = agents?.resolvedAgent(explicitID: nil)?.id else { throw WorkspaceClientError.transportUnavailable }
            return DirectHermesPersonalityClient(workspace: workspace, owner: owner, profileID: profile,
                currentOwner: { [weak connections, weak agents] in
                    guard agents?.resolvedAgent(explicitID: nil)?.id == profile else { return nil }
                    return connections?.owner
                })
        })
        let skillsBox = WorkspaceOwnedClientBox<any HermesSkillsAndToolsCatalogClient>(
            connections: connections, authority: authority
        ) { workspace, owner, current in
            DirectHermesSkillsAndToolsClient(workspace: workspace, owner: owner, currentOwner: current)
        }
        skillsAndTools = SkillsAndToolsStore(client: WorkspaceSkillsAndToolsProxy(box: skillsBox))
        let slashCommandsBox = WorkspaceOwnedClientBox<any SlashCommandCatalogClient>(
            connections: connections, authority: authority
        ) { workspace, owner, current in
            DirectHermesSlashCommandCatalogClient(workspace: workspace, owner: owner, currentOwner: current)
        }
        let currentPromptStore: @MainActor () -> DirectHermesPromptStore? = { [weak connections] in
            guard let connections,
                  let owner = connections.owner,
                  owner.authority == authority,
                  let workspace = connections.hosts.selectedWorkspace,
                  workspace.connectionGeneration == owner.connectionGeneration else { return nil }
            return workspace.promptStore
        }
        let dashboard = DirectHermesDashboardDataSource(
            authority: authority, sessions: sessions, agents: agents,
            approvals: { [weak rooms] in
                var values: [DirectHermesDashboardApproval] = []
                if let rooms {
                    values = rooms.rooms.flatMap { room in
                        rooms.pendingApprovals(roomID: room.id).map {
                            .hostedRoom($0, roomName: room.title)
                        }
                    }
                }
                values += currentPromptStore()?.dashboardApprovals() ?? []
                return values
            },
            clarifications: {
                currentPromptStore()?.dashboardClarifications() ?? []
            },
            approvalResponder: { [weak rooms, weak connections, weak bridge] approval, decision in
                guard let connections, let owner = connections.owner,
                      owner.authority == authority else {
                    throw WorkspaceClientError.ownerChanged
                }
                if let store = currentPromptStore(), store.containsApproval(presentationID: approval.id) {
                    guard let bridge else { throw WorkspaceClientError.ownerChanged }
                    try await bridge.respondToPromptApproval(presentationID: approval.id, decision: decision)
                    guard connections.owner == owner else { throw WorkspaceClientError.ownerChanged }
                    return
                }
                guard let rooms, decision == .once || decision == .deny,
                      let pending = rooms.rooms.flatMap({ rooms.pendingApprovals(roomID: $0.id) })
                        .first(where: { $0.id == approval.id }) else {
                    throw DirectHermesWorkspaceError.expiredPrompt
                }
                _ = try await rooms.resolveNativeApproval(roomID: pending.roomID,
                    approval: pending, choice: decision == .once ? .once : .deny)
            },
            clarificationResponder: { [weak connections, weak bridge] clarification, response in
                guard let connections, let owner = connections.owner,
                      owner.authority == authority,
                      currentPromptStore() != nil, let bridge else {
                    throw WorkspaceClientError.ownerChanged
                }
                try await bridge.respondToPromptClarification(presentationID: clarification.id, answer: response)
                guard connections.owner == owner else { throw WorkspaceClientError.ownerChanged }
            },
            structuredClarificationResponder: { [weak connections, weak bridge] clarification, response in
                guard let connections, let owner = connections.owner,
                      owner.authority == authority,
                      currentPromptStore() != nil, let bridge else {
                    throw WorkspaceClientError.ownerChanged
                }
                try await bridge.respondToPromptClarification(presentationID: clarification.id, response: response)
                guard connections.owner == owner else { throw WorkspaceClientError.ownerChanged }
            },
            defaults: preferences,
            isCurrentOwner: { [weak connections] in connections?.owner?.authority == authority }
        )
        let generatedMediaBox = WorkspaceOwnedClientBox<DirectHermesGeneratedMediaClient>(
            connections: connections, authority: authority
        ) { workspace, owner, current in
            DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: current,
                                             cache: .shared, remoteFetch: LinkPreviewLoader.live.fetch)
        }
        let mediaResolver = WorkspaceGeneratedMediaProxy(box: generatedMediaBox)
        bridge.attachmentResolver = mediaResolver
        bridge.speakerNote = DirectHermesChatSpeakerNote(
            currentWorkspace: { [weak connections] in connections?.workspace },
            name: { [weak userIdentity] in userIdentity?.identity.name ?? "" }
        )
        let features = ShellFeatureStore(
            timing: .immediate, catalog: sessions, agents: agents, agentRuntimeDefaults: defaults,
            allowsNewChatAgentDefaults: false,
            botModeRooms: rooms, userIdentity: userIdentity, scheduledTasks: scheduledTasks,
            dashboardSource: dashboard, approvalRequestLoader: dashboard, approvalClient: dashboard,
            conversationClient: { [weak bridge] record, _ in
                bridge?.conversationClient(for: record) ?? NativeWorkspaceUnavailableClient()
            },
            conversationPrepared: { [weak connections, weak bridge] model, client in
                bridge?.bind(model, client: client)
                guard let native = client as? DirectHermesConversationClient,
                      let coordinate = bridge?.currentCoordinate(for: model.conversationID),
                      let source = connections?.nativeInvalidationSource(authority: authority) else { return }
                resumeProgress.bind(
                    model: model, client: native, coordinate: coordinate, source: source
                )
            },
            navigationWorkspaceOwner: { [weak connections] in
                guard let owner = connections?.owner, owner.authority == authority else { return nil }
                return owner
            },
            nativeWarmSessionIsCurrent: { [weak bridge] record, model in
                bridge?.isWarmSession(record, model: model) == true
            },
            voiceClient: { [weak connections, weak bridge] record, _ in
                guard let connections, let owner = connections.owner, owner.authority == authority,
                      let workspace = connections.workspace,
                      let conversation = bridge?.conversationClient(for: record) as? DirectHermesConversationClient,
                      let coordinate = bridge?.currentCoordinate(for: record.id), coordinate.owner == owner else {
                    return NativeWorkspaceUnavailableClient()
                }
                let output = DirectHermesVoiceSpeechOutput(workspace: workspace, owner: owner,
                    profileID: coordinate.profileID, currentOwner: { [weak connections] in connections?.owner })
                let transcriber = connections.hosts.selectedWorkspace?.nativeClient?.makeVoiceTranscriber(
                    profileID: coordinate.profileID, owner: owner,
                    currentOwner: { [weak connections] in connections?.owner })
                return DirectHermesVoiceSessionClient(conversation: conversation, output: output,
                                                      speechRate: { settings.voiceSpeed.hermesTTSSpeed },
                                                      transcriber: transcriber)
            },
            sessionControlMessaging: sessionControls,
            slashCommandCatalogClient: WorkspaceSlashCommandCatalogProxy(box: slashCommandsBox),
            generatedMediaResolver: mediaResolver,
            recentModelHistory: RecentModelHistoryStore(defaults: preferences, scopeID: { scope }),
            midSessionBehavior: { settings.midSessionChatBehavior }
        )
        self.features = features
        features.teamCallServices = DirectHermesTeamCallServices(connections: connections, authority: authority)
        bridge.onSessionTodosChange = { [weak connections, weak features] owner, snapshot in
            guard connections?.owner == owner, owner.authority == authority else { return }
            features?.acceptSessionTodos(snapshot)
        }
        bridge.onNativeSubagentRosterChange = { [weak connections, weak features] owner, id, client, items in
            guard connections?.owner == owner, owner.authority == authority else { return }
            features?.acceptNativeSubagentRoster(items, sessionID: id, client: client)
        }
        bridge.onSessionRetired = { [weak features] id in features?.retireNavigationSession(id: id) }
        // Sessions is the initial root tab. Prepare its stable model before
        // mounting the shell; ShellFeatureStore is not an observable store.
        _ = features.prepareSessions()
        features.configureLiveVoiceFactory { [weak connections, weak bridge] session, agent, chat in
            guard let connections, let owner = connections.owner, owner.authority == authority,
                  let workspace = connections.workspace,
                  workspace.nativeContext?.features.contains("native-voice-v1") == true,
                  let coordinate = bridge?.currentCoordinate(for: session.id), coordinate.owner == owner,
                  let stored = coordinate.storedSessionID, session.kind == .direct else { return nil }
            let voiceOwner = LiveVoiceOwner(hostID: authority.cacheScopeID,
                authorizationID: owner.authenticationGeneration.uuidString + ":" + owner.connectionGeneration.uuidString,
                agentID: coordinate.profileID, sessionID: stored)
            let voice = NativeLiveVoiceSession(owner: voiceOwner, operation: { operation, payload in
                try await workspace.perform(operation, payload: payload, owner: owner)
            }, isCurrent: { [weak connections] in connections?.owner == owner },
            closeCleanupFactory: { [weak workspace] voiceID in
                workspace?.makeNativeVoiceCloseCleanup(
                    agentID: voiceOwner.agentID, sessionID: voiceOwner.sessionID, voiceID: voiceID
                )
            }, submit: { [weak chat] text in
                guard let chat else { throw LiveVoiceControlError.wrongOwner }
                let response = try await chat.sendNativeVoiceMessage(text)
                return response.items.compactMap { item -> String? in
                    guard item.role == .assistant, case .message(let text) = item.content else { return nil }
                    return text
                }.joined(separator: "\n\n")
            })
            return voice.makeModel(agentName: agent?.name ?? "Hermes")
        }
        // Native creation already captures the verified selected cwd before
        // mutation; do not perform a second post-create workspace move.
        newChat = NewChatCoordinator(appState: appState, agents: agents, catalog: sessions,
                                    prepare: { features.prepareNewChat($0) })
        resetClients = [modelCache.clear, agentReadCache.clear, directoryBox.reset, defaultsBox.reset, controlsBox.reset, projectBox.reset, gitBox.reset, scheduleBox.reset, skillsBox.reset]
        invalidations = NativeWorkspaceInvalidationCoordinator(
            currentSource: { [weak connections] in
                connections?.nativeInvalidationSource(authority: authority)
            },
            refreshSessions: { [weak self] source in
                await self?.refreshActiveSessionsAfterInvalidation(expectedOwner: source.owner)
            },
            refreshScheduledTasks: { [weak self] source in
                await self?.refreshScheduledTasksAfterInvalidation(expectedOwner: source.owner)
            },
            publish: { [weak connections] source, notice in
                connections?.publishInvalidation(notice, source: source)
                guard connections?.nativeInvalidationSource(
                    authority: source.owner.authority
                ) == source else { return }
                if case .resumeProgress(let progress) = notice {
                    resumeProgress.receive(progress, source: source)
                }
            }
        )
        features.configureCanonicalSessionReentry { [weak self] record, model in
            guard let self else { throw WorkspaceClientError.ownerChanged }
            try await self.reenterCanonicalSession(record: record, model: model)
        }
        features.configureNativeWarmSessionRefresh { [weak self] record, model in
            guard let self else { throw WorkspaceClientError.ownerChanged }
            try await self.refreshWarmSessionMetadata(record: record, model: model)
        }
        if let promptStore = currentPromptStore() {
            observedPromptStore = promptStore
            promptStore.addObserver(id: promptObserverID) { [weak features, weak connections, weak promptStore, weak agents] in
                guard connections?.owner?.authority == authority else { return }
                if let promptStore {
                    BighelpPromptAlerts.shared.receive(promptStore.waitingPrompts()) { profile in
                        agents?.profiles.first { $0.id == profile }?.name
                    }
                }
                Task { @MainActor [weak features] in
                    await features?.dashboardModel.refreshAfterExternalChange()
                }
            }
        }
        bridge.onUnknownRuntimeEvent = { [weak self] owner in
            guard let self, !self.retired, self.connections.owner == owner,
                  owner.authority == self.authority else { return }
            self.scheduleActiveSessionsRefresh(expectedOwner: owner)
        }
        widgetPublisher = BighelpWidgetSnapshotPublisher(sessions: sessions, scheduledTasks: scheduledTasks, agents: agents)
    }

    /// Features the bighelp plugin serves (from its `/native/context`), not Hermes itself.
    static let pluginCapabilities: Set<WorkspaceCapability> = [
        .liveVoice, .wikiRead, .wikiEdit, .wikiDisconnect, .cardTemplates, .cards, .forms, .cloudNotifications,
        .phoneTools, .projectChangesRead, .agentBoard, .agentBoardFeedback,
    ]

    func refresh() async {
        await refreshFlight.run { [weak self] in
            await self?.performRefresh()
        }
        await retryUnrecoveredActiveChat()
    }

    /// Coming back must leave the open chat current. When the bulk recovery
    /// could not refresh it, try once more through Force Refresh's durable
    /// reattach path before asking the person to reopen it.
    private func retryUnrecoveredActiveChat() async {
        guard let id = unrecoveredActiveChatID else { return }
        unrecoveredActiveChatID = nil
        guard !retired, appState.activeConversationID == id else { return }
        do {
            try await features.forceRefreshSession(id: id)
        } catch is CancellationError {
        } catch {
            guard !retired, appState.activeConversationID == id else { return }
            errorMessage = "This chat could not be refreshed from Hermes. Reopen it to try again."
        }
    }

    func stockGitPresentation(profileID: String) throws -> NativeStockGitProjectPresentation {
        guard let coordinator = try stockGitBox.value() as? NativeStockGitCoordinator else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        return try coordinator.projectPresentation(profileID: profileID)
    }

    /// Refreshes the composite saved + process-local active inventory without
    /// repeating health, agents, projects, or other host bootstrap work.
    func refreshActiveSessions() async {
        guard let owner = connections.owner, owner.authority == authority else { return }
        await refreshActiveSessions(expectedOwner: owner)
    }

    private func reenterCanonicalSession(
        record: SessionRecord,
        model: ChatModel
    ) async throws {
        guard isReady, !retired,
              let owner = connections.owner, owner.authority == authority,
              sessions.session(id: record.id).map({ current in
                current.id == record.id && current.kind == record.kind
                    && current.agentIDs == record.agentIDs
                    && current.remoteStoredID == record.remoteStoredID
                    && current.remoteSource == record.remoteSource
              }) == true,
              bridge.retainsCanonicalSession(record, model: model) else {
            throw WorkspaceClientError.ownerChanged
        }
        let refreshed = try await bridge.reenterCanonicalSession(record, model: model)
        try require(owner)
        _ = try features.installSessionStateSnapshot(
            SessionHydrationPage(record: refreshed, nextOffset: nil),
            source: record
        )
        try require(owner)
        guard bridge.isWarmSession(
            sessions.session(id: record.id) ?? refreshed,
            model: model
        ) else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    private func refreshWarmSessionMetadata(
        record: SessionRecord,
        model: ChatModel
    ) async throws {
        guard isReady, !retired,
              let owner = connections.owner, owner.authority == authority,
              bridge.canRecoverRetainedSession(record, model: model) else {
            throw WorkspaceClientError.ownerChanged
        }
        // A warm read is not permission to revoke a healthy retained socket.
        try await reenterCanonicalSession(record: record, model: model)
        try require(owner)

        guard !isRefreshing, connections.owner == owner,
              bridge.isWarmSession(record, model: model) else { return }
        do {
            try await agents.load()
            try require(owner)
            try agentRepository.save(agents.profiles)
        } catch is CancellationError {
            throw CancellationError()
        } catch WorkspaceClientError.ownerChanged {
            throw WorkspaceClientError.ownerChanged
        } catch {
            // Keep the last usable directory; session recovery already applied.
        }
    }

    private func refreshActiveSessions(expectedOwner: WorkspaceOwner) async {
        await activeSessionsFlight.run { [weak self] in
            await self?.performActiveSessionsRefresh(expectedOwner: expectedOwner)
        }
    }

    private func refreshActiveSessionsAfterInvalidation(expectedOwner: WorkspaceOwner) async {
        await activeSessionsFlight.runAfterCurrent { [weak self] in
            await self?.performActiveSessionsRefresh(expectedOwner: expectedOwner)
        }
    }

    private func performActiveSessionsRefresh(expectedOwner: WorkspaceOwner) async {
        guard isReady, !retired,
              let owner = connections.owner,
              owner == expectedOwner,
              owner.authority == authority else { return }
        do {
            try await sessions.load(requireAuthoritativeRefresh: true)
            try require(owner)
        } catch is CancellationError {
        } catch {
            // SessionCatalogStore retains usable saved state and the prior
            // confirmed live overlay on an incomplete read.
        }
    }

    private func refreshSessionsForBootstrap(owner: WorkspaceOwner, request: UUID) async throws {
        let result = NativeWorkspaceRefreshErrorBox()
        await activeSessionsFlight.runAfterCurrent { [self] in
            do {
                try require(owner, request: request)
                try await sessions.load(requireAuthoritativeRefresh: true)
                try require(owner, request: request)
            } catch {
                result.error = error
            }
        }
        try require(owner, request: request)
        if let error = result.error { throw error }
    }

    private func scheduleActiveSessionsRefresh(expectedOwner: WorkspaceOwner) {
        Task { @MainActor [weak self] in
            await self?.refreshActiveSessions(expectedOwner: expectedOwner)
        }
    }

    private func refreshScheduledTasks(expectedOwner: WorkspaceOwner) async {
        await scheduledTasksFlight.run { [weak self] in
            await self?.performScheduledTasksRefresh(expectedOwner: expectedOwner)
        }
    }

    private func refreshScheduledTasksAfterInvalidation(expectedOwner: WorkspaceOwner) async {
        await scheduledTasksFlight.runAfterCurrent { [weak self] in
            await self?.performScheduledTasksRefresh(expectedOwner: expectedOwner)
        }
    }

    private func performScheduledTasksRefresh(expectedOwner: WorkspaceOwner) async {
        guard !retired,
              connections.owner == expectedOwner,
              expectedOwner.authority == authority else { return }
        await scheduledTasks.load()
        guard connections.owner == expectedOwner, !retired else { return }
    }

    private func performRefresh() async {
        guard !retired, let owner = connections.owner, owner.authority == authority,
              let workspace = connections.workspace else { suspend(); return }
        let request = UUID()
        refreshID = request
        isRefreshing = true
        errorMessage = nil
        rooms.configureNativeClient(HermesHostedRoomClient(workspace: workspace, owner: owner), preservingCatalog: isReady)
        defer { if refreshID == request { isRefreshing = false } }
        do {
            let health = try await workspace.perform(.hostHealth, payload: [:], owner: owner)
            try DirectHermesReleaseContract.validateHealth(health)
            try require(owner, request: request)
            guard let directStore = connections.hosts.selectedWorkspace else {
                throw WorkspaceClientError.ownerChanged
            }
            let manifest = try await directStore.discoverCapabilityManifest(expectedOwner: owner.connectionGeneration)
            try require(owner, request: request)
            var supported = manifest.supportedOperations
            // Hermes' own list says nothing about the plugin. Until the plugin's list is read,
            // its features are unknown rather than missing, so no screen asks for an update
            // while a reconnect is still under way.
            var pluginFeaturesKnown = false
            func publishCapabilities() throws {
                try require(owner, request: request)
                var availability = manifest.operationAvailability
                for capability in supported { availability[capability] = .available }
                if !pluginFeaturesKnown {
                    for capability in Self.pluginCapabilities where availability[capability] != .available {
                        availability[capability] = .unknown
                    }
                }
                try connections.installCapabilities(WorkspaceCapabilities(owner: owner, values: availability))
            }
            try publishCapabilities()
            // Reattach the visible conversation before optional workspace reads.
            // Failures remain isolated; a deleted chat cannot disable features.
            let failedSessions = try await NativeWorkspaceSessionRecovery.recover(
                bridge.retainedSessionIDs, prioritizing: appState.activeConversationID,
                requireCurrent: { try self.require(owner, request: request) }
            ) { id in
                guard self.sessions.session(id: id) != nil else { return }
                let refreshing = self.features.preparedChatModel(id: id)
                refreshing?.beginHostRefresh()
                defer { refreshing?.endHostRefresh() }
                let source = try self.sessions.restoreSessionContent(id: id)
                let recovered = try await self.sessions.refreshKnownSession(id: id)
                try self.require(owner, request: request)
                _ = try self.features.installSessionStateSnapshot(
                    SessionHydrationPage(record: recovered, nextOffset: nil), source: source
                )
            }
            if let active = appState.activeConversationID, failedSessions.contains(active) {
                unrecoveredActiveChatID = active
            }
            do {
                _ = try await workspace.perform(.nativeContext, payload: [:], owner: owner)
                optionalFeatureMessage = nil
            } catch {
                try require(owner, request: request)
                optionalFeatureMessage = "Optional host integrations are unavailable. Core workspace access does not require them."
            }
            if let context = workspace.nativeContext {
                if context.features.contains("native-voice-v1") { supported.insert(.liveVoice) }
                if context.features.contains("native-wiki-v1") { supported.formUnion([.wikiRead, .wikiEdit]) }
                if context.features.contains("native-wiki-disconnect-v1") { supported.insert(.wikiDisconnect) }
                if context.features.contains("native-card-templates-v1") { supported.insert(.cardTemplates) }
                // Rich interactive cards (generative UI, including forms) and the
                // plugin notification channel are core plugin capabilities, not
                // versioned feature flags: a fetched native context means the
                // bighelp plugin is installed and serving them.
                supported.formUnion([.cards, .forms, .cloudNotifications])
                if context.features.contains("native-device-tools-v1") { supported.insert(.phoneTools) }
                if context.features.contains("native-project-git-read-v1") { supported.insert(.projectChangesRead) }
                if context.features.contains("native-agent-board-v1") { supported.insert(.agentBoard) }
                if context.features.contains("native-agent-board-feedback-v1") { supported.insert(.agentBoardFeedback) }
            }
            pluginFeaturesKnown = true
            try publishCapabilities()
            try await agents.load()
            try require(owner, request: request)
            try agentRepository.save(agents.profiles)
            supported.formUnion(DirectHermesReleaseContract.profileOperations)
            try publishCapabilities()
            await refreshScheduledTasks(expectedOwner: owner)
            try require(owner, request: request)
            if scheduledTasks.loadState == .loaded { supported.formUnion([.schedulesEdit, .schedulesRun]) }
            if let profile = agents.resolvedAgent(explicitID: nil) {
                let projectClient = DirectHermesProjectClient(
                    workspace: workspace, owner: owner, currentOwner: { [weak connections] in connections?.owner },
                    resolveSession: { [weak bridge] in bridge?.currentCoordinate(for: $0) }
                )
                do {
                    _ = try await projectClient.load(agentID: profile.id)
                    try require(owner, request: request)
                    supported.formUnion([.projectsEdit, .sessionWorkspaceEdit])
                } catch {
                    try require(owner, request: request)
                    optionalFeatureMessage = "Project actions could not be verified. Refresh this host before changing projects."
                }
            }
            await rooms.refreshNativeRoomCatalog()
            try require(owner, request: request)
            if rooms.nativeExecutionAvailable {
                supported.formUnion([.groupsRead, .groupsCreate, .groupsSend, .groupsRename, .groupsStop,
                                     .groupsRetry, .groupsApprove, .groupsDisband])
            }
            try publishCapabilities()
            connections.cloneClient = DirectHermesAgentProfileCloneClient(
                workspace: workspace, owner: owner, currentOwner: { [weak connections] in connections?.owner }
            )
            connections.openCanonicalSession = { [weak self] profile, expectedOwner in
                guard let self else { throw WorkspaceClientError.ownerChanged }
                try self.require(expectedOwner)
                let record = try await self.bridge.canonicalChat(profileID: profile)
                try self.require(expectedOwner)
                _ = try self.sessions.installWorkspaceRecord(record, ownerIsCurrent: { [weak self] in
                    self?.connections.owner == expectedOwner && self?.retired == false
                })
                return record.id
            }
            isReady = true
            try await refreshSessionsForBootstrap(owner: owner, request: request)
            try require(owner, request: request)
            isSuspended = false

        } catch {
            guard !retired, refreshID == request else { return }
            errorMessage = error is WorkspaceClientError
                ? error.localizedDescription : "The native workspace could not be loaded. No other host or transport was used."
        }
    }

    func refreshLocalCache() async -> Bool {
        guard !retired, connections.owner?.authority == authority else { return false }
        // Keep drafts and the currently visible transcript while replacing cached reads.
        resetClients.forEach { $0() }
        await refresh()
        return errorMessage == nil && isReady
    }

    func receive(_ event: DirectHermesEvent) {
        if NativeWorkspaceInvalidationDecoder.handles(event.type) {
            guard let source = connections.nativeInvalidationSource(authority: authority) else { return }
            invalidations?.receive(event, source: source)
            return
        }
        bridge.receive(event)
        if event.type == "gateway.ready" || event.type == "session.reclaimed",
           let owner = connections.owner,
           owner.authority == authority {
            Task { @MainActor [weak self] in
                await self?.recoverRetainedSessionsAfterTransportReconnect(
                    expectedOwner: owner
                )
            }
        }
    }

    private func recoverRetainedSessionsAfterTransportReconnect(
        expectedOwner: WorkspaceOwner
    ) async {
        await transportRecoveryFlight.runAfterCurrent { [weak self] in
            guard let self, self.isReady, !self.retired,
                  self.connections.owner == expectedOwner else { return }
            do {
                let failed = try await self.bridge.recoverRetainedSessionsAfterTransportReconnect(
                    expectedOwner: expectedOwner,
                    prioritizing: self.appState.activeConversationID
                )
                if let active = self.appState.activeConversationID,
                   failed.contains(active) {
                    self.errorMessage = "This chat lost its live connection. Its text and draft are preserved; nothing was resent."
                }
            } catch is CancellationError {
            } catch {
                guard self.connections.owner == expectedOwner, !self.retired else { return }
                self.errorMessage = "The live chat connection could not be restored. Its text and draft are preserved; nothing was resent."
            }
        }
    }

    func suspend() {
        isSuspended = true
        refreshFlight.cancel()
        activeSessionsFlight.cancel()
        transportRecoveryFlight.cancel()
        scheduledTasksFlight.cancel()
        invalidations?.suspend()
        resumeProgress.suspend()
        features.cancelNavigationHydrations()
        sessions.cancelHistoryRefreshes()
        features.invalidateLiveVoice()
        refreshID = UUID()
        isRefreshing = false
        features.flushChatPersistence()
        bridge.suspend()
        rooms.configureNativeClient(nil, preservingCatalog: true)
        rooms.configureNativeActivityClient(nil)
    }

    func retire() {
        guard !retired else { return }
        widgetPublisher?.retire(); widgetPublisher = nil
        observedPromptStore?.removeObserver(id: promptObserverID)
        observedPromptStore = nil
        suspend()
        retired = true
        resetClients.forEach { $0() }
        bridge.resetForAccountBoundary()
        features.resetForAccountBoundary()
    }

    private func install(_ supported: Set<WorkspaceCapability>, owner: WorkspaceOwner) throws {
        try require(owner)
        try connections.installCapabilities(WorkspaceCapabilities(
            owner: owner,
            values: Dictionary(uniqueKeysWithValues: WorkspaceCapability.allCases.map {
                ($0, supported.contains($0) ? .available : .unavailable(.unsupportedOperation))
            })
        ))
    }

    private func require(_ owner: WorkspaceOwner, request: UUID? = nil) throws {
        try Task.checkCancellation()
        guard !retired, connections.owner == owner, owner.authority == authority,
              request == nil || request == refreshID else { throw WorkspaceClientError.ownerChanged }
    }
}

/// Recovery is isolated by session, but cancellation and host changes still
/// invalidate the whole operation before any later session can be touched.
@MainActor
enum NativeWorkspaceSessionRecovery {
    static func recover(
        _ ids: [String], prioritizing activeID: String?,
        requireCurrent: () throws -> Void,
        hydrate: (String) async throws -> Void
    ) async throws -> Set<String> {
        var ordered = ids
        if let activeID, let index = ordered.firstIndex(of: activeID) {
            ordered.remove(at: index)
            ordered.insert(activeID, at: 0)
        }
        var failed = Set<String>()
        for id in ordered {
            try Task.checkCancellation()
            try requireCurrent()
            do {
                try await hydrate(id)
            } catch {
                try Task.checkCancellation()
                try requireCurrent()
                failed.insert(id)
            }
            try requireCurrent()
        }
        return failed
    }
}
