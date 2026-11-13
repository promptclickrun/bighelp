import SwiftUI

// The Marketplace (Settings › Apps & skills, and each bot's profile): one bot's Skills, Plugins,
// Talk anywhere and, with Advanced options, MCP servers and toolsets, on the same pages Hermes tools
// and Advanced Options open.
extension RootShellView {
    /// The Marketplace for `agentID`: Settings passes the bot in use, a bot's profile its own.
    func makeMarketplace(for agentID: String) -> MarketplaceContext {
        let name = agents.profiles.first { $0.id == agentID }?.name ?? agentID
        let dependencies = marketplaceDependencies(agentID: agentID)
        return MarketplaceContext(
            hostName: workspaceHostName, agentName: name,
            plugins: dependencies.map { PluginLifecycleManagementModel(client: $0.plugins, keptCopies: .shared) },
            page: { section in
                AnyView(marketplacePage(section, agentID: agentID, name: name, dependencies: dependencies))
            })
    }

    @ViewBuilder
    private func marketplacePage(_ section: MarketplaceSection, agentID: String, name: String,
                                 dependencies: CapabilitiesManagementDependencies?) -> some View {
        switch section {
        case .skills, .plugins, .toolsets:
            let destination: WorkspaceDestination = switch section {
            case .skills: .skills
            case .plugins: .plugins
            default: .toolsets
            }
            if let dependencies, let page = CapabilitiesManagementView(
                destination: destination, hostName: workspaceHostName, profileName: name, dependencies: dependencies) {
                page
            } else {
                WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                                         reason: String(localized: "Connect to your computer, then open this again."))
            }
        case .mcp:
            advancedOptionsPage(.toolServers, agentID: agentID)
        case .messaging:
            advancedOptionsPage(.messaging, agentID: agentID)
        }
    }

    /// A bot's Core Files (`CoreFilesView`) on the computer in use; made-up files in demo mode.
    func makeCoreFiles(for agentID: String) -> (any CoreFilesSource)? {
        #if DEBUG
        if usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true { return DemoCoreFiles() }
        #endif
        guard let workspace = workspaceConnections?.workspace else { return nil }
        let chatID = workspace.nativeContext?.features.contains(DirectHermesCoreFilesClient.chatFeature) == true
            ? coreFilesChatID(for: agentID) : nil
        return DirectHermesCoreFilesClient(agentID: agentID, sessionID: chatID) { [weak workspaceConnections] in
            workspaceConnections?.workspace
        }
    }

    /// The chat whose folder decides a bot's AGENTS.md, as Hermes decides it: the chat open now when it's this
    /// bot's, else the bot's Bot Chat.
    private func coreFilesChatID(for agentID: String) -> String? {
        let records = sessionCatalog.records
        let open = appState.activeConversationID.flatMap { id in records.first { $0.id == id } }
            .flatMap { $0.kind == .direct && $0.agentIDs == [agentID] ? $0 : nil }
        return (open ?? records.first { $0.isBotChat && $0.agentIDs == [agentID] })?.remoteStoredID
    }

    /// A bot's projects and the one its new chats start in (its profile › Active Project), in a store of its
    /// own so the shell's Projects keep theirs. Nil without a computer.
    func makeBotProjects(for agentID: String) -> HermesWorkspaceStore? {
        guard usesWorkspaceFixtures || workspaceConnections?.workspace != nil else { return nil }
        return hermesWorkspaces.separateStore()
    }

    /// After a bot's Active Project changes, the shell's Projects read again when they show that bot.
    func botProjectChanged(_ agentID: String) {
        guard hermesWorkspaces.catalogAgentID == agentID else { return }
        Task { await hermesWorkspaces.load(agentID: agentID) }
    }

    /// A bot's Connections: this device's access and the apps the bot can use, as Settings › Apps & skills
    /// lists them. Its skills and plugins are in its Marketplace, and its saved logins have their own row.
    func makeBotConnections(for agentID: String) -> AnyView {
        AnyView(AppsHubView(native: connectorAppsModel(), composio: composioAppsModel(for: agentID)) {
            NavigationLink {
                PermissionsSettingsView(center: permissionCenter)
            } label: {
                DeviceAccessRowLabel()
            }
            .accessibilityIdentifier("bot.connections.device-access")
        })
    }

    /// The Skills Hub and Plugins clients for `agentID` on the computer in use; demo mode's
    /// made-up catalogs (`DemoCapabilityCatalogHost`). Nil without a computer.
    private func marketplaceDependencies(agentID: String) -> CapabilitiesManagementDependencies? {
        #if DEBUG
        if usesDemoCapabilityCatalogs, let owner = currentWorkspaceOwner {
            let host = DemoCapabilityCatalogHost.shared
            let current: @MainActor () -> WorkspaceOwner? = { currentWorkspaceOwner }
            return CapabilitiesManagementDependencies(
                skills: DirectHermesSkillsHubClient(http: host, owner: owner, profileID: agentID, currentOwner: current),
                mcp: DirectHermesMCPClient(http: host, owner: owner, profileID: agentID, currentOwner: current),
                plugins: DirectHermesPluginLifecycleClient(http: host, owner: owner, currentOwner: current,
                                                           marketplace: DemoPluginMarketplace()),
                toolsets: DirectHermesToolsetClient(http: host, owner: owner, profileID: agentID, currentOwner: current))
        }
        #endif
        guard let owner = currentWorkspaceOwner, let connections = workspaceConnections,
              let direct = connections.hosts.selectedWorkspace?.nativeClient else { return nil }
        let current: @MainActor () -> WorkspaceOwner? = { currentWorkspaceOwner }
        let status = DirectHermesHostOperationsClient(rpc: direct, http: direct, owner: owner, currentOwner: current)
        return CapabilitiesManagementDependencies(
            skills: DirectHermesSkillsHubClient(http: direct, owner: owner, profileID: agentID,
                                                currentOwner: current, actionStatusClient: status),
            mcp: DirectHermesMCPClient(http: direct, rpc: direct, owner: owner, profileID: agentID,
                                       currentOwner: current, actionStatusClient: status),
            plugins: DirectHermesPluginLifecycleClient(
                http: direct, owner: owner, currentOwner: current,
                marketplace: DirectHermesPluginMarketplaceClient { [weak connections] in connections?.workspace }),
            toolsets: DirectHermesToolsetClient(http: direct, owner: owner, profileID: agentID,
                                                currentOwner: current, actionStatusClient: status))
    }
}

/// Makes the Marketplace once, when its page first shows, and keeps it while the page is on the
/// stack: `navigationDestination` builds its view again on every update.
struct MarketplaceHost: View {
    let make: @MainActor () -> MarketplaceContext

    @State private var context: MarketplaceContext?

    var body: some View {
        Group {
            if let context {
                MarketplaceView(context: context)
            } else {
                Color.clear
            }
        }
        .onAppear { if context == nil { context = make() } }
    }
}
