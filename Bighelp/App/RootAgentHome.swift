import SwiftUI

/// The agent home: the Chat tab opens the selected agent's chat, and Feed,
/// Ideas, Goals and Apps show that agent's board. The avatar opens its profile,
/// the name switches agents or groups, and ☰ holds chats and the rest of the app.
struct NewChatPickerRequest: Identifiable {
    let id = UUID()
    let seed: String?
    let owner: WorkspaceOwner
}

extension RootShellView {
    var homeAgent: AgentProfile? { agents.resolvedAgent(explicitID: nil) }

    /// What the home agent is doing right now, from its recent direct chats.
    var homeActivity: AgentActivityKind {
        guard let agent = homeAgent else { return .idle }
        for summary in sessionCatalog.recentSummaries(includeCronSessions: false).prefix(12)
        where summary.kind == .direct && summary.agentIDs.first == agent.id {
            if let model = featureStore.preparedChatModel(id: summary.id), model.isSending {
                return model.liveActivityKind
            }
        }
        return .idle
    }

    /// Who the island shows: the open chat's agent while it works, else the
    /// home agent's latest direct chat.
    var islandActivity: AgentIslandActivity? {
        guard settings.agentIslandEnabled else { return nil }
        #if DEBUG
        // "-test-island-activity coding": the home agent looks busy, for screenshots.
        let arguments = ProcessInfo.processInfo.arguments
        if usesWorkspaceFixtures, let index = arguments.firstIndex(of: "-test-island-activity"),
           arguments.indices.contains(index + 1), let kind = AgentActivityKind(rawValue: arguments[index + 1]),
           let agent = homeAgent {
            return AgentIslandActivity(agentID: agent.id, name: agent.name,
                                       imageURL: agents.avatarURL(for: agent), kind: kind)
        }
        #endif
        if case .chat(let id)? = appState.path.last, let model = featureStore.preparedChatModel(id: id),
           !model.isBotMode, model.isSending, let agentID = model.memberIDs.first,
           let profile = agents.profiles.first(where: { $0.id == agentID }) {
            return AgentIslandActivity(agentID: agentID, name: profile.name,
                                       imageURL: agents.avatarURL(for: profile), kind: model.liveActivityKind)
        }
        guard let agent = homeAgent else { return nil }
        let kind = homeActivity
        guard kind.isWorking else { return nil }
        return AgentIslandActivity(agentID: agent.id, name: agent.name,
                                   imageURL: agents.avatarURL(for: agent), kind: kind)
    }

    /// Touch and hold the island: go to the chat that is working.
    func openIslandChat() {
        guard let activity = agentIsland?.activity else { return }
        if case .chat(let id)? = appState.path.last,
           featureStore.preparedChatModel(id: id)?.memberIDs.first == activity.agentID { return }
        if homeAgent?.id != activity.agentID { agents.select(activity.agentID) }
        openHomeChat(replacing: true)
    }

    /// Every phone chat uses the agent-home look (big live avatar) and the tab
    /// bar. The Chat tab's own chat gets ☰, and so does an agent tapped on
    /// Agents (it becomes that chat). A chat picked from a list or opened about
    /// something (Feed's Discuss, a task, a deeper page) gets Back to it.
    func homeChrome(for route: AppRoute) -> AgentHomeChrome {
        // The all-hosts view has no home chat: its chats get Back to All agents.
        let isHome = !fleetModeOn && appState.selectedTab == .sessions && appState.path.count == 1
            && appState.path.first == route && !appState.chatOpenedFromList
        return AgentHomeChrome(
            isEnabled: true,
            isHome: isHome,
            // All hosts too: a chat's agent is on the selected host, so its tabs are that agent's.
            showsTabBar: true,
            onMenu: { isHomeDrawerPresented.toggle() },
            onProfile: { profileAgentID = $0 },
            onSwitchAgent: { isAgentSwitcherPresented = true },
            onNewChat: { presentNewChatPicker(seed: $0) },
            onStartChat: { startHomeChat(with: $0) },
            tabSelection: tabSelection,
            unreadTabs: boardUnreadTabs
        )
    }

    /// Feed, Ideas and Goals with items the person hasn't seen yet.
    var boardUnreadTabs: Set<AppTab> {
        var tabs: Set<AppTab> = []
        if agentBoard.unreadCount(.feed) > 0 { tabs.insert(.feed) }
        if agentBoard.unreadCount(.idea) > 0 { tabs.insert(.ideas) }
        if agentBoard.unreadCount(.goal) > 0 { tabs.insert(.goals) }
        return tabs
    }

    var opensHomeChat: Bool {
        // The all-hosts view opens on its list of agents.
        guard !fleetModeOn else { return false }
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "loopdy.home.opens-chat") == nil || defaults.bool(forKey: "loopdy.home.opens-chat")
    }

    /// Opens the home agent's latest direct chat, or a new one.
    func openHomeChat(replacing: Bool = false) {
        // Already there: tapping Chat again keeps the chat as it is. A chat
        // with Back (picked from the list) isn't the home chat; Chat leaves it.
        if !replacing, appState.selectedTab == .sessions, appState.path.count == 1, !appState.chatOpenedFromList,
           case .chat = appState.path[0] { return }
        guard let agent = homeAgent else {
            appState.select(.sessions)
            return
        }
        let latest = sessionCatalog.recentSummaries(includeCronSessions: false)
            .first { $0.kind == .direct && $0.agentIDs.first == agent.id }
        appState.chatOpenedFromList = false
        if let latest {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                appState.select(.sessions)
                openSession(latest)
            }
        } else {
            // A new chat replaces the open one in place, so only leave other tabs.
            if appState.selectedTab != .sessions { appState.select(.sessions) }
            startNewChat(explicitAgentID: agent.id)
        }
    }

    /// Opens a chat as the Chat tab's home chat.
    func openAsHomeChat(_ summary: SessionSummary) {
        appState.select(.sessions)
        appState.chatOpenedFromList = false
        openSessionSelection(summary)
    }

    /// Opens Settings › Chat › Open on once at launch, with its Start with
    /// agent, after saved chats and agents have loaded. False while it waits
    /// for Kanban's first answer.
    @discardableResult
    func openLaunchLandingIfNeeded(kanbanWaitIsOver: Bool = false) -> Bool {
        // Never push under the "Unable to open" alert: iOS drops that push while
        // the path keeps it, leaving the Chats list with no ☰ or tab bar. A link,
        // widget or notification opening the app wins (it marks this done).
        guard !didAutoOpenHomeChat, actionErrorMessage == nil, !hasPendingOutsideOpen,
              appState.selectedTab == .sessions, appState.path.isEmpty,
              sessionCatalog.hasLoadedState, let owner = currentWorkspaceOwner, homeAgent != nil else { return true }
        let choice = settings.launchLanding
        let kanban = kanbanAvailability.host == owner.cacheScopeID ? kanbanAvailability.isAvailable : nil
        guard let destination = BighelpLanding.destination(for: choice, kanbanAvailable: kanban,
                                                           kanbanWaitIsOver: kanbanWaitIsOver,
                                                           projectsAvailable: canOpenProjects) else { return false }
        didAutoOpenHomeChat = true
        // The all-hosts view opens on its list of agents.
        guard !fleetModeOn else { return true }
        if let agentID = BighelpLanding.startAgent(stored: settings.startAgentID(scope: owner.cacheScopeID),
                                                   agentIDs: agents.profiles.map(\.id), choice: choice),
           homeAgent?.id != agentID {
            agents.makeHomeAgent(agentID)
        }
        switch destination {
        case .chatList: break
        case .homeChat, .allAgents: openHomeChat()
        case .agents: appState.select(.agents)
        case .board(let tab): appState.select(tab)
        case .kanban: openKanban()
        case .projects: openProjects()
        }
        return true
    }

    /// "Ask" and "Discuss": a new chat with this agent, the text ready to send.
    func askAgent(_ text: String) {
        appState.pendingComposerText = text
        startNewChat(explicitAgentID: homeAgent?.id)
    }

    /// A filled-in blueprint: a new chat that sends it straight away.
    func sendToAgent(_ text: String) {
        appState.pendingComposerText = text
        appState.pendingComposerSends = true
        startNewChat(explicitAgentID: homeAgent?.id)
    }

    func switchHomeAgent(to agent: AgentProfile) {
        if fleetModeOn {
            // Stay in the all-hosts view: the agent's chat replaces this one,
            // with Back to All agents.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                appState.select(.sessions)
                performFleetOpen(.agent(profileID: agent.id))
            }
            return
        }
        agents.select(agent.id)
        if appState.selectedTab == .sessions { openHomeChat(replacing: true) }
    }

    /// Header New chat: pick one agent for a 1:1 chat or several for a group.
    func presentNewChatPicker(seed: String?) {
        guard let owner = currentWorkspaceOwner else {
            actionErrorMessage = "Connect to your Hermes host to start a chat."
            return
        }
        newChatPicker = NewChatPickerRequest(seed: seed, owner: owner)
    }

    /// A 1:1 chat from the New chat picker; that agent becomes the home agent.
    func startHomeChat(with agentID: String) {
        agents.select(agentID)
        if appState.selectedTab != .sessions { appState.select(.sessions) }
        appState.chatOpenedFromList = false
        startNewChat(explicitAgentID: agentID)
    }

    /// Agents: tapping an agent chats with it. On one computer that's the Chat
    /// tab's own chat, like New chat: ☰ (which leads back to Agents) and the
    /// Chat tab lit. The all-hosts view has no home chat and keeps Back.
    func openAgentChat(_ agentID: String) {
        guard !fleetModeOn else {
            agents.select(agentID)
            startNewChat(explicitAgentID: agentID)
            return
        }
        startHomeChat(with: agentID)
    }

    func inviteToGroup(seed: String?) {
        guard let owner = groupCreationReadyOwner else {
            actionErrorMessage = "Group chats need a connected Hermes host."
            return
        }
        handleAgentWorkspaceAction(AgentWorkspaceActionRequest(owner: owner, action: .createGroup(seedProfileID: seed)))
    }

    /// The selected host, when it can make group chats.
    private var groupCreationReadyOwner: WorkspaceOwner? {
        guard let owner = currentWorkspaceOwner, botModeRooms.canCreateNativeRoom,
              currentWorkspaceCapabilities.supports(.groupsCreate, owner: owner, profileID: nil) else { return nil }
        return owner
    }

    /// A group chat with these agents right away, named after them, then
    /// opened: what New group chat's Create does, minus the form (All agents'
    /// New chat › Group chat already picked who's in it).
    func createGroupChat(with profileIDs: [String]) {
        guard let owner = groupCreationReadyOwner else {
            actionErrorMessage = "Group chats need a connected Hermes host."
            return
        }
        let profiles = profileIDs.compactMap { id in agents.profiles.first { $0.id == id } }
        guard profiles.count == profileIDs.count, (2...BotModeRoom.maximumMembers).contains(profiles.count) else {
            actionErrorMessage = "Those agents aren't all on this host anymore. Pick them again from New chat."
            return
        }
        Task { @MainActor in
            do {
                let room = try await botModeRooms.createNativeRoom(
                    roomID: "room-\(UUID().uuidString)",
                    name: BotModeCreateRoomView.automaticName(profiles.map(\.name)), profiles: profiles)
                // A reconnect meanwhile is still this computer.
                guard isCurrentSignIn(owner), let current = currentWorkspaceOwner else { return }
                openHostedGroup(room.id, owner: current, settings: false)
            } catch is CancellationError {
            } catch {
                guard isCurrentSignIn(owner) else { return }
                actionErrorMessage = "The group chat couldn't be created. Check the host, then try again."
            }
        }
    }

    /// Closes the open home sheet, then runs the next step once it is gone.
    func afterClosingHomeSheets(_ action: @escaping @MainActor () -> Void) {
        // The Mac's ☰ is a sidebar that stays open; with no sheet over it,
        // there's nothing to wait for.
        if BighelpPlatform.isMac, !isAgentSwitcherPresented, profileAgentID == nil {
            action()
            return
        }
        afterHomeSheet = action
        isHomeDrawerPresented = false
        isAgentSwitcherPresented = false
        profileAgentID = nil
    }

    func runAfterHomeSheet() {
        let action = afterHomeSheet
        afterHomeSheet = nil
        action?()
    }

    // MARK: Board tabs

    func boardContext(for agent: AgentProfile) -> AgentBoardContext {
        AgentBoardContext(
            agentID: agent.id, agentName: agent.name, imageURL: agents.avatarURL(for: agent),
            activity: homeActivity, store: agentBoard,
            onProfile: { profileAgentID = agent.id },
            onSwitchAgent: { isAgentSwitcherPresented = true },
            onAsk: askAgent,
            onSend: sendToAgent,
            onMenu: { isHomeDrawerPresented.toggle() },
            onNewChat: { startHomeChat(with: agent.id) },
            onPickAgents: { presentNewChatPicker(seed: agent.id) },
            tools: appsTools(for: agent)
        )
    }

    @ViewBuilder
    func agentBoardTab(_ tab: AppTab) -> some View {
        if let agent = homeAgent {
            let context = boardContext(for: agent)
            switch tab {
            case .feed: AgentFeedView(context: context)
            case .ideas: AgentIdeasView(context: context)
            case .goals: AgentGoalsView(context: context)
            default: AgentAppsView(context: context, media: agentMedia) { appsArtifacts }
            }
        } else {
            ContentUnavailableView("No agent yet", systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Connect to Hermes to see your agent's feed, ideas and goals."))
        }
    }

    func appsTools(for agent: AgentProfile) -> [(title: String, systemImage: String, action: () -> Void)] {
        [
            ("Files", "folder", { openWorkspaceDestination(.files) }),
            ("Memory", "brain", { openWorkspaceDestination(.memory) }),
            ("Skills & tools", "wrench.and.screwdriver", { openWorkspaceDestination(.skills) }),
            ("Scheduled tasks", "calendar.badge.clock", { openScheduledTasks(filteredTo: agent.id) }),
        ]
    }

    /// Picks the agent's workspace folder when Hermes can't find one: the profile Files reads from.
    func workspaceFolderChooser(owner: WorkspaceOwner) -> WorkspaceFolderChooser? {
        guard let client = workspaceConnections?.workspace as? DirectHermesWorkspaceClient,
              let profile = client.nativeContext?.servingProfileID ?? homeAgent?.id
        else { return nil }
        return .live(client: client, owner: owner, profileID: profile)
    }

    @ViewBuilder
    var appsArtifacts: some View {
        if let owner = currentWorkspaceOwner, let performer = workspaceConnections?.workspace,
           let direct = workspaceConnections?.hosts.selectedWorkspace?.nativeClient {
            ConfiguredWorkspaceArtifactsView(
                hostName: workspaceHostName, owner: owner, http: direct, performer: performer,
                currentOwner: { workspaceConnections?.workspace === performer ? currentWorkspaceOwner : nil },
                isEmbedded: true, folderChooser: workspaceFolderChooser(owner: owner)
            )
            .id(owner)
        } else {
            ContentUnavailableView("No artifacts yet", systemImage: "square.on.circle",
                description: Text("Files, pages and apps your agent makes show up here."))
        }
    }

    // MARK: Board data

    struct AgentBoardClientKey: Equatable {
        let owner: WorkspaceOwner?
        /// Unknown until the plugin's features arrive after each (re)connect.
        let board: WorkspaceAvailability
        let feedback: Bool
        let goalCategories: Bool
        let files: Bool
        let answers: Bool
        let fixtures: Bool
        /// The selected computer will reconnect by itself (it has a saved sign-in).
        let reconnects: Bool
    }

    var agentBoardClientKey: AgentBoardClientKey {
        let owner = currentWorkspaceOwner
        let board = owner.map { currentWorkspaceCapabilities.availability(for: .agentBoard, owner: $0) } ?? .unknown
        let feedback = owner.map {
            currentWorkspaceCapabilities.supports(.agentBoardFeedback, owner: $0, profileID: nil)
        } ?? false
        let goalCategories = owner.map {
            currentWorkspaceCapabilities.supports(.agentBoardGoalCategories, owner: $0, profileID: nil)
        } ?? false
        let files = owner.map { currentWorkspaceCapabilities.supports(.agentBoardFiles, owner: $0, profileID: nil) } ?? false
        let answers = owner.map {
            currentWorkspaceCapabilities.supports(.agentBoardAnswers, owner: $0, profileID: nil)
        } ?? false
        return AgentBoardClientKey(owner: owner, board: board, feedback: feedback, goalCategories: goalCategories,
                                   files: files, answers: answers, fixtures: usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true,
                                   reconnects: nativeWorkspaceStore?.hasSavedConnection == true)
    }

    /// Keyed by sign-in, not connection: a reconnect keeps the usage on screen,
    /// and the client picks up the new connection itself.
    struct ProviderUsageKey: Equatable {
        let signIn: WorkspaceSignIn?
        let fixtures: Bool
    }

    var providerUsageKey: ProviderUsageKey {
        ProviderUsageKey(signIn: currentWorkspaceOwner?.signIn ?? workspaceSignIn,
                         fixtures: usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true)
    }

    /// The plugin route reports whether it's there; the overlay explains an older plugin.
    func configureProviderUsage(_ key: ProviderUsageKey) {
        if key.fixtures {
            providerUsage.configure(client: DemoProviderUsageClient(), scope: "fixtures")
            return
        }
        guard let signIn = key.signIn, let connections = workspaceConnections else {
            providerUsage.configure(client: nil)
            return
        }
        providerUsage.configure(client: DirectHermesProviderUsageClient(
            currentWorkspace: { [weak connections] in connections?.workspace }
        ), scope: signIn)
    }

    /// Feed, Ideas and Goals follow the connection. Coming back to the app reconnects and
    /// relearns the plugin's features; meanwhile the board waits and keeps what it shows,
    /// then reloads. Only a host that answers without the feature asks for a plugin update.
    func configureAgentBoard(_ key: AgentBoardClientKey) async {
        // Media has its own plugin feature; the route says when it's missing.
        agentMedia.configure(client: key.owner.flatMap { owner in
            key.fixtures ? nil : workspaceConnections?.workspace.map { DirectHermesAgentMediaClient(workspace: $0, owner: owner) }
        })
        if key.fixtures, key.owner != nil {
            let client = DemoAgentBoardClient()
            BighelpWidgetBoardLoader.shared.configure(client: client, scope: "fixtures")
            await agentBoard.connect(client: client, scope: "fixtures")
            return
        }
        switch AgentBoardConnectionStep.decide(isConnected: key.owner != nil, board: key.board,
                                               reconnects: key.reconnects) {
        case .wait:
            agentBoard.waitForConnection()
        case .connect:
            guard let owner = key.owner, let workspace = workspaceConnections?.workspace else {
                return agentBoard.waitForConnection()
            }
            // Posts' files download like chat files, into the same cache.
            let files = key.files ? DirectHermesGeneratedMediaClient(
                workspace: workspace, owner: owner, currentOwner: { [weak workspace] in workspace?.owner },
                cache: .shared) : nil
            let client = DirectHermesAgentBoardClient(workspace: workspace, owner: owner, supportsFeedback: key.feedback,
                                                      supportsGoalCategories: key.goalCategories,
                                                      supportsAnswers: key.answers, files: files)
            // Feed, Ideas and Goals widgets set to another agent read its board the same way.
            BighelpWidgetBoardLoader.shared.configure(client: client, scope: owner.cacheScopeID)
            await agentBoard.connect(client: client, scope: owner.cacheScopeID)
        case .pluginMissing:
            agentBoard.configure(client: nil)
            BighelpWidgetBoardLoader.shared.configure(client: nil, scope: nil)
        case .disconnected:
            agentBoard.configure(client: nil, isDisconnected: true)
            BighelpWidgetBoardLoader.shared.configure(client: nil, scope: nil)
        }
    }

    /// Attached to the workspace shell only: host setup and onboarding have no
    /// navigation destinations, so a chat pushed under them would be blank.
    func homeAutoOpen<Content: View>(_ content: Content) -> some View {
        content
            .task(id: HomeAutoOpenKey(loaded: sessionCatalog.hasLoadedState, agentID: homeAgent?.id,
                                      owner: currentWorkspaceOwner, kanban: kanbanAvailability.isAvailable)) {
                // Let the shell register its destinations before pushing.
                await Task.yield()
                guard !openLaunchLandingIfNeeded() else { return }
                // Kanban hasn't answered for this computer yet: a new answer
                // restarts this; none in time opens the default.
                try? await Task.sleep(for: BighelpLanding.kanbanWait)
                guard !Task.isCancelled else { return }
                openLaunchLandingIfNeeded(kanbanWaitIsOver: true)
            }
            .onChange(of: actionErrorMessage == nil) { _, cleared in
                if cleared { openLaunchLandingIfNeeded() }
            }
    }

    struct BoardPreloadKey: Equatable {
        let client: AgentBoardClientKey
        let agentID: String?
    }

    /// Widget boards refresh when the app opens, the host changes, or the agents do.
    struct WidgetBoardsKey: Equatable {
        let client: AgentBoardClientKey
        let homeAgentID: String?
        let agentIDs: Set<String>
        let isActive: Bool
    }

    struct HomeAutoOpenKey: Equatable {
        let loaded: Bool
        let agentID: String?
        let owner: WorkspaceOwner?
        let kanban: Bool?
    }

    // MARK: Dynamic Island pictures

    var activityAvatarKey: [String] {
        agents.profiles.map { "\($0.id)|\($0.avatarFileName ?? "")" }
    }

    /// Copies each agent's picture into the shared app group, small, so the
    /// Live Activity in the Dynamic Island shows the real avatar.
    func shareActivityAvatars() async {
        let sources = agents.profiles.compactMap { profile in
            agents.avatarURL(for: profile).map { (profile.id, $0) }
        }
        await Task.detached(priority: .utility) {
            for (agentID, url) in sources {
                BighelpActivityAvatarWriter.write(agentID: agentID, from: url)
            }
        }.value
    }

    // MARK: Reactions

    struct HostReactionsKey: Equatable {
        let owner: WorkspaceOwner?
        let enabled: Bool
    }

    var hostReactionsKey: HostReactionsKey {
        HostReactionsKey(owner: workspaceConnections?.isDirectSelected == true ? currentWorkspaceOwner : nil,
                         enabled: settings.reactionsReachAgent)
    }

    /// Settings › Chat › reactions, mirrored onto the host like Hermes Desktop:
    /// the agent gets Hermes' react tool and learns of your reactions.
    func syncHostReactions(_ key: HostReactionsKey) async {
        guard let owner = key.owner, let workspace = workspaceConnections?.workspace else { return }
        _ = try? await workspace.perform(.configSet, payload: [
            "key": .string("display.message_reactions"), "value": .string(key.enabled ? "true" : "false"),
        ], owner: owner)
    }

    // MARK: Sheets

    func agentHomeSheets<Content: View>(_ content: Content) -> some View {
        content
            .task(id: agentBoardClientKey) { await configureAgentBoard(agentBoardClientKey) }
            .task(id: providerUsageKey) { configureProviderUsage(providerUsageKey) }
            .task(id: agentBoardClientKey) { await configureKanban(agentBoardClientKey) }
            // Loads the home agent's board up front, so new Feed, Ideas and Goals
            // items show as dots on the tab bar before the tab is opened.
            .task(id: BoardPreloadKey(client: agentBoardClientKey, agentID: homeAgent?.id)) {
                guard agentBoard.isAvailable, let agentID = homeAgent?.id, agentBoard.agentID != agentID else { return }
                await agentBoard.load(agentID: agentID)
            }
            .task(id: WidgetBoardsKey(client: agentBoardClientKey, homeAgentID: homeAgent?.id,
                                      agentIDs: Set(agents.profiles.map(\.id)), isActive: scenePhase == .active)) {
                guard scenePhase == .active else { return }
                await BighelpWidgetBoardLoader.shared.refresh(homeAgentID: homeAgent?.id,
                                                              knownAgentIDs: Set(agents.profiles.map(\.id)))
            }
            .task(id: usageReaderKey) { configureUsage(usageReaderKey) }
            .environment(\.providerUsage, providerUsage)
            .task(id: hostReactionsKey) { await syncHostReactions(hostReactionsKey) }
            // Widgets show the home agent's Feed and Goals in the app's colors.
            .onChange(of: agentBoard.items, initial: true) { _, _ in BighelpWidgetExtras.shared.update(board: agentBoard) }
            .onChange(of: settings.appearanceContext, initial: true) { _, context in
                BighelpWidgetExtras.shared.update(appearance: context)
            }
            .background {
                if let agentIsland {
                    AgentIslandPublisher(model: agentIsland) { islandActivity }
                }
            }
            .onAppear { agentIsland?.onOpen = { openIslandChat() } }
            .task(id: activityAvatarKey) { await shareActivityAvatars() }
            .modifier(PinnedAgentsWidgetHooks(
                agents: agents, fleet: fleet, isActive: scenePhase == .active,
                demo: usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true
                    ? (sessionCatalog, featureStore.scheduledTasks) : nil))
            .sheet(isPresented: Binding(get: { profileAgentID != nil }, set: { if !$0 { profileAgentID = nil } }),
                   onDismiss: runAfterHomeSheet) {
                if let id = profileAgentID, let agent = agents.profiles.first(where: { $0.id == id }) {
                    agentProfileSheet(agent)
                }
            }
            .sheet(item: $newChatPicker) { request in
                BotModeCreateRoomView(rooms: botModeRooms, agents: agents, seedProfileID: request.seed,
                                      onStartDirect: { startHomeChat(with: $0) }) { roomID in
                    guard request.owner == currentWorkspaceOwner else { return }
                    openHostedGroup(roomID, owner: request.owner, settings: false)
                }
                .bighelpSheetSize(.standard)
            }
            .sheet(isPresented: $isAgentSwitcherPresented, onDismiss: runAfterHomeSheet) {
                agentSwitcherSheet
            }
            .modifier(MacSidebarMemory(isOpen: $isHomeDrawerPresented,
                                       canShow: !presentsFirstRunOnboarding && !needsInitialHostSetup))
            .modifier(HomeMenuPresentation(isPresented: $isHomeDrawerPresented, onDismiss: runAfterHomeSheet) {
                homeDrawer
            })
    }

    private func agentProfileSheet(_ agent: AgentProfile) -> some View {
        let owner = currentWorkspaceOwner
        let canEdit = owner.map { currentWorkspaceCapabilities.supports(.profilesEdit, owner: $0, profileID: agent.id) } ?? false
        // From a chat with this agent: that chat's model and reasoning.
        let chat: ChatModel? = if case .chat(let id)? = appState.path.last,
                                  let model = featureStore.preparedChatModel(id: id),
                                  !model.isBotMode, model.memberIDs.first == agent.id { model } else { nil }
        return AgentProfileSheet(
            agent: agent, imageURL: agents.avatarURL(for: agent), activity: homeActivity,
            isConnected: owner != nil, store: agentBoard,
            schedules: (featureStore.scheduledTasks?.tasks ?? []).filter { $0.agentID == agent.id },
            onEdit: {
                guard canEdit, let owner else {
                    actionErrorMessage = "Connect to this host before editing its agent profile."
                    return
                }
                afterClosingHomeSheets {
                    workspaceProfileEditor = .editing(agent, store: agents, processor: AvatarImageProcessor(),
                                                      isCurrent: { currentWorkspaceOwner?.signIn == owner.signIn })
                }
            },
            onOpenSchedule: { task in afterClosingHomeSheets { openScheduledTask(task) } },
            chatControls: chat?.runtimeControls,
            onChangeModel: chat.map { chat in { afterClosingHomeSheets { chat.requestSessionControls() } } }
        )
    }

    private var homeGroups: [SessionSummary] {
        sessionCatalog.recentSummaries(includeCronSessions: false).filter { $0.kind == .botMode }
    }

    private var agentSwitcherSheet: some View {
        let groups = homeGroups
        return AgentSwitcherSheet(
            agents: agents.profiles,
            selectedID: homeAgent?.id,
            imageURL: { agents.avatarURL(for: $0) },
            groups: groups.map { .init(id: $0.id, name: $0.title, memberCount: $0.agentIDs.count) },
            onSelect: { agent in afterClosingHomeSheets { switchHomeAgent(to: agent) } },
            onSelectGroup: { group in
                guard let summary = groups.first(where: { $0.id == group.id }) else { return }
                afterClosingHomeSheets { openAsHomeChat(summary) }
            },
            onNewGroup: { afterClosingHomeSheets { inviteToGroup(seed: homeAgent?.id) } },
            onNewAgent: { afterClosingHomeSheets { appState.select(.agents) } },
            onManageAgents: { afterClosingHomeSheets { appState.select(.agents) } }
        )
    }

    private var homeDrawer: some View {
        AgentHomeDrawer(
            chats: Array(sessionCatalog.recentSummaries(includeCronSessions: false).prefix(12)),
            agent: { id in agents.profiles.first { $0.id == id }.map { ($0.name, agents.avatarURL(for: $0)) } },
            hosts: fleetMenuHosts,
            destinations: fleetModeOn ? fleetMenuDestinations : menuDestinations,
            onOpen: { summary in afterClosingHomeSheets { openAsHomeChat(summary) } },
            fleetChats: fleetModeOn ? fleet.map { fleet in
                (fleet, { chat in afterClosingHomeSheets { openFleetChat(chat) } })
            } : nil
        )
    }

    /// Where the ☰ menu goes. Every menu entry point opens this one menu.
    var menuDestinations: BighelpMenuDestinations {
        BighelpMenuDestinations(
            newChatTitle: homeAgent.map { "New chat with \($0.name)" } ?? "New chat",
            onNewChat: {
                afterClosingHomeSheets {
                    if appState.selectedTab != .sessions { appState.select(.sessions) }
                    appState.chatOpenedFromList = false
                    startNewChat(explicitAgentID: homeAgent?.id)
                }
            },
            onAllChats: { afterClosingHomeSheets { appState.select(.sessions) } },
            onProjects: canOpenProjects ? { afterClosingHomeSheets { openProjects() } } : nil,
            onAgents: { afterClosingHomeSheets { appState.select(.agents) } },
            onScheduledTasks: { afterClosingHomeSheets { openScheduledTasks(filteredTo: nil) } },
            onKanban: canOpenKanban ? { afterClosingHomeSheets { openKanban() } } : nil,
            folder: settings.nerdModeEnabled
                ? (name: activeHermesWorkspaceName, open: { afterClosingHomeSheets { presentHermesWorkspaces() } })
                : nil,
            onUsage: usage.isAvailable ? { afterClosingHomeSheets { showUsage() } } : nil,
            onCredentialVault: canOpenCredentialVault ? { afterClosingHomeSheets { openCredentialVault() } } : nil,
            onSettings: { afterClosingHomeSheets { appState.select(.profile) } }
        )
    }

}

// MARK: - Projects

extension RootShellView {
    /// Projects are the host's own (Hermes projects); demo mode has samples.
    var canOpenProjects: Bool {
        nativeRuntime != nil || (usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true)
    }

    var projectsContext: ProjectsContext? {
        guard let store = projectsStore else { return nil }
        return ProjectsContext(
            store: store, workspaces: hermesWorkspaces, agentID: workspaceAgentID,
            isNerdMode: settings.nerdModeEnabled,
            onOpenProject: { appState.open(.project(id: $0)) },
            onNewChat: { startChat(inProject: $0) },
            onOpenChat: { openProjectChat($0) },
            onManage: { openWorkspaceDestination(.projects) }
        )
    }

    func openProjects() {
        let source: any ProjectsSource
        if let runtime = nativeRuntime {
            guard let lifecycle = try? runtime.stockGitPresentation(profileID: workspaceAgentID).projects else {
                actionErrorMessage = "Projects couldn't be opened. Check that your computer is connected, then try again."
                return
            }
            source = LiveProjectsSource(lifecycle: lifecycle)
        } else if usesWorkspaceFixtures {
            source = DemoProjectsSource()
        } else {
            actionErrorMessage = "Connect to your computer to use Projects."
            return
        }
        projectsStore = ProjectsStore(source: source, profileID: workspaceAgentID)
        if appState.selectedTab != .sessions { appState.select(.sessions) }
        appState.path = [.projects]
    }

    /// Hermes starts new chats in the current project's folder, so the
    /// project becomes current, then the chat opens.
    func startChat(inProject id: String) {
        Task { @MainActor in
            guard await hermesWorkspaces.select(id: id, agentID: workspaceAgentID) else {
                actionErrorMessage = hermesWorkspaces.errorMessage ?? "This project couldn't be opened. Try again."
                return
            }
            appState.chatOpenedFromList = true
            startNewChat(explicitAgentID: workspaceAgentID)
        }
    }

    func openProjectChat(_ chat: ProjectsStore.Chat) {
        appState.chatOpenedFromList = true
        if let id = chat.catalogID, let record = sessionCatalog.session(id: id) {
            openSessionSelection(record.summary)
            return
        }
        // Usually the chat is already in the list: open it at once. Looking it
        // up on the host reloads every chat first, which took seconds.
        if let record = sessionCatalog.records.first(where: {
            $0.kind == .direct && $0.agentIDs == [chat.profileID] && $0.remoteStoredID == chat.id
        }) {
            openSession(record.summary)
            return
        }
        guard projectsStore?.openingChatID == nil else { return }
        projectsStore?.openingChatID = chat.id
        Task { @MainActor in
            defer { projectsStore?.openingChatID = nil }
            do {
                let record = try await sessionCatalog.resolveStoredSession(profileID: chat.profileID,
                                                                            storedSessionID: chat.id)
                openSession(record.summary)
            } catch is CancellationError {
            } catch {
                actionErrorMessage = "This chat couldn't be opened. Try again from All sessions."
            }
        }
    }
}
