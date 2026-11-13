import PhotosUI
import SwiftUI
import UIKit
import WatchConnectivity

@MainActor
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var userIdentity: UserIdentityStore
    let agents: [AgentProfile]
    let personalities: PersonalityStore
    let permissionCenter: PermissionCenter
    let onOpenSessions: () -> Void
    let onOpenScheduledTasks: () -> Void
    let onClearLocalCache: @MainActor () async -> Bool
    let agentDirectory: AgentDirectoryStore?

    let voiceSettingsScope: String?
    let voiceSettingsClient: (any VoiceSettingsClient)?
    let voiceSettingsIsCurrent: @MainActor () -> Bool
    let notificationScope: String?
    let notificationPreferencesClient: BighelpBuzzKitPreferencesClient
    let notificationRuntimeSource: @MainActor () -> BighelpNotificationRuntimeSnapshot
    let refreshNotificationRuntime: (@MainActor () async throws -> BighelpNotificationRuntimeSnapshot)?
    let notificationIsCurrent: @MainActor () -> Bool
    /// Opens a native Hermes administration page (models, providers, files, ...).
    var onOpenWorkspaceDestination: ((WorkspaceDestination) -> Void)?
    /// Opens another app route (Hermes tools hub, activity, direct links, ...).
    var onOpenRoute: ((AppRoute) -> Void)?
    /// Connections › Native App Connections for the computer in use (demo mode: made-up apps); nil hides it.
    var connectorApps: (@MainActor () -> ConnectorAppsModel?)?
    /// Connections › Composio Apps (one Composio sign-in for every computer); nil hides it.
    var composioApps: (@MainActor () -> ComposioAppsModel?)?
    /// Marketplace for the bot in use, on Apps & skills.
    var marketplace: (@MainActor () -> MarketplaceContext)?
    /// Connections › Secure credential vault: nil hides the row (no computer chosen), and nil from
    /// the closure means the computer isn't connected right now.
    var credentialVault: (@MainActor () -> CredentialVaultModel?)?
    @State private var openVault: CredentialVaultModel?
    @State private var vaultNeedsComputer = false
    /// Settings › Teamwork for the computer in use; nil hides the row.
    var teamwork: (@MainActor () -> TeamworkModel?)?
    /// Every computer: Show every computer and Update every computer; nil hides them.
    var fleet: SettingsFleetAccess?
    /// The first group's Usage row (the tightest plan's percent); nil hides it.
    var usage: ProviderUsageStore?
    /// Shares from other apps waiting to be sent (`PendingShareListView`); its row shows while any wait.
    var pendingShares: PendingShareReviewContext?
    /// Settings › Chat › Archived chats; nil hides the row.
    var archivedChats: SettingsArchivedChats?
    /// Your computers › Time zone, for the computer in use; nil (or nil from it) has no row to change.
    var computerTimeZone: (@MainActor () -> SimpleBotHostSettings?)?

    @State var teamworkModel: TeamworkModel?
    /// The computer `teamworkModel` was made for (`cacheScopeID`).
    @State var teamworkScope: String?

    /// Shows just this pushed page (the Settings sheet's stack pushes `SettingsDestination` values).
    private var pushedPage: SettingsDestination?
    /// The Settings sheet's stack takes value links; the main stack, typed `[AppRoute]`, ignores
    /// them, so there the rows push the page itself (`settingsLink`). Set with `withDone`: only
    /// the sheet has a Done.
    private var pushesByValue = false
    @Environment(\.bighelpNotificationContext) private var notificationContext
    /// Held in state so the computer rows redraw when the check finishes; the shared
    /// per-host models live in a plain dictionary SwiftUI can't observe.
    @State private var hostPluginUpdate: HostPluginUpdateModel?
    @State var photoSelection: PhotosPickerItem?
    @State var avatarError: String?
    @FocusState var isDisplayNameFocused: Bool
    @State var displayNameDraft: String
    @State var displayNameBaseline: String
    @State var isImportingAvatar = false
    @State var nameSaveStatus: String?
    @State var isPersonalitiesPresented = false
    @Environment(\.bighelpHostRegistry) var hostRegistry
    @Environment(\.bighelpScreen) var screen
    @State var isClearCacheConfirmationPresented = false
    @State var isClearingLocalCache = false
    @State var localCacheStatusMessage: String?
    @Environment(\.reflectiveVisionCamera) var reflectiveVisionCamera
    @Environment(\.companionStore) var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope

    /// In the Settings sheet: Done on its pages too, beside Back. Done closes Settings.
    private(set) var onDone: (() -> Void)?

    /// Settings as a sheet, with Done on its pages.
    func withDone(_ action: @escaping () -> Void) -> SettingsView {
        var copy = self
        copy.onDone = action
        copy.pushesByValue = true
        return copy
    }

    /// Done on a page pushed inside the sheet: pushed pages don't get the sheet's own toolbar.
    func settingsDone<Page: View>(_ page: Page) -> some View {
        page.toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
    }

    init(
        settings: SettingsStore,
        userIdentity: UserIdentityStore = UserIdentityStore(),
        agents: [AgentProfile] = [],
        personalities: PersonalityStore = PersonalityStore(client: FixturePersonalityClient()),
        permissionCenter: PermissionCenter = PermissionCenter(),
        onOpenSessions: @escaping () -> Void = {},
        onOpenScheduledTasks: @escaping () -> Void = {},
        onClearLocalCache: @escaping @MainActor () async -> Bool = { true },
        voiceSettingsScope: String? = nil,
        voiceSettingsClient: (any VoiceSettingsClient)? = nil,
        voiceSettingsIsCurrent: @escaping @MainActor () -> Bool = { false },
        notificationScope: String? = nil,
        notificationPreferencesClient: BighelpBuzzKitPreferencesClient = BighelpBuzzKitPreferencesClient(),
        notificationRuntimeSource: @escaping @MainActor () -> BighelpNotificationRuntimeSnapshot = {
            .current
        },
        refreshNotificationRuntime: (@MainActor () async throws -> BighelpNotificationRuntimeSnapshot)? = nil,
        registerNotificationDevice _: (@MainActor () async throws -> BighelpNotificationRuntimeSnapshot)? = nil,
        notificationIsCurrent: @escaping @MainActor () -> Bool = { false },
        agentDirectory: AgentDirectoryStore? = nil,

        onOpenWorkspaceDestination: ((WorkspaceDestination) -> Void)? = nil,
        onOpenRoute: ((AppRoute) -> Void)? = nil,
        connectorApps: (@MainActor () -> ConnectorAppsModel?)? = nil,
        composioApps: (@MainActor () -> ComposioAppsModel?)? = nil,
        marketplace: (@MainActor () -> MarketplaceContext)? = nil,
        credentialVault: (@MainActor () -> CredentialVaultModel?)? = nil,
        teamwork: (@MainActor () -> TeamworkModel?)? = nil,
        fleet: SettingsFleetAccess? = nil,
        usage: ProviderUsageStore? = nil,
        pendingShares: PendingShareReviewContext? = nil,
        archivedChats: SettingsArchivedChats? = nil,
        computerTimeZone: (@MainActor () -> SimpleBotHostSettings?)? = nil
    ) {
        self.onOpenWorkspaceDestination = onOpenWorkspaceDestination
        self.onOpenRoute = onOpenRoute
        self.connectorApps = connectorApps
        self.composioApps = composioApps
        self.marketplace = marketplace
        self.credentialVault = credentialVault
        self.teamwork = teamwork
        self.fleet = fleet
        self.usage = usage
        self.pendingShares = pendingShares
        self.archivedChats = archivedChats
        self.computerTimeZone = computerTimeZone

        _settings = Bindable(wrappedValue: settings)
        _userIdentity = Bindable(wrappedValue: userIdentity)
        _displayNameDraft = State(initialValue: userIdentity.identity.name)
        _displayNameBaseline = State(initialValue: userIdentity.identity.name)
        self.agents = agents
        self.personalities = personalities
        self.permissionCenter = permissionCenter
        self.onOpenSessions = onOpenSessions
        self.onOpenScheduledTasks = onOpenScheduledTasks
        self.onClearLocalCache = onClearLocalCache
        self.agentDirectory = agentDirectory

        self.voiceSettingsScope = voiceSettingsScope
        self.voiceSettingsClient = voiceSettingsClient
        self.voiceSettingsIsCurrent = voiceSettingsIsCurrent
        self.notificationScope = notificationScope
        self.notificationPreferencesClient = notificationPreferencesClient
        self.notificationRuntimeSource = notificationRuntimeSource
        self.refreshNotificationRuntime = refreshNotificationRuntime
        self.notificationIsCurrent = notificationIsCurrent
    }

    var body: some View {
        Group {
            if let pushedPage { settingsDone(page(for: pushedPage)) }
            else { menuPage }
        }
    }

    /// This pushed page alone, for the Settings sheet's `navigationDestination`. Built in `body`, so
    /// the page reads the theme live.
    func showing(_ destination: SettingsDestination) -> Self {
        var page = self
        page.pushedPage = destination
        return page
    }

    /// A row that opens one Settings page: pushed by value in the sheet, so `AppState.openSettings`
    /// can reach it, and as the page itself in the main stack. The page is type-erased: the menu
    /// is one of the pages, and an opaque type can't contain itself.
    @ViewBuilder
    func settingsLink<Label: View>(to destination: SettingsDestination,
                                   @ViewBuilder label: () -> Label) -> some View {
        if pushesByValue {
            NavigationLink(value: destination, label: label)
        } else {
            NavigationLink {
                AnyView(settingsDone(page(for: destination)))
            } label: {
                label()
            }
        }
    }

    /// What each `SettingsDestination` draws, without its Done.
    @ViewBuilder
    private func page(for destination: SettingsDestination) -> some View {
        switch destination {
        case .section(let section): self.destination(for: section)
        case .you: settingsPage(title: String(localized: "You")) { localIdentity }
        case .chatLayout: ChatLayoutSettingsView()

        case .thinking: ThinkingLookSettingsView()
        case .apps: connectionsPage
        case .connection: connectionPage
        }
    }

    /// Settings › Apps & skills (`SettingsDestination.apps`): what this device lets bots use, the apps
    /// they can use, and the vault of logins their browser can use. One page for all of it.
    private var connectionsPage: some View {
        AppsHubView(native: connectorApps?() ?? nil, composio: composioApps?() ?? nil,
                    onOpenVault: credentialVault.map { make in
                        {
                            openVault = make()
                            vaultNeedsComputer = openVault == nil
                        }
                    },
                    vaultNeedsComputer: vaultNeedsComputer, marketplace: marketplace) {
            settingsLink(to: .section(.permissions)) {
                DeviceAccessRowLabel()
                    .bighelpSettingsLinkLabel()
            }
            .bighelpSettingsLink()
            .accessibilityIdentifier("settings.connections.device-access")
            .driveTarget("settings.connections.device-access")
        }
        .modifier(CredentialVaultSheet(model: $openVault))
    }

    private var menuPage: some View {
        // Each section is deferred and type-erased: inlined together they overflow
        // the device's main-thread stack in Release builds (see BighelpDeferredSection).
        // One Settings in every mode. Every row opens one page, so the first screen stays a short
        // list: you, your bots and what they use, this app, your computers, then help.
        Form {
            BighelpDeferredSection { youSection }
            BighelpDeferredSection { yourBotsSection }
            BighelpDeferredSection {
                settingsMenuGroup(header: String(localized: "This app"),
                                  sections: [.appearance, .chat, .notifications])
            }
            #if os(visionOS)
            BighelpDeferredSection { SpatialAvatarSettingsSection(settings: settings) }
            #endif
            BighelpDeferredSection { computersSection }
            BighelpDeferredSection { helpAndAdvancedSection }
        }
        .animation(.snappy(duration: BighelpTokens.transitionDuration), value: settings.nerdModeEnabled)
        .animation(.snappy(duration: BighelpTokens.transitionDuration), value: settings.showsEveryComputer)
        .bighelpFormSurface()
        .listSectionSpacing(20)
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Settings")
        .bighelpSheet(isPresented: $isPersonalitiesPresented) {
            NavigationStack {
                PersonalitiesView(store: personalities)
            }
            .bighelpSheetSize(.standard)
            .presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("settings.screen")
        // An agent's drive points at rows low on this page (Add a computer).
        .driveScrolls()
        .task(id: selectedHostPluginCheckKey) {
            // One quiet check per host per app session, once it's connected.
            guard hostRegistry?.selectedWorkspace?.isConnected == true,
                  let hostRegistry, let hostID = hostRegistry.selectedHostID else { return }
            let model = HostPluginUpdateModel.model(for: hostID, registry: hostRegistry)
            hostPluginUpdate = model
            await model.checkIfNeeded()
        }
    }

    private var currentConnection: some View {
        Section {
            if let hostRegistry, let workspace = hostRegistry.selectedWorkspace, let saved = workspace.savedConnection {
                LabeledContent("Address", value: saved.endpoint.identity)
                LabeledContent("Sign-in", value: authenticationTitle(saved.authentication))
                Text(workspace.status)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.connection.status")
            } else { Text("No computer is connected.").foregroundStyle(.secondary) }
        } header: {
            Text("This computer")
        } footer: {
            Text("Sign-ins stay in this device's Keychain.")
        }
    }

    /// Connection details: the computer in use's address and sign-in, and which plugin features
    /// each part of the app found. Its computer's page links it with Advanced options on.
    private var connectionPage: some View {
        settingsPage(title: String(localized: "Connection details")) {
            currentConnection
            BighelpPluginCapabilitiesSection(connections: workspaceConnections,
                                             permissionCenter: permissionCenter,
                                             showsPluginSummary: false)
        }
    }

    /// Settings › Help & feedback: where to ask and read, the switch for sharing usage and crash
    /// reports, then this device's Apple Watch and the app's version.
    private var helpPage: some View {
        settingsPage(title: SettingsMenuSection.help.title) {
            helpAndFeedback
            TelemetrySettingsSection()
            aboutThisDevice
            signatureSection
        }
        .accessibilityIdentifier("settings.help")
    }

    private var signatureSection: some View {
        Section {} footer: { BighelpBunnySignature() }
    }

    private var helpAndFeedback: some View {
        Section {
            Link("Report a problem", destination: URL(string: "https://github.com/promptclickrun/bighelp/issues")!)
            Link("Documentation", destination: URL(string: "https://hermes-agent.nousresearch.com/docs")!)
        } header: {
            Text("Help")
        }
    }

    /// The Watch's state in one row where a Watch can pair, then the version.
    private var aboutThisDevice: some View {
        Section {
            #if !targetEnvironment(macCatalyst) // Only an iPhone pairs with an Apple Watch.
            if WCSession.isSupported() {
                LabeledContent("Apple Watch", value: watchStatus)
                    .accessibilityIdentifier("settings.help.apple-watch")
            }
            #endif
            #if targetEnvironment(macCatalyst)
            BighelpMacUpdatesRow()
            #else
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            #endif
        } header: {
            Text("This device")
        }
    }

    /// "Not paired", "App not installed", "Connected" or "Not reachable".
    private var watchStatus: String {
        let session = WCSession.default
        if !session.isPaired { return String(localized: "Not paired") }
        if !session.isWatchAppInstalled { return String(localized: "App not installed") }
        return session.isReachable ? String(localized: "Connected") : String(localized: "Not reachable")
    }

    private func authenticationTitle(_ authentication: DirectHermesStoredAuthentication) -> String {
        switch authentication {
        case .dashboardSession(_, let automatic):
            automatic ? String(localized: "No sign-in") : String(localized: "Session token")
        case .bearer: String(localized: "Account on this computer")
        case .legacyLoopbackToken: String(localized: "Session token")
        }
    }

    /// "Ink bubbles · Paper · Black"
    var appearanceSummary: String {
        String(localized: "\(settings.bubbleColorName) bubbles · \(settings.lightBackground.name) · \(settings.darkBackground.name)")
    }

    private var selectedHostPluginCheckKey: String {
        "\(hostRegistry?.selectedHostID?.uuidString ?? "none"):\(hostRegistry?.selectedWorkspace?.isConnected == true)"
    }

    @ViewBuilder
    func destination(for section: SettingsMenuSection) -> some View {
        switch section {

        case .chat:
            chatPage
        case .voice:
            VoiceSettingsView(settings: settings, agents: agents,
                              selectedAgentID: agentDirectory?.selectedAgentID,
                              client: voiceSettingsClient, scope: voiceSettingsScope,
                              isCurrent: voiceSettingsIsCurrent)
        case .companion:
            if let companionStore {
                CompanionSettingsView(store: companionStore)
            }
        case .appearance:
            appearancePage
        case .notifications:
            BighelpNotificationSettingsView(
                permissionCenter: permissionCenter,
                hostRegistry: hostRegistry,
                scope: notificationContext?.scope ?? notificationScope,
                preferencesClient: notificationPreferencesClient,
                runtimeSource: notificationRuntimeSource,
                refreshRuntime: notificationContext?.refresh ?? refreshNotificationRuntime,
                sendTest: notificationContext?.test,
                turnOff: notificationTurnOff,
                quietHoursSync: notificationQuietHoursSync,
                channelAlertsSync: notificationChannelAlertsSync,
                isCurrent: notificationContext?.isCurrent ?? notificationIsCurrent
            )
        case .permissions:
            PermissionsSettingsView(center: permissionCenter)
        case .help:
            helpPage
        }
    }

    private var notificationQuietHoursSync: BighelpQuietHoursSync? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures") ? .demo : nil
        #else
        nil
        #endif
    }

    private var notificationChannelAlertsSync: BighelpChannelAlertsSync? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures") ? .demo : nil
        #else
        nil
        #endif
    }

    private var notificationTurnOff: BighelpNotificationTurnOff? {
        #if DEBUG
        notificationContext?.turnOff ?? BighelpNotificationTurnOff.demoShared
        #else
        notificationContext?.turnOff
        #endif
    }

    func settingsPage<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .driveScrolls()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A row's title alone. Its second line, when it has one, is the control's own value.
    func settingTitle(_ title: String) -> some View {
        Text(title)
            .bighelpFont(.body)
            .foregroundStyle(theme.primaryText)
    }

    /// A row's title with a hint under it, for the few rows whose title can't carry it: six words at most.
    func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(title)
                .bighelpFont(.body)
                .foregroundStyle(theme.primaryText)
            Text(detail)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, BighelpTokens.space4)
    }

    @BighelpThemeReader var theme

    @Environment(\.workspaceConnections) var workspaceConnections
}

#Preview("Settings") {
    NavigationStack {
        SettingsView(settings: SettingsStore())
    }
}

#Preview("Settings - Accessibility Extra Large") {
    NavigationStack {
        SettingsView(settings: SettingsStore())
    }
    .dynamicTypeSize(.accessibility3)
}

/// A computer's page confirms Clear local cache before it runs.
struct ClearCacheConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let onConfirm: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.alert("Clear local cache?", isPresented: $isPresented) {
            Button("Clear and refresh", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("bighelp keeps your sign-in and preferences, clears what it saved from this computer, then downloads your bots and chats again.")
        }
    }
}

/// The wordmark under Help & feedback. Tap it three times and the b does a shadow-puppet
/// bunny (the kit's easter egg).
private struct BighelpBunnySignature: View {
    @State private var taps = 0
    @State private var motion: BighelpNoodleMotion?

    var body: some View {
        BighelpWordmark(height: 24, motion: motion) { motion = nil }
            .frame(maxWidth: .infinity)
            .padding(.top, BighelpTokens.space24)
            .contentShape(.rect)
            .onTapGesture {
                taps += 1
                guard taps >= 3 else { return }
                taps = 0
                motion = .bunny
            }
            .accessibilityIdentifier("settings.signature")
    }
}
