import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct ChatDestinationView: View {
    let model: ChatModel
    @State private var sessionAppearance: SessionAppearanceStore?
    @State private var isSessionFilesPresented = false
    @State private var isChatAppearancePresented = false
    @State private var requestsSessionFilesAfterDetails = false
    @State private var isNativeAttentionPresented = false
    /// Briefly after the chat opens or the app returns (a Dynamic Island or
    /// notification tap), a question or approval waiting on you opens focused.
    @State private var attentionAutoOpenUntil: Date?
    @State private var isNativeSessionControlsPresented = false
    #if targetEnvironment(macCatalyst)
    @State var pendingMacPanelRequest: BighelpMacChatPanelRequest?
    #else
    @State private var requestsNativeControlsAfterMenu = false
    #endif
    @State private var responseHaptics = ResponseHapticsController()
    @State private var isHapticsSurfaceVisible = false
    @State private var projectChanges: ProjectChangesStore
    @State var voicePresentation: VoicePresentation?
    @State var attachmentFlow = ChatAttachmentFlowState()
    @State var isPhotoPickerPresented = false
    @State var isFilePickerPresented = false
    @State var isCameraPickerPresented = false
    @State var isDocumentScannerPresented = false
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
    let userIdentity: UserIdentityStore
    let permissionCenter: PermissionCenter
    let selectedTab: AppTab?
    let sessionOrganizationAccountID: String?
    let sessionOrganizationHostID: String?
    let responseHapticsCoveredByRoot: Bool
    let appearanceAuthority: WorkspaceAuthority?
    let headerActions: ChatHeaderActions
    let onNewChat: () -> Void
    let onStartSession: () -> Void
    /// An edge swipe's place (Settings › Chat › Swipe from the edges), the same as from any other screen.
    let onEdgeAction: (WorkspaceSwipeAction) -> Void
    let onOpenAgentSessions: (String) -> Void
    let onOpenApproval: (ApprovalRequest) -> Void
    let onForkMessage: ((String) -> Void)?

    private var currentAppearanceScope: SessionAppearanceScope? {
        let authority = model.nativeConversationClient?.nativeWorkspaceAuthority ?? appearanceAuthority
        let account = authority.map { value in
            [value.kind.rawValue, value.providerID ?? "", value.principalID]
                .map { "\($0.utf8.count):\($0)" }.joined()
        } ?? sessionOrganizationAccountID
        let host = authority.map { value in
            [value.endpointIdentity, value.hostID].map { "\($0.utf8.count):\($0)" }.joined()
        } ?? sessionOrganizationHostID
        guard let account, let host,
              let profile = model.nativeConversationClient?.profile ?? (model.isBotMode ? "bot-mode" : model.memberIDs.first) else { return nil }
        return try? SessionAppearanceScope(accountID: account, hostID: host, profileID: profile, sessionID: model.conversationID)
    }

    private func reconcileAppearanceStore() {
        let scope = currentAppearanceScope
        guard sessionAppearance?.scope != scope || sessionAppearance?.isRetired == true else { return }
        sessionAppearance?.retire()
        sessionAppearance = scope.map { SessionAppearanceStore(scope: $0) }
    }

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
        projectGitClient: any ProjectGitClient,
        userIdentity: UserIdentityStore,
        permissionCenter: PermissionCenter,
        selectedTab: AppTab?,
        sessionOrganizationAccountID: String?,
        sessionOrganizationHostID: String?,
        responseHapticsCoveredByRoot: Bool,
        onNewChat: @escaping () -> Void,
        onStartSession: @escaping () -> Void,
        onEdgeAction: @escaping (WorkspaceSwipeAction) -> Void,
        onOpenAgentSessions: @escaping (String) -> Void,
        onOpenApproval: @escaping (ApprovalRequest) -> Void,
        onForkMessage: ((String) -> Void)?,
        appearanceAuthority: WorkspaceAuthority? = nil
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
        _projectChanges = State(initialValue: ProjectChangesStore(client: projectGitClient))
        self.userIdentity = userIdentity
        self.permissionCenter = permissionCenter
        self.selectedTab = selectedTab
        self.sessionOrganizationAccountID = sessionOrganizationAccountID
        self.sessionOrganizationHostID = sessionOrganizationHostID
        self.responseHapticsCoveredByRoot = responseHapticsCoveredByRoot
        self.appearanceAuthority = appearanceAuthority
        self.headerActions = ChatHeaderActions(newChat: onNewChat)
        self.onNewChat = onNewChat
        self.onStartSession = onStartSession
        self.onEdgeAction = onEdgeAction
        self.onOpenAgentSessions = onOpenAgentSessions
        self.onOpenApproval = onOpenApproval
        self.onForkMessage = onForkMessage
    }

    var body: some View {
        chatCanvas
            .modifier(TeamCallEntry(chat: model, rooms: botModeRooms, services: featureStore.teamCallServices,
                                    agents: agents, userIdentity: userIdentity,
                                    transcription: settings.voiceTranscription,
                                    permissionCenter: permissionCenter))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.canvas")
        .chatAttention(client: model.nativeConversationClient,
                       agentName: identity?.name ?? model.workingAgentName,
                       isPresented: $isNativeAttentionPresented, canPopUp: canPopUpAttention)
        .onChange(of: currentAppearanceScope, initial: true) { _, _ in reconcileAppearanceStore() }
        .onAppear {
            reconcileAppearanceStore()
            armAttentionAutoOpen()
            isHapticsSurfaceVisible = true
            if featureStore.ownsNativeNavigationHydration {
                featureStore.retainModels(ownedBy: appState.path)
            }
        }
        .onDisappear {
            #if targetEnvironment(macCatalyst)
            pendingMacPanelRequest = nil
            #endif
            sessionAppearance?.retire()
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
            && voicePresentation == nil && !isPeopleAndChatPresented && !isChatAppearancePresented
            && !attachmentFlow.isActionMenuPresented && !isPhotoPickerPresented
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
            && !isPeopleAndChatPresented && !isSessionFilesPresented && !isChatAppearancePresented
            && !isProjectChangesPresented
    }

    /// A question or approval may pop up over the chat: it's on screen, the app
    /// is in front, and nothing else (a picker, a sheet, voice) is up.
    private var canPopUpAttention: Bool {
        scenePhase == .active && voicePresentation == nil
            && appState.path.last == .chat(conversationID: model.conversationID)
            && !responseHapticsCoveredByRoot
            && !isPeopleAndChatPresented && !isSessionFilesPresented && !isChatAppearancePresented
            && !isProjectChangesPresented
            && !isNativeSessionControlsPresented && !attachmentFlow.isActionMenuPresented
            && !isPhotoPickerPresented && !isFilePickerPresented
            && !isCameraPickerPresented && !isDocumentScannerPresented
    }

    /// Coming back to this chat reloads it exactly like Force Refresh, so it is
    /// never left showing what it looked like before the person stepped away.
    private func refreshOnReturn() {
        guard model.nativeConversationClient != nil, !model.isBotMode else { return }
        let id = model.conversationID
        Task { @MainActor in try? await featureStore.forceRefreshSession(id: id) }
    }

    /// Live voice couldn't start: remember turn-based voice in Settings
    /// (listens on the phone, answers with the host's text-to-speech) and
    /// reopen voice with it.
    private func useTurnBasedVoice() {
        settings.voiceConversationMode = .turnBased
        voicePresentation = featureStore.makeVoicePresentation(
            for: model.conversationID,
            mode: settings.voiceMode,
            transcription: settings.voiceTranscription,
            conversationMode: .turnBased,
            liveProvider: settings.liveVoiceProvider,
            liveVoice: settings.liveVoice(for: settings.liveVoiceProvider)
        )
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
            onAttachmentTap: {
                #if targetEnvironment(macCatalyst)
                pendingMacPanelRequest = nil
                #endif
                attachmentFlow.isActionMenuPresented = true
            },
            onProjectChangesTap: {
                withAnimation(.snappy(duration: 0.28)) {
                    isProjectChangesPresented = true
                }
            },
            onVoiceTap: {
                voicePresentation = featureStore.makeVoicePresentation(
                    for: model.conversationID,
                    mode: settings.voiceMode,
                    transcription: settings.voiceTranscription,
                    conversationMode: settings.voiceConversationMode,
                    liveProvider: settings.liveVoiceProvider,
                    liveVoice: settings.liveVoice(for: settings.liveVoiceProvider)
                )
            },
            onApprovalTap: onOpenApproval,
            onPeopleTap: { isPeopleAndChatPresented = true },
            onChatFilesTap: { isSessionFilesPresented = true },
            onChatAppearanceTap: sessionAppearance == nil ? nil : { isChatAppearancePresented = true },
            onSessionToolsTap: nativeSessionControls == nil ? nil : { isNativeSessionControlsPresented = true },
            onNewChatTap: onNewChat,
            onLoadPreviousMessages: loadPreviousMessages,
            onForkMessage: onForkMessage,
            referenceHub: referenceHub,
            referenceSkills: skillsAndTools,
            onReferenceSend: sendReferences.action,
            foldCompletedTurns: settings.foldCompletedTurns,
            sessionAppearance: sessionAppearance?.snapshot ?? .inherited,
            onForceRefresh: forceRefreshAction
        )
        }
    }

    private var chatCanvas: some View {
        referenceChatCanvas
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
                appearanceStore: sessionAppearance,
                nativeSessionControls: nativeSessionControls,
                filesAction: ChatSessionFilesAction {
                    requestsSessionFilesAfterDetails = true
                    isPeopleAndChatPresented = false
                })
        }
        .bighelpSheet(isPresented: $isSessionFilesPresented) {
            ChatSessionFilesView(model: model)
        }
        .bighelpChatPanel(isPresented: $isChatAppearancePresented, anchor: .appearance) {
            if let sessionAppearance {
                NavigationStack { SessionAppearanceView(store: sessionAppearance) }
                    .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: voicePresentation != nil) { _, isPresented in
            if isPresented { VoiceLaunchState.shared.finish() }
        }
        .bighelpFullScreenCover(item: $voicePresentation, onDismiss: {
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
                chatActivity: { [model] in model.liveActivityKind }
            )
            .onChange(of: model.isSending, initial: true) { _, active in
                presentation.model.reconcileAgentRun(isActive: active)
            }
            .interactiveDismissDisabled()
        }
        .bighelpSheet(isPresented: $isNativeSessionControlsPresented) {
            if let presentation = nativeSessionControls {
                NavigationStack { NativeSessionControlsView(presentation: presentation) }
                    .id(presentation.clientIdentity)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .bighelpChatPanel(isPresented: $attachmentFlow.isActionMenuPresented, anchor: .attachments, onDismiss: {
            #if targetEnvironment(macCatalyst)
            attachmentPanelDidDismiss {
                isNativeSessionControlsPresented = model.nativeConversationClient != nil
            }
            #else
            if requestsNativeControlsAfterMenu {
                requestsNativeControlsAfterMenu = false
                isNativeSessionControlsPresented = model.nativeConversationClient != nil
            }
            #endif
        }) {
            ChatActionMenuSheet(
                agentName: identity?.name ?? "your agent",
                agentID: model.memberIDs.first ?? "default",
                sessionID: model.conversationID,
                currentModelName: model.runtimeControls?.modelDisplayName ?? "Session model",
                isCameraAvailable: ChatCameraPicker.isAvailable,
                agents: agents,
                runtimeControls: model.runtimeControls,
                slashCommandCatalog: { model.slashCommandCatalog },
                skillsAndTools: skillsAndTools,
                workspaces: hermesWorkspaces,
                onSelect: performChatAction,
                onChooseAgent: { agent in
                    featureStore.reassignDirectChat(
                        sessionID: model.conversationID,
                        to: agent.id
                    )
                },
                onSelectSlashCommand: model.selectSlashCommand,
                allowsImages: model.supportedAttachmentKinds.contains(.image),
                allowsFiles: model.supportedAttachmentKinds.contains(.file),
                onNativeSessionControls: model.nativeConversationClient == nil ? nil : {
                    #if targetEnvironment(macCatalyst)
                    pendingMacPanelRequest = .nativeSessionControls
                    #else
                    requestsNativeControlsAfterMenu = true
                    #endif
                    attachmentFlow.isActionMenuPresented = false
                }
            )
            #if !targetEnvironment(macCatalyst)
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
            .bighelpFullScreenCover(isPresented: $isDocumentScannerPresented, onDismiss: finishDocumentScan) {
                ChatDocumentScanner { result in
                    documentScanResult = result
                    isDocumentScannerPresented = false
                }
                .ignoresSafeArea()
            }
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
            #endif
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(BighelpTokens.radius20)
        }
        // Native Mac panels need a stable presenter outside the transient
        // popover; presenting from inside it leaves the first click pending.
        #if targetEnvironment(macCatalyst)
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
        #endif
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
        .onChange(of: projectChangesRefreshTrigger) { _, _ in
            projectChanges.requestRefresh()
        }
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
        .task(id: appState.pendingComposerText) {
            // Only a fresh chat takes the board's text, never one already in use.
            guard appState.pendingComposerText != nil, model.transcriptEntries.isEmpty, model.draft.isEmpty,
                  let text = appState.consumeComposerText() else { return }
            model.draft = text
            guard appState.consumeComposerSend() else { return }
            // A new chat connects a moment after it opens; send once it can, and leave the
            // text in the message box if it never does.
            for _ in 0..<60 where !model.canSend {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard model.canSend, model.draft == text else { return }
            await model.send()
        }
        .task(id: appState.pendingVoiceConversationID) {
            guard appState.consumeVoiceRequest(for: model.conversationID) else { return }
            voicePresentation = featureStore.makeVoicePresentation(
                for: model.conversationID,
                mode: settings.voiceMode,
                transcription: settings.voiceTranscription,
                conversationMode: settings.voiceConversationMode,
                liveProvider: settings.liveVoiceProvider,
                liveVoice: settings.liveVoice(for: settings.liveVoiceProvider)
            )
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

    private var chatOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            let browser = settings.preferredBrowser
            guard browser != .systemDefault else { return .systemAction }
            guard
                let probeURL = browser.availabilityProbeURL,
                UIApplication.shared.canOpenURL(probeURL),
                let targetURL = browser.targetURL(for: url)
            else { return .systemAction }
            UIApplication.shared.open(targetURL)
            return .handled
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

    private var projectChangesRefreshTrigger: String {
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

    /// Project Changes (git diffs for a chat's Hermes project) is a developer
    /// tool, so it appears only with Nerd Mode on.
    private var showsProjectChanges: Bool {
        settings.nerdModeEnabled && settings.showProjectChanges
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
        let action = side == .left
            ? settings.leftEdgeSwipeAction
            : settings.rightEdgeSwipeAction
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
