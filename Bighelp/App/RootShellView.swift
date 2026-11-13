import SwiftUI
import UIKit

@MainActor
struct RootShellView: View {
    #if DEBUG
    @State var voiceSettingsPreview = VoiceSettingsPreviewClient()
    #endif

    @AppStorage("loopdy.onboarding.first-run-v1.completed")
    private var hasCompletedFirstRunOnboarding = false
    /// Connected, with the plugin, notifications and mode steps still to go (`FirstRunOnboarding`).
    @AppStorage(FirstRunOnboarding.afterConnectKey)
    private var isOnboardingAfterConnect = false
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
    /// Opens the workspace if it didn't open, on the connection already up.
    var reopenNativeWorkspace: (@MainActor () async -> Void)? = nil
    var agentIsland: AgentIslandModel? = nil
    /// Every agent on every host (the all-hosts view), kept across host switches.
    var fleet: FleetStore? = nil

    @Environment(\.bighelpHostRegistry) var hostRegistry
    @Environment(\.managedNotificationService) private var managedNotifications
    @State var actionErrorMessage: String?
    /// The tap (a Live Activity, an alert) whose new computer is still connecting; its timer runs once.
    @State private var externalOpenWaitID: UUID?
    @State var isHostStatusPresented = false
    @State private var actionErrorShowsHostStatus = false
    @State var hostRuntime: HostRuntimeStore?
    /// A widget or notification link that arrived before the host answered.
    @State private var pendingIncomingURL: URL?
    /// Offered as "Try Again" in the error alert.
    @State var actionErrorRetry: (@MainActor () -> Void)?

    @State var sessionRestoreRequest: SessionRestoreRequest?
    @State var sessionRestoreTask: Task<Void, Never>?
    @State var canonicalChatCoordinator = CanonicalChatCoordinator()
    @State var simpleBotsChatOpening = SimpleBotsChatOpening()
    @State var chatDissolve = ChatDissolveTransition()
    @State var managementStore: WorkspaceManagementStore?
    /// Host pages open in the stack, one per destination (`WorkspaceOpenScreens`).
    @State var capabilitiesPresentations = WorkspaceOpenScreens<NativeCapabilitiesPresentation>()
    @State var administrationPresentations = WorkspaceOpenScreens<NativeAdministrationPresentation>()
    @State var lifecycleCoordinator: NativeWorkspaceLifecycleCoordinator?
    @State var lifecycleProfileID: String?
    @State var lifecyclePresentationID: UUID?

    @State var isGroupCreationPresented = false
    @State var groupCreationSeed: String?
    @State var groupCreationOwner: WorkspaceOwner?
    @State private var isStartingNewChat = false
    @State private var newChatStartID: UUID?
    @State private var fixtureCanonicalSessions: [String: String] = [:]
    @State var workspaceFixtureGeneration = UUID()
    /// Demo runs' connection; `-demo-reconnects-on-return` makes each return a reconnect.
    @State var workspaceFixtureConnection = UUID()
    @State private var cardInteractionStore = BighelpCardInteractionStore()
    @Environment(\.workspaceConnections) var workspaceConnections
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.bighelpScreen) var screen
    @Environment(\.bighelpSplitColumn) var splitColumn
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State var connectionKeeper = WorkspaceConnectionKeeper()
    /// The computer and sign-in open screens belong to (`WorkspacePresentationContinuity`).
    @State var workspaceSignIn: WorkspaceSignIn?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Settings sheet, held by `AppState` so code outside the view can open it to a page.
    var isUnifiedSettingsPresented: Bool {
        get { appState.isSettingsPresented }
        nonmutating set { appState.isSettingsPresented = newValue }
    }
    @State private var isKeyboardVisible = false
    @State private var rootBottomSafeArea: CGFloat = 0
    @State private var afterSettingsDismiss: (() -> Void)?
    /// Today's Edit, a space's page and the space Delete asks about.
    @State var isEditingToday = false
    @State var spacePage: TodaySpace?
    @State var deletingSpace: TodayPanelDescriptor?
    /// The connection the shell's board follows; Today's boards and a bot's Dashboard read through it.
    @State var agentBoard = AgentBoardStore()
    /// Provider Usage for the connected host; opened from chat ⋯, Settings and the context window.
    @State var providerUsage = ProviderUsageStore()
    @State var usage = UsageStore()
    @State var agentMedia = AgentMediaStore()
    /// Which bots are working or need you, for the home's three roots.
    @State var botChatActivity = BotChatActivityStore()
    /// The sidebar: iPad's slide-in panel, the Mac's and Vision Pro's column. iPhone has none.
    @State var isHomeDrawerPresented = false
    /// This shell, for the open Duo's list: a new shell replaces the list the last one showed.
    @State var splitColumnShellID = UUID()
    /// The connection the shell's Feed, Ideas and Goals were last set up for (`configureAgentBoard`).
    @State var agentBoardConfiguredKey: AgentBoardClientKey?
    /// The open Projects screens' chats and project details.
    @State var projectsStore: ProjectsStore?
    /// Coding sessions on the selected computer (`cacheScopeID`), kept through reconnects.
    @State var codeHome: CodeHomeStore?
    @State var codeSheet: CodeSheet?
    @State var devFactory: DevFactoryStore?
    @State var kanbanModel: KanbanBoardModel?
    @State var kanbanAvailability = KanbanAvailability()
    @State var kanbanTaskToOpen: String?
    /// The connected computer's Workflows, when its plugin has them.
    @State var workflowsStore: WorkflowsStore?
    @State var workflowsAvailability = WorkflowsAvailability()
    @State var isNeedsYouPresented = false
    @State var didPresentDemoNeedsYou = false
    #if os(visionOS)
    @Environment(\.openWindow) var openWindow
    @Environment(\.spatialAvatar) var spatialAvatar
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
            },
            storedSessionID: {
                guard currentWorkspaceOwner == owner else { return nil }
                if let coordinate = nativeRuntime?.bridge.currentCoordinate(for: model.conversationID) {
                    return coordinate.storedSessionID ?? coordinate.runtimeSessionID
                }
                // The demo's drafts belong to the chat itself.
                return usesWorkspaceFixtures ? model.conversationID : nil
            }
        )
    }

    var body: some View {
        agentHomeSheets(rootContent)
        .modifier(AIDataConsentGate(inFirstSetup: presentsFirstRunOnboarding || hostRegistry?.isWorkspaceReady != true,
                                    usesDemoData: usesWorkspaceFixtures))
        .modifier(pendingShareReview)
        .modifier(FleetHooks(
            liveKey: liveFleetKey, readiness: fleetOpenReadiness, hostsKey: fleetHostsKey, scenePhase: scenePhase,
            keepsConnected: keepsFleetHostsConnected,
            recordLive: recordLiveFleet, openPending: openPendingFleetIfReady,
            syncHosts: syncFleetHosts, cancelReads: { fleet?.cancelReads() },
            setKeepsConnected: setKeepsFleetHostsConnected))
        .modifier(FleetSectionAdoption(placements: agents.profiles.compactMap(\.placement),
                                       adopt: { fleet?.adoptSections(adding: $0) }))
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
        .modifier(ChatDissolveLifetime(transition: chatDissolve, appState: appState,
                                      signIn: workspaceSignIn, scenePhase: scenePhase))
        .modifier(CanonicalChatLifetime(coordinator: canonicalChatCoordinator, appState: appState,
                                        owner: currentWorkspaceOwner, agentID: homeAgent?.id))
        .modifier(WorkspacePresentationContinuity(
            owner: currentWorkspaceOwner, registryGeneration: hostRegistry?.generation,
            isHostSettled: nativeRuntime.map { $0.isReady && !$0.isSuspended && !$0.isRefreshing } ?? true,
            signIn: $workspaceSignIn, close: closeWorkspacePresentations,
            reattach: reattachWorkspacePresentations))

        .bighelpSheet(isPresented: $isGroupCreationPresented) {
            BotModeCreateRoomView(rooms: botModeRooms, agents: agents, seedProfileID: groupCreationSeed,
                                  sectionChoice: groupSectionChoice) { roomID in
                // A reconnect while the sheet was open is still this computer.
                guard let owner = groupCreationOwner, isCurrentSignIn(owner),
                      let current = currentWorkspaceOwner else { return }
                openHostedGroup(roomID, owner: current, settings: false)
            }
            .bighelpSheetSize(.standard)
        }
        // With Settings open (Settings › System › Add Host), Settings presents it: one view shows one sheet.
        .modifier(HostSetupSheet(registry: hostRegistry, isActive: !isUnifiedSettingsPresented))
        .onChange(of: hostRegistry?.selectedHostID) { _, _ in
            chatDissolve.cancel()
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
            // A quick trip away (the app switcher, a widget, a notification opened) keeps the phone tools,
            // like the host connection, until the background grace ends; only then are calls retired and
            // the channel closed as paused. A shortcut out in Shortcuts keeps them on its own (`DeviceToolHandoff`).
            if phase == .background {
                DeviceToolHandoff.shared.holdBackgroundGrace()
                BighelpBackgroundGrace.shared.begin("device-tools") { [permissionCenter] in
                    // Back on screen as it ran out (still inactive): nothing to stop.
                    guard UIApplication.shared.applicationState == .background else { return }
                    DeviceToolHandoff.shared.releaseBackgroundGrace()
                    if !DeviceToolHandoff.shared.isActive { permissionCenter.deviceTools.invalidateOperations() }
                }
            } else {
                DeviceToolHandoff.shared.releaseBackgroundGrace()
            }
        }
        .task(id: hostRuntimeScope) { await prepareHostRuntime() }
        .onChange(of: agents.errorMessage) { _, _ in
            Task { await currentHostRuntime?.refresh() }
        }
        .modifier(IncomingLinks(open: handleIncomingURL))
        // A voice start that can't open says why; the voice stage mustn't hide that.
        .onChange(of: actionErrorMessage != nil) { _, failed in if failed { VoiceLaunchState.shared.finish() } }
        .modifier(LostChatHooks(featureStore: featureStore, attach: watchForLostChats))
        .modifier(DriveShellHooks(appState: appState, featureStore: featureStore, agents: agents,
                                  usesDemoFixtures: usesDemoFixtures))
        .modifier(BighelpShortcutParameterUpdates(agents: agents, scheduledTasks: featureStore.scheduledTasks,
                                                  rooms: botModeRooms, catalog: sessionCatalog))
        .modifier(PendingLinkRetry(acceptsLinks: acceptsIncomingLinks, acceptsChatStarts: acceptsChatStarts,
                                   retry: openPendingIncomingChatIfNeeded))
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
                if nativeRuntime != nil, !signInEndedBeforeOpening { workspace }
                // Every computer shows: the home stays on screen, from the computers' saved copies,
                // while the tapped one's computer connects.
                else if showsEveryHost, fleet?.pendingOpen != nil { conversationsRoot }
                else if nativeWorkspaceHasProblem { nativeWorkspace }
                // A moment, as the app starts: the saved workspace opens once iOS lets its files be read.
                else { theme.canvas.ignoresSafeArea().accessibilityIdentifier("native-workspace.opening") }
            } else if let registry = hostRegistry, registry.connectionMode == .independent, !usesWorkspaceFixtures {
                BighelpHostsPage(registry: registry)
            } else if usesWorkspaceFixtures {
                workspace
            } else {
                nativeWorkspace
            }
        }
        .overlay {
            ZStack { simpleBotsOpeningLoader }
                .animation(.snappy, value: fleet?.pendingOpen != nil)
                .animation(.snappy, value: simpleBotsChatOpening.isShowing)
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
        if isOnboardingAfterConnect, !hostRegistry.hosts.isEmpty { return true }
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
        lifecycleCoordinator = nil
        lifecycleProfileID = nil
        lifecyclePresentationID = nil
        isGroupCreationPresented = false
        fixtureCanonicalSessions = [:]
    }

    private func completeFirstRunOnboarding() {
        // "How do you want to start?" was just answered: this run opens there too.
        home.land(on: settings.homeLanding, view: settings.homeView)
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
              hostRegistry.onboardingHostID == nil, !isOnboardingAfterConnect else { return }
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
                    // The socket can still be up with no workspace open (a wake while the phone was
                    // locked); reconnect() leaves a live socket alone.
                    await reopenNativeWorkspace?()
                    await nativeRuntime?.refresh()
                }
            }
        )
    }

    /// Something to say before the workspace opens: its saved files didn't open, the sign-in ended or the
    /// connection failed. Otherwise nothing waits on screen for the computer.
    private var nativeWorkspaceHasProblem: Bool {
        nativeWorkspaceError != nil || nativeRuntime?.errorMessage != nil
            || nativeWorkspaceStore?.requiresAuthentication == true || connectionKeeper.state == .disconnected
    }

    /// The saved workspace shows before its computer answers (`NativeWorkspaceSelectionStore`). A sign-in
    /// that ended before it connected once this run keeps the opening screen, which has Sign in again.
    private var signInEndedBeforeOpening: Bool {
        nativeWorkspaceStore?.requiresAuthentication == true && nativeRuntime?.isReady == false
    }

    /// Opening the workspace counts as connecting until it's open, and so do
    /// the keeper's quiet retries, as the island says. A connection with no workspace
    /// yet and no error (a wake while the phone was locked) is still connecting.
    private var nativeWorkspaceStatus: HostConnectionStatus {
        let host = HostConnectionStatus(workspace: nativeWorkspaceStore, keeper: connectionKeeper)
        if nativeWorkspaceStore?.requiresAuthentication == true { return host }
        let failed = nativeWorkspaceError != nil || nativeRuntime?.errorMessage != nil
        let isWorking = nativeRuntime?.isRefreshing == true || host.phase == .connecting || host.phase == .reconnecting
            || (nativeRuntime == nil && !failed && host.phase == .connected)
        return HostConnectionStatus(isConnected: !isWorking && !failed && host.phase == .connected,
                                    isConnecting: isWorking, isFirstConnection: !connectionKeeper.hasConnected)
    }

    var workspace: some View { workspaceShell }

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

    private var shell: some View {
        rootTabs
        .toolbar(.hidden, for: .tabBar)
        // Every root draws its own header (`HomeHeaderBar`); a pushed page has the bar's or its own.
        .toolbar(.hidden, for: .navigationBar)
        .modifier(HomeBars(isAtRoot: appState.path.isEmpty, isKeyboardVisible: isKeyboardVisible,
                           selection: tabSelection, items: homeTabItems, onNewChat: { openNewChat() },
                           bottomInset: rootBottomSafeArea, selectedTint: theme.action, tint: theme.secondaryText))
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { rootBottomSafeArea = $0 }
        // The iPhone Duo open: the list beside the page.
        .onChange(of: splitColumnKey, initial: true) { updateSplitColumn() }
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
            routeDestination(route)
                .environment(\.providerUsage, providerUsage)
                .environment(\.needsYouDeckContext, needsYouDeckContext)
                // The root is hidden under a pushed screen and can't present; the top screen does.
                .modifier(OpenErrorPresentation(root: self))
        }
        .modifier(OpenErrorPresentation(root: self))
        .bighelpSheet(isPresented: Binding(get: { appState.isSettingsPresented },
                                           set: { appState.isSettingsPresented = $0 }), onDismiss: {
            // A swipe-down closes the sheet without `closeSettings`. Not when it has opened again.
            if !appState.isSettingsPresented { appState.settingsPath = NavigationPath() }
            let action = afterSettingsDismiss
            afterSettingsDismiss = nil
            action?()
        }) {
            settingsSheetContent
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

    /// The Settings sheet, from the person's circle on every root. Its stack's path lives in `AppState`, and
    /// `SettingsDestination` values pushed on it draw here.
    private var settingsSheetContent: some View {
        // Done on every page closes Settings; Back steps through its pages.
        let settingsSheet = workspaceSettings().withDone { isUnifiedSettingsPresented = false }
        return NavigationStack(path: Binding(get: { appState.settingsPath },
                                             set: { appState.settingsPath = $0 })) {
            settingsSheet.settingsDone(settingsSheet)
                .navigationDestination(for: SettingsDestination.self) { settingsSheet.showing($0) }
        }
        .bighelpSheetSize()
        .presentationDragIndicator(.visible)
        .modifier(HostSetupSheet(registry: hostRegistry, isActive: true))
    }

    /// The three places. The shell switches the root itself: a hidden TabView creates a UIKit
    /// containment boundary that drops feature search and toolbar actions. On the open iPhone Duo a
    /// list shows left of the fold instead, and the page beside it waits for a pick.
    @ViewBuilder
    var rootTabs: some View {
        if let splitList, splitList.isList { splitPlaceholder(splitList) } else { homeRoot(appState.selectedTab) }
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
        let action = side == .left ? settings.leftEdgeSwipeAction : settings.rightEdgeSwipeAction
        Color.clear
            .frame(width: WorkspaceEdgeSwipeResolver.activationEdgeWidth)
            .contentShape(Rectangle())
            // Below the header row, so the buttons in its corners keep their taps.
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

    /// Where an edge swipe goes, from any screen (a chat included).
    func performWorkspaceAction(_ action: WorkspaceSwipeAction) {
        BighelpKeyboard.dismiss()
        switch action {
        case .quickWorkspace:
            // The sidebar where there is one; the phone has none, so its chats.
            if sidebarIsAvailable { isHomeDrawerPresented.toggle() } else { appState.select(.chats) }
        case .newChat:
            openNewChat()
        case .sessions:
            appState.select(.chats)
        case .agents:
            appState.select(.bots)
        case .home:
            appState.select(.conversations)
        case .profile:
            openBotPageOrSettings()
        case .none:
            break
        }
    }

    /// In a chat with one bot, that bot's page; anywhere else, Settings.
    private func openBotPageOrSettings() {
        if case .simpleBotProfile? = appState.path.last { return }
        if case .chat(let id)? = appState.path.last, let model = featureStore.preparedChatModel(id: id),
           !model.isBotMode, let botID = model.memberIDs.first {
            appState.open(.simpleBotProfile(agentID: botID))
        } else {
            isUnifiedSettingsPresented = true
        }
    }

    /// One computer's Sessions page, pushed from Chats: projects, imports from other apps, one
    /// bot's chats.
    func oneHostSessions(_ model: SessionsModel) -> SessionsView {
        SessionsView(
            model: model,
            agents: agents,
            settings: settings,
            organizeByProjects: settings.organizeChatsByProjects,
            sessionOrganizationAccountID: sessionOrganizationAccountID,
            sessionOrganizationHostID: sessionOrganizationHostID,
            onStartChat: { startNewChat(explicitAgentID: $0) },
            onNewGroupChat: newGroupChatAction,
            onSelect: { openSessionSelection($0) },
            otherApps: otherAppChats,
            onOpenBroughtIn: { openBroughtInChat($0) },
            projectMove: chatProjectMove
        )
    }

    /// Codex and Claude Code chats on the working computer, through its own Hermes; demo mode
    /// has samples. What it's for (sign-in and agent) names the list, so another one reloads it.
    var otherAppChats: (source: any OtherAppChatsSource, id: String)? {
        if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true {
            let opened = sessionCatalog.recentSummaries(includeCronSessions: false).first { $0.kind == .direct }?.id
            return opened.map { (DemoOtherAppChats(openedSessionID: $0), "demo") }
        }
        guard let owner = currentWorkspaceOwner, let connections = workspaceConnections, connections.owner == owner,
              let direct = connections.hosts.selectedWorkspace?.nativeClient else { return nil }
        let client = DirectHermesSessionMaintenanceClient(
            rpc: direct, http: direct, owner: owner, currentOwner: { [weak connections] in connections?.owner },
            // Bringing a chat in never closes a running one.
            resolveClosableRuntime: { _ in throw HermesSessionMaintenanceError.invalidRequest },
            reconcileClosedRuntime: { _ in throw HermesSessionMaintenanceError.invalidRequest })
        return (LiveOtherAppChats(client: client, profileID: workspaceAgentID),
                "\(owner.authority.cacheScopeID)|\(owner.connectionGeneration)|\(workspaceAgentID)")
    }

    /// A chat brought in from Codex or Claude Code opens like any other, once Hermes lists it.
    func openBroughtInChat(_ storedSessionID: String) {
        if let record = sessionCatalog.session(id: storedSessionID) {
            openSession(record.summary)
            return
        }
        let profileID = workspaceAgentID
        Task { @MainActor in
            do {
                let record = try await sessionCatalog.resolveStoredSession(profileID: profileID,
                                                                           storedSessionID: storedSessionID)
                openSession(record.summary)
            } catch is CancellationError {
            } catch {
                actionErrorMessage = "The chat is in Hermes now, but it couldn't be opened. Find it in Chats."
            }
        }
    }

    /// + › New Group Chat: Hermes' hosted rooms, made in the New Group Chat sheet.
    var newGroupChatAction: (() -> Void)? {
        // The room store's own answer, not the published capability: that comes only after the whole
        // connection's refresh, so New Group Chat took 10 seconds or more after every return to the app.
        guard let owner = currentWorkspaceOwner, botModeRooms.offersNewGroupChat else { return nil }
        return {
            handleAgentWorkspaceAction(AgentWorkspaceActionRequest(owner: owner, action: .createGroup(seedProfileID: nil)))
        }
    }

    func leaveSettings(perform action: @escaping () -> Void) {
        if isUnifiedSettingsPresented {
            afterSettingsDismiss = action
            isUnifiedSettingsPresented = false
        } else {
            action()
        }
    }

    func workspaceSettings() -> SettingsView {
        SettingsView(
            settings: settings, userIdentity: userIdentity,
            agents: agents.profiles, personalities: personalities,
            permissionCenter: permissionCenter,
            onOpenSessions: { leaveSettings { appState.select(.chats) } },
            onOpenScheduledTasks: { leaveSettings { openScheduledTasks(filteredTo: nil) } },
            onClearLocalCache: {
                if let nativeRuntime { return await nativeRuntime.refreshLocalCache() }
                return await clearLocalCache()
            },
            voiceSettingsScope: voiceSettingsScope, voiceSettingsClient: voiceSettingsClient,
            voiceSettingsIsCurrent: voiceSettingsIsCurrent,
            agentDirectory: agents,
            onOpenWorkspaceDestination: { destination in
                leaveSettings { openWorkspaceDestination(destination) }
            },
            onOpenRoute: { route in
                leaveSettings { openPrepared(route) }
            },
            connectorApps: { connectorAppsModel() },
            composioApps: { composioAppsModel() },
            marketplace: { makeMarketplace(for: workspaceAgentID) },
            credentialVault: homeCredentialVault,
            teamwork: { teamworkModel() },
            fleet: fleet.map { fleet in
                SettingsFleetAccess(maintenance: { fleet.maintenance() }, gatewayCount: { fleet.hosts.count })
            },
            usage: providerUsage,
            pendingShares: settingsPendingShareContext,
            archivedChats: settingsArchivedChats,
            computerTimeZone: computerTimeZoneSettings()
        )
    }

    /// Settings › Chat › Archived chats: a chat opened from it leaves Settings for the chat.
    private var settingsArchivedChats: SettingsArchivedChats {
        let agents = agents
        return SettingsArchivedChats(
            catalog: sessionCatalog,
            agentName: { id in agents.profiles.first { $0.id == id }?.name ?? id },
            onOpen: { summary in
                leaveSettings { openSession(summary) }
            })
    }

    /// Settings › Your computers › Time zone: saved for every bot on the computer in use, read
    /// through its primary bot. Nil without a computer to ask.
    private func computerTimeZoneSettings() -> @MainActor () -> SimpleBotHostSettings? {
        let agents = agents
        return {
            guard let configuration = makeSimpleBotHostConfiguration() else { return nil }
            let profile = agents.resolvedAgent(explicitID: nil)?.id ?? "default"
            return SimpleBotHostSettings(client: configuration, profile: profile,
                                         allProfiles: { agents.profiles.map(\.id) })
        }
    }

    /// Settings › Teamwork on the computer in use; demo mode's made-up computer otherwise.
    func teamworkModel() -> TeamworkModel? {
        if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true {
            return TeamworkModel(client: DemoTeamworkClient.shared)
        }
        guard currentWorkspaceOwner != nil else { return nil }
        return TeamworkModel(client: DirectHermesTeamworkClient(
            workspace: { [weak workspaceConnections] in workspaceConnections?.workspace }))
    }

    /// Settings › Connections › Composio Apps: your Composio sign-in, and the agent in use on the
    /// computer in use (or `agentID`, a bot's Marketplace); made-up apps in demo mode.
    func composioAppsModel(for agentID: String? = nil) -> ComposioAppsModel? {
        if usesWorkspaceFixtures {
            #if DEBUG
            return DemoComposio.model()
            #else
            return nil
            #endif
        }
        var agentHost: (any ComposioAgentHost)?
        if let workspace = workspaceConnections?.workspace, let owner = currentWorkspaceOwner,
           let direct = workspaceConnections?.hosts.selectedWorkspace?.nativeClient {
            let profileID = agentID ?? workspaceAgentID
            let agentName = agentID.flatMap { id in agents.profiles.first { $0.id == id }?.name } ?? workspaceProfileName
            let current: @MainActor () -> WorkspaceOwner? = { [weak workspace] in workspace?.owner }
            agentHost = DirectHermesComposioAgentHost(
                hostName: workspaceHostName, agentName: agentName, profileID: profileID,
                workspace: workspace,
                mcp: DirectHermesMCPClient(http: direct, rpc: direct, owner: owner, profileID: profileID,
                                           currentOwner: current, actionStatusClient: nil))
        }
        return ComposioAppsModel(account: .shared, agentHost: agentHost)
    }

    /// Settings › Connections for the computer in use, while it's connected; sample apps in demo mode.
    func connectorAppsModel() -> ConnectorAppsModel? {
        if let workspace = hostRegistry?.selectedWorkspace, hostRegistry?.selectedHostID != nil {
            guard workspace.isConnected else { return nil }
            return ConnectorAppsModel(service: DirectHermesConnectorAppsService(workspace: workspace),
                                      nousSignIn: { providerSignInStore() })
        }
        guard usesWorkspaceFixtures else { return nil }
        #if DEBUG
        let signedOut = ProcessInfo.processInfo.arguments.contains("-test-connectors-signed-out")
        return ConnectorAppsModel(service: DemoConnectorAppsService(signedOut: signedOut),
                                  nousSignIn: { DemoProviderKeys.store() })
        #else
        return ConnectorAppsModel(service: DemoConnectorAppsService())
        #endif
    }

    /// A provider sign-in for the computer and agent in use, built as AI providers builds its own, for
    /// a page that signs in without opening AI providers (Apps' Nous Portal sign-in). The caller retires it.
    func providerSignInStore() -> ProviderAccountsStore? {
        guard let owner = currentWorkspaceOwner, let connections = workspaceConnections,
              let direct = connections.hosts.selectedWorkspace?.nativeClient else { return nil }
        let profileID = workspaceAgentID
        let currentOwner: @MainActor () -> WorkspaceOwner? = {
            Data(workspaceAgentID.utf8) == Data(profileID.utf8) ? currentWorkspaceOwner : nil
        }
        return ProviderAccountsStore(
            hostName: workspaceHostName, profileID: profileID,
            servingProfileID: connections.workspace?.nativeContext?.servingProfileID,
            client: DirectHermesProviderClient(rpc: direct, http: direct, owner: owner, currentOwner: currentOwner),
            hostSignIn: ProviderHostSignInStore(
                profileID: profileID, hostName: workspaceHostName,
                client: DirectHermesHostSignInClient(owner: owner, currentWorkspace: { [weak connections] in
                    currentOwner() == owner ? connections?.workspace : nil
                })
            )
        )
    }



    /// The menu bar's New Chat (⌘N), Settings (⌘,), sidebar (⌃⌘S) and, on the Mac, the three
    /// places (⌘1–⌘3).
    private var menuCommandActions: BighelpShellActions {
        let selection = tabSelection
        return BighelpShellActions(
            newChat: { openNewChat() },
            openSettings: { isUnifiedSettingsPresented = true },
            isSidebarOpen: isHomeDrawerPresented,
            toggleSidebar: { isHomeDrawerPresented.toggle() },
            selectTab: { selection.wrappedValue = $0 },
            tabs: homeTabItems
        )
    }

    /// `opened` gets the chat Hermes made, after the local canvas it showed first has passed it on.
    /// `tracksNewChat`: this is New chat's own blank chat, so each ID it shows under (the canvas,
    /// then Hermes' chat) is the one that draws the To row (`newChatSlot(forChat:model:)`). When
    /// New chat's blank chat is already on top (another bot was picked for it), the new one takes
    /// its place in one step.
    func startNewChat(explicitAgentID: String?, startsVoice: Bool = false, tracksNewChat: Bool = false,
                      opened: (@MainActor (String) -> Void)? = nil) {
        let replacesBlankChat = tracksNewChat && newChatSession.conversationID != nil
            && appState.path.last == newChatSession.conversationID.map { .chat(conversationID: $0) }
        // New chat's choices row reads this computer's projects.
        if tracksNewChat { prepareCodeHome() }
        runNewChatStart(retry: { startNewChat(explicitAgentID: explicitAgentID, startsVoice: startsVoice,
                                              tracksNewChat: tracksNewChat, opened: opened) }) {
            let outcome = try await newChatCoordinator.start(
                explicitAgentID: explicitAgentID, replacingBlankChat: replacesBlankChat,
                beforePresentation: { next, previous in
                    presentNewChatDissolve(next, replacing: previous)
                    if tracksNewChat { newChatSession.conversationID = next }
                })
            guard case .opened(let id, _) = outcome else { return }
            if startsVoice { appState.requestVoiceMode(for: id) }
            opened?(id)
        }
    }

    /// A widget's New Chat arrives as the app wakes, before the host connection
    /// (dropped in the background) is back; creating the chat then failed with
    /// "host unavailable". Wait for the host the way Shortcuts do.
    private func startIncomingNewChat(agentID: String?) {
        runNewChatStart(retry: { startIncomingNewChat(agentID: agentID) }) {
            if let shortcutService, nativeRuntime != nil, !usesWorkspaceFixtures {
                try await shortcutService.openNewChat(agentID: agentID, beforePresentation: presentNewChatDissolve)
            } else {
                let known = agentID.flatMap { id in agents.profiles.contains(where: { $0.id == id }) ? id : nil }
                _ = try await newChatCoordinator.start(explicitAgentID: known,
                                                       beforePresentation: presentNewChatDissolve)
            }
        }
    }

    func presentNewChatDissolve(_ nextID: String, replacing previousID: String?) {
        chatDissolve.present(nextID: nextID, replacing: previousID, reduceMotion: reduceMotion)
    }

    func runNewChatStart(retry: @escaping @MainActor () -> Void,
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
                chatDissolve.cancel()
                // A replaced account or host must not present the old request's error.
            } catch {
                chatDissolve.cancel()
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



    var workspaceAgentID: String {
        agents.resolvedAgent(explicitID: nil)?.id ?? "default"
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

    /// The computer in use's Sessions page over where the person is; `agentID` shows one bot's chats.
    func openSessions(filteredTo agentID: String?) {
        guard featureStore.prepareSessions(filteredTo: agentID) else { return }
        if appState.path.last != .sessions { appState.open(.sessions) }
    }

    /// Scheduled tasks over where the person is; `agentID` shows one bot's routines.
    func openScheduledTasks(filteredTo agentID: String?) {
        guard featureStore.prepareScheduledTasks(filteredTo: agentID) else { return }
        if appState.path.last != .scheduledTasks { appState.open(.scheduledTasks) }
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
            .bighelpSheet(isPresented: $isHostStatusPresented) {
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
        // The way back from Shortcuts to a phone-tool call: not a screen to open.
        if DeviceToolHandoff.shared.handleCallback(url) { return }
        guard let route = BighelpIncomingURLRoute.parse(url) else { return }
        if holdsLinkForItsComputer(url) { return }
        // Opened while the app starts or comes back, a link found no workspace
        // ("host unavailable") or opened its chat under an alert. It waits for
        // a host that answers instead; the latest one wins.
        if route.opensWorkspaceContent, !(route.startsAChat ? acceptsChatStarts : acceptsIncomingLinks) {
            pendingIncomingURL = url
            return
        }
        switch route {
        case .home:
            // Notifications and older links named the Activity inbox. Updates,
            // approvals and questions now live in the bot's chat.
            openPrimaryBotChat()
        case .chat(let sessionID):
            openIncomingChat(sessionID: sessionID)
        case .agent(let tab, let agentID):
            // From the Watch and the widgets: that bot's Feed, Ideas or Goals over Today. The
            // primary bot stays who it is.
            switch tab {
            case "feed": showOverToday(.feed, agentID: agentID)
            case "ideas": showOverToday(.idea, agentID: agentID)
            case "goals": showOverToday(.goal, agentID: agentID)
            case "apps":
                if let id = agentID ?? homeAgent?.id {
                    appState.open(.simpleBotProfile(agentID: id, opening: BotProfileOpening(tab: .files)))
                }
            default: openPrimaryBotChat()
            }
        case .newChat(let agentID):
            startIncomingNewChat(agentID: agentID)
        case .agentChat(let agentID, let hostID):
            openIncomingAgentChat(agentID: agentID, hostID: hostID)
        case .voice(let agentID, let hostID):
            openIncomingAgentChat(agentID: agentID, hostID: hostID, startsVoice: true)
        case .scheduledTasks:
            guard featureStore.prepareScheduledTasks(filteredTo: nil) else { return }
            showOverWork([.scheduledTasks])
        case .scheduledTask(let id):
            guard featureStore.prepareScheduledTasks(filteredTo: nil),
                  (try? featureStore.prepareForUserNavigation(.scheduledTask(id: id, agentID: nil))) == true else { return }
            showOverWork([.scheduledTasks, .scheduledTask(id: id, agentID: nil)])
        case .sessions:
            appState.select(.chats)
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
            appState.select(.bots)
        case .projects:
            openProjects()
        case .settings:
            isUnifiedSettingsPresented = true
        case .workflows:
            openWorkflows()
        case .workflow(let id, _, let startsRun):
            openWorkflow(id: id, startsRun: startsRun)
        case .workflowRun(let id):
            openWorkflows(run: id)
        case .usage:
            openUsage()
        }
    }

    /// A link naming a computer (a widget or Shortcut set to one gateway, a workflow)
    /// opens there. True when it can't open yet: bighelp switched to that computer
    /// and the link waits until it answers, or it can't be opened and says why.
    private func holdsLinkForItsComputer(_ url: URL) -> Bool {
        guard let hostID = BighelpIncomingURLRoute.hostID(in: url), let fleet else { return false }
        guard let host = fleet.reader.hosts.first(where: { $0.id == hostID }) else {
            actionErrorMessage = "That computer isn't in bighelp anymore."
            return true
        }
        guard !host.isSelected else { return false }
        guard fleet.canOpen(hostID) else {
            actionErrorMessage = "\(host.name) is a sample host in this demo."
            return true
        }
        recordLiveFleet()
        pendingIncomingURL = url
        fleet.select(hostID)
        return true
    }

    private func openIncomingChat(sessionID: String) {
        // A chat's own ID starts "native-session-v1:"; only the scoped digest is an activity link.
        if ManagedNotificationValidation.isOpaqueSessionID(sessionID), let managedNotifications {
            sessionRestoreTask?.cancel()
            // Only a card this phone no longer owns, or whose computer is gone, gets here.
            do { try managedNotifications.openActivity(opaqueSessionID: sessionID) }
            catch { actionErrorMessage = "This chat can't be opened from here anymore. Find it in bighelp instead." }
            return
        }
        // Demo data opens links the way a real host does.
        if nativeRuntime != nil || usesDemoFixtures {
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
        switch open.target {
        case .catalog(let sessionID):
            guard BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
            handleIncomingURL(BighelpWidgetSnapshot.chatURL(sessionID))
            return
        case .reference(let profileID, let reference, let isScheduledRun):
            openNotifiedChat(open, profileID: profileID, reference: reference, isScheduledRun: isScheduledRun)
        case .stored(let hostID, let profileID, let storedSessionID):
            openStoredChat(open, hostID: hostID, profileID: profileID, storedSessionID: storedSessionID)
        }
    }

    /// A verified chat (a Live Activity, a managed alert). Saved on the phone, it opens at once from
    /// its saved history and catches up when the host answers, as a tapped alert does; a chat the
    /// phone hasn't seen yet waits for the host's list.
    private func openStoredChat(_ open: BighelpExternalSessionOpen, hostID: UUID?, profileID: String,
                                storedSessionID: String) {
        // bighelp holds only the selected computer's chats: while it switches to the card's
        // computer it has none yet, and a switch that was given back opens nothing.
        if open.switchedHost != nil, let hostID, hostRegistry?.selectedHostID != hostID {
            _ = BighelpExternalSessionOpenCenter.shared.consume(open)
            return
        }
        if holdsOpenForSwitchedComputer(open) { return }
        guard nativeRuntime != nil else { return }
        if let hostID, hostRegistry?.selectedHostID != hostID {
            _ = BighelpExternalSessionOpenCenter.shared.consume(open)
            return
        }
        if let record = SessionRecord.matching(storedID: storedSessionID, profileID: profileID,
                                               in: sessionCatalog.records) {
            guard BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
            openSession(record.summary)
            return
        }
        guard acceptsIncomingLinks, BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
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

    /// A tap that switched computers (a Live Activity or an alert of another one) opens nothing until
    /// that computer is ready. Opened while it was still connecting, the chat could fail to prepare
    /// and "This session could not be prepared" showed over the chat that then opened anyway. A
    /// computer that never answers ends the wait with the usual message and the selection goes
    /// back, as for a tap in the all-hosts view (`returnIfFleetHostDoesNotAnswer`).
    private func holdsOpenForSwitchedComputer(_ open: BighelpExternalSessionOpen) -> Bool {
        guard ExternalOpenHostWait.step(open, hostIsReady: isFleetHostReady, timedOut: false) != .openNow else {
            return false
        }
        guard externalOpenWaitID != open.id else { return true }
        externalOpenWaitID = open.id
        let waitingFor = hostRegistry?.selectedHostID
        Task { @MainActor in
            try? await Task.sleep(for: FleetSwitchFallback.timeout)
            // Connected by now, it opens like any link would. Otherwise: opened meanwhile or replaced
            // by a newer tap, nothing is left to give up.
            guard hostRegistry?.selectedWorkspace?.isConnected != true,
                  BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
            externalOpenWaitID = nil
            // A computer picked since then stands.
            guard hostRegistry?.selectedHostID == waitingFor else { return }
            giveUpOnSwitchedComputer(open)
        }
        return true
    }

    private func giveUpOnSwitchedComputer(_ open: BighelpExternalSessionOpen) {
        let unreachable = hostRegistry?.selectedHost?.name ?? "that computer"
        let previous = open.switchedHost?.from
        let stillOn = previous.flatMap { id in hostRegistry?.hosts.first { $0.id == id }?.name }
        if let previous, stillOn != nil {
            if let fleet { fleet.select(previous) } else { hostRegistry?.select(previous) }
        }
        actionErrorMessage = ExternalOpenHostWait.message(unreachable: unreachable, stillOn: stillOn)
    }

    /// A tapped alert's chat. Saved on the phone, it opens at once from its saved history and
    /// catches up when the host answers; a chat the phone hasn't seen yet waits for the host's list.
    /// A scheduled run's alert can name its job's chat or the job (`BighelpScheduledAlertLinks`).
    private func openNotifiedChat(_ open: BighelpExternalSessionOpen, profileID: String, reference: String,
                                  isScheduledRun: Bool) {
        if holdsOpenForSwitchedComputer(open) { return }
        guard nativeRuntime != nil || usesDemoFixtures else { return }
        if case .chat(let record)? = BighelpScheduledAlertLinks.place(
            reference: reference, profileID: profileID, records: sessionCatalog.records, tasks: nil,
            isScheduledRun: isScheduledRun) {
            guard BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
            openSession(record.summary)
            return
        }
        guard acceptsIncomingLinks, BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
        Task { @MainActor in
            // Workflow alerts point at a run, not a chat.
            if !isScheduledRun, await openNotifiedWorkflowRun(profileID: profileID, reference: reference) { return }
            let tasks = isScheduledRun ? await scheduledTasksForAlert() : nil
            if case .task(let task)? = BighelpScheduledAlertLinks.place(
                reference: reference, profileID: profileID, records: sessionCatalog.records, tasks: tasks,
                isScheduledRun: isScheduledRun) {
                openScheduledAlertTask(task)
                return
            }
            try? await sessionCatalog.load(requireAuthoritativeRefresh: true)
            switch BighelpScheduledAlertLinks.place(reference: reference, profileID: profileID,
                                                    records: sessionCatalog.records, tasks: tasks,
                                                    isScheduledRun: isScheduledRun) {
            case .chat(let record)?: openSession(record.summary)
            case .task(let task)?: openScheduledAlertTask(task)
            case .tasks(let agentID)?: openScheduledAlertTasks(agentID: agentID)
            // Tasks that couldn't load: their screen says why and offers to try again.
            case nil where isScheduledRun: openScheduledAlertTasks(agentID: profileID)
            case nil: actionErrorMessage = "This conversation is no longer on your computer."
            }
        }
    }

    /// Widgets, notifications and Shortcuts open once the host answers: its
    /// workspace is loaded and not suspended or reconnecting.
    private var acceptsIncomingLinks: Bool {
        guard !usesDemoFixtures else { return true }
        guard let hostRegistry, hostRegistry.isWorkspaceReady, hostRegistry.selectedHostID != nil,
              let nativeRuntime else { return false }
        return nativeRuntime.isReady && !nativeRuntime.isSuspended
    }

    /// Voice, a new chat and an agent's chat need a connection that can make and open a chat, never
    /// the chat list. Coming back from the background, the list held Start voice chat for seconds
    /// after the computer answered (#934).
    private var acceptsChatStarts: Bool {
        if acceptsIncomingLinks { return true }
        guard let hostRegistry, hostRegistry.isWorkspaceReady, hostRegistry.selectedHostID != nil,
              let nativeRuntime, let owner = workspaceConnections?.owner else { return false }
        return nativeRuntime.chatsOwner == owner
    }

    private func openPendingIncomingChatIfNeeded() {
        // A link that only starts a chat goes first; handling it again holds it if it came too soon.
        if !acceptsIncomingLinks, acceptsChatStarts, let url = pendingIncomingURL,
           BighelpIncomingURLRoute.parse(url)?.startsAChat == true {
            pendingIncomingURL = nil
            handleIncomingURL(url)
        }
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
        let route = AppRoute.chat(conversationID: session.id)
        let simpleBotsOpening = beginSimpleBotsChatOpening(session)
        defer { noteSimpleBotsChatOpened(simpleBotsOpening, route: route) }
        // On screen already (a notification or link about it): keep it as it is, any load it
        // has under way included, and catch up from the host.
        if appState.path.last == route, featureStore.preparedModel(for: route) != nil {
            featureStore.refreshWarmSessionState(id: session.id)
            appState.activateConversation(id: session.id, source: .sessions)
            return
        }
        sessionRestoreTask?.cancel()
        sessionRestoreTask = nil
        sessionRestoreRequest = nil
        let restoreRequest = SessionRestoreRequest(
            sessionID: session.id,
            originTab: appState.selectedTab,
            originPath: appState.path
        )
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

    /// Hermes refused a message because another Hermes process holds this chat (4090), which
    /// retrying meets again. The chat goes on in a branch with its history (`session.branch`
    /// through its last message), the branch opens, and the message is sent there.
    func continueInBranch(from model: ChatModel, _ continuation: ChatBranchContinuation) {
        let sourceID = model.conversationID
        guard let last = sessionCatalog.session(id: sourceID)?.items.last(where: {
            if case .message = $0.content { return true }
            return false
        }) else {
            model.failureMessage = "This chat is open in another Hermes process. Start a new chat to go on. Your text has been kept."
            return
        }
        Task { @MainActor in
            do {
                let branch = try await sessionCatalog.forkSession(id: sourceID, throughItemID: last.id)
                sessionCatalog.updateDraft(continuation.message, for: branch.id)
                if !continuation.hasAttachments { appState.sendsDraftOnOpen.insert(branch.id) }
                model.resolveBranchContinuation(continuation)
                let route = AppRoute.chat(conversationID: branch.id)
                guard try featureStore.prepareForUserNavigation(route) else {
                    actionErrorMessage = "This chat went on in a new chat with the same history. Find it in Sessions."
                    return
                }
                appState.activateConversation(id: branch.id, source: .fork)
            } catch {
                model.branchContinuation = nil
                model.failureMessage = "This chat is open in another Hermes process, and bighelp couldn't continue it in a new chat. Start a new chat to go on. Your text has been kept."
            }
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

    @BighelpThemeReader var theme

}

private extension BighelpIncomingURLRoute {
    /// Routes that open a chat or the agent home need the host's workspace.
    var opensWorkspaceContent: Bool {
        switch self {
        case .home, .chat, .newChat, .agentChat, .voice, .kanban, .approval, .group, .projects, .workflows, .workflow,
             .workflowRun: true
        // Today, Bots and Chats show their saved items and refresh themselves; waiting for
        // the host before even switching tabs made these links feel broken.
        case .agent, .agents, .scheduledTasks, .scheduledTask, .sessions, .settings, .usage: false
        }
    }

    /// Routes that start or open one agent's chat, and read nothing from the chat list.
    var startsAChat: Bool {
        switch self {
        case .voice, .newChat, .agentChat: true
        default: false
        }
    }
}

/// A link that waited for the computer opens once the workspace can take it. Its own modifier keeps
/// RootShellView's body small enough to type-check.
private struct PendingLinkRetry: ViewModifier {
    let acceptsLinks: Bool
    let acceptsChatStarts: Bool
    let retry: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: acceptsLinks) { _, ready in if ready { retry() } }
            .onChange(of: acceptsChatStarts) { _, ready in if ready { retry() } }
    }
}

/// Links, Handoff from the Watch (what it was showing, opened here), and
/// screens Shortcuts open. Its own modifier keeps RootShellView's body small
/// enough to type-check.
private struct IncomingLinks: ViewModifier {
    let open: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                // A loopdy:// link the system handed over: a widget, a Live Activity or a link in an alert.
                if BighelpIncomingURLRoute.parse(url) != nil { Telemetry.featureUsed(.widgetOpened) }
                open(url)
            }
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
            if registry?.selectedWorkspace?.requiresAuthentication == true, let host = registry?.selectedHost {
                Button("Sign in again") { registry?.beginAuthentication(for: host) }
                    .accessibilityIdentifier("native-workspace.sign-in-again")
            } else if status.phase != .connecting {
                Button("Reconnect", action: reconnect)
            }
        }
        .accessibilityIdentifier("native-workspace.connecting")
        .toolbar { BighelpHostsToolbarLink(registry: registry) }
    }
}
