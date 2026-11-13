import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What restarts the hand-over of a board's text to the message box (`AppState.leaveComposerText`).
private struct PendingComposerText: Equatable {
    let conversationID: String
    let text: String?
}

@MainActor
struct ChatDestinationView: View {
    let model: ChatModel
    @State private var isSessionFilesPresented = false
    @State private var isProjectMovePresented = false
    @State private var requestsSessionFilesAfterDetails = false
    @State private var isNativeAttentionPresented = false
    /// Briefly after the chat opens or the app returns (a Dynamic Island or
    /// notification tap), a question or approval waiting on you opens focused.
    @State private var attentionAutoOpenUntil: Date?
    @State private var responseHaptics = ResponseHapticsController()
    @State private var replyReader = ChatReplyReader()
    @State private var isHapticsSurfaceVisible = false
    @State private var projectChanges: ProjectChangesStore
    @State var voicePresentation: VoicePresentation?
    /// Bots mode's voice: a bar over the chat instead of the voice screen.
    @State var voiceBar: VoicePresentation?
    @State var attachmentFlow = ChatAttachmentFlowState()
    @State var isPhotoPickerPresented = false
    @State var isFilePickerPresented = false
    @State var isCameraPickerPresented = false
    @State var isDocumentScannerPresented = false
    @State var isDrawingPresented = false
    @State var documentScanResult: Result<ChatAttachment, Error>?
    @State var documentScanMembers: [String] = []
    @State var photoSelections: [PhotosPickerItem] = []
    @State var attachmentErrorMessage: String?
    @State var attachmentRecoveryKind: PermissionKind?
    /// ☰ from the voice screen: the menu opens once voice has closed.
    @State private var opensMenuAfterVoice = false
    @State private var modelPickerRequest = 0
    @State private var isProjectChangesPresented = false
    @State private var projectChangesPanelWidth: CGFloat = ProjectChangesPanelWidthPolicy.minimum
    @State private var projectChangesPanelDragStartWidth: CGFloat?

    let appState: AppState
    let settings: SettingsStore
    let featureStore: ShellFeatureStore
    let catalog: SessionCatalogStore
    let agents: AgentDirectoryStore
    let agentEditorPresentation: ChatAgentEditorPresentation?
    let botModeRooms: BotModeRoomStore
    let skillsAndTools: SkillsAndToolsStore
    let hermesWorkspaces: HermesWorkspaceStore
    /// Move to Project… in ⋯; nil where the chat can't move (a group chat, a computer that can't).
    let projectMove: ChatProjectMove?
    let userIdentity: UserIdentityStore
    let permissionCenter: PermissionCenter
    let responseHapticsCoveredByRoot: Bool
    let appearanceAuthority: WorkspaceAuthority?
    let headerActions: ChatHeaderActions
    let onNewChat: () -> Void
    /// Settings › AI providers (a failed turn's Fix sign-in).
    let onOpenProviderAccounts: () -> Void
    let onNewBotChat: (() -> Void)?
    let onContinueInBranch: ((ChatBranchContinuation) -> Void)?
    let consumesSendOnOpen: ((String) -> Bool)?
    /// An edge swipe's place (Settings › Chat › Swipe from the edges), the same as from any other screen.
    let onEdgeAction: (WorkspaceSwipeAction) -> Void
    let onOpenAgentSessions: (String) -> Void
    let onOpenApproval: (ApprovalRequest) -> Void
    let onForkMessage: ((String) -> Void)?
    /// Code mode sessions: Markdown paths in messages open the viewer.
    let hostFiles: HostFileLinkContext?
    /// ••• › Files: the chat's working folder on the computer. Asked for when Files opens, so it
    /// reads the connection there is then; nil (a group chat) lists the chat's own attachments.
    let chatFolders: (() -> ChatFolderContext?)?
    /// One home: New chat's parts, for its blank chat only. The shell decides that from the chat's
    /// id; this view only hands them on, and never reads the chat's messages to decide.
    let newChat: ChatNewChatSlot?

    private var nativeSessionControls: NativeSessionControlsPresentation? {
        guard let native = model.nativeConversationClient else { return nil }
        return NativeSessionControlsPresentation(
            client: native, connectionGeneration: native.sessionActionsConnectionGeneration,
            isSessionRunning: native.sessionActionsAreRunning,
            onReconcileHistory: { [weak native] original, _ in
                guard let native, original === native, model.nativeConversationClient === original else {
                    throw WorkspaceClientError.ownerChanged
                }
                let generation = original.sessionActionsConnectionGeneration
                let source = try catalog.restoreSessionContent(id: model.conversationID)
                let refreshed = try await catalog.refreshAfterNativeHistoryMutation(id: model.conversationID)
                guard model.nativeConversationClient === original,
                      original.sessionActionsConnectionGeneration == generation else {
                    throw WorkspaceClientError.ownerChanged
                }
                _ = try featureStore.installSessionStateSnapshot(
                    SessionHydrationPage(record: refreshed, nextOffset: nil), source: source)
                model.flushPersistence()
            })
    }

    init(
        model: ChatModel,
        appState: AppState,
        settings: SettingsStore,
        featureStore: ShellFeatureStore,
        catalog: SessionCatalogStore,
        agents: AgentDirectoryStore,
        agentEditorPresentation: ChatAgentEditorPresentation?,
        botModeRooms: BotModeRoomStore,
        skillsAndTools: SkillsAndToolsStore,
        hermesWorkspaces: HermesWorkspaceStore,
        projectMove: ChatProjectMove? = nil,
        projectGitClient: any ProjectGitClient,
        userIdentity: UserIdentityStore,
        permissionCenter: PermissionCenter,
        responseHapticsCoveredByRoot: Bool,
        onNewChat: @escaping () -> Void,
        onOpenProviderAccounts: @escaping () -> Void,
        onNewBotChat: (() -> Void)? = nil,
        onContinueInBranch: ((ChatBranchContinuation) -> Void)? = nil,
        consumesSendOnOpen: ((String) -> Bool)? = nil,
        onEdgeAction: @escaping (WorkspaceSwipeAction) -> Void,
        onOpenAgentSessions: @escaping (String) -> Void,
        onOpenApproval: @escaping (ApprovalRequest) -> Void,
        onForkMessage: ((String) -> Void)?,
        appearanceAuthority: WorkspaceAuthority? = nil,
        hostFiles: HostFileLinkContext? = nil,
        chatFolders: (() -> ChatFolderContext?)? = nil,
        newChat: ChatNewChatSlot? = nil
    ) {
        self.model = model
        self.appState = appState
        self.settings = settings
        self.featureStore = featureStore
        self.catalog = catalog
        self.agents = agents
        self.agentEditorPresentation = agentEditorPresentation
        self.botModeRooms = botModeRooms
        self.skillsAndTools = skillsAndTools
        self.hermesWorkspaces = hermesWorkspaces
        self.projectMove = projectMove
        _projectChanges = State(initialValue: ProjectChangesStore(client: projectGitClient))
        self.userIdentity = userIdentity
        self.permissionCenter = permissionCenter
        self.responseHapticsCoveredByRoot = responseHapticsCoveredByRoot
        self.appearanceAuthority = appearanceAuthority
        self.hostFiles = hostFiles
        self.chatFolders = chatFolders
        self.newChat = newChat
        self.headerActions = ChatHeaderActions(newChat: onNewChat)
        self.onNewChat = onNewChat
        self.onOpenProviderAccounts = onOpenProviderAccounts
        self.onNewBotChat = onNewBotChat
        self.onContinueInBranch = onContinueInBranch
        self.consumesSendOnOpen = consumesSendOnOpen
        self.onEdgeAction = onEdgeAction
        self.onOpenAgentSessions = onOpenAgentSessions
        self.onOpenApproval = onOpenApproval
        self.onForkMessage = onForkMessage
    }

    var body: some View {
        let _ = ChatPerformanceProbe.count("chat.destination.body")
        chatCanvas
            .modifier(TeamCallEntry(chat: model, rooms: botModeRooms, services: featureStore.teamCallServices,
                                    agents: agents, userIdentity: userIdentity,
                                    transcription: settings.voiceTranscription,
                                    permissionCenter: permissionCenter))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.canvas")
            .background {
                ChatReplyReading(model: model, reader: replyReader,
                                 isOn: settings.autoSpeakRepliesEnabled && voicePresentation == nil && voiceBar == nil,
                                 rate: settings.voiceSpeed.hermesTTSSpeed,
                                 makeOutput: { featureStore.makeReplySpeech(for: model.conversationID) })
            }
        .chatAttention(client: model.nativeConversationClient,
                       agentName: identity?.name ?? model.workingAgentName,
                       isPresented: $isNativeAttentionPresented, canPopUp: canPopUpAttention)
        .onAppear {
            armAttentionAutoOpen()
            isHapticsSurfaceVisible = true
            if featureStore.ownsNativeNavigationHydration {
                featureStore.retainModels(ownedBy: appState.path)
            }
        }
        .onDisappear {
            isHapticsSurfaceVisible = false
            // NavigationStack updates its path before the outgoing destination
            // finishes disappearing. Retain its prepared model until this
            // lifecycle boundary so the pop cannot replace it with the route
            // unavailable fallback mid-transition.
            featureStore.retainModels(ownedBy: appState.path)
        }
        .onReceive(model.responseTextGrowth) { event in
            responseHaptics.receive(
                event,
                conversationID: model.conversationID,
                isEnabled: settings.responseHapticsEnabled,
                isSceneActive: scenePhase == .active,
                isVisible: isResponseHapticsVisible && responseHaptics.isSurfaceUncovered
            )
        }
    }

    private var isResponseHapticsVisible: Bool {
        guard isHapticsSurfaceVisible,
              appState.path.last == .chat(conversationID: model.conversationID),
              case .chat(let current)? = featureStore.preparedModel(
                for: .chat(conversationID: model.conversationID)
              ), current === model else { return false }
        return !responseHapticsCoveredByRoot
            && !isNativeAttentionPresented
            && voicePresentation == nil && !isPeopleAndChatPresented && !isProjectMovePresented
            && !isPhotoPickerPresented && !isDrawingPresented
            && !isFilePickerPresented && !isCameraPickerPresented && !isDocumentScannerPresented
            && !isProjectChangesPresented
            && attachmentErrorMessage == nil
    }

    /// The chat is on screen and nothing the person moved to covers it.
    /// Attachment pickers and model controls are part of using the chat.
    private var isChatInFront: Bool {
        appState.path.last == .chat(conversationID: model.conversationID)
            && !responseHapticsCoveredByRoot && !isNativeAttentionPresented
            && voicePresentation == nil
            && !isPeopleAndChatPresented && !isSessionFilesPresented && !isProjectMovePresented
            && !isProjectChangesPresented
    }

    /// A question or approval may pop up over the chat: it's on screen, the app
    /// is in front, and nothing else (a picker, a sheet, voice) is up.
    private var canPopUpAttention: Bool {
        scenePhase == .active && voicePresentation == nil
            && appState.path.last == .chat(conversationID: model.conversationID)
            && !responseHapticsCoveredByRoot
            && !isPeopleAndChatPresented && !isSessionFilesPresented && !isProjectMovePresented
            && !isProjectChangesPresented
            && !isDrawingPresented
            && !isPhotoPickerPresented && !isFilePickerPresented
            && !isCameraPickerPresented && !isDocumentScannerPresented
    }

    /// Coming back to this chat reloads it exactly like Force Refresh, so it is
    /// never left showing what it looked like before the person stepped away.
    private func refreshOnReturn() {
        guard !model.isBotMode else { return }
        // A chat whose open failed has no connection of its own yet: coming back opens it again.
        guard model.nativeConversationClient != nil else {
            featureStore.reopenFailedChat(id: model.conversationID)
            return
        }
        let id = model.conversationID
        Task { @MainActor in try? await featureStore.forceRefreshSession(id: id) }
    }

    /// The computer this chat is on (`cacheScopeID`), which an agent's own voice choices are kept under.
    var voiceComputer: String? {
        (model.nativeConversationClient?.nativeWorkspaceAuthority ?? appearanceAuthority)?.cacheScopeID
    }

    /// The agent voice speaks for: the chat's own, else its first.
    var voiceAgentID: String? { model.nativeConversationClient?.profile ?? model.memberIDs.first }

    /// How voice opens here: the agent's own choice from its Default Voice, else Settings › Voice.
    var agentVoice: AgentVoicePreference {
        settings.voicePreference(computer: voiceComputer, agentID: voiceAgentID)
    }

    func makeVoice(_ mode: VoiceConversationMode) -> VoicePresentation {
        let voice = agentVoice
        return featureStore.makeVoicePresentation(
            for: model.conversationID,
            mode: settings.voiceMode,
            transcription: settings.voiceTranscription,
            conversationMode: mode,
            liveProvider: voice.liveProvider,
            liveVoice: voice.liveVoice
        )
    }

    /// Opens voice here, in the bar over a Bots mode chat when `inBar`. Live voice needs the chat's
    /// session on the computer, and a chat that opened a moment ago (a cold Start voice chat, a tap
    /// right after opening) is still getting it. Voice waits for it under the starting cover; it
    /// once asked at once and showed "This chat is still opening" a second before it could start.
    func openVoice(inBar: Bool = false) async {
        guard await waitForChatBeforeLiveVoice() else { return }
        let presentation = makeVoice(agentVoice.mode)
        if inBar {
            withAnimation(.snappy(duration: 0.25)) { voiceBar = presentation }
            // The cover's own end follows the full-screen voice; the bar ends it here.
            VoiceLaunchState.shared.finish()
        } else {
            voicePresentation = presentation
        }
    }

    /// False when the wait was cancelled (the person moved on), so nothing opens.
    func waitForChatBeforeLiveVoice() async -> Bool {
        guard agentVoice.mode == .codexLive,
              featureStore.liveVoiceUnavailable(in: model.conversationID)?.passesByItself == true else { return true }
        let launch = VoiceLaunchState.shared
        // A Shortcut's start already shows the cover; a tap in the chat gets it for the wait.
        let startedCover = !launch.isStarting
        if startedCover {
            let profile = voiceAgentID.flatMap { id in agents.profiles.first { $0.id == id } }
            launch.begin(agent: profile.map { .init(id: $0.id, name: $0.name, imageURL: agents.avatarURL(for: $0)) })
        }
        await featureStore.waitForLiveVoice(in: model.conversationID)
        guard !Task.isCancelled else {
            if startedCover { launch.finish() }
            return false
        }
        return true
    }

    /// The voice bar over a Bots mode chat, under its header.
    @ViewBuilder
    private var voiceBarOverlay: some View {
        if let voiceBar, let agentID = model.memberIDs.first {
            let profile = agents.profiles.first { $0.id == agentID }
            SimpleBotVoiceBar(
                presentation: voiceBar, agentID: agentID, agentName: profile?.name ?? "Your bot",
                imageURL: profile.flatMap { agents.avatarURL(for: $0) }, permissionCenter: permissionCenter,
                onSwitchMode: { mode in
                    // The bar is over one bot's chat: the switch is that bot's own choice.
                    settings.setVoiceConversationMode(mode, computer: voiceComputer, agentID: voiceAgentID)
                    self.voiceBar = makeVoice(mode)
                },
                onEnded: { withAnimation(.snappy(duration: 0.25)) { self.voiceBar = nil } }
            )
            .id(voiceBar.id)
            .onChange(of: model.isSending, initial: true) { _, active in
                voiceBar.model.reconcileAgentRun(isActive: active)
            }
            .padding(.top, 72)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Live voice couldn't start: remember turn-based voice (listens on the
    /// phone, answers with the host's text-to-speech) where the agent's voice
    /// type comes from, its own or Settings', and reopen voice with it.
    private func useTurnBasedVoice() {
        settings.useTurnBasedVoice(computer: voiceComputer, agentID: voiceAgentID)
        voicePresentation = makeVoice(.turnBased)
    }

    /// Live voice couldn't start yet (still connecting, or a step on the computer): try it again.
    private func tryLiveVoiceAgain() {
        voicePresentation = makeVoice(agentVoice.mode)
    }

    private var forceRefreshAction: (@MainActor () async throws -> Void)? {
        guard model.nativeConversationClient != nil, !model.isBotMode else { return nil }
        return {
            try await featureStore.forceRefreshSession(id: model.conversationID)
        }
    }

    private var referenceChatCanvas: some View {
        ReferenceChatComposition(model: model, catalog: catalog, featureStore: featureStore,
                                 appState: appState) { referenceHub, sendReferences in
        ChatView(
            model: model,
            agentName: identity?.name ?? model.workingAgentName ?? "Hermes agent",
            agentRole: identity?.role ?? "Hermes agent",
            agentStatus: model.nativeConversationClient == nil ? "Hermes" : "Direct Hermes",
            agents: agents,
            agentEditorPresentation: agentEditorPresentation,
            dashboardModel: featureStore.dashboardModel,
            sessionCatalog: catalog,
            senderResolver: TimelineSenderResolver(userIdentity: userIdentity, agents: agents),
            allModelsRequest: modelPickerRequest,
            projectChangesSummary: showsProjectChanges
                ? projectChanges.railSummary
                : nil,
            composerFocusRequest: attachmentFlow.composerFocusRequest,
            onAttachmentTap: performChatAction,
            onProjectChangesTap: {
                withAnimation(.snappy(duration: 0.28)) {
                    isProjectChangesPresented = true
                }
            },
            onVoiceTap: {
                let inBar = homeChrome.isSimpleBots && model.memberIDs.count == 1
                Task { @MainActor in await openVoice(inBar: inBar) }
            },
            onApprovalTap: onOpenApproval,
            onPeopleTap: { isPeopleAndChatPresented = true },
            onGroupSettingsTap: model.botModeRoomID == nil ? nil : {
                // Read at the tap: this body must not read the room, which changes with each message.
                if let roomID = model.botModeRoom?.nativeRoomID {
                    appState.open(.groupSettings(roomID: roomID, conversationID: model.conversationID))
                } else {
                    isPeopleAndChatPresented = true
                }
            },
            onChatFilesTap: { isSessionFilesPresented = true },
            projectMenuItem: projectMenuItem,
            onNewChatTap: onNewChat,
            onOpenProviderAccounts: model.nativeConversationClient == nil ? nil : onOpenProviderAccounts,
            onNewBotChat: onNewBotChat,
            onContinueInBranch: onContinueInBranch,
            consumesSendOnOpen: consumesSendOnOpen,
            onLoadPreviousMessages: loadPreviousMessages,
            onForkMessage: onForkMessage,
            referenceHub: referenceHub,
            referenceSkills: skillsAndTools,
            onReferenceSend: sendReferences.action,
            foldCompletedTurns: settings.foldCompletedTurns,
            workStyle: settings.chatWorkStyle,
            onForceRefresh: forceRefreshAction,
            newChat: newChat
        )
        }
    }

    /// A file the person sent opens in their bot's Files tab. The plugin's staging folder isn't
    /// one Files shows, so a file still there (an agent without a folder here) doesn't open.
    private var openSentFile: (@MainActor (ChatSentFile) -> Void)? {
        guard !model.isBotMode else { return nil }
        let agentID = model.agentID
        let appState = appState
        return { file in
            guard !file.path.contains("/plugin-data/loopdy/uploads/") else { return }
            appState.open(.simpleBotProfile(agentID: agentID, opening: BotProfileOpening(file: file.path)))
        }
    }

    private var chatCanvas: some View {
        referenceChatCanvas
        // Inside the chat's own link action, so file links open the viewer and the rest reach it.
        .hostFileLinks(hostFiles)
        .environment(\.chatOpenSentFile, openSentFile)
        .environment(\.openURL, chatOpenURLAction)
        .background(ResponseHapticsSurface(controller: responseHaptics))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            // Navigation destinations sit above the root shell, so the root
            // edge gesture surface cannot receive a swipe while a chat is
            // open. Keep a narrow, route-local surface here and route it
            // through the same user-configured actions as the root shell.
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    chatEdgeGestureSurface(
                        side: .left,
                        containerWidth: geometry.size.width
                    )
                    Spacer(minLength: 0)
                    chatEdgeGestureSurface(
                        side: .right,
                        containerWidth: geometry.size.width
                    )
                }
            }
        }
        // Over the edge-swipe strips, so they never take a tap meant for the bar.
        .overlay(alignment: .top) { voiceBarOverlay }
        .overlay(alignment: .trailing) {
            if horizontalSizeClass == .regular, isProjectChangesPresented {
                GeometryReader { geometry in
                    let panelWidth = ProjectChangesPanelWidthPolicy.clamp(
                        width: projectChangesPanelWidth,
                        containerWidth: geometry.size.width
                    )
                    ZStack(alignment: .trailing) {
                        HStack(spacing: 0) {
                            Button(action: dismissProjectChanges) {
                                Rectangle()
                                    .fill(theme.primaryText.opacity(0.001))
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .frame(width: max(geometry.size.width - panelWidth, 0))
                            .frame(maxHeight: .infinity)
                            .accessibilityIdentifier("project-changes.outside-dismiss")
                            .accessibilityLabel("Close project changes")
                            .accessibilityHint("Returns to the chat canvas.")
                            Spacer(minLength: 0)
                        }

                        ZStack(alignment: .leading) {
                            ProjectChangesView(
                                store: projectChanges,
                                showsCloseButton: true,
                                onClose: dismissProjectChanges,
                                isExpanded: projectChangesPanelWidth >= geometry.size.width * 0.9,
                                onToggleExpansion: {
                                    let width = projectChangesPanelWidth >= geometry.size.width * 0.9
                                        ? ProjectChangesPanelWidthPolicy.minimum
                                        : geometry.size.width
                                    if reduceMotion {
                                        projectChangesPanelWidth = width
                                    } else {
                                        withAnimation(.snappy(duration: 0.24)) {
                                            projectChangesPanelWidth = width
                                        }
                                    }
                                }
                            )
                            Rectangle()
                                .fill(theme.primaryText.opacity(0.001))
                                .frame(width: 32)
                                .contentShape(.rect)
                                .overlay {
                                    Capsule()
                                        .fill(theme.secondaryText.opacity(0.35))
                                        .frame(width: 4, height: 48)
                                }
                                .accessibilityIdentifier("project-changes.resize-handle")
                                .accessibilityLabel("Resize project changes panel")
                                .accessibilityHint("Drag left to expand the panel, or right to shrink it.")
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 8)
                                        .onChanged { value in
                                            let startWidth = projectChangesPanelDragStartWidth
                                                ?? projectChangesPanelWidth
                                            if projectChangesPanelDragStartWidth == nil {
                                                projectChangesPanelDragStartWidth = startWidth
                                            }
                                            projectChangesPanelWidth = ProjectChangesPanelWidthPolicy.clamp(
                                                width: startWidth - value.translation.width,
                                                containerWidth: geometry.size.width
                                            )
                                        }
                                        .onEnded { value in
                                            guard let startWidth = projectChangesPanelDragStartWidth else { return }
                                            projectChangesPanelDragStartWidth = nil
                                            let snapped = ProjectChangesPanelWidthPolicy.snappedWidth(
                                                startWidth: startWidth,
                                                translation: value.translation.width,
                                                containerWidth: geometry.size.width
                                            )
                                            if reduceMotion {
                                                projectChangesPanelWidth = snapped
                                            } else {
                                                withAnimation(.snappy(duration: 0.24)) {
                                                    projectChangesPanelWidth = snapped
                                                }
                                            }
                                        }
                                )
                        }
                        .frame(width: panelWidth)
                        .background(theme.canvas)
                        .overlay(alignment: .leading) { Divider() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(4)
            }
        }
        .onChange(of: isChatInFront) { wasInFront, isInFront in
            if !wasInFront, isInFront { refreshOnReturn() }
        }
        .bighelpSheet(isPresented: $isPeopleAndChatPresented, onDismiss: {
            if requestsSessionFilesAfterDetails {
                requestsSessionFilesAfterDetails = false
                isSessionFilesPresented = true
            }
        }) {
            PeopleAndChatView(model: model, agents: agents,
                nativeSessionControls: nativeSessionControls,
                filesAction: ChatSessionFilesAction {
                    requestsSessionFilesAfterDetails = true
                    isPeopleAndChatPresented = false
                })
        }
        .bighelpSheet(isPresented: $isSessionFilesPresented) {
            if let folders = chatFolders?() {
                ChatFolderBrowserView(context: folders)
                    .bighelpSheetSize(.large)
            } else {
                ChatSessionFilesView(model: model)
            }
        }
        .bighelpSheet(isPresented: $isProjectMovePresented) {
            if let projectMove {
                MoveChatToProjectSheet(move: projectMove, chatTitle: model.sessionTitle, agentID: model.agentID,
                                       sessionID: model.conversationID, currentProjectID: currentProject?.id)
            }
        }
        .onChange(of: voicePresentation != nil) { _, isPresented in
            if isPresented { VoiceLaunchState.shared.finish() }
        }
        .bighelpFullScreenCover(item: $voicePresentation, onDismiss: {
            // One home: a chat has no ☰, so this does nothing there; it goes with the voice screen's ☰.
            guard opensMenuAfterVoice else { return }
            opensMenuAfterVoice = false
            homeChrome.onMenu()
        }) { presentation in
            VoicePresentationContainer(
                presentation: presentation,
                agentID: model.memberIDs.first,
                agentImageURL: model.memberIDs.first
                    .flatMap { id in agents.profiles.first { $0.id == id } }
                    .flatMap { agents.avatarURL(for: $0) },
                permissionCenter: permissionCenter,
                onEnded: { voicePresentation = nil },
                onWorkspaceTap: openMenuFromVoice,
                onUseTurnBased: useTurnBasedVoice,
                onTryAgain: tryLiveVoiceAgain,
                chatActivity: { [model] in model.liveActivityKind },
                chatStep: { [model] in model.liveStepPhrase }
            )
            .onChange(of: model.isSending, initial: true) { _, active in
                presentation.model.reconcileAgentRun(isActive: active)
            }
            .interactiveDismissDisabled()
        }
        // What the plus menu opens. They hang on the chat itself: the menu is gone by the time one shows.
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoSelections,
            maxSelectionCount: max(0, 10 - model.draftAttachments.count),
            matching: .images
        )
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .bighelpFullScreenCover(isPresented: $isCameraPickerPresented) {
            ChatCameraPicker(
                onCapture: { image in
                    isCameraPickerPresented = false
                    importCameraImage(image)
                },
                onCancel: { isCameraPickerPresented = false }
            )
            .ignoresSafeArea()
        }
        #if !targetEnvironment(macCatalyst)
        .bighelpFullScreenCover(isPresented: $isDocumentScannerPresented, onDismiss: finishDocumentScan) {
            ChatDocumentScanner { result in
                documentScanResult = result
                isDocumentScannerPresented = false
            }
            .ignoresSafeArea()
        }
        #endif
        .bighelpSheet(isPresented: $isDrawingPresented) {
            ChatDrawingSheet(
                onAdd: { image in
                    isDrawingPresented = false
                    importDrawing(image)
                },
                onCancel: { isDrawingPresented = false }
            )
        }
        .navigationDestination(isPresented: compactProjectChangesPresentation) {
            ProjectChangesView(
                store: projectChanges,
                showsCloseButton: false,
                onClose: {},
            )
        }
        .task(id: projectChangesBindingTrigger) {
            let agentID = model.memberIDs.first ?? "default"
            var workspaceID = hermesWorkspaces.workspaceID(
                forSessionID: model.conversationID
            )
            if hermesWorkspaces.catalogAgentID != agentID {
                workspaceID = nil
            }
            if workspaceID == nil && model.sessionWorkspaceID == nil {
                await hermesWorkspaces.load(
                    agentID: agentID,
                    sessionID: model.conversationID
                )
                workspaceID = hermesWorkspaces.workspaceID(
                    forSessionID: model.conversationID
                )
            }
            let loadedWorkspaceName = hermesWorkspaces.catalog?.workspaces.first {
                $0.id == workspaceID
            }?.name
            let target = ProjectChangesTargetResolver.target(
                agentID: agentID,
                sessionID: model.conversationID,
                restoredWorkspaceID: model.sessionWorkspaceID,
                restoredWorkspaceName: model.sessionWorkspaceName,
                loadedWorkspaceID: workspaceID,
                loadedWorkspaceName: loadedWorkspaceName
            )
            if !showsProjectChanges {
                await projectChanges.bind(target: nil, enabled: false)
            } else {
                await projectChanges.bind(
                    target: target,
                    enabled: showsProjectChanges
                )
            }
        }
        .modifier(ProjectChangesRefreshTrigger(model: model) { projectChanges.requestRefresh() })
        .modifier(PendingShareIntake(model: model, appState: appState, scope: voiceComputer))
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            projectChanges.requestRefresh()
            armAttentionAutoOpen()
        }
        .onChange(of: model.nativeConversationClient?.prompts.map(\.id) ?? []) { _, _ in
            presentAttentionIfArmed()
        }
        .onChange(of: photoSelections) { _, selections in
            guard !selections.isEmpty else { return }
            Task { await importPhotos(selections) }
        }
        // By chat as well as text: a new chat's blank canvas hands this view to the chat Hermes made,
        // and that chat takes the text then.
        .task(id: PendingComposerText(conversationID: model.conversationID, text: appState.pendingComposerText)) {
            // Only the chat on top takes the board's text: a new chat, or, from a bot's Dashboard,
            // that bot's own chat, history and all.
            let isOnTop = appState.path.last == .chat(conversationID: model.conversationID)
            if model.isAwaitingAuthoritativeSessionAllocation {
                // The blank canvas shows the text at once, however long the computer takes, but
                // doesn't take it: the canvas goes when the chat arrives, and its draft doesn't
                // always get across in time.
                guard isOnTop, model.draft.isEmpty, let shown = appState.showComposerText() else { return }
                if !(shown.fillsBlanks && model.beginBlueprintDraft(shown.text)) { model.draft = shown.text }
                return
            }
            let isNamedBotChat = isOnTop && appState.pendingComposerAgentID.map { model.memberIDs == [$0] } == true
            guard let pending = appState.takeComposerText(isNewChat: isOnTop && model.transcriptEntries.isEmpty,
                                                          isNamedBotChat: isNamedBotChat) else { return }
            if pending.sendsAtOnce {
                // Let's do it: a message of its own, whatever the box holds. If it can't go, it
                // waits in an empty box for Send. Taking the text restarts this task, so the send
                // runs on its own.
                Task { [model] in
                    if await !model.sendFromOutside(pending.text), model.draft.isEmpty { model.draft = pending.text }
                }
                return
            }
            if pending.wasShown, !model.draft.isEmpty {
                // It came across from the canvas, with whatever the person changed there. Its chips
                // came too (`prepareNewChat`), unless the text is still as the blueprint wrote it.
                if pending.fillsBlanks, model.blueprintDraft == nil, model.draft == pending.text {
                    model.beginBlueprintDraft(pending.text)
                }
                return
            }
            // Something typed already stays: the text goes below it.
            guard model.draft.isEmpty else {
                model.draft += "\n\n" + pending.text
                return
            }
            // A blueprint's blanks show as chips; anything else, or one with no blanks, is plain text.
            if pending.fillsBlanks, model.beginBlueprintDraft(pending.text) { return }
            model.draft = pending.text
        }
        .task(id: appState.pendingVoiceConversationID) {
            // The request stays until voice can open, so withdrawing it (another computer, another
            // screen) cancels this wait.
            guard appState.pendingVoiceConversationID == model.conversationID,
                  await waitForChatBeforeLiveVoice(),
                  appState.consumeVoiceRequest(for: model.conversationID) else { return }
            voicePresentation = makeVoice(agentVoice.mode)
        }
        .onChange(of: isCameraPickerPresented) { wasPresented, isPresented in
            guard wasPresented && !isPresented else { return }
            Task {
                await reflectiveVisionCamera?.update(enabled: reflectiveVisionEnabled)
            }
        }
        .alert(
            "Attachment unavailable",
            isPresented: Binding(
                get: { attachmentErrorMessage != nil },
                set: {
                    if !$0 {
                        attachmentErrorMessage = nil
                        attachmentRecoveryKind = nil
                    }
                }
            )
        ) {
            if let kind = attachmentRecoveryKind {
                Button("Open System Settings") {
                    permissionCenter.performRecoveryAction(for: kind)
                    attachmentRecoveryKind = nil
                    attachmentErrorMessage = nil
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentErrorMessage ?? "That attachment could not be added.")
        }
    }

    /// Maps, Music and other apps' links open in their apps; web pages in the browser picked in
    /// Settings › Chat (`ChatLinkRoute`).
    private var chatOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            let browser = settings.preferredBrowser
            let isInstalled = browser.availabilityProbeURL.map { UIApplication.shared.canOpenURL($0) } ?? true
            switch ChatLinkRoute.route(url, browser: browser, browserIsInstalled: isInstalled) {
            case .system:
                return .systemAction
            case .appElseBrowser(let browserURL):
                Task { @MainActor in
                    if await UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { return }
                    await UIApplication.shared.open(browserURL)
                }
                return .handled
            }
        }
    }

    private var projectChangesBindingTrigger: String {
        let agentID = model.memberIDs.first ?? "default"
        let workspaceID = hermesWorkspaces.workspaceID(
            forSessionID: model.conversationID
        ) ?? "none"
        return [
            agentID,
            model.conversationID,
            model.sessionWorkspaceID ?? "none",
            model.sessionWorkspaceName ?? "none",
            workspaceID,
            String(showsProjectChanges),
        ].joined(separator: "|")
    }

    /// File changes (git diffs for a chat's Hermes project), in ⋯ with Nerd Mode on or off.
    private var showsProjectChanges: Bool {
        settings.showProjectChanges
    }

    /// The chat's project as Hermes last reported it: a load or a move this run, else the saved chat.
    private var currentProject: (id: String, name: String?)? {
        if let id = hermesWorkspaces.workspaceID(forSessionID: model.conversationID) {
            let name = model.sessionWorkspaceID == id ? model.sessionWorkspaceName : nil
            return (id, name ?? hermesWorkspaces.catalog?.workspaces.first { $0.id == id }?.name)
        }
        return model.sessionWorkspaceID.map { ($0, model.sessionWorkspaceName) }
    }

    /// ⋯ › Move to Project…, showing the chat's project.
    private var projectMenuItem: ChatProjectMenuItem? {
        guard projectMove != nil else { return nil }
        return ChatProjectMenuItem(projectName: currentProject?.name) { isProjectMovePresented = true }
    }

    private var compactProjectChangesPresentation: Binding<Bool> {
        Binding(
            get: { horizontalSizeClass != .regular && isProjectChangesPresented },
            set: { presented in
                if !presented {
                    isProjectChangesPresented = false
                }
            }
        )
    }

    private func dismissProjectChanges() {
        guard isProjectChangesPresented else { return }
        if reduceMotion {
            isProjectChangesPresented = false
        } else {
            withAnimation(.snappy(duration: 0.24)) {
                isProjectChangesPresented = false
            }
        }
    }

    private enum ChatEdgeSide {
        case left
        case right
    }

    @ViewBuilder
    private func chatEdgeGestureSurface(
        side: ChatEdgeSide,
        containerWidth: CGFloat
    ) -> some View {
        let action = side == .left ? settings.leftEdgeSwipeAction : settings.rightEdgeSwipeAction
        Color.clear
            .frame(width: WorkspaceEdgeSwipeResolver.activationEdgeWidth)
            .contentShape(Rectangle())
            .allowsHitTesting(action != .none)
            .highPriorityGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onEnded { value in
                        let startX = side == .left
                            ? value.startLocation.x
                            : containerWidth
                                - WorkspaceEdgeSwipeResolver.activationEdgeWidth
                                + value.startLocation.x
                        guard let resolved = WorkspaceEdgeSwipeResolver.resolve(
                            start: CGPoint(
                                x: startX,
                                y: value.startLocation.y
                            ),
                            translation: value.translation,
                            containerWidth: containerWidth,
                            leftAction: settings.leftEdgeSwipeAction,
                            rightAction: settings.rightEdgeSwipeAction
                        ) else { return }
                        performChatEdgeAction(resolved)
                    }
            )
            .accessibilityHidden(true)
    }

    private func performChatEdgeAction(_ action: WorkspaceSwipeAction) {
        BighelpKeyboard.dismiss()
        onEdgeAction(action)
    }

    /// ☰ on the voice screen: the one menu, once voice has closed.
    private func openMenuFromVoice() {
        opensMenuAfterVoice = true
        voicePresentation = nil
    }

    private var identity: ChatDestinationAgentIdentity? {
        ChatDestinationAgentResolver(catalog: catalog, agents: agents)
            .resolve(
                sessionID: model.conversationID,
                fallbackName: model.workingAgentName
            )
    }

    @State private var isPeopleAndChatPresented = false

    private var referenceableSessions: [SessionSummary] {
        Array(catalog.recentSummaries.filter { $0.id != model.conversationID }.prefix(50))
    }

    private func loadPreviousMessages() {
        guard model.hasPreviousHistory, !model.isLoadingPreviousHistory else { return }
        model.beginLoadingPreviousHistory()
        Task { @MainActor in
            do {
                _ = try await catalog.hydratePreviousPage(id: model.conversationID)
                guard featureStore.prepare(.chat(conversationID: model.conversationID)) else {
                    model.finishLoadingPreviousHistory(
                        hasPreviousHistory: true,
                        errorMessage: "Previous messages could not be prepared. Try again."
                    )
                    return
                }
                model.finishLoadingPreviousHistory(
                    hasPreviousHistory: catalog.hasPreviousHistory(id: model.conversationID)
                )
            } catch is CancellationError {
                model.finishLoadingPreviousHistory(
                    hasPreviousHistory: catalog.hasPreviousHistory(id: model.conversationID)
                )
            } catch {
                model.finishLoadingPreviousHistory(
                    hasPreviousHistory: true,
                    errorMessage: "Previous messages could not be loaded. Try again."
                )
            }
        }
    }

    @BighelpThemeReader private var theme

    @Environment(\.reflectiveVisionEnabled) var reflectiveVisionEnabled
    @Environment(\.reflectiveVisionCamera) var reflectiveVisionCamera
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.agentHomeChrome) private var homeChrome

    private func armAttentionAutoOpen() {
        attentionAutoOpenUntil = .now.addingTimeInterval(8)
        presentAttentionIfArmed()
    }

    /// Closes the keyboard and opens what's waiting, so it isn't hidden behind
    /// the header with the keyboard up.
    private func presentAttentionIfArmed() {
        guard let until = attentionAutoOpenUntil, until > .now,
              let native = model.nativeConversationClient, !native.prompts.isEmpty,
              !isNativeAttentionPresented, voicePresentation == nil else { return }
        attentionAutoOpenUntil = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isNativeAttentionPresented = true
    }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

struct ChatDestinationAgentIdentity: Equatable {
    let name: String
    let role: String
}

@MainActor
struct ChatDestinationAgentResolver {
    let catalog: SessionCatalogStore
    let agents: AgentDirectoryStore

    func resolve(sessionID: String) -> ChatDestinationAgentIdentity? {
        guard let session = catalog.session(id: sessionID) else { return nil }
        let fallbackName = session.items.reversed().first { item in
            item.role == .assistant
                && item.sender.kind == .agent
                && (session.agentIDs.isEmpty || session.agentIDs.contains(item.sender.id))
        }?.sender.snapshot.name
        return resolve(sessionID: sessionID, fallbackName: fallbackName)
    }

    func resolve(
        sessionID: String,
        fallbackName: String?
    ) -> ChatDestinationAgentIdentity? {
        if let agentID = catalog.session(id: sessionID)?.agentIDs.first,
           let agent = agents.profiles.first(where: { $0.id == agentID }) {
            return ChatDestinationAgentIdentity(name: agent.name, role: agent.role)
        }
        guard let fallbackName else { return nil }
        let normalized = fallbackName
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return ChatDestinationAgentIdentity(name: normalized, role: "Hermes agent")
    }
}

/// Project Changes looks again whenever the chat's work moves on. The chat's messages and work are
/// read here, in a modifier of their own: read in `ChatDestinationView`'s body, every streamed piece
/// of an answer redrew the whole chat screen and handed every view in it a new link action, so even
/// the message box's text view updated on each piece.
private struct ProjectChangesRefreshTrigger: ViewModifier {
    let model: ChatModel
    let refresh: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: trigger) { _, _ in refresh() }
    }

    private var trigger: String {
        let lastActivity = model.activityTurns.last?.events.last
        let activityRevision = lastActivity.map {
            "\($0.eventID):\($0.lifecycle.rawValue)"
        } ?? "none"
        return [
            String(model.items.count),
            model.items.last?.id ?? "none",
            activityRevision,
            String(model.isSending),
        ].joined(separator: "|")
    }
}
