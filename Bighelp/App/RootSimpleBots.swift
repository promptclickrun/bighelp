import SwiftUI

// Bots mode (Settings › Bots mode): its home in place of the Chat
// tab, its short Settings, bot profiles, and how its chats look.
extension RootShellView {
    /// Bots mode wins over the all-hosts view and Open on (`fleetModeOn`).
    var simpleBotsOn: Bool { settings.simpleBotsEnabled }

    /// The home is the tab's root, whatever is pushed over it: no bar, no ☰; the person's circle opens Settings.
    var simpleBotsHomeIsRoot: Bool {
        simpleBotsOn && appState.selectedTab == .sessions
    }

    var simpleBotsHome: some View {
        SimpleBotsHomeView(context: simpleBotsContext)
    }

    /// Multi-gateway while the gateway of a tapped bot connects: the home, from every gateway's copy,
    /// under the opening loader. What was tapped opens once it's connected (`openPendingFleetIfReady`).
    func simpleBotsSwitching(to hostID: UUID) -> some View {
        simpleBotsHome
    }

    /// Multi-gateway: a bot on another gateway opens once that gateway is connected and its chats
    /// are loaded, often a few seconds. The Noodle loader covers the whole wait, from the tap to
    /// the chat, so the screen never looks stuck; Cancel goes back to where the tap came from.
    @ViewBuilder var simpleBotsOpeningLoader: some View {
        #if DEBUG
        // Demo hosts can't be switched to; this shows the loader for screenshots.
        if settings.simpleBotsEnabled, ProcessInfo.processInfo.arguments.contains("-test-simple-bots-opening") {
            SimpleBotsOpeningOverlay(botName: "Mina Shah", gatewayName: "Studio Mac", onCancel: {})
        }
        #endif
        if simpleBotsMultiGatewayOn, let fleet, let pending = fleet.pendingOpen {
            SimpleBotsOpeningOverlay(
                botName: pending.profileID.flatMap { fleet.agent(hostID: pending.hostID, profileID: $0)?.name },
                gatewayName: fleet.hostName(pending.hostID),
                onCancel: cancelPendingFleetOpen)
            .transition(.opacity)
        } else if simpleBotsOn {
            SimpleBotsChatOpeningLayer(opening: simpleBotsChatOpening,
                                       readiness: { simpleBotsChatOpeningReadiness },
                                       onCancel: cancelSimpleBotsChatOpening)
        }
    }

    /// Bots mode: a chat opening from a list, a search, a profile or a link. Nil outside it.
    func beginSimpleBotsChatOpening(_ session: SessionSummary) -> UUID? {
        guard simpleBotsOn else { return nil }
        let agentID = session.kind == .direct && session.agentIDs.count == 1 ? session.agentIDs[0] : nil
        let name = agentID.flatMap { id in agents.profiles.first { $0.id == id }?.name } ?? session.title
        return simpleBotsChatOpening.begin(agentID: agentID, name: name, originPath: appState.path,
                                           hasCachedContent: hasCachedChatContent(session.id))
    }

    func hasCachedChatContent(_ id: String) -> Bool {
        if let model = featureStore.preparedChatModel(id: id), !model.transcriptEntries.isEmpty { return true }
        guard let record = try? sessionCatalog.restoreSessionContent(id: id) else { return false }
        // A metadata row with accepted messages and no payload is not a cached empty chat.
        return !record.items.isEmpty || !record.activityEvents.isEmpty || !record.hasAcceptedMessage
    }

    /// After `openSession`: the chat is on screen (the loader waits for its messages if they aren't
    /// there yet), or nothing opened and the loader has nothing to wait for.
    func noteSimpleBotsChatOpened(_ opening: UUID, route: AppRoute) {
        guard case .chat(let id) = route, appState.path.last == route else {
            simpleBotsChatOpening.endIfNothingOpened(opening)
            return
        }
        simpleBotsChatOpening.attach(opening, conversationID: id)
        simpleBotsChatOpening.update(simpleBotsChatOpeningReadiness)
    }

    /// Ready once the chat on screen shows its messages: a saved copy, or the host's history once read.
    var simpleBotsChatOpeningReadiness: SimpleBotsChatOpening.Readiness {
        guard let opening = simpleBotsChatOpening.current else { return .waiting }
        if actionErrorMessage != nil { return .failed }
        guard let id = opening.conversationID else { return .waiting }
        // Moved on from it: nothing left to cover.
        guard appState.path.last == .chat(conversationID: id) else { return .failed }
        guard let model = featureStore.preparedChatModel(id: id) else { return .ready }
        return model.isHydratingHistory && model.transcriptEntries.isEmpty ? .waiting : .ready
    }

    /// Cancel on the opening loader: stop the lookup and go back to where the tap came from.
    func cancelSimpleBotsChatOpening() {
        guard let opening = simpleBotsChatOpening.cancel() else { return }
        canonicalChatCoordinator.cancel()
        guard opening.conversationID != nil, appState.path != opening.originPath else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { appState.path = opening.originPath }
    }

    var simpleBotsContext: SimpleBotsContext {
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
            gateways: simpleBotsGateways,
            activity: botChatActivity,
            activitySource: botChatActivitySource,
            modeSwitch: modeSwitch
        )
    }

    /// Where the bots' working states come from: the gateway in use's plugin route, else what stock
    /// Hermes tells the app of its Bot Chats; with Multi-gateway, also the other gateways' fresh
    /// all-hosts copies. The closures hold only stores, so each tick reads what's current.
    var botChatActivitySource: BotChatActivitySource {
        let agents = agents, catalog = sessionCatalog, connections = workspaceConnections
        let fleet = fleet, settings = settings
        let fixtures = usesWorkspaceFixtures
        return BotChatActivitySource(
            live: {
                // Hidden bots last, so the ones shown are always in the request.
                let ids = (agents.profiles.filter { $0.placement?.isHidden != true }
                    + agents.profiles.filter { $0.placement?.isHidden == true }).map(\.id)
                if fixtures, connections?.isDirectSelected != true {
                    #if DEBUG
                    if DemoBotChatActivity.isOn {
                        return .init(scope: "fixtures", signIn: nil, agentIDs: ids, reader: DemoBotChatActivity(),
                                     fallback: { [:] })
                    }
                    #endif
                    return nil
                }
                guard let connections, let owner = connections.owner, let workspace = connections.workspace else {
                    return nil
                }
                let routed = workspace.nativeContext?.features.contains(DirectHermesBotChatActivityClient.feature) == true
                return .init(scope: owner.cacheScopeID, signIn: owner.signIn, agentIDs: ids,
                             reader: routed ? DirectHermesBotChatActivityClient(
                                 currentWorkspace: { [weak connections] in connections?.workspace }) : nil,
                             fallback: { BotChatActivitySignals.botChats(catalog.records) })
            },
            others: {
                guard settings.simpleBotsEnabled, settings.simpleBotsMultiGateway, let fleet else { return [:] }
                return BotChatActivitySignals.fleet(fleet.snapshots, now: Date())
            },
            refreshOthers: {
                guard settings.simpleBotsEnabled, settings.simpleBotsMultiGateway else { return }
                fleet?.refresh()
            })
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
                    var bot = SimpleBotsBot(agent, imageURL: fleet.avatars.url(for: agent.avatarFile))
                    bot.isOnGatewayInUse = host.id == selected
                    bots.append(bot)
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
                        actionErrorMessage = String(localized: "\(agent.name) couldn't be hidden. Try again.")
                    }
                }
            },
            refresh: {
                // Keep the primary bot put from now on, whichever gateway comes into use.
                if settings.simpleBotsMultiPrimary == nil, let primaryID { settings.simpleBotsMultiPrimary = primaryID }
                fleet.refresh()
            })
    }

    /// The edge swipes in Bots mode (`effectiveLeftEdgeSwipeAction`): from the left back to your
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

    /// Its scheduled tasks as a page with Back, not the Tasks tab Bots mode doesn't show.
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
            },
            makeFilesSource: { makeSimpleBotFilesSource() },
            makeMediaClient: { makeSimpleBotMediaClient() },
            showsHiddenFiles: settings.nerdModeEnabled,
            dashboard: SimpleBotDashboardHooks(
                shellBoard: agentBoard,
                onAsk: { id, text in askSimpleBot(id, text, sends: false) },
                onSend: { id, text in askSimpleBot(id, text, sends: true) })
        )
    }

    /// The bot's own chat with the text in its message box (a Dashboard's Ask, Do it or template).
    /// It's the Bot Chat, history and all; only an empty message box takes the text.
    func askSimpleBot(_ agentID: String, _ text: String, sends: Bool) {
        appState.leaveComposerText(text, sends: sends, agentID: agentID)
        openSimpleBotChat(agentID)
    }

    /// Each bot's own folder on the computer, read through the connection of the moment.
    func makeSimpleBotFilesSource() -> (any SimpleBotFilesSource)? {
        if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true { return SimpleBotDemoFiles() }
        guard let connections = workspaceConnections else { return nil }
        return SimpleBotHostFiles { [weak connections] in
            guard let connections, let owner = connections.owner,
                  let http = connections.hosts.selectedWorkspace?.nativeClient else { return nil }
            return .init(owner: owner, http: http)
        }
    }

    /// The bot's photos and videos, as the full app's Files › Media reads them.
    func makeSimpleBotMediaClient() -> (any AgentMediaClient)? {
        if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true { return DemoAgentMediaClient.shared }
        guard let connections = workspaceConnections else { return nil }
        return SimpleBotHostMedia { [weak connections] in
            guard let connections, let owner = connections.owner, let workspace = connections.workspace else { return nil }
            return (workspace, owner)
        }
    }

    /// Bots mode's Settings sheet; All Settings leads to everything else.
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
            gateways: BighelpMenuHosts.current(registry: hostRegistry, demoHosts: demoHosts),
            catalog: sessionCatalog,
            onOpenSession: { summary in
                leaveSettings {
                    appState.chatOpenedFromList = true
                    openSession(summary)
                }
            }
        ))
    }
}
