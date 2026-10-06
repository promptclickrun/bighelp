import SwiftUI
import UIKit

@MainActor
struct RootShellView: View {
    #if DEBUG
    @State var voiceSettingsPreview = VoiceSettingsPreviewClient()
    #endif

    @AppStorage("loopdy.onboarding.first-run-v1.completed")
    private var hasCompletedFirstRunOnboarding = false
    @State private var didCompleteForcedFirstRunOnboarding = false
    let appState: AppState
    let settings: SettingsStore
    let featureStore: ShellFeatureStore
    let sessionCatalog: SessionCatalogStore
    let agents: AgentDirectoryStore
    let agentRuntimeDefaults: any AgentRuntimeDefaultsClient
    let botModeRooms: BotModeRoomStore
    let demoHosts: DemoHosts
    let permissionCenter: PermissionCenter
    let personalities: PersonalityStore
    let skillsAndTools: SkillsAndToolsStore
    let hermesWorkspaces: HermesWorkspaceStore
    let projectGitClient: any ProjectGitClient
    let userIdentity: UserIdentityStore
    let newChatCoordinator: NewChatCoordinator
    /// Opens chats asked for from outside the app once the host answers.
    var shortcutService: BighelpShortcutService? = nil
    let usesDemoFixtures: Bool
    let clearLocalCache: @MainActor () async -> Bool
    var nativeRuntime: NativeWorkspaceRuntime? = nil
    var nativeWorkspaceError: String? = nil
    var agentIsland: AgentIslandModel? = nil
    /// Every agent on every host (the all-hosts view), kept across host switches.
    var fleet: FleetStore? = nil

    @Environment(\.bighelpHostRegistry) var hostRegistry
    @Environment(\.managedNotificationService) private var managedNotifications
    @State var actionErrorMessage: String?
    /// Feed, Ideas, Goals and Apps fold the bottom menu while scrolled down.
    /// All hosts: the chat you left for Feed, Ideas or Goals, which the Chat tab goes back to.
    @State var fleetLastChatID: String?
    @State var isHostStatusPresented = false
    @State private var actionErrorShowsHostStatus = false
    @State var hostRuntime: HostRuntimeStore?
    /// A widget or notification link that arrived before the host answered.
    @State private var pendingIncomingURL: URL?
    /// Opens Agents filtered to one agent's group chats (from the Chats rail's menu).
    @State var agentGroupFilterRequest: String?
    @State var agentCreateRequest = false
    /// Offered as "Try Again" in the error alert.
    @State private var actionErrorRetry: (@MainActor () -> Void)?
    @State var isHermesWorkspacePresented = false
    @State var credentialVault: CredentialVaultModel?
    @State var sessionRestoreRequest: SessionRestoreRequest?
    @State var sessionRestoreTask: Task<Void, Never>?
    @State var managementStore: WorkspaceManagementStore?
    /// Host pages open in the stack, one per destination (`WorkspaceOpenScreens`).
    @State var capabilitiesPresentations = WorkspaceOpenScreens<NativeCapabilitiesPresentation>()
    @State var administrationPresentations = WorkspaceOpenScreens<NativeAdministrationPresentation>()
    @State var lifecycleCoordinator: NativeWorkspaceLifecycleCoordinator?
    @State var lifecycleProfileID: String?
    @State var lifecyclePresentationID: UUID?
    @State var workspaceProfileEditor: AgentEditorModel?
    @State var isGroupCreationPresented = false
    @State var groupCreationSeed: String?
    @State var groupCreationOwner: WorkspaceOwner?
    /// The chat header's New chat: one agent starts a 1:1 chat, several a group.
    @State var newChatPicker: NewChatPickerRequest?
    @State var groupSettingsModel: ChatModel?
    @State private var isStartingNewChat = false
    @State private var newChatStartID: UUID?
    @State private var fixtureCanonicalSessions: [String: String] = [:]
    @State var workspaceFixtureGeneration = UUID()
    /// Demo runs' connection; `-demo-reconnects-on-return` makes each return a reconnect.
    @State var workspaceFixtureConnection = UUID()
    @State private var cardInteractionStore = BighelpCardInteractionStore()
    /// The all-hosts view asking which host a one-host screen is for.
    @State var fleetGateRequest: FleetDestination?
    @State var isFleetNewChatPresented = false
    @Environment(\.workspaceConnections) var workspaceConnections
    @Environment(\.scenePhase) var scenePhase
    @State var connectionKeeper = WorkspaceConnectionKeeper()
    /// The computer and sign-in open screens belong to (`WorkspacePresentationContinuity`).
    @State var workspaceSignIn: WorkspaceSignIn?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State var isUnifiedSettingsPresented = false
    @State private var isKeyboardVisible = false
    @State private var rootBottomSafeArea: CGFloat = 0
    @State private var afterSettingsDismiss: (() -> Void)?
    // Agent home (Muse-style): board data, the profile, the switcher and the ☰ drawer.
    @State var agentBoard = AgentBoardStore()
    /// Provider Usage for the connected host; opened from chat ⋯, ☰ and the context window.
    @State var providerUsage = ProviderUsageStore()
    @State var usage = UsageStore()
    @State var agentMedia = AgentMediaStore()
    @State var profileAgentID: String?
    @State var isAgentSwitcherPresented = false
    @State var isHomeDrawerPresented = false
    @State var didAutoOpenHomeChat = false
    /// The open Projects screens' chats and project details.
    @State var projectsStore: ProjectsStore?
    @State var kanbanModel: KanbanBoardModel?
    @State var kanbanAvailability = KanbanAvailability()
    @State var kanbanTaskToOpen: String?
    /// The connected computer's Workflows (☰ › Workflows), when its plugin has them.
    @State var workflowsStore: WorkflowsStore?
    @State var workflowsAvailability = WorkflowsAvailability()
    #if os(visionOS)
    @Environment(\.openWindow) var openWindow
    #endif
    /// Runs after a home sheet closes, so the next sheet can open.
    @State var afterHomeSheet: (@MainActor () -> Void)?

    /// Demo runs show Provider Keys with made-up accounts instead of a host's.
    var demoProviderKeysStore: ProviderAccountsStore? {
        #if DEBUG
        usesWorkspaceFixtures ? DemoProviderKeys.shared : nil
        #else
        nil
        #endif
    }

    var usesWorkspaceFixtures: Bool {
        ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures")
            || ProcessInfo.processInfo.arguments.contains("-disable-demo-delays")
    }

    func chatAgentEditorPresentation(for model: ChatModel) -> ChatAgentEditorPresentation? {
        guard !model.isBotMode, let owner = currentWorkspaceOwner,
              let profileID = model.memberIDs.first,
              agents.profiles.contains(where: { $0.id == profileID }) else { return nil }
        let capabilities = currentWorkspaceCapabilities
        guard capabilities.supports(.profilesEdit, owner: owner, profileID: profileID) else { return nil }
        let canReadDefaults = capabilities.supports(.modelsRead, owner: owner, profileID: profileID)
        let canEditDefaults = capabilities.supports(.agentDefaultsEdit, owner: owner, profileID: profileID)
        let unavailable: WorkspaceCapability? = canReadDefaults
            ? (canEditDefaults ? nil : .agentDefaultsEdit) : .modelsRead
        let readOnlyReason = unavailable.flatMap {
            AgentActionsPresentation.unavailableMessage(capabilities.availability(for: $0, owner: owner, profileID: profileID))
                ?? WorkspaceUnavailableReason.unsupportedOperation.message
        }
        return ChatAgentEditorPresentation(profileID: profileID, store: agents,
            runtimeDefaultsClient: canReadDefaults ? agentRuntimeDefaults : nil,
            runtimeDefaultsReadOnlyReason: readOnlyReason,
            isCurrent: {
                currentWorkspaceOwner == owner && model.memberIDs.first == profileID
                    && agents.profiles.contains(where: { $0.id == profileID })
                    && currentWorkspaceCapabilities.supports(.profilesEdit, owner: owner, profileID: profileID)
            })
    }

    func cardInteractions(for model: ChatModel) -> ChatCardInteractionHandler? {
        guard let owner = currentWorkspaceOwner, let profile = model.memberIDs.first else { return nil }
        let scope = ChatCardInteractionScope(authorityID: owner.cacheScopeID,
                                             profileID: profile, conversationID: model.conversationID)
        return ChatCardInteractionHandler(
            scope: scope, store: cardInteractionStore,
            currentDraft: { model.draft },
            stageComposer: { text, strategy in
                switch strategy {
                case .replace: model.draft = text
                case .append:
                    model.draft += model.draft.isEmpty || model.draft.hasSuffix("\n") ? text : "\n" + text
                }
            },
            sendReply: { text in
                guard model.acceptsCardReply(text) else { return false }
                Task { @MainActor in await model.sendCardReply(text) }
                return true
            },
            scheduledTasks: model.isBotMode ? nil : featureStore.scheduledTasks.map { ChatCardScheduledTaskBackend(store: $0) },
            currentScope: {
                guard currentWorkspaceOwner == owner,
                      model.memberIDs.first == profile else { return nil }
                return scope
            }
        )
    }

    var body: some View {
        agentHomeSheets(rootContent)
        .modifier(CredentialVaultSheet(model: $credentialVault))
        .modifier(FleetSheets(
            fleet: fleet, gate: $fleetGateRequest, isNewChatPresented: $isFleetNewChatPresented,
            onGate: { destination, hostID in openFleet(.destination(destination), on: hostID) },
            onNewChat: startFleetChat,
            onNewGroup: newGroupChatAction == nil ? nil : { startFleetGroupChat(with: $0) },
            appPage: fleetAppPage))
        .modifier(FleetHooks(
            liveKey: liveFleetKey, readiness: fleetOpenReadiness, hostsKey: fleetHostsKey, scenePhase: scenePhase,
            keepsConnected: keepsFleetHostsConnected,
            recordLive: recordLiveFleet, openPending: openPendingFleetIfReady,
            syncHosts: { fleet?.syncHosts() }, cancelReads: { fleet?.cancelReads() },
            setKeepsConnected: setKeepsFleetHostsConnected))
        .environment(\.agentDeletion, agentDeletionAction)
        .focusedSceneValue(\.bighelpShellActions, menuCommandActions)
        .bighelpThemePresentation(theme)
        .onChange(of: hostRegistry?.hosts.isEmpty, initial: true) { _, _ in
            reconcileRestoredHostOnboardingState()
        }
        .onChange(of: hostRegistry?.onboardingHostID) { _, _ in
            reconcileRestoredHostOnboardingState()
        }
        .modifier(DemoReconnectOnReturn(scenePhase: scenePhase, connection: $workspaceFixtureConnection,
                                        isEnabled: usesWorkspaceFixtures))
        .onChange(of: appState.path) { _, _ in retireClosedWorkspacePresentations() }
        .modifier(WorkspacePresentationContinuity(
            owner: currentWorkspaceOwner, registryGeneration: hostRegistry?.generation,
            isHostSettled: nativeRuntime.map { $0.isReady && !$0.isSuspended && !$0.isRefreshing } ?? true,
            signIn: $workspaceSignIn, close: closeWorkspacePresentations,
            reattach: reattachWorkspacePresentations))
        .sheet(item: $workspaceProfileEditor) { editor in
            AgentEditorView(model: editor, runtimeDefaultsClient: agentRuntimeDefaults, onCompleted: { _ in })
                .environment(\.agentDeletion, agentDeletionAction)
        }
        .sheet(isPresented: $isGroupCreationPresented) {
            BotModeCreateRoomView(rooms: botModeRooms, agents: agents, seedProfileID: groupCreationSeed) { roomID in
                // A reconnect while the sheet was open is still this computer.
                guard let owner = groupCreationOwner, isCurrentSignIn(owner),
                      let current = currentWorkspaceOwner else { return }
                openHostedGroup(roomID, owner: current, settings: false)
            }
            .bighelpSheetSize(.standard)
        }
        .sheet(isPresented: Binding(
            get: { groupSettingsModel != nil }, set: { if !$0 { groupSettingsModel = nil } }
        )) {
            if let model = groupSettingsModel {
                PeopleAndChatView(model: model, agents: agents)
                    .bighelpSheetSize(.standard)
            }
        }
        .sheet(isPresented: Binding(get: { hostRegistry?.isSetupPresented == true },
                                   set: { if !$0 { hostRegistry?.finishSetup() } })) {
            if let hostRegistry {
                NavigationStack {
                    HostSetupView(registry: hostRegistry, hostToAuthenticate: hostRegistry.hosts.first { $0.id == hostRegistry.setupHostID })
                }
                .bighelpSheetSize(.standard)
            }
        }
        .onChange(of: hostRegistry?.selectedHostID) { _, _ in
            appState.resetForHostBoundary()
        }
        .task(id: hostRegistry?.selectedHostID) {
            connectionKeeper.bind { [hostRegistry] in
                hostRegistry?.isWorkspaceReady == true ? hostRegistry?.selectedWorkspace : nil
            }
            ConnectionIslandFollower.shared.follow(connectionKeeper)
            guard scenePhase == .active else { return }
            await nativeWorkspaceStore?.reconnect()
        }
        .onChange(of: scenePhase) { _, phase in
            connectionKeeper.setActive(phase == .active)
            if phase == .background { rememberOpenChat() }
            if phase == .background, let store = nativeWorkspaceStore {
                // Closed only if the app stays away; a Shortcut still running keeps it.
                BighelpBackgroundGrace.shared.begin("connection") { [weak store] in
                    guard BighelpShortcutService.holdsHostConnection == 0 else { return }
                    store?.suspendForPresentationExit()
                }
            }
            if phase == .active {
                BighelpBackgroundGrace.shared.cancel()
                Task { @MainActor in
                    guard scenePhase == .active else { return }
                    await nativeWorkspaceStore?.reconnect()
                }
            }
        }
        .overlay {
            if let workspace = nativeWorkspaceStore {
                DirectHermesSecurePromptOverlay(workspace: workspace)
            }
        }
        .onChange(of: currentDeviceToolScope, initial: true) { _, scope in
            permissionCenter.deviceTools.bind(scope)
        }
        .onChange(of: nativeDeviceToolTrigger, initial: true) { _, signature in
            permissionCenter.nativeDeviceToolLifetime.update(signature) {
                await runNativeDeviceTools()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            permissionCenter.nativeDeviceToolLifetime.stop()
            permissionCenter.deviceTools.invalidateOperations()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            // Protected-data availability is not observable SwiftUI state.
            // Resume explicitly even when scenePhase stayed active.
            permissionCenter.nativeDeviceToolLifetime.update(nativeDeviceToolTrigger) {
                await runNativeDeviceTools()
            }
        }
        .onChange(of: currentDeviceToolScope) { _, _ in
            sessionRestoreTask?.cancel()
            sessionRestoreTask = nil
            sessionRestoreRequest = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { permissionCenter.deviceTools.invalidateOperations() }
        }
        .task(id: hostRuntimeScope) { await prepareHostRuntime() }
        .onChange(of: agents.errorMessage) { _, _ in
            Task { await currentHostRuntime?.refresh() }
        }
        .modifier(IncomingLinks(open: handleIncomingURL))
        .onAppear { watchForLostChats() }
        .modifier(BighelpShortcutParameterUpdates(agents: agents, scheduledTasks: featureStore.scheduledTasks,
                                                  rooms: botModeRooms, catalog: sessionCatalog))
        .onChange(of: acceptsIncomingLinks) { _, ready in
            if ready { openPendingIncomingChatIfNeeded() }
        }
        .onChange(of: BighelpExternalSessionOpenCenter.shared.pending, initial: true) { _, open in
            if let open { openExternalSession(open) }
        }
        // A tapped alert from a cold start: its chat opens as soon as the saved list is read.
        .onChange(of: sessionCatalog.records.count) { _, _ in
            if let open = BighelpExternalSessionOpenCenter.shared.pending { openExternalSession(open) }
        }
    }

    var nativeWorkspaceStore: DirectHermesWorkspaceStore? {
        guard hostRegistry?.isWorkspaceReady == true else { return nil }
        return hostRegistry?.selectedWorkspace
    }

    @ViewBuilder private var rootContent: some View {
        Group {
            if let registry = hostRegistry, registry.isWorkspaceReady, !registry.storageIsReadable {
                ContentUnavailableView {
                    Label("Saved hosts unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(registry.errorMessage ?? "Saved hosts could not be loaded.")
                } actions: {
                    Button("Try Again") { registry.retryLoading() }
                }
            } else if let registry = hostRegistry, presentsFirstRunOnboarding {
                FirstRunOnboardingView(
                    registry: registry,
                    settings: settings,
                    onCompleted: completeFirstRunOnboarding
                )
            } else if let registry = hostRegistry, registry.isWorkspaceReady,
                      (needsInitialHostSetup || (registry.onboardingHostID != nil && !registry.isSetupPresented)) {
                HostSetupView(registry: registry, allowsDismiss: false)
            } else if nativeWorkspaceStore != nil {
                if nativeRuntime != nil { workspace }
                else if fleetModeOn, let fleet {
                    FleetConnectingView(
                        fleet: fleet, onOpen: openFleetAgent,
                        isConnecting: nativeWorkspaceStore?.isConnecting == true || nativeRuntime?.isRefreshing == true
                            || nativeWorkspaceStore?.isConnected == true,
                        retry: { Task { await nativeWorkspaceStore?.reconnect() } })
                }
                else { nativeWorkspace }
            } else if let registry = hostRegistry, registry.connectionMode == .independent, !usesWorkspaceFixtures {
                BighelpHostsPage(registry: registry)
            } else if usesWorkspaceFixtures {
                workspace
            } else {
                nativeWorkspace
            }
        }
    }

    var presentsFirstRunOnboarding: Bool {
        guard let hostRegistry,
              hostRegistry.isWorkspaceReady,
              hostRegistry.storageIsReadable,
              hostRegistry.errorMessage == nil else { return false }
        #if DEBUG
        if isForcedFirstRunOnboarding { return !didCompleteForcedFirstRunOnboarding }
        if usesWorkspaceFixtures || ProcessInfo.processInfo.arguments.contains("-test-no-configured-hosts") { return false }
        #endif
        guard !hasCompletedFirstRunOnboarding else { return false }
        return hostRegistry.hosts.isEmpty || hostRegistry.onboardingHostID != nil
    }

    #if DEBUG
    private var isForcedFirstRunOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-force-signed-out-onboarding")
    }
    #endif

    /// Another computer or sign-in: nothing opened for the old one stays up.
    private func closeWorkspacePresentations() {
        managementStore?.retire()
        managementStore = nil
        _ = capabilitiesPresentations.removeAll()
        for page in administrationPresentations.removeAll() { page.retire() }
        workspaceProfileEditor = nil
        lifecycleCoordinator = nil
        lifecycleProfileID = nil
        lifecyclePresentationID = nil
        isGroupCreationPresented = false
        groupSettingsModel = nil
        fixtureCanonicalSessions = [:]
    }

    private func completeFirstRunOnboarding() {
        didCompleteForcedFirstRunOnboarding = true
        #if DEBUG
        guard !isForcedFirstRunOnboarding else { return }
        #endif
        hasCompletedFirstRunOnboarding = true
    }

    private func reconcileRestoredHostOnboardingState() {
        #if DEBUG
        guard !isForcedFirstRunOnboarding else { return }
        #endif
        guard let hostRegistry,
              hostRegistry.isWorkspaceReady,
              !hostRegistry.hosts.isEmpty,
              hostRegistry.onboardingHostID == nil else { return }
        hasCompletedFirstRunOnboarding = true
    }

    var needsInitialHostSetup: Bool {
        guard let hostRegistry, hostRegistry.isWorkspaceReady, hostRegistry.errorMessage == nil else { return false }
        #if DEBUG
        if usesDemoFixtures && !ProcessInfo.processInfo.arguments.contains("-test-no-configured-hosts") { return false }
        #endif
        return hostRegistry.hosts.isEmpty
    }

    private var nativeWorkspace: some View {
        NativeWorkspaceStatusView(
            status: nativeWorkspaceStatus,
            message: nativeWorkspaceError ?? nativeRuntime?.errorMessage
                ?? nativeWorkspaceStore?.status ?? "Connecting to this host.",
            registry: hostRegistry,
            reconnect: {
                Task {
                    await nativeWorkspaceStore?.reconnect()
                    await nativeRuntime?.refresh()
                }
            }
        )
    }

    /// Opening the workspace counts as connecting until it's open, and so do
    /// the keeper's quiet retries, as the island says.
    private var nativeWorkspaceStatus: HostConnectionStatus {
        let host = HostConnectionStatus(workspace: nativeWorkspaceStore, keeper: connectionKeeper)
        let isWorking = nativeRuntime?.isRefreshing == true || host.phase == .connecting || host.phase == .reconnecting
        let failed = nativeWorkspaceError != nil || nativeRuntime?.errorMessage != nil
        return HostConnectionStatus(isConnected: !isWorking && !failed && host.phase == .connected,
                                    isConnecting: isWorking, isFirstConnection: !connectionKeeper.hasConnected)
    }

    var workspace: some View {
        homeAutoOpen(workspaceShell)
    }

    private var workspaceShell: some View {
        GeometryReader { geometry in
            shell
                .overlay(alignment: .leading) {
                    edgeGestureSurface(side: .left, containerWidth: geometry.size.width)
                }
                .overlay(alignment: .trailing) {
                    edgeGestureSurface(side: .right, containerWidth: geometry.size.width)
                }
                .allowsHitTesting(!isBlockingSessionRestore)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(isBlockingSessionRestore)
                .overlay {
                    if isBlockingSessionRestore, let request = sessionRestoreRequest {
                        sessionRestoreOverlay(request)
                    }
                }
        }
    }

    private var isBlockingSessionRestore: Bool {
        guard let request = sessionRestoreRequest else { return false }
        return appState.activeConversationID != request.sessionID
    }

    private func sessionRestoreOverlay(_: SessionRestoreRequest) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
            BighelpCard {
                VStack(spacing: BighelpTokens.space12) {
                    BighelpThinkingOrb(scenario: .shaping)
                    Text("Restoring session")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(theme.primaryText)
                    Text("Loading the transcript and rebuilding saved interface cards…")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 300)
                .padding(BighelpTokens.space12)
            }
            .padding(BighelpTokens.space24)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Restoring session")
        .accessibilityIdentifier("session.restore.loading")
    }

    @ViewBuilder
    private var hostAwareHomeTab: some View {
        workspaceActivity
    }

    @ViewBuilder
    private var hostAwareAgentsTab: some View {
            AgentsShellView(
                agents: agents,
                runtimeDefaultsClient: agentRuntimeDefaults,
                onSelect: { openAgentChat($0.id) },
                onOpenSessions: { openSessions(filteredTo: $0.id) },
                onOpenHostStatus: { isHostStatusPresented = true },
                hostRuntime: currentHostRuntime,
                workspaceOwner: currentWorkspaceOwner,
                capabilities: currentWorkspaceCapabilities,
                botModeRooms: botModeRooms,
                cloneClient: workspaceConnections?.cloneClient,
                shortcutsAvailable: usesWorkspaceFixtures
                    || (nativeRuntime != nil && currentWorkspaceOwner != nil)
,
                onAction: handleAgentWorkspaceAction,
                groupFilterRequest: $agentGroupFilterRequest,
                createRequest: $agentCreateRequest
            )
            // The one main action, where a thumb rests, as on All agents.
            .overlay(alignment: .bottomTrailing) {
                if appState.path.isEmpty {
                    RootComposeButton(identifier: "agents.new-chat", size: 72) {
                        if currentWorkspaceOwner != nil { presentNewChatPicker(seed: nil) }
                        else { startNewChat(explicitAgentID: nil) }
                    }
                        .padding(.trailing, BighelpTokens.space20)
                        .padding(.bottom, BighelpTokens.space12)
                }
            }
    }

    /// Feed, Ideas, Goals and Apps draw their own header (the agent's avatar).
    private var showsAgentBoard: Bool {
        appState.path.isEmpty && appState.selectedTab.isAgentBoard
    }

    private var shell: some View {
        rootTabs
        .toolbar(.hidden, for: .tabBar)
        .toolbar(showsAgentBoard ? .hidden : .automatic, for: .navigationBar)
        .navigationTitle(showsAgentBoard ? "" : rootNavigationTitle)
        .navigationBarTitleDisplayMode(showsAgentBoard ? .inline : .large)
        .toolbar {
            if appState.path.isEmpty, !appState.selectedTab.isAgentBoard {
                // ☰ always opens chats, agents, tasks and settings, on iPad too.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isHomeDrawerPresented.toggle()
                    } label: {
                        Image(systemName: "line.3.horizontal").bighelpToolbarIcon()
                    }
                    .bighelpIconLabel("Chats and menu", shortcut: "⌃⌘S")
                    .accessibilityIdentifier("home.drawer.open")
                }
                // Ember lives only in chrome: the brand bar on root screens.
                // Touch and hold it to switch hosts.
                EmberBrandToolbarItem(demoHosts: demoHosts)
                // All agents has its own options there instead (☰ switches back to one host).
                if fleetModeOn, appState.selectedTab == .scheduledTasks { fleetToolbar }
            }
        }
        #if os(visionOS)
        // Beside the window, not along its bottom edge by the close control.
        .ornament(visibility: visionTabsVisible ? .visible : .hidden,
                  attachmentAnchor: .scene(.leading), contentAlignment: .trailing) {
            VisionTabOrnament(selection: tabSelection, unread: boardUnreadTabs,
                              onNewChat: appState.selectedTab == .sessions && appState.path.isEmpty && !fleetModeOn ? {
                                  appState.chatOpenedFromList = true
                                  startNewChat(explicitAgentID: nil)
                              } : nil)
        }
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsBottomNavigation && !BighelpPlatform.usesTabOrnament {
                // All agents has its own New chat, bottom right.
                FloatingTabBar(selection: tabSelection,
                               onNewChat: appState.selectedTab == .sessions && !fleetModeOn ? {
                                   appState.chatOpenedFromList = true
                                   startNewChat(explicitAgentID: nil)
                               } : nil,
                               homeIndicatorSink: FloatingTabBar.homeIndicatorSink(forBottomInset: rootBottomSafeArea),
                               unread: boardUnreadTabs)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { rootBottomSafeArea = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: BighelpTokens.transitionDuration), value: showsBottomNavigation)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            botModeLoadErrorBanner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationDestination(for: AppRoute.self) { route in
            // Pushed screens don't reliably inherit values set below the stack.
            routeDestination(route).environment(\.providerUsage, providerUsage)
                // The root is hidden under a pushed screen and can't present; the top screen does.
                .modifier(OpenErrorPresentation(root: self))
        }
        .modifier(OpenErrorPresentation(root: self))
        .sheet(isPresented: $isUnifiedSettingsPresented, onDismiss: {
            let action = afterSettingsDismiss
            afterSettingsDismiss = nil
            action?()
        }) {
            NavigationStack {
                workspaceSettings()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isUnifiedSettingsPresented = false }
                                .accessibilityIdentifier("settings.done")
                        }
                    }
            }
            .bighelpSheetSize()
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isHermesWorkspacePresented) {
            HermesWorkspacePickerView(
                store: hermesWorkspaces,
                agentID: workspaceAgentID
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
        }
        .onChange(of: appState.path) { previousPath, path in
            let bindsPendingCanvas: Bool = {
                guard case .chat(let previousID)? = previousPath.last,
                      case .chat(let currentID)? = path.last else { return false }
                return previousID.hasPrefix("local-draft:") && !currentID.hasPrefix("local-draft:")
            }()
            if !bindsPendingCanvas { BighelpKeyboard.dismiss() }
            if let restoreRequest = sessionRestoreRequest {
                let route = AppRoute.chat(conversationID: restoreRequest.sessionID)
                // Leaving ends presentation observation, not native feature-
                // owned hydration, even when returning to the original root.
                let leftHydratingChat = SessionRestorePresentationPolicy.ownsHydration(
                    route: route, path: previousPath
                ) && !SessionRestorePresentationPolicy.ownsHydration(route: route, path: path)
                let leftRestore = !SessionRestorePresentationPolicy.ownsRestore(
                    route: route,
                    originTab: restoreRequest.originTab,
                    originPath: restoreRequest.originPath,
                    currentTab: appState.selectedTab,
                    currentPath: path
                )
                if leftHydratingChat || leftRestore {
                    sessionRestoreTask?.cancel()
                    sessionRestoreTask = nil
                    sessionRestoreRequest = nil
                }
            }
        }
        .onChange(of: appState.selectedTab) { _, tab in
            guard let restoreRequest = sessionRestoreRequest,
                  tab != restoreRequest.originTab
            else { return }
            sessionRestoreTask?.cancel()
            sessionRestoreTask = nil
            sessionRestoreRequest = nil
        }
    }

    private var showsBottomNavigation: Bool {
        // The all-hosts view is just its list. Feed, Ideas and Goals keep the
        // bar if something opens them, so its Chat tab always leads back.
        // Not on Agents: pick an agent first, so Feed, Ideas and Goals are clearly its own.
        appState.path.isEmpty && !isKeyboardVisible && appState.selectedTab != .agents
            && (!fleetModeOn || appState.selectedTab.isAgentBoard)
    }

    /// Vision Pro's tab strip on root screens. The agent's own chat draws its
    /// own: a screen covered by a pushed one doesn't show its ornaments.
    private var visionTabsVisible: Bool {
        appState.path.isEmpty && appState.selectedTab != .agents && (!fleetModeOn || appState.selectedTab.isAgentBoard)
    }

    @ViewBuilder
    private var rootTabs: some View {
        // The conversation shell owns navigation. A hidden TabView creates a
        // UIKit containment boundary that drops feature search and toolbar actions.
        switch appState.selectedTab {
        case .agents:
            hostAwareAgentsTab
        case .scheduledTasks:
            scheduledTasksRootTab
        case .workspace:
            WorkspaceHubView(
                hostName: workspaceHostName,
                profileName: workspaceProfileName,
                onOpen: openWorkspaceDestination
            )
        case .home, .inbox:
            hostAwareHomeTab
        case .profile:
            workspaceSettings()
        case .sessions:
            sessionsRootTab
        case .feed, .ideas, .goals, .apps:
            agentBoardTab(appState.selectedTab)
        }
    }

    private var rootNavigationTitle: String {
        switch appState.selectedTab {
        case .sessions: fleetModeOn ? "All agents" : "Sessions"
        case .agents: "Agents"
        case .scheduledTasks: "Scheduled Tasks"
        case .home, .inbox: "Activity"
        case .workspace: "Hermes Tools"
        case .profile: "Settings"
        case .feed: "Feed"
        case .ideas: "Ideas"
        case .goals: "Goals"
        case .apps: "Apps"
        }
    }

    @ViewBuilder
    private var botModeLoadErrorBanner: some View {
        if nativeWorkspaceStore == nil,
           let banner = BotModeLoadBannerState(message: botModeRooms.loadErrorMessage) {
            HStack(spacing: BighelpTokens.space8) {
                Label(banner.message, systemImage: "exclamationmark.triangle.fill")
                    .bighelpFont(.metadata)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: BighelpTokens.space8)
                Button(banner.actionLabel) {
                    do { try botModeRooms.load() } catch { }
                }
                .bighelpFont(.label)
                .foregroundStyle(.white)
                .frame(minHeight: BighelpTokens.hitTarget)
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space8)
            .background(.red)
            .accessibilityIdentifier("bot-mode-load-error")
        }
    }

    private enum EdgeSide {
        case left
        case right
    }

    @ViewBuilder
    private func edgeGestureSurface(side: EdgeSide, containerWidth: CGFloat) -> some View {
        let action = side == .left
            ? settings.leftEdgeSwipeAction
            : settings.rightEdgeSwipeAction
        Color.clear
            .frame(width: WorkspaceEdgeSwipeResolver.activationEdgeWidth)
            .contentShape(Rectangle())
            // Below the header row, so ☰ and ⋯ in the corners (Feed, Ideas, Goals, Apps) keep their taps.
            .padding(.top, HeaderButtonMetrics.glass + 2 * HeaderButtonMetrics.slop + BighelpTokens.space8)
            .allowsHitTesting(action != .none && !isHomeDrawerPresented
                && (side == .left || WorkspaceEdgeSwipeResolver.trailingEdgeIsActive(
                    tab: appState.selectedTab, pathIsEmpty: appState.path.isEmpty)))
            .highPriorityGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onEnded { value in
                        let startX = side == .left
                            ? value.startLocation.x
                            : containerWidth - WorkspaceEdgeSwipeResolver.activationEdgeWidth + value.startLocation.x
                        guard let resolved = WorkspaceEdgeSwipeResolver.resolve(
                            start: CGPoint(x: startX, y: value.startLocation.y),
                            translation: value.translation,
                            containerWidth: containerWidth,
                            leftAction: settings.leftEdgeSwipeAction,
                            rightAction: settings.rightEdgeSwipeAction
                        ) else { return }
                        performWorkspaceAction(resolved)
                    }
            )
            .accessibilityHidden(true)
    }

    /// Every way into the menu (☰, edge swipes, inner pages) opens the same ☰ sheet.
    private func presentQuickWorkspace() {
        BighelpKeyboard.dismiss()
        // ☰ toggles: the Mac and Vision Pro sidebar stays reachable while open.
        isHomeDrawerPresented.toggle()
    }

    private func performWorkspaceAction(_ action: WorkspaceSwipeAction) {
        BighelpKeyboard.dismiss()
        switch action {
        case .quickWorkspace:
            presentQuickWorkspace()
        case .newChat:
            startNewChat(explicitAgentID: nil)
        case .sessions:
            openSessions(filteredTo: nil)
        case .agents:
            appState.select(.agents)
        case .home, .inbox:
            openHomeChat()
        case .profile:
            appState.select(.profile)
        case .none:
            break
        }
    }

    var tabSelection: Binding<AppTab> {
        Binding(
            get: { appState.selectedTab },
            set: { tab in
                // Chat from a chat is where you already are, not a trip to the list.
                if tab == .sessions, case .chat? = appState.path.last { return }
                // From a chat, its agent's Feed, Ideas and Goals; and the switch is a swap like
                // Feed to Ideas, not the chat sliding away.
                if fleetModeOn, case .chat(let id)? = appState.path.last { fleetLastChatID = id }
                if tab.isAgentBoard, case .chat(let id)? = appState.path.last,
                   let members = featureStore.preparedChatModel(id: id)?.memberIDs, members.count == 1,
                   members[0] != homeAgent?.id {
                    _ = agents.setPrimaryAgent(members[0])
                }
                var transaction = Transaction()
                transaction.disablesAnimations = !appState.path.isEmpty
                    || (tab == .sessions && appState.selectedTab.isAgentBoard)
                withTransaction(transaction) { selectTab(tab) }
            }
        )
    }

    private func selectTab(_ tab: AppTab) {
        // All hosts has no home chat: Chat goes back to the chat you were in, else to All agents.
        if tab == .sessions, fleetModeOn, appState.path.isEmpty, let id = fleetLastChatID,
           let record = sessionCatalog.session(id: id) {
            appState.chatOpenedFromList = true
            openSession(record.summary)
            return
        }
        if tab == .sessions, opensHomeChat {
            // Chat is the agent's own chat; ☰ and swipe-back reach the full list.
            openHomeChat()
        } else if tab == .sessions {
            openSessions(filteredTo: nil)
        } else if tab == .scheduledTasks {
            openScheduledTasks(filteredTo: nil)
        } else {
            appState.select(tab)
        }
    }

    @ViewBuilder
    private var sessionsRootTab: some View {
        if fleetModeOn, let fleet {
            fleetHome(fleet)
        } else if case .sessions(let model)? = featureStore.preparedModel(for: .sessions) {
            SessionsView(
                model: model,
                agents: agents,
                settings: settings,
                organizeByProjects: settings.organizeChatsByProjects,
                sessionOrganizationAccountID: sessionOrganizationAccountID,
                sessionOrganizationHostID: sessionOrganizationHostID,
                onStartChat: { appState.chatOpenedFromList = true; startNewChat(explicitAgentID: $0) },
                onNewGroupChat: newGroupChatAction.map { action in { appState.chatOpenedFromList = true; action() } },
                onSelect: { appState.chatOpenedFromList = true; openSessionSelection($0) },
                agentActionsConfig: agentActionsConfig
            )
        } else {
            ProgressView("Loading sessions")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    _ = featureStore.prepareSessions(filteredTo: nil)
                }
        }
    }

    /// Group chats use Hermes' hosted rooms, the same path as Agents › New group chat.
    var newGroupChatAction: (() -> Void)? {
        guard let owner = currentWorkspaceOwner, botModeRooms.canCreateNativeRoom,
              currentWorkspaceCapabilities.supports(.groupsCreate, owner: owner, profileID: nil)
        else { return nil }
        return {
            handleAgentWorkspaceAction(AgentWorkspaceActionRequest(owner: owner, action: .createGroup(seedProfileID: nil)))
        }
    }

    @ViewBuilder
    private var scheduledTasksRootTab: some View {
        if fleetModeOn, let fleet {
            FleetTasksView(fleet: fleet, onOpen: openFleetTask)
                // This host's own tasks, as its Scheduled tasks screen would load them.
                .task { if featureStore.scheduledTasks?.loadState == .idle { await featureStore.scheduledTasks?.load() } }
        } else if let store = featureStore.scheduledTasks {
            ScheduledTasksView(store: store, agents: agents, showsInlineHeading: true, onOpen: openScheduledTask)
        } else {
            ContentUnavailableView("Scheduled Tasks", systemImage: "calendar.badge.clock",
                                   description: Text("Scheduled work is unavailable for this connection."))
        }
    }

    private func leaveSettings(perform action: @escaping () -> Void) {
        if isUnifiedSettingsPresented {
            afterSettingsDismiss = action
            isUnifiedSettingsPresented = false
        } else {
            action()
        }
    }

    /// Settings' Appearance or Chat page alone, for Fleet settings.
    func fleetAppPage(_ section: SettingsMenuSection) -> AnyView {
        AnyView(workspaceSettings().opening(section))
    }

    func workspaceSettings(destination: WorkspaceDestination? = nil) -> SettingsView {
        SettingsView(
            settings: settings, focusedDestination: destination, userIdentity: userIdentity,
            agents: agents.profiles, personalities: personalities,
            permissionCenter: permissionCenter,
            onOpenSessions: { leaveSettings { openSessions(filteredTo: nil) } },
            onOpenScheduledTasks: { leaveSettings { openScheduledTasks(filteredTo: nil) } },
            onClearLocalCache: {
                if let nativeRuntime { return await nativeRuntime.refreshLocalCache() }
                return await clearLocalCache()
            },
            voiceSettingsScope: voiceSettingsScope, voiceSettingsClient: voiceSettingsClient,
            voiceSettingsIsCurrent: voiceSettingsIsCurrent,
            pluginUpdateScope: pluginUpdateScope, pluginUpdateClient: pluginUpdateClient,
            pluginUpdateIsCurrent: pluginUpdateIsCurrent,
            hostRuntime: currentHostRuntime, agentDirectory: agents,
            landingScope: currentWorkspaceOwner?.cacheScopeID,
            onOpenWorkspaceDestination: { destination in
                leaveSettings { openWorkspaceDestination(destination) }
            },
            onOpenRoute: { route in
                leaveSettings { openPrepared(route) }
            }
        )
    }

    var workspaceActivity: some View {
        DashboardView(
            model: featureStore.dashboardModel,
            connection: HostConnectionStatus(dashboardIsConnected: nativeRuntime != nil
                ? currentWorkspaceOwner != nil : dashboardFixtureIsConnected),
            onInboxItemTap: openDashboardInboxItem,
            onAttentionItemTap: openDashboardAttentionItem,
            onWorkItemTap: openDashboardWorkItem
        )
    }

    func routeWithWorkspaceMenu<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .toolbar {
                if settings.nerdModeEnabled {
                    ToolbarItem(placement: .topBarTrailing) {
                        // The native toolbar supplies its own Liquid Glass surface.
                        Button {
                            presentQuickWorkspace()
                        } label: {
                            Image(systemName: "line.3.horizontal").bighelpToolbarIcon()
                        }
                        .bighelpIconLabel("Menu")
                        .accessibilityIdentifier("workspace.menu")
                    }
                }
            }
    }

    /// The menu bar's New Chat (⌘N), Settings (⌘,), sidebar (⌃⌘S) and, on the Mac, tabs (⌘1–⌘5).
    private var menuCommandActions: BighelpShellActions {
        var actions = BighelpShellActions(
            newChat: { startNewChat(explicitAgentID: nil) },
            openSettings: { isUnifiedSettingsPresented = true },
            isSidebarOpen: isHomeDrawerPresented,
            toggleSidebar: { isHomeDrawerPresented.toggle() }
        )
        if appState.path.isEmpty, !fleetModeOn {
            let selection = tabSelection
            actions.selectTab = { tab in selection.wrappedValue = tab }
        }
        return actions
    }

    func startNewChat(explicitAgentID: String?) {
        runNewChatStart(retry: { startNewChat(explicitAgentID: explicitAgentID) }) {
            _ = try await newChatCoordinator.start(explicitAgentID: explicitAgentID)
        }
    }

    /// A widget's New Chat arrives as the app wakes, before the host connection
    /// (dropped in the background) is back; creating the chat then failed with
    /// "host unavailable". Wait for the host the way Shortcuts do.
    private func startIncomingNewChat(agentID: String?) {
        runNewChatStart(retry: { startIncomingNewChat(agentID: agentID) }) {
            if let shortcutService, nativeRuntime != nil, !usesWorkspaceFixtures {
                try await shortcutService.openNewChat(agentID: agentID)
            } else {
                let known = agentID.flatMap { id in agents.profiles.contains(where: { $0.id == id }) ? id : nil }
                _ = try await newChatCoordinator.start(explicitAgentID: known)
            }
        }
    }

    private func runNewChatStart(retry: @escaping @MainActor () -> Void,
                                 _ start: @escaping @MainActor () async throws -> Void) {
        guard !isStartingNewChat else { return }
        let operationID = UUID()
        newChatStartID = operationID
        withAnimation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration)) {
            isStartingNewChat = true
        }
        Task { @MainActor in
            defer {
                finishNewChatOpening(operationID)
            }
            do {
                try await start()
            } catch is CancellationError {
                // A replaced account or host must not present the old request's error.
            } catch {
                actionErrorShowsHostStatus = agents.errorMessage != nil || AgentDirectoryStore.isHermesCapabilityMissing(error)
                // The chat keeps any draft typed while it was starting; Try Again reuses it.
                actionErrorRetry = retry
                actionErrorMessage = error is WorkspaceClientError || error is BighelpShortcutServiceError
                    || error is DirectHermesSessionError
                    ? error.localizedDescription
                    : AgentDirectoryStore.isHermesCapabilityMissing(error)
                    ? AgentDirectoryStore.hermesCompatibilityRecovery
                    : (agents.errorMessage ?? "New chat could not be opened. Try again.")
            }
        }
    }

    private func finishNewChatOpening(_ operationID: UUID) {
        guard newChatStartID == operationID else { return }
        newChatStartID = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration)) {
            isStartingNewChat = false
        }
    }

    var activeHermesWorkspaceName: String {
        hermesWorkspaces.catalog?.workspaces.first(where: \.isActive)?.name
            ?? "Workspace"
    }

    var workspaceAgentID: String {
        agents.resolvedAgent(explicitID: nil)?.id ?? "default"
    }

    func presentHermesWorkspaces() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            isHermesWorkspacePresented = true
        }
    }

    func openApproval(requestID: String) {
        Task {
            do {
                guard try await featureStore.prepareApproval(id: requestID) else {
                    actionErrorMessage = "This approval is no longer available."
                    return
                }
                appState.open(.approval(requestID: requestID))
            } catch {
                actionErrorMessage = "This approval could not be loaded from Hermes. Try again."
            }
        }
    }

    func openApproval(request: ApprovalRequest) {
        guard featureStore.prepareApproval(request: request) else { return }
        appState.open(.approval(requestID: request.id))
    }

    func openSessions(filteredTo agentID: String?) {
        guard featureStore.prepareSessions(filteredTo: agentID) else { return }
        appState.openSessions()
    }

    func openScheduledTasks(filteredTo agentID: String?) {
        guard featureStore.prepareScheduledTasks(filteredTo: agentID) else { return }
        appState.openScheduledTasks()
    }

    fileprivate func openErrorPresentations<Content: View>(_ content: Content) -> some View {
        content
            .alert("Unable to open", isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil; actionErrorRetry = nil } }
            )) {
                if let retry = actionErrorRetry {
                    Button("Try Again") {
                        actionErrorMessage = nil
                        actionErrorShowsHostStatus = false
                        actionErrorRetry = nil
                        retry()
                    }
                }
                if actionErrorShowsHostStatus {
                    Button("View Host Status") {
                        actionErrorMessage = nil
                        actionErrorShowsHostStatus = false
                        actionErrorRetry = nil
                        isHostStatusPresented = true
                    }
                }
                Button("OK", role: .cancel) {
                    actionErrorMessage = nil
                    actionErrorShowsHostStatus = false
                    actionErrorRetry = nil
                }
            } message: {
                Text(actionErrorMessage ?? "Try again.")
            }
            .sheet(isPresented: $isHostStatusPresented) {
                NavigationStack {
                    Form {
                        HostRuntimeSection(store: currentHostRuntime, agents: agents, theme: theme)
                    }
                    .scrollContentBackground(.hidden)
                    .background(theme.canvas.ignoresSafeArea())
                    .navigationTitle("Host Status")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isHostStatusPresented = false }
                        }
                    }
                }
                .accessibilityIdentifier("host-runtime.screen")
                .bighelpSheetSize(.standard)
                .presentationDragIndicator(.visible)
            }
    }

    private func handleIncomingURL(_ url: URL) {
        guard let route = BighelpIncomingURLRoute.parse(url) else { return }
        // A link opening the app wins over Settings › Chat › Open on, and keeps the mode you were in.
        didAutoOpenHomeChat = true
        settings.restoreAllHostsModeForOutsideOpen()
        // Opened while the app starts or comes back, a link found no workspace
        // ("host unavailable") or opened its chat under an alert. It waits for
        // a host that answers instead; the latest one wins.
        if route.opensWorkspaceContent, !acceptsIncomingLinks {
            pendingIncomingURL = url
            return
        }
        switch route {
        case .home:
            // Notifications and older links named the Activity inbox. Updates,
            // approvals and questions now live in the agent's chat.
            openHomeChat()
        case .chat(let sessionID):
            openIncomingChat(sessionID: sessionID)
        case .agent(let tab, let agentID):
            // From the Watch: that agent's Feed, Ideas or Goals.
            if let agentID { _ = agents.setPrimaryAgent(agentID) }
            switch tab {
            case "feed": appState.select(.feed)
            case "ideas": appState.select(.ideas)
            case "goals": appState.select(.goals)
            case "apps": appState.select(.apps)
            default: openHomeChat()
            }
        case .newChat(let agentID):
            startIncomingNewChat(agentID: agentID)
        case .agentChat(let agentID, let hostID):
            openIncomingAgentChat(agentID: agentID, hostID: hostID)
        case .scheduledTasks:
            appState.select(.scheduledTasks)
        case .scheduledTask(let id):
            appState.select(.scheduledTasks)
            openPrepared(.scheduledTask(id: id, agentID: nil))
        case .sessions:
            appState.select(.sessions)
        case .kanban(let board, let task):
            openKanban(board: board, task: task)
        case .approval(let id):
            openApproval(requestID: id)
        case .group(let roomID):
            guard let owner = currentWorkspaceOwner else {
                actionErrorMessage = "This group is no longer available on the selected host."
                return
            }
            openHostedGroup(roomID, owner: owner, settings: false)
        case .agents:
            appState.select(.agents)
        case .projects:
            openProjects()
        case .settings:
            appState.select(.profile)
        case .workflows:
            openWorkflows()
        case .workflow(let id, let hostID, let startsRun):
            // A workflow on another computer: switch to it, and open the workflow once it answers.
            if let hostID, let hostRegistry, hostID != hostRegistry.selectedHostID {
                guard hostRegistry.hosts.contains(where: { $0.id == hostID }) else {
                    actionErrorMessage = "That computer isn't in bighelp anymore."
                    return
                }
                pendingIncomingURL = url
                hostRegistry.select(hostID)
                return
            }
            openWorkflow(id: id, startsRun: startsRun)
        }
    }

    private func openIncomingChat(sessionID: String) {
        // A chat's own ID starts "native-session-v1:"; only the scoped digest is an activity link.
        if ManagedNotificationValidation.isOpaqueSessionID(sessionID), let managedNotifications {
            sessionRestoreTask?.cancel()
            sessionRestoreTask = Task { @MainActor in
                do { try await managedNotifications.openActivity(opaqueSessionID: sessionID) }
                catch { actionErrorMessage = "The original activity conversation is unavailable. No other host was opened." }
            }
            return
        }
        if nativeRuntime != nil {
            openNativeSession(id: sessionID)
            return
        }
        guard nativeWorkspaceStore == nil else {
            actionErrorMessage = "This legacy chat link cannot be opened. The native host was not changed."
            return
        }
        sessionRestoreTask?.cancel()
        let restoreRequest = SessionRestoreRequest(
            sessionID: sessionID,
            originTab: appState.selectedTab,
            originPath: appState.path
        )
        sessionRestoreRequest = restoreRequest
        sessionRestoreTask = Task { @MainActor in
            defer {
                if sessionRestoreRequest == restoreRequest {
                    sessionRestoreRequest = nil
                    sessionRestoreTask = nil
                }
            }
            do {
                let authoritative = try await sessionCatalog.prepareExistingSession(id: sessionID)
                try Task.checkCancellation()
                guard
                    sessionRestoreRequest == restoreRequest,
                    SessionRestorePresentationPolicy.canComplete(
                        originTab: restoreRequest.originTab,
                        originPath: restoreRequest.originPath,
                        currentTab: appState.selectedTab,
                        currentPath: appState.path
                    )
                else { return }
                SessionRestoreMetadataReconciler.reconcile(
                    authoritative,
                    workspaces: hermesWorkspaces
                )
                let route = AppRoute.chat(conversationID: sessionID)
                guard try featureStore.prepareForUserNavigation(route) else {
                    actionErrorMessage = "This session could not be prepared. Try again."
                    return
                }
                appState.activateConversation(id: sessionID, source: .quickSwitch)
            } catch is CancellationError {
                return
            } catch {
                guard sessionRestoreRequest == restoreRequest else { return }
                actionErrorMessage = "This session could not be loaded from Hermes. Try again."
            }
        }
    }

    /// Widget links carry the native catalog's own session ID. The catalog may
    /// not have loaded yet on a cold launch, so load once before giving up.
    private func openNativeSession(id sessionID: String) {
        if let record = sessionCatalog.session(id: sessionID) {
            openSessionSelection(record.summary)
            return
        }
        Task { @MainActor in
            try? await sessionCatalog.load()
            guard let record = sessionCatalog.session(id: sessionID) else {
                actionErrorMessage = "This chat is no longer available."
                return
            }
            openSessionSelection(record.summary)
        }
    }

    /// Managed notifications and Live Activities verify a durable Hermes
    /// coordinate; resolve it through the visible catalog and open that row.
    func openExternalSession(_ open: BighelpExternalSessionOpen) {
        // A notification opening the app wins over Settings › Chat › Open on, and keeps the mode
        // you were in: All hosts stays All hosts, so ☰ matches it.
        didAutoOpenHomeChat = true
        settings.restoreAllHostsModeForOutsideOpen()
        switch open.target {
        case .catalog(let sessionID):
            guard BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
            handleIncomingURL(BighelpWidgetSnapshot.chatURL(sessionID))
            return
        case .reference(let profileID, let reference):
            openNotifiedChat(open, profileID: profileID, reference: reference)
            return
        case .stored:
            break
        }
        guard nativeRuntime != nil, case .stored(let profileID, let storedSessionID) = open.target,
              BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
        Task { @MainActor in
            do {
                let record = try await sessionCatalog.resolveStoredSession(
                    profileID: profileID, storedSessionID: storedSessionID)
                openSession(record.summary)
            } catch is CancellationError {
                return
            } catch {
                actionErrorMessage = "This conversation could not be opened. Try again from Chats."
            }
        }
    }

    /// A tapped alert's chat. Saved on the phone, it opens at once from its saved history and
    /// catches up when the host answers; a chat the phone hasn't seen yet waits for the host's list.
    private func openNotifiedChat(_ open: BighelpExternalSessionOpen, profileID: String, reference: String) {
        guard nativeRuntime != nil || usesDemoFixtures else { return }
        if let record = SessionRecord.matching(reference: reference, profileID: profileID, in: sessionCatalog.records) {
            guard BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
            openSession(record.summary)
            return
        }
        guard acceptsIncomingLinks, BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
        Task { @MainActor in
            // Workflow alerts point at a run, not a chat.
            if await openNotifiedWorkflowRun(profileID: profileID, reference: reference) { return }
            try? await sessionCatalog.load(requireAuthoritativeRefresh: true)
            guard let record = SessionRecord.matching(reference: reference, profileID: profileID,
                                                      in: sessionCatalog.records) else {
                actionErrorMessage = "This conversation is no longer on your computer."
                return
            }
            openSession(record.summary)
        }
    }

    /// A link, widget, Shortcut or notification waiting for the host: the
    /// launch's landing screen gives way to it.
    var hasPendingOutsideOpen: Bool {
        pendingIncomingURL != nil || BighelpIncomingLinkCenter.shared.pending != nil
            || BighelpExternalSessionOpenCenter.shared.pending != nil
    }

    /// Widgets, notifications and Shortcuts open once the host answers: its
    /// workspace is loaded and not suspended or reconnecting.
    private var acceptsIncomingLinks: Bool {
        guard !usesDemoFixtures else { return true }
        guard let hostRegistry, hostRegistry.isWorkspaceReady, hostRegistry.selectedHostID != nil,
              let nativeRuntime else { return false }
        return nativeRuntime.isReady && !nativeRuntime.isSuspended
    }

    private func openPendingIncomingChatIfNeeded() {
        guard acceptsIncomingLinks else { return }
        if let url = pendingIncomingURL {
            pendingIncomingURL = nil
            handleIncomingURL(url)
        }
        // A notification tap resolved before the workspace was ready.
        if let open = BighelpExternalSessionOpenCenter.shared.pending { openExternalSession(open) }
    }

    func openScheduledTask(_ task: ScheduledTask) {
        openPrepared(.scheduledTask(id: task.id, agentID: task.agentID))
    }

    func openSession(_ session: SessionSummary) {
        sessionRestoreTask?.cancel()
        sessionRestoreTask = nil
        sessionRestoreRequest = nil
        let restoreRequest = SessionRestoreRequest(
            sessionID: session.id,
            originTab: appState.selectedTab,
            originPath: appState.path
        )
        let route = AppRoute.chat(conversationID: session.id)
        // Mount the retained owner and its scoped cache before any await.
        do {
            guard try featureStore.prepareCachedForUserNavigation(route),
                  case .chat(let model)? = featureStore.preparedModel(for: route),
                  let cached = sessionCatalog.session(id: session.id) else { return }
            let featureOwnsHydration = featureStore.ownsNativeNavigationHydration && cached.kind == .direct
            if featureOwnsHydration, featureStore.canReturnToWarmSession(id: session.id) {
                featureStore.refreshWarmSessionState(id: session.id)
                appState.activateConversation(id: session.id, source: .sessions)
                return
            }
            let hydration: ShellFeatureStore.NavigationHydration?
            if featureOwnsHydration {
                // Admission must precede the cancellable presentation Task.
                hydration = try featureStore.startNavigationHydration(id: session.id)
            } else {
                hydration = nil
                var presentation = cached
                if model.isSending { presentation.isActive = true }
                model.beginHistoryHydration(from: presentation)
            }
            sessionRestoreRequest = restoreRequest
            appState.activateConversation(id: session.id, source: .sessions)
            sessionRestoreTask = Task { @MainActor in
                defer {
                    if !featureOwnsHydration,
                       sessionRestoreRequest == restoreRequest || sessionRestoreRequest?.sessionID != session.id {
                        model.finishHistoryHydration(hasPreviousHistory: sessionCatalog.hasPreviousHistory(id: session.id))
                    }
                    if sessionRestoreRequest == restoreRequest {
                        sessionRestoreRequest = nil
                        sessionRestoreTask = nil
                    }
                }
                do {
                    // Page preparation already resolves the native session and
                    // performs one ordered recovery. Do not repeat it as metadata.
                    let authoritative: SessionRecord
                    if let hydration { authoritative = try await hydration.value() }
                    else { authoritative = try await sessionCatalog.hydrateInitialPage(id: session.id) }
                    try Task.checkCancellation()
                    guard sessionRestoreRequest == restoreRequest,
                          SessionRestorePresentationPolicy.ownsHydration(route: route, path: appState.path) else { return }
                    SessionRestoreMetadataReconciler.reconcile(authoritative, workspaces: hermesWorkspaces)
                    if !featureOwnsHydration { _ = featureStore.prepare(route) }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, sessionRestoreRequest == restoreRequest else { return }
                    actionErrorMessage = "This chat could not be refreshed. Your saved conversation and draft are still available."
                }
            }
        } catch {
            // While the host is reconnecting, open the saved conversation; it
            // catches up once the connection returns instead of showing an error.
            if openCachedChatWhileReconnecting(route) { return }
            actionErrorMessage = "This session could not be prepared. Try again."
        }
    }

    /// Opens a retained chat from its saved history when the only problem is a
    /// missing host connection, and asks the host to reconnect.
    private func openCachedChatWhileReconnecting(_ route: AppRoute) -> Bool {
        guard case .chat(let id) = route, let store = nativeWorkspaceStore, !store.isConnected,
              featureStore.preparedModel(for: route) != nil else { return false }
        appState.activateConversation(id: id, source: .sessions)
        connectionKeeper.retry()
        return true
    }

    func openSessionSelection(_ session: SessionSummary) {
        switch SessionSelectionRouting.target(for: session) {
        case .session:
            openSession(session)
        case .hostedRoom(let roomID):
            guard let owner = currentWorkspaceOwner else {
                actionErrorMessage = "This group is no longer available on the selected host."
                return
            }
            openHostedGroup(roomID, owner: owner, settings: false)
        }
    }

    func forkSession(sourceID: String, throughItemID: String) {
        Task {
            do {
                let fork = try await sessionCatalog.forkSession(
                    id: sourceID,
                    throughItemID: throughItemID
                )
                let route = AppRoute.chat(conversationID: fork.id)
                guard try featureStore.prepareForUserNavigation(route) else {
                    actionErrorMessage = "The fork was created, but could not be opened. Find it in Sessions."
                    return
                }
                appState.activateConversation(id: fork.id, source: .fork)
            } catch {
                actionErrorMessage = "This checkpoint could not be forked. Refresh the session and try again."
            }
        }
    }

    func openPrepared(_ route: AppRoute) {
        do {
            guard try featureStore.prepareForUserNavigation(route) else { return }
            appState.open(route)
        } catch {
            if openCachedChatWhileReconnecting(route) { return }
            actionErrorMessage = "This session could not be prepared. Try again."
        }
    }

    private func openDashboardInboxItem(_ item: DashboardInboxItem) {
        guard let sessionID = item.sessionID,
              let session = sessionCatalog.session(id: sessionID) else {
            actionErrorMessage = "This conversation is no longer available."
            return
        }
        openSession(session.summary)
    }

    private func openDashboardAttentionItem(_ item: DashboardAttentionItem) {
        if let approvalID = item.approvalID {
            openApproval(requestID: approvalID)
            return
        }
        guard let session = featureStore.dashboardModel.session(for: item) else {
            actionErrorMessage = "This conversation is no longer available."
            return
        }
        openSession(session.summary)
    }

    private func openDashboardWorkItem(_ item: DashboardWorkItem) {
        guard let session = sessionCatalog.session(id: item.sessionID) else {
            actionErrorMessage = "This conversation is no longer available."
            return
        }
        openSession(session.summary)
    }

    /// The demo dashboard reads as connected only in the Home work fixture.
    private var dashboardFixtureIsConnected: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-use-demo-fixtures") && arguments.contains("-test-home-work") { return true }
        #endif
        return false
    }

    @BighelpThemeReader private var theme

}

private extension BighelpIncomingURLRoute {
    /// Routes that open a chat or the agent home need the host's workspace.
    var opensWorkspaceContent: Bool {
        switch self {
        case .home, .chat, .newChat, .agentChat, .kanban, .approval, .group, .projects, .workflows, .workflow: true
        // Feed, Ideas, Goals and Agents show their saved items and refresh themselves; waiting for
        // the host before even switching tabs made these links feel broken.
        case .agent, .agents, .scheduledTasks, .scheduledTask, .sessions, .settings: false
        }
    }
}

/// Links, Handoff from the Watch (what it was showing, opened here), and
/// screens Shortcuts open. Its own modifier keeps RootShellView's body small
/// enough to type-check.
private struct IncomingLinks: ViewModifier {
    let open: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .onOpenURL(perform: open)
            .onContinueUserActivity(WatchPhoneLink.handoffActivityType) { activity in
                if let link = activity.userInfo?["url"] as? String, let url = URL(string: link) { open(url) }
            }
            .onChange(of: BighelpIncomingLinkCenter.shared.pending, initial: true) { _, link in
                if let link, BighelpIncomingLinkCenter.shared.consume(link) { open(link.url) }
            }
    }
}

/// "Unable to open" and the Host Status it offers. Links and widgets fail
/// while a chat may be open on top of the root, so every screen in the stack
/// carries it; only the visible one can present.
private struct OpenErrorPresentation: ViewModifier {
    let root: RootShellView

    func body(content: Content) -> some View {
        root.openErrorPresentations(content)
    }
}

/// Before a computer's workspace opens: what the connection is doing, why it
/// stopped (in the computer's own words), and Reconnect once nothing's running.
private struct NativeWorkspaceStatusView: View {
    let status: HostConnectionStatus
    let message: String
    let registry: BighelpHostRegistry?
    let reconnect: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Hermes workspace", systemImage: "network")
        } description: {
            Text(message)
        } actions: {
            BighelpConnectionPill(phase: status.phase, label: status.label)
            if status.phase != .connecting {
                Button("Reconnect", action: reconnect)
            }
        }
        .accessibilityIdentifier("native-workspace.connecting")
        .toolbar { BighelpHostsToolbarLink(registry: registry) }
    }
}
