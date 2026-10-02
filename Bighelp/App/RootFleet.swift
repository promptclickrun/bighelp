import SwiftUI

/// The all-hosts view: every agent on every host in one list. Lists come from
/// all hosts; opening anything first makes its host the selected one, and
/// screens that belong to one host (Settings, Projects…) ask which host.
extension RootShellView {
    var fleetModeOn: Bool { settings.allHostsMode && fleet != nil }

    func setAllHostsMode(_ on: Bool) {
        settings.allHostsMode = on
        appState.chatOpenedFromList = false
        appState.select(.sessions)
        if on {
            recordLiveFleet()
            fleet?.refresh()
        } else if opensHomeChat {
            openHomeChat(replacing: true)
        }
    }

    /// ☰'s host row, with the all-hosts switch beside it. Picking one host
    /// while all hosts show means "just this one".
    var fleetMenuHosts: BighelpMenuHosts {
        var hosts = BighelpMenuHosts.current(registry: hostRegistry, linkDevices: linkDevices)
        guard fleet != nil else { return hosts }
        let isOn = fleetModeOn
        let select = hosts.select
        hosts.select = { id in
            if isOn { setAllHostsMode(false) }
            select(id)
        }
        hosts.allHosts = .init(isOn: isOn, toggle: { setAllHostsMode(!isOn) })
        return hosts
    }

    /// ☰'s destinations while all hosts show: lists span hosts, and a screen
    /// that belongs to one host asks which.
    var fleetMenuDestinations: BighelpMenuDestinations {
        var destinations = menuDestinations
        destinations.onAllAgents = { afterClosingHomeSheets { appState.chatOpenedFromList = false; appState.select(.sessions) } }
        destinations.newChatTitle = "New chat"
        destinations.onNewChat = { afterClosingHomeSheets { isFleetNewChatPresented = true } }
        destinations.onAllChats = { afterClosingHomeSheets { openFleetChats() } }
        destinations.onAgents = { afterClosingHomeSheets { fleetGate(.agents) } }
        destinations.onSettings = { afterClosingHomeSheets { fleetGate(.settings) } }
        if destinations.onNewGroup != nil {
            destinations.onNewGroup = { afterClosingHomeSheets { fleetGate(.newGroup) } }
        }
        if destinations.onProjects != nil {
            destinations.onProjects = { afterClosingHomeSheets { fleetGate(.projects) } }
        }
        if destinations.onKanban != nil {
            destinations.onKanban = { afterClosingHomeSheets { fleetGate(.kanban) } }
        }
        if destinations.onProviderUsage != nil {
            destinations.onProviderUsage = { afterClosingHomeSheets { fleetGate(.providerUsage) } }
        }
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
    }

    // MARK: Opening across hosts

    func openFleetAgent(_ agent: FleetAgent) {
        openFleet(.agent(profileID: agent.profileID), on: agent.hostID)
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
                      onOpenRoutines: { openFleet(.routines(profileID: $0.profileID), on: $0.hostID) })
    }

    /// Settings, Projects and other one-host screens: with several hosts, ask
    /// which one first; with one, just open it.
    func fleetGate(_ destination: FleetDestination) {
        guard let fleet, fleetModeOn, fleet.hosts.count > 1 else {
            performFleetOpen(.destination(destination))
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
        appState.select(.sessions)
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
                        actionErrorMessage = "This chat couldn't be opened. Try again from All chats."
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
            case .projects:
                if canOpenProjects { openProjects() } else { actionErrorMessage = "Projects aren't available on this host." }
            case .kanban:
                if canOpenKanban { openKanban() } else { actionErrorMessage = "Kanban isn't set up on this host." }
            case .providerUsage:
                if providerUsage.isAvailable { providerUsage.show(agentID: homeAgent?.id ?? "default") }
                else { actionErrorMessage = "Provider usage isn't available on this host." }
            case .credentialVault: openCredentialVault()
            case .folder: presentHermesWorkspaces()
            case .newGroup: inviteToGroup(seed: nil)
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
                updatedAt: summary.updatedAt, isActive: summary.isActive
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
                    FleetHostPicker(fleet: fleet, destination: destination) { hostID in
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
