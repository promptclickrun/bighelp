import SwiftUI

/// Which host a row belongs to, shown only when there's more than one.
struct FleetHostTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.bighelp(.caption2).weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(theme.secondaryText.opacity(0.12), in: .capsule)
            .accessibilityLabel("on \(name)")
    }

    @BighelpThemeReader private var theme
}

extension FleetActivity {
    var liveState: AgentLiveState {
        switch self {
        case .working: .thinking
        case .waiting: .nudge
        }
    }
}

/// Filter chips: all hosts, or one. A host that couldn't be read says so.
struct FleetHostFilter: View {
    let fleet: FleetStore
    @Binding var selection: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BighelpTokens.space8) {
                chip("All hosts", isOn: selection == nil, id: "fleet.filter.all") { selection = nil }
                ForEach(fleet.hosts) { host in
                    chip(host.name, isOn: selection == host.id,
                         status: HostConnectionStatus(fleet: fleet.statuses[host.id], hostName: host.name),
                         id: "fleet.filter.\(host.name)") { selection = host.id }
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
        }
    }

    /// A host still loading or out of reach shows it; a reachable one stays plain.
    private func chip(_ title: String, isOn: Bool, status: HostConnectionStatus? = nil, id: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let status, status.phase != .connected {
                    BighelpConnectionIndicator(phase: status.phase, tint: isOn ? theme.actionForeground : nil)
                }
                Text(title).lineLimit(1)
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(isOn ? theme.actionForeground : theme.primaryText)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: 34)
            .background(isOn ? theme.action : theme.surface, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @BighelpThemeReader private var theme
}

/// One agent: its picture (with what it's doing), name, host, and its latest chat.
struct FleetAgentRow: View {
    let agent: FleetAgent
    let fleet: FleetStore

    var body: some View {
        let latest = fleet.latestChat(for: agent)
        HStack(spacing: BighelpTokens.space12) {
            AvatarView(stableID: agent.profileID, displayName: agent.name,
                       imageURL: fleet.avatars.url(for: agent.avatarFile), size: SessionRow.avatarSize,
                       state: agent.activity?.liveState)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    Text(agent.name)
                        .font(.bighelp(.callout).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if fleet.showsHostNames { FleetHostTag(name: fleet.hostName(agent.hostID)) }
                    Spacer(minLength: BighelpTokens.space4)
                    if let latest {
                        Text(SessionRow.compactTimestamp(latest.updatedAt))
                            .font(.bighelp(.footnote))
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                if !agent.role.isEmpty {
                    Text(agent.role)
                        .font(.bighelp(.footnote).weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Text(subtitle(latest))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ latest: FleetChat?) -> String {
        if let activity = agent.activity { return activity.liveState.label }
        if let latest {
            let preview = SessionPreviewText.plain(latest.preview)
            return preview.isEmpty ? latest.title : preview
        }
        return "Start a chat"
    }

    @BighelpThemeReader private var theme
}

/// All agents on all hosts: pick one and start working with it.
struct FleetHomeView: View {
    let fleet: FleetStore
    let onOpen: (FleetAgent) -> Void
    /// None while the selected host is still connecting.
    var onNewChat: (() -> Void)? = nil
    /// Pins or unpins an agent on its own host.
    var onSetPinned: ((FleetAgent, Bool) -> Void)? = nil
    /// Opens, renames or deletes a group chat. None hides group chats' actions.
    var onGroupAction: ((FleetGroup, FleetGroupAction) -> Void)? = nil
    /// The agent's routines: add, pause, resume or delete them there.
    var onOpenRoutines: ((FleetAgent) -> Void)? = nil
    /// New agent: asks which computer first.
    var onNewAgent: (() -> Void)? = nil
    /// The computer every all-hosts list is narrowed to; nil shows every computer.
    @Binding var hostFilter: UUID?
    /// Hidden agents show, dimmed, so they can be shown again. For this visit only.
    @State private var showsHidden = false
    @State private var namePrompt: FleetNamePrompt?
    @State private var deletingGroup: FleetGroup?
    @State private var deletedSection: FleetSectionDeletion?
    /// A pinned agent held and let go, where its menu can't open (visionOS,
    /// iOS before 17.4): its actions.
    @State private var managing: FleetAgent?
    @State private var search = ""
    @State private var isArrangingPinned = false

    var body: some View {
        let pinned = pinnedAgents
        let listed = listedAgents(excluding: Set(pinned.map(\.id)))
        List {
            if !pinned.isEmpty {
                Section {
                    pinnedRow(pinned)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if fleet.showsHostNames {
                Section {
                    FleetHostFilter(fleet: fleet, selection: $hostFilter)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            ForEach(blocks(listed)) { block in
                Section {
                    ForEach(block.items) { item in itemRow(item) }
                } header: {
                    blockHeader(block)
                }
            }
            Section {
                FleetHostNotes(fleet: fleet, hostFilter: hostFilter)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(isArrangingPinned)
        // The one main action, where a thumb rests: above the search bar, on the right.
        .overlay(alignment: .bottomTrailing) {
            if let onNewChat {
                RootComposeButton(identifier: "fleet.new-chat", size: 72, action: onNewChat)
                    .padding(.trailing, BighelpTokens.space20)
                    .padding(.bottom, BighelpTokens.space12)
            }
        }
        .toolbar {
            // Top right, in place of the one-host switch (☰ has that): new agent, sections, hidden agents.
            if onGroupAction != nil {
                ToolbarItem(placement: .topBarTrailing) { organizeMenu }
            }
        }
        .searchable(text: $search, prompt: "Search agents")
        .refreshable {
            fleet.refresh(force: true)
            await fleet.waitForReads()
        }
        .overlay {
            if fleet.agents().isEmpty, fleet.groups().isEmpty, !fleet.hosts.contains(where: { fleet.isReading($0.id) }) {
                ContentUnavailableView("No agents yet", systemImage: "person.2",
                                       description: Text("The agents on your hosts show up here."))
            }
        }
        .task { fleet.refresh() }
        .confirmationDialog(managing?.name ?? "", isPresented: Binding(
            get: { managing != nil }, set: { if !$0 { managing = nil } }), titleVisibility: .visible) {
            if let agent = managing {
                Button("Open chat") { onOpen(agent) }
                if let onSetPinned {
                    Button("Unpin") { onSetPinned(agent, false) }
                        .accessibilityIdentifier("fleet.pinned.unpin")
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .modifier(FleetListPrompts(fleet: fleet, namePrompt: $namePrompt, deletingGroup: $deletingGroup,
                                   deletedSection: $deletedSection, onGroupAction: onGroupAction))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.home")
    }

    /// Pinned agents up top, like favorites, when nothing is filtered.
    private var pinnedAgents: [FleetAgent] {
        guard search.isEmpty, hostFilter == nil else { return [] }
        return fleet.pinnedAgents().filter { showsHidden || !$0.isHidden }
    }

    private func listedAgents(excluding pinned: Set<String>) -> [FleetListItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let agents = fleet.agents(on: hostFilter).filter { agent in
            guard !pinned.contains(agent.id), showsHidden || !agent.isHidden else { return false }
            guard !query.isEmpty else { return true }
            return agent.name.localizedCaseInsensitiveContains(query)
                || agent.role.localizedCaseInsensitiveContains(query)
                || fleet.hostName(agent.hostID).localizedCaseInsensitiveContains(query)
        }
        guard onGroupAction != nil else { return agents.map(FleetListItem.agent) }
        let groups = fleet.groups(on: hostFilter).filter { group in
            query.isEmpty || group.name.localizedCaseInsensitiveContains(query)
                || group.memberNames.contains { $0.localizedCaseInsensitiveContains(query) }
                || fleet.hostName(group.hostID).localizedCaseInsensitiveContains(query)
        }
        return agents.map(FleetListItem.agent) + groups.map(FleetListItem.group)
    }

    /// Sections in the person's order, then everything not in one. While
    /// searching, empty sections step aside.
    private func blocks(_ items: [FleetListItem]) -> [FleetSectionBlock] {
        let all = FleetSectioning.blocks(items, sections: fleet.sections, groupSections: fleet.groupSectionIDs)
        guard search.isEmpty else { return all.filter { !$0.items.isEmpty } }
        return all
    }

    @ViewBuilder
    private func blockHeader(_ block: FleetSectionBlock) -> some View {
        if let section = block.section {
            let index = fleet.sections.firstIndex(of: section) ?? 0
            FleetSectionHeader(title: section.name, count: block.items.count,
                               onRename: { namePrompt = .renameSection(section) },
                               onDelete: { deletedSection = fleet.deleteSection(section.id) },
                               onMoveUp: index > 0 ? { fleet.moveSection(section.id, by: -1) } : nil,
                               onMoveDown: index < fleet.sections.count - 1 ? { fleet.moveSection(section.id, by: 1) } : nil)
        } else if !fleet.sections.isEmpty, !block.items.isEmpty {
            FleetSectionHeader(title: "Not in a section", count: block.items.count)
        }
    }

    /// New agent, new section, and showing hidden agents. New group chat is in New chat.
    private var organizeMenu: some View {
        Menu {
            if let onNewAgent {
                Button("New agent", systemImage: "person.badge.plus", action: onNewAgent)
                    .accessibilityIdentifier("fleet.organize.new-agent")
            }
            Button("New section", systemImage: "folder.badge.plus") { namePrompt = .newSection(filing: nil) }
                .accessibilityIdentifier("fleet.organize.new-section")
            let hidden = fleet.hiddenAgentCount
            if hidden > 0 || showsHidden {
                Toggle(isOn: $showsHidden) {
                    Label("Show hidden agents (\(hidden))", systemImage: "eye")
                }
                .accessibilityIdentifier("fleet.organize.show-hidden")
            }
        } label: {
            // Plus: it adds (an agent, a section), and it isn't New chat's compose button.
            Image(systemName: "plus").bighelpToolbarIcon()
        }
        .bighelpIconLabel("Add")
        .accessibilityHint("New agent, new section, hidden agents.")
        .accessibilityIdentifier("fleet.organize")
    }

    @ViewBuilder
    private func itemRow(_ item: FleetListItem) -> some View {
        switch item {
        case .agent(let agent): agentRow(agent)
        case .group(let group): groupRow(group)
        }
    }

    private func agentRow(_ agent: FleetAgent) -> some View {
        Button { onOpen(agent) } label: {
            FleetAgentRow(agent: agent, fleet: fleet)
                .opacity(agent.isHidden ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .contextMenu { TileMenuContent(items: agentMenu(agent)) }
        .accessibilityValue(agent.isHidden ? "Hidden" : "")
        .accessibilityIdentifier("fleet.agent.\(agent.name)")
    }

    /// An agent's long-press menu, the same for its row and its pinned tile.
    private func agentMenu(_ agent: FleetAgent) -> [TileMenuItem] {
        var items: [TileMenuItem] = []
        if let onSetPinned {
            items.append(TileMenuItem(title: agent.isPinned ? "Unpin" : "Pin",
                                      systemImage: agent.isPinned ? "pin.slash" : "pin",
                                      identifier: "fleet.agent.\(agent.isPinned ? "unpin" : "pin")") {
                onSetPinned(agent, !agent.isPinned)
            })
        }
        if let onOpenRoutines {
            let count = fleet.tasks(on: agent.hostID).filter { $0.profileID == agent.profileID }.count
            items.append(TileMenuItem(title: count == 0 ? "Routines" : "Routines (\(count))",
                                      systemImage: "clock.arrow.circlepath", identifier: "fleet.agent.routines") {
                onOpenRoutines(agent)
            })
        }
        if onGroupAction != nil {
            items.append(sectionMenu(current: fleet.section(of: agent), item: .agent(agent)) { id in
                Task { try? await fleet.file(agent, in: id) }
            })
            items.append(TileMenuItem(title: agent.isHidden ? "Show in list" : "Hide from list",
                                      systemImage: agent.isHidden ? "eye" : "eye.slash",
                                      identifier: "fleet.agent.\(agent.isHidden ? "unhide" : "hide")") {
                Task { try? await fleet.setHidden(agent, !agent.isHidden) }
            })
        }
        return items
    }

    private func groupRow(_ group: FleetGroup) -> some View {
        Button { onGroupAction?(group, .open) } label: { FleetGroupRow(group: group, fleet: fleet) }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .contextMenu {
                Button("Open chat", systemImage: "bubble.left.and.bubble.right") { onGroupAction?(group, .open) }
                TileMenuContent(items: [sectionMenu(current: fleet.section(of: group), item: .group(group)) {
                    fleet.file(group, in: $0)
                }])
                if group.hostID == fleet.selectedHostID {
                    Button("Rename", systemImage: "pencil") { namePrompt = .renameGroup(group) }
                        .disabled(!group.canRename)
                        .accessibilityIdentifier("fleet.group.rename")
                    Button("Delete", systemImage: "trash", role: .destructive) { deletingGroup = group }
                        .disabled(!group.canDelete)
                        .accessibilityIdentifier("fleet.group.delete")
                }
            }
            .accessibilityIdentifier("fleet.group.\(group.name)")
    }

    /// Move to a section, a new one, or out of the one it's in.
    private func sectionMenu(current: FleetSection?, item: FleetListItem,
                             file: @escaping (String?) -> Void) -> TileMenuItem {
        var choices = fleet.sections.map { section in
            TileMenuItem(title: section.name, systemImage: section.id == current?.id ? "checkmark" : "folder",
                         isEnabled: section.id != current?.id) { file(section.id) }
        }
        choices.append(TileMenuItem(title: "New section", systemImage: "folder.badge.plus",
                                    identifier: "fleet.move.new-section") { namePrompt = .newSection(filing: item) })
        if current != nil {
            choices.append(TileMenuItem(title: "Remove from section", systemImage: "folder.badge.minus",
                                        identifier: "fleet.move.remove") { file(nil) })
        }
        return TileMenuItem(title: "Move to section", systemImage: "folder", children: choices, identifier: "fleet.move")
    }

    /// Big pictures with the name and role, simple like a contact grid. Touch
    /// and hold one to drag it into a new place.
    private func pinnedRow(_ agents: [FleetAgent]) -> some View {
        PinnedArrangeGrid(
            items: agents,
            columns: PinnedAgentsLayout.columns,
            canReorder: true, space: "fleet.pinned", open: onOpen, manage: { managing = $0 },
            menu: { agentMenu($0) }, reorder: { fleet.reorderPinned($0) }, isArranging: $isArrangingPinned,
            identifier: { "fleet.pinned.\($0.name)" },
            tile: { agent, lifted in pinnedTile(agent, lifted: lifted) },
            trailing: { EmptyView() }
        )
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
    }

    private func pinnedTile(_ agent: FleetAgent, lifted: Bool) -> some View {
        PinnedAgentTileLabel(name: agent.name, isLifted: lifted) {
            AvatarView(stableID: agent.profileID, displayName: agent.name,
                       imageURL: fleet.avatars.url(for: agent.avatarFile), size: PinnedAgentsLayout.avatarSize,
                       state: agent.activity?.liveState)
        } detail: {
            if let role = AgentFeaturedTile.roleLine(agent.role) { Text(role) }
        }
        .accessibilityElement(children: .combine)
        // Once, with its computer like the rows say ("on Desk Hermes"); the picture also named it.
        .accessibilityLabel(pinnedLabel(agent))
    }

    private func pinnedLabel(_ agent: FleetAgent) -> String {
        let parts = [agent.name, AgentFeaturedTile.roleLine(agent.role),
                     fleet.showsHostNames ? "on \(fleet.hostName(agent.hostID))" : nil]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    @BighelpThemeReader private var theme
}

/// The list stays up while a tapped agent's host connects, with a note.
struct FleetConnectingView: View {
    let fleet: FleetStore
    @Binding var hostFilter: UUID?
    let onOpen: (FleetAgent) -> Void
    /// False once connecting stopped without a connection.
    let isConnecting: Bool
    let retry: () -> Void
    /// Failure shows only after an attempt; a switch starts connecting a moment later.
    @State private var hasTried = false

    var body: some View {
        let status = HostConnectionStatus(fleetSwitchTo: fleet.selectedHostID.map(fleet.hostName) ?? "your host",
                                          isConnecting: isConnecting, hasTried: hasTried)
        FleetHomeView(fleet: fleet, onOpen: onOpen, hostFilter: $hostFilter)
            .onChange(of: isConnecting, initial: true) { _, connecting in if connecting { hasTried = true } }
            .onChange(of: fleet.selectedHostID) { _, _ in hasTried = isConnecting }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: BighelpTokens.space8) {
                    BighelpConnectionIndicator(phase: status.phase)
                    Text(status.label)
                        .contentTransition(.opacity)
                    if status.phase == .disconnected {
                        Button("Try again", action: retry)
                            .buttonStyle(.borderless)
                    }
                }
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(theme.surface)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fleet.connecting")
            }
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .toolbar { BighelpHostsToolbarLink(registry: registry) }
    }

    @Environment(\.bighelpHostRegistry) private var registry
    @BighelpThemeReader private var theme
}

/// Hosts still loading or out of reach, at the bottom of a list.
struct FleetHostNotes: View {
    let fleet: FleetStore
    let hostFilter: UUID?

    var body: some View {
        ForEach(fleet.hosts.filter { hostFilter == nil || $0.id == hostFilter }) { host in
            if let status = HostConnectionStatus(fleet: fleet.statuses[host.id], hostName: host.name) {
                switch status.phase {
                case .disconnected:
                    HStack(spacing: BighelpTokens.space8) {
                        BighelpConnectionIndicator(phase: status.phase)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.label).font(.bighelp(.subheadline).weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                            if let reason = status.detailText {
                                Text(fleet.snapshots[host.id] == nil ? reason : "\(reason) Showing what it had last time.")
                                    .font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer(minLength: BighelpTokens.space8)
                        Button("Try again") { fleet.refresh(force: true) }
                            .font(.bighelp(.subheadline).weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("fleet.host-note.\(host.name)")
                case .connecting where fleet.snapshots[host.id] == nil:
                    HStack(spacing: BighelpTokens.space8) {
                        BighelpConnectionIndicator(phase: status.phase)
                        Text(status.label).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                    }
                    .listRowBackground(Color.clear)
                default:
                    EmptyView()
                }
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// Every chat on every host, newest first, each tagged with its host and where it started.
/// A computer's chip works on that computer the way one-computer mode does: its own Sessions
/// screen (projects, folders, pins), without leaving all hosts.
struct FleetChatsView: View {
    let fleet: FleetStore
    @Binding var hostFilter: UUID?
    @Binding var filter: FleetChatsFilter
    let onOpen: (FleetChat) -> Void
    /// The picked computer's own Sessions screen once it's the working computer; nil until then.
    var hostSessions: ((UUID) -> AnyView?)? = nil
    @State private var search = ""

    var body: some View {
        if let hostFilter, let sessions = hostSessions?(hostFilter) {
            sessions
                .safeAreaInset(edge: .top, spacing: 0) {
                    if fleet.showsHostNames {
                        FleetHostFilter(fleet: fleet, selection: $hostFilter)
                            .padding(.vertical, BighelpTokens.space4)
                            .background(BighelpThemeCanvas(theme: theme))
                    }
                }
        } else {
            mergedList
        }
    }

    private var mergedList: some View {
        let chats = visibleChats
        return List {
            if fleet.showsHostNames {
                FleetHostFilter(fleet: fleet, selection: $hostFilter)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(chats) { chat in
                Button { onOpen(chat) } label: { FleetChatRow(chat: chat, fleet: fleet) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("fleet.chat.\(chat.title)")
            }
            FleetHostNotes(fleet: fleet, hostFilter: hostFilter)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .dismissesKeyboardOnScroll(true, immediately: true)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        // The glass search bar along the bottom, as on All agents.
        .searchable(text: $search, prompt: "Search sessions")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { filterMenu } }
        .refreshable {
            fleet.refresh(force: true)
            await fleet.waitForReads()
        }
        .overlay {
            if chats.isEmpty {
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if filter.isActive {
                    ContentUnavailableView("No matching chats", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Try a different agent or place."))
                } else {
                    ContentUnavailableView("No sessions yet", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        .task { fleet.refresh() }
        .navigationTitle("All sessions")
        .accessibilityIdentifier("fleet.chats")
    }

    private var visibleChats: [FleetChat] { fleet.chats(on: hostFilter, matching: search, filter: filter) }

    /// The same filters as one computer's Sessions, for what every computer reports.
    /// Projects belong to one computer: pick its chip to group or filter by project.
    private var filterMenu: some View {
        let agents = fleet.agents(on: hostFilter).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let origins = fleet.origins(on: hostFilter)
        return Menu {
            Picker("Agent", selection: $filter.agentID) {
                Text("All agents").tag(String?.none)
                ForEach(agents) { agent in
                    Text(fleet.showsHostNames && hostFilter == nil ? "\(agent.name) · \(fleet.hostName(agent.hostID))" : agent.name)
                        .tag(Optional(agent.id))
                }
            }
            .accessibilityIdentifier("fleet.chats.filter.agent")
            if !origins.isEmpty {
                Picker("Started in", selection: $filter.origin) {
                    Text("Everywhere").tag(String?.none)
                    ForEach(origins, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .accessibilityIdentifier("fleet.chats.filter.origin")
            }
            if filter.isActive {
                Divider()
                Button("Clear Filters", systemImage: "arrow.counterclockwise") { filter = FleetChatsFilter() }
                    .accessibilityIdentifier("fleet.chats.filters.clear")
            }
        } label: {
            Image(systemName: filter.isActive
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .accessibilityLabel("Filter chats")
        .accessibilityIdentifier("fleet.chats.filters")
    }

    @BighelpThemeReader private var theme
}

/// A chat in the all-hosts lists: who it's with, its host, title and when.
struct FleetChatRow: View {
    let chat: FleetChat
    let fleet: FleetStore
    var compact = false

    var body: some View {
        let agent = fleet.agent(hostID: chat.hostID, profileID: chat.profileID)
        HStack(spacing: BighelpTokens.space12) {
            AvatarView(stableID: chat.profileID, displayName: agent?.name ?? "Agent",
                       imageURL: fleet.avatars.url(for: agent?.avatarFile), size: compact ? 30 : SessionRow.avatarSize,
                       state: chat.isActive ? .thinking : nil)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    Text(chat.title.isEmpty ? "New chat" : chat.title)
                        .font(compact ? .body : .callout.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: BighelpTokens.space4)
                    Text(SessionRow.compactTimestamp(chat.updatedAt))
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                HStack(spacing: 6) {
                    Text(agent?.name ?? "Agent")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    if fleet.showsHostNames { FleetHostTag(name: fleet.hostName(chat.hostID)) }
                    if !compact { SessionOriginTag(source: chat.origin, size: 11) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// Scheduled tasks on every host, each tagged with its host.
struct FleetTasksView: View {
    let fleet: FleetStore
    @Binding var hostFilter: UUID?
    let onOpen: (FleetTask) -> Void

    var body: some View {
        List {
            if fleet.showsHostNames {
                FleetHostFilter(fleet: fleet, selection: $hostFilter)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(fleet.tasks(on: hostFilter)) { task in
                Button { onOpen(task) } label: { row(task) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("fleet.task.\(task.name)")
            }
            FleetHostNotes(fleet: fleet, hostFilter: hostFilter)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            fleet.refresh(force: true)
            await fleet.waitForReads()
        }
        .overlay {
            if fleet.tasks(on: hostFilter).isEmpty {
                ContentUnavailableView("No scheduled tasks", systemImage: "calendar.badge.clock",
                                       description: Text("Ask an agent to check in or remind you, and it shows up here."))
            }
        }
        .task { fleet.refresh() }
        .accessibilityIdentifier("fleet.tasks")
    }

    private func row(_ task: FleetTask) -> some View {
        let agent = fleet.agent(hostID: task.hostID, profileID: task.profileID)
        return HStack(spacing: BighelpTokens.space12) {
            AvatarView(stableID: task.profileID, displayName: agent?.name ?? "Agent",
                       imageURL: fleet.avatars.url(for: agent?.avatarFile), size: 44,
                       state: task.status == .failed ? .nudge : nil)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BighelpTokens.space8) {
                    Text(task.name)
                        .font(.bighelp(.callout).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if fleet.showsHostNames { FleetHostTag(name: fleet.hostName(task.hostID)) }
                }
                Text([agent?.name, task.schedule].compactMap { $0 }.joined(separator: " · "))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                Text(ScheduledTaskCopy.shortNextRun(status: task.status, nextRun: task.nextRun))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(task.status == .failed ? theme.danger : theme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, BighelpTokens.space4)
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// Asks which host a host-only screen (Settings, Projects…) should open for.
struct FleetHostPicker: View {
    let fleet: FleetStore
    let destination: FleetDestination
    var appPage: ((SettingsMenuSection) -> AnyView)?
    let onPick: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            List {
                if destination == .settings, let maintenance = fleet.maintenance() {
                    Section {
                        NavigationLink {
                            FleetSettingsView(store: maintenance, appPage: appPage)
                                .onAppear { detent = .large }
                        } label: {
                            HStack(spacing: BighelpTokens.space12) {
                                BighelpIconTile(systemName: "square.stack.3d.up.fill", tint: Color(hex: "5B6B7F"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Fleet settings")
                                        .font(.bighelp(.body).weight(.semibold))
                                        .foregroundStyle(theme.primaryText)
                                    Text("Update and restart every host, together or one by one")
                                        .font(.bighelp(.footnote))
                                        .foregroundStyle(theme.secondaryText)
                                }
                            }
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                        }
                        .accessibilityIdentifier("fleet.gate.fleet-settings")
                    }
                }
                Section {
                    ForEach(fleet.hosts) { host in
                        Button { onPick(host.id) } label: {
                            HStack(spacing: BighelpTokens.space12) {
                                BighelpIconTile(systemName: "desktopcomputer")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .font(.bighelp(.body).weight(.semibold))
                                        .foregroundStyle(theme.primaryText)
                                    Text(detail(host))
                                        .font(.bighelp(.footnote))
                                        .foregroundStyle(theme.secondaryText)
                                }
                                Spacer(minLength: BighelpTokens.space8)
                                Image(systemName: "chevron.right")
                                    .font(.bighelp(.footnote).weight(.semibold))
                                    .foregroundStyle(theme.tertiaryText)
                            }
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("fleet.gate.host.\(host.name)")
                    }
                } footer: {
                    Text("\(destination.title) belongs to one host. Pick which one.")
                }
            }
            .navigationTitle(destination.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("fleet.gate.cancel")
                        .bighelpToolbarText()
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .bighelpSheetSize(.standard)
        .accessibilityIdentifier("fleet.gate")
    }

    private func detail(_ host: FleetHost) -> String {
        let agents = fleet.snapshots[host.id]?.agents.count
        let count = agents.map { $0 == 1 ? "1 agent" : "\($0) agents" }
        var unreachable: String?
        if case .unreachable = fleet.statuses[host.id] { unreachable = "Couldn't reach it just now" }
        return [host.isSelected ? "Open now" : nil, count, unreachable].compactMap { $0 }.joined(separator: " · ")
    }

    @BighelpThemeReader private var theme
}

/// New chat in the all-hosts view: pick any agent on any host. Group chat
/// turns it into picking several agents from one host.
struct FleetAgentPicker: View {
    let fleet: FleetStore
    let onPick: (FleetAgent) -> Void
    /// Starts a group chat with the picked agents. None hides Group chat.
    var onPickGroup: (([FleetAgent]) -> Void)? = nil
    @State private var search = ""
    @State private var isPickingGroup = false
    /// Picked agents, in the order they were tapped.
    @State private var picked: [FleetAgent] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(agents) { agent in row(agent) }
                } header: {
                    if isPickingGroup { groupHeader }
                }
            }
            .searchable(text: $search, prompt: "Search agents")
            .navigationTitle(isPickingGroup ? "New group chat" : "New chat with…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("fleet.new-chat.cancel")
                        .bighelpToolbarText()
                }
                if let onPickGroup {
                    ToolbarItem(placement: .confirmationAction) {
                        if isPickingGroup {
                            Button("Create chat") { onPickGroup(picked) }
                                .fontWeight(.semibold)
                                .disabled(!(2...BotModeRoom.maximumMembers).contains(picked.count))
                                .bighelpDefaultAction()
                                .accessibilityIdentifier("fleet.new-chat.create-group")
                                .bighelpToolbarText()
                        } else {
                            Button("Group chat") { withAnimation(.snappy(duration: 0.2)) { isPickingGroup = true } }
                                .accessibilityHint("Pick several agents for one chat.")
                                .accessibilityIdentifier("fleet.new-chat.group")
                                .bighelpToolbarText()
                        }
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bighelpSheetSize(.standard)
    }

    private func row(_ agent: FleetAgent) -> some View {
        let isPicked = picked.contains { $0.id == agent.id }
        let isAvailable = !isPickingGroup || isPicked || canAdd(agent)
        return Button { tap(agent) } label: {
            HStack(spacing: BighelpTokens.space12) {
                AvatarView(stableID: agent.profileID, displayName: agent.name,
                           imageURL: fleet.avatars.url(for: agent.avatarFile), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: BighelpTokens.space8) {
                        Text(agent.name).font(.bighelp(.body).weight(.semibold)).foregroundStyle(theme.primaryText)
                        if fleet.showsHostNames { FleetHostTag(name: fleet.hostName(agent.hostID)) }
                    }
                    if !agent.role.isEmpty {
                        Text(agent.role).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isPickingGroup {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .font(.bighelp(.title3))
                        .foregroundStyle(isPicked ? theme.action : theme.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
            .opacity(isAvailable ? 1 : 0.4)
        }
        .bighelpPlainButtonStyle()
        .disabled(!isAvailable)
        .accessibilityValue(isPickingGroup ? (isPicked ? "Selected" : "Not selected") : "")
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("fleet.new-chat.\(agent.name)")
    }

    /// How many are picked, and why another host's agents can't join.
    private var groupHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(picked.count < 2 ? "Pick 2 to \(BotModeRoom.maximumMembers) agents"
                 : "\(picked.count) of \(BotModeRoom.maximumMembers) picked")
                .monospacedDigit()
            if fleet.showsHostNames {
                Text(picked.first.map { "Agents on \(fleet.hostName($0.hostID)) can join." }
                     ?? "Everyone in a group chat is on the same host.")
            }
        }
        .font(.bighelp(.footnote))
        .textCase(nil)
        .foregroundStyle(theme.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.new-chat.group-note")
    }

    /// A group chat lives on one host, and holds a few agents at most.
    private func canAdd(_ agent: FleetAgent) -> Bool {
        guard picked.count < BotModeRoom.maximumMembers else { return false }
        return picked.first.map { $0.hostID == agent.hostID } ?? true
    }

    private func tap(_ agent: FleetAgent) {
        guard isPickingGroup else { return onPick(agent) }
        if let index = picked.firstIndex(where: { $0.id == agent.id }) {
            picked.remove(at: index)
        } else if canAdd(agent) {
            picked.append(agent)
        }
    }

    private var agents: [FleetAgent] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return fleet.agents().filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    @BighelpThemeReader private var theme
}
