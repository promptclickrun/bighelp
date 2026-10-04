import PhotosUI
import SwiftUI
import UIKit
import WatchConnectivity

@MainActor
struct SettingsView: View {
    let focusedDestination: WorkspaceDestination?
    @Bindable var settings: SettingsStore
    @Bindable var userIdentity: UserIdentityStore
    let agents: [AgentProfile]
    let personalities: PersonalityStore
    let permissionCenter: PermissionCenter
    let onOpenSessions: () -> Void
    let onOpenScheduledTasks: () -> Void
    let onClearLocalCache: @MainActor () async -> Bool
    let hostRuntime: HostRuntimeStore?
    let agentDirectory: AgentDirectoryStore?
    /// The computer Start with is kept for (`cacheScopeID`).
    let landingScope: String?
    let voiceSettingsScope: String?
    let voiceSettingsClient: (any VoiceSettingsClient)?
    let voiceSettingsIsCurrent: @MainActor () -> Bool
    let pluginUpdateScope: String?
    let pluginUpdateClient: (any PluginUpdateClient)?
    let pluginUpdateIsCurrent: @MainActor () -> Bool
    let notificationScope: String?
    let notificationPreferencesClient: BighelpBuzzKitPreferencesClient
    let notificationRuntimeSource: @MainActor () -> BighelpNotificationRuntimeSnapshot
    let refreshNotificationRuntime: (@MainActor () async throws -> BighelpNotificationRuntimeSnapshot)?
    let notificationIsCurrent: @MainActor () -> Bool
    /// Opens a native Hermes administration page (models, providers, files, ...).
    var onOpenWorkspaceDestination: ((WorkspaceDestination) -> Void)?
    /// Opens another app route (Hermes tools hub, activity, direct links, ...).
    var onOpenRoute: ((AppRoute) -> Void)?
    /// Shows just this page (Fleet settings links Appearance and Chat here, so there's one copy of each).
    private var openSection: SettingsMenuSection?
    @Environment(\.bighelpNotificationContext) private var notificationContext
    @State private var pluginUpdates: PluginUpdateStore?
    /// Held in state so this screen redraws when the check finishes; the shared
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
    @State var isClearCacheConfirmationPresented = false
    @State var isClearingLocalCache = false
    @State var localCacheStatusMessage: String?
    @Environment(\.reflectiveVisionCamera) var reflectiveVisionCamera
    @Environment(\.companionStore) private var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope

    init(
        settings: SettingsStore,
        focusedDestination: WorkspaceDestination? = nil,
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
        pluginUpdateScope: String? = nil,
        pluginUpdateClient: (any PluginUpdateClient)? = nil,
        pluginUpdateIsCurrent: @escaping @MainActor () -> Bool = { false },
        notificationScope: String? = nil,
        notificationPreferencesClient: BighelpBuzzKitPreferencesClient = BighelpBuzzKitPreferencesClient(),
        notificationRuntimeSource: @escaping @MainActor () -> BighelpNotificationRuntimeSnapshot = {
            .current
        },
        refreshNotificationRuntime: (@MainActor () async throws -> BighelpNotificationRuntimeSnapshot)? = nil,
        registerNotificationDevice _: (@MainActor () async throws -> BighelpNotificationRuntimeSnapshot)? = nil,
        notificationIsCurrent: @escaping @MainActor () -> Bool = { false },
        hostRuntime: HostRuntimeStore? = nil,
        agentDirectory: AgentDirectoryStore? = nil,
        landingScope: String? = nil,
        onOpenWorkspaceDestination: ((WorkspaceDestination) -> Void)? = nil,
        onOpenRoute: ((AppRoute) -> Void)? = nil
    ) {
        self.onOpenWorkspaceDestination = onOpenWorkspaceDestination
        self.onOpenRoute = onOpenRoute
        self.focusedDestination = focusedDestination
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
        self.hostRuntime = hostRuntime
        self.agentDirectory = agentDirectory
        self.landingScope = landingScope
        self.voiceSettingsScope = voiceSettingsScope
        self.voiceSettingsClient = voiceSettingsClient
        self.voiceSettingsIsCurrent = voiceSettingsIsCurrent
        self.pluginUpdateScope = pluginUpdateScope
        self.pluginUpdateClient = pluginUpdateClient
        self.pluginUpdateIsCurrent = pluginUpdateIsCurrent
        self.notificationScope = notificationScope
        self.notificationPreferencesClient = notificationPreferencesClient
        self.notificationRuntimeSource = notificationRuntimeSource
        self.refreshNotificationRuntime = refreshNotificationRuntime
        self.notificationIsCurrent = notificationIsCurrent
    }

    var body: some View {
        Group {
            if let openSection { destination(for: openSection) }
            else if let focusedDestination { focusedPage(focusedDestination) }
            else { menuPage }
        }
    }

    /// This settings page alone.
    func opening(_ section: SettingsMenuSection) -> Self {
        var page = self
        page.openSection = section
        return page
    }

    private var menuPage: some View {
        // Each section is deferred and type-erased: inlined together they overflow
        // the device's main-thread stack in Release builds (see BighelpDeferredSection).
        // Every row opens one page, so the first screen stays a short list.
        Form {
            BighelpDeferredSection { localIdentity }
            BighelpDeferredSection { assistantBasics }
            BighelpDeferredSection {
                settingsMenuGroup(sections: [.appearance, .chat, .voice, .notifications])
            }
            #if os(visionOS)
            BighelpDeferredSection { SpatialAvatarSettingsSection(settings: settings) }
            #endif
            BighelpDeferredSection {
                settingsMenuGroup(sections: [.connectivityAndNotifications, .permissions] + Self.watchSection
                                  + (companionStore == nil ? [] : [.companion]) + [.help])
            }
            BighelpDeferredSection { nerdModeToggle }
            if settings.nerdModeEnabled {
                BighelpDeferredSection { hermesSection }
            }
        }
        .animation(.snappy(duration: BighelpTokens.transitionDuration), value: settings.nerdModeEnabled)
        .bighelpFormSurface()
        .listSectionSpacing(20)
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Settings")
        .sheet(isPresented: $isPersonalitiesPresented) {
            NavigationStack {
                PersonalitiesView(store: personalities)
            }
            .bighelpSheetSize(.standard)
            .presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("settings.screen")
        .task(id: pluginUpdateScope) {
            pluginUpdates?.invalidate()
            guard let scope = pluginUpdateScope, let client = pluginUpdateClient else {
                pluginUpdates = nil
                return
            }
            let store = PluginUpdateStore(scope: scope, client: client, isCurrent: pluginUpdateIsCurrent)
            pluginUpdates = store
            await store.refreshStatus()
        }
        .task(id: selectedHostPluginCheckKey) {
            // One quiet check per host per app session, once it's connected.
            guard hostRegistry?.selectedWorkspace?.isConnected == true,
                  let hostRegistry, let hostID = hostRegistry.selectedHostID else { return }
            let model = HostPluginUpdateModel.model(for: hostID, registry: hostRegistry)
            hostPluginUpdate = model
            await model.checkIfNeeded()
        }
    }

    @ViewBuilder
    private func focusedPage(_ destination: WorkspaceDestination) -> some View {
        if destination == .appearance {
            appearancePage
                .accessibilityIdentifier("settings.detail.appearance")
        } else {
            focusedFormPage(destination)
        }
    }

    private func focusedFormPage(_ destination: WorkspaceDestination) -> some View {
        settingsPage(title: destination.title) {
            switch destination {
            case .tabBar:
                Section("Bottom menu") {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right")
                    Label("Agents", systemImage: "person.2")
                    Label("Tasks", systemImage: "calendar.badge.clock")
                    Label("Workspace", systemImage: "square.grid.2x2")
                    Text(Self.bottomMenuNote).font(.bighelp(.footnote)).foregroundStyle(.secondary)
                }
                edgeGestures
            case .caching:
                localCache
                Section { Text("Agents, groups and chat history stay on this device between connections. Hermes remains the source for changes.").foregroundStyle(.secondary) }
            case .security:
                currentConnection
            case .contact:
                helpAndFeedback
            case .watch:
                appleWatch
            default: EmptyView()
            }
        }
        .accessibilityIdentifier("settings.detail.\(destination.rawValue)")
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
            } else { Text("No host is connected.").foregroundStyle(.secondary) }
        } header: {
            Text("Connection details")
        } footer: {
            Text("Sign-ins stay in this device's Keychain.")
        }
    }

    /// Settings › Hosts: your computers, then the selected one's plugin with
    /// Update as the obvious button. Connection details are for Nerd Mode.
    /// Settings › System: the computer in use's System screen (its computers, update Hermes and
    /// the plugin, restart the gateway, Additional settings); its computers alone while it's
    /// offline, so another can still be picked or added.
    @ViewBuilder
    private var systemPage: some View {
        if let hostRegistry, hostRegistry.selectedHostID != nil {
            SystemSettingsPage(registry: hostRegistry) {
                hostsPage
            } extras: {
                if settings.nerdModeEnabled {
                    NavigationLink {
                        settingsPage(title: "Connection") {
                            currentConnection
                            BighelpPluginCapabilitiesSection(connections: workspaceConnections,
                                                             permissionCenter: permissionCenter,
                                                             showsPluginSummary: false)
                            localCache
                        }
                    } label: {
                        Label("Connection & plugin features", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
            }
        } else {
            hostsPage
        }
    }

    private var hostsPage: some View {
        let pluginUpdate = selectedHostPluginUpdate.flatMap { $0.state == .notInstalled ? nil : $0 }
        return settingsPage(title: SettingsMenuSection.connectivityAndNotifications.title) {
            if let hostRegistry {
                BighelpConfiguredHostsSection(registry: hostRegistry)
                if let pluginUpdate {
                    HostPluginUpdateSection(model: pluginUpdate)
                }
                if settings.nerdModeEnabled, hostRegistry.selectedHostID != nil {
                    currentConnection
                }
            } else {
                HostRuntimeSection(store: hostRuntime, agents: agentDirectory, theme: theme)
                PluginUpdateSection(store: pluginUpdates, theme: theme)
                connectivity
            }
            // Which plugin features each part of the app found: technical, so Nerd Mode only.
            if settings.nerdModeEnabled {
                BighelpPluginCapabilitiesSection(
                    connections: workspaceConnections,
                    permissionCenter: permissionCenter,
                    showsPluginSummary: pluginUpdate == nil
                )
                localCache
            }
        }
    }

    private var helpAndFeedback: some View {
        Section("Help & feedback") {
            Link("Report a problem", destination: URL(string: "https://github.com/promptclickrun/bighelp/issues")!)
            Link("Hermes documentation", destination: URL(string: "https://hermes-agent.nousresearch.com/docs")!)
            #if targetEnvironment(macCatalyst)
            BighelpMacUpdatesRow()
            #else
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            #endif
        }
    }

    private var appleWatch: some View {
        Section("Apple Watch") {
            if WCSession.isSupported() {
                LabeledContent("Paired", value: WCSession.default.isPaired ? "Yes" : "No")
                LabeledContent("App installed", value: WCSession.default.isWatchAppInstalled ? "Yes" : "No")
                LabeledContent("Connection", value: WCSession.default.isReachable ? "Reachable" : "Not currently reachable")
            } else { Text("Apple Watch connectivity is unavailable on this device.") }
        }
    }

    private func authenticationTitle(_ authentication: DirectHermesStoredAuthentication) -> String {
        switch authentication {
        case .dashboardSession(_, let automatic): automatic ? "No sign-in" : "Session token"
        case .bearer: "Host account"
        case .legacyLoopbackToken: "Session token"
        }
    }

    private func settingsMenuGroup(sections: [SettingsMenuSection]) -> some View {
        Section {
            ForEach(sections) { section in
                NavigationLink {
                    destination(for: section)
                } label: {
                    settingsMenuRow(section)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .accessibilityValue(section == .appearance ? appearanceSummary : "")
                .accessibilityIdentifier(section.accessibilityIdentifier)
            }
        }
        .listRowBackground(theme.surface)
    }

    /// "Lavender bubbles · Cream · Graphite"
    var appearanceSummary: String {
        "\(settings.bubbleColorName) bubbles · "
            + "\(settings.lightBackground.name) · \(settings.darkBackground.name)"
    }

    private func menuDetail(_ section: SettingsMenuSection) -> String {
        switch section {
        case .appearance: appearanceSummary
        case .voice: settings.voiceConversationMode == .codexLive
            ? "GPT Live 1 · a live conversation" : "TTS · reads replies aloud"
        default: section.detail
        }
    }

    private var selectedHostPluginUpdate: HostPluginUpdateModel? {
        guard let hostID = hostRegistry?.selectedHostID else { return nil }
        if let hostPluginUpdate, hostPluginUpdate.hostID == hostID { return hostPluginUpdate }
        return HostPluginUpdateModel.existingModel(for: hostID)
    }

    private var selectedHostPluginCheckKey: String {
        "\(hostRegistry?.selectedHostID?.uuidString ?? "none"):\(hostRegistry?.selectedWorkspace?.isConnected == true)"
    }

    private func settingsMenuRow(_ section: SettingsMenuSection) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: section.systemImage, tint: section.tintHex.map { Color(hex: $0) })
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                if section == .connectivityAndNotifications, let attention = selectedHostPluginUpdate?.attentionTitle {
                    Text(attention)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.action)
                        .accessibilityIdentifier("settings.menu.plugin-update")
                } else {
                    Text(menuDetail(section))
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private func destination(for section: SettingsMenuSection) -> some View {
        switch section {
        case .workspace:
            settingsPage(title: section.title) {
                workspace
                edgeGestures
            }
        case .agentsAndPersonalities:
            settingsPage(title: section.title) {
                agentBehavior
            }
        case .chat:
            chatPage
        case .voice:
            VoiceSettingsView(settings: settings, agents: agents,
                              selectedAgentID: agentDirectory?.selectedAgentID,
                              client: voiceSettingsClient, scope: voiceSettingsScope,
                              isCurrent: voiceSettingsIsCurrent)
        case .companion:
            if let companionStore {
                CompanionSettingsView(store: companionStore, agents: agents, agentScope: companionAgentScope)
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
                isCurrent: notificationContext?.isCurrent ?? notificationIsCurrent
            )
        case .permissions:
            PermissionsSettingsView(center: permissionCenter)
        case .help:
            settingsPage(title: section.title) { helpAndFeedback }
        case .watch:
            settingsPage(title: section.title) { appleWatch }
        case .connectivityAndNotifications:
            systemPage
        }
    }

    private var notificationQuietHoursSync: BighelpQuietHoursSync? {
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

    private static var bottomMenuNote: String {
        #if targetEnvironment(macCatalyst)
        "The bottom menu shows on these four screens and hides while you chat."
        #else
        "On iPhone, the bottom menu shows on these four screens and hides while you chat or type."
        #endif
    }

    /// A Mac pairs with no Apple Watch.
    private static var watchSection: [SettingsMenuSection] {
        #if targetEnvironment(macCatalyst)
        []
        #else
        [.watch]
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ClearCacheConfirmation(isPresented: $isClearCacheConfirmationPresented, onConfirm: clearLocalCache))
    }

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

    @Environment(\.workspaceConnections) private var workspaceConnections
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

/// Every page that shows "Clear Local Cache" confirms it the same way.
struct ClearCacheConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let onConfirm: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.alert("Clear local cache?", isPresented: $isPresented) {
            Button("Clear Cache and Refresh", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("bighelp will keep your account and preferences, clear cached data for the selected host, then pull fresh agents, sessions, and account data.")
        }
    }
}
