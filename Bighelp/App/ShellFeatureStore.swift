import Foundation

@MainActor
struct DemoFixtureTiming {
    let chatSleeper: any DemoSleeper
    let approvalDelay: Duration
    let voiceDelay: Duration

    static let visible = DemoFixtureTiming(
        chatSleeper: VisibleDemoSleeper(),
        approvalDelay: .milliseconds(420),
        voiceDelay: .milliseconds(180)
    )

    static let immediate = DemoFixtureTiming(
        chatSleeper: ImmediateDemoSleeper(),
        approvalDelay: .zero,
        voiceDelay: .zero
    )
}

struct VoicePresentation: Identifiable {
    let id: String
    let model: VoiceModel
    let conversationMode: VoiceConversationMode
    var liveModel: LiveVoiceModel? = nil
}

enum PreparedRouteModel {
    case chat(ChatModel)
    case sessions(SessionsModel)
    case scheduledTasks(ScheduledTasksStore)
    case approval(ApprovalModel)
}

@MainActor
final class ShellFeatureStore {
    let dashboardModel: DashboardModel

    private let timing: DemoFixtureTiming
    private let catalog: SessionCatalogStore
    private let agents: AgentDirectoryStore?
    private let agentRuntimeDefaults: (any AgentRuntimeDefaultsClient)?
    private let allowsNewChatAgentDefaults: Bool
    private let runtimeDefaultsRetryDelays: [Duration]
    private let botModeRooms: BotModeRoomStore?
    private let userIdentity: UserIdentityStore?
    private let conversationClientFactory: (SessionRecord, AgentProfile?) -> any ConversationClient
    private let conversationPrepared: @MainActor (ChatModel, any ConversationClient) -> Void
    private let sessionControlMessaging: (any BighelpLinkSessionControlMessaging)?
    private let slashCommandCatalogClient: (any SlashCommandCatalogClient)?
    private let generatedMediaResolver: (any GeneratedMediaResolving)?
    private let voiceClientFactory: ((SessionRecord, AgentProfile?) -> any VoiceSessionClient)?
    private let voiceInputLevelSource: () -> any VoiceInputLevelSource
    private let approvalRequestLoader: (any ApprovalRequestLoading)?
    private let approvalClient: (any ApprovalClient)?
    private let approvalPublisher: @MainActor (LoadedApprovalRequest) -> Void
    private let midSessionBehavior: @MainActor () -> MidSessionChatBehavior
    private let recentModelHistory: RecentModelHistoryStore
    let scheduledTasks: ScheduledTasksStore?
    /// Voices and microphone for group chats' team calls; nil hides the call.
    var teamCallServices: (any TeamCallServices)?
    /// A new chat that never sent anything was retired (Hermes dropped its unsaved session):
    /// its ID, agent and draft, so the screen showing it can open a fresh chat in its place.
    var onUnsentChatRetired: (@MainActor (String, String, String) -> Void)?
    private var chatModels: [String: ChatModel] = [:]
    private let navigationWorkspaceOwner: (@MainActor () -> WorkspaceOwner?)?
    private let nativeWarmSessionIsCurrent: @MainActor (SessionRecord, ChatModel) -> Bool
    private var nativeWarmSessionRefresh: (@MainActor (SessionRecord, ChatModel) async throws -> Void)?
    private var nativeCanonicalSessionReentry: (@MainActor (SessionRecord, ChatModel) async throws -> Void)?
    private let navigationHydrationTimeout: Duration
    private var navigationHydrations: [String: NavigationHydrationFlight] = [:]
    private var warmSessionRefreshes: [String: WarmSessionRefreshFlight] = [:]
    private var canonicalSessionReentries: [String: CanonicalSessionReentryFlight] = [:]
    private var hydratedNavigationModels: [String: ObjectIdentifier] = [:]
    private var navigationOwnedConversationIDs: Set<String> = []
    private var nativeModelUse: [String: UInt64] = [:]
    private var nativeModelUseSequence: UInt64 = 0
    private var retentionTask: Task<Void, Never>?
    private var isPruningModels = false
    static let nativeIdleWarmModelLimit = 4

    /// A presentation waiter, not the canonical task. Cancelling value() only
    /// removes that observer; even the last observer cannot cancel hydration.
    @MainActor
    final class NavigationHydration {
        let id = UUID()
        private var result: Result<SessionRecord, Error>?
        private var waiters: [UUID: CheckedContinuation<SessionRecord, Error>] = [:]

        func value() async throws -> SessionRecord {
            try Task.checkCancellation()
            let waiter = UUID()
            let record: SessionRecord = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result { continuation.resume(with: result) }
                    else { waiters[waiter] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
                }
            }
            try Task.checkCancellation()
            return record
        }

        fileprivate func finish(_ result: Result<SessionRecord, Error>) {
            guard self.result == nil else { return }
            self.result = result
            let observers = Array(waiters.values)
            waiters.removeAll()
            for observer in observers { observer.resume(with: result) }
        }
    }

    private struct NavigationHydrationFlight {
        let handle: NavigationHydration
        let model: ChatModel
        let source: SessionRecord
        let accountGeneration: UInt64
        let owner: WorkspaceOwner?
        let ownsHydrationFlag: Bool
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
    }

    private struct CanonicalSessionReentryFlight {
        let id: UUID
        let model: ChatModel
        let owner: WorkspaceOwner
        let task: Task<Void, Error>
    }

    private struct WarmSessionRefreshFlight {
        let id: UUID
        let model: ChatModel
        let owner: WorkspaceOwner?
        let task: Task<Void, any Error>
    }

    private var defersChatPresentation = false
    private var hasDeferredDashboardRefresh = false
    private var accountGeneration: UInt64 = 0
    private(set) var backgroundActivityProjectionCount = 0
    private final class BackgroundActivityProjection {
        var ledger: ChatActivityLedger
        var publishedEvents: [ChatActivityEvent]
        init(session: SessionRecord) {
            ledger = ChatActivityLedger(sessionID: session.id, events: session.activityEvents)
            publishedEvents = session.activityEvents
        }
    }
    // Reuse reconciliation indexes only within a delivery batch. These hold no
    // views, and are retired when presentation resumes or the account changes.
    private var backgroundActivityProjections: [String: BackgroundActivityProjection] = [:]

    func setChatPresentationDeferred(_ deferred: Bool) {
        guard defersChatPresentation != deferred else { return }
        // Keep the batch open while mounted models publish their final
        // snapshots, then persist all conversations in one catalog write.
        if deferred {
            defersChatPresentation = true
            catalog.setPresentationDeferred(true)
        }
        for model in chatModels.values { model.setTranscriptPresentationDeferred(deferred) }
        if !deferred {
            defersChatPresentation = false
            backgroundActivityProjections.removeAll()
            catalog.setPresentationDeferred(false)
            for snapshot in sessionSubagentSnapshots.values { dashboardModel.updateSubagentWork(snapshot) }
            catalog.flushPersistence()
            if hasDeferredDashboardRefresh {
                hasDeferredDashboardRefresh = false
                refreshDashboardAfterIncomingChange()
            }
        }
    }

    private func refreshDashboardAfterIncomingChange() {
        if defersChatPresentation {
            hasDeferredDashboardRefresh = true
            return
        }
        let generation = accountGeneration
        Task { [weak self] in
            guard let self, self.accountGeneration == generation else { return }
            await self.dashboardModel.refreshAfterExternalChange()
        }
    }
    private var sessionsModel: SessionsModel?
    private var approvalModels: [String: ApprovalModel] = [:]
    private var voiceSessionSequences: [String: Int] = [:]
    private var liveVoiceFactory: ((SessionRecord, AgentProfile?, ChatModel) -> LiveVoiceModel?)?
    private weak var activeLiveVoice: LiveVoiceModel?

    func configureLiveVoiceFactory(_ factory: @escaping (SessionRecord, AgentProfile?, ChatModel) -> LiveVoiceModel?) {
        liveVoiceFactory = factory
    }

    func configureCanonicalSessionReentry(
        _ reenter: @escaping @MainActor (SessionRecord, ChatModel) async throws -> Void
    ) {
        nativeCanonicalSessionReentry = reenter
    }

    func configureNativeWarmSessionRefresh(
        _ refresh: @escaping @MainActor (SessionRecord, ChatModel) async throws -> Void
    ) {
        nativeWarmSessionRefresh = refresh
    }

    func invalidateLiveVoice() {
        activeLiveVoice?.invalidateOwner()
        activeLiveVoice = nil
    }

    @discardableResult
    func installSessionStateSnapshot(_ page: SessionHydrationPage, source: SessionRecord) throws -> SessionRecord {
        let hydrated = try catalog.installSessionStateSnapshot(page, source: source)
        if let model = chatModels[source.id] {
            // Opening the hydration gate must not retire a locally pending
            // send before exact canonical pending-message reconciliation.
            var presentationSource = source
            if model.isSending { presentationSource.isActive = true }
            let ownsFlag = !model.isHydratingHistory
            if ownsFlag { model.beginHistoryHydration(from: presentationSource) }
            model.reconcileHydratedSession(hydrated)
            if ownsFlag { model.finishHistoryHydration(hasPreviousHistory: page.nextOffset != nil) }
            hydratedNavigationModels[source.id] = ObjectIdentifier(model)
        }
        return hydrated
    }

    func receiveLiveVoiceEvent(_ payload: [String: BighelpJSONValue]) {
        guard let model = activeLiveVoice else { return }
        model.receive(payload, owner: model.owner)
    }
    private var sessionTodoSnapshots: [String: SessionTodoSnapshot] = [:]
    private var sessionSubagentSnapshots: [String: SessionSubagentRosterSnapshot] = [:]
    private var unresolvedSubagentSnapshots: [String: SessionSubagentRosterSnapshot] = [:]

    init(
        timing: DemoFixtureTiming,
        catalog: SessionCatalogStore,
        agents: AgentDirectoryStore? = nil,
        agentRuntimeDefaults: (any AgentRuntimeDefaultsClient)? = nil,
        allowsNewChatAgentDefaults: Bool = true,
        runtimeDefaultsRetryDelays: [Duration] = [.seconds(1), .seconds(3)],
        botModeRooms: BotModeRoomStore? = nil,
        userIdentity: UserIdentityStore? = nil,
        scheduledTasks: ScheduledTasksStore? = nil,
        dashboardSource: (any DashboardDataSource)? = nil,
        dashboardVerifiedConnectionGeneration: @escaping @MainActor () -> UInt64? = { 0 },
        approvalRequestLoader: (any ApprovalRequestLoading)? = nil,
        approvalClient: (any ApprovalClient)? = nil,
        approvalPublisher: @escaping @MainActor (LoadedApprovalRequest) -> Void = { _ in },
        conversationClient: ((SessionRecord, AgentProfile?) -> any ConversationClient)? = nil,
        conversationPrepared: @escaping @MainActor (ChatModel, any ConversationClient) -> Void = { _, _ in },
        navigationWorkspaceOwner: (@MainActor () -> WorkspaceOwner?)? = nil,
        nativeWarmSessionIsCurrent: @escaping @MainActor (SessionRecord, ChatModel) -> Bool = { _, _ in false },
        navigationHydrationTimeout: Duration = .seconds(180),
        voiceClient: ((SessionRecord, AgentProfile?) -> any VoiceSessionClient)? = nil,
        voiceInputLevelSource: @escaping () -> any VoiceInputLevelSource = {
            AVAudioEngineVoiceInputLevelSource()
        },
        sessionControlMessaging: (any BighelpLinkSessionControlMessaging)? = nil,
        slashCommandCatalogClient: (any SlashCommandCatalogClient)? = nil,
        generatedMediaResolver: (any GeneratedMediaResolving)? = nil,
        recentModelHistory: RecentModelHistoryStore = RecentModelHistoryStore(),
        midSessionBehavior: @escaping @MainActor () -> MidSessionChatBehavior = { .steer }
    ) {
        self.timing = timing
        self.catalog = catalog
        self.agents = agents
        self.agentRuntimeDefaults = agentRuntimeDefaults
        self.allowsNewChatAgentDefaults = allowsNewChatAgentDefaults
        self.runtimeDefaultsRetryDelays = runtimeDefaultsRetryDelays
        self.botModeRooms = botModeRooms
        self.userIdentity = userIdentity
        self.scheduledTasks = scheduledTasks
        self.approvalRequestLoader = approvalRequestLoader
        self.approvalClient = approvalClient
        self.approvalPublisher = approvalPublisher
        self.conversationPrepared = conversationPrepared
        self.navigationWorkspaceOwner = navigationWorkspaceOwner
        self.nativeWarmSessionIsCurrent = nativeWarmSessionIsCurrent
        self.navigationHydrationTimeout = navigationHydrationTimeout
        voiceClientFactory = voiceClient
        self.voiceInputLevelSource = voiceInputLevelSource
        self.sessionControlMessaging = sessionControlMessaging
        self.slashCommandCatalogClient = slashCommandCatalogClient
        self.generatedMediaResolver = generatedMediaResolver
        self.recentModelHistory = recentModelHistory
        self.midSessionBehavior = midSessionBehavior
        conversationClientFactory = conversationClient ?? { session, agent in
            let agentID = session.agentIDs.first ?? "default"
            return ConversationFixtureClient(
                canonicalAgentID: agentID,
                agentDisplayName: agent?.name ?? "Assistant",
                agentAvatarFileName: agent?.avatarFileName
            )
        }
        dashboardModel = DashboardModel(
            source: dashboardSource ?? DashboardFixtureSource(),
            verifiedConnectionGeneration: dashboardVerifiedConnectionGeneration
        )
        dashboardModel.configureWorkSessions { [weak self] in
            self?.dashboardWorkSessions(presentation: false) ?? []
        }
        dashboardModel.configureWorkPresentation { [weak self] in
            self?.dashboardWorkSessions(presentation: true) ?? []
        }
        dashboardModel.configureWorkScheduledTasks { [weak scheduledTasks] in scheduledTasks?.tasks ?? [] }
    }

    private func dashboardWorkSessions(presentation: Bool) -> [SessionRecord] {
        let records = presentation ? catalog.presentedRecords : catalog.records
        if presentation && defersChatPresentation { return records }
        return records.map { record in
            guard let model = chatModels[record.id] else { return record }
            var live = record
            live.isActive = model.isSending || record.isActive
            live.items = model.items
            live.activityEvents = model.activityLedger.allEvents
            return live
        }
    }

    func preparedModel(for route: AppRoute) -> PreparedRouteModel? {
        switch route {
        case .chat(let conversationID):
            chatModels[conversationID].map(PreparedRouteModel.chat)
        case .sessions:
            sessionsModel.map(PreparedRouteModel.sessions)
        case .scheduledTasks, .scheduledTask:
            scheduledTasks.map(PreparedRouteModel.scheduledTasks)
        case .approval(let requestID):
            approvalModels[requestID].map(PreparedRouteModel.approval)
        case .skillsAndTools,
             .workspaceActivity, .workspaceSettings, .workspaceManagement, .workspaceConnections, .workspaceHub,
             .projects, .project, .kanban, .usage, .allHostsChats, .board,
             .workflows, .workflow, .workflowRun, .workflowSignoff, .workflowRuns:
            nil
        }
    }

    /// The retained model for a chat, whether or not it is on screen.
    func preparedChatModel(id: String) -> ChatModel? { chatModels[id] }

    /// A chat's agent and text, while it's never sent anything: what a fresh session needs to
    /// take its place if Hermes drops it while the app is away.
    func unsentChat(id: String) -> (agentID: String, text: String)? {
        guard let model = chatModels[id], !model.isBotMode, model.transcriptEntries.isEmpty,
              model.memberIDs.count == 1, let agentID = model.memberIDs.first else { return nil }
        return (agentID, model.draft)
    }

    @discardableResult
    func prepare(_ route: AppRoute) -> Bool {
        switch route {
        case .chat(let conversationID):
            guard let session = try? catalog.restoreSessionContent(id: conversationID) else { return false }
            if let existing = chatModels[conversationID] {
                noteNativeModelUse(conversationID)
                let agent = session.agentIDs.first.flatMap { id in agents?.profiles.first { $0.id == id } }
                let native = conversationClientFactory(session, agent) as? DirectHermesConversationClient
                if ownsNativeNavigationHydration, let native, existing.nativeConversationClient === native {
                    // History preparation already reconciled this attached
                    // native sink. It may have advanced since the page returned.
                    conversationPrepared(existing, native)
                    return true
                }
                existing.reconcileHydratedSession(session, goalSnapshot: session.sessionGoal)
                if let native, existing.nativeConversationClient !== native,
                   existing.attachPreparedNativeClient(native) {
                    conversationPrepared(existing, native)
                }
                if session.kind != .botMode { return true }
                guard existing.botModeRoomID != nil && existing.botModeRoom != nil else {
                    existing.retireResponseHaptics()
                    chatModels[conversationID] = nil
                    return false
                }
                return true
            }
            let model = chatModel(for: session)
            guard session.kind == .botMode else { return true }
            guard model.botModeRoomID != nil && model.botModeRoom != nil else {
                model.retireResponseHaptics()
                chatModels[conversationID] = nil
                return false
            }
            return true
        case .sessions:
            if preparedModel(for: route) != nil { return true }
            guard let agents else { return false }
            sessionsModel = SessionsModel(
                catalog: catalog,
                agents: agents,
                hostedRooms: botModeRooms
            )
            return true
        case .scheduledTasks:
            return scheduledTasks != nil
        case .scheduledTask(let id, let agentID):
            guard let scheduledTasks, scheduledTasks.task(id: id, agentID: agentID) != nil else { return false }
            return true
        case .approval(let requestID):
            if preparedModel(for: route) != nil { return true }
            guard approvalRequestLoader == nil else { return false }
            guard let request = ApprovalFixtureCatalog.request(id: requestID) else {
                return false
            }
            _ = approvalModel(for: request)
            return true
        case .skillsAndTools,
             .workspaceActivity, .workspaceSettings, .workspaceManagement, .workspaceConnections, .workspaceHub,
             .projects, .project, .kanban, .usage, .allHostsChats, .board,
             .workflows, .workflow, .workflowRun, .workflowSignoff, .workflowRuns:
            return true
        }
    }

    /// Prepares the empty direct chat returned by the new-chat creation path.
    /// The explicit creation boundary, rather than the presence or absence of a
    /// remote coordinate, grants agent-default initialization authority.
    @discardableResult
    func prepareNewChat(_ route: AppRoute) -> Bool {
        guard case .chat(let conversationID) = route,
              let session = try? catalog.restoreSessionContent(id: conversationID),
              session.kind == .direct,
              !session.hasAcceptedMessage,
              session.items.isEmpty
        else { return false }

        let model: ChatModel
        if let existing = chatModels[conversationID] {
            existing.reconcileHydratedSession(session, goalSnapshot: session.sessionGoal)
            model = existing
        } else {
            model = chatModel(for: session, isExplicitlyNewChat: true)
        }
        // Native creation already established the exact stream. Retain that
        // verified preparation so Force Refresh does not require a fake reopen.
        if navigationWorkspaceOwner?() != nil,
           model.ownsReferenceSession(session),
           nativeWarmSessionIsCurrent(session, model) {
            hydratedNavigationModels[conversationID] = ObjectIdentifier(model)
        }
        return true
    }

    @discardableResult
    func prepareCachedForUserNavigation(_ route: AppRoute) throws -> Bool {
        if case .chat(let id) = route, let model = chatModels[id] {
            // A remapped catalog row must not inherit another coordinate's
            // draft/canvas, even though its visible ID happened to survive.
            if ownsNativeNavigationHydration, let current = catalog.session(id: id),
               current.kind == .direct, !model.isBotMode,
               !model.ownsReferenceSession(current),
               !hasCurrentNavigationHydration(id: id) {
                retireNavigationSession(id: id)
            } else {
                noteNativeModelUse(id)
                navigationOwnedConversationIDs.insert(id)
                return true
            }
        }
        let prepared = try prepareForUserNavigation(route)
        if prepared, case .chat(let id) = route {
            noteNativeModelUse(id)
            navigationOwnedConversationIDs.insert(id)
        }
        return prepared
    }

    var ownsNativeNavigationHydration: Bool { navigationWorkspaceOwner != nil }

    /// Pure inspection of a retained, already attached native owner. No cache
    /// restore, lease rebind, history request or recovery is hidden in a hit.
    func canReturnToWarmSession(id: String) -> Bool {
        guard ownsNativeNavigationHydration, navigationWorkspaceOwner?() != nil,
              navigationHydrations[id] == nil,
              let model = chatModels[id], let record = catalog.session(id: id),
              hydratedNavigationModels[id] == ObjectIdentifier(model),
              !model.isHydratingHistory, !model.isLoadingPreviousHistory,
              model.ownsReferenceSession(record) else { return false }
        return nativeWarmSessionIsCurrent(record, model)
    }

    func refreshWarmSessionState(id: String) {
        guard let model = chatModels[id], let source = catalog.session(id: id),
              canReturnToWarmSession(id: id) else { return }
        _ = scheduleWarmSessionRefresh(
            id: id,
            source: source,
            model: model,
            owner: navigationWorkspaceOwner?()
        )
    }

    @discardableResult
    private func scheduleWarmSessionRefresh(
        id: String,
        source: SessionRecord,
        model: ChatModel,
        owner: WorkspaceOwner?
    ) -> Task<Void, any Error>? {
        guard let refresh = nativeWarmSessionRefresh else { return nil }
        if let flight = warmSessionRefreshes[id] {
            if flight.model === model, flight.owner == owner { return flight.task }
            flight.task.cancel()
            warmSessionRefreshes[id] = nil
        }
        let flightID = UUID()
        model.beginHostRefresh()
        let task = Task { @MainActor [weak self, weak model] in
            defer { model?.endHostRefresh() }
            guard let model else { throw CancellationError() }
            defer {
                if let self, self.warmSessionRefreshes[id]?.id == flightID {
                    self.warmSessionRefreshes[id] = nil
                }
            }
            try await refresh(source, model)
        }
        warmSessionRefreshes[id] = WarmSessionRefreshFlight(
            id: flightID,
            model: model,
            owner: owner,
            task: task
        )
        return task
    }

    /// Force Refresh is an exact-session re-entry, not a second hydration
    /// pipeline. The retained model owns drafts, attachments, scroll state and
    /// unresolved submissions while the native runtime refreshes canonical data.
    func forceRefreshSession(id: String) async throws {
        guard ownsNativeNavigationHydration,
              let owner = navigationWorkspaceOwner?(),
              let model = chatModels[id],
              let source = catalog.session(id: id), source.kind == .direct,
              model.ownsReferenceSession(source) else {
            throw WorkspaceClientError.ownerChanged
        }
        if let flight = canonicalSessionReentries[id] {
            guard flight.owner == owner, flight.model === model else {
                throw WorkspaceClientError.ownerChanged
            }
            try await flight.task.value
            return
        }
        // Suspension clears warm-readiness markers, not retained ownership.
        // The native reentry closure validates the exact owner/client/session
        // before recovering; requiring a warm marker here prevents that repair.
        guard let reenter = nativeCanonicalSessionReentry else {
            throw WorkspaceClientError.ownerChanged
        }

        let flightID = UUID()
        model.beginHostRefresh()
        let task = Task { @MainActor [weak self, weak model] in
            defer { model?.endHostRefresh() }
            guard let self, let model else { throw CancellationError() }
            defer {
                if self.canonicalSessionReentries[id]?.id == flightID {
                    self.canonicalSessionReentries[id] = nil
                }
            }
            try await reenter(source, model)
            guard self.navigationWorkspaceOwner?() == owner,
                  self.chatModels[id] === model,
                  let current = self.catalog.session(id: id),
                  model.ownsReferenceSession(current),
                  self.nativeWarmSessionIsCurrent(current, model) else {
                throw WorkspaceClientError.ownerChanged
            }
            self.hydratedNavigationModels[id] = ObjectIdentifier(model)
        }
        canonicalSessionReentries[id] = CanonicalSessionReentryFlight(
            id: flightID,
            model: model,
            owner: owner,
            task: task
        )
        try await task.value
    }

    /// Admit synchronously, before creating a view-owned Task. A second open
    /// joins the exact flight, so A -> B -> A cannot replace A's native lease.
    /// Explicit callers may also exercise this seam with a fixture catalog;
    /// Root opts in only for the native workspace composition.
    func startNavigationHydration(id: String) throws -> NavigationHydration {
        guard let model = chatModels[id], let source = catalog.session(id: id),
              source.kind == .direct else { throw SessionCatalogError.invalidSession }
        let owner = navigationWorkspaceOwner?()
        if ownsNativeNavigationHydration, owner == nil { throw CancellationError() }
        if let flight = navigationHydrations[id] {
            if flight.model === model, flight.accountGeneration == accountGeneration,
               flight.owner == owner, Self.sameNavigationSession(flight.source, source) {
                return flight.handle
            }
            cancelNavigationHydration(id: id)
        }
        let handle = NavigationHydration()
        if canReturnToWarmSession(id: id) {
            refreshWarmSessionState(id: id)
            handle.finish(.success(source))
            return handle
        }
        let ownsFlag = !model.isHydratingHistory
        hydratedNavigationModels[id] = nil
        if ownsFlag {
            var presentation = source
            if model.isSending { presentation.isActive = true }
            // A delayed catalog checkpoint must not clear a richer live canvas.
            presentation.items = model.items
            presentation.activityEvents = model.activityLedger.allEvents
            model.beginHistoryHydration(from: presentation)
        }
        navigationHydrations[id] = NavigationHydrationFlight(
            handle: handle, model: model, source: source,
            accountGeneration: accountGeneration, owner: owner, ownsHydrationFlag: ownsFlag
        )
        let flightID = handle.id
        let catalog = catalog
        navigationHydrations[id]?.task = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                guard self?.navigationHydrations[id]?.handle.id == flightID,
                      self?.hasCurrentNavigationHydration(id: id) == true else { throw CancellationError() }
                let record = try await catalog.hydrateInitialPage(id: id)
                try Task.checkCancellation()
                self?.completeNavigationHydration(id: id, flightID: flightID, result: .success(record))
            } catch {
                self?.completeNavigationHydration(id: id, flightID: flightID, result: .failure(error))
            }
        }
        let timeout = navigationHydrationTimeout
        navigationHydrations[id]?.deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard self?.navigationHydrations[id]?.handle.id == flightID else { return }
            self?.cancelNavigationHydration(id: id)
        }
        noteNativeModelUse(id)
        return handle
    }

    /// Scene/workspace suspension revokes feature ownership synchronously.
    /// Ordinary route disappearance deliberately does not call this method.
    func cancelNavigationHydrations() {
        hydratedNavigationModels.removeAll()
        for id in Array(navigationHydrations.keys) { cancelNavigationHydration(id: id) }
        let warm = warmSessionRefreshes
        warmSessionRefreshes.removeAll()
        for flight in warm.values { flight.task.cancel() }
        let reentries = canonicalSessionReentries
        canonicalSessionReentries.removeAll()
        for flight in reentries.values { flight.task.cancel() }
    }

    func retireNavigationSession(id: String) {
        cancelNavigationHydration(id: id)
        warmSessionRefreshes.removeValue(forKey: id)?.task.cancel()
        canonicalSessionReentries.removeValue(forKey: id)?.task.cancel()
        hydratedNavigationModels[id] = nil
        guard let model = chatModels.removeValue(forKey: id) else { return }
        // A new chat that never sent anything: the screen showing it opens a fresh one in its place.
        if !model.isBotMode, model.transcriptEntries.isEmpty, model.memberIDs.count == 1,
           let agentID = model.memberIDs.first {
            onUnsentChatRetired?(id, agentID, model.draft)
        }
        // Removing the exact sink first prevents its final flush from writing
        // into a replacement catalog coordinate.
        model.retireResponseHaptics()
        model.cancelGeneratedMediaResolutionRequests()
        model.invalidateReferenceOwnership()
        nativeModelUse[id] = nil
        navigationOwnedConversationIDs.remove(id)
    }

    private func cancelNavigationHydration(id: String) {
        guard let flight = navigationHydrations.removeValue(forKey: id) else { return }
        flight.task?.cancel()
        flight.deadline?.cancel()
        if flight.ownsHydrationFlag, chatModels[id] === flight.model {
            flight.model.finishHistoryHydration(hasPreviousHistory: catalog.hasPreviousHistory(id: id))
        }
        flight.handle.finish(.failure(CancellationError()))
        scheduleNativeRetention()
    }

    private func completeNavigationHydration(
        id: String, flightID: UUID, result: Result<SessionRecord, Error>
    ) {
        guard let flight = navigationHydrations[id], flight.handle.id == flightID else { return }

        guard flight.accountGeneration == accountGeneration,
              flight.owner == navigationWorkspaceOwner?(), chatModels[id] === flight.model,
              let current = catalog.session(id: id) else {
            cancelNavigationHydration(id: id)
            return
        }
        var completion = result
        if case .success(let record) = result {
            guard Self.sameNavigationSession(record, current),
                  prepare(.chat(conversationID: id)), chatModels[id] === flight.model else {
                cancelNavigationHydration(id: id)
                return
            }
            // Preparation attaches the existing native adapter even offscreen.
            // Publish its latest sink, not the older value returned across await.
            let model = flight.model
            if !model.hasPendingIndependentMessageSubmission {
                catalog.updateChatSnapshot(draft: model.persistedDraft, items: model.items,
                    activityEvents: model.activityLedger.allEvents, activityVisibility: model.activityVisibility, for: id)
            }
            // The model's normal checkpoint excludes provisional independent
            // rows. Do not bypass that rule while such a submission is pending.
            model.flushPersistence()
            catalog.flushPersistence()
            hydratedNavigationModels[id] = ObjectIdentifier(model)
            completion = .success(catalog.session(id: id) ?? record)
        }
        navigationHydrations[id] = nil
        flight.deadline?.cancel()
        if flight.ownsHydrationFlag {
            flight.model.finishHistoryHydration(hasPreviousHistory: catalog.hasPreviousHistory(id: id))
        }
        flight.handle.finish(completion)
        scheduleNativeRetention()
    }

    private static func sameNavigationSession(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.agentIDs == rhs.agentIDs
            && lhs.remoteStoredID == rhs.remoteStoredID && lhs.remoteSource == rhs.remoteSource
            && lhs.botModeRoomID == rhs.botModeRoomID
    }

    private func hasCurrentNavigationHydration(id: String) -> Bool {
        guard let flight = navigationHydrations[id], flight.accountGeneration == accountGeneration,
              flight.owner == navigationWorkspaceOwner?(), chatModels[id] === flight.model,
              let current = catalog.session(id: id) else { return false }
        return Self.sameNavigationSession(flight.source, current)
    }

    @discardableResult
    func prepareForUserNavigation(_ route: AppRoute) throws -> Bool {
        if case .chat(let conversationID) = route,
           catalog.session(id: conversationID)?.kind == .botMode {
            guard let botModeRooms else { return false }
            try BotModeRoomLoadingPolicy.load(botModeRooms, for: .explicitUse)
        }
        return prepare(route)
    }

    @discardableResult
    func prepareApproval(id: String) async throws -> Bool {
        let route = AppRoute.approval(requestID: id)
        if preparedModel(for: route) != nil { return true }
        guard let approvalRequestLoader else { return prepare(route) }
        let loaded = try await approvalRequestLoader.loadApproval(id: id)
        guard loaded.request.id == id else { return false }
        approvalPublisher(loaded)
        _ = approvalModel(
            for: loaded.request,
            allowedDecisions: loaded.allowedDecisions
        )
        return true
    }

    @discardableResult
    func prepareApproval(request: ApprovalRequest) -> Bool {
        _ = approvalModel(for: request)
        return true
    }

    func retainModels(ownedBy routes: [AppRoute]) {
        navigationOwnedConversationIDs = Set(routes.compactMap { route -> String? in
            guard case .chat(let conversationID) = route else { return nil }
            return conversationID
        })
        for id in navigationOwnedConversationIDs.sorted() { noteNativeModelUse(id) }
        pruneRetainedModels()
        voiceSessionSequences = voiceSessionSequences.filter { conversationID, _ in
            navigationOwnedConversationIDs.contains(conversationID)
        }
        // Sessions is a root tab. Keep its prepared model stable while a
        // selected session is pushed, so Back returns to the same root state.
    }

    private func noteNativeModelUse(_ id: String) {
        guard catalog.session(id: id)?.kind == .direct else { return }
        guard ownsNativeNavigationHydration || chatModels[id]?.nativeConversationClient?.nativeWorkspaceAuthority != nil else { return }
        nativeModelUseSequence &+= 1
        nativeModelUse[id] = nativeModelUseSequence
    }

    private func scheduleNativeRetention() {
        guard ownsNativeNavigationHydration, retentionTask == nil, !isPruningModels else { return }
        retentionTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.retentionTask = nil
            self.pruneRetainedModels()
        }
    }

    private func pruneRetainedModels() {
        guard !isPruningModels else { return }
        isPruningModels = true
        defer { isPruningModels = false }
        for (id, model) in chatModels where !navigationOwnedConversationIDs.contains(id) {
            model.flushPersistence()
        }
        catalog.flushPersistence()

        var protected = navigationOwnedConversationIDs
        var idleNativeIDs: [String] = []
        for (id, model) in chatModels {
            if model.isSending || model.hasPendingIndependentMessageSubmission
                || model.isHydratingHistory || model.isLoadingPreviousHistory
                || navigationHydrations[id] != nil || canonicalSessionReentries[id] != nil {
                protected.insert(id)
                continue
            }
            guard nativeModelUse[id] != nil,
                  ownsNativeNavigationHydration || model.nativeConversationClient?.nativeWorkspaceAuthority != nil else { continue }
            let record = catalog.session(id: id)
            let native = model.nativeConversationClient
            // Journal uncertainty, accepted work and composer-only material
            // are owners, not cache entries. Never evict them to reach four.
            let hasUnobservedCatalogWork = native?.connected != true && record?.hasActiveWork == true
            let cannotEvict = native?.projection.running == true
                || native?.journal.unresolved.isEmpty == false
                || hasUnobservedCatalogWork
                || record?.sessionSubagents?.subagents.isEmpty == false
                || native?.nativeSubagents.isEmpty == false
                || !model.pendingMidSessionSubmissions.isEmpty
                || model.referenceSubmission != nil
                || !model.draftAttachments.isEmpty
                || catalog.persistenceErrorMessage != nil
                || record.map({ Data($0.draft.utf8) }) != Data(model.persistedDraft.utf8)
                || record?.referenceState != model.referenceState
            if cannotEvict { protected.insert(id) }
            else if !protected.contains(id) { idleNativeIDs.append(id) }
        }
        idleNativeIDs.sort {
            let lhs = nativeModelUse[$0, default: 0], rhs = nativeModelUse[$1, default: 0]
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        protected.formUnion(idleNativeIDs.prefix(Self.nativeIdleWarmModelLimit))
        for (id, model) in chatModels where !protected.contains(id) {
            model.retireResponseHaptics()
            chatModels[id] = nil
            nativeModelUse[id] = nil
            hydratedNavigationModels[id] = nil
        }
    }

    func resetForAccountBoundary() {
        cancelNavigationHydrations()
        navigationOwnedConversationIDs.removeAll()
        nativeModelUse.removeAll()
        activeLiveVoice?.invalidateOwner()
        activeLiveVoice = nil
        chatModels.values.forEach {
            $0.retireResponseHaptics()
            $0.cancelGeneratedMediaResolutionRequests()
            $0.flushPersistence()
            $0.invalidateReferenceOwnership()
        }
        catalog.flushPersistence()
        accountGeneration &+= 1
        retentionTask?.cancel()
        retentionTask = nil
        backgroundActivityProjections.removeAll()
        chatModels.removeAll()
        sessionsModel = nil
        approvalModels.removeAll()
        voiceSessionSequences.removeAll()
        sessionTodoSnapshots.removeAll()
        sessionSubagentSnapshots.removeAll()
        unresolvedSubagentSnapshots.removeAll()
        hasDeferredDashboardRefresh = false
        dashboardModel.resetForAccountBoundary()
    }

    func flushChatPersistence() {
        chatModels.values.forEach { $0.flushPersistence() }
        catalog.flushPersistence()
    }


    @discardableResult
    func prepareSessions(filteredTo agentID: String? = nil) -> Bool {
        guard prepare(.sessions) else { return false }
        sessionsModel?.agentFilter = agentID.map(SessionAgentFilter.agent) ?? .all
        return true
    }

    @discardableResult
    func prepareScheduledTasks(filteredTo agentID: String?) -> Bool {
        guard prepare(.scheduledTasks) else { return false }
        scheduledTasks?.agentFilterID = agentID
        return true
    }

    func acceptAssistantLiveness(_ message: BighelpLinkAssistantMessage) {
        guard let session = DashboardWorkProjection.session(
            resolving: message.sessionID, agentID: message.agentID, in: catalog.records
        ) else { return }
        if message.delivery == .draft, session.items.contains(where: {
            $0.id == message.messageID && $0.metadata.delivery != "Streaming"
        }) { return }
        catalog.reconcileAssistantLiveness(
            sessionID: session.id,
            turnID: message.turnID,
            sentAt: Date(timeIntervalSince1970: TimeInterval(message.sentAt)),
            isStreaming: message.delivery == .draft
        )
        if message.delivery == .final {
            refreshDashboardAfterIncomingChange()
        }
    }

    func acceptExternal(
        _ items: [TimelineItem],
        conversationID: String,
        isLiveAssistantText: Bool = false
    ) {
        let visibleSessionID = catalog.visibleSessionID(
            resolvingProtocolSessionID: conversationID
        ) ?? conversationID
        if let model = chatModels[visibleSessionID] {
            model.acceptExternal(items, isLiveAssistantText: isLiveAssistantText)
            if items.allSatisfy({ $0.metadata.delivery == "Streaming" }) {
                for item in items {
                    guard let projected = model.projectedMessage(id: item.id) else { continue }
                    catalog.updateStreamingTail(projected, for: visibleSessionID)
                }
            }
            return
        }
        for item in items {
            // Keep a live tail for unmounted sessions too; a final of the same
            // ID replaces its draft rather than appending or being discarded.
            catalog.acceptExternalTimelineItem(item, for: visibleSessionID)
        }
        if !defersChatPresentation, items.contains(where: { $0.metadata.delivery != "Streaming" }) {
            catalog.flushPersistence()
        }
    }

    func acceptExternalActivity(_ event: ChatActivityEvent, agentID: String? = nil) {
        let matched = DashboardWorkProjection.session(
            resolving: event.sessionID, agentID: agentID, in: catalog.records
        )
        // An ambiguous or differently owned known coordinate must not route
        // through the catalog's legacy first-match alias resolver.
        if matched == nil, catalog.records.contains(where: {
            $0.id == event.sessionID || $0.remoteStoredID == event.sessionID
        }) { return }
        let visibleSessionID = matched?.id ?? event.sessionID
        let routedEvent = event.routed(to: visibleSessionID)
        let session = catalog.session(id: visibleSessionID)
            ?? catalog.ensureActiveChild(
                id: visibleSessionID,
                title: "Subagent task",
                agentID: agentID, persist: !defersChatPresentation
            )
        if let model = chatModels[visibleSessionID] {
            let result = model.acceptActivity(routedEvent)
            if result == .inserted || result == .recovered || result == .updated {
                catalog.reconcileActivityLiveness(routedEvent, for: visibleSessionID)
            }
            return
        }
        let projection: BackgroundActivityProjection
        if defersChatPresentation,
           let cached = backgroundActivityProjections[session.id],
           cached.publishedEvents == session.activityEvents {
            projection = cached
        } else {
            backgroundActivityProjectionCount += 1
            projection = BackgroundActivityProjection(session: session)
            if defersChatPresentation {
                // A new history snapshot invalidates the cached projection.
                // Capacity bounds temporary indexes during multi-session replay.
                if backgroundActivityProjections.count >= 8 {
                    backgroundActivityProjections.removeAll()
                }
                backgroundActivityProjections[session.id] = projection
            }
        }
        let result = projection.ledger.receive(routedEvent)
        guard result == .inserted || result == .recovered || result == .updated else { return }
        projection.ledger.retainLatest(SessionCatalogStore.activityRetentionLimit)
        projection.publishedEvents = projection.ledger.allEvents
        catalog.replaceActivity(
            projection.publishedEvents,
            visibility: session.activityVisibility,
            for: session.id
        )
        catalog.reconcileActivityLiveness(routedEvent, for: visibleSessionID)
    }

    func acceptSessionGoal(_ snapshot: SessionGoalSnapshot) {
        let visibleID = catalog.visibleSessionID(resolvingProtocolSessionID: snapshot.sessionID)
            ?? catalog.visibleSessionID(resolvingProtocolSessionID: snapshot.storedSessionID)
            ?? snapshot.sessionID
        guard let session = catalog.session(id: visibleID),
              session.remoteStoredID == nil || session.remoteStoredID == snapshot.storedSessionID else { return }
        let routed = snapshot.routed(to: visibleID)
        catalog.reconcileSessionGoal(routed)
        chatModels[visibleID]?.reconcileGoal(routed)
    }

    func acceptSessionContext(_ snapshot: SessionContextSnapshot) {
        let visibleSessionID = catalog.visibleSessionID(
            resolvingProtocolSessionID: snapshot.sessionId
        ) ?? snapshot.sessionId
        let routedSnapshot = snapshot.routed(to: visibleSessionID)
        guard catalog.session(id: visibleSessionID) != nil
                || chatModels[visibleSessionID] != nil
        else { return }
        catalog.reconcileSessionContext(routedSnapshot)
        chatModels[visibleSessionID]?.reconcileSessionContext(routedSnapshot)
    }

    func acceptSessionTodos(_ snapshot: SessionTodoSnapshot) {
        let visibleSessionID = catalog.visibleSessionID(
            resolvingProtocolSessionID: snapshot.sessionID
        ) ?? snapshot.sessionID
        let routedSnapshot = snapshot.routed(to: visibleSessionID)
        guard catalog.session(id: visibleSessionID) != nil
                || chatModels[visibleSessionID] != nil
        else { return }
        guard routedSnapshot.isValid,
              routedSnapshot.supersedes(catalog.session(id: visibleSessionID)?.sessionTodos),
              routedSnapshot.supersedes(sessionTodoSnapshots[visibleSessionID]) else { return }
        sessionTodoSnapshots[visibleSessionID] = routedSnapshot
        catalog.reconcileSessionTodos(routedSnapshot)
        chatModels[visibleSessionID]?.reconcileTodos(routedSnapshot)
    }

    func acceptNativeSubagentRoster(
        _ items: [NativeSubagentRailItem],
        sessionID: String,
        client: DirectHermesConversationClient
    ) {
        guard let model = chatModels[sessionID],
              model.nativeConversationClient === client,
              items == client.nativeSubagents,
              let record = catalog.session(id: sessionID),
              model.ownsReferenceSession(record) else { return }
        // The client has already atomically replaced its canonical maps. This
        // sink only republishes that exact projection; it cannot author a roster.
        model.reconcileNativeSubagents(client.nativeSubagents)
    }

    func acceptSessionSubagents(_ snapshot: SessionSubagentRosterSnapshot) {
        guard snapshot.isValid else { return }
        guard let parent = DashboardWorkProjection.session(
            resolving: snapshot.sessionID, agentID: nil, in: catalog.records
        ) else {
            // The first child can precede materialization of a new parent's
            // durable coordinate. Discover it, never guess an alias from a draft.
            let previous = unresolvedSubagentSnapshots[snapshot.sessionID]
            if let previous, previous.updatedAt >= snapshot.updatedAt { return }
            guard previous != nil || unresolvedSubagentSnapshots.count < 256 else { return }
            unresolvedSubagentSnapshots[snapshot.sessionID] = snapshot
            guard previous == nil else { return }
            let generation = accountGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.catalog.load(requireAuthoritativeRefresh: true)
                guard self.accountGeneration == generation else { return }
                guard let latest = self.unresolvedSubagentSnapshots.removeValue(forKey: snapshot.sessionID),
                      DashboardWorkProjection.session(resolving: latest.sessionID, agentID: nil, in: self.catalog.records) != nil
                else { return }
                self.acceptSessionSubagents(latest)
            }
            return
        }
        let visibleSessionID = parent.id
        let incoming = snapshot.routed(to: visibleSessionID)
        // Catalog discovery may have captured a newer roster while resolving
        // this event. Adopt that snapshot in the mounted rail as well.
        let routedSnapshot = parent.sessionSubagents.map {
            $0.updatedAt >= incoming.updatedAt ? $0 : incoming
        } ?? incoming
        guard sessionSubagentSnapshots[visibleSessionID].map({
            routedSnapshot.updatedAt > $0.updatedAt
        }) ?? true else { return }
        let previousChildIDs = Set((sessionSubagentSnapshots[visibleSessionID]
            ?? catalog.session(id: visibleSessionID)?.sessionSubagents)?.subagents.map(\.sessionID) ?? [])
        let currentChildIDs = Set(routedSnapshot.subagents.map(\.sessionID))
        sessionSubagentSnapshots[visibleSessionID] = routedSnapshot
        catalog.reconcileSubagentWork(routedSnapshot)
        if !defersChatPresentation { dashboardModel.updateSubagentWork(routedSnapshot) }
        if let parent = catalog.session(id: visibleSessionID) {
            for child in routedSnapshot.subagents where catalog.session(id: child.sessionID) == nil {
                catalog.ensureActiveChild(id: child.sessionID,
                    title: SessionSubagentRosterPresentation.card(for: child).name,
                    agentID: parent.agentIDs.first, persist: !defersChatPresentation)
            }
            for childID in previousChildIDs.subtracting(currentChildIDs) {
                if let child = DashboardWorkProjection.session(resolving: childID, agentID: parent.agentIDs.first, in: catalog.records) {
                    catalog.markInactiveAfterAuthoritativeTerminal(id: child.id, persist: !defersChatPresentation)
                }
            }
        }
        catalog.reconcileSubagentSessions(
            parentSessionID: visibleSessionID,
            childSessionIDs: routedSnapshot.subagents.map(\.sessionID)
        )
        for child in routedSnapshot.subagents {
            guard let record = DashboardWorkProjection.session(
                resolving: child.sessionID,
                agentID: catalog.session(id: visibleSessionID)?.agentIDs.first,
                in: catalog.records
            ), DashboardWorkProjection.meaningfulTitle(record.title) == nil
                || record.title == "Subagent task"
            else { continue }
            catalog.reconcileLiveSessionTitle(
                id: record.id, title: SessionSubagentRosterPresentation.card(for: child).name,
                persist: !defersChatPresentation
            )
        }
        guard catalog.session(id: visibleSessionID) != nil
                || chatModels[visibleSessionID] != nil
        else { return }
        chatModels[visibleSessionID]?.reconcileSubagents(routedSnapshot)
    }

    /// Re-attempts session-only hydration after Link reconnects. This is
    /// intentionally separate from the agent-directory refresh so a failed
    /// defaults RPC cannot leave an already-open chat on an unknown default
    /// forever after the transport has recovered.
    func retryAgentRuntimeDefaults() {
        guard agentRuntimeDefaults != nil else { return }
        for model in chatModels.values {
            guard let controls = model.runtimeControls else { continue }
            scheduleAgentRuntimeDefaults(
                sessionID: model.conversationID,
                agentID: controls.agentID,
                controls: controls
            )
        }
    }

    func reassignDirectChat(
        sessionID: String,
        to agentID: String
    ) -> DirectChatAgentSelectionResult {
        guard let model = chatModels[sessionID] else { return .unavailable }
        guard model.canReassignDirectAgent else {
            return model.items.isEmpty ? .unavailable : .blockedByHistory
        }
        let result = catalog.reassignDirectAgent(sessionID: sessionID, to: agentID)
        guard result == .reassigned,
              let session = catalog.session(id: sessionID)
        else { return result }

        let agent = agents?.profiles.first(where: { $0.id == agentID })
        let runtimeControls = sessionControlMessaging.map {
            SessionRuntimeControlModel(
                sessionID: sessionID,
                agentID: agentID,
                messaging: $0,
                modelHistory: recentModelHistory,
                allowsAgentDefaults: allowsNewChatAgentDefaults
            )
        }
        let slashCommands = slashCommandCatalogClient.map {
            SlashCommandCatalogModel(
                sessionID: sessionID,
                agentID: agentID,
                client: $0
            )
        }
        let conversationClient = conversationClientFactory(session, agent)
        model.reassignDirectAgent(
            to: agentID,
            client: conversationClient,
            runtimeControls: runtimeControls,
            slashCommandCatalog: slashCommands
        )
        conversationPrepared(model, conversationClient)
        if let runtimeControls, agentRuntimeDefaults != nil {
            scheduleAgentRuntimeDefaults(
                sessionID: sessionID,
                agentID: agentID,
                controls: runtimeControls
            )
        }
        return .reassigned
    }

    private func chatModel(
        for session: SessionRecord,
        isExplicitlyNewChat: Bool = false
    ) -> ChatModel {
        if let existing = chatModels[session.id] {
            return existing
        }

        let agentID = session.agentIDs.first ?? "default"
        let agent = agents?.profiles.first(where: { $0.id == agentID })
        let botModeRoomID = prepareBotModeRoom(for: session)
        let initialItems: [TimelineItem] = if session.kind == .botMode {
            botModeRoomID.flatMap { id in botModeRooms?.room(id: id)?.privateHistory } ?? []
        } else {
            session.items
        }
        let runtimeControls = sessionControlMessaging.map {
            SessionRuntimeControlModel(
                sessionID: session.id,
                agentID: agentID,
                messaging: $0,
                modelHistory: recentModelHistory,
                allowsAgentDefaults: allowsNewChatAgentDefaults && (isExplicitlyNewChat
                    || (session.remoteStoredID == nil && !session.hasAcceptedMessage && session.items.isEmpty))
            )
        }
        let referenceGeneration = accountGeneration
        weak var referenceModel: ChatModel?
        let conversationClient = conversationClientFactory(session, agent)
        #if DEBUG
        if let fixture = conversationClient as? CanvasStreamingFixtureClient {
            fixture.featureStore = self
            fixture.catalog = catalog
        }
        #endif
        let model = ChatModel(
            conversationID: session.id,
            client: conversationClient,
            sleeper: timing.chatSleeper,
            userIdentityStore: userIdentity,
            agentID: agentID,
            initialItems: initialItems,
            initialDraft: session.draft,
            initialActivityEvents: session.activityEvents,
            initialActivityVisibility: session.activityVisibility,
            initialGoalSnapshot: session.sessionGoal,
            initialTodoSnapshot: session.sessionTodos,
            midSessionBehavior: midSessionBehavior,
            sourceSession: session,
            botModeRoomStore: botModeRooms,
            agentDirectory: agents,
            runtimeControls: runtimeControls,
            slashCommandCatalog: slashCommandCatalogClient.map {
                SlashCommandCatalogModel(
                    sessionID: session.id,
                    agentID: agentID,
                    client: $0
                )
            },
            generatedMediaResolver: generatedMediaResolver,
            botModeRoomID: botModeRoomID,
            onSessionChange: { [weak self, weak catalog] draft, items, ledger, visibility in
                guard let self, let catalog, self.accountGeneration == referenceGeneration,
                      let referenceModel, self.chatModels[session.id] === referenceModel else { return }
                if self.ownsNativeNavigationHydration, !referenceModel.isBotMode {
                    guard let current = catalog.session(id: session.id),
                          referenceModel.ownsReferenceSession(current) else { return }
                }
                let previousTail = catalog.session(id: session.id)?.items.last
                let settledReply = items.last.map {
                    $0.role == .assistant && $0.metadata.delivery != "Streaming"
                        && ($0.id != previousTail?.id || previousTail?.metadata.delivery == "Streaming")
                } ?? false
                let shouldSettle = settledReply && self.chatModels[session.id]?.isSending == false
                if shouldSettle { catalog.markInactiveAfterAuthoritativeTerminal(id: session.id, persist: false) }
                catalog.updateChatSnapshot(
                    draft: draft,
                    items: items,
                    activityEvents: ledger.allEvents,
                    activityVisibility: visibility,
                    for: session.id
                )
                if settledReply, !self.defersChatPresentation { catalog.flushPersistence() }
                if shouldSettle {
                    self.refreshDashboardAfterIncomingChange()
                }
                if !referenceModel.isSending { self.scheduleNativeRetention() }
            },
            onGoalSnapshotChange: { [weak self, weak catalog] snapshot in
                guard let self, let catalog,
                      self.accountGeneration == referenceGeneration,
                      let referenceModel,
                      self.chatModels[session.id] === referenceModel,
                      snapshot.sessionID == session.id,
                      let current = catalog.session(id: session.id),
                      referenceModel.ownsReferenceSession(current) else { return }
                if let storedID = current.remoteStoredID,
                   Data(storedID.utf8) != Data(snapshot.storedSessionID.utf8) { return }
                catalog.reconcileSessionGoal(snapshot)
            },
            onTodoSnapshotChange: { [weak self, weak catalog] snapshot in
                guard let self, let catalog,
                      self.accountGeneration == referenceGeneration,
                      let referenceModel,
                      self.chatModels[session.id] === referenceModel,
                      snapshot.sessionID == session.id,
                      let current = catalog.session(id: session.id),
                      referenceModel.ownsReferenceSession(current) else { return }
                catalog.reconcileSessionTodos(snapshot)
                if snapshot.supersedes(self.sessionTodoSnapshots[session.id]) {
                    self.sessionTodoSnapshots[session.id] = snapshot
                }
            },
            onTurnStopped: { [weak self, weak catalog] in
                catalog?.markInactiveAfterAcceptedStop(id: session.id)
                guard catalog != nil else { return }
                Task { @MainActor [weak self, weak catalog] in
                    guard let self, let catalog else { return }
                    do {
                        let authoritative = try await catalog.refreshExistingSession(id: session.id)
                        self.chatModels[session.id]?.reconcileHydratedSession(authoritative)
                    } catch is CancellationError {
                    } catch {
                        // The accepted local Stop remains authoritative until
                        // the next successful catalog refresh.
                    }
                }
            },
            onBotModeChange: { [weak catalog] roomID, memberIDs in
                catalog?.convertToBotMode(sessionID: session.id, memberIDs: memberIDs, roomID: roomID) ?? false
            },
            onBotModeChangeWithHistory: { [weak catalog] roomID, memberIDs, privateHistory in
                catalog?.convertToBotMode(
                    sessionID: session.id,
                    memberIDs: memberIDs,
                    roomID: roomID,
                    privateHistory: privateHistory
                ) ?? false
            },
            onBotModeCollapse: { [weak catalog] roomID, remainingAgentID, privateHistory in
                catalog?.convertToDirect(
                    sessionID: session.id,
                    roomID: roomID,
                    remainingAgentID: remainingAgentID,
                    privateHistory: privateHistory
                ) ?? false
            },
            onReferenceStateChange: { [weak self, weak catalog] draft, state in
                guard let self, let catalog, self.accountGeneration == referenceGeneration,
                      let referenceModel, self.chatModels[session.id] === referenceModel,
                      let current = catalog.session(id: session.id),
                      referenceModel.ownsReferenceSession(current) else { throw CancellationError() }
                try catalog.updateReferenceState(canonicalDraft: draft, state: state, for: session.id)
            }
        )
        referenceModel = model
        if let runtime = session.sessionRuntime {
            runtimeControls?.reconcileSessionRuntime(runtime)
        }
        if let snapshot = session.sessionContext {
            model.reconcileSessionContext(snapshot, isLive: false)
        }
        if let snapshot = sessionTodoSnapshots[session.id] {
            model.reconcileTodos(snapshot)
        }
        if let snapshot = session.sessionSubagents {
            model.reconcileSubagents(snapshot)
        }
        if let snapshot = sessionSubagentSnapshots[session.id] {
            model.reconcileSubagents(snapshot)
        }
        model.setTranscriptPresentationDeferred(defersChatPresentation)
        chatModels[session.id] = model
        noteNativeModelUse(session.id)
        conversationPrepared(model, conversationClient)
        if let runtimeControls, session.remoteStoredID != nil || session.hasAcceptedMessage {
            scheduleCurrentReasoning(
                sessionID: session.id,
                controls: runtimeControls
            )
        }
        if let runtimeControls, agentRuntimeDefaults != nil {
            scheduleAgentRuntimeDefaults(
                sessionID: session.id,
                agentID: agentID,
                controls: runtimeControls
            )
        }
        return model
    }

    private func scheduleCurrentReasoning(
        sessionID: String,
        controls: SessionRuntimeControlModel
    ) {
        Task { @MainActor [weak self, weak controls] in
            guard let self, let controls,
                  self.chatModels[sessionID]?.runtimeControls === controls else { return }
            await controls.loadReasoningPickerIfNeeded()
        }
    }

    private func scheduleAgentRuntimeDefaults(
        sessionID: String,
        agentID: String,
        controls: SessionRuntimeControlModel
    ) {
        guard let agentRuntimeDefaults else { return }
        Task { @MainActor [weak self, weak controls] in
            guard let self, let controls else { return }
            for attempt in 0...self.runtimeDefaultsRetryDelays.count {
                do {
                    let defaults = try await agentRuntimeDefaults.loadDefaults(
                        agentID: agentID
                    )
                    guard self.chatModels[sessionID]?.runtimeControls === controls else {
                        return
                    }
                    controls.seedAgentDefaults(defaults[.mainChats])
                    if let providers = agentRuntimeDefaults.cachedModelProviders(agentID: agentID) {
                        controls.seedCachedModelProviders(providers)
                    }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard attempt < self.runtimeDefaultsRetryDelays.count else {
                        controls.markAgentDefaultsLoadFailed()
                        return
                    }
                    do {
                        try await Task.sleep(for: self.runtimeDefaultsRetryDelays[attempt])
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func prepareBotModeRoom(for session: SessionRecord) -> String? {
        guard session.kind == .botMode, let botModeRooms, !session.agentIDs.isEmpty else { return nil }
        let roomID = session.botModeRoomID ?? "bot-\(session.id)"
        if botModeRooms.room(id: roomID) != nil { return roomID }
        try? BotModeRoomLoadingPolicy.load(
            botModeRooms,
            for: .automaticRestore
        )
        if botModeRooms.room(id: roomID) != nil { return roomID }

        let handles = AgentHandle.directory(for: session.agentIDs.compactMap { id in
            agents?.profiles.first(where: { $0.id == id })
        })
        let members = session.agentIDs.map { id in
            let handle = handles.first(where: { $0.profileID == id })?.handle ?? AgentHandle.normalized(id)
            return BotModeMember(profileID: id, handle: handle, sessionID: "\(roomID)-\(id)")
        }
        let allowedAgentIDs = Set(session.agentIDs)
        let canonicalEvents = session.items.compactMap { item -> BotModeEvent? in
            if item.role == .assistant, item.sender.kind == .agent, !allowedAgentIDs.contains(item.sender.id) {
                return nil
            }
            return BotModeEvent.privateContextEvent(from: item)
        }
        let memberContexts = Dictionary(uniqueKeysWithValues: members.map { member in
            (
                member.profileID,
                BotModeMemberContext(
                    sessionID: member.sessionID,
                    messages: canonicalEvents
                )
            )
        })
        guard let room = try? BotModeRoom(
            id: roomID,
            directSessionID: nil,
            members: members,
            privateHistory: session.botModePrivateHistory,
            visibleEvents: [.botModeStarted(id: "bot-mode-started-\(session.id)")] + canonicalEvents,
            memberContexts: memberContexts
        ) else { return nil }
        do {
            try botModeRooms.persist(room: room)
        } catch {
            return nil
        }
        return roomID
    }

    private func approvalModel(
        for request: ApprovalRequest,
        allowedDecisions: Set<ApprovalDecision> = [.once, .deny]
    ) -> ApprovalModel {
        if let existing = approvalModels[request.id] {
            return existing
        }

        let model = ApprovalModel(
            request: request,
            allowedDecisions: allowedDecisions,
            client: approvalClient ?? ApprovalFixtureClient(confirmationDelay: timing.approvalDelay)
        )
        approvalModels[request.id] = model
        return model
    }

    func makeVoicePresentation(
        for conversationID: String,
        mode: VoiceMode = .pressToTalk,
        transcription: VoiceTranscriptionSource = .onDevice,
        conversationMode: VoiceConversationMode = .codexLive,
        liveProvider: LiveVoiceProvider = .codexSubscription,
        liveVoice: String = LiveVoiceProvider.codexSubscription.defaultVoice
    ) -> VoicePresentation {
        let sequence = voiceSessionSequences[conversationID, default: 0] + 1
        voiceSessionSequences[conversationID] = sequence

        let session = catalog.session(id: conversationID)
        let agent = session?.agentIDs.first.flatMap { agentID in
            agents?.profiles.first(where: { $0.id == agentID })
        }
        let client: any VoiceSessionClient
        if let session, let voiceClientFactory {
            client = voiceClientFactory(session, agent)
        } else {
            client = VoiceFixtureClient(confirmationDelay: timing.voiceDelay)
        }
        let initialTranscript = voiceClientFactory == nil
            ? VoiceFixture.transcript
            : Self.voiceTranscript(from: session?.items ?? [])

        activeLiveVoice?.invalidateOwner()
        let liveModel = conversationMode == .codexLive
            ? session.flatMap { liveVoiceFactory?($0, agent, chatModel(for: $0)) }
            : nil
        liveModel?.configure(provider: liveProvider, voice: liveVoice)
        activeLiveVoice = liveModel
        return VoicePresentation(
            id: "\(conversationID)-voice-\(sequence)",
            model: VoiceModel(
                conversationID: conversationID,
                agentName: agent?.name ?? "bighelp",
                status: (chatModels[conversationID]?.isSending == true || session?.isActive == true) ? .working : .listening,
                isAgentRunActive: chatModels[conversationID]?.isSending == true || session?.isActive == true,
                mode: mode,
                transcription: transcription,
                client: client,
                inputLevelSource: voiceInputLevelSource(),
                transcriptRows: initialTranscript,
                userName: { [weak userIdentity] in userIdentity?.identity.displayName ?? UserIdentity.placeholderName },
                onStartedTurn: { [weak self] transcript in
                    self?.acceptVoiceTurnStarted(
                        transcript: transcript,
                        conversationID: conversationID
                    )
                },
                onSteeredTurn: { [weak self] transcript in
                    self?.acceptVoiceTurnStarted(transcript: transcript, conversationID: conversationID, isSteering: true)
                },
                onCompletedTurn: { [weak self] transcript, reply in
                    self?.acceptVoiceTurn(
                        transcript: transcript,
                        reply: reply,
                        conversationID: conversationID
                    )
                },
                onFailedTurn: { [weak self] in
                    self?.catalog.markInactiveAfterAuthoritativeTerminal(
                        id: conversationID
                    )
                    self?.chatModels[conversationID]?
                        .finishExternallyOwnedTurnWithoutReply()
                },
                holdMusic: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                    ? AVAudioPlayerHoldMusic() : nil
            ),
            conversationMode: conversationMode,
            liveModel: liveModel
        )
    }

    private func acceptVoiceTurn(
        transcript: String,
        reply: VoiceAgentReply,
        conversationID: String
    ) {
        _ = transcript
        if let model = chatModels[conversationID] {
            model.acceptAuthoritativeTerminalForExternallyOwnedTurn(reply.timelineItems)
        } else {
            acceptExternal(reply.timelineItems, conversationID: conversationID)
        }
        catalog.markInactiveAfterAuthoritativeTerminal(id: conversationID)
    }

    private func acceptVoiceTurnStarted(
        transcript: String,
        conversationID: String,
        isSteering: Bool = false
    ) {
        let identity = userIdentity?.identity ?? UserIdentity(name: "", avatarFileName: nil)
        let human = TimelineItem(
            id: "voice-user-\(UUID().uuidString.lowercased())",
            role: .human,
            sender: .user(snapshot: .init(name: identity.displayName, avatarFileName: identity.avatarFileName)),
            content: .message(transcript),
            metadata: .init(source: "Voice", freshness: "Just now", delivery: "Sent", timestamp: Date())
        )
        if let model = chatModels[conversationID] {
            if isSteering { model.acceptExternal([human]) }
            else { model.beginExternallyOwnedTurn(with: human) }
        } else {
            catalog.accept(human, for: conversationID)
        }
        if !isSteering { catalog.markActiveForLocalTurn(id: conversationID) }
    }

    private static func voiceTranscript(from items: [TimelineItem]) -> [VoiceTranscriptRow] {
        items.suffix(8).compactMap { item in
            guard case .message(let text) = item.content else { return nil }
            return VoiceTranscriptRow(
                id: "voice-history-\(item.id)",
                speaker: item.sender.snapshot.name,
                time: "Recent",
                text: text
            )
        }
    }
}

private enum ApprovalFixtureCatalog {
    static func request(id: String) -> ApprovalRequest? {
        switch id {
        case ApprovalRequest.vendorFixture.id:
            .vendorFixture
        default:
            nil
        }
    }
}
