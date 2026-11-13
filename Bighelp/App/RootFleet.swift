import SwiftUI

/// Every computer in the one home (Settings › Your computers › Show every computer): the Bots and
/// Chats views list every computer's, and opening anything first makes its computer the one in use.
extension RootShellView {
    /// Every computer's bots and chats are on screen, and the other computers stay connected.
    var showsEveryHost: Bool { settings.showsEveryComputer && fleet != nil }

    // MARK: Opening across computers

    /// An agent from a widget, Shortcut or link: its Bot Chat, or with `startsVoice`
    /// its Bot Chat in voice. A link naming another computer switched there first
    /// (`holdsLinkForItsComputer`). The primary bot stays who it is.
    func openIncomingAgentChat(agentID: String?, hostID: UUID?, startsVoice: Bool = false) {
        let place = hostID.flatMap { id in fleet?.hosts.first { $0.id == id }?.name } ?? "this computer"
        Task { @MainActor in
            // Opened as the app starts: the agent list may still be on its way.
            if agents.profiles.isEmpty { try? await agents.load() }
            // No agent named: the home agent. One that's gone is never swapped for another.
            let agent = agentID.map { id in agents.profiles.first { $0.id == id } } ?? homeAgent
            guard let agent else {
                actionErrorMessage = "That bot isn't on \(place) anymore."
                return
            }
            guard startsVoice else {
                openCanonicalAgentChat(agent.id)
                return
            }
            VoiceLaunchState.shared.update(agent: .init(id: agent.id, name: agent.name,
                                                        imageURL: agents.avatarURL(for: agent)))
            // Voice talks with the bot in its own Bot Chat.
            openCanonicalAgentChat(agent.id, startsVoice: true)
        }
    }

    func openFleetChat(_ chat: FleetChat) {
        openFleet(.chat(profileID: chat.profileID, storedSessionID: chat.storedSessionID,
                        appSessionID: chat.appSessionID), on: chat.hostID)
    }

    /// A chat's Rename or Archive from Chats. On the selected computer it goes
    /// through its sessions, as on its own Sessions screen; on another, straight to it.
    func changeFleetChat(_ chat: FleetChat, _ change: FleetChatChange) {
        guard let fleet else { return }
        Task { @MainActor in
            do {
                guard chat.hostID == fleet.selectedHostID else {
                    try await fleet.updateChat(chat, change)
                    return
                }
                let record: SessionRecord
                if let id = chat.appSessionID, let saved = sessionCatalog.session(id: id) {
                    record = saved
                } else {
                    record = try await sessionCatalog.resolveStoredSession(profileID: chat.profileID,
                                                                           storedSessionID: chat.storedSessionID)
                }
                switch change {
                case .rename(let title): try await sessionCatalog.renameSession(id: record.id, title: title)
                case .archive: try await sessionCatalog.archiveSession(id: record.id)
                }
            } catch is CancellationError {
            } catch {
                actionErrorMessage = switch change {
                case .rename: "bighelp couldn't rename this chat. Try again."
                case .archive: "bighelp couldn't archive this chat. Try again."
                }
            }
        }
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
            _ = home.takeNewChatHandoff(after: .refused)
            actionErrorMessage = "\(fleet.hostName(hostID)) is a sample computer in this demo."
            return
        }
        recordLiveFleet()
        let previous = fleet.selectedHostID
        // The tab stays: what opens is pushed over it on the other computer, so Back goes there.
        fleet.pendingOpen = FleetPendingOpen(hostID: hostID, open: open, returnHostID: previous)
        fleet.select(hostID)
        returnIfFleetHostDoesNotAnswer(hostID, previous: previous)
    }

    /// The header's computer menu on Today and Work: that computer becomes the one in use, with
    /// nothing to open there. One that doesn't answer gives the selection back, as a tapped bot's
    /// computer does, so neither the app nor its next launch is left on it.
    func selectFleetHost(_ hostID: UUID) {
        guard let fleet, hostID != fleet.selectedHostID else { return }
        recordLiveFleet()
        let previous = fleet.selectedHostID
        // A tap that waited for another computer is given up: the person picked this one.
        fleet.pendingOpen = nil
        _ = home.takeNewChatHandoff(after: .cancelled)
        fleet.select(hostID)
        returnIfFleetHostDoesNotAnswer(hostID, previous: previous, opensSomething: false)
    }

    /// Cancel on the opening loader: back to the computer the tap came from.
    func cancelPendingFleetOpen() {
        guard let fleet, let pending = fleet.pendingOpen else { return }
        fleet.pendingOpen = nil
        _ = home.takeNewChatHandoff(after: .cancelled)
        if let back = pending.returnHostID, fleet.selectedHostID == pending.hostID { fleet.select(back) }
    }

    /// A tapped agent's computer that doesn't answer gives the selection back to the one that
    /// worked, so the app (and its next launch) isn't left on a computer that's down, and
    /// the opening loader ends. The one that worked stays connected while
    /// every host shows, so going back is at once. `opensSomething`: a tap waits for this computer
    /// (`pendingOpen`), and it is ready once that can open. Without one (the header's computer
    /// menu) the wait is for the computer alone, and a connection is enough.
    private func returnIfFleetHostDoesNotAnswer(_ hostID: UUID, previous: UUID?, opensSomething: Bool = true) {
        guard let fleet, let previous, previous != hostID else { return }
        // With nothing to open, "still waited for" is "still the computer in use".
        let waitedFor: @MainActor () -> UUID? = { opensSomething ? fleet.pendingOpen?.hostID : hostID }
        Task { @MainActor in
            // Selecting it starts its connection; this makes sure an attempt runs now.
            await nativeWorkspaceStore?.reconnect()
            let wait = BighelpShortcutConnectionWait.Host(
                isWanted: { FleetSwitchFallback.isWaiting(for: hostID, pending: waitedFor(),
                                                         selected: fleet.selectedHostID) },
                isConnecting: { nativeWorkspaceStore?.isConnecting == true },
                isConnected: { nativeWorkspaceStore?.isConnected == true },
                isReady: { opensSomething ? isFleetHostReady : true },
                synchronize: {})
            let ready = (try? await BighelpShortcutConnectionWait.untilReady(wait, timeout: FleetSwitchFallback.timeout))
                ?? false
            guard FleetSwitchFallback.shouldReturn(ready: ready, waitingFor: hostID,
                                                   pending: waitedFor(),
                                                   selected: fleet.selectedHostID) else { return }
            fleet.pendingOpen = nil
            _ = home.takeNewChatHandoff(after: .unanswered)
            fleet.select(previous)
            actionErrorMessage = FleetSwitchFallback.message(unreachable: fleet.hostName(hostID),
                                                             stillOn: fleet.hostName(previous))
        }
    }

    /// The host a tap waited for is ready: open what was tapped.
    func openPendingFleetIfReady() {
        // A Live Activity or alert tap that switched computers waits for the same readiness.
        if isFleetHostReady, let open = BighelpExternalSessionOpenCenter.shared.pending, open.switchedHost != nil {
            openExternalSession(open)
        }
        guard let fleet, let pending = fleet.pendingOpen, pending.hostID == fleet.selectedHostID,
              isFleetHostReady else { return }
        fleet.pendingOpen = nil
        // The chat's own opening loader takes over from the computer's, with no gap.
        simpleBotsChatOpening.showsNextAtOnce = true
        performFleetOpen(pending.open)
        simpleBotsChatOpening.showsNextAtOnce = false
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

    /// Other hosts stay connected while every host's data is on screen, so opening an agent on one
    /// doesn't connect first. In the background they close with the selected host's connection, once
    /// the app has been away a while (`BighelpBackgroundGrace`), and connect again when it's back.
    var keepsFleetHostsConnected: Bool { showsEveryHost && hostRegistry != nil }

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
        // New chat's text and To row, if they came with the switch. Taken whatever opens, so
        // nothing else ever starts with them later.
        let handoff = home.takeNewChatHandoff(after: .opened)
        switch open {
        case .agent(let profileID):
            openAgentChat(profileID)
        case .newChat(let profileID):
            // New chat's pick of a bot on this computer came with the switch: its text and its To row.
            if let text = handoff?.text, !text.isEmpty { appState.leaveComposerText(text) }
            startNewChat(explicitAgentID: profileID, tracksNewChat: handoff?.followsPick == true,
                         // The chat is made: the box the text came from lets it go.
                         opened: { _ in handoff?.delivered() })
        case .chat(let profileID, let storedSessionID, let appSessionID):
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
                        actionErrorMessage = "This chat couldn't be opened. "
                            + (HermesRefusalMessage.sentence(in: error) ?? "Try again from Chats.")
                    }
                }
            }
        case .group(let roomID):
            guard let owner = currentWorkspaceOwner else { return }
            handleAgentWorkspaceAction(.init(owner: owner, action: .openGroup(roomID: roomID)))
        case .groupSettings(let roomID):
            guard let owner = currentWorkspaceOwner else { return }
            handleAgentWorkspaceAction(.init(owner: owner, action: .openGroupSettings(roomID: roomID)))
        case .newGroup(let profileIDs, let peers):
            let session = newChatSession
            createGroupChat(with: profileIDs, peers: peers, firstMessage: handoff?.text) { openedID in
                session.groupEnded()
                // The group chat has the text: the box it came from lets it go.
                if openedID != nil { handoff?.delivered() }
            }
        case .routines(let profileID):
            openScheduledTasks(filteredTo: profileID)
        case .botProfile(let profileID):
            appState.open(.simpleBotProfile(agentID: profileID))
        case .task(let jobID, let profileID):
            // The bot's routines, and the task over them.
            openScheduledTasks(filteredTo: profileID)
            openPrepared(.scheduledTask(id: jobID, agentID: profileID))
        }
    }

    // MARK: The selected host's live data

    /// What changes the selected host's part of the lists. Nil unless every computer shows, so
    /// nothing is computed then.
    struct LiveFleetKey: Equatable {
        let hostID: UUID
        let agents: [AgentProfile]
        let pinned: [String]
        let chats: [SessionSummary]
        let tasks: [ScheduledTask]
        let groups: [HermesBotModeRoomSummary]
    }

    var liveFleetKey: LiveFleetKey? {
        guard showsEveryHost, let hostID = fleet?.selectedHostID, isFleetHostReady else { return nil }
        return LiveFleetKey(
            hostID: hostID, agents: agents.profiles, pinned: agents.pinnedAgentIDs,
            chats: Array(sessionCatalog.recentSummaries(includeCronSessions: false)
                .filter { $0.kind == .direct }.prefix(80)),
            tasks: featureStore.scheduledTasks?.tasks ?? [],
            groups: botModeRooms.catalogRooms
        )
    }

    func recordLiveFleet() {
        guard let fleet, let key = liveFleetKey else { return }
        let chats = key.chats.compactMap { summary -> FleetChat? in
            guard let profileID = summary.agentIDs.first else { return nil }
            return FleetChat(
                hostID: key.hostID, profileID: profileID,
                storedSessionID: sessionCatalog.session(id: summary.id)?.remoteStoredID ?? summary.id,
                appSessionID: summary.id, title: summary.title, preview: summary.preview,
                updatedAt: summary.updatedAt, isActive: summary.isActive, origin: summary.origin,
                isPinned: summary.isPinned
            )
        }
        let agentRows = key.agents.map { profile in
            FleetAgent(hostID: key.hostID, profileID: profile.id, name: profile.name, role: profile.role,
                       avatarFile: fleet.liveAvatarFile(from: agents.avatarURL(for: profile)),
                       isPinned: key.pinned.contains(profile.id), isDefault: profile.isDefault,
                       activity: chats.contains { $0.profileID == profile.id && $0.isActive } ? .working : nil,
                       placement: profile.placement, look: profile.look)
        }
        let names = Dictionary(key.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let canDelete = botModeRooms.nativeCapabilities?.supports("groups.disband") == true
        let groups = key.groups.filter(\.canOpen).map { room in
            FleetGroup(hostID: key.hostID, roomID: room.roomID, name: room.name,
                       memberNames: room.members.map { names[$0.profile] ?? $0.handle },
                       updatedAt: room.updatedAt, isWorking: botModeRooms.room(id: room.roomID)?.isNativeWorking == true,
                       canRename: room.canRename, canDelete: canDelete, memberIDs: room.members.map(\.profile))
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

extension RootShellView {
    /// The computers changed: the home's lists and widgets' Gateway choice follow.
    func syncFleetHosts() {
        guard let fleet else { return }
        fleet.syncHosts()
        BighelpWidgetGatewayPublisher.publish(fleet.hosts)
    }

    /// Hosts, their names (a rename shows at once) and which is selected.
    var fleetHostsKey: [String] {
        guard let fleet else { return [] }
        return (hostRegistry?.hosts.map { $0.id.uuidString + "\u{1f}" + $0.name } ?? [])
            + [hostRegistry?.selectedHostID ?? fleet.selectedHostID].compactMap { $0?.uuidString }
    }
}

/// Keeps every computer's lists current: the selected host's live data, a tap
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
            .onChange(of: hostsKey, initial: true) { _, _ in syncHosts() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cancelReads() }
                // Back from the background: connect the other hosts again (and read the stale ones).
                if phase == .active, keepsConnected { setKeepsConnected(true) }
            }
            .onChange(of: keepsConnected, initial: true) { _, keep in setKeepsConnected(keep) }
    }
}

/// Sections made on another device (or in Hermes Desktop) that the gateway in use's own agents are
/// in, for the Bots view, which reads those agents live rather than from every host's copies.
struct FleetSectionAdoption: ViewModifier {
    let placements: [AgentListPlacement]
    let adopt: ([AgentListPlacement]) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: placements, initial: true) { _, placements in adopt(placements) }
    }
}
