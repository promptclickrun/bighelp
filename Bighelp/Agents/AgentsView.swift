import SwiftUI

@MainActor
struct AgentsView: View {
    let store: AgentDirectoryStore
    let runtimeDefaultsClient: any AgentRuntimeDefaultsClient
    let onSelect: (AgentProfile) -> Void
    let onOpenSessions: (AgentProfile) -> Void
    var onOpenHostStatus: (() -> Void)? = nil
    var hostRuntime: HostRuntimeStore? = nil
    var workspaceOwner: WorkspaceOwner? = nil
    var capabilities: WorkspaceCapabilities = .disconnected
    var botModeRooms: BotModeRoomStore? = nil
    var cloneClient: (any AgentProfileCloneClient)? = nil
    var shortcutsAvailable = false
    var onAction: (@MainActor (AgentWorkspaceActionRequest) -> Void)? = nil
    /// Set from elsewhere (the Chats rail's "Group chats") to show one agent's groups.
    var groupFilterRequest: Binding<String?> = .constant(nil)
    /// Set from all computers › New agent: opens the new-agent editor once this computer is connected.
    var createRequest: Binding<Bool> = .constant(false)

    @State private var query = ""
    @State private var groupPreferences = AgentGroupPreferences()
    @State private var showsArchivedGroups = false
    @State private var renameGroup: HermesBotModeRoomSummary?
    @State private var renameText = ""
    @State private var deleteGroup: HermesBotModeRoomSummary?
    @State private var groupFilterProfileID: String?
    @State private var areGroupsExpanded = true
    @State private var agentActions = AgentActions()
    @State private var actionAgent: AgentProfile?
    @Environment(\.agentDeletion) private var agentDeletion
    @State private var activeOwner: WorkspaceOwner?
    @State private var shownSignIn: WorkspaceSignIn?
    @State private var actionOwner: WorkspaceOwner?
    @State private var deferredAction: DeferredAgentAction?
    @State private var isSearchPresented = false
    /// A pinned agent is lifted: the list holds still while it moves.
    @State private var isArrangingPinned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleProfiles: [AgentProfile] {
        AgentDirectoryPresentation.visibleProfiles(store.profiles, query: query)
    }

    private var visibleGroups: [HermesBotModeRoomSummary] {
        AgentDirectoryPresentation.visibleGroups(
            botModeRooms?.catalogRooms ?? [], profiles: store.profiles,
            query: query, profileID: groupFilterProfileID
        )
    }

    private var groupScope: String { workspaceOwner?.cacheScopeID ?? "unavailable" }
    private func preference(_ group: HermesBotModeRoomSummary) -> AgentGroupPreferences.Entry {
        groupPreferences.entry(group.roomID, scope: groupScope)
    }
    private func togglePin(_ group: HermesBotModeRoomSummary) {
        var entry = preference(group); entry.pinned.toggle()
        groupPreferences.set(entry, id: group.roomID, scope: groupScope)
    }
    private func toggleArchive(_ group: HermesBotModeRoomSummary) {
        var entry = preference(group); entry.archived.toggle()
        groupPreferences.set(entry, id: group.roomID, scope: groupScope)
    }

    private var featured: AgentDirectoryPresentation.Featured {
        AgentDirectoryPresentation.featured(
            visible: visibleProfiles, pinnedIDs: store.pinnedAgentIDs, primaryID: store.primaryAgentID
        )
    }

    private var liveStates: [String: AgentLiveState] {
        guard let botModeRooms else { return [:] }
        return AgentLiveStatePresentation.agentStates(
            rooms: botModeRooms.catalogRooms, pendingApprovals: botModeRooms.pendingApprovals(roomID:)
        )
    }

    private func groupLiveState(_ group: HermesBotModeRoomSummary) -> AgentLiveState? {
        guard let botModeRooms else { return nil }
        return AgentLiveStatePresentation.groupState(
            isWorking: botModeRooms.nativeRoomIsWorking(roomID: group.roomID),
            hasPendingApprovals: !botModeRooms.pendingApprovals(roomID: group.roomID).isEmpty
        )
    }

    /// The featured grid is a browsing aid; searching and group filtering
    /// collapse the directory to plain results.
    private var showsFeatured: Bool {
        query.isEmpty && groupFilterProfileID == nil && !featured.profiles.isEmpty
    }

    /// A host with no agents cannot have useful group chats, so its first-run
    /// screen is just the friendly empty state.
    private var isDirectoryEmpty: Bool {
        query.isEmpty && groupFilterProfileID == nil && visibleProfiles.isEmpty && visibleGroups.isEmpty
            && store.errorMessage == nil && !store.isLoading && !store.isInitialLoadPending
    }

    var body: some View {
        GeometryReader { geometry in
            let states = liveStates
            List {
                if showsFeatured { featuredSection(states) }
                ForEach(
                    AgentDirectoryPresentation.sectionOrder(filteredToProfileID: groupFilterProfileID),
                    id: \.self
                ) { section in
                    switch section {
                    case .groups:
                        if !isDirectoryEmpty { groupsSection }
                    case .agents:
                        agentsSection(states)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDisabled(isArrangingPinned)
            .textCase(nil)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, max(0, (geometry.size.width - 760) / 2), for: .scrollContent)
            .contentMargins(.top, BighelpTokens.space4, for: .scrollContent)
            .contentMargins(.bottom, BighelpTokens.space24, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
            .dismissesKeyboardOnScroll(true)
            .accessibilityIdentifier("agents.screen")
            .searchable(text: $query, isPresented: $isSearchPresented,
                        placement: .navigationBarDrawer, prompt: "Search agents and groups")
            .toolbar {
                #if targetEnvironment(macCatalyst)
                // A Mac list can't be pulled down to refresh.
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    .keyboardShortcut("r")
                    .accessibilityIdentifier("agents.refresh")
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button("Create agent", systemImage: "plus", action: startCreating)
                        .disabled(!supports(.profilesCreate))
                        .accessibilityIdentifier("agents.create")
                }
            }
            .background(theme.canvas.ignoresSafeArea())
        }
        .onAppear {
            activeOwner = workspaceOwner
            if let workspaceOwner { shownSignIn = workspaceOwner.signIn }
        }
        .onChange(of: createRequest.wrappedValue, initial: true) { _, _ in startRequestedCreation() }
        .onChange(of: workspaceOwner?.signIn) { _, _ in startRequestedCreation() }
        .onChange(of: groupFilterRequest.wrappedValue, initial: true) { _, profileID in
            guard let profileID else { return }
            groupFilterRequest.wrappedValue = nil
            showGroups(of: profileID)
        }
        .onChange(of: workspaceOwner) { _, current in
            activeOwner = current
            // An actions sheet left open acts on the new connection.
            if let current, actionOwner?.signIn == current.signIn { actionOwner = current }
            // Disconnected, or back on the same computer and sign-in (bighelp
            // reconnects after you've been away): menus and dialogs stay open.
            guard let current, current.signIn != shownSignIn else { return }
            let previousScope = shownSignIn?.authority.cacheScopeID
            shownSignIn = current.signIn
            deferredAction = nil
            actionAgent = nil
            renameGroup = nil
            deleteGroup = nil
            if previousScope != current.cacheScopeID {
                groupPreferences = AgentGroupPreferences()
                query = ""
                showsArchivedGroups = false
                groupFilterProfileID = nil
            }
        }
        .task(id: workspaceOwner?.cacheScopeID) {
            guard Self.shouldBootstrapStoreRefresh(for: workspaceOwner) else { return }
            await store.loadIfNeededReportingErrors()
        }
        .task(id: workspaceOwner) {
            guard Self.shouldBootstrapStoreRefresh(for: workspaceOwner) else { return }
            if botModeRooms?.catalogState == .idle {
                await botModeRooms?.refreshNativeRoomCatalog()
            }
        }
        .refreshable { await refresh() }
        .sheet(item: $actionAgent, onDismiss: finishAgentActionSheet) { agent in
            AgentActionSheet(
                agent: agent,
                imageURL: store.avatarURL(for: agent),
                actions: actionItems(agent)
            ) { action in
                perform(action, profileID: agent.id, expectedOwner: actionOwner)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .bighelpSheetSize(.standard)
        }
        .alert("Rename group", isPresented: Binding(get: { renameGroup != nil }, set: { if !$0 { renameGroup = nil } })) {
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) { renameGroup = nil }
            Button("Rename") {
                if let group = renameGroup { dispatch(.renameGroup(roomID: group.roomID, name: renameText)) }
                renameGroup = nil
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete this group?", isPresented: Binding(get: { deleteGroup != nil }, set: { if !$0 { deleteGroup = nil } }), titleVisibility: .visible) {
            Button("Delete group", role: .destructive) {
                if let group = deleteGroup { dispatch(.deleteGroup(roomID: group.roomID)) }
                deleteGroup = nil
            }
        } message: { Text("This permanently deletes the group on Hermes and stops its active work.") }
        .agentActionsPresentation(agentActions, config: actionsConfig)
    }


    private func featuredSection(_ states: [String: AgentLiveState]) -> some View {
        let featured = featured
        return Section {
            AgentsSectionCaption(title: featured.isPinnedSelection ? "Pinned" : "Your agents")
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: BighelpTokens.space4, leading: BighelpTokens.space16,
                                          bottom: 0, trailing: BighelpTokens.space16))
                .listRowSeparator(.hidden)
            AgentPinnedGrid(
                agents: featured.profiles,
                canReorder: featured.isPinnedSelection,
                imageURL: avatarURL,
                liveState: { agent in states[agent.id] ?? .idle },
                isPrimary: isPrimary,
                open: openFeatured,
                manage: manage,
                reorder: reorderPinned,
                create: createAction,
                isArranging: $isArrangingPinned
            )
            .listRowInsets(EdgeInsets(top: BighelpTokens.space8, leading: BighelpTokens.space16,
                                      bottom: BighelpTokens.space16, trailing: BighelpTokens.space16))
            .listRowSeparator(.hidden)
        }
        .listRowBackground(theme.canvas)
        .listSectionSeparator(.hidden)
    }

    private var groupsSection: some View {
        let groups = visibleGroups.filter { preference($0).archived == showsArchivedGroups }
            .sorted { preference($0).pinned && !preference($1).pinned }
        return Section {
            groupsCaption
                .listRowInsets(EdgeInsets(top: BighelpTokens.space8, leading: BighelpTokens.space16,
                                          bottom: 0, trailing: BighelpTokens.space4))
                .listRowSeparator(.hidden)
            if canCreateGroup {
                AgentNewGroupRow { dispatch(.createGroup(seedProfileID: groupFilterProfileID)) }
                    .accessibilityIdentifier("agents.groups.create")
                    .listRowInsets(Self.rowInsets)
            }
            if areGroupsExpanded {
                if let profileID = groupFilterProfileID {
                    HStack {
                        Text("Groups with \(store.profiles.first(where: { $0.id == profileID })?.name ?? "this agent")")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.primaryText)
                        Spacer()
                        Button("Clear group filter", systemImage: "xmark.circle.fill") {
                            groupFilterProfileID = nil
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .accessibilityIdentifier("agents.groups.clear-filter")
                    }
                    .listRowInsets(Self.rowInsets)
                }
                groupStatus
                    .listRowInsets(Self.rowInsets)
                ForEach(groups) { group in
                    AgentGroupRowView(
                        group: group, profiles: store.profiles, avatarDirectory: store.avatarDirectory,
                        isPinned: preference(group).pinned, liveState: groupLiveState(group)
                    ) { dispatch(.openGroup(roomID: group.roomID)) }
                    .listRowInsets(Self.rowInsets)
                    .contextMenu {
                        Button("Open chat", systemImage: "bubble.left.and.bubble.right") {
                            dispatch(.openGroup(roomID: group.roomID))
                        }
                        Button(preference(group).pinned ? "Unpin" : "Pin", systemImage: "pin") { togglePin(group) }
                        Button("Rename", systemImage: "pencil") { renameText = group.name; renameGroup = group }
                            .disabled(!group.canRename)
                        Button(preference(group).archived ? "Unarchive" : "Archive", systemImage: "archivebox") { toggleArchive(group) }
                        Button("Group settings", systemImage: "slider.horizontal.3") {
                            dispatch(.openGroupSettings(roomID: group.roomID))
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteGroup = group }
                            .disabled(botModeRooms?.nativeCapabilities?.supports("groups.disband") != true)
                    }
                    .swipeActions(edge: .leading) {
                        Button(preference(group).pinned ? "Unpin" : "Pin", systemImage: "pin") { togglePin(group) }
                            .tint(theme.action)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteGroup = group }
                            .disabled(botModeRooms?.nativeCapabilities?.supports("groups.disband") != true)
                        Button(preference(group).archived ? "Unarchive" : "Archive", systemImage: "archivebox") { toggleArchive(group) }
                            .tint(theme.secondaryText)
                    }
                }
                if groups.isEmpty, !visibleGroups.isEmpty {
                    Text(showsArchivedGroups ? "No archived groups." : "No groups to show.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .listRowInsets(Self.rowInsets)
                }
                archivedGroupsRow
            }
        }
        .listRowBackground(theme.canvas)
        .listRowSeparatorTint(theme.separator)
        .listSectionSeparator(.hidden)
    }

    /// Like Mail's Archive: a full-width row after the list switches between
    /// current and archived group chats. Hidden when nothing is archived.
    @ViewBuilder
    private var archivedGroupsRow: some View {
        let archivedCount = visibleGroups.filter { preference($0).archived }.count
        if showsArchivedGroups || archivedCount > 0 {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: BighelpTokens.stateDuration)) {
                    showsArchivedGroups.toggle()
                }
            } label: {
                HStack(spacing: BighelpTokens.space12) {
                    Image(systemName: showsArchivedGroups ? "chevron.backward" : "archivebox")
                        .font(.bighelp(.body).weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 52)
                    Text(showsArchivedGroups ? "Back to group chats" : "Archived group chats (\(archivedCount))")
                        .font(.bighelp(.subheadline).weight(.medium))
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowInsets(Self.rowInsets)
            .accessibilityLabel(showsArchivedGroups ? "Show groups" : "Archived groups")
            .accessibilityValue(showsArchivedGroups ? "" : "\(archivedCount)")
            .accessibilityIdentifier("agents.groups.archived-toggle")
        }
    }

    private var groupsCaption: some View {
        HStack(spacing: BighelpTokens.space4) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration)) {
                    areGroupsExpanded.toggle()
                }
            } label: {
                HStack(spacing: BighelpTokens.space4) {
                    AgentsSectionCaption(title: showsArchivedGroups ? "Archived group chats" : "Group chats")
                    Image(systemName: areGroupsExpanded ? "chevron.down" : "chevron.right")
                        .font(.bighelp(.caption2).weight(.bold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            // Borderless, not plain: a plain button claims the whole list row, which
            // would swallow taps meant for the archive toggle beside it.
            .buttonStyle(.borderless)
            .accessibilityLabel(showsArchivedGroups ? "Archived group chats" : "Group chats")
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(areGroupsExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("agents.groups.disclosure")
            Spacer()
        }
    }

    @ViewBuilder
    private var groupStatus: some View {
        let state = botModeRooms?.catalogState ?? .unavailable("Connect to a compatible host to see its groups.")
        switch state {
        case .idle, .loading:
            ProgressView(visibleGroups.isEmpty ? "Loading groups" : "Refreshing groups")
                .accessibilityIdentifier("agents.groups.loading")
        case .unavailable(let message), .failed(let message):
            recovery(message, identifier: "agents.groups.error") {
                Task { await botModeRooms?.refreshNativeRoomCatalog() }
            }
        case .loaded:
            if visibleGroups.isEmpty {
                Text(query.isEmpty && groupFilterProfileID == nil ? "No groups yet." : "No matching groups.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("agents.groups.empty")
            }
        }
    }

    private func agentsSection(_ states: [String: AgentLiveState]) -> some View {
        Section {
            if !isDirectoryEmpty {
                AgentsSectionCaption(title: query.isEmpty ? "All agents" : "Agents")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: BighelpTokens.space16, leading: BighelpTokens.space16,
                                              bottom: BighelpTokens.space4, trailing: BighelpTokens.space16))
                    .listRowSeparator(.hidden)
            }
            if let error = store.errorMessage {
                recovery(error, identifier: "agents.load-error") {
                    Task { await store.loadReportingErrors() }
                }
                .listRowInsets(Self.rowInsets)
            }
            if (store.isLoading || store.isInitialLoadPending) && store.profiles.isEmpty {
                ProgressView(store.profiles.isEmpty ? "Loading agents" : "Refreshing agents")
                    .frame(maxWidth: .infinity)
                    .listRowInsets(Self.rowInsets)
                    .accessibilityIdentifier("agents.refreshing")
            } else if isDirectoryEmpty {
                AgentsEmptyStateView(canCreate: supports(.profilesCreate), onCreate: startCreating)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("agents.empty")
            } else if visibleProfiles.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? (store.errorMessage == nil ? "No agents yet" : "Agents unavailable") : "No matching agents",
                    systemImage: query.isEmpty ? "person.2" : "magnifyingglass",
                    description: Text(query.isEmpty ? "Agents on this host appear here." : "Try another name or description.")
                )
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("agents.empty")
            }
            ForEach(visibleProfiles) { agent in row(agent, liveState: states[agent.id] ?? .idle) }
        }
        .listRowBackground(theme.canvas)
        .listRowSeparatorTint(theme.separator)
        .listSectionSeparator(.hidden)
    }

    /// Rows sit directly on the canvas; separators start under the text
    /// column (16 + 52 + 12 = 80pt), like Messages.
    private static let rowInsets = EdgeInsets(
        top: 0, leading: BighelpTokens.space16, bottom: 0, trailing: BighelpTokens.space8
    )

    private func row(_ agent: AgentProfile, prefix: String = "agent", liveState: AgentLiveState = .idle) -> some View {
        let actions = actionItems(agent)
        let pin = actions.first { $0.action == .togglePin }
        let edit = actions.first { $0.action == .edit }
        return AgentRowView(
            agent: agent, imageURL: store.avatarURL(for: agent),
            isPrimary: store.isPrimary(agent.id), isPinned: store.isPinned(agent.id),
            canOpenChat: actions.first { $0.action == .openChat }?.isEnabled == true,
            onOpenChat: { perform(.openChat, profileID: agent.id, expectedOwner: workspaceOwner) },
            onManage: { actionOwner = workspaceOwner; actionAgent = agent },
            identifierPrefix: prefix,
            liveState: liveState
        )
        .listRowInsets(Self.rowInsets)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let pin {
                Button(pin.title, systemImage: pin.systemImage) {
                    perform(.togglePin, profileID: agent.id, expectedOwner: workspaceOwner)
                }
                .tint(theme.action)
                .disabled(!pin.isEnabled)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let delete = actions.first(where: { $0.action == .delete }) {
                Button("Delete", systemImage: delete.systemImage, role: .destructive) {
                    perform(.delete, profileID: agent.id, expectedOwner: workspaceOwner)
                }
                .disabled(!delete.isEnabled)
            }
            if let edit, !edit.isUnsupported {
                Button("Edit", systemImage: edit.systemImage) {
                    perform(.edit, profileID: agent.id, expectedOwner: workspaceOwner)
                }
                .tint(theme.action)
                .disabled(!edit.isEnabled)
            }
        }
        .contextMenu { agentContextMenu(agent) }
        .accessibilityAction(named: "Manage agent") {
            actionOwner = workspaceOwner
            actionAgent = agent
        }
    }

    private func refresh() async {
        await store.loadReportingErrors()
        await botModeRooms?.refreshNativeRoomCatalog()
    }

    private func avatarURL(_ agent: AgentProfile) -> URL? { store.avatarURL(for: agent) }
    private func isPrimary(_ agent: AgentProfile) -> Bool { store.isPrimary(agent.id) }
    private func reorderPinned(_ ids: [String]) { store.reorderPinnedAgents(ids) }
    private var createAction: (() -> Void)? { supports(.profilesCreate) ? { startCreating() } : nil }

    /// A pinned agent's chat, or its actions when it can't open one.
    private func openFeatured(_ agent: AgentProfile) {
        if actionItems(agent).first(where: { $0.action == .openChat })?.isEnabled == true {
            perform(.openChat, profileID: agent.id, expectedOwner: workspaceOwner)
        } else {
            manage(agent)
        }
    }

    /// That agent's actions, the same sheet as Manage agent.
    private func manage(_ agent: AgentProfile) {
        actionOwner = workspaceOwner
        actionAgent = agent
    }

    @ViewBuilder
    private func agentContextMenu(_ agent: AgentProfile) -> some View {
        AgentActionMenuItems(actions: agentActions, agent: agent, config: actionsConfig) { action in
            perform(action, profileID: agent.id, expectedOwner: workspaceOwner)
        }
    }

    private func recovery(_ message: String, identifier: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Try again", action: retry)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("\(identifier).retry")
                if onOpenHostStatus != nil || onAction != nil {
                    Button("Host status") {
                        if onAction != nil { dispatch(.openHostStatus) }
                        else { onOpenHostStatus?() }
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func actionItems(_ agent: AgentProfile) -> [AgentActionItem] {
        agentActions.items(agent, actionsConfig)
    }

    private var actionsConfig: AgentActionsConfig {
        AgentActionsConfig(store: store, runtimeDefaultsClient: runtimeDefaultsClient, owner: workspaceOwner,
                           capabilities: capabilities, cloneClient: cloneClient,
                           shortcutsAvailable: shortcutsAvailable, onAction: onAction, agentDeletion: agentDeletion)
    }

    private func supports(_ capability: WorkspaceCapability, profileID: String? = nil) -> Bool {
        guard let workspaceOwner else { return false }
        return capabilities.supports(capability, owner: workspaceOwner, profileID: profileID)
    }

    private func capabilityReason(_ capability: WorkspaceCapability, profileID: String?) -> String {
        guard let workspaceOwner else { return WorkspaceUnavailableReason.notConnected.message }
        return AgentActionsPresentation.unavailableMessage(
            capabilities.availability(for: capability, owner: workspaceOwner, profileID: profileID)
        ) ?? WorkspaceUnavailableReason.unsupportedOperation.message
    }

    private var canCreateGroup: Bool {
        onAction != nil && supports(.groupsCreate) && botModeRooms?.canCreateNativeRoom == true
    }

    /// Direct native runtime owns the initial agent and room refresh so a view
    /// mount cannot cancel its shared-store load or invalidate its catalog
    /// capability negotiation. Link and fixture presentations retain their
    /// view-owned bootstrap.
    nonisolated static func shouldBootstrapStoreRefresh(for owner: WorkspaceOwner?) -> Bool {
        owner?.authority.kind != .direct
    }

    private func perform(_ action: AgentRowMenuAction, profileID: String, expectedOwner: WorkspaceOwner?) {
        guard let owner = expectedOwner, owner == workspaceOwner, owner == activeOwner,
              let agent = store.profiles.first(where: { $0.id == profileID }),
              actionItems(agent).first(where: { $0.action == action })?.isEnabled == true else {
            agentActions.actionError = "This action is no longer available. Reopen the agent's actions to see its current status."
            return
        }
        if actionAgent != nil {
            deferredAction = DeferredAgentAction(action: action, profileID: profileID, owner: owner)
            actionAgent = nil
            return
        }
        actionAgent = nil
        if action == .groups {
            showGroups(of: profileID)
        } else {
            agentActions.perform(action, agent: agent, config: actionsConfig)
        }
    }

    private func showGroups(of profileID: String) {
        query = ""
        groupFilterProfileID = profileID
        areGroupsExpanded = true
    }

    private func finishDeferredAction() {
        guard let pending = deferredAction else { return }
        deferredAction = nil
        perform(pending.action, profileID: pending.profileID, expectedOwner: pending.owner)
    }

    private func finishAgentActionSheet() {
        finishDeferredAction()
    }

    private func dispatch(_ action: AgentWorkspaceAction) {
        guard let owner = workspaceOwner, owner == activeOwner, let onAction else {
            agentActions.actionError = "The host connection changed. Try opening this action again."
            return
        }

        onAction(AgentWorkspaceActionRequest(owner: owner, action: action))
    }

    /// The studio itself offers scratch, built-in and saved templates.
    private func startRequestedCreation() {
        guard createRequest.wrappedValue, workspaceOwner != nil else { return }
        createRequest.wrappedValue = false
        // The "which computer?" sheet is still closing; a sheet presented now would be dropped.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            startCreating()
        }
    }

    private func startCreating() {
        guard let owner = workspaceOwner, supports(.profilesCreate) else {
            agentActions.actionError = "Agent creation is not available on this connection."
            return
        }
        agentActions.editor = .creating(
            store: store,
            processor: AvatarImageProcessor(),
            profileCloneSupport: supports(.profilesClone)
                ? .nativeBundleOnly
                : .unavailable("Native profile cloning is not available on this connection."),
            isCurrent: { activeOwner?.signIn == owner.signIn }
        )
    }

    @BighelpThemeReader private var theme
}

private struct DeferredAgentAction {
    let action: AgentRowMenuAction
    let profileID: String
    let owner: WorkspaceOwner
}
