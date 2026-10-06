import SwiftUI

/// The all-hosts view: every agent on every host in one list. Lists come from
/// all hosts; opening anything first makes its host the selected one, and
/// screens that belong to one host (Settings, Projects…) ask which host.
extension RootShellView {
    var fleetModeOn: Bool { settings.allHostsMode && fleet != nil }

    func setAllHostsMode(_ on: Bool) {
        settings.allHostsMode = on
        fleetFocus = nil
        fleetChatsFilter = FleetChatsFilter()
        appState.chatOpenedFromList = false
        appState.select(.sessions)
        if on {
            recordLiveFleet()
            fleet?.refresh()
        } else if opensHomeChat {
            openHomeChat(replacing: true)
        }
    }

    /// ☰'s host row, with the all-hosts switch beside it. While all hosts show, picking a
    /// computer narrows the lists to it and works on it, without leaving all hosts; the
    /// switch beside it shows one computer again.
    var fleetMenuHosts: BighelpMenuHosts {
        var hosts = BighelpMenuHosts.current(registry: hostRegistry, demoHosts: demoHosts)
        guard let fleet else { return hosts }
        let isOn = fleetModeOn
        if isOn {
            // The same computers as the all-hosts chips, the focused one marked.
            hosts.hosts = fleet.hosts.map { .init(id: $0.id.uuidString, name: $0.name, isSelected: $0.id == fleetFocus) }
            hosts.select = { id in focusFleet(UUID(uuidString: id)) }
        }
        hosts.allHosts = .init(isOn: isOn, isFocused: fleetFocus != nil,
                               showAll: { focusFleet(nil) }, toggle: { setAllHostsMode(!isOn) })
        return hosts
    }

    /// Narrows every all-hosts list to one computer (nil: all of them). On All sessions the
    /// computer becomes the working one, so its own Sessions screen can show.
    func focusFleet(_ hostID: UUID?) {
        fleetFocus = hostID
        fleetChatsFilter = FleetChatsFilter()
        if appState.path.last == .allHostsChats { workOnFocusedFleetHost() }
    }

    /// The focused computer becomes the working one (where its own screens open), staying in all hosts.
    func workOnFocusedFleetHost() {
        guard let fleet, fleetModeOn, let hostID = fleetFocus, hostID != fleet.selectedHostID,
              fleet.canOpen(hostID) else { return }
        recordLiveFleet()
        fleet.select(hostID)
    }

    // MARK: Places that look the same in either mode

    /// Every chat: every computer's while all show, else this computer's Sessions list.
    func openAllSessions(filteredTo agentID: String? = nil) {
        guard fleetModeOn else {
            openSessions(filteredTo: agentID)
            return
        }
        fleetChatsFilter = FleetChatsFilter(
            agentID: agentID.flatMap { id in fleet?.selectedHostID.map { FleetID.make($0, id) } })
        openFleetChats()
    }

    /// The agents: All agents while all computers show, else this computer's Agents.
    func openAgentsList() {
        if fleetModeOn {
            appState.chatOpenedFromList = false
            appState.select(.sessions)
        } else {
            appState.select(.agents)
        }
    }

    /// Settings belongs to one computer: while all show, the focused one, or ask which.
    func openSettingsPage() {
        if fleetModeOn { fleetGate(.settings) } else { appState.select(.profile) }
    }

    /// A one-computer page (Projects, Kanban, Workflows) over the all-hosts list it was
    /// opened from, so Back goes there again.
    func showOneHostPage(_ routes: [AppRoute]) {
        let base = fleetModeOn ? Array(appState.path.prefix { $0.isAllHosts }) : []
        appState.path = base + routes
    }

    /// ☰'s destinations while all hosts show: lists span hosts, and a screen
    /// that belongs to one host asks which.
    var fleetMenuDestinations: BighelpMenuDestinations {
        var destinations = menuDestinations
        destinations.onAllAgents = { afterClosingHomeSheets { appState.chatOpenedFromList = false; appState.select(.sessions) } }
        destinations.newChatTitle = "New chat"
        destinations.onNewChat = { afterClosingHomeSheets { isFleetNewChatPresented = true } }
        destinations.onAllChats = { afterClosingHomeSheets { openAllSessions() } }
        destinations.onAgents = { afterClosingHomeSheets { fleetGate(.agents) } }
        destinations.onSettings = { afterClosingHomeSheets { fleetGate(.settings) } }
        // Every host's tasks in one list.
        destinations.onScheduledTasks = { afterClosingHomeSheets {
            _ = featureStore.prepareScheduledTasks(filteredTo: nil)
            appState.chatOpenedFromList = false
            appState.openScheduledTasks()
        } }
        // Projects and Kanban belong to one computer: the focused one, or ask which.
        destinations.onProjects = canOpenProjects ? { afterClosingHomeSheets { fleetGate(.projects) } } : nil
        destinations.onKanban = canOpenKanban ? { afterClosingHomeSheets { fleetGate(.kanban) } } : nil
        // Workflows ask which computer, then open that one's.
        destinations.onWorkflows = { afterClosingHomeSheets { fleetGate(.workflows) } }
        // Usage covers every host while all show; no host to pick.
        if destinations.onCredentialVault != nil {
            destinations.onCredentialVault = { afterClosingHomeSheets { fleetGate(.credentialVault) } }
        }
        if let folder = destinations.folder {
            destinations.folder = (name: folder.name, open: { afterClosingHomeSheets { fleetGate(.folder) } })
        }
        return destinations
    }

    func openFleetChats() {
        if appState.selectedTab != .sessions { appState.select(.sessions) }
        appState.path = [.allHostsChats]
        // A computer picked on All agents opens its own Sessions here too.
        workOnFocusedFleetHost()
    }

    // MARK: Opening across hosts

    func openFleetAgent(_ agent: FleetAgent) {
        openFleet(.agent(profileID: agent.profileID), on: agent.hostID)
    }

    /// A pinned agent from the widget: its latest chat or a new one, on its own
    /// computer when the link names one (switching there first, like All agents).
    func openIncomingAgentChat(agentID: String, hostID: UUID?) {
        if let hostID, let fleet, hostID != fleet.selectedHostID {
            guard fleet.hosts.contains(where: { $0.id == hostID }) else {
                actionErrorMessage = "That computer isn't in bighelp anymore."
                return
            }
            if let known = fleet.snapshots[hostID]?.agents, !known.isEmpty,
               !known.contains(where: { $0.profileID == agentID }) {
                actionErrorMessage = "That agent isn't on \(fleet.hostName(hostID)) anymore."
                return
            }
            openFleet(.agent(profileID: agentID), on: hostID)
            return
        }
        let place = hostID.flatMap { id in fleet?.hosts.first { $0.id == id }?.name } ?? "this computer"
        Task { @MainActor in
            // Opened as the app starts: the agent list may still be on its way.
            if agents.profiles.isEmpty { try? await agents.load() }
            guard agents.profiles.contains(where: { $0.id == agentID }) else {
                actionErrorMessage = "That agent isn't on \(place) anymore."
                return
            }
            performFleetOpen(.agent(profileID: agentID))
        }
    }

    func openFleetChat(_ chat: FleetChat) {
        openFleet(.chat(profileID: chat.profileID, storedSessionID: chat.storedSessionID,
                        appSessionID: chat.appSessionID), on: chat.hostID)
    }

    func openFleetTask(_ task: FleetTask) {
        openFleet(.task(jobID: task.jobID, profileID: task.profileID), on: task.hostID)
    }

    func startFleetChat(with agent: FleetAgent) {
        openFleet(.newChat(profileID: agent.profileID), on: agent.hostID)
    }

    /// A group chat's actions from the all-hosts list. Renaming and deleting
    /// act on the selected host, the way the Agents screen does them.
    func performFleetGroupAction(_ group: FleetGroup, _ action: FleetGroupAction) {
        guard case .open = action else {
            guard group.hostID == fleet?.selectedHostID, let owner = currentWorkspaceOwner else { return }
            switch action {
            case .rename(let name):
                handleAgentWorkspaceAction(.init(owner: owner, action: .renameGroup(roomID: group.roomID, name: name)))
            case .delete:
                handleAgentWorkspaceAction(.init(owner: owner, action: .deleteGroup(roomID: group.roomID)))
            case .open: break
            }
            return
        }
        openFleet(.group(roomID: group.roomID), on: group.hostID)
    }

    /// A group chat with the agents picked in New chat. They're all on one
    /// host; that host becomes the selected one first.
    func startFleetGroupChat(with agents: [FleetAgent]) {
        guard let hostID = agents.first?.hostID, agents.allSatisfy({ $0.hostID == hostID }) else { return }
        openFleet(.newGroup(profileIDs: agents.map(\.profileID)), on: hostID)
    }

    func fleetHome(_ fleet: FleetStore) -> FleetHomeView {
        FleetHomeView(fleet: fleet, onOpen: { openFleetAgent($0) }, onNewChat: { isFleetNewChatPresented = true },
                      onSetPinned: { setFleetPin($0, $1) }, onGroupAction: { performFleetGroupAction($0, $1) },
                      onOpenRoutines: { openFleet(.routines(profileID: $0.profileID), on: $0.hostID) },
                      onNewAgent: { fleetGate(.newAgent) }, hostFilter: fleetFocusBinding)
    }

    var fleetFocusBinding: Binding<UUID?> {
        Binding(get: { fleetFocus }, set: { focusFleet($0) })
    }

    /// All sessions while every computer shows. A picked computer gets its own Sessions screen.
    func fleetChats(_ fleet: FleetStore) -> FleetChatsView {
        FleetChatsView(fleet: fleet, hostFilter: fleetFocusBinding, filter: $fleetChatsFilter,
                       onOpen: { openFleetChat($0) }, hostSessions: { fleetHostSessions($0) })
    }

    /// The focused computer's Sessions screen, as one-computer mode shows it, once it's the
    /// working computer and connected.
    private func fleetHostSessions(_ hostID: UUID) -> AnyView? {
        guard hostID == fleet?.selectedHostID, isFleetHostReady else { return nil }
        if case .sessions(let model)? = featureStore.preparedModel(for: .sessions) {
            return AnyView(oneHostSessions(model))
        }
        return AnyView(ProgressView("Loading sessions")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { _ = featureStore.prepareSessions(filteredTo: nil) })
    }

    /// Settings, Projects and other one-host screens: on the focused computer, else with
    /// several, ask which one first; with one, just open it.
    func fleetGate(_ destination: FleetDestination) {
        guard let fleet, fleetModeOn, fleet.hosts.count > 1 else {
            performFleetOpen(.destination(destination))
            return
        }
        if let focus = fleetFocus, fleet.hosts.contains(where: { $0.id == focus }), fleet.canOpen(focus) {
            openFleet(.destination(destination), on: focus)
            return
        }
        fleetGateRequest = destination
    }

    /// Opens now on the selected host; otherwise switches hosts and opens
    /// once that host's connection is ready.
    func openFleet(_ open: FleetOpen, on hostID: UUID) {
        guard let fleet else { return }
        if hostID == fleet.selectedHostID {
            performFleetOpen(open)
            return
        }
        guard fleet.canOpen(hostID) else {
            actionErrorMessage = "\(fleet.hostName(hostID)) is a sample host in this demo."
            return
        }
        recordLiveFleet()
        fleet.pendingOpen = FleetPendingOpen(hostID: hostID, open: open)
        appState.chatOpenedFromList = false
        // An all-hosts list stays under what opens, so Back goes there again.
        let onAllHostsList = appState.path.first?.isAllHosts == true
            || (appState.path.isEmpty && [.sessions, .scheduledTasks].contains(appState.selectedTab))
        if !onAllHostsList { appState.select(.sessions) }
        fleet.select(hostID)
    }

    /// The host a tap waited for is ready: open what was tapped.
    func openPendingFleetIfReady() {
        guard let fleet, let pending = fleet.pendingOpen, pending.hostID == fleet.selectedHostID,
              isFleetHostReady else { return }
        fleet.pendingOpen = nil
        performFleetOpen(pending.open)
    }

    /// The selected host is connected and its chats are on hand. That's the
    /// saved copy from its last visit, so a chat opens at once while the host's
    /// details finish loading behind it (like the home chat at launch).
    var isFleetHostReady: Bool {
        if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true { return sessionCatalog.hasLoadedState }
        guard let runtime = nativeRuntime, !runtime.isSuspended,
              runtime.authority == currentWorkspaceOwner?.authority else { return false }
        return sessionCatalog.hasLoadedState
    }

    /// Other hosts stay connected while the all-hosts view is on and the app
    /// is open; in the background only the selected host's connection stays,
    /// as before.
    var keepsFleetHostsConnected: Bool { fleetModeOn && scenePhase != .background && hostRegistry != nil }

    func setKeepsFleetHostsConnected(_ keep: Bool) {
        hostRegistry?.keepsOtherHostsConnected = keep
        if keep { fleet?.refresh() }
    }

    struct FleetOpenReadiness: Equatable {
        let pending: FleetPendingOpen?
        let selected: UUID?
        let ready: Bool
    }

    var fleetOpenReadiness: FleetOpenReadiness {
        FleetOpenReadiness(pending: fleet?.pendingOpen, selected: fleet?.selectedHostID, ready: isFleetHostReady)
    }

    func performFleetOpen(_ open: FleetOpen) {
        switch open {
        case .agent(let profileID):
            agents.select(profileID)
            if appState.selectedTab != .sessions { appState.select(.sessions) }
            appState.chatOpenedFromList = true
            if let latest = sessionCatalog.recentSummaries(includeCronSessions: false)
                .first(where: { $0.kind == .direct && $0.agentIDs.first == profileID }) {
                openSession(latest)
            } else {
                startNewChat(explicitAgentID: profileID)
            }
        case .newChat(let profileID):
            agents.select(profileID)
            if appState.selectedTab != .sessions { appState.select(.sessions) }
            appState.chatOpenedFromList = true
            startNewChat(explicitAgentID: profileID)
        case .chat(let profileID, let storedSessionID, let appSessionID):
            appState.chatOpenedFromList = true
            if let appSessionID, let record = sessionCatalog.session(id: appSessionID) {
                openSessionSelection(record.summary)
            } else if let record = sessionCatalog.records.first(where: {
                $0.kind == .direct && $0.agentIDs == [profileID] && $0.remoteStoredID == storedSessionID
            }) {
                openSession(record.summary)
            } else {
                Task { @MainActor in
                    do {
                        let record = try await sessionCatalog.resolveStoredSession(
                            profileID: profileID, storedSessionID: storedSessionID)
                        openSession(record.summary)
                    } catch is CancellationError {
                    } catch {
                        actionErrorMessage = "This chat couldn't be opened. Try again from All sessions."
                    }
                }
            }
        case .group(let roomID):
            guard let owner = currentWorkspaceOwner else { return }
            handleAgentWorkspaceAction(.init(owner: owner, action: .openGroup(roomID: roomID)))
        case .newGroup(let profileIDs):
            createGroupChat(with: profileIDs)
        case .routines(let profileID):
            openScheduledTasks(filteredTo: profileID)
        case .task(let jobID, let profileID):
            if appState.selectedTab != .scheduledTasks { appState.select(.scheduledTasks) }
            openPrepared(.scheduledTask(id: jobID, agentID: profileID))
        case .destination(let destination):
            switch destination {
            case .settings: appState.select(.profile)
            case .agents: appState.select(.agents)
            case .newAgent:
                // That computer's Agents screen opens its new-agent editor once it's connected.
                agentCreateRequest = true
                appState.select(.agents)
            case .projects:
                if canOpenProjects { openProjects() } else { actionErrorMessage = "Projects aren't available on this host." }
            case .kanban:
                if canOpenKanban { openKanban() } else { actionErrorMessage = "Kanban isn't set up on this host." }
            case .workflows: openWorkflows()
            case .credentialVault: openCredentialVault()
            case .folder: presentHermesWorkspaces()
            }
        }
    }

    // MARK: The selected host's live data

    /// What changes the selected host's part of the list. Nil when the
    /// all-hosts view is off, so nothing is computed then.
    struct LiveFleetKey: Equatable {
        let hostID: UUID
        let agents: [AgentProfile]
        let pinned: [String]
        let chats: [SessionSummary]
        let tasks: [ScheduledTask]
        let groups: [HermesBotModeRoomSummary]
    }

    var liveFleetKey: LiveFleetKey? {
        guard fleetModeOn, let hostID = fleet?.selectedHostID, isFleetHostReady else { return nil }
        return LiveFleetKey(
            hostID: hostID, agents: agents.profiles, pinned: agents.pinnedAgentIDs,
            chats: Array(sessionCatalog.recentSummaries(includeCronSessions: false)
                .filter { $0.kind == .direct }.prefix(80)),
            tasks: featureStore.scheduledTasks?.tasks ?? [],
            groups: botModeRooms.catalogRooms
        )
    }

    /// Pin or unpin from All agents: the selected host's agent list saves its
    /// own pins (and its limit); the fleet saves another host's.
    func setFleetPin(_ agent: FleetAgent, _ pinned: Bool) {
        if agent.hostID == fleet?.selectedHostID {
            guard pinned ? agents.pinAgent(agent.profileID) : agents.unpinAgent(agent.profileID) else { return }
        }
        fleet?.setPinned(agent, pinned)
    }

    func recordLiveFleet() {
        guard let fleet, let key = liveFleetKey else { return }
        let chats = key.chats.compactMap { summary -> FleetChat? in
            guard let profileID = summary.agentIDs.first else { return nil }
            return FleetChat(
                hostID: key.hostID, profileID: profileID,
                storedSessionID: sessionCatalog.session(id: summary.id)?.remoteStoredID ?? summary.id,
                appSessionID: summary.id, title: summary.title, preview: summary.preview,
                updatedAt: summary.updatedAt, isActive: summary.isActive, origin: summary.origin
            )
        }
        let agentRows = key.agents.map { profile in
            FleetAgent(hostID: key.hostID, profileID: profile.id, name: profile.name, role: profile.role,
                       avatarFile: fleet.liveAvatarFile(from: agents.avatarURL(for: profile)),
                       isPinned: key.pinned.contains(profile.id), isDefault: profile.isDefault,
                       activity: chats.contains { $0.profileID == profile.id && $0.isActive } ? .working : nil,
                       placement: profile.placement)
        }
        let names = Dictionary(key.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let canDelete = botModeRooms.nativeCapabilities?.supports("groups.disband") == true
        let groups = key.groups.filter(\.canOpen).map { room in
            FleetGroup(hostID: key.hostID, roomID: room.roomID, name: room.name,
                       memberNames: room.members.map { names[$0.profile] ?? $0.handle },
                       updatedAt: room.updatedAt, isWorking: botModeRooms.room(id: room.roomID)?.isNativeWorking == true,
                       canRename: room.canRename, canDelete: canDelete)
        }
        fleet.selectedHostPlacementWriter = { [agents] placement, profileID in
            try await agents.setPlacement(placement, profileID: profileID)
        }
        fleet.recordLive(FleetSnapshot(agents: agentRows, chats: chats,
                                       tasks: key.tasks.map { FleetTask(hostID: key.hostID, scheduledTask: $0) },
                                       groups: groups, refreshedAt: Date()),
                         hostID: key.hostID)
    }
}

/// The all-hosts view's sheets: which host a one-host screen is for, and
/// whom to start a new chat with.
/// A choice runs once its sheet is gone, so the next screen can present.
struct FleetSheets: ViewModifier {
    let fleet: FleetStore?
    @Binding var gate: FleetDestination?
    @Binding var isNewChatPresented: Bool
    let onGate: (FleetDestination, UUID) -> Void
    let onNewChat: (FleetAgent) -> Void
    /// None when the selected host can't make group chats.
    let onNewGroup: (([FleetAgent]) -> Void)?
    /// Settings' own Appearance and Chat pages, for Fleet settings.
    var appPage: ((SettingsMenuSection) -> AnyView)?
    @State private var pickedHost: (destination: FleetDestination, hostID: UUID)?
    @State private var pickedAgent: FleetAgent?
    @State private var pickedGroup: [FleetAgent]?

    func body(content: Content) -> some View {
        content
            .sheet(item: $gate, onDismiss: {
                guard let picked = pickedHost else { return }
                pickedHost = nil
                onGate(picked.destination, picked.hostID)
            }) { destination in
                if let fleet {
                    FleetHostPicker(fleet: fleet, destination: destination, appPage: appPage) { hostID in
                        pickedHost = (destination, hostID)
                        gate = nil
                    }
                }
            }
            .sheet(isPresented: $isNewChatPresented, onDismiss: {
                if let group = pickedGroup {
                    pickedGroup = nil
                    onNewGroup?(group)
                }
                guard let agent = pickedAgent else { return }
                pickedAgent = nil
                onNewChat(agent)
            }) {
                if let fleet {
                    FleetAgentPicker(fleet: fleet, onPick: { agent in
                        pickedAgent = agent
                        isNewChatPresented = false
                    }, onPickGroup: onNewGroup.map { _ in { agents in
                        pickedGroup = agents
                        isNewChatPresented = false
                    } })
                }
            }
    }
}

extension RootShellView {
    /// The all-hosts view's own buttons: back to one host, and a new chat
    /// with any agent.
    @ToolbarContentBuilder
    var fleetToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // One bot: a tap goes back to one host.
            Button { setAllHostsMode(false) } label: {
                Image(BighelpGlyph.bot.assetName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Color.accentColor)
                    .bighelpToolbarIcon()
            }
                .bighelpIconLabel("Show one host")
                .accessibilityHint("Shows the selected host's agents and chats again.")
                .accessibilityIdentifier("fleet.toggle")
        }
    }

    /// Hosts, their names (a rename shows at once) and which is selected.
    var fleetHostsKey: [String] {
        guard let fleet else { return [] }
        return (hostRegistry?.hosts.map { $0.id.uuidString + "\u{1f}" + $0.name } ?? [])
            + [hostRegistry?.selectedHostID ?? fleet.selectedHostID].compactMap { $0?.uuidString }
    }
}

/// Keeps the all-hosts view current: the selected host's live data, a tap
/// waiting for its host, the configured hosts, and no reads in the background.
struct FleetHooks: ViewModifier {
    let liveKey: RootShellView.LiveFleetKey?
    let readiness: RootShellView.FleetOpenReadiness
    let hostsKey: [String]
    let scenePhase: ScenePhase
    let keepsConnected: Bool
    let recordLive: () -> Void
    let openPending: () -> Void
    let syncHosts: () -> Void
    let cancelReads: () -> Void
    let setKeepsConnected: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: liveKey, initial: true) { _, _ in recordLive() }
            .onChange(of: readiness, initial: true) { _, _ in openPending() }
            .onChange(of: hostsKey) { _, _ in syncHosts() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { cancelReads() } }
            .onChange(of: keepsConnected, initial: true) { _, keep in setKeepsConnected(keep) }
    }
}
