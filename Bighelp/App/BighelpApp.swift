import AppIntents
import SwiftUI
import UserNotifications
import UIKit

@main
@MainActor
struct BighelpApp: App {
    @UIApplicationDelegateAdaptor(BighelpLinkApplicationDelegate.self)
    private var applicationDelegate

    @State private var hostRegistry: BighelpHostRegistry
    /// Every agent on every host, for the all-hosts view.
    @State private var fleet: FleetStore
    @State private var workspaceConnections: WorkspaceConnectionStore
    @State private var nativeWorkspaces: NativeWorkspaceSelectionStore
    @State private var notificationComposition: BighelpManagedNotificationComposition
    @State private var appState: AppState
    @State private var settings: SettingsStore
    @State private var companion: CompanionStore
    @State private var agentIsland = AgentIslandModel()
    @State private var userIdentity: UserIdentityStore
    @State private var agentDirectory: AgentDirectoryStore
    private let agentRuntimeDefaults: any AgentRuntimeDefaultsClient
    @State private var botModeRooms: BotModeRoomStore
    @State private var linkAccount: BighelpLinkAccountStore
    @State private var linkDevices: BighelpLinkDeviceStore
    @State private var permissionCenter: PermissionCenter
    @State private var permissionsOnboarding: PermissionsOnboardingModel
    @State private var sessionCatalog: SessionCatalogStore
    @State private var personalities: PersonalityStore
    @State private var skillsAndTools: SkillsAndToolsStore
    @State private var hermesWorkspaces: HermesWorkspaceStore
    private let projectGitClient: any ProjectGitClient
    private let optionalReferences: OptionalReferenceServices
    private let bighelpCardDataClient: any BighelpCardDataFetching
    private let cardCatalogFixtureURL: URL?
    private let cardCatalogInstalledVersions: [String: Int]
    @State private var featureStore: ShellFeatureStore
    private let subagentStreamAcceptanceFixture: SubagentStreamAcceptanceFixtureController?
    #if os(iOS) && !targetEnvironment(macCatalyst)
    private let watchRelay: WatchRelay
    #endif
    @State private var newChatCoordinator: NewChatCoordinator
    private let shortcutService: BighelpShortcutService
    @State private var reflectiveVisionCamera: ReflectiveVisionCamera
    @State private var sideMenu = BighelpSideMenu()
    @State private var providerLogoStore: ProviderLogoStore?
    #if os(visionOS)
    @State private var spatialAvatar: SpatialAvatarModel
    #endif
    private let requiresLinkAccount: Bool
    private let clearLocalCache: @MainActor () async -> Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG && targetEnvironment(simulator)
        // Reset preferences once per UI test, while retaining them across that
        // test's process relaunches. Launch-argument overrides remain intact.
        if arguments.contains("-use-demo-fixtures")
            || arguments.contains("-disable-demo-delays")
            || arguments.contains("-force-signed-out-onboarding")
            || arguments.contains("-native-workspace-acceptance") {
            if let token = ProcessInfo.processInfo.environment["BIGHELP_UI_TEST_RUN_ID"],
               UUID(uuidString: token) != nil,
               let domain = Bundle.main.bundleIdentifier {
                let defaults = UserDefaults.standard
                let marker = "loopdy.ui-tests.last-run-id"
                if defaults.string(forKey: marker) != token {
                    defaults.removePersistentDomain(forName: domain)
                    defaults.set(token, forKey: marker)
                }
            }
        }
        #endif
        let composition = BighelpAppComposition()
        #if DEBUG
        if arguments.contains("-use-demo-fixtures") {
            LinkPreviewStore.shared = LinkPreviewStore(loader: .fixture, directory: nil)
        }
        #endif
        var usesRemoteProviderLogos = !arguments.contains("-use-demo-fixtures")
            && !arguments.contains("-disable-demo-delays")
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #if DEBUG
        if arguments.contains("-enable-provider-logo-updates") {
            usesRemoteProviderLogos = true
        }
        #endif
        _providerLogoStore = State(initialValue: usesRemoteProviderLogos ? ProviderLogoStore.makeLive() : nil)
        if arguments.contains("-show-card-catalog"), arguments.contains("-use-card-catalog-fixture") {
            cardCatalogFixtureURL = Bundle.main.url(
                forResource: "card-catalog-index",
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? Bundle.main.url(forResource: "card-catalog-index", withExtension: "json")
        } else {
            cardCatalogFixtureURL = nil
        }
        if let flagIndex = arguments.firstIndex(of: "-card-catalog-installed-version"),
           arguments.indices.contains(flagIndex + 1),
           let version = Int(arguments[flagIndex + 1]) {
            cardCatalogInstalledVersions = ["weather-brief": version]
        } else {
            cardCatalogInstalledVersions = [:]
        }
        _appState = State(initialValue: composition.appState)
        _settings = State(initialValue: composition.settings)
        _companion = State(initialValue: composition.companion)
        _userIdentity = State(initialValue: composition.userIdentity)
        _agentDirectory = State(initialValue: composition.agentDirectory)
        agentRuntimeDefaults = composition.agentRuntimeDefaults
        _botModeRooms = State(initialValue: composition.botModeRooms)
        _linkAccount = State(initialValue: composition.linkAccount)
        let hostRegistry = DirectHermesApplicationFactory.makeRegistry()
        hostRegistry.restoreConnectionSelection(deviceID: composition.linkAccount.credentials?.deviceID,
            authorizationEpoch: composition.linkAccount.credentials?.authorizationEpoch)
        #if DEBUG
        if arguments.contains("-force-signed-out-onboarding") {
            hostRegistry.useIndependentWorkspace()
        }
        if !composition.requiresLinkAccount && arguments.contains("-test-no-configured-hosts") {
            hostRegistry.bind(deviceID: "fixture-account", authorizationEpoch: 1)
        }
        #endif
        let priorAccountClear = composition.linkAccount.onLocalAccountCleared
        composition.linkAccount.onLocalAccountCleared = {
            hostRegistry.bind(deviceID: nil, authorizationEpoch: nil)
            priorAccountClear()
        }
        _hostRegistry = State(initialValue: hostRegistry)
        var fleet = FleetStore(reader: RegistryFleetReader(registry: hostRegistry))
        #if DEBUG
        // Real-host UI tests add real hosts to the demo shell; they read those.
        if arguments.contains("-use-demo-fixtures"), !arguments.contains("-test-no-configured-hosts") {
            fleet = FleetStore(reader: FleetFixtureReader(), directory: FileManager.default.temporaryDirectory
                .appending(path: "bighelp-fleet-demo-\(ProcessInfo.processInfo.processIdentifier)"))
        }
        #endif
        _fleet = State(initialValue: fleet)
        let connections = WorkspaceConnectionStore(hosts: hostRegistry)
        _workspaceConnections = State(initialValue: connections)
        let nativeWorkspaces = composition.makeNativeWorkspaceSelection(connections: connections)
        _nativeWorkspaces = State(initialValue: nativeWorkspaces)
        // Demo runs without a real host use the demo stores, as the shell does.
        let usesDemoWorkspace = arguments.contains("-use-demo-fixtures") || arguments.contains("-disable-demo-delays")
        let nativeWorkspaceKey: @MainActor () -> BighelpShortcutWorkspaceKey? = {
            if usesDemoWorkspace, !connections.isDirectSelected { return nil }
            guard hostRegistry.connectionMode == .independent || connections.isDirectSelected else { return nil }
            return BighelpShortcutWorkspaceKey(
                hostID: hostRegistry.selectedHostID,
                registryGeneration: hostRegistry.generation,
                owner: connections.owner
            )
        }
        let matchesNativeWorkspaceKey: @MainActor (BighelpShortcutWorkspaceKey) -> Bool = { key in
            guard hostRegistry.connectionMode == .independent || connections.isDirectSelected,
                  hostRegistry.selectedHostID == key.hostID,
                  hostRegistry.generation == key.registryGeneration else { return false }
            guard let expectedOwner = key.owner else { return true }
            return connections.owner == expectedOwner
        }
        let resolveNativeWorkspace: @MainActor (BighelpShortcutWorkspaceKey) async throws -> BighelpShortcutWorkspace? = { key in
            guard matchesNativeWorkspaceKey(key) else {
                return nil
            }
            // A runtime suspended in the background still reports ready.
            if let runtime = nativeWorkspaces.current,
               runtime.isReady, !runtime.isSuspended,
               let owner = connections.owner,
               key.owner == nil || key.owner == owner {
                return BighelpShortcutWorkspace(runtime: runtime)
            }

            await hostRegistry.selectedWorkspace?.reconnect()
            await nativeWorkspaces.synchronize()
            guard matchesNativeWorkspaceKey(key),
                  let runtime = nativeWorkspaces.current,
                  runtime.isReady, !runtime.isSuspended,
                  connections.owner != nil else {
                return nil
            }
            return BighelpShortcutWorkspace(runtime: runtime)
        }
        // The host didn't answer: drop the dead socket and connect again.
        let reconnectHost: @MainActor () async -> Void = {
            guard let store = hostRegistry.selectedWorkspace else { return }
            await store.suspend()
            await store.reconnect()
            await nativeWorkspaces.synchronize()
        }
        composition.shortcutService.bindNativeWorkspace(
            key: nativeWorkspaceKey,
            resolve: resolveNativeWorkspace,
            reconnect: reconnectHost
        )
        composition.shortcutService.hostServices = Self.shortcutHostServices(connections: connections,
                                                                            arguments: arguments)
        AppDependencyManager.shared.add(dependency: composition.shortcutService)
        let notificationComposition = BighelpManagedNotificationComposition(
            factory: composition.managedNotificationFactory,
            registry: hostRegistry,
            account: composition.linkAccount
        )
        _notificationComposition = State(initialValue: notificationComposition)

        let priorNativeEvent = hostRegistry.onNativeEvent
        hostRegistry.onNativeEvent = { [weak nativeWorkspaces, weak notificationComposition] host, event in
            priorNativeEvent?(host, event)
            nativeWorkspaces?.receive(host: host, event: event)
            Task { @MainActor [weak notificationComposition] in
                await notificationComposition?.receiveNativeEvent(host, event)
            }
        }
        _linkDevices = State(initialValue: composition.linkDevices)
        _permissionCenter = State(initialValue: composition.permissionCenter)
        _permissionsOnboarding = State(initialValue: composition.permissionsOnboarding)
        _sessionCatalog = State(initialValue: composition.sessionCatalog)
        _personalities = State(initialValue: composition.personalities)
        _skillsAndTools = State(initialValue: composition.skillsAndTools)
        _hermesWorkspaces = State(initialValue: composition.hermesWorkspaces)
        projectGitClient = composition.projectGitClient
        optionalReferences = composition.optionalReferences
        bighelpCardDataClient = composition.bighelpCardDataClient
        _featureStore = State(initialValue: composition.featureStore)
        subagentStreamAcceptanceFixture = composition.subagentStreamAcceptanceFixture
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let watchRelay = Self.makeWatchRelay(composition, connections: connections, arguments: arguments)
        watchRelay.activate()
        self.watchRelay = watchRelay
        #endif
        #if os(iOS)
        Self.configureCarPlay(composition, arguments: arguments)
        #endif
        _newChatCoordinator = State(initialValue: composition.newChatCoordinator)
        shortcutService = composition.shortcutService
        _reflectiveVisionCamera = State(initialValue: ReflectiveVisionCamera())
        requiresLinkAccount = composition.requiresLinkAccount
        clearLocalCache = composition.clearLocalCache
        #if os(visionOS)
        _spatialAvatar = State(initialValue: Self.makeSpatialAvatar(composition, arguments: arguments))
        BighelpVisionChrome.useReadableNavigationColors()
        #endif
    }

    /// Feed, Kanban and the host's name for Shortcuts, on the host in use;
    /// demo runs use the local fixtures.
    private static func shortcutHostServices(connections: WorkspaceConnectionStore,
                                             arguments: [String]) -> BighelpShortcutHostServices {
        let usesDemo = arguments.contains("-use-demo-fixtures") || arguments.contains("-disable-demo-delays")
        let demo: @MainActor () -> Bool = { usesDemo && !connections.isDirectSelected }
        let demoBoards = DemoAgentBoardClient()
        return BighelpShortcutHostServices(
            hostName: { demo() ? "Demo host" : connections.selectedDirectHost?.name },
            hermesVersion: {
                if demo() { return "0.21.4" }
                guard let owner = connections.owner, let workspace = connections.workspace,
                      let stats = try? await workspace.perform(.systemStatus, payload: [:], owner: owner)
                else { return nil }
                return stats["hermes_version"]?.string
            },
            boards: {
                if demo() { return demoBoards }
                guard let owner = connections.owner, let workspace = connections.workspace,
                      connections.capabilities.supports(.agentBoard, owner: owner) else { return nil }
                return DirectHermesAgentBoardClient(
                    workspace: workspace, owner: owner,
                    supportsFeedback: connections.capabilities.supports(.agentBoardFeedback, owner: owner))
            },
            kanban: {
                if demo() { return DemoKanbanService.shared }
                guard let owner = connections.owner, connections.hosts.selectedWorkspace?.nativeClient != nil else {
                    return nil
                }
                return LiveKanbanService(
                    host: owner.authority,
                    currentOwner: { connections.owner },
                    makeClient: { owner in
                        connections.hosts.selectedWorkspace?.nativeClient?
                            .makeKanbanClient(owner: owner, currentOwner: { connections.owner })
                    })
            }
        )
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// The Watch talks through the same live host as Shortcuts, so it works
    /// with bighelp closed; demo runs use the local fixtures.
    private static func makeWatchRelay(_ composition: BighelpAppComposition, connections: WorkspaceConnectionStore,
                                       arguments: [String]) -> WatchRelay {
        #if DEBUG
        if arguments.contains("-use-demo-fixtures") {
            let demo = BighelpShortcutWorkspace(
                appState: composition.appState, agents: composition.agentDirectory,
                runtimeDefaults: composition.agentRuntimeDefaults, catalog: composition.sessionCatalog,
                featureStore: composition.featureStore, newChatCoordinator: composition.newChatCoordinator)
            let boards = DemoAgentBoardClient()
            return WatchRelay(workspace: { demo }, boards: { boards }, hasHost: { true }, hostKey: { "demo" })
        }
        #endif
        let shortcuts = composition.shortcutService
        return WatchRelay(
            workspace: { try await shortcuts.connectedWorkspace() },
            boards: {
                guard let owner = connections.owner, let workspace = connections.workspace,
                      connections.capabilities.supports(.agentBoard, owner: owner) else { return nil }
                return DirectHermesAgentBoardClient(
                    workspace: workspace, owner: owner,
                    supportsFeedback: connections.capabilities.supports(.agentBoardFeedback, owner: owner))
            },
            hasHost: { connections.hosts.selectedHostID != nil },
            hostKey: { WatchRelay.hostKey(for: connections.hosts.selectedHostID) }
        )
    }
    #endif

    #if os(iOS)
    /// CarPlay's voice chat talks through the same live host as Shortcuts;
    /// demo runs use the local fixtures.
    private static func configureCarPlay(_ composition: BighelpAppComposition, arguments: [String]) {
        BighelpCarPlayServices.settings = composition.settings
        #if DEBUG
        if arguments.contains("-use-demo-fixtures") {
            let demo = BighelpShortcutWorkspace(
                appState: composition.appState, agents: composition.agentDirectory,
                runtimeDefaults: composition.agentRuntimeDefaults, catalog: composition.sessionCatalog,
                featureStore: composition.featureStore, newChatCoordinator: composition.newChatCoordinator)
            BighelpCarPlayServices.workspace = { demo }
            return
        }
        #endif
        let shortcuts = composition.shortcutService
        BighelpCarPlayServices.workspace = { try await shortcuts.connectedWorkspace() }
    }
    #endif

    #if os(visionOS)
    /// The agent in the room talks through the same live host as Shortcuts;
    /// demo runs use the local fixtures.
    private static func makeSpatialAvatar(_ composition: BighelpAppComposition,
                                          arguments: [String]) -> SpatialAvatarModel {
        let shortcuts = composition.shortcutService
        #if DEBUG
        if arguments.contains("-use-demo-fixtures") {
            let demo = BighelpShortcutWorkspace(
                appState: composition.appState, agents: composition.agentDirectory,
                runtimeDefaults: composition.agentRuntimeDefaults, catalog: composition.sessionCatalog,
                featureStore: composition.featureStore, newChatCoordinator: composition.newChatCoordinator)
            return SpatialAvatarModel { demo }
        }
        #endif
        return SpatialAvatarModel { try await shortcuts.connectedWorkspace() }
    }
    #endif

    private var nativeClarificationFixtureEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures")
            && ProcessInfo.processInfo.arguments.contains("-test-native-clarification-ui")
        #else
        false
        #endif
    }

    /// The main screen for the current host (or the local fixtures).
    private func rootShell(native: NativeWorkspaceRuntime?, navigation: AppState) -> RootShellView {
        RootShellView(
            appState: navigation,
            settings: settings,
            featureStore: native?.features ?? featureStore,
            sessionCatalog: native?.sessions ?? sessionCatalog,
            agents: native?.agents ?? agentDirectory,
            agentRuntimeDefaults: native?.defaults ?? agentRuntimeDefaults,
            botModeRooms: native?.rooms ?? botModeRooms,
            linkAccount: linkAccount,
            linkDevices: linkDevices,
            permissionCenter: permissionCenter,
            permissionsOnboarding: permissionsOnboarding,
            personalities: native?.personalities ?? personalities,
            skillsAndTools: native?.skillsAndTools ?? skillsAndTools,
            hermesWorkspaces: native?.projects ?? hermesWorkspaces,
            projectGitClient: native?.projectGitClient ?? projectGitClient,
            userIdentity: userIdentity,
            newChatCoordinator: native?.newChat ?? newChatCoordinator,
            shortcutService: shortcutService,
            requiresLinkAccount: requiresLinkAccount,
            clearLocalCache: clearLocalCache,
            nativeRuntime: native,
            nativeWorkspaceError: nativeWorkspaces.errorMessage,
            agentIsland: agentIsland,
            fleet: fleet
        )
    }

    var body: some Scene {
        WindowGroup(id: SpatialAvatarSceneID.main) {
            if isInjectedUnitTestHost {
                Color.clear
            } else if isModelsPageFixture {
                #if DEBUG && targetEnvironment(simulator)
                ModelAdministrationFixture.rootView()
                #endif
            } else if isPluginUpdateFixture {
                #if DEBUG && targetEnvironment(simulator)
                HostPluginUpdateFixture.rootView()
                #endif
            } else if isSystemPageFixture {
                #if DEBUG && targetEnvironment(simulator)
                SystemPageFixture.rootView()
                #endif
            } else if isSecureInputFixture {
                #if DEBUG && targetEnvironment(simulator)
                DirectHermesSecurePromptFixture.rootView()
                #endif
            } else if BighelpLoaderGallery.isRequested {
                BighelpLoaderGallery.rootView()
            } else if isCarPlaySessionFixture {
                #if DEBUG && os(iOS) && targetEnvironment(simulator)
                CarPlaySessionFixture.rootView()
                #endif
            } else {
            @Bindable var navigation = nativeWorkspaces.current?.appState ?? appState
            let native = nativeWorkspaces.current
            let notificationContext = notificationComposition.integration.map { integration in
                let generation = hostRegistry.generation
                return BighelpNotificationContext.make(
                    service: integration.service,
                    isCurrent: {
                        !Task.isCancelled
                            && notificationComposition.owns(
                                integration,
                                registryGeneration: generation
                            )
                    }
                )
            }
            Group {
                if nativeClarificationFixtureEnabled {
                    #if DEBUG
                    NativeClarificationAcceptanceFixtureView()
                    #endif
                } else if let cardCatalogFixtureURL {
                    BighelpCardCatalogView.fixture(
                        indexURL: cardCatalogFixtureURL,
                        cacheURL: FileManager.default.temporaryDirectory.appending(
                            path: "loopdy-card-catalog-fixture-cache.json"
                        ),
                        installedVersions: cardCatalogInstalledVersions
                    )
                } else {
                    NavigationStack(path: $navigation.path) {
                        rootShell(native: native, navigation: navigation)
                    }
                    .modifier(BighelpSideMenuHost(menu: sideMenu))
                    // Around the Dynamic Island: which agent is working, on what.
                    .environment(\.agentActivityInIsland, agentIsland.isAvailable)
                    .overlay(alignment: .top) { AgentActivityIslandLayer(model: agentIsland) }
                    // Reconnecting after time away, shown without closing what's open.
                    .overlay { ConnectionIslandLayer().allowsHitTesting(false) }
                    .modifier(VoiceLaunchCoverOverlay())
                    .statusBarHidden(agentIsland.hidesStatusBar)
                    .animation(.snappy, value: agentIsland.hidesStatusBar)
                }
            }
            .environment(\.bighelpHostRegistry, hostRegistry)
            .environment(\.workspaceConnections, workspaceConnections)
            .environment(\.bighelpNotificationContext, notificationContext)
            .task(id: nativeWorkspaces.synchronizationKey) {
                await nativeWorkspaces.synchronize()
            }
            .environment(\.managedNotificationService, notificationComposition.service)
            .task(id: notificationComposition.revision.description + ":" + hostRegistry.generation.uuidString + ":" + String(scenePhase == .active)) {
                guard scenePhase == .active, notificationComposition.integration != nil else { return }
                let generation = hostRegistry.generation
                await notificationComposition.recoverForeground {
                    !Task.isCancelled && scenePhase == .active
                        && hostRegistry.generation == generation
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.protectedDataDidBecomeAvailableNotification
            )) { _ in
                _ = notificationComposition.retryAfterProtectedDataBecomesAvailable()
            }
            .environment(\.directHermesWorkspace, hostRegistry.selectedWorkspace)
            .onChange(of: linkAccount.credentials, initial: true) { _, credentials in
                #if DEBUG
                if !requiresLinkAccount && ProcessInfo.processInfo.arguments.contains("-test-no-configured-hosts") { return }
                #endif
                hostRegistry.bind(deviceID: credentials?.deviceID, authorizationEpoch: credentials?.authorizationEpoch)
            }
            .environment(\.bighelpUIV2Enabled, settings.uiV2Enabled)
            .environment(\.bighelpUIV3Enabled, settings.interfaceVersion == .v3)
            .environment(\.nerdModeEnabled, settings.nerdModeEnabled)
            .modifier(BighelpTextSizing())
            #if os(visionOS)
            .modifier(SpatialAvatarMainWindowHooks(model: spatialAvatar))
            // No app-wide tint here: visionOS would fill every toolbar button with it.
            .modifier(BighelpVisionInk())
            #else
            // Lavender (asset AccentColor, light/dark) for every control that
            // doesn't set its own tint, including switches that default to green.
            .tint(Color.accentColor)
            .modifier(BighelpMacWindowStyle(sideMenu: sideMenu))
            #endif
            .environment(\.companionStore, companion)
            .environment(\.providerLogoStore, providerLogoStore)
            .environment(\.companionAgentScope, companionAgentScope)
            .environment(\.bighelpCardDataClient, usesFixtureWorkspace
                ? bighelpCardDataClient : BighelpCardStaticDataClient() as any BighelpCardDataFetching)
            .onChange(of: navigation.activeConversationID) { _, _ in
                (native?.features ?? featureStore).invalidateLiveVoice()
            }
            .environment(
                \.appAppearance,
                settings.appearanceContext
            )
            .environment(\.reflectiveVisionEnabled, settings.reflectiveVisionEnabled)
            .environment(\.reflectiveVisionCamera, reflectiveVisionCamera)
            .environment(\.subagentStreamAcceptanceFixture, subagentStreamAcceptanceFixture)
            .preferredColorScheme(settings.appearance.preferredColorScheme)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                // Opening bighelp is "I've seen it": the icon badge goes away.
                await BighelpAppBadge.clear()
                await providerLogoStore?.refreshIfNeeded()
            }
            .task(id: settings.reflectiveVisionEnabled) {
                await BighelpProactiveNotificationOpenCenter.shared.activate()
                await reflectiveVisionCamera.update(enabled: settings.reflectiveVisionEnabled)
            }
            .onChange(of: permissionCenter.status(for: .camera).authorization) { _, status in
                guard status == .authorized, settings.reflectiveVisionEnabled else { return }
                Task { await reflectiveVisionCamera.update(enabled: true) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    _ = notificationComposition.retryAfterForeground()
                }
                #if DEBUG && targetEnvironment(simulator)
                // "-test-badge-on-background 3": stand in for a push that badges the icon.
                let arguments = ProcessInfo.processInfo.arguments
                if phase == .background, !BighelpTestBadge.applied,
                   let index = arguments.firstIndex(of: "-test-badge-on-background"),
                   arguments.indices.contains(index + 1), let count = Int(arguments[index + 1]) {
                    BighelpTestBadge.applied = true
                    let task = UIApplication.shared.beginBackgroundTask(withName: "test badge")
                    Task { @MainActor in
                        try? await UNUserNotificationCenter.current().setBadgeCount(count)
                        UIApplication.shared.endBackgroundTask(task)
                    }
                }
                #endif
                if requiresLinkAccount, phase == .background {
                    (native?.features ?? featureStore).flushChatPersistence()
                    // Keep the workspace through a quick trip away; mark the
                    // presentation boundary only if the app stays away.
                    BighelpBackgroundGrace.shared.begin("workspace") { [nativeWorkspaces] in
                        nativeWorkspaces.suspend()
                    }
                }
                if phase == .active { BighelpBackgroundGrace.shared.cancel() }
                #if os(iOS) && !targetEnvironment(macCatalyst)
                if phase == .active { Task { await BighelpActivityKitDriver.dismissFinishedActivities() } }
                #endif
                Task { @MainActor in
                    // A newer scene transition may have arrived before this task starts.
                    guard scenePhase == phase else { return }
                    if phase == .active {
                        if !usesFixtureWorkspace {
                            await nativeWorkspaces.refreshCurrentRuntimeForForeground()
                            guard scenePhase == .active, !usesFixtureWorkspace else { return }
                            await permissionCenter.refresh()
                            await reflectiveVisionCamera.update(enabled: settings.reflectiveVisionEnabled)
                            return
                        }
                        await featureStore.dashboardModel.refreshAfterExternalChange()
                        await permissionCenter.refresh()
                        await reflectiveVisionCamera.update(
                            enabled: settings.reflectiveVisionEnabled
                        )
                    } else {
                        (native?.features ?? featureStore).flushChatPersistence()
                        reflectiveVisionCamera.suspend()
                    }
                }
            }
            }
        }
        .commands { BighelpMenuCommands() }
        #if os(visionOS)
        // bighelp always starts in its own window; simple mode is a choice.
        .defaultLaunchBehavior(.presented)
        #endif
        #if os(visionOS)
        SpatialAvatarScenes(model: spatialAvatar, settings: settings, companion: companion,
                            companionAgentScope: companionAgentScope, permissionCenter: permissionCenter)
        KanbanWindowScene(settings: settings, companion: companion, companionAgentScope: companionAgentScope)
        #endif
    }

    private var isModelsPageFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains(ModelAdministrationFixture.launchArgument)
        #else
        false
        #endif
    }

    private var isPluginUpdateFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains(HostPluginUpdateFixture.launchArgument)
        #else
        false
        #endif
    }

    private var isSystemPageFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains(SystemPageFixture.launchArgument)
        #else
        false
        #endif
    }

    private var isSecureInputFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains(DirectHermesSecurePromptFixture.launchArgument)
        #else
        false
        #endif
    }

    private var isCarPlaySessionFixture: Bool {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains(CarPlaySessionFixture.launchArgument)
        #else
        false
        #endif
    }

    private var isInjectedUnitTestHost: Bool {
        #if DEBUG
        // Hosted unit tests exercise their own stores. Starting a saved real
        // host's UI and network lifecycle here makes those tests operate on
        // unrelated user data and contaminates main-actor latency measurements.
        // UI tests launch a separate, uninjected application process.
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }

    private var usesFixtureWorkspace: Bool {
        // Only synthetic previews use the fixture feature graph. Production
        // chat is selected from the independently authenticated host registry.
        !requiresLinkAccount && hostRegistry.selectedHostID == nil
    }

    private var companionAgentScope: String {
        if let credentials = linkAccount.credentials, let host = hostRegistry.selectedHost {
            return CompanionSurfaceScope.accountHost(deviceID: credentials.deviceID,
                authorizationEpoch: credentials.authorizationEpoch, hostID: host.hostConnectionID)
        }
        #if DEBUG
        if !requiresLinkAccount { return "fixture-account:fixture-host" }
        #endif
        guard let credentials = linkAccount.credentials,
              let hostID = linkDevices.selectedHostID else { return "" }
        return CompanionSurfaceScope.accountHost(
            deviceID: credentials.deviceID,
            authorizationEpoch: credentials.authorizationEpoch,
            hostID: hostID
        )
    }

}

private extension AppAppearance {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// UI tests badge the icon once, on the first trip to the background.
@MainActor
enum BighelpTestBadge {
    static var applied = false
}
#endif
