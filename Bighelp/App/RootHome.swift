import SwiftUI

// The one home: its three roots (Bots or Chats, Today, Work), their headers, the bar and the sidebar.
extension RootShellView {
    /// The tab, the first tab's view and what New chat and Today hold, above every computer.
    var home: HomeSelection { appState.home }

    // MARK: The bar and the headers

    /// A tab is a root: picking one closes whatever was pushed (the sidebar and ⌘1–⌘3 pick over a chat).
    var tabSelection: Binding<HomeTab> {
        Binding(get: { appState.selectedTab }, set: { appState.select($0) })
    }

    /// The first place is named after the view the person opens on; Today's dot is Needs you.
    var homeTabItems: [HomeTabItem] {
        HomeTabItem.standard(view: settings.homeView, todayHasNew: !needsYouEntries.isEmpty)
    }

    /// iPad at regular width has the slide-in panel, Mac and Vision Pro the column. iPhone has neither.
    var sidebarIsAvailable: Bool {
        BighelpPlatform.isMac || BighelpPlatform.usesTabOrnament || horizontalSizeClass == .regular
    }

    /// What every root's header starts from: the person's circle, which opens Settings, and the
    /// sidebar button where there's a sidebar.
    func homeHeaderContext(title: String? = nil) -> HomeHeaderContext {
        var context = HomeHeaderContext(personName: userIdentity.identity.displayName,
                                        personImageURL: userIdentity.avatarURL(),
                                        onOpenSettings: { isUnifiedSettingsPresented = true })
        context.title = title
        if sidebarIsAvailable { context.onToggleSidebar = { isHomeDrawerPresented.toggle() } }
        return context
    }

    /// Bots | Chats, for this run; Settings › Chat › Opens on picks the one a launch starts on.
    var homeViewSwitch: HomeViewSwitch {
        HomeViewSwitch(current: home.view) { home.view = $0 }
    }

    /// Today and Work show the computer in use: with two or more, the header switches it.
    private var homeHeaderComputer: HomeHeaderComputer? {
        let hosts = BighelpMenuHosts.current(registry: hostRegistry, demoHosts: demoHosts)
        guard let name = hosts.hosts.first(where: \.isSelected)?.name else { return nil }
        return HomeHeaderComputer(name: name, hosts: hosts.hosts, select: { id in
            if let fleet, let hostID = UUID(uuidString: id), hostRegistry?.hosts.isEmpty == false {
                recordLiveFleet()
                fleet.select(hostID)
            } else {
                hosts.select(id)
            }
        })
    }

    @ViewBuilder
    func homeRoot(_ tab: HomeTab) -> some View {
        switch tab {
        case .conversations: conversationsRoot
        case .today: todayRoot
        case .work: workRoot
        }
    }

    // MARK: Bots and Chats

    @ViewBuilder
    var conversationsRoot: some View {
        switch home.view {
        case .bots: SimpleBotsHomeView(context: simpleBotsContext)
        case .chats: ChatsInboxView(context: chatsInboxContext)
        }
    }

    private var chatsInboxContext: ChatsInboxContext {
        var header = homeHeaderContext()
        header.viewSwitch = homeViewSwitch
        if let newGroupChatAction {
            header.newItems = [.groupChat]
            header.onNew = { _ in newGroupChatAction() }
        }
        let catalog = sessionCatalog
        let features = featureStore
        return ChatsInboxContext(
            catalog: catalog, agents: agents, fleet: fleet, showsEveryComputer: showsEveryHost,
            rooms: botModeRooms.catalogRooms,
            codeSessionIDs: Set(codeHome?.sessions.map(\.id) ?? []),
            activity: botChatActivity, activitySource: botChatActivitySource,
            unsentDraft: { features.unsentDraft($0) },
            // Nothing says so while the keeper's quiet tries run.
            isConnected: nativeWorkspaceStore == nil || connectionKeeper.state != .disconnected,
            header: AnyView(HomeHeaderBar(context: header)),
            onOpen: { openInboxChat($0) },
            onChange: { changeInboxChat($0, $1) },
            onRefresh: { try? await catalog.load(requireAuthoritativeRefresh: true) },
            onNewChat: { openNewChat() },
            onOpenArchived: { appState.openSettings(at: [.section(.chat)]) },
            onOpenThisComputer: { openSessions(filteredTo: nil) })
    }

    private func openInboxChat(_ target: ChatsInboxTarget) {
        switch target {
        case .session(let summary): openSessionSelection(summary)
        case .fleetChat(let chat): openFleetChat(chat)
        case .group(let group): openFleet(.group(roomID: group.roomID), on: group.hostID)
        }
    }

    /// A row's long-press change. The computer in use's chats change through its catalog; another
    /// computer's go straight to it (rename and archive only: it keeps no pins or read state here).
    private func changeInboxChat(_ row: ChatsInboxRow, _ change: ChatsInboxChange) {
        switch row.source {
        case .session(let summary):
            if let roomID = summary.hostedRoomID, case .rename(let name) = change, let owner = currentWorkspaceOwner {
                handleAgentWorkspaceAction(.init(owner: owner, action: .renameGroup(roomID: roomID, name: name)))
                return
            }
            Task { @MainActor in
                do {
                    switch change {
                    case .pin(let pinned): try await sessionCatalog.setSessionPinned(id: summary.id, pinned: pinned)
                    case .unread(let unread): try await sessionCatalog.setSessionUnread(id: summary.id, unread: unread)
                    case .rename(let title): try await sessionCatalog.renameSession(id: summary.id, title: title)
                    case .archive: try await sessionCatalog.archiveSession(id: summary.id)
                    }
                } catch is CancellationError {
                } catch {
                    actionErrorMessage = String(localized: "bighelp couldn't change this chat. Try again.")
                }
            }
        case .fleetChat(let chat):
            switch change {
            case .rename(let title): changeFleetChat(chat, .rename(title))
            case .archive: changeFleetChat(chat, .archive)
            case .pin, .unread: break
            }
        case .fleetGroup:
            break
        }
    }

    /// The computer in use's own Sessions page, pushed from Chats: projects, imports from other
    /// apps and one bot's chats.
    @ViewBuilder
    func sessionsDestination(_ model: SessionsModel?) -> some View {
        if let model {
            oneHostSessions(model)
        } else {
            ProgressView("Loading sessions")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { _ = featureStore.prepareSessions(filteredTo: nil) }
        }
    }

    /// Every bot the home lists: every computer's while they show, else the computer in use's.
    var homeBots: [SimpleBotsBot] {
        if let gateways = simpleBotsGateways { return gateways.bots.filter { !$0.isHidden } }
        return agents.profiles.filter { $0.placement?.isHidden != true }
            .map { SimpleBotsBot($0, imageURL: agents.avatarURL(for: $0)) }
    }

    // MARK: Today

    private var spacesBridge: SpacesTodayBridge { SpacesTodayBridge { spacePage = $0 } }

    var todayRoot: some View {
        let bridge = spacesBridge
        let layout = home.todayLayout
        return TodayView(context: todayContext(bridge))
            .onAppear { layout.ownedChanges = bridge.ownedChanges }
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await TodaySpacesModel.shared.watch()
            }
            .spacesDeleteConfirmation($deletingSpace, bridge: bridge, layout: layout)
            .bighelpFullScreenCover(item: $spacePage) { item in
                if let page = item.space.page {
                    // A space's page never sends a message.
                    HTMLAppScreen(app: page.card(title: item.space.title, description: item.space.description),
                                  agentID: item.space.agentID, connection: TodaySpacesModel.shared.pageConnection(item),
                                  send: { _ in throw SpacesError.other(code: nil) })
                }
            }
    }

    private func todayContext(_ bridge: SpacesTodayBridge) -> TodayContext {
        var header = homeHeaderContext(title: String(localized: "Today"))
        header.computer = homeHeaderComputer
        header.trailing = AnyView(TodayEditButton(isEditing: $isEditingToday))
        let boards = todayBoardsContext
        let shares = PendingShareCenter.shared
        var context = TodayContext(
            header: AnyView(HomeHeaderBar(context: header)),
            needsYou: todayNeedsYou,
            onOpenNeedsYou: { isNeedsYouPresented = true },
            pendingShares: shares.waitingCount > 0
                ? TodayPendingShares(count: shares.waitingCount, open: { shares.showList() }) : nil,
            panels: [TodayBoardsPanel.descriptor] + bridge.descriptors(from: TodaySpacesModel.shared.items),
            makePanel: { panel in
                panel.kind == SpacesTodayBridge.kind ? bridge.panel(for: panel)
                    : AnyView(TodayBoardsPanel(context: boards, size: panel.size))
            },
            layout: home.todayLayout, isEditing: $isEditingToday,
            onDeletePanel: { deletingSpace = $0 },
            activity: botChatActivity, activitySource: botChatActivitySource)
        context.aboveGrid = AnyView(SpacesTodayNotes(notes: bridge.notes))
        if !isEditingToday {
            context.belowGrid = AnyView(TodayCreateBox(
                bots: SpacesHost.current()?.bots ?? [],
                primaryBotID: agents.primaryAgentID ?? agents.profiles.first(where: \.isDefault)?.id
            ) { agentID, text in
                appState.leaveComposerText(String(localized: "Make me a space for Today: \(text)"))
                startNewChat(explicitAgentID: agentID)
            })
        }
        context.panelMenu = { bridge.menuItems(for: $0) }
        return context
    }

    /// The card's count and its first entry: who asks, and what kind of answer it waits for.
    private var todayNeedsYou: TodayNeedsYouSummary? {
        let entries = needsYouEntries
        guard let first = entries.first else { return nil }
        let profile = first.agent.flatMap { agent in agents.profiles.first { $0.id == agent.id } }
        return TodayNeedsYouSummary(count: entries.count, agentID: first.agent?.id, botName: first.title,
                                    line: first.kind.title, imageURL: profile.flatMap { agents.avatarURL(for: $0) })
    }

    var todayBoardsContext: TodayBoardsContext {
        TodayBoardsContext(
            store: home.todayBoards, bots: homeBots, shellBoard: agentBoard,
            // The bot's own board, where the item opens in full.
            onOpenItem: { agentID, item in openTodayBoard(item.kind, agentID: agentID) },
            onSeeAll: { kind, agentID in openTodayBoard(kind, agentID: agentID) },
            onAsk: { agentID, text in askSimpleBot(agentID, text, fillsBlanks: false) })
    }

    /// A bot's Feed, Ideas or Goals from outside (the Watch, a widget): Today, then its board.
    func showOverToday(_ kind: AgentBoardItem.Kind, agentID: String?) {
        appState.select(.today, thenOpen: [.board(kind, agentID: agentID)])
    }

    private func openTodayBoard(_ kind: AgentBoardItem.Kind, agentID: String?) {
        let route = AppRoute.board(kind, agentID: agentID)
        if appState.path.last != route { appState.open(route) }
    }

    /// See all: every bot's Feed, Ideas or Goals, or one bot's board.
    func todayBoardPage(_ kind: AgentBoardItem.Kind, agentID: String?) -> some View {
        TodayBoardPage(context: todayBoardsContext, kind: kind, agentID: agentID,
                       makeBoardContext: { bot, store in
                           let id = bot.profileID
                           var board = AgentBoardContext(
                               agentID: id, agentName: bot.name, imageURL: bot.imageURL, activity: .idle, store: store,
                               onProfile: { appState.open(.simpleBotProfile(agentID: id)) }, onSwitchAgent: {},
                               onAsk: { askSimpleBot(id, $0, fillsBlanks: false) },
                               onSend: { askSimpleBot(id, $0, fillsBlanks: false, sendsAtOnce: true) },
                               onBlueprint: { askSimpleBot(id, $0, fillsBlanks: true) },
                               onMenu: {}, onNewChat: {}, onPickAgents: {}, tools: [])
                           // The page has Back and the bot chips; the board's own buttons would repeat them.
                           board.showsHeaderButtons = false
                           return board
                       },
                       onBack: { [appState] in
                           if case .board? = appState.path.last { appState.path.removeLast() }
                       })
    }

    // MARK: Work

    var workRoot: some View {
        var header = homeHeaderContext(title: String(localized: "Work"))
        header.computer = homeHeaderComputer
        return WorkView(context: workContext(header: AnyView(HomeHeaderBar(context: header)), projectID: nil))
    }

    /// Work filtered to one project, pushed: its pull requests, worktrees and Dev Factory in ⋯.
    func workProjectPage(_ projectID: String) -> some View {
        let store = codeHome
        let actions = WorkProjectActions(
            onPullRequests: { codeSheet = .pullRequests },
            onWorktrees: { codeSheet = .worktrees },
            onDevFactory: canOpenWorkflows ? { openDevFactory() } : nil,
            openPullRequests: store?.git?.pullRequests.count ?? 0)
        var context = workContext(header: nil, projectID: projectID)
        context.projectActions = actions
        return codeSheets(WorkView(context: context))
            .navigationTitle(store?.projects.first { $0.id == projectID }?.name ?? String(localized: "Project"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { WorkProjectMenu(actions: actions) } }
            // The sheets read the store's project.
            .task(id: projectID) { await store?.selectProject(projectID) }
    }

    private func workContext(header: AnyView?, projectID: String?) -> WorkContext {
        var doors: [WorkDoor] = []
        if canOpenProjects { doors.append(WorkDoor(kind: .projects, open: { openProjects() })) }
        if canOpenKanban { doors.append(WorkDoor(kind: .tasks, open: { openKanban() })) }
        if canOpenWorkflows {
            doors.append(WorkDoor(kind: .workflows, count: workflowsStore.map { $0.workflows.count },
                                  open: { openWorkflows() }))
        }
        if let schedules = featureStore.scheduledTasks {
            doors.append(WorkDoor(kind: .schedules, count: schedules.tasks.isEmpty ? nil : schedules.tasks.count,
                                  open: { openScheduledTasks(filteredTo: nil) }))
        }
        let scope = currentWorkspaceOwner?.cacheScopeID
        return WorkContext(
            header: header, projectID: projectID,
            code: codeHome.flatMap { $0.scopeID == scope ? $0 : nil },
            codeStatus: CodeChatStatusReader(catalog: sessionCatalog, features: featureStore),
            dashboard: featureStore.dashboardModel,
            activity: botChatActivity, activitySource: botChatActivitySource,
            workflows: workflowsStore, kanban: kanbanModel, schedules: featureStore.scheduledTasks,
            agents: agents,
            onOpen: { openWork($0) },
            doors: doors,
            onRefresh: { await refreshWork() },
            connectionKey: [currentWorkspaceOwner?.connectionGeneration.uuidString ?? "none",
                            String(canOpenKanban), String(canOpenWorkflows)].joined(separator: "|"))
    }

    /// Work reads every store it shows. Kanban's and Workflows' are made here too, where the computer
    /// has them: before, only their own pages made them.
    private func refreshWork() async {
        prepareCodeHome()
        if canOpenKanban, kanbanModel == nil, let service = makeKanbanService() {
            kanbanModel = KanbanBoardModel(service: service, agents: kanbanAgents)
        }
        if canOpenWorkflows { prepareWorkflowsStore() }
        await codeHome?.load()
        await featureStore.dashboardModel.load()
        await workflowsStore?.load()
        if let kanbanModel {
            if kanbanModel.snapshot == nil { await kanbanModel.start() } else { await kanbanModel.refresh() }
        }
        if let schedules = featureStore.scheduledTasks, schedules.loadState == .idle { await schedules.load() }
        await nativeRuntime?.refreshActiveSessions()
    }

    private func openWork(_ target: WorkTarget) {
        switch target {
        case .codeSession(let id), .chat(let id):
            guard let record = sessionCatalog.session(id: id) else {
                actionErrorMessage = "This chat isn't on this computer anymore."
                return
            }
            openSessionSelection(record.summary)
        case .codeChanges(let id):
            appState.open(.codeChanges(sessionID: id))
        case .codeBatch(let id):
            appState.open(.codeBatch(id: id))
        case .bot(let id):
            openSimpleBotChat(id)
        case .workflowRun(let id):
            guard prepareWorkflowsStore() != nil else { return }
            appState.open(.workflowRun(id: id))
        case .kanbanTask(let id):
            openKanban(task: id)
        case .scheduledTask(let task):
            openPrepared(.scheduledTask(id: task.jobID, agentID: task.profileID))
        }
    }

    /// A page of Work's (Projects, Kanban, Workflows, a task) from outside it (a link, a widget, an
    /// alert, Needs you): Work, then the page, so Back goes to Work.
    func showOverWork(_ routes: [AppRoute]) {
        appState.select(.work, thenOpen: routes)
    }

    // MARK: The sidebar

    /// iPad's slide-in panel and the Mac's and Vision Pro's column: the three places, recent chats
    /// and what has no other door.
    var homeSidebar: some View {
        HomeSidebar(context: HomeSidebarContext(
            items: homeTabItems,
            selection: appState.path.isEmpty ? appState.selectedTab : nil,
            onSelect: { tab in afterClosingHomeSheets { appState.select(tab) } },
            recent: sidebarRecentChats,
            onSeeAll: { afterClosingHomeSheets { appState.select(.chats) } },
            more: sidebarLinks,
            onNewChat: { afterClosingHomeSheets { openNewChat() } },
            onOpenSettings: { afterClosingHomeSheets { isUnifiedSettingsPresented = true } }))
    }

    private var sidebarRecentChats: [HomeSidebarChat] {
        let bots = homeBots
        return sessionCatalog.recentSummaries(includeCronSessions: false).prefix(8).map { summary in
            let members = summary.agentIDs.compactMap { id in bots.first { $0.profileID == id } }
            let bot = summary.kind == .direct ? members.first : nil
            let face: AnyView = if let bot {
                AnyView(SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL, size: 30))
            } else {
                AnyView(SimpleBotsGroupFace(members: members, size: 30))
            }
            return HomeSidebarChat(id: summary.id, title: summary.title,
                                   subtitle: bot?.name ?? String(localized: "Group chat"), face: face,
                                   isUnread: summary.isUnread, updatedAt: summary.updatedAt,
                                   open: { afterClosingHomeSheets { openSessionSelection(summary) } })
        }
    }

    private var sidebarLinks: [HomeSidebarLink] {
        var links: [HomeSidebarLink] = []
        let waiting = needsYouEntries.count
        if waiting > 0 {
            links.append(HomeSidebarLink(id: "needs-you", title: String(localized: "Needs you"), symbol: "hand.raised",
                                         detail: "\(waiting)", showsDot: true,
                                         action: { afterClosingHomeSheets { isNeedsYouPresented = true } }))
        }
        if let shared = pendingSharesMenuRow {
            links.append(HomeSidebarLink(id: "shared", title: String(localized: "Shared with bighelp"),
                                         symbol: "tray.and.arrow.down", detail: "\(shared.count)", showsDot: true,
                                         action: shared.open))
        }
        if usage.isAvailable {
            links.append(HomeSidebarLink(id: "usage", title: String(localized: "Usage"), symbol: "chart.bar",
                                         action: { afterClosingHomeSheets { showUsage() } }))
        }
        #if os(visionOS)
        links.append(HomeSidebarLink(id: "simple-mode", title: String(localized: "Simple mode"), symbol: "figure.stand",
                                     action: { SpatialSimpleMode.enter(spatialAvatar, openWindow: openWindow) }))
        #endif
        return links
    }

    /// Runs `action` once the iPad's panel has closed, so what it opens can present. The Mac's and
    /// Vision Pro's column stays, and with no panel open there's nothing to wait for.
    func afterClosingHomeSheets(_ action: @escaping @MainActor () -> Void) {
        guard isHomeDrawerPresented, !BighelpPlatform.isMac, !BighelpPlatform.usesTabOrnament else {
            action()
            return
        }
        afterHomeSheet = action
        isHomeDrawerPresented = false
    }

    func runAfterHomeSheet() {
        let action = afterHomeSheet
        afterHomeSheet = nil
        action?()
    }
}

/// The home's places around its roots: the bar on iPhone, iPad and the Mac, the ornament on Vision Pro
/// and the side strip on the iPhone Duo. Only a root shows them: a pushed page has Back. Its own
/// modifier keeps the shell's body small enough to type-check.
struct HomeBars: ViewModifier {
    /// Nothing is pushed over the root.
    let isAtRoot: Bool
    let isKeyboardVisible: Bool
    let selection: Binding<HomeTab>
    let items: [HomeTabItem]
    let onNewChat: () -> Void
    let bottomInset: CGFloat
    let selectedTint: Color
    let tint: Color

    @Environment(\.bighelpScreen) private var screen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsBar: Bool {
        isAtRoot && !isKeyboardVisible && !BighelpPlatform.usesTabOrnament && !screen.usesSideBar
    }

    func body(content: Content) -> some View {
        content
            #if os(visionOS)
            // Beside the window, not along its bottom edge by the close control.
            .ornament(visibility: isAtRoot ? .visible : .hidden,
                      attachmentAnchor: .scene(.leading), contentAlignment: .trailing) {
                HomeTabOrnament(selection: selection, items: items, onNewChat: onNewChat)
            }
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsBar {
                    HomeTabBar(selection: selection, items: items, onNewChat: onNewChat,
                               homeIndicatorSink: FloatingTabBar.homeIndicatorSink(forBottomInset: bottomInset))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // The iPhone Duo: the places go down the side strip with the screen's own buttons.
            .toolbar {
                if isAtRoot && !isKeyboardVisible && screen.usesSideBar {
                    HomeStripTabs(selection: selection, items: items, onNewChat: onNewChat,
                                  selectedTint: selectedTint, tint: tint)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: BighelpTokens.transitionDuration), value: showsBar)
    }
}
