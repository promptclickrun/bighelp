import SwiftUI
import UIKit

/// A host-owned runtime control; presentation never grants transport authority.
struct ChatSessionControlAccessory {
    let title: String
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void
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

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.bighelpScreen) private var screen
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.providerUsage) private var providerUsage
    @Environment(\.companionStore) private var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope
    @Environment(\.agentHomeChrome) var homeChrome
    @Environment(\.chatDissolveTransition) private var chatDissolve
    @Environment(\.appAppearance) private var appAppearance
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
    let onForceRefresh: (@MainActor () async throws -> Void)?
    let foldCompletedTurns: Bool
    /// Settings › Chat › Shows as. A group chat keeps its own folders (`workStyleInUse`).
    let workStyle: ChatWorkStyle
    let showsHeader: Bool
    let sessionControlAccessory: ChatSessionControlAccessory?
    let agentName: String
    let agentRole: String
    let agentStatus: String
    let identityParticipants: [ChatIdentityParticipant]?
    let agents: AgentDirectoryStore?
    let dashboardModel: DashboardModel?
    let directHermesClient: DirectHermesConversationClient?
    let directHermesClarifications: [DirectHermesPrompt]
    let sessionCatalog: SessionCatalogStore?
    let senderResolver: TimelineSenderResolver
    let allModelsRequest: Int
    let projectChangesSummary: ProjectChangesRailSummary?
    let composerFocusRequest: Int
    let onAttachmentTap: ((ChatActionMenuAction) -> Void)?
    let onProjectChangesTap: () -> Void
    let onVoiceTap: () -> Void
    let onApprovalTap: (ApprovalRequest) -> Void
    let onPeopleTap: () -> Void
    /// A group chat Hermes runs: its name and ⋯ › Group Settings open Group Settings. Nil
    /// leaves the item out, and the name opens the chat's info.
    let onGroupSettingsTap: (() -> Void)?
    /// This chat's files, from ⋯ › Files. Nil leaves the item out.
    let onChatFilesTap: (() -> Void)?
    /// ⋯ › Move to Project…. Nil leaves the item out.
    let projectMenuItem: ChatProjectMenuItem?
    let onNewChatTap: () -> Void
    /// Settings › AI providers, for a failed turn's Fix sign-in. Nil leaves the button out.
    let onOpenProviderAccounts: (() -> Void)?
    /// Set when this chat is its agent's Bot Chat: starts a new one (⋯ › New Bot Chat).
    let onNewBotChat: (() -> Void)?
    /// Hermes refused a message because another Hermes process holds this chat: go on in a branch.
    let onContinueInBranch: ((ChatBranchContinuation) -> Void)?
    /// True once for a chat that should send its draft when connected (a branch's message).
    let consumesSendOnOpen: ((String) -> Bool)?
    let onLoadPreviousMessages: () -> Void
    let onForkMessage: ((String) -> Void)?
    let referenceHub: ReferenceHubStore?
    let referenceSkills: SkillsAndToolsStore?
    let onReferenceSend: ((ReferenceFrozenDraft, MidSessionChatBehavior?) async -> Void)?
    /// One home: New chat's parts, given to its blank chat only. Read through `newChat`.
    let newChatSlot: ChatNewChatSlot?
    @State private var fallbackReferenceHub = ReferenceHubStore(owner: nil, providers: [])
    @State private var isChatVisible = false
    /// Tells the app which chat this screen shows (`BighelpVisibleChats`, ...).
    @State private var screenMount = ChatScreenMount()

    @State private var isSessionControlsPresented = false
    /// Model settings opens on All models (a failed turn's Use another model).
    @State private var sessionControlsStartOnAllModels = false
    @State private var isContextWindowPresented = false
    /// Change in the context pop-up: open Model settings once the pop-up is gone.
    @State private var opensModelControlsAfterContext = false
    #if targetEnvironment(macCatalyst)
    /// The Mac's Model settings pop-up hangs from what opened it: the ⋯
    /// button, or the message box for requests from elsewhere (the context
    /// window, chat Info, the agent's profile).
    private enum SessionControlsOrigin { case options, composer }
    @State private var sessionControlsOrigin = SessionControlsOrigin.options
    @State private var optionsButtonBottom: CGFloat = 0
    @State private var canvasWidth: CGFloat = 0
    #endif
    @State private var sessionTitleDialog: SessionTitleDialog?
    @State private var sessionTitleDraft = ""
    @State private var sessionTitleErrorMessage = ""
    @State private var isRenamingSessionTitle = false
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
    @State private var compactError: String?
    @State var headerHeight: CGFloat = 0
    /// Full screen height, for the Auto avatar size.
    @State private var screenHeight: CGFloat = 0
    @State private var bottomSafeArea: CGFloat = 0
    /// The bottom of the chat's safe area (the keyboard's top while it shows), in the window.
    @State private var safeBottomInWindow: CGFloat = 0
    @AppStorage(ChatLayoutPreferences.densityKey) var chatDensity: ChatDensity = .comfortable
    @AppStorage(ChatReasoningPlacement.storageKey) var reasoningPlacement = ChatReasoningPlacement.defaultPlacement
    @AppStorage(ChatLayoutPreferences.agentMessageStyleKey) var chatAgentStyle: ChatAgentMessageStyle = .bubble
    @AppStorage(ChatLayoutPreferences.showsSessionTitleKey)
    private var showsSessionTitle = ChatLayoutPreferences.showsSessionTitleByDefault
    @State var composerHeight: CGFloat = 0

    init(
        model: ChatModel,
        agentName: String = "Avery Park",
        agentRole: String = "Finance agent",
        agentStatus: String = "Hermes",
        identityParticipants: [ChatIdentityParticipant]? = nil,
        agents: AgentDirectoryStore? = nil,
        dashboardModel: DashboardModel? = nil,
        directHermesClient: DirectHermesConversationClient? = nil,
        directHermesClarifications: [DirectHermesPrompt] = [],
        sessionCatalog: SessionCatalogStore? = nil,
        senderResolver: TimelineSenderResolver = TimelineSenderResolver(),
        allModelsRequest: Int = 0,
        projectChangesSummary: ProjectChangesRailSummary? = nil,
        composerFocusRequest: Int = 0,
        onAttachmentTap: ((ChatActionMenuAction) -> Void)? = nil,
        onProjectChangesTap: @escaping () -> Void = {},
        onVoiceTap: @escaping () -> Void = {},
        onApprovalTap: @escaping (ApprovalRequest) -> Void = { _ in },
        onPeopleTap: @escaping () -> Void = {},
        onGroupSettingsTap: (() -> Void)? = nil,
        onChatFilesTap: (() -> Void)? = nil,
        projectMenuItem: ChatProjectMenuItem? = nil,
        onNewChatTap: @escaping () -> Void = {},
        onOpenProviderAccounts: (() -> Void)? = nil,
        onNewBotChat: (() -> Void)? = nil,
        onContinueInBranch: ((ChatBranchContinuation) -> Void)? = nil,
        consumesSendOnOpen: ((String) -> Bool)? = nil,
        onLoadPreviousMessages: @escaping () -> Void = {},
        onForkMessage: ((String) -> Void)? = nil,
        referenceHub: ReferenceHubStore? = nil,
        referenceSkills: SkillsAndToolsStore? = nil,
        onReferenceSend: ((ReferenceFrozenDraft, MidSessionChatBehavior?) async -> Void)? = nil,
        foldCompletedTurns: Bool = true,
        workStyle: ChatWorkStyle = .card,
        showsHeader: Bool = true,
        sessionControlAccessory: ChatSessionControlAccessory? = nil,
        onForceRefresh: (@MainActor () async throws -> Void)? = nil,
        newChat: ChatNewChatSlot? = nil
    ) {
        self.model = model
        self.newChatSlot = newChat
        self.onForceRefresh = onForceRefresh
        self.foldCompletedTurns = foldCompletedTurns
        self.workStyle = workStyle
        // Before the first frame, so a chat opens with its folders as the style has them.
        model.activityDisclosures.configure(style: model.isBotMode ? nil : workStyle)
        self.showsHeader = showsHeader
        self.sessionControlAccessory = sessionControlAccessory
        self.agentName = agentName
        self.agentRole = agentRole
        self.agentStatus = agentStatus
        self.identityParticipants = identityParticipants
        self.agents = agents
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
        self.onGroupSettingsTap = onGroupSettingsTap
        self.onChatFilesTap = onChatFilesTap
        self.projectMenuItem = projectMenuItem
        self.onNewChatTap = onNewChatTap
        self.onOpenProviderAccounts = onOpenProviderAccounts
        self.onNewBotChat = onNewBotChat
        self.onContinueInBranch = onContinueInBranch
        self.consumesSendOnOpen = consumesSendOnOpen
        self.onLoadPreviousMessages = onLoadPreviousMessages
        self.onForkMessage = onForkMessage
        self.referenceHub = referenceHub
        self.referenceSkills = referenceSkills
        self.onReferenceSend = onReferenceSend
    }

    var workStyleInUse: ChatWorkStyle? {
        model.isBotMode ? nil : workStyle
    }

    /// A group chat's turns hold several agents' thinking, so it stays in each one's steps.
    var reasoningPlacementInUse: ChatReasoningPlacement {
        model.isBotMode ? .steps : reasoningPlacement
    }

    /// One home: New chat's parts while nothing is sent here. A first message (waiting, on its way
    /// or sent) or a failure to show makes this an ordinary chat, whatever the shell still passes.
    /// They go with the pushed header, which holds the To row. A chat without the slot reads
    /// nothing here, and with it only what the rows already read.
    private var newChat: ChatNewChatSlot? {
        guard let newChatSlot, homeChrome.isPushedChat, model.isBlankForNewChat else { return nil }
        return newChatSlot
    }

    var body: some View {
        let _ = ChatPerformanceProbe.count("chat.body")
        let _ = model.botModeRoomStore?.rooms
        // Track the connection capability stamp in the presenting view, not
        // only inside the retained pop-up, so a reconnect updates it.
        let _ = model.runtimeControls?.selectionSupport
        return chatCanvas
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            theme.canvas.ignoresSafeArea()
        }
        .environment(\.bighelpUIV3Enabled, true)
        .environment(\.bighelpUIV2Enabled, true)
        .environment(\.chatActivityDisclosureStore, model.activityDisclosures)
        .environment(\.chatWorkFolding, ChatWorkFolding(foldsFinished: foldCompletedTurns, style: workStyleInUse ?? .full))
        .modifier(ChatScheduledRetryLifecycle(model: model))
        .modifier(ChatBackgroundCommandsWatch(model: model))
        .onAppear {
            isChatVisible = true
            registerChatDissolve()
            screenMount.mount(model)
        }
        // This view can be handed another model while it stays on screen (New chat, a reconnect).
        .onChange(of: ObjectIdentifier(model)) { _, _ in
            registerChatDissolve()
            if isChatVisible { screenMount.mount(model) }
        }
        .onChange(of: workStyleInUse) { _, style in
            model.activityDisclosures.configure(style: style)
        }
        // A request from outside the chat screen to open Model settings.
        .onChange(of: allModelsRequest) { _, request in
            guard request > 0, let controls = model.runtimeControls else { return }
            guard !ChatRuntimeSelectionLockout.isLocked(isTurnActive: controls.isTurnActive) else {
                return
            }
            #if targetEnvironment(macCatalyst)
            sessionControlsOrigin = .composer
            #endif
            openSessionControls(controls)
        }
        .onChange(of: model.modelSettingsRequest) { _, _ in
            guard let controls = model.runtimeControls,
                  !ChatRuntimeSelectionLockout.isLocked(isTurnActive: controls.isTurnActive) else { return }
            #if targetEnvironment(macCatalyst)
            sessionControlsOrigin = .composer
            #endif
            openSessionControls(controls)
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
                openSessionControls(controls, allModels: model.sessionControlsOpenOnAllModels)
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
            screenMount.unmount()
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
        .onChange(of: model.branchContinuation) { _, continuation in
            if let continuation { onContinueInBranch?(continuation) }
        }
        .task(id: model.conversationID) { await sendDraftOnOpenIfAsked() }
        // A group's live activity (who is typing) is read only while it's on screen.
        .task(id: model.botModeActivityScope) { await model.observeBotModeActivity() }
        // What other agents this agent asked are doing, while they're on it.
        .task(id: model.agentTalkFollowKey) { await model.followAgentTalk() }
        .task(id: model.otherProcessFollowKey) { await model.followOtherProcess() }
        .alert("Couldn't compact", isPresented: Binding(get: { compactError != nil }, set: { if !$0 { compactError = nil } })) {
            Button("OK") { compactError = nil }
        } message: { Text(compactError ?? "") }
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
                TextField("Chat name", text: $sessionTitleDraft)
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
                Text(onNewBotChat == nil
                     ? "Enter a name up to \(SessionTitleRules.maximumLength) characters."
                     : "Renamed, this becomes a regular chat, and tapping the bot starts a new Bot Chat.")
            case .error:
                Text(sessionTitleErrorMessage)
            }
        }
    }

    private func registerChatDissolve() {
        let appearance = appAppearance, accent = theme.action
        chatDissolve?.register(conversationID: model.conversationID, backdrop: UIColor(theme.canvas),
                               // The look as it is when the chat goes, in this chat's colors.
                               look: { AnyView(ChatDissolveLookBand(look: .selected, accent: accent)
                                   .environment(\.appAppearance, appearance)) },
                               scrollView: { [weak timelineController] in timelineController?.scrollView })
    }

    private var companionSignal: CompanionChatSignal {
        let ledger = model.ledgerReading
        var runningIDs = ledger.running
        if model.isSending { runningIDs.insert("sending:\(model.conversationID)") }

        var successIDs = ledger.succeeded
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

    /// The pet is the avatar of the agent asking, else the chat's agent.
    private var companionPet: AgentPetIdentity? {
        let participants = resolvedIdentityParticipants
        let agentID = chatClarifications.first?.agentID ?? model.memberIDs.first ?? participants.first?.stableID
        guard let agentID else { return nil }
        let participant = participants.first { $0.stableID == agentID }
        return AgentPetIdentity(agentID: agentID, name: participant?.displayName ?? agentName,
                                imageURL: participant?.imageURL)
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
            // One home: a new chat's people list stands where its empty messages would be.
            .opacity(showsNewChatPeople ? 0 : 1)
            #if !os(visionOS)
            // Messages run on under the status bar and home indicator, so the blur under the
            // header reaches the top of the screen without a hard edge. UIKit adds those
            // areas to the table's insets itself, so nothing moves.
            .ignoresSafeArea(.container, edges: .vertical)
            #endif
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
            .overlay { newChatPeople }
            .overlay(alignment: .bottom) { timelineStatusOverlay }
            .overlay(alignment: .top) {
                floatingHeader
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Half-folded, it takes every spare point first, so the message box's area is
                    // only as tall as the space under the fold. Only then: elsewhere the message box
                    // and the bar keep their own height.
                    Spacer(minLength: headerHeight).layoutPriority(laptopDeckHeight > 0 ? 1 : 0)
                    VStack(spacing: 0) {
                        // Half-folded like a laptop: everything under the fold is the message box's.
                        // Typing, it rests on the keyboard; otherwise it sits just under the fold.
                        if laptopDeckHeight > 0, isDraftFocused { Spacer(minLength: 0) }
                        composer
                            .fixedSize(horizontal: false, vertical: !(referenceHub ?? fallbackReferenceHub).isPresented)
                            #if targetEnvironment(macCatalyst)
                            .popover(isPresented: sessionControlsPresented(from: .composer)) { macSessionControls }
                            #endif
                        if laptopDeckHeight > 0, !isDraftFocused { Spacer(minLength: 0) }
                        newChatChoices
                    }
                    // The messages stop at the fold: the timeline keeps clear of all of this.
                    .frame(minHeight: laptopDeckHeight)
                    // The Skills and commands list takes the room under the header before the spacer
                    // does. Offered an equal share, a long list showed about two rows.
                    .layoutPriority((referenceHub ?? fallbackReferenceHub).isPresented && laptopDeckHeight == 0 ? 1 : 0)
                    #if !os(visionOS)
                    // The same soft blur under the message box and a new chat's choices.
                    .background {
                        ChatEdgeBlur(edge: .bottom) { [timelineController] in timelineController.scrollView }
                            .ignoresSafeArea(edges: .bottom)
                    }
                    #endif
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            } action: { screenHeight = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeArea = $0 }
            .onGeometryChange(for: CGFloat.self) { [isLaptop = screen.isLaptop] proxy in
                // Only half-folded like a laptop: a chat redraws for every change of this.
                isLaptop ? proxy.frame(in: .global).maxY - proxy.safeAreaInsets.bottom : 0
            } action: { safeBottomInWindow = $0 }
            #if targetEnvironment(macCatalyst)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasWidth = $0 }
            #endif
    }

    /// The iPhone Duo half-folded like a laptop: from the fold down to the bottom of the safe area.
    private var laptopDeckHeight: CGFloat {
        guard screen.isLaptop, let fold = screen.fold else { return 0 }
        return max(0, safeBottomInWindow - fold.maxY)
    }

    /// One home: the bots to pick from, over a new chat's empty messages until something is sent.
    private var showsNewChatPeople: Bool { newChat?.people != nil }

    /// Between the header and the message box, so the list follows the keyboard and its rows never
    /// run under either. An overlay of its own: it takes no part in the message box's layout.
    @ViewBuilder
    private var newChatPeople: some View {
        if let people = newChat?.people {
            people
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(.rect)
                .clipped()
                .padding(.top, headerHeight)
                .padding(.bottom, composerHeight)
        }
    }

    /// One home: a new chat's choices (project, where it runs, branch, mode) under the message box,
    /// in the place the in-chat bar had. A sibling of the box, so a change in it never redraws the
    /// box, and `composerHeight` measures both, so the messages keep clear of it.
    @ViewBuilder
    private var newChatChoices: some View {
        if let choices = newChat?.choicesRow {
            choices
                // The box's lane, with the row's own side padding outside it.
                .frame(maxWidth: horizontalSizeClass == .regular
                       ? ChatCanvasLayout.regularLaneMaximumWidth + 2 * BighelpTokens.space12 : .infinity)
                // Its own height only: offered a share of the spare room, it would take it from the spacer.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Each control samples the transcript, never an opaque toolbar slab.
    /// The table alone reserves the measured header and composer insets.
    private var floatingHeader: some View {
        let toRow = newChat?.toRow
        return pushedHeader(toRow: toRow)
        .background(alignment: .bottom) { sessionControlsAnchor }
        .foregroundStyle(theme.primaryText)
        // The To row ends in its own line, and the people list starts right under it.
        .padding(.bottom, toRow == nil ? 8 : 0)
        #if !os(visionOS)
        .background {
            // Messages scroll on beneath the header and blur near the top, so the
            // glass buttons and the name show the chat instead of a band of color.
            ChatEdgeBlur(edge: .top) { [timelineController] in timelineController.scrollView }
                .ignoresSafeArea(edges: .top)
        }
        #endif
    }

    /// One-on-one chats only: group chats already show their title.
    private var shownSessionTitle: String? {
        guard showsSessionTitle, !model.isBotMode else { return nil }
        return model.headerSessionTitle
    }

    /// The agent this chat is with; a group chat has no one agent.
    private var homeAgentID: String {
        resolvedIdentityParticipants.first?.stableID ?? model.memberIDs.first ?? agentName
    }

    /// One home: Back, who the chat is with (a bot's pill opens its page) and ⋯; a new chat with
    /// nothing sent has its To row instead. Back pops to wherever the chat was opened from.
    private func pushedHeader(toRow: AnyView?) -> some View {
        ChatPushedHeader(identity: AnyView(conversationHeader), toRow: toRow, options: AnyView(chatOptionsMenu),
                         onBack: {
                             dismissKeyboard()
                             dismiss()
                         })
    }

    private var composer: some View {
        ChatComposerHost(
            model: model,
            agentName: agentName,
            sessionCatalog: sessionCatalog,
            onAttachmentTap: attachmentAction,
            onVoiceTap: dismissKeyboardAndOpenVoice,
            onFittingRailVerticalDrag: requestFittingRailScroll,
            draftFocus: $isDraftFocused,
            isDraftFocused: isDraftFocused,
            onDismissKeyboard: dismissKeyboard,
            onWillSend: { timelineController.scrollToLatest(animated: false) },
            companionPet: companionStore?.isEnabled == true ? companionPet : nil,
            companionReaction: companionReaction,
            companionSizeScale: companionStore?.sizeScale ?? 1,
            companionIsAdventurous: companionStore?.isAdventurous == true,
            referenceHub: referenceHub ?? fallbackReferenceHub,
            referenceSkills: referenceSkills,
            onReferenceSend: onReferenceSend,
            sendOverride: newChat?.sendOverride
        )
        // One home: while New chat's To row isn't this chat's one bot, voice would be another bot's.
        .modifier(ChatVoiceAvailability(isOffered: newChat?.isOneBotsChat != false))
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
                sessionTitleErrorMessage = "Enter a chat name between 1 and \(SessionTitleRules.maximumLength) characters."
                sessionTitleDialog = .error
            } catch {
                sessionTitleErrorMessage = "bighelp could not rename this chat. Try again."
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
                simpleBotIdentityButton
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.header-surface")
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }

    /// Model settings, from the ⋯ menu or the message box's model chip. A sheet on iPhone, iPad and
    /// Vision Pro; the Mac hangs a pop-up from what opened it (`macSessionControls`).
    private var sessionControlsAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            #if targetEnvironment(macCatalyst)
            .onChange(of: isSessionControlsPresented) { _, presented in
                guard !presented else { return }
                sessionControlsOrigin = .options
            }
            #else
            .bighelpSheet(isPresented: $isSessionControlsPresented) {
                if let controls = model.runtimeControls {
                    ChatModelSettingsSheet(
                        controls: controls,
                        isAllocating: model.isAwaitingAuthoritativeSessionAllocation,
                        contextWindow: model.contextWindow,
                        startsOnAllModels: sessionControlsStartOnAllModels,
                        onDone: { isSessionControlsPresented = false }
                    )
                }
            }
            #endif
            // Hermes takes a new model or level on the next turn, so a turn that
            // starts closes the sheet rather than promise a change mid-answer.
            .onChange(of: model.runtimeControls?.isTurnActive) { _, active in
                if active == true {
                    isSessionControlsPresented = false
                }
            }
            .allowsHitTesting(false)
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

    /// The Mac's Model settings pop-up, hung from the ⋯ button or the message box.
    @ViewBuilder
    private var macSessionControls: some View {
        if let controls = model.runtimeControls {
            ChatModelSettingsMacPopover(
                controls: controls,
                size: sessionControlsSize,
                contextWindow: model.contextWindow,
                startsOnAllModels: sessionControlsStartOnAllModels,
                onDone: { isSessionControlsPresented = false }
            )
            .presentationCompactAdaptation(.popover)
            .bighelpPopoverDismissal(isPresented: $isSessionControlsPresented)
        }
    }

    /// Fits the window: the room below the ⋯ button, or above the message box.
    private var sessionControlsSize: CGSize {
        let room = sessionControlsOrigin == .options
            ? screenHeight - optionsButtonBottom
            : screenHeight - composerHeight - bottomSafeArea
        let width: CGFloat = canvasWidth > 0 ? min(560, canvasWidth - 32) : 560
        // Leaves the arrow and a margin clear of the window's edge.
        return CGSize(width: min(width, 440), height: min(620, max(320, room - 48)))
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

    /// The bot's face and name in one pill; it opens the bot's page.
    private var simpleBotIdentityButton: some View {
        let participant = resolvedIdentityParticipants.first
        let agentID = model.memberIDs.first ?? participant?.stableID ?? agentName
        return Button {
            dismissKeyboard()
            homeChrome.onProfile(agentID)
        } label: {
            ChatAgentIdentityPill(agentID: agentID, name: agentName, imageURL: participant?.imageURL,
                                  sessionTitle: shownSessionTitle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agentName)
        .accessibilityValue(headerLiveActivityPresentation?.text ?? shownSessionTitle ?? headerLiveState.label)
        .accessibilityHint("Opens its profile")
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

    /// Coming back reloads the chat from Hermes behind its saved copy, so only the agent's own work shows here.
    private var headerLiveActivityPresentation: ChatHeaderLiveActivityPresentation? {
        ChatHeaderLiveActivityPresentation.resolve(
            phrase: currentHeaderActivityPhrase,
            isActive: isChatVisible && model.isSending
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
            if let onGroupSettingsTap { onGroupSettingsTap() } else { onPeopleTap() }
        } label: {
            ChatConversationIdentityLabel(
                title: model.botModeRoomTitle,
                subtitle: model.botModeLeadName.map { "Lead: \($0)" },
                participants: resolvedIdentityParticipants,
                theme: theme,
                showsCaption: true,
                memberCount: resolvedIdentityParticipants.count + 1
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.botModeRoomTitle), \(groupParticipantSummary)")
        .accessibilityValue(model.botModeLeadName.map { "Lead: \($0)" } ?? "")
        .accessibilityHint(opensGroupSettings ? "Opens Group Settings" : "Opens People and Chat details")
        .accessibilityIdentifier("chat.people")
    }

    /// A group Hermes runs has Group Settings; any other group's name opens its people.
    private var opensGroupSettings: Bool {
        onGroupSettingsTap != nil && model.botModeRoom?.hasNativeRoom == true
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

    /// iOS keeps a menu under about 60% of the screen's height and draws it at the device's text size,
    /// not bighelp's. The whole list, File changes and all, fits that at the default size
    /// (`CompactChatMenuUITests`); from XL it folds into This chat, Agent and More.
    private var foldsChatOptions: Bool {
        let device = DynamicTypeSize(UIApplication.shared.preferredContentSizeCategory) ?? dynamicTypeSize
        return device >= .xLarge || dynamicTypeSize.isAccessibilitySize
    }

    /// One list: a Bot Chat's New Bot Chat, then This chat (with File changes), Model (Model & speed,
    /// Usage) and More (Bot page, Advanced). Folded, This chat, Agent and More hold all but Model &
    /// speed, so no level needs scrolling without reducing the font.
    private var chatOptionsMenu: some View {
        Menu {
            if foldsChatOptions {
                modelAndSpeedMenu
                Menu {
                    chatItems
                } label: {
                    Label("This chat", systemImage: "bubble.left")
                }
                .accessibilityIdentifier("chat.options.this-chat")
                if onNewBotChat != nil || showsBotPageItem {
                    Menu {
                        newChatItems
                        botPageItem
                    } label: {
                        Label("Bot", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("chat.options.agent")
                }
                Menu {
                    // Here, not in This chat: four rows there need scrolling at the largest sizes.
                    fileChangesMenuItem
                    usageMenu
                    advancedMenu
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("chat.options.more")
            } else {
                // Lines, not titles, between the groups: titles made the list taller than iOS lets a
                // menu grow, so it scrolled.
                Section { newChatItems }
                Section {
                    chatItems
                    fileChangesMenuItem
                }
                Section {
                    modelAndSpeedMenu
                    usageMenu
                }
                Section {
                    botPageItem
                    advancedMenu
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                #if targetEnvironment(macCatalyst)
                // The same weight as Back across the header.
                .font(.bighelp(.title3).weight(.semibold))
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
        .accessibilityHint("This chat, file changes, model and speed, usage and advanced options")
        .accessibilityIdentifier("chat.options")
        .modifier(ChatFastModeLoader(controls: model.runtimeControls,
                                    isAllocating: model.isAwaitingAuthoritativeSessionAllocation))
    }

    @ViewBuilder
    private var modelAndSpeedMenu: some View {
        if sessionControlAccessory != nil || model.runtimeControls != nil {
            Menu {
                modelAndReasoningMenuItem
                if let controls = model.runtimeControls {
                    SessionFastModeMenu(controls: controls, isAllocating: model.isAwaitingAuthoritativeSessionAllocation)
                }
            } label: {
                // One line at accessibility sizes, so all four rows fit without scrolling.
                Text(dynamicTypeSize.isAccessibilitySize ? "Model" : "Model & speed")
                if !dynamicTypeSize.isAccessibilitySize, let summary = modelSummary { Text(summary) }
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityIdentifier("chat.options.model-speed")
        }
    }

    @ViewBuilder
    private var fileChangesMenuItem: some View {
        if let changes = projectChangesSummary {
            Button {
                dismissKeyboard()
                onProjectChangesTap()
            } label: {
                Text("File changes")
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(ProjectChangesRailPresentation.visibleLabels(for: changes).joined(separator: " "))
                }
                Image(systemName: "plusminus")
            }
            .accessibilityLabel(ProjectChangesRailPresentation.accessibilityLabel(for: changes))
            .accessibilityIdentifier("chat.file-changes")
        }
    }

    /// Rename, Move to Project and Files, and a group's Group Settings and Chat info (its members).
    @ViewBuilder
    private var chatItems: some View {
        if opensGroupSettings, let onGroupSettingsTap {
            Button("Group Settings", systemImage: "person.2") {
                dismissKeyboard()
                onGroupSettingsTap()
            }
            .accessibilityIdentifier("chat.group-settings")
        }
        if model.isBotMode {
            Button("Chat info", systemImage: "info.circle") {
                dismissKeyboard()
                onPeopleTap()
            }
            .accessibilityIdentifier("chat.info")
        }
        if sessionCatalog != nil {
            Button("Rename…", systemImage: "pencil", action: presentSessionTitleRename)
                .disabled(isRenamingSessionTitle)
                .accessibilityIdentifier("chat.rename")
        }
        if let projectMenuItem {
            Button {
                dismissKeyboard()
                projectMenuItem.open()
            } label: {
                Text(dynamicTypeSize.isAccessibilitySize ? "Move…" : "Move to Project…")
                if !dynamicTypeSize.isAccessibilitySize, let name = projectMenuItem.projectName { Text(name) }
                Image(systemName: "folder")
            }
            .accessibilityIdentifier("chat.move-project")
        }
        if let onChatFilesTap {
            Button("Files", systemImage: "paperclip") {
                dismissKeyboard()
                onChatFilesTap()
            }
            .accessibilityIdentifier("chat.files")
        }
    }

    /// A Bot Chat's New Bot Chat.
    @ViewBuilder
    private var newChatItems: some View {
        if let onNewBotChat {
            Button("New Bot Chat", systemImage: "arrow.trianglehead.counterclockwise") {
                dismissKeyboard()
                onNewBotChat()
            }
            .accessibilityIdentifier("chat.new-bot-chat")
        }
    }

    /// A chat with one bot, in the shell: only there is a page to open. Not while New chat's To row
    /// names nobody or several bots: the page would be the blank chat's bot's, not theirs.
    private var showsBotPageItem: Bool {
        !model.isBotMode && homeChrome.isPushedChat && newChat?.isOneBotsChat != false
    }

    /// The bot's page, the same one its name in the header opens.
    @ViewBuilder
    private var botPageItem: some View {
        if showsBotPageItem {
            Button("Bot page", systemImage: "person.crop.circle") {
                dismissKeyboard()
                homeChrome.onProfile(homeAgentID)
            }
            .accessibilityIdentifier("chat.bot-page")
        }
    }

    /// A branch made for a refused message sends it once the branch is connected; if it
    /// isn't soon, the message stays in the box for the person to send.
    private func sendDraftOnOpenIfAsked() async {
        guard consumesSendOnOpen?(model.conversationID) == true else { return }
        for _ in 0..<150 {
            if model.directTransportIsReady, !model.draft.isEmpty {
                await model.send()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
    }

    /// Usage › Compact: Hermes folds earlier messages into a summary; the rail above
    /// the message box shows it working, then what it saved.
    private func compactChat(_ client: any CompactingConversationClient) {
        Task {
            do {
                try await client.compact(conversationID: model.conversationID)
            } catch is CancellationError {
            } catch {
                compactError = "Hermes couldn't compact this chat. Try again when the bot isn't replying."
            }
        }
    }

    @ViewBuilder
    private var usageMenu: some View {
        if offersContextWindow || providerUsage?.isAvailable == true || canCompact {
            Menu {
                providerUsageMenuItem
                contextWindowMenuItem
                compactMenuItem
            } label: {
                Label("Usage", systemImage: "gauge.with.dots.needle.50percent")
            }
            .accessibilityIdentifier("chat.options.usage")
        }
    }

    private var canCompact: Bool { model.client is any CompactingConversationClient }

    /// Beside the context window it frees, and an everyday action, so it never
    /// waits for Nerd Mode: Nerd Mode is kept per device, and a new install has it off.
    @ViewBuilder
    private var compactMenuItem: some View {
        if let compacting = model.client as? any CompactingConversationClient {
            Button("Compact", systemImage: "arrow.down.right.and.arrow.up.left") {
                dismissKeyboard()
                compactChat(compacting)
            }
            .disabled(model.isSending || model.compaction != nil)
            .accessibilityIdentifier("chat.compact")
        }
    }

    private var advancedMenu: some View {
        Menu {
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    displayMenuItems
                } label: {
                    Label("Display", systemImage: "eye")
                }
                .accessibilityIdentifier("chat.options.display")
            } else {
                displayMenuItems
            }
            if onForceRefresh != nil {
                Button(isForceRefreshing ? "Refreshing…" : (dynamicTypeSize.isAccessibilitySize ? "Refresh" : "Force refresh"),
                       systemImage: "arrow.clockwise", action: forceRefresh)
                    .disabled(isForceRefreshing)
                    .accessibilityIdentifier("chat.force-refresh")
            }
        } label: {
            Label("Advanced", systemImage: "gearshape.2")
        }
        .accessibilityIdentifier("chat.options.advanced")
    }

    @ViewBuilder
    private var displayMenuItems: some View {
        Toggle(isOn: reasoningVisibilityBinding) {
            Label(dynamicTypeSize.isAccessibilitySize ? "Reasoning" : "Show reasoning", systemImage: "sparkles")
        }
        .accessibilityHint("Shows or hides Thinking cards for this chat.")
        .accessibilityIdentifier("chat.visibility.reasoning")
        Toggle(isOn: toolCallVisibilityBinding) {
            Label(dynamicTypeSize.isAccessibilitySize ? "Tool calls" : "Show tool calls", systemImage: "terminal")
        }
        .accessibilityIdentifier("chat.visibility.tool-calls")
    }

    @ViewBuilder
    private var modelAndReasoningMenuItem: some View {
        if let accessory = sessionControlAccessory {
            Button(action: accessory.action) {
                Text(dynamicTypeSize.isAccessibilitySize ? "Model" : "Model settings")
                if !dynamicTypeSize.isAccessibilitySize, let summary = modelSummary { Text(summary) }
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Model settings")
            .disabled(!accessory.isEnabled || model.isAwaitingAuthoritativeSessionAllocation)
            .accessibilityIdentifier(accessory.accessibilityIdentifier)
        } else if let controls = model.runtimeControls {
            Button {
                openSessionControls(controls)
            } label: {
                Text(dynamicTypeSize.isAccessibilitySize ? "Model" : "Model settings")
                if !dynamicTypeSize.isAccessibilitySize, let summary = modelSummary { Text(summary) }
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Model settings")
            .disabled(ChatRuntimeSelectionLockout.isLocked(isTurnActive: controls.isTurnActive)
                || model.isAwaitingAuthoritativeSessionAllocation)
            .accessibilityIdentifier("chat.session-controls")
        }
    }

    @ViewBuilder
    private var contextWindowMenuItem: some View {
        if offersContextWindow {
            Button(action: openContextWindow) {
                Text("Context window")
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(model.sessionContext.map {
                        "\(SessionContextRingPresentation.remainingLabel(usedPercent: $0.contextPercent)) left"
                    } ?? "Not reported yet")
                }
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

    /// Hermes reports a chat's context size only once the agent has answered in its
    /// current session (a new chat, or any chat after Hermes restarts, has none yet),
    /// so a Hermes chat always offers Context window, saying when it's still to come,
    /// rather than the item and Usage disappearing.
    private var offersContextWindow: Bool {
        model.sessionContext != nil || directHermesClient != nil
    }

    /// The pop-up hangs from the ⋯ button. The menu has already closed when its
    /// item runs, so nothing else is presenting.
    private func openContextWindow() {
        guard offersContextWindow else { return }
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
            .bighelpPopoverDismissal(isPresented: $isContextWindowPresented)
            .onDisappear(perform: contextWindowDidClose)
        } else {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text("Context window").bighelpFont(.label, weight: .semibold)
                Text("Hermes reports this chat's context size after the bot's next reply.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BighelpTokens.space20)
            .frame(minWidth: 260, alignment: .leading)
            .background(theme.canvas)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.session-context.pending")
            .presentationCompactAdaptation(.popover)
            .bighelpPopoverDismissal(isPresented: $isContextWindowPresented)
        }
    }

    private func changeModelFromContext() {
        opensModelControlsAfterContext = true
        isContextWindowPresented = false
    }

    /// Change in the pop-up opens Model settings once the pop-up is gone.
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

    private var resolvedIdentityParticipants: [ChatIdentityParticipant] {
        if let identityParticipants, !identityParticipants.isEmpty {
            return identityParticipants
        }

        if model.isBotMode {
            return model.nativeRoomParticipants.map { participant in
                ChatIdentityParticipant(
                    stableID: participant.id,
                    displayName: participant.displayName,
                    imageURL: participant.peerImageURL ?? participant.profile.flatMap { agents?.avatarURL(for: $0) }
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

    private func openSessionControls(_ controls: SessionRuntimeControlModel, allModels: Bool = false) {
        guard !model.isAwaitingAuthoritativeSessionAllocation else { return }
        sessionControlsStartOnAllModels = allModels
        // The keyboard would cover the sheet's lower half.
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


    private var attachmentAction: ((ChatActionMenuAction) -> Void)? {
        // One home: a new chat's message that a group chat or a coding session takes is text only.
        guard let onAttachmentTap, newChat?.offersAttachments != false else { return nil }
        return { action in
            dismissKeyboard()
            onAttachmentTap(action)
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

    @BighelpThemeReader var theme: BighelpTheme

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
}

/// Takes voice out of the message box's button where the chat's bot isn't who the person is
/// writing to. Read and set here, in a view of its own, so the box's other capabilities stay as
/// its screen gave them.
private struct ChatVoiceAvailability: ViewModifier {
    let isOffered: Bool
    @Environment(\.chatSurfaceCapabilities) private var capabilities

    func body(content: Content) -> some View {
        var next = capabilities
        if !isOffered { next.voice = false }
        return content.environment(\.chatSurfaceCapabilities, next)
    }
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
