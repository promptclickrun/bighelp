import SwiftUI

// Simple Bot mode (Settings › Simple Bot mode): its home in place of the Chat
// tab, its short Settings, bot profiles, and how its chats look.
extension RootShellView {
    /// Simple Bot mode wins over the all-hosts view and Open on (`fleetModeOn`).
    var simpleBotsOn: Bool { settings.simpleBotsEnabled }

    /// The home is the tab's root, whatever is pushed over it: no bar, no ☰; the person's circle opens Settings.
    var simpleBotsHomeIsRoot: Bool {
        simpleBotsOn && appState.selectedTab == .sessions
    }

    var simpleBotsHome: some View {
        SimpleBotsHomeView(context: simpleBotsContext)
    }

    /// Multi-gateway while the gateway of a tapped bot connects: the home, from every gateway's copy,
    /// with a line saying so. What was tapped opens once it's connected (`openPendingFleetIfReady`).
    func simpleBotsSwitching(to hostID: UUID) -> some View {
        simpleBotsHome
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: BighelpTokens.space8) {
                    ProgressView()
                    Text("Connecting to \(fleet?.hostName(hostID) ?? "your gateway")…")
                        .font(.bighelp(.subheadline))
                }
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: 40)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, BighelpTokens.space8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("simple-bots.connecting")
            }
    }

    private var simpleBotsContext: SimpleBotsContext {
        let owner = currentWorkspaceOwner
        let capabilities = currentWorkspaceCapabilities
        func supports(_ capability: WorkspaceCapability) -> Bool {
            owner.map { capabilities.supports(capability, owner: $0, profileID: nil) } ?? false
        }
        return SimpleBotsContext(
            agents: agents, catalog: sessionCatalog,
            personName: userIdentity.identity.displayName, personImageURL: userIdentity.avatarURL(),
            scope: owner?.cacheScopeID ?? "local",
            canCreateBots: usesWorkspaceFixtures || supports(.profilesCreate),
            canCreateGroups: supports(.groupsCreate) && botModeRooms.canCreateNativeRoom,
            onOpenBot: { openSimpleBotChat($0) },
            onOpenSession: { summary in
                appState.chatOpenedFromList = true
                openSession(summary)
            },
            onOpenSettings: { isUnifiedSettingsPresented = true },
            onOpenProfile: { appState.open(.simpleBotProfile(agentID: $0)) },
            onNewChat: { agentID in
                appState.chatOpenedFromList = true
                startNewChat(explicitAgentID: agentID)
            },
            onCreateGroup: { createGroupChat(with: $0) },
            makeCreator: { makeSimpleBotCreator() },
            onRoutines: { openSimpleBotRoutines($0) },
            gateways: simpleBotsGateways
        )
    }

    /// Multi-gateway: every gateway's bots. The one in use is live, or its all-hosts copy until its agents
    /// are known (the home stays on screen while it connects); the others come from their copies, which
    /// stay current because those gateways stay connected (`keepsFleetHostsConnected`).
    private var simpleBotsGateways: SimpleBotsGateways? {
        guard simpleBotsMultiGatewayOn, let fleet else { return nil }
        let selected = fleet.selectedHostID
        let liveKnown = nativeRuntime != nil && agents.knowsProfiles
        var bots: [SimpleBotsBot] = [], latest: [String: SimpleBotsLatest] = [:], pinned: [String] = []
        for host in fleet.hosts {
            if host.id == selected, liveKnown {
                let live = agents.profiles.map { SimpleBotsBot($0, hostID: host.id, imageURL: agents.avatarURL(for: $0)) }
                bots += live
                latest.merge(SimpleBotsHomeProjection.latestChats(
                    sessionCatalog.recentSummaries(includeCronSessions: false), bots: live.map { ($0.id, $0.profileID) }
                )) { _, new in new }
                pinned += agents.pinnedAgentIDs.map { FleetID.make(host.id, $0) }
            } else {
                for agent in fleet.agents(on: host.id) {
                    bots.append(SimpleBotsBot(agent, imageURL: fleet.avatars.url(for: agent.avatarFile)))
                    if let chat = fleet.latestChat(for: agent) {
                        latest[agent.id] = SimpleBotsLatest(preview: chat.preview, date: chat.updatedAt)
                    }
                    if agent.isPinned { pinned.append(agent.id) }
                }
            }
        }
        let shown = bots.filter { !$0.isHidden }
        // The one picked on this device; else the gateway in use's primary bot, then its default one.
        let inUse = selected.flatMap { host in
            (agents.primaryAgentID ?? agents.profiles.first(where: \.isDefault)?.id).map { FleetID.make(host, $0) }
        }
        let primaryID = [settings.simpleBotsMultiPrimary, inUse].compactMap { $0 }
            .first { id in shown.contains { $0.id == id } }
            ?? shown.first { $0.hostID == selected && $0.isDefault }?.id ?? shown.first(where: \.isDefault)?.id
        return SimpleBotsGateways(
            selectedHostID: selected, bots: bots, latest: latest, pinnedIDs: pinned, primaryID: primaryID,
            filter: settings.simpleBotsGatewayFilter ? fleet.hosts : nil,
            open: { open, hostID in openFleet(open, on: hostID) },
            setPinned: { bot, pin in
                if bot.profile != nil, bot.hostID == fleet.selectedHostID {
                    _ = pin ? agents.pinAgent(bot.profileID, limit: .max, counting: 0) : agents.unpinAgent(bot.profileID)
                } else if let agent = bot.fleetAgent {
                    fleet.setPinned(agent, pin)
                }
            },
            setPrimary: { bot in
                settings.simpleBotsMultiPrimary = bot.id
                if bot.profile != nil { _ = agents.setPrimaryAgent(bot.profileID) }
            },
            hide: { bot in
                guard let agent = bot.fleetAgent else { return }
                Task { @MainActor in
                    do { try await fleet.setHidden(agent, true) } catch {
                        actionErrorMessage = "\(agent.name) couldn't be hidden. Try again."
                    }
                }
            },
            refresh: {
                // Keep the primary bot put from now on, whichever gateway comes into use.
                if settings.simpleBotsMultiPrimary == nil, let primaryID { settings.simpleBotsMultiPrimary = primaryID }
                fleet.refresh()
            })
    }

    /// The edge swipes in Simple Bot mode (`effectiveLeftEdgeSwipeAction`): from the left back to your
    /// bots, from the right this bot's profile (the primary bot's on the home). False for anything else.
    func performSimpleBotsSwipe(_ action: WorkspaceSwipeAction) -> Bool {
        switch action {
        case .agents:
            appState.select(.sessions)
            appState.path.removeAll()
            return true
        case .profile:
            let chatBot: String? = if case .chat(let id)? = appState.path.last {
                featureStore.preparedChatModel(id: id)?.memberIDs.first
            } else { nil }
            guard let botID = chatBot ?? agents.primaryAgentID ?? agents.profiles.first(where: \.isDefault)?.id
            else { return true }
            if case .simpleBotProfile(let shown)? = appState.path.last, shown == botID { return true }
            appState.open(.simpleBotProfile(agentID: botID))
            return true
        default:
            return false
        }
    }

    /// A bot's chat over the home, with Back: its Bot Chat, like everywhere else.
    func openSimpleBotChat(_ agentID: String) {
        openCanonicalAgentChat(agentID, fromList: true)
    }

    /// Its scheduled tasks as a page with Back, not the Tasks tab Simple Bot mode doesn't show.
    func openSimpleBotRoutines(_ agentID: String) {
        guard featureStore.prepareScheduledTasks(filteredTo: agentID) else { return }
        appState.open(.scheduledTasks)
    }

    /// A new bot, made the way New agent makes one: a copy of the default bot's setup where the host can.
    func makeSimpleBotCreator() -> AgentEditorModel? {
        guard let owner = currentWorkspaceOwner else {
            return usesWorkspaceFixtures ? .creating(store: agents, processor: AvatarImageProcessor()) : nil
        }
        let capabilities = currentWorkspaceCapabilities
        guard usesWorkspaceFixtures || capabilities.supports(.profilesCreate, owner: owner, profileID: nil) else {
            return nil
        }
        return .creating(
            store: agents, processor: AvatarImageProcessor(),
            profileCloneSupport: capabilities.supports(.profilesClone, owner: owner, profileID: nil)
                ? .nativeBundleOnly
                : .unavailable("Native profile cloning is not available on this connection."),
            isCurrent: { currentWorkspaceOwner?.signIn == owner.signIn })
    }

    func simpleBotProfileContext(for agentID: String) -> SimpleBotProfileContext {
        let owner = currentWorkspaceOwner
        let canEdit = usesWorkspaceFixtures
            || (owner.map { currentWorkspaceCapabilities.supports(.profilesEdit, owner: $0, profileID: agentID) } ?? false)
        let agent = agents.profiles.first { $0.id == agentID }
        return SimpleBotProfileContext(
            agents: agents, scheduledTasks: featureStore.scheduledTasks,
            screenService: makeBotScreenService(), screenChats: agent.map(botScreenChats(for:)) ?? [],
            canEdit: canEdit,
            onOpenChat: { openSimpleBotChat($0) },
            onOpenRoutine: { openScheduledTask($0) },
            onEditDetails: { profile in
                guard let owner else { return }
                workspaceProfileEditor = .editing(profile, store: agents, processor: AvatarImageProcessor(),
                                                  isCurrent: { currentWorkspaceOwner?.signIn == owner.signIn })
            },
            makeModelDefaults: { id in
                let capabilities = currentWorkspaceCapabilities
                guard usesWorkspaceFixtures || owner.map({
                    capabilities.supports(.modelsRead, owner: $0, profileID: id)
                        && capabilities.supports(.agentDefaultsEdit, owner: $0, profileID: id)
                }) == true else { return nil }
                return AgentRuntimeDefaultsEditorModel(agentID: id, client: agentRuntimeDefaults)
            }
        )
    }

    /// Simple Bot mode's Settings sheet; All Settings leads to everything else.
    func simpleBotsSettings() -> some View {
        let close = { isUnifiedSettingsPresented = false }
        let profile = agents.resolvedAgent(explicitID: nil)?.id ?? "default"
        let agents = agents
        let configuration: (any SimpleBotHostConfiguring)? = usesWorkspaceFixtures
            && workspaceConnections?.isDirectSelected != true
            ? SimpleBotDemoConfiguration.shared
            : currentWorkspaceOwner.map { _ in
                SimpleBotWorkspaceConfiguration(workspace: { [weak workspaceConnections] in workspaceConnections?.workspace })
            }
        return SimpleBotsSettingsView(context: SimpleBotsSettingsContext(
            settings: settings, userIdentity: userIdentity, agents: agents,
            makeHostSettings: {
                configuration.map {
                    SimpleBotHostSettings(client: $0, profile: profile, allProfiles: { agents.profiles.map(\.id) })
                }
            },
            usage: providerUsage,
            makeTeamwork: { teamworkModel() },
            page: { page in AnyView(workspaceSettings().withDone(close).simpleBotsPage(page)) },
            allSettings: {
                let settings = workspaceSettings().withDone(close)
                return AnyView(settings.settingsDone(settings))
            },
            onOpenUsage: { leaveSettings { appState.open(.usage) } },
            onOpenComputer: { id in leaveSettings { appState.open(.simpleBotProfile(agentID: id)) } },
            onDone: close,
            gateways: BighelpMenuHosts.current(registry: hostRegistry, demoHosts: demoHosts)
        ))
    }
}
