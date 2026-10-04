import SwiftUI
import UIKit

/// A host-owned runtime control; presentation never grants transport authority.
struct ChatSessionControlAccessory {
    let title: String
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void
}

/// The ⋯ menu's model group, top to bottom: which model, how full its
/// context window is, and the plans behind it. A missing part drops its item.
enum ChatOptionsModelMenuItem: Hashable {
    case modelAndReasoning
    case contextWindow
    case providerUsage

    static func items(hasModelControls: Bool, showsContextWindow: Bool, showsProviderUsage: Bool) -> [Self] {
        [hasModelControls ? .modelAndReasoning : nil,
         showsContextWindow ? .contextWindow : nil,
         showsProviderUsage ? .providerUsage : nil].compactMap { $0 }
    }
}

struct ChatHeaderLiveActivityPresentation: Equatable {
    let text: String
    let lineLimit = 1
    let maximumWidth: CGFloat = 240
    let shimmers = true
    let usesOwnSurface = false

    static func resolve(phrase: String?, isActive: Bool) -> Self? {
        guard isActive,
              let text = phrase?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return Self(text: text)
    }
}

/// Owner-fenced dependencies for editing the profile that owns this chat.
///
/// The presenting composition root supplies the exact profile and authority
/// check. `ChatView` owns only the sheet, so opening the editor never replaces
/// the retained chat route or its draft.
@MainActor
struct ChatAgentEditorPresentation {
    let profileID: String
    let store: AgentDirectoryStore
    let runtimeDefaultsClient: (any AgentRuntimeDefaultsClient)?
    let runtimeDefaultsReadOnlyReason: String?
    private let isCurrent: @MainActor () -> Bool
    fileprivate let onCompleted: @MainActor (AgentProfile) -> Void

    init(
        profileID: String,
        store: AgentDirectoryStore,
        runtimeDefaultsClient: (any AgentRuntimeDefaultsClient)? = nil,
        runtimeDefaultsReadOnlyReason: String? = nil,
        isCurrent: @escaping @MainActor () -> Bool,
        onCompleted: @escaping @MainActor (AgentProfile) -> Void = { _ in }
    ) {
        self.profileID = profileID
        self.store = store
        self.runtimeDefaultsClient = runtimeDefaultsClient
        self.runtimeDefaultsReadOnlyReason = runtimeDefaultsReadOnlyReason
        self.isCurrent = isCurrent
        self.onCompleted = onCompleted
    }

    var isAvailable: Bool {
        isCurrent() && store.profiles.contains(where: { $0.id == profileID })
    }

    fileprivate func makeRoute() -> ChatAgentEditorRoute? {
        guard isAvailable,
              let profile = store.profiles.first(where: { $0.id == profileID }) else {
            return nil
        }
        let expectedProfileID = profileID
        let editor = AgentEditorModel.editing(
            profile,
            store: store,
            processor: AvatarImageProcessor(),
            isCurrent: {
                isCurrent()
                    && store.profiles.contains(where: { $0.id == expectedProfileID })
            }
        )
        return ChatAgentEditorRoute(
            model: editor,
            runtimeDefaultsClient: runtimeDefaultsClient,
            runtimeDefaultsReadOnlyReason: runtimeDefaultsReadOnlyReason,
            onCompleted: onCompleted
        )
    }
}

@MainActor
private struct ChatAgentEditorRoute: Identifiable {
    let id = UUID()
    let model: AgentEditorModel
    let runtimeDefaultsClient: (any AgentRuntimeDefaultsClient)?
    let runtimeDefaultsReadOnlyReason: String?
    let onCompleted: @MainActor (AgentProfile) -> Void
}

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.providerUsage) private var providerUsage
    @Environment(\.companionStore) private var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope
    @Environment(\.agentHomeChrome) private var homeChrome
    @Environment(\.teamCallAction) private var teamCallAction
    private enum SessionTitleDialog {
        case rename
        case error
    }

    enum HeaderControlAlignmentPolicy {
        case sharedCenterAxis

        func controlCenterY(rowHeight: CGFloat, controlHeight: CGFloat) -> CGFloat {
            ((rowHeight - controlHeight) / 2) + (controlHeight / 2)
        }
    }

    let model: ChatModel
    let sessionAppearance: SessionAppearanceSnapshot
    let onForceRefresh: (@MainActor () async throws -> Void)?
    let foldCompletedTurns: Bool
    let showsHeader: Bool
    let sessionControlAccessory: ChatSessionControlAccessory?
    let workspaceButtonLabel: String
    let agentName: String
    let agentRole: String
    let agentStatus: String
    let identityParticipants: [ChatIdentityParticipant]?
    let agents: AgentDirectoryStore?
    let agentEditorPresentation: ChatAgentEditorPresentation?
    let dashboardModel: DashboardModel?
    let directHermesClient: DirectHermesConversationClient?
    let directHermesClarifications: [DirectHermesPrompt]
    let sessionCatalog: SessionCatalogStore?
    let senderResolver: TimelineSenderResolver
    let allModelsRequest: Int
    let projectChangesSummary: ProjectChangesRailSummary?
    let composerFocusRequest: Int
    let onAttachmentTap: (() -> Void)?
    let onProjectChangesTap: () -> Void
    let onVoiceTap: () -> Void
    let onApprovalTap: (ApprovalRequest) -> Void
    let onPeopleTap: () -> Void
    /// This chat's files, look and (Nerd Mode) Hermes session tools, from the ⋯ menu.
    /// Nil leaves the item out.
    let onChatFilesTap: (() -> Void)?
    let onChatAppearanceTap: (() -> Void)?
    let onSessionToolsTap: (() -> Void)?
    let onWorkspaceTap: () -> Void
    let showsWorkspaceButton: Bool
    let onNewChatTap: () -> Void
    let onLoadPreviousMessages: () -> Void
    let onForkMessage: ((String) -> Void)?
    let referenceHub: ReferenceHubStore?
    let referenceSkills: SkillsAndToolsStore?
    let onReferenceSend: ((ReferenceFrozenDraft, MidSessionChatBehavior?) async -> Void)?
    @State private var fallbackReferenceHub = ReferenceHubStore(owner: nil, providers: [])
    @State private var isChatVisible = false

    @State private var isSessionControlsPresented = false
    @State private var isContextWindowPresented = false
    /// Change in the context pop-up: open Model & reasoning once the pop-up is gone.
    @State private var opensModelControlsAfterContext = false
    #if targetEnvironment(macCatalyst)
    /// The Mac's Model & reasoning pop-up hangs from what opened it: the ⋯
    /// button, or the message box for requests from elsewhere (the context
    /// window, chat Info, the agent's profile).
    private enum SessionControlsOrigin { case options, composer }
    @State private var sessionControlsOrigin = SessionControlsOrigin.options
    @State private var sessionControlsPath: [ChatSessionControlsPage] = []
    @State private var optionsButtonBottom: CGFloat = 0
    @State private var canvasWidth: CGFloat = 0
    #endif
    @State private var agentEditorRoute: ChatAgentEditorRoute?
    @State private var sessionTitleDialog: SessionTitleDialog?
    @State private var sessionTitleDraft = ""
    @State private var sessionTitleErrorMessage = ""
    @State private var isRenamingSessionTitle = false
    @State private var isAllModelsPresented = false
    @State var timelineController = ChatTimelineController()
    @State var fittingRailScrollRequest = ChatRailScrollRequest()
    @State private var companionCompletionTracker = CompanionCompletionTracker()
    @State private var companionReaction: CompanionReaction = .idle
    @State private var companionCelebrationTask: Task<Void, Never>?
    @State private var companionAffectionTask: Task<Void, Never>?
    @State private var companionIsCelebrating = false
    @State private var isDraftFocused = false
    @State private var composerFocusTask: Task<Void, Never>?
    @State private var isForceRefreshing = false
    @State private var refreshGeneration: UUID?
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshError: String?
    @State var headerHeight: CGFloat = 0
    /// Full screen height, for the Auto avatar size.
    @State private var screenHeight: CGFloat = 0
    @State private var bottomSafeArea: CGFloat = 0
    @AppStorage(ChatLayoutPreferences.densityKey) var chatDensity: ChatDensity = .comfortable
    @State var composerHeight: CGFloat = 0

    init(
        model: ChatModel,
        agentName: String = "Avery Park",
        agentRole: String = "Finance agent",
        agentStatus: String = "Hermes",
        identityParticipants: [ChatIdentityParticipant]? = nil,
        agents: AgentDirectoryStore? = nil,
        agentEditorPresentation: ChatAgentEditorPresentation? = nil,
        dashboardModel: DashboardModel? = nil,
        directHermesClient: DirectHermesConversationClient? = nil,
        directHermesClarifications: [DirectHermesPrompt] = [],
        sessionCatalog: SessionCatalogStore? = nil,
        senderResolver: TimelineSenderResolver = TimelineSenderResolver(),
        allModelsRequest: Int = 0,
        projectChangesSummary: ProjectChangesRailSummary? = nil,
        composerFocusRequest: Int = 0,
        onAttachmentTap: (() -> Void)? = nil,
        onProjectChangesTap: @escaping () -> Void = {},
        onVoiceTap: @escaping () -> Void = {},
        onApprovalTap: @escaping (ApprovalRequest) -> Void = { _ in },
        onPeopleTap: @escaping () -> Void = {},
        onChatFilesTap: (() -> Void)? = nil,
        onChatAppearanceTap: (() -> Void)? = nil,
        onSessionToolsTap: (() -> Void)? = nil,
        onWorkspaceTap: @escaping () -> Void = {},
        showsWorkspaceButton: Bool = true,
        onNewChatTap: @escaping () -> Void = {},
        onLoadPreviousMessages: @escaping () -> Void = {},
        onForkMessage: ((String) -> Void)? = nil,
        referenceHub: ReferenceHubStore? = nil,
        referenceSkills: SkillsAndToolsStore? = nil,
        onReferenceSend: ((ReferenceFrozenDraft, MidSessionChatBehavior?) async -> Void)? = nil,
        foldCompletedTurns: Bool = true,
        showsHeader: Bool = true,
        sessionControlAccessory: ChatSessionControlAccessory? = nil,
        workspaceButtonLabel: String = "Open Quick Workspace",
        sessionAppearance: SessionAppearanceSnapshot = .inherited,
        onForceRefresh: (@MainActor () async throws -> Void)? = nil
    ) {
        self.model = model
        self.sessionAppearance = sessionAppearance
        self.onForceRefresh = onForceRefresh
        self.foldCompletedTurns = foldCompletedTurns
        self.showsHeader = showsHeader
        self.sessionControlAccessory = sessionControlAccessory
        self.workspaceButtonLabel = workspaceButtonLabel
        self.agentName = agentName
        self.agentRole = agentRole
        self.agentStatus = agentStatus
        self.identityParticipants = identityParticipants
        self.agents = agents
        self.agentEditorPresentation = agentEditorPresentation
        self.dashboardModel = dashboardModel
        self.directHermesClient = directHermesClient
        self.directHermesClarifications = directHermesClarifications
        self.sessionCatalog = sessionCatalog
        self.senderResolver = senderResolver
        self.allModelsRequest = allModelsRequest
        self.projectChangesSummary = projectChangesSummary
        self.composerFocusRequest = composerFocusRequest
        self.onAttachmentTap = onAttachmentTap
        self.onProjectChangesTap = onProjectChangesTap
        self.onVoiceTap = onVoiceTap
        self.onApprovalTap = onApprovalTap
        self.onPeopleTap = onPeopleTap
        self.onChatFilesTap = onChatFilesTap
        self.onChatAppearanceTap = onChatAppearanceTap
        self.onSessionToolsTap = onSessionToolsTap
        self.onWorkspaceTap = onWorkspaceTap
        self.showsWorkspaceButton = showsWorkspaceButton
        self.onNewChatTap = onNewChatTap
        self.onLoadPreviousMessages = onLoadPreviousMessages
        self.onForkMessage = onForkMessage
        self.referenceHub = referenceHub
        self.referenceSkills = referenceSkills
        self.onReferenceSend = onReferenceSend
    }

    @Environment(\.nerdModeEnabled) private var nerdModeEnabled

    var body: some View {
        let _ = model.botModeRoomStore?.rooms
        // Track the connection capability stamp in the presenting view, not
        // only inside the retained sheet closure, so reconnect updates it.
        let runtimeSupport = model.runtimeControls?.selectionSupport
        return chatCanvas
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                theme.canvas
                SessionAppearanceBackgroundView(snapshot: sessionAppearance)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isAllModelsPresented) {
            if let controls = model.runtimeControls {
                allModelsPicker(controls, support: runtimeSupport)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $agentEditorRoute) { route in
            AgentEditorView(
                model: route.model,
                runtimeDefaultsClient: route.runtimeDefaultsClient,
                runtimeDefaultsReadOnlyReason: route.runtimeDefaultsReadOnlyReason
            ) { profile in
                route.onCompleted(profile)
                agentEditorRoute = nil
            }
        }
        .environment(\.bighelpUIV3Enabled, true)
        .environment(\.bighelpUIV2Enabled, true)
        .environment(\.chatActivityDisclosureStore, model.activityDisclosures)
        .onAppear {
            isChatVisible = true
            BighelpVisibleChats.shared.appeared(model)
            ChatPDFPagesDraftRegistry.mount(model)
            model.nativeSessionResumeProgress.mount()
        }
        .onChange(of: allModelsRequest) { _, request in
            guard request > 0, let controls = model.runtimeControls else { return }
            guard !ChatRuntimeSelectionLockout.isLocked(isTurnActive: controls.isTurnActive) else {
                return
            }
            #if targetEnvironment(macCatalyst)
            sessionControlsPath = [.allModels]
            openSessionControls(controls)
            #else
            isSessionControlsPresented = false
            isAllModelsPresented = true
            Task { @MainActor in await controls.loadPickersIfNeeded() }
            #endif
        }
        .onChange(of: model.sessionControlsRequest) { _, _ in
            guard let controls = model.runtimeControls,
                  !ChatRuntimeSelectionLockout.isLocked(isTurnActive: controls.isTurnActive) else { return }
            // The sheet or pop-up that asked is still closing; present after it's gone.
            Task { @MainActor in
                #if targetEnvironment(macCatalyst)
                await Self.presentationsSettled()
                sessionControlsOrigin = .composer
                #else
                try? await Task.sleep(for: .milliseconds(450))
                #endif
                openSessionControls(controls)
            }
        }
        .onChange(of: composerFocusRequest) { _, request in
            scheduleComposerFocusIfRequested(request)
        }
        .onChange(of: companionSignal, initial: true) { _, signal in
            reconcileCompanion(signal)
        }
        .onChange(of: model.nativeAffectionReaction) { _, signal in
            guard isChatVisible, companionStore?.isEnabled == true, !companionIsCelebrating,
                  NativeAffectionReactionPresentation.companionReaction(for: signal) == .attention else { return }
            companionAffectionTask?.cancel()
            companionReaction = .attention
            companionAffectionTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard isChatVisible, !companionIsCelebrating else { return }
                companionReaction = companionSignal.baselineReaction
            }
        }
        .onChange(of: model.companionHistoryRevision) { _, _ in
            companionAffectionTask?.cancel()
            companionAffectionTask = nil
            companionCompletionTracker = CompanionCompletionTracker()
            companionCelebrationTask?.cancel()
            companionCelebrationTask = nil
            companionIsCelebrating = false
            companionReaction = companionSignal.baselineReaction
        }
        .onChange(of: companionStore?.isEnabled) { _, enabled in
            companionAffectionTask?.cancel()
            companionAffectionTask = nil
            companionCompletionTracker = CompanionCompletionTracker()
            guard enabled != true else {
                reconcileCompanion(companionSignal)
                return
            }
            companionCelebrationTask?.cancel()
            companionCelebrationTask = nil
            companionIsCelebrating = false
            companionReaction = .idle
        }
        .onDisappear {
            refreshGeneration = nil
            refreshTask?.cancel()
            refreshTask = nil
            isForceRefreshing = false
            refreshError = nil
            isChatVisible = false
            BighelpVisibleChats.shared.disappeared(model)
            ChatPDFPagesDraftRegistry.unmount(model)
            model.nativeSessionResumeProgress.unmount()
            companionAffectionTask?.cancel()
            companionAffectionTask = nil
            composerFocusTask?.cancel()
            composerFocusTask = nil
            isDraftFocused = false
            companionCelebrationTask?.cancel()
            companionCelebrationTask = nil
            companionIsCelebrating = false
            companionReaction = companionSignal.baselineReaction
            companionCompletionTracker = CompanionCompletionTracker()
        }
        .alert("Refresh failed", isPresented: Binding(get: { refreshError != nil }, set: { if !$0 { refreshError = nil } })) {
            Button("OK") { refreshError = nil }
        } message: { Text(refreshError ?? "") }
        .onChange(of: sessionTitleDraft) { _, value in
            if value.count > SessionTitleRules.maximumLength {
                sessionTitleDraft = String(value.prefix(SessionTitleRules.maximumLength))
            }
        }
        .alert(
            sessionTitleDialog == .rename ? "Rename chat" : "Rename failed",
            isPresented: sessionTitleDialogIsPresented,
            presenting: sessionTitleDialog
        ) { dialog in
            switch dialog {
            case .rename:
                TextField("Session name", text: $sessionTitleDraft)
                    .accessibilityIdentifier("chat.session-title.rename-field")
                Button("Cancel", role: .cancel) {}
                Button("Save") { renameCurrentSession() }
                    .accessibilityIdentifier("chat.session-title.rename-save")
            case .error:
                Button("OK", role: .cancel) {}
            }
        } message: { dialog in
            switch dialog {
            case .rename:
                Text("Enter a name up to \(SessionTitleRules.maximumLength) characters.")
            case .error:
                Text(sessionTitleErrorMessage)
            }
        }
    }

    private var companionSignal: CompanionChatSignal {
        let events = model.activityLedger.allEvents
        var runningIDs = Set(events.filter { $0.lifecycle == .running }.map(\.id))
        if model.isSending { runningIDs.insert("sending:\(model.conversationID)") }

        var successIDs = Set(events.compactMap { event -> String? in
            guard event.lifecycle == .succeeded,
                  event.kind == .subagent || event.kind == .botHandoff else { return nil }
            return event.id
        })
        if let taskDrawer = model.taskDrawer {
            for task in taskDrawer.items {
                let id = "task:\(model.conversationID):\(taskDrawer.turnID):\(task.id)"
                if task.status == .completed { successIDs.insert(id) }
                if task.status == .inProgress { runningIDs.insert(id) }
            }
        }
        if let goal = model.sessionGoal {
            let id = "goal:\(goal.storedSessionID)"
            if goal.status == .done { successIDs.insert(id) }
            if goal.status == .active { runningIDs.insert(id) }
        }
        return CompanionChatSignal(
            clarificationIDs: Set(chatClarifications.map(\.id)),
            runningIDs: runningIDs,
            meaningfulSuccessIDs: successIDs
        )
    }

    private func companionAppearance(from store: CompanionStore) -> CompanionAppearance {
        guard let agentID = chatClarifications.first?.agentID ?? model.memberIDs.first,
              !companionAgentScope.isEmpty else {
            return store.defaultAppearance
        }
        return store.appearance(
            for: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: agentID)
        )
    }

    private func reconcileCompanion(_ signal: CompanionChatSignal) {
        let shouldCelebrate = companionCompletionTracker.consume(
            signal, historyRevision: model.companionHistoryRevision,
            enabled: companionStore?.isEnabled == true
        )

        if !signal.clarificationIDs.isEmpty {
            companionCelebrationTask?.cancel()
            companionCelebrationTask = nil
            companionIsCelebrating = false
            companionReaction = .question
            return
        }
        guard companionStore?.isEnabled == true else { return }
        if shouldCelebrate {
            companionCelebrationTask?.cancel()
            companionIsCelebrating = true
            companionReaction = .celebrate
            companionCelebrationTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: CompanionReactionDuration.chatCelebration)
                } catch {
                    return
                }
                companionIsCelebrating = false
                companionReaction = companionSignal.baselineReaction
                companionCelebrationTask = nil
            }
        } else if !companionIsCelebrating {
            companionReaction = signal.baselineReaction
        }
    }

    /// The session identity row. The title sits on the header's centre axis so
    /// it reads as a caption for the model chip directly above it, while the
    /// context ring keeps a stable trailing position that never competes with
    /// the primary header actions for width.

    private var sessionTitleDialogIsPresented: Binding<Bool> {
        Binding(
            get: { sessionTitleDialog != nil },
            set: { if !$0 { sessionTitleDialog = nil } }
        )
    }

    // The viewport extends beneath native glass. Only the table owns content
    // insets; overlay heights do not reserve a second SwiftUI scroll region.
    private var chatCanvas: some View {
        timeline
            #if os(visionOS)
            // The window is see-through, so a canvas-colored band can't hide
            // messages under the header; they fade out before reaching it instead.
            .mask {
                VStack(spacing: 0) {
                    Color.clear.frame(height: max(headerHeight - 24, 0))
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 32)
                    Color.black
                    // Same at the bottom, so nothing peeks around the message box.
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                    Color.clear.frame(height: max(composerHeight - 20, 0))
                }
                .ignoresSafeArea()
            }
            #endif
            .overlay(alignment: .top) {
                floatingHeader
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    Spacer(minLength: headerHeight)
                    VStack(spacing: 0) {
                        composer
                            .fixedSize(horizontal: false, vertical: !(referenceHub ?? fallbackReferenceHub).isPresented)
                            #if targetEnvironment(macCatalyst)
                            .popover(isPresented: sessionControlsPresented(from: .composer)) { macSessionControls }
                            #endif
                        // Chats keep the bottom bar under the composer.
                        if homeChrome.isEnabled, homeChrome.showsTabBar, let selection = homeChrome.tabSelection,
                           !isDraftFocused, !BighelpPlatform.usesTabOrnament {
                            FloatingTabBar(selection: selection,
                                           homeIndicatorSink: FloatingTabBar.homeIndicatorSink(forBottomInset: bottomSafeArea),
                                           unread: homeChrome.unreadTabs, isInChat: true)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            #if os(visionOS)
            // Chats keep Vision Pro's tab strip beside the window.
            .ornament(visibility: homeChrome.isEnabled && homeChrome.showsTabBar && homeChrome.tabSelection != nil
                          ? .visible : .hidden,
                      attachmentAnchor: .scene(.leading), contentAlignment: .trailing) {
                if let selection = homeChrome.tabSelection {
                    VisionTabOrnament(selection: selection, unread: homeChrome.unreadTabs, isInChat: true)
                }
            }
            #endif
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            } action: { screenHeight = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeArea = $0 }
            #if targetEnvironment(macCatalyst)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasWidth = $0 }
            #endif
    }

    /// Each control samples the transcript, never an opaque toolbar slab.
    /// The table alone reserves the measured header and composer insets.
    private var floatingHeader: some View {
        Group {
            if homeChrome.isEnabled {
                homeHeader
            } else {
                standardHeader
            }
        }
        .background(alignment: .bottom) { sessionControlsAnchor }
        .foregroundStyle(theme.primaryText)
        // The home header's buttons carry their own touch margin.
        .padding(.horizontal, (BighelpPlatform.usesTabOrnament ? 22 : 12)
                 - (homeChrome.isEnabled ? HeaderButtonMetrics.slop : 0))
        // Vision Pro's rounded window corner clipped ☰; keep it clear.
        .padding(.top, BighelpPlatform.usesTabOrnament ? 12 : max(0, 4 - (homeChrome.isEnabled ? HeaderButtonMetrics.slop : 0)))
        .padding(.bottom, 8)
        #if !os(visionOS)
        .background(alignment: .top) {
            // Messages scroll beneath the header. A short fade in the canvas
            // color keeps the name chip readable without an opaque bar.
            // The taller home header (big avatar) needs a solid band behind it.
            LinearGradient(stops: [
                .init(color: theme.canvas, location: 0),
                .init(color: theme.canvas.opacity(homeChrome.isEnabled ? 1 : 0.92),
                      location: homeChrome.isEnabled ? 0.72 : 0.55),
                .init(color: theme.canvas.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .padding(.bottom, -24)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #endif
    }

    /// Chat tab: the agent's live avatar leads, like a home screen.
    private var homeHeader: some View {
        let participant = resolvedIdentityParticipants.first
        return AgentHomeChatHeader(
            agentID: participant?.stableID ?? model.memberIDs.first ?? agentName,
            displayName: agentName,
            imageURL: participant?.imageURL,
            activity: model.liveActivityKind,
            // Coming back reloads the chat from Hermes; say so while it catches up.
            status: isChatVisible && model.isRefreshingFromHost && !model.isSending ? "Updating…" : nil,
            groupIdentity: model.isBotMode ? AnyView(conversationHeader) : nil,
            options: AnyView(chatOptionsMenu),
            chrome: homeChrome,
            screenHeight: screenHeight,
            beforeAction: dismissKeyboard,
            onBack: { dismiss() }
        )
    }

    private var standardHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    dismissKeyboard()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.bighelp(.title3).weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("chat.back")
            }
            .frame(width: 92, alignment: .leading)
            conversationHeader.frame(maxWidth: .infinity)
            HStack(spacing: 4) {
                Button(action: onNewChatTap) {
                    Image(systemName: "square.and.pencil")
                        .font(.bighelp(.title3))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("chat.new-chat")
                chatOptionsMenu
                    .bighelpNavigationGlass(in: Circle(), isInteractive: true)
            }
            .frame(width: 92, alignment: .trailing)
        }
    }

    private var composer: some View {
        ChatComposer(
            model: model,
            agentName: agentName,
            sessionCatalog: sessionCatalog,
            onAttachmentTap: attachmentAction,
            onVoiceTap: dismissKeyboardAndOpenVoice,
            onFittingRailVerticalDrag: requestFittingRailScroll,
            draftFocus: $isDraftFocused,
            onDismissKeyboard: dismissKeyboard,
            onWillSend: { timelineController.scrollToLatest(animated: false) },
            companionAppearance: companionStore.flatMap { store in
                store.isEnabled ? companionAppearance(from: store) : nil
            },
            companionReaction: companionReaction,
            companionSizeScale: companionStore?.sizeScale ?? 1,
            companionIsAdventurous: companionStore?.isAdventurous == true,
            referenceHub: referenceHub ?? fallbackReferenceHub,
            referenceSkills: referenceSkills,
            onReferenceSend: onReferenceSend
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func presentSessionTitleRename() {
        guard sessionCatalog != nil, !isRenamingSessionTitle else { return }
        sessionTitleDraft = model.sessionTitle
        sessionTitleDialog = .rename
    }

    private func renameCurrentSession() {
        guard let sessionCatalog, !isRenamingSessionTitle else { return }
        isRenamingSessionTitle = true
        Task { @MainActor in
            defer { isRenamingSessionTitle = false }
            do {
                let title = try SessionTitleRules.validated(sessionTitleDraft)
                try await sessionCatalog.renameSession(id: model.conversationID, title: title)
                model.applyRenamedSessionTitle(title)
            } catch is CancellationError {
                return
            } catch SessionCatalogError.invalidTitle {
                sessionTitleErrorMessage = "Enter a session name between 1 and \(SessionTitleRules.maximumLength) characters."
                sessionTitleDialog = .error
            } catch {
                sessionTitleErrorMessage = "bighelp could not rename this session. Try again."
                sessionTitleDialog = .error
            }
        }
    }

    /// Native navigation owns the back gesture and toolbar safe area.
    private var conversationHeader: some View {
        Group {
            if model.isBotMode {
                VStack(spacing: 6) {
                    groupConversationIdentityButton
                    if let teamCallAction { TeamCallHeaderButton(action: teamCallAction) }
                }
            } else {
                conversationIdentityButton
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.header-surface")
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }

    /// Model & reasoning, from the ⋯ menu. Anchored to whichever header shows
    /// (the agent-home header has no small identity button). The Mac hangs it
    /// from the ⋯ button itself (`macSessionControls`).
    private var sessionControlsAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            #if targetEnvironment(macCatalyst)
            .onChange(of: isSessionControlsPresented) { _, presented in
                guard !presented else { return }
                sessionControlsPath = []
                sessionControlsOrigin = .options
            }
            #else
            .popover(isPresented: $isSessionControlsPresented, arrowEdge: .top) {
                if let controls = model.runtimeControls {
                    ChatSessionControlsPopover(
                        controls: controls,
                        usesWideLayout: horizontalSizeClass == .regular,
                        onSeeAllModels: showAllModels,
                        onApplied: { isSessionControlsPresented = false }
                    )
                    .presentationCompactAdaptation(.popover)
                }
            }
            #endif
            // Hermes takes a new model or level on the next turn, so a turn that
            // starts closes the picker rather than promise a change mid-answer.
            .onChange(of: model.runtimeControls?.isTurnActive) { _, active in
                if active == true {
                    isSessionControlsPresented = false
                    isAllModelsPresented = false
                }
            }
            .accessibilityHidden(true)
    }

    #if targetEnvironment(macCatalyst)
    /// Presented from `origin` only, so the ⋯ button and the message box never both show it.
    private func sessionControlsPresented(from origin: SessionControlsOrigin) -> Binding<Bool> {
        Binding(
            get: { isSessionControlsPresented && sessionControlsOrigin == origin && model.runtimeControls != nil },
            set: { if !$0 { isSessionControlsPresented = false } }
        )
    }

    /// One pop-up for the Mac: quick choices and reasoning, with every model
    /// pushed inside it instead of closing it for a sheet.
    @ViewBuilder
    private var macSessionControls: some View {
        if let controls = model.runtimeControls {
            ChatSessionControlsMacPopover(
                controls: controls,
                path: $sessionControlsPath,
                size: sessionControlsSize,
                onApplied: { isSessionControlsPresented = false }
            ) {
                allModelsPicker(controls, support: controls.selectionSupport, isEmbedded: true) {
                    isSessionControlsPresented = false
                }
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    /// Fits the window: the room below the ⋯ button, or above the message box.
    private var sessionControlsSize: CGSize {
        let room = sessionControlsOrigin == .options
            ? screenHeight - optionsButtonBottom
            : screenHeight - composerHeight - bottomSafeArea
        let width: CGFloat = canvasWidth > 0 ? min(560, canvasWidth - 32) : 560
        // Leaves the arrow and a margin clear of the window's edge.
        return CGSize(width: width, height: min(620, max(320, room - 48)))
    }

    /// A pop-up presented while a sheet is still closing is dropped. Waits for
    /// whatever is opening or closing to finish (at most a second), instead of a fixed delay.
    private static func presentationsSettled() async {
        for _ in 0..<25 {
            // The first pause also lets the sheet that asked begin to close.
            try? await Task.sleep(for: .milliseconds(40))
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            let isTransitioning = windows.contains { window in
                var controller = window.rootViewController
                while let current = controller {
                    if current.isBeingPresented || current.isBeingDismissed { return true }
                    controller = current.presentedViewController
                }
                return false
            }
            if !isTransitioning { return }
        }
    }
    #endif

    private var conversationIdentityButton: some View {
        Button {
            dismissKeyboard()
            onPeopleTap()
        } label: {
            ChatConversationIdentityLabel(
                title: agentName,
                subtitle: headerLiveActivityPresentation?.text,
                participants: resolvedIdentityParticipants,
                theme: theme,
                subtitleShimmers: headerLiveActivityPresentation?.shimmers == true,
                showsCaption: true,
                liveState: headerLiveState
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat with \(agentName)")
        .accessibilityValue(headerLiveActivityPresentation?.text ?? headerLiveState.label)
        .accessibilityHint("Opens agent and chat details")
        .accessibilityIdentifier("chat.identity")
    }

    /// The header avatar is the agent's live status: working while a turn
    /// runs, replying once its answer is streaming into the transcript.
    private var headerLiveState: AgentLiveState {
        guard model.isSending else { return .idle }
        if case .message(let item)? = model.transcriptEntries.last,
           item.role == .assistant, item.metadata.delivery == "Streaming" {
            return .speaking
        }
        return .thinking
    }

    private var headerLiveActivityPresentation: ChatHeaderLiveActivityPresentation? {
        ChatHeaderLiveActivityPresentation.resolve(
            phrase: currentHeaderActivityPhrase,
            isActive: isChatVisible && model.isSending
        ) ?? ChatHeaderLiveActivityPresentation.resolve(
            // Coming back reloads the chat from Hermes; say so while it catches up.
            phrase: "Updating…",
            isActive: isChatVisible && model.isRefreshingFromHost
        )
    }

    private var currentHeaderActivityPhrase: String? {
        if let phrase = model.nativeConversationClient?.spinnerActivityText {
            return phrase
        }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-test-reasoning-shimmer-header") {
            return "Burning the draft…"
        }
        #endif
        return nil
    }

    private var groupConversationIdentityButton: some View {
        Button {
            dismissKeyboard()
            onPeopleTap()
        } label: {
            ChatConversationIdentityLabel(
                title: model.botModeRoomTitle,
                subtitle: nil,
                participants: resolvedIdentityParticipants,
                theme: theme,
                showsCaption: true,
                memberCount: resolvedIdentityParticipants.count + 1
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.botModeRoomTitle), \(groupParticipantSummary)")
        .accessibilityHint("Opens People and Chat details")
        .accessibilityIdentifier("chat.people")
    }

    private var groupParticipantSummary: String {
        (["You"] + model.nativeRoomParticipants.map(\.displayName)).joined(separator: ", ")
    }

    private func forceRefresh() {
        guard let onForceRefresh, !isForceRefreshing else { return }
        let generation = UUID()
        refreshGeneration = generation
        isForceRefreshing = true
        refreshError = nil
        refreshTask = Task { @MainActor in
            defer {
                if refreshGeneration == generation { isForceRefreshing = false; refreshTask = nil }
            }
            do { try await onForceRefresh() }
            catch is CancellationError { }
            catch {
                if refreshGeneration == generation {
                    refreshError = "The chat could not be refreshed. Your draft and attachments are unchanged. Try again."
                }
            }
        }
    }

    /// Grouped by how often each is needed: where to go, this chat's project
    /// changes, the model (shown, so a glance says which one), this chat, its
    /// agent, then technical tools under Advanced. Dividers (not Sections) group
    /// items so each keeps its accessibility identifier.
    private var chatOptionsMenu: some View {
        Menu {
            if showsWorkspaceButton {
                Button("Go to…", systemImage: "square.grid.2x2", action: dismissKeyboardAndOpenWorkspace)
                    .accessibilityLabel(workspaceButtonLabel)
                    .accessibilityIdentifier("chat.workspace-menu")
            }
            if let changes = projectChangesSummary {
                if showsWorkspaceButton { Divider() }
                Button {
                    dismissKeyboard()
                    onProjectChangesTap()
                } label: {
                    Text("File changes")
                    Text(ProjectChangesRailPresentation.visibleLabels(for: changes).joined(separator: " "))
                    Image(systemName: "plusminus")
                }
                .accessibilityLabel(ProjectChangesRailPresentation.accessibilityLabel(for: changes))
                .accessibilityIdentifier("chat.file-changes")
            }
            if showsWorkspaceButton || projectChangesSummary != nil { Divider() }
            modelMenuItems
            Divider()
            if sessionCatalog != nil {
                Button("Rename chat", systemImage: "pencil", action: presentSessionTitleRename)
                    .disabled(isRenamingSessionTitle)
                    .accessibilityIdentifier("chat.rename")
            }
            if let onChatFilesTap {
                Button("Chat files", systemImage: "folder") {
                    dismissKeyboard()
                    onChatFilesTap()
                }
                .accessibilityIdentifier("chat.files")
            }
            if let onChatAppearanceTap {
                Button("Chat appearance", systemImage: "photo.on.rectangle.angled") {
                    dismissKeyboard()
                    onChatAppearanceTap()
                }
                .accessibilityIdentifier("chat.appearance")
            }
            if !model.isBotMode {
                Divider()
                Button("Edit this agent", systemImage: "person.crop.circle") {
                    presentCurrentAgentEditor()
                }
                .disabled(!canEditCurrentAgent)
                .accessibilityIdentifier("chat.edit-current-agent")
            }
            // Display, recovery and session tools are technical: Nerd Mode only.
            if nerdModeEnabled {
            Divider()
            Menu {
                if let onSessionToolsTap {
                    Button("Session tools", systemImage: "wrench.and.screwdriver") {
                        dismissKeyboard()
                        onSessionToolsTap()
                    }
                    .accessibilityIdentifier("chat.session-tools")
                }
                Toggle(isOn: reasoningVisibilityBinding) {
                    Label("Show reasoning", systemImage: "sparkles")
                }
                .accessibilityHint("Shows or hides Thinking cards for this chat.")
                .accessibilityIdentifier("chat.visibility.reasoning")
                Toggle(isOn: toolCallVisibilityBinding) {
                    Label("Show tool calls", systemImage: "terminal")
                }
                .accessibilityIdentifier("chat.visibility.tool-calls")
                if onForceRefresh != nil {
                    Button(isForceRefreshing ? "Refreshing…" : "Force refresh", systemImage: "arrow.clockwise", action: forceRefresh)
                        .disabled(isForceRefreshing)
                        .accessibilityIdentifier("chat.force-refresh")
                }
            } label: {
                Label("Advanced", systemImage: "gearshape.2")
            }
            .accessibilityIdentifier("chat.options.advanced")
            }
        } label: {
            Image(systemName: "ellipsis")
                #if targetEnvironment(macCatalyst)
                // The same glyph as New chat beside it.
                .font(.bighelp(.title3).weight(homeChrome.isEnabled ? .semibold : .regular))
                #endif
                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .background { contextWindowAnchor }
        #if targetEnvironment(macCatalyst)
        // Drawn like the round buttons beside it, not as a Mac pull-down button.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .popover(isPresented: sessionControlsPresented(from: .options), arrowEdge: .top) { macSessionControls }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { optionsButtonBottom = $0 }
        #endif
        .accessibilityLabel("Conversation options")
        .accessibilityHint(nerdModeEnabled
            ? "Go to, file changes, model, context window, usage, this chat, the agent and advanced options"
            : "Model, usage, this chat and the agent")
        .accessibilityIdentifier("chat.options")
    }

    /// The model shows under its item, so switching starts from knowing which is on.
    private var modelMenuItems: some View {
        let items = ChatOptionsModelMenuItem.items(
            hasModelControls: sessionControlAccessory != nil || model.runtimeControls != nil,
            showsContextWindow: contextWindowSnapshot != nil,
            showsProviderUsage: providerUsage?.isAvailable == true
        )
        return ForEach(items, id: \.self) { item in
            switch item {
            case .modelAndReasoning: modelAndReasoningMenuItem
            case .contextWindow: contextWindowMenuItem
            case .providerUsage: providerUsageMenuItem
            }
        }
    }

    @ViewBuilder
    private var modelAndReasoningMenuItem: some View {
        if let accessory = sessionControlAccessory {
            Button(action: accessory.action) {
                Text("Model & reasoning")
                if let summary = modelSummary { Text(summary) }
                Image(systemName: "slider.horizontal.3")
            }
            .disabled(!accessory.isEnabled || model.isAwaitingAuthoritativeSessionAllocation)
            .accessibilityIdentifier(accessory.accessibilityIdentifier)
        } else if let controls = model.runtimeControls {
            Button {
                openSessionControls(controls)
            } label: {
                Text("Model & reasoning")
                if let summary = modelSummary { Text(summary) }
                Image(systemName: "slider.horizontal.3")
            }
            .disabled(ChatRuntimeSelectionLockout.isLocked(isTurnActive: controls.isTurnActive)
                || model.isAwaitingAuthoritativeSessionAllocation)
            .accessibilityIdentifier("chat.session-controls")
        }
    }

    @ViewBuilder
    private var contextWindowMenuItem: some View {
        if let context = contextWindowSnapshot {
            Button(action: openContextWindow) {
                Text("Context window")
                Text("\(SessionContextRingPresentation.remainingLabel(usedPercent: context.contextPercent)) left")
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
            .accessibilityIdentifier("chat.context-window")
        }
    }

    @ViewBuilder
    private var providerUsageMenuItem: some View {
        if let providerUsage, providerUsage.isAvailable {
            Button("Usage", systemImage: "gauge.with.dots.needle.50percent") {
                providerUsage.show(agentID: model.memberIDs.first ?? "default")
            }
            .accessibilityIdentifier("chat.provider-usage")
        }
    }

    /// Token context is a technical readout: Nerd Mode only, as the ring was.
    private var contextWindowSnapshot: SessionContextSnapshot? {
        nerdModeEnabled ? model.sessionContext : nil
    }

    /// The pop-up hangs from the ⋯ button. The menu has already closed when its
    /// item runs, so nothing else is presenting.
    private func openContextWindow() {
        guard contextWindowSnapshot != nil else { return }
        dismissKeyboard()
        isContextWindowPresented = true
    }

    /// The ⋯ button's anchor for the context pop-up (the same glass pop-up the
    /// ring above the message box used to open).
    private var contextWindowAnchor: some View {
        Color.clear
            .allowsHitTesting(false)
            .popover(isPresented: $isContextWindowPresented, arrowEdge: .top) { contextWindowPopover }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var contextWindowPopover: some View {
        if let context = model.sessionContext {
            let showsUsage = providerUsage?.isAvailable == true
            SessionContextTokenPopover(
                snapshot: context,
                onShowProviderUsage: showsUsage ? { showProviderUsageFromContext() } : nil,
                runtimeControls: model.runtimeControls,
                onChangeModel: changeModelFromContext
            )
            .presentationCompactAdaptation(.popover)
            .onDisappear(perform: contextWindowDidClose)
        }
    }

    private func changeModelFromContext() {
        opensModelControlsAfterContext = true
        isContextWindowPresented = false
    }

    /// Change in the pop-up opens Model & reasoning once the pop-up is gone.
    private func contextWindowDidClose() {
        guard opensModelControlsAfterContext else { return }
        opensModelControlsAfterContext = false
        model.requestSessionControls()
    }

    /// Closes the pop-up first; it and the usage overlay can't show together.
    private func showProviderUsageFromContext() {
        isContextWindowPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            providerUsage?.show(agentID: model.memberIDs.first ?? "default")
        }
    }

    /// "GPT-5.5 · High", or just the model while reasoning is unknown.
    private var modelSummary: String? {
        guard let controls = model.runtimeControls else { return nil }
        return [controls.modelDisplayName, controls.currentReasoningLabel].compactMap { $0 }.joined(separator: " · ")
    }

    private var reasoningVisibilityBinding: Binding<Bool> {
        Binding(
            get: { model.activityVisibility.showReasoning },
            set: { model.setReasoningVisible($0) }
        )
    }

    private var toolCallVisibilityBinding: Binding<Bool> {
        Binding(
            get: { model.activityVisibility.showToolCalls },
            set: { model.setToolCallsVisible($0) }
        )
    }

    private var canEditCurrentAgent: Bool {
        guard let presentation = agentEditorPresentation,
              presentation.profileID == model.memberIDs.first else { return false }
        return presentation.isAvailable
    }

    private func presentCurrentAgentEditor() {
        guard canEditCurrentAgent,
              let route = agentEditorPresentation?.makeRoute() else { return }
        dismissKeyboard()
        agentEditorRoute = route
    }

    private var resolvedIdentityParticipants: [ChatIdentityParticipant] {
        if let identityParticipants, !identityParticipants.isEmpty {
            return identityParticipants
        }

        if model.isBotMode {
            return model.nativeRoomParticipants.map { participant in
                ChatIdentityParticipant(
                    stableID: participant.id,
                    displayName: participant.displayName,
                    imageURL: participant.profile.flatMap { agents?.avatarURL(for: $0) }
                )
            }
        }

        let profile = agents?.profiles.first {
            model.memberIDs.contains($0.id)
                || $0.name.localizedCaseInsensitiveCompare(agentName) == .orderedSame
        }
        return [ChatIdentityParticipant(
            stableID: profile?.id ?? model.memberIDs.first ?? agentName,
            displayName: profile?.name ?? agentName,
            imageURL: profile.flatMap { agents?.avatarURL(for: $0) }
        )]
    }

    /// iPhone and iPad: close the pop-up and open every model in a sheet. (The
    /// Mac pushes them inside the pop-up; see `ChatSessionControlsMacPopover`.)
    private func showAllModels() {
        guard !model.isAwaitingAuthoritativeSessionAllocation else { return }
        let closingPopover = isSessionControlsPresented
        isSessionControlsPresented = false
        guard let controls = model.runtimeControls else { return }
        Task { @MainActor in
            // UIKit drops a sheet presented while the popover is still closing.
            if closingPopover { try? await Task.sleep(for: .milliseconds(450)) }
            isAllModelsPresented = true
            await controls.loadPickersIfNeeded()
        }
    }

    private func openSessionControls(_ controls: SessionRuntimeControlModel) {
        guard !model.isAwaitingAuthoritativeSessionAllocation else { return }
        // The popover hangs below the header; the keyboard would cover its lower half.
        dismissKeyboard()
        isSessionControlsPresented = true
        Task { @MainActor in
            await controls.loadPickersIfNeeded()
        }
    }

    /// Long-press › Reply: the composer quotes the message and the keyboard opens.
    func startReply(to item: TimelineItem) {
        model.reply(to: item, senderName: senderResolver.display(for: item.sender).name)
        composerFocusTask?.cancel()
        composerFocusTask = Task { @MainActor in
            // The message menu is still closing; the keyboard rises after it.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            isDraftFocused = true
        }
    }

    private func scheduleComposerFocusIfRequested(_ request: Int) {
        guard request > 0 else { return }
        composerFocusTask?.cancel()
        composerFocusTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard !Task.isCancelled, request == composerFocusRequest else { return }
            isDraftFocused = true
        }
    }

    private func dismissKeyboardAndOpenWorkspace() {
        (referenceHub ?? fallbackReferenceHub).dismiss()
        dismissKeyboard()
        onWorkspaceTap()
    }

    private var attachmentAction: (() -> Void)? {
        guard let onAttachmentTap else { return nil }
        return {
            dismissKeyboard()
            onAttachmentTap()
        }
    }

    private func dismissKeyboardAndOpenVoice() {
        dismissKeyboard()
        onVoiceTap()
    }

    func dismissKeyboard() {
        composerFocusTask?.cancel()
        composerFocusTask = nil
        isDraftFocused = false
        BighelpKeyboard.dismiss()
    }

    /// Every model, with reasoning: the iPhone and iPad sheet, or the page the
    /// Mac pushes inside its Model & reasoning pop-up.
    private func allModelsPicker(
        _ controls: SessionRuntimeControlModel,
        support: SessionRuntimeControlSupport?,
        isEmbedded: Bool = false,
        onClose: (() -> Void)? = nil
    ) -> BighelpModelPickerSheet {
        BighelpModelPickerSheet(
            title: "Choose model",
            scopeLabel: "This chat only",
            providers: controls.modelProviders,
            currentProviderID: controls.currentProvider,
            currentModelID: controls.currentModel,
            isLoading: controls.isLoadingModel,
            isApplying: controls.isApplyingSelection,
            errorMessage: controls.errorMessage,
            onClearError: controls.clearError,
            onRetry: {
                Task { await controls.loadPickersIfNeeded() }
            },
            onSelect: { _, _ in },
            isModelPinned: controls.isModelPinned,
            onToggleModelPin: { providerID, modelID in
                controls.toggleModelPin(providerID: providerID, modelID: modelID)
            },
            reasoningOptions: controls.reasoningOptions,
            currentReasoningValue: controls.currentReasoningValue,
            statusMessage: controls.statusMessage,
            modelUnavailableReason: support?.modelUnavailableReason,
            reasoningUnavailableReason: support?.reasoningUnavailableReason,
            modelConfirmation: controls.pendingModelConfirmation,
            onConfirmModel: confirmSessionModel,
            onCancelModelConfirmation: { controls.cancelModelConfirmation(expected: $0) },
            isEmbedded: isEmbedded,
            onClose: onClose,
            onApply: applySelection
        )
    }

    private func applySelection(_ draft: SessionRuntimeSelectionDraft) {
        guard let controls = model.runtimeControls else { return }
        Task {
            await controls.apply(draft)
            guard controls.errorMessage == nil, !controls.hasPendingSelection else { return }
            await controls.loadModelPicker()
            guard controls.errorMessage == nil else { return }
            await controls.loadReasoningPicker()
            guard controls.errorMessage == nil else { return }
            closeAllModels()
        }
    }

    private func confirmSessionModel(_ confirmation: SessionRuntimeModelConfirmation) {
        guard let controls = model.runtimeControls else { return }
        Task {
            guard await controls.confirmModelSelection(confirmation) else { return }
            await controls.loadPickersIfNeeded()
            guard controls.errorMessage == nil else { return }
            closeAllModels()
        }
    }

    private func closeAllModels() {
        isAllModelsPresented = false
        #if targetEnvironment(macCatalyst)
        // Every model is a page inside the pop-up there.
        isSessionControlsPresented = false
        #endif
    }

    @BighelpThemeReader var theme: BighelpTheme

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
}

#Preview("Chat · canonical timeline") {
    ChatView(
        model: ChatModel(
            conversationID: "preview-finance",
            client: ConversationFixtureClient(),
            sleeper: VisibleDemoSleeper()
        )
    )
}

#Preview("Chat · large text") {
    let model = ChatModel(
        conversationID: "preview-large-text",
        client: ConversationFixtureClient()
    )
    model.draft = "Give me a detailed update on the vendor payment and the rest of today’s plan."
    return ChatView(model: model)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Chat · empty") {
    ChatView(
        model: ChatModel(
            conversationID: "preview-empty",
            client: ConversationFixtureClient(),
            initialItems: []
        )
    )
}
