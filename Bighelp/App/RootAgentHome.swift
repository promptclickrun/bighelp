import OSLog
import SwiftUI

// The bots' own chats and what follows the connection for the whole home: the shell's board, usage,
// the Dynamic Island and the sidebar's host.
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
        if let working = sessionCatalog.recentSummaries(includeCronSessions: false).first(where: {
            $0.kind == .direct && $0.agentIDs.first == activity.agentID
                && featureStore.preparedChatModel(id: $0.id)?.isSending == true
        }) {
            openSessionSelection(working)
        } else {
            openCanonicalAgentChat(activity.agentID)
        }
    }

    /// The primary bot's own chat, pushed: an old Activity link, or an alert that names no chat
    /// with nothing waiting. With no bot yet, the first tab.
    func openPrimaryBotChat() {
        guard let agent = homeAgent else {
            appState.select(.conversations)
            return
        }
        openCanonicalAgentChat(agent.id)
    }

    /// The tapped agent's Bot Chat; if the host can't give one, its latest chat or a new one.
    /// `startsVoice` opens voice on it. Cancelled only when the person moves on (another
    /// screen, tab or computer).
    func openCanonicalAgentChat(_ profileID: String, startsVoice: Bool = false, dissolvesOutgoing: Bool = false) {
        let saved = sessionCatalog.records.first(where: { $0.isBotChat && $0.agentIDs == [profileID] })
        // The opening loader covers the lookup and the chat's first load if they're slow.
        let opening = simpleBotsChatOpening.begin(
            agentID: profileID, name: agents.profiles.first { $0.id == profileID }?.name,
            originPath: appState.path, hasCachedContent: saved.map { hasCachedChatContent($0.id) } ?? false)
        // A Bot Chat opened before is saved here: open it at once (its chat loads from
        // Hermes as usual) rather than wait a second or two on the lookup.
        if let saved {
            showAgentChat(saved, startsVoice: startsVoice, dissolvesOutgoing: dissolvesOutgoing)
            simpleBotsChatOpening.endIfNothingOpened(opening)
            return
        }
        guard let owner = currentWorkspaceOwner else {
            simpleBotsChatOpening.endIfNothingOpened(opening)
            actionErrorMessage = "Connect to this computer to open the bot’s chat."
            return
        }
        let originTab = appState.selectedTab
        let originPath = appState.path
        let lookup = canonicalChatCoordinator.open(profileID: profileID, owner: owner, resolve: { profile, expectedOwner in
            // Demo data only when no real computer is selected (tests add real ones to a demo launch).
            if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true {
                #if DEBUG
                try await SimpleBotsChatOpening.demoLookupDelay()
                #endif
                return try DemoSessionCatalogClient.canonicalID(profileID: profile, records: sessionCatalog.records)
            }
            let ready = try await connectedOwner(signedInAs: expectedOwner)
            guard let connections = workspaceConnections else { throw WorkspaceClientError.ownerChanged }
            return try await connections.openCanonicalSession(profile, ready)
        }, canPresent: {
            currentWorkspaceOwner?.signIn == owner.signIn
                && appState.selectedTab == originTab && appState.path == originPath
        }, present: { id in
            guard let record = sessionCatalog.session(id: id), record.kind == .direct,
                  record.agentIDs == [profileID] else {
                openLatestAgentChat(profileID, startsVoice: startsVoice, dissolvesOutgoing: dissolvesOutgoing)
                return
            }
            showAgentChat(record, startsVoice: startsVoice, dissolvesOutgoing: dissolvesOutgoing)
        }, failed: {
            openLatestAgentChat(profileID, startsVoice: startsVoice, dissolvesOutgoing: dissolvesOutgoing)
        })
        Task { @MainActor in
            await lookup.value
            simpleBotsChatOpening.endIfNothingOpened(opening)
        }
    }

    /// The chat is pushed over where the person is, so Back returns there.
    private func showAgentChat(_ record: SessionRecord, startsVoice: Bool, dissolvesOutgoing: Bool = false) {
        if dissolvesOutgoing { presentNewChatDissolve(record.id, replacing: appState.activeConversationID) }
        openSession(record.summary)
        if startsVoice { appState.requestVoiceMode(for: record.id) }
    }

    /// A computer the all-hosts list just switched to shows its saved chats before
    /// it finishes connecting, and its Bot Chat lookup works only once it has.
    private func connectedOwner(signedInAs owner: WorkspaceOwner) async throws -> WorkspaceOwner {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let current = currentWorkspaceOwner, current.signIn == owner.signIn,
               let runtime = nativeRuntime, runtime.isReady, !runtime.isSuspended,
               runtime.authority == current.authority {
                return current
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WorkspaceClientError.transportUnavailable
    }

    /// Some hosts can't give an agent its Bot Chat: one already titled "Bot Chat"
    /// from Hermes' API server is hidden from the app but keeps the title. The
    /// agent still opens, on its latest chat or a new one, never an error.
    private func openLatestAgentChat(_ profileID: String, startsVoice: Bool, dissolvesOutgoing: Bool = false) {
        if let latest = sessionCatalog.recentSummaries(includeCronSessions: false)
            .first(where: { $0.kind == .direct && $0.agentIDs == [profileID] }) {
            if dissolvesOutgoing { presentNewChatDissolve(latest.id, replacing: appState.activeConversationID) }
            openSession(latest)
            if startsVoice { appState.requestVoiceMode(for: latest.id) }
        } else {
            startNewChat(explicitAgentID: profileID, startsVoice: startsVoice)
        }
    }

    /// This chat › New Bot Chat, offered only in an agent's Bot Chat.
    func botChatRestart(_ conversationID: String) -> (() -> Void)? {
        guard let record = sessionCatalog.session(id: conversationID), record.isBotChat else { return nil }
        return { startNewBotChat(record) }
    }

    /// This chat › New Bot Chat: the open Bot Chat becomes a regular chat named for
    /// now, and the agent's new Bot Chat opens in its place, a fresh start when a
    /// long one has filled its context. The blank chat shows at once, the way New chat's does
    /// (`NewChatCoordinator`); the rename and the computer making the next Bot Chat happen behind it.
    /// They once came first, and the old chat sat there for seconds with no sign of anything (#940).
    func startNewBotChat(_ record: SessionRecord) {
        guard let agentID = record.agentIDs.first else { return }
        let origin = appState.path
        let signIn = currentWorkspaceOwner?.signIn
        runNewChatStart(retry: { startNewBotChat(record) }) {
            do {
                _ = try await newChatCoordinator.start(explicitAgentID: agentID, creating: { _ in
                    try await sessionCatalog.renameSession(id: record.id,
                                                           title: SessionRecord.retiredBotChatTitle(at: .now))
                    return try await nextBotChat(for: agentID, signedInAs: signIn)
                }, beforePresentation: presentNewChatDissolve)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Nothing was made: back to the Bot Chat the person was in, which says why.
                if currentWorkspaceOwner?.signIn == signIn, sessionCatalog.session(id: record.id) != nil {
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { appState.path = origin }
                }
                throw error
            }
        }
    }

    /// The agent's Bot Chat as the computer has it now (it makes one when the agent has none).
    private func nextBotChat(for agentID: String, signedInAs signIn: WorkspaceSignIn?) async throws -> SessionRecord {
        let id: String
        if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true {
            id = try DemoSessionCatalogClient.canonicalID(profileID: agentID, records: sessionCatalog.records)
        } else {
            guard let owner = currentWorkspaceOwner, owner.signIn == signIn, let connections = workspaceConnections else {
                throw WorkspaceClientError.ownerChanged
            }
            id = try await connections.openCanonicalSession(agentID, owner)
        }
        guard let made = sessionCatalog.session(id: id), made.kind == .direct, made.agentIDs == [agentID] else {
            throw WorkspaceClientError.invalidResponse
        }
        return made
    }

    /// A bot tapped on the Bots view opens what Settings › Chat › A bot opens asks for: its Bot
    /// Chat, its latest chat, or a new one. The chat is pushed; the primary bot stays who it is.
    func openAgentChat(_ agentID: String) {
        Telemetry.featureUsed(.agentOpened)
        switch settings.botChatExperience {
        case .botChat: openCanonicalAgentChat(agentID)
        case .lastChat: openLatestAgentChat(agentID, startsVoice: false)
        case .newChat: startNewChat(explicitAgentID: agentID)
        }
    }

    /// The selected host, when it can make group chats.
    private var groupCreationReadyOwner: WorkspaceOwner? {
        guard let owner = currentWorkspaceOwner, botModeRooms.offersNewGroupChat else { return nil }
        return owner
    }

    /// A group chat with these bots right away, named after them, then opened: what New Group
    /// Chat's Create does, minus the form (New chat's To row already picked who's in it).
    /// `firstMessage` is sent in it once it opens. `ended` is called once, however this ends: with
    /// the group chat's ID once it is open, or nil when it couldn't be made or opened. New chat
    /// keeps its text, and holds a second Send, until then.
    func createGroupChat(with profileIDs: [String], peers: [HermesBotModePeerCandidate] = [],
                         firstMessage: String? = nil, ended: (@MainActor (String?) -> Void)? = nil) {
        guard let owner = groupCreationReadyOwner else {
            actionErrorMessage = "Group chats need a connected Hermes computer."
            ended?(nil)
            return
        }
        let profiles = profileIDs.compactMap { id in agents.profiles.first { $0.id == id } }
        guard profiles.count == profileIDs.count,
              (2...BotModeRoom.maximumMembers).contains(profiles.count + peers.count) else {
            actionErrorMessage = "Those bots aren't all on this computer anymore. Pick them again from New chat."
            ended?(nil)
            return
        }
        Task { @MainActor in
            do {
                let room = try await botModeRooms.createNativeRoom(
                    roomID: "room-\(UUID().uuidString)",
                    name: BotModeCreateRoomView.automaticName(profiles.map(\.name) + peers.map(\.name)),
                    profiles: profiles, peers: peers)
                // A reconnect meanwhile is still this computer.
                guard isCurrentSignIn(owner), let current = currentWorkspaceOwner else {
                    ended?(nil)
                    return
                }
                openHostedGroup(room.id, owner: current, settings: false, firstMessage: firstMessage, opened: ended)
            } catch is CancellationError {
                ended?(nil)
            } catch let error as BotModePeerLinkError {
                ended?(nil)
                guard isCurrentSignIn(owner) else { return }
                actionErrorMessage = error.message
            } catch {
                ended?(nil)
                // The kind of failure only; never host data.
                Logger(subsystem: "app.loopdy.mobile", category: "BotMode")
                    .error("Group chat create failed: \(String(reflecting: error), privacy: .public)")
                guard isCurrentSignIn(owner) else { return }
                actionErrorMessage = "The group chat couldn't be created. Check the computer, then try again."
            }
        }
    }

    /// `AppState.openNeedsYou()` (an alert that names no chat). Once the computer is connected it reads
    /// the computer's list, so the question the alert was about is in it, then opens Needs you, or the
    /// primary bot's chat when nothing waits. The request is kept until then: a cold launch can ask before the
    /// computer answers, so it waits for the connection (the shell's task restarts when
    /// `needsYouListIsReady` changes) and gives up after `NeedsYouRequest.connectionWait`. Settings is
    /// closed first, since a sheet can't show over it.
    func settleNeedsYouRequest() async {
        guard appState.isNeedsYouRequested else { return }
        guard needsYouListIsReady else {
            try? await Task.sleep(for: NeedsYouRequest.connectionWait)
            // Cancelled: the connection came up, or the request was settled or replaced.
            guard !Task.isCancelled, appState.isNeedsYouRequested else { return }
            appState.isNeedsYouRequested = false
            leaveSettings { openPrimaryBotChat() }
            return
        }
        await featureStore.dashboardModel.refreshAfterExternalChange()
        guard !Task.isCancelled, appState.isNeedsYouRequested else { return }
        appState.isNeedsYouRequested = false
        if needsYouEntries.isEmpty {
            leaveSettings { openPrimaryBotChat() }
        } else {
            leaveSettings { afterClosingHomeSheets { isNeedsYouPresented = true } }
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
        let today: Bool
        let todayDetail: Bool
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
        let today = owner.map { currentWorkspaceCapabilities.supports(.agentToday, owner: $0, profileID: nil) } ?? false
        let todayDetail = owner.map {
            currentWorkspaceCapabilities.supports(.agentTodayDetail, owner: $0, profileID: nil)
        } ?? false
        return AgentBoardClientKey(owner: owner, board: board, feedback: feedback, goalCategories: goalCategories,
                                   files: files, answers: answers, today: today, todayDetail: todayDetail, fixtures: usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true,
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
    ///
    /// The root's task does this, and so does a bot's Dashboard: a root task doesn't run while a
    /// screen covers the root, so after a reconnect the Dashboard followed the old connection, and
    /// every load said the host or connection had changed. Each connection is set up once.
    func configureAgentBoard(_ key: AgentBoardClientKey) async {
        guard key != agentBoardConfiguredKey else { return }
        agentBoardConfiguredKey = key
        // Media has its own plugin feature; the route says when it's missing.
        agentMedia.configure(client: key.owner.flatMap { owner in
            key.fixtures ? DemoAgentMediaClient.shared
                : workspaceConnections?.workspace.map { DirectHermesAgentMediaClient(workspace: $0, owner: owner) }
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
                                                      supportsAnswers: key.answers, supportsToday: key.today,
                                                      supportsTodayDetail: key.todayDetail, files: files)
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
            .task(id: agentBoardClientKey) { await configureWorkflows(agentBoardClientKey) }
            // Loads the primary bot's board up front: the widgets show it.
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
            .task(id: usageWidgetKey) { await followUsageWidget() }
            .task(id: workflowsWidgetKey) { await followWorkflowsWidget() }
            .environment(\.providerUsage, providerUsage)
            .bighelpSheet(isPresented: $isNeedsYouPresented) {
                NeedsYouDeckView(context: needsYouDeckContext)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .bighelpSheetSize(.standard)
            }
            .environment(\.needsYouDeckContext, needsYouDeckContext)
            .task(id: needsYouRequestKey) { await settleNeedsYouRequest() }
            #if DEBUG
            .task {
                guard !didPresentDemoNeedsYou,
                      ProcessInfo.processInfo.arguments.contains("-demo-needs-you") else { return }
                didPresentDemoNeedsYou = true
                await needsYouDeckContext.refresh()
                isNeedsYouPresented = true
            }
            #endif
            .task(id: hostReactionsKey) { await syncHostReactions(hostReactionsKey) }
            // Widgets show the home agent's Feed and Goals in the app's colors.
            .onChange(of: agentBoard.items, initial: true) { _, _ in BighelpWidgetExtras.shared.update(board: agentBoard) }
            .onChange(of: agentBoard.state) { _, _ in BighelpWidgetExtras.shared.update(board: agentBoard) }
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
            // A space's draft card in a chat leads to Today once its space is added. Each computer
            // has its own navigation, so it's handed over again when that changes.
            .onChange(of: ObjectIdentifier(appState), initial: true) {
                SpaceDraftCardHost.openToday = { [appState] in appState.select(.today) }
            }
            .modifier(PinnedAgentsWidgetHooks(
                agents: agents, fleet: fleet, isActive: scenePhase == .active,
                demo: usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true
                    ? (sessionCatalog, featureStore.scheduledTasks) : nil))
            .modifier(MacSidebarMemory(isOpen: $isHomeDrawerPresented,
                                       canShow: !presentsFirstRunOnboarding && !needsInitialHostSetup))
            .modifier(HomeMenuPresentation(isPresented: $isHomeDrawerPresented, onDismiss: runAfterHomeSheet,
                                           contentID: ObjectIdentifier(featureStore)) {
                // The Mac's and Vision Pro's column is kept outside the shell: drawn again from
                // the stores each time they change, not a copy made when it opened.
                BighelpLiveColumn { homeSidebar }
            })
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
        showOverWork([.projects])
    }

    /// Hermes starts new chats in the current project's folder, so the
    /// project becomes current, then the chat opens.
    func startChat(inProject id: String) {
        Task { @MainActor in
            guard await hermesWorkspaces.select(id: id, agentID: workspaceAgentID) else {
                actionErrorMessage = hermesWorkspaces.errorMessage ?? "This project couldn't be opened. Try again."
                return
            }
            startNewChat(explicitAgentID: workspaceAgentID)
        }
    }

    func openProjectChat(_ chat: ProjectsStore.Chat) {
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
                actionErrorMessage = "This chat couldn't be opened. Try again from Chats."
            }
        }
    }
}
