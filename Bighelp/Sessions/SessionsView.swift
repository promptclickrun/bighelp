import SwiftUI

enum SessionsPresentation {
    enum LoadingMode: Equatable {
        case none
        case fullScreen
        case inline
    }

    static func loadingMode(
        loadState: SessionsModel.LoadState,
        hasSessions: Bool
    ) -> LoadingMode {
        if loadState == .loading {
            return hasSessions ? .inline : .fullScreen
        }
        if loadState == .idle, !hasSessions {
            return .fullScreen
        }
        return .none
    }
}

@MainActor
struct SessionsView: View {
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private enum ActionDialog {
        case rename(SessionSummary)
        case delete(SessionSummary)
        case error(String)
    }

    @State private var model: SessionsModel
    @State private var actionDialog: ActionDialog?
    @State private var renameDraft = ""
    @State private var mutatingSessionIDs = Set<String>()
    @State private var draggedSessionSectionKey: SessionSectionKey?
    @State private var lastSessionSectionDropTargetKey: SessionSectionKey?
    @State private var mutationSuccesses = 0
    @State private var mutationFailures = 0
    let agents: AgentDirectoryStore
    let settings: SettingsStore
    let organizeByProjects: Bool
    let sessionOrganizationAccountID: String?
    let sessionOrganizationHostID: String?
    /// Starts a new chat, optionally with a specific agent. Nil hides quick-start affordances.
    let onStartChat: ((String?) -> Void)?
    /// Starts a Hermes hosted group chat (Bot Mode). Nil when the host can't create rooms.
    let onNewGroupChat: (() -> Void)?
    let onSelect: (SessionSummary) -> Void
    /// The Agents list's hold menu for the "Your agents" rail.
    var agentActionsConfig: AgentActionsConfig? = nil
    @State private var agentActions = AgentActions()
    /// Codex and Claude Code chats on this computer, and what identifies that list; nil hides them.
    let otherApps: (source: any OtherAppChatsSource, id: String)?
    /// Opens a chat brought in from another app, by its Hermes session ID.
    let onOpenBroughtIn: ((String) -> Void)?
    @State private var otherAppsStore: OtherAppChatsStore?
    @State private var otherAppsStoreID: String?
    /// The Hermes, Codex or Claude Code choice, shared with All sessions; nil keeps it here.
    let sharedAppFilter: Binding<SessionAppFilter>?
    /// A Codex or Claude Code chat to preview once the list is there (picked on All sessions).
    let requestedOtherAppChat: Binding<HermesForeignSessionItem?>?

    init(
        model: SessionsModel,
        agents: AgentDirectoryStore,
        settings: SettingsStore,
        organizeByProjects: Bool = false,
        sessionOrganizationAccountID: String? = nil,
        sessionOrganizationHostID: String? = nil,
        onStartChat: ((String?) -> Void)? = nil,
        onNewGroupChat: (() -> Void)? = nil,
        onSelect: @escaping (SessionSummary) -> Void,
        agentActionsConfig: AgentActionsConfig? = nil,
        otherApps: (source: any OtherAppChatsSource, id: String)? = nil,
        onOpenBroughtIn: ((String) -> Void)? = nil,
        appFilter: Binding<SessionAppFilter>? = nil,
        requestedOtherAppChat: Binding<HermesForeignSessionItem?>? = nil
    ) {
        self.otherApps = otherApps
        self.sharedAppFilter = appFilter
        self.requestedOtherAppChat = requestedOtherAppChat
        self.onOpenBroughtIn = onOpenBroughtIn
        self.onNewGroupChat = onNewGroupChat
        model.showsCronSessions = settings.showCronSessions
        _model = State(initialValue: model)
        self.agents = agents
        self.settings = settings
        self.organizeByProjects = organizeByProjects
        self.sessionOrganizationAccountID = sessionOrganizationAccountID
        self.sessionOrganizationHostID = sessionOrganizationHostID
        self.onStartChat = onStartChat
        self.onSelect = onSelect
        self.agentActionsConfig = agentActionsConfig
    }

    /// Same as holding an agent in Agents; "Group chats" opens that list filtered.
    private func performAgentAction(_ action: AgentRowMenuAction, agent: AgentProfile, config: AgentActionsConfig) {
        guard action == .groups else {
            agentActions.perform(action, agent: agent, config: config)
            return
        }
        guard let owner = config.owner, let onAction = config.onAction else { return }
        onAction(AgentWorkspaceActionRequest(owner: owner, action: .openAgentGroups(profileID: agent.id)))
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if uiV3Enabled {
                nativeDirectory(model: model)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                        if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Searching loaded chats")
                                .bighelpFont(.metadata)
                                .foregroundStyle(theme.tertiaryText)
                                .accessibilityIdentifier("sessions.search-scope")
                        }
                        DisclosureGroup("Advanced filters") {
                            filters(model: model)
                        }
                        .tint(theme.secondaryText)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("sessions.filters")
                        content(model: model)
                    }
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.vertical, BighelpTokens.space24)
                    .bighelpShellContentWidth()
                }
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.large)
        // The glass search bar along the bottom, as on All agents.
        .searchable(text: $model.query, prompt: "Search sessions")
        .toolbar {
            #if targetEnvironment(macCatalyst)
            // A Mac list can't be pulled down to refresh.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .keyboardShortcut("r")
                .accessibilityIdentifier("sessions.refresh")
            }
            #endif
            if uiV3Enabled {
                ToolbarItem(placement: .topBarTrailing) {
                    nativeFilterMenu(model: model)
                }
            }
        }
        .accessibilityIdentifier("sessions.screen")
        .sensoryFeedback(.success, trigger: mutationSuccesses)
        .sensoryFeedback(.error, trigger: mutationFailures)
        .task {
            model.synchronizeHostedRooms()
            if model.loadState == .idle {
                await model.load()
            }
        }
        .refreshable {
            await model.load()
        }
        .onDisappear {
            model.didLeaveScreen()
            resetSectionDrag()
        }
        .onChange(of: sessionOrganizationAccountID) { _, _ in resetSectionDrag() }
        .onChange(of: sessionOrganizationHostID) { _, _ in resetSectionDrag() }
        .onChange(of: organizeByProjects) { _, _ in resetSectionDrag() }
        .onChange(of: settings.showCronSessions) { _, value in
            model.showsCronSessions = value
        }
        .onChange(of: renameDraft) { _, value in
            if value.count > SessionTitleRules.maximumLength {
                renameDraft = String(value.prefix(SessionTitleRules.maximumLength))
            }
        }
        .alert(
            actionDialogTitle,
            isPresented: actionDialogIsPresented,
            presenting: actionDialog
        ) { dialog in
            switch dialog {
            case .rename(let session):
                TextField("Session name", text: $renameDraft)
                    .accessibilityIdentifier("sessions.rename-field")
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    performMutation(sessionID: session.id) {
                        try await model.renameSession(id: session.id, title: renameDraft)
                    }
                }
                .accessibilityIdentifier("sessions.rename-save")
            case .delete(let session):
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    performMutation(sessionID: session.id) {
                        try await model.deleteSession(id: session.id)
                    }
                }
                .accessibilityIdentifier("sessions.delete-confirm")
            case .error:
                Button("OK", role: .cancel) {}
            }
        } message: { dialog in
            switch dialog {
            case .rename:
                Text("Enter a name up to \(SessionTitleRules.maximumLength) characters.")
            case .delete(let session):
                Text("Delete “\(session.title)” permanently? This cannot be undone.")
            case .error(let message):
                Text(message)
            }
        }
        .agentActionsPresentation(agentActions, config: agentActionsConfig)
        .task(id: OtherAppsKey(id: otherApps?.id, app: model.appFilter)) {
            guard let otherApps else {
                otherAppsStore = nil
                otherAppsStoreID = nil
                return
            }
            let store: OtherAppChatsStore
            if let current = otherAppsStore, otherAppsStoreID == otherApps.id {
                store = current
            } else {
                store = OtherAppChatsStore(source: otherApps.source)
                otherAppsStore = store
                otherAppsStoreID = otherApps.id
            }
            guard model.appFilter.showsOtherAppChats else { return }
            await store.load(app: model.appFilter.foreignSource)
        }
        .task(id: RequestedPreviewKey(item: requestedOtherAppChat?.wrappedValue?.id, list: otherAppsStoreID)) {
            guard let request = requestedOtherAppChat, let item = request.wrappedValue,
                  let store = otherAppsStore else { return }
            request.wrappedValue = nil
            await store.showPreview(item)
        }
        .onAppear {
            if let sharedAppFilter, sharedAppFilter.wrappedValue != model.appFilter {
                model.appFilter = sharedAppFilter.wrappedValue
            }
        }
        .onChange(of: model.appFilter) { _, filter in
            if let sharedAppFilter, sharedAppFilter.wrappedValue != filter { sharedAppFilter.wrappedValue = filter }
        }
        .bighelpSheet(isPresented: Binding(get: { otherAppsStore?.preview != nil },
                                    set: { if !$0 { otherAppsStore?.closePreview() } })) {
            if let store = otherAppsStore, let preview = store.preview {
                OtherAppChatPreviewSheet(preview: preview, isWorking: store.isWorking, onOpen: {
                    Task { @MainActor in
                        if let id = await store.bringIn() { onOpenBroughtIn?(id) }
                    }
                }, onCancel: { store.closePreview() })
            }
        }
        .alert("Codex and Claude Code", isPresented: Binding(get: { otherAppsStore?.errorMessage != nil },
                                                           set: { if !$0 { otherAppsStore?.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(otherAppsStore?.errorMessage ?? "")
        }
    }

    /// Chats in Codex and Claude Code on this computer, after this computer's own. One tap
    /// shows the start; Open brings it into Hermes as a chat here.
    @ViewBuilder
    private func otherAppsSection(model: SessionsModel) -> some View {
        if let store = otherAppsStore, onOpenBroughtIn != nil, model.appFilter.showsOtherAppChats {
            let items = otherAppItems(store, model: model)
            if !items.isEmpty {
                Section {
                    sectionCaption(otherAppsCaption(model.appFilter))
                        .accessibilityIdentifier("sessions.section.other-apps")
                        .modifier(SessionCaptionRow())
                    ForEach(items) { item in
                        Button { Task { await store.showPreview(item) } } label: { OtherAppChatRow(item: item) }
                            .buttonStyle(.plain)
                            .disabled(store.isWorking)
                            .listRowInsets(rowInsets)
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("sessions.other-app.\(item.title)")
                    }
                    if store.nextOffset != nil, !isSearching(model) {
                        Button("Show more") { Task { await store.loadMore() } }
                            .font(.bighelp(.subheadline).weight(.semibold))
                            .tint(theme.action)
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("sessions.other-apps.more")
                    }
                }
                .listSectionSeparator(.hidden)
            }
        }
    }

    private func nativeDirectory(model: SessionsModel) -> some View {
        @Bindable var model = model
        return List {
            if showsAppFilter(model) {
                SessionAppFilterBar(selection: $model.appFilter)
                    .listRowInsets(EdgeInsets(top: BighelpTokens.space4, leading: BighelpTokens.space16,
                                              bottom: BighelpTokens.space8, trailing: BighelpTokens.space16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if isSearching(model) {
                Text("Search covers chats already loaded on this device.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("sessions.search-scope")
            } else if let onStartChat, showsAgentStrip(model) {
                agentStrip(onStartChat, activeAgentIDs: activeAgentIDs(model))
            }
            nativeContent(model: model)
            otherAppsSection(model: model)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .dismissesKeyboardOnScroll(true, immediately: true)
        .background(theme.canvas)
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
    }

    /// Hermes, Codex and Claude Code, once there's a list to choose from.
    private func showsAppFilter(_ model: SessionsModel) -> Bool {
        model.hasLoadedSessions || model.appFilter != .all || !(otherAppsStore?.items.isEmpty ?? true)
    }

    /// Chats still in Codex or Claude Code under the app chosen, matching the search.
    private func otherAppItems(_ store: OtherAppChatsStore, model: SessionsModel) -> [HermesForeignSessionItem] {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.items.filter {
            model.appFilter.includes(source: $0.source)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
    }

    private func otherAppsCaption(_ filter: SessionAppFilter) -> String {
        switch filter {
        case .codex: "In Codex"
        case .claudeCode: "In Claude Code"
        case .all, .hermes: "In Codex and Claude Code"
        }
    }

    private func isSearching(_ model: SessionsModel) -> Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Landscape iPhone keeps its short viewport for the chats themselves;
    /// the tab bar's compose button still starts a chat.
    private func showsAgentStrip(_ model: SessionsModel) -> Bool {
        onStartChat != nil && !isSearching(model) && model.hasLoadedSessions
            && !agents.profiles.isEmpty && verticalSizeClass != .compact
    }

    /// Agents with a running chat in the catalog. This is the only live signal
    /// the session summaries carry, so every other agent reads as idle.
    private func activeAgentIDs(_ model: SessionsModel) -> Set<String> {
        Set(model.filteredSections.flatMap(\.sessions).filter(\.isActive).flatMap(\.agentIDs))
    }

    private func nativeFilterMenu(model: SessionsModel) -> some View {
        @Bindable var model = model
        @Bindable var settings = self.settings
        // Each filter is its own labeled submenu that shows its current choice, so
        // the menu reads as four short questions instead of one long list.
        return Menu {
            Section("Filter by") {
                Picker(selection: $model.typeFilter) {
                    ForEach(SessionTypeFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                } label: {
                    Label("Type", systemImage: "bubble.left.and.bubble.right")
                    Text(model.typeFilter.title)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("sessions.filter.type")

                Picker(selection: $model.agentFilter) {
                    Text("All agents").tag(SessionAgentFilter.all)
                    ForEach(model.availableAgents, id: \.id) { agent in
                        Text(agent.name).tag(SessionAgentFilter.agent(agent.id))
                    }
                } label: {
                    Label("Agent", systemImage: "person.crop.circle")
                    Text(agentFilterTitle(model.agentFilter, model: model))
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("sessions.filter.agent")

                Picker(selection: $model.projectFilter) {
                    Text("All projects").tag(SessionProjectFilter.all)
                    ForEach(model.availableProjects) { project in
                        Text(project.name).tag(SessionProjectFilter.project(project))
                    }
                    Text("Unassigned").tag(SessionProjectFilter.unassigned)
                    if case .project(let selected) = model.projectFilter,
                       !model.availableProjects.contains(selected) {
                        Text("Unavailable: \(selected.name)").tag(model.projectFilter)
                    }
                } label: {
                    Label("Project", systemImage: "folder")
                    Text(projectFilterTitle(model.projectFilter))
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("sessions.filter.project")

                if !model.availableOrigins.isEmpty {
                    Picker(selection: $model.originFilter) {
                        Text("Everywhere").tag(SessionOriginFilter.all)
                        ForEach(model.availableOrigins, id: \.self) { label in
                            Text(label).tag(SessionOriginFilter.origin(label))
                        }
                    } label: {
                        Label("Started in", systemImage: "arrow.down.app")
                        Text(model.originFilter.title)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("sessions.filter.origin")
                }
            }

            if hasActiveFilters(model) {
                Section {
                    Button("Clear Filters", systemImage: "arrow.counterclockwise") {
                        model.typeFilter = .all
                        model.agentFilter = .all
                        model.projectFilter = .all
                        model.originFilter = .all
                    }
                    .accessibilityIdentifier("sessions.filters.clear")
                }
            }

            // List options that used to live only in Settings.
            Section("View") {
                Toggle("Group by Project", systemImage: "folder.badge.gearshape", isOn: $settings.organizeChatsByProjects)
                    .accessibilityIdentifier("sessions.options.organize-by-projects")
                Toggle("Show Scheduled Runs", systemImage: "calendar.badge.clock", isOn: $settings.showCronSessions)
                    .accessibilityIdentifier("sessions.options.show-cron-sessions")
            }
        } label: {
            Image(systemName: hasActiveFilters(model)
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .accessibilityLabel("Filter chats")
        .accessibilityValue(filterAccessibilityValue(model))
        .accessibilityIdentifier("sessions.filters")
    }

    @ViewBuilder
    private func nativeContent(model: SessionsModel) -> some View {
        switch model.loadState {
        case .loading:
            // A refresh keeps the loaded list in place (the pull-to-refresh control
            // already reports progress); only a first load shows placeholder rows.
            if model.hasLoadedSessions {
                nativeLoadedContent(model: model)
            } else {
                nativeLoadingPlaceholder
            }
        case .failed(let message):
            Section {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await model.load() } }
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .tint(theme.action)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .padding(.vertical, BighelpTokens.space4)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listSectionSeparator(.hidden)
            .accessibilityIdentifier("sessions.failure")
            if model.hasLoadedSessions { nativeLoadedContent(model: model) }
        case .idle:
            if model.hasLoadedSessions {
                nativeLoadedContent(model: model)
            } else {
                nativeLoadingPlaceholder
            }
        case .loaded:
            nativeLoadedContent(model: model)
        }
    }

    /// "Your agents": one tap starts a chat with that agent; the dashed tile
    /// starts a chat with the default agent.
    private func agentStrip(_ start: @escaping (String?) -> Void, activeAgentIDs: Set<String>) -> some View {
        Section {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                sectionCaption("Your agents")
                    .padding(.horizontal, BighelpTokens.space16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: BighelpTokens.space16) {
                        ForEach(agents.profiles) { profile in
                            let state: AgentLiveState = activeAgentIDs.contains(profile.id) ? .thinking : .idle
                            Button { start(profile.id) } label: {
                                agentStripTile(name: profile.name) {
                                    AvatarView(
                                        stableID: profile.id,
                                        displayName: profile.name,
                                        imageURL: agents.avatarURL(for: profile),
                                        size: 56,
                                        state: state
                                    )
                                }
                            }
                            .buttonStyle(.bighelpTilePress)
                            .contextMenu {
                                if let agentActionsConfig {
                                    AgentActionMenuItems(actions: agentActions, agent: profile, config: agentActionsConfig) { action in
                                        performAgentAction(action, agent: profile, config: agentActionsConfig)
                                    }
                                }
                            }
                            .accessibilityLabel("New chat with \(profile.name)")
                            .accessibilityValue(state == .idle ? "" : state.label)
                            .accessibilityIdentifier("sessions.start-with.\(profile.id)")
                        }

                        Button { start(nil) } label: {
                            agentStripTile(name: "New") {
                                Circle()
                                    .strokeBorder(
                                        theme.primaryText.opacity(0.3),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                                    )
                                    .frame(width: 56, height: 56)
                                    .overlay {
                                        Image(systemName: "plus")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(theme.secondaryText)
                                    }
                            }
                        }
                        .buttonStyle(.bighelpTilePress)
                        .accessibilityLabel("New chat")
                        .accessibilityIdentifier("sessions.start-with.new")

                        if let onNewGroupChat {
                            Button(action: onNewGroupChat) {
                                agentStripTile(name: "Group") {
                                    Circle()
                                        .strokeBorder(
                                            theme.primaryText.opacity(0.3),
                                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                                        )
                                        .frame(width: 56, height: 56)
                                        .overlay {
                                            Image(systemName: "person.3.fill")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(theme.secondaryText)
                                        }
                                }
                            }
                            .buttonStyle(.bighelpTilePress)
                            .accessibilityLabel("New group chat")
                            .accessibilityIdentifier("sessions.start-with.group")
                        }
                    }
                    .padding(.horizontal, BighelpTokens.space16)
                    .padding(.vertical, BighelpTokens.space4)
                }
            }
            .padding(.top, BighelpTokens.space4)
            .padding(.bottom, BighelpTokens.space8)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listSectionSeparator(.hidden)
        .accessibilityIdentifier("sessions.start-with")
    }

    private func agentStripTile(name: String, @ViewBuilder avatar: () -> some View) -> some View {
        VStack(spacing: 6) {
            avatar()
            Text(name)
                .font(.system(size: stripNameSize))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(width: 64)
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
    }

    private var nativeLoadingPlaceholder: some View {
        Section {
            ForEach(0..<6, id: \.self) { index in
                // One VoiceOver stop announces the load; the rest are decorative.
                SessionRowPlaceholder(index: index)
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading chats")
                    .accessibilityHidden(index != 0)
                    .accessibilityIdentifier(index == 0 ? "sessions.loading" : "")
            }
        }
        .listSectionSeparator(.hidden)
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: BighelpTokens.space8 + 2,
            leading: BighelpTokens.space16,
            bottom: BighelpTokens.space8 + 2,
            trailing: BighelpTokens.space16
        )
    }

    @ViewBuilder
    private func nativeLoadedContent(model: SessionsModel) -> some View {
        let unorderedSections = model.filteredSections(organizeByProjects: organizeByProjects)
        let availableProjectKeys = unorderedSections.map(\.key).filter(\.isReorderable)
        let layout = settings.sessionSectionLayout(
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID,
            availableProjectKeys: availableProjectKeys
        )
        let sections = model.filteredSections(
            organizeByProjects: organizeByProjects,
            projectOrder: layout.projectOrder
        )

        if !model.hasLoadedSessions {
            Section {
                SessionsGettingStartedView(onStart: onStartChat.map { start -> () -> Void in { start(nil) } })
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("sessions.empty")
            }
            .listSectionSeparator(.hidden)
        } else if sections.isEmpty, let store = otherAppsStore, model.appFilter != .all, model.appFilter.showsOtherAppChats,
                  !otherAppItems(store, model: model).isEmpty {
            // Only chats still in Codex or Claude Code: their own section says so.
            EmptyView()
        } else if sections.isEmpty {
            Section {
                ContentUnavailableView(
                    model.appFilter.emptyTitle,
                    systemImage: model.appFilter == .all || model.appFilter == .hermes ? "magnifyingglass" : "chevron.left.forwardslash.chevron.right",
                    description: Text(emptyDescription(model))
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("sessions.empty-results")
            }
            .listSectionSeparator(.hidden)
        } else {
            // Captions sit in plain rows (not sticky List headers) so they share
            // the canvas instead of a system header bar.
            let showsRecentCaption = sections.count > 1 || showsAgentStrip(model)
            ForEach(sections) { section in
                if section.key == .pinned {
                    Section {
                        sectionCaption(section.title)
                            .accessibilityIdentifier("sessions.section.pinned")
                            .modifier(SessionCaptionRow())
                        nativePinnedGrid(section.sessions, model: model)
                            .listRowInsets(EdgeInsets(
                                top: BighelpTokens.space4,
                                leading: BighelpTokens.space16,
                                bottom: BighelpTokens.space12,
                                trailing: BighelpTokens.space16
                            ))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .listSectionSeparator(.hidden)
                } else {
                    Section {
                        if section.key != .sessions || showsRecentCaption {
                            sectionHeader(section, availableProjectKeys: layout.projectOrder)
                                .modifier(SessionCaptionRow())
                        }
                        if !layout.isCollapsed(section.key) {
                            ForEach(section.sessions) { session in
                                nativeSessionButton(session, model: model)
                            }
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
            }
        }
    }

    private func nativePinnedGrid(_ sessions: [SessionSummary], model: SessionsModel) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: BighelpTokens.space12, alignment: .top),
                count: dynamicTypeSize.isAccessibilitySize ? 2 : 3
            ),
            alignment: .center,
            spacing: BighelpTokens.space12
        ) {
            ForEach(sessions) { session in
                let state: AgentLiveState = session.isActive ? .thinking : .idle
                // A Menu with a primary action, not .contextMenu: the grid is one
                // List row, and a row shows the first context menu in it for
                // every tile, so holding one chat offered another chat's Delete.
                Menu {
                    sessionActions(session, model: model)
                } label: {
                    VStack(spacing: 5) {
                        SessionIdentityView(session: session, agents: agents, size: 64, state: state)
                        Text(session.title)
                            .font(.system(size: pinnedTitleSize, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                        if state != .idle {
                            AgentLiveStateLabel(state: state, font: .system(size: sectionCaptionSize))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .top)
                    .contentShape(.rect)
                } primaryAction: {
                    onSelect(session)
                }
                .menuStyle(.button)
                .buttonStyle(.bighelpTilePress)
                .menuIndicator(.hidden)
                .disabled(mutatingSessionIDs.contains(session.id))
                #if targetEnvironment(macCatalyst)
                // A Mac opens that menu only on click and hold; right-click is the habit there.
                .overlay { MacTileMenu(items: { macPinnedMenu(session, model: model) }).accessibilityHidden(true) }
                #endif
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pinned chat, \(session.title)")
                .accessibilityValue(state == .idle ? "" : state.label)
                .accessibilityIdentifier("session.pin.\(session.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned chats")
        .accessibilityIdentifier("sessions.pinned-grid")
    }

    private func nativeSessionButton(_ session: SessionSummary, model: SessionsModel) -> some View {
        Button { onSelect(session) } label: {
            SessionRow(session: session, agents: agents)
        }
        .buttonStyle(.plain)
        .disabled(mutatingSessionIDs.contains(session.id))
        .listRowInsets(rowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.separator)
        .alignmentGuide(.listRowSeparatorLeading) { _ in SessionRow.textLeading }
        .contextMenu { sessionActions(session, model: model) }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if model.canManageConversation(session) {
                Button {
                    performMutation(sessionID: session.id) {
                        try await model.setSessionPinned(id: session.id, pinned: !session.isPinned)
                    }
                } label: {
                    Label(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin")
                }
                .tint(theme.action)
                .accessibilityIdentifier("session.swipe.pin.\(session.id)")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if model.canManageConversation(session) {
                if model.canDeleteConversation {
                    Button(role: .destructive) {
                        actionDialog = .delete(session)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("session.swipe.delete.\(session.id)")
                }
                Button {
                    performMutation(sessionID: session.id) {
                        try await model.archiveSession(id: session.id)
                    }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.indigo)
                .accessibilityIdentifier("session.swipe.archive.\(session.id)")
            }
        }
    }

    /// Brand section caption: 11pt bold, letterspaced, uppercase, muted.
    private func sectionCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: sectionCaptionSize, weight: .bold))
            .tracking(sectionCaptionSize * 0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func sessionActions(_ session: SessionSummary, model: SessionsModel) -> some View {
        if model.canManageConversation(session) {
            Button {
                renameDraft = session.title
                actionDialog = .rename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .accessibilityIdentifier("session.action.rename.\(session.id)")

            Button {
                performMutation(sessionID: session.id) {
                    try await model.setSessionPinned(id: session.id, pinned: !session.isPinned)
                }
            } label: {
                Label(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            .accessibilityIdentifier("session.action.pin.\(session.id)")

            Button {
                performMutation(sessionID: session.id) {
                    try await model.archiveSession(id: session.id)
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .accessibilityIdentifier("session.action.archive.\(session.id)")

            if model.canDeleteConversation {
                Divider()
                Button(role: .destructive) {
                    actionDialog = .delete(session)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("session.action.delete.\(session.id)")
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    /// `sessionActions` as a pinned tile's right-click menu (see `MacTileMenu`).
    private func macPinnedMenu(_ session: SessionSummary, model: SessionsModel) -> [MacTileMenu.Item] {
        guard model.canManageConversation(session), !mutatingSessionIDs.contains(session.id) else { return [] }
        var items = [
            MacTileMenu.Item(title: "Rename", systemImage: "pencil") {
                renameDraft = session.title
                actionDialog = .rename(session)
            },
            MacTileMenu.Item(title: session.isPinned ? "Unpin" : "Pin",
                             systemImage: session.isPinned ? "pin.slash" : "pin") {
                performMutation(sessionID: session.id) {
                    try await model.setSessionPinned(id: session.id, pinned: !session.isPinned)
                }
            },
            MacTileMenu.Item(title: "Archive", systemImage: "archivebox") {
                performMutation(sessionID: session.id) {
                    try await model.archiveSession(id: session.id)
                }
            },
        ]
        if model.canDeleteConversation {
            items.append(MacTileMenu.Item(title: "Delete", systemImage: "trash", isDestructive: true, startsGroup: true) {
                actionDialog = .delete(session)
            })
        }
        return items
    }
    #endif

    private func filters(model: SessionsModel) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Menu {
                Button("All agents") { model.agentFilter = .all }
                ForEach(model.availableAgents, id: \.id) { agent in
                    Button(agent.name) { model.agentFilter = .agent(agent.id) }
                }
            } label: {
                Label(agentFilterTitle(model.agentFilter, model: model), systemImage: "person.2")
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            .accessibilityLabel("Agent filter")
            .accessibilityValue(agentFilterTitle(model.agentFilter, model: model))
            .accessibilityIdentifier("sessions.filter.agent")

            Menu {
                Button("All projects") { model.projectFilter = .all }
                ForEach(model.availableProjects) { project in
                    Button(project.name) { model.projectFilter = .project(project) }
                        .accessibilityIdentifier("sessions.filter.project.\(project.projectID)")
                }
                Button("Unassigned") { model.projectFilter = .unassigned }
            } label: {
                Label(projectFilterTitle(model.projectFilter), systemImage: "folder")
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            .accessibilityLabel("Project filter")
            .accessibilityValue(projectFilterTitle(model.effectiveProjectFilter))
            .accessibilityIdentifier("sessions.filter.project")

            if !model.availableOrigins.isEmpty {
                Menu {
                    Button("Everywhere") { model.originFilter = .all }
                    ForEach(model.availableOrigins, id: \.self) { label in
                        Button(label) { model.originFilter = .origin(label) }
                    }
                } label: {
                    Label(model.originFilter.title, systemImage: "arrow.down.left.square")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.primaryText)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .accessibilityLabel("Started in filter")
                .accessibilityValue(model.originFilter.title)
                .accessibilityIdentifier("sessions.filter.origin")
            }

            Picker("Type", selection: Bindable(model).typeFilter) {
                ForEach(SessionTypeFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("sessions.filter.type")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func content(model: SessionsModel) -> some View {
        switch model.loadState {
        case .loading:
            if SessionsPresentation.loadingMode(
                loadState: model.loadState,
                hasSessions: model.hasLoadedSessions
            ) == .fullScreen {
                BighelpThinkingOrb(
                    scenario: .searching,
                    visibleLabel: "Loading sessions"
                )
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .accessibilityIdentifier("sessions.loading")
            } else {
                ProgressView("Refreshing sessions")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("sessions.refreshing")
                loadedContent(model: model)
            }
        case .failed(let message):
            BighelpShellSection {
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    Text(message)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.primaryText)
                    Button("Retry") {
                        Task { await model.load() }
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            }
            .accessibilityIdentifier("sessions.failure")
            if uiV2Enabled && model.hasLoadedSessions {
                loadedContent(model: model)
            }
        case .idle:
            if SessionsPresentation.loadingMode(
                loadState: model.loadState,
                hasSessions: model.hasLoadedSessions
            ) == .fullScreen {
                BighelpThinkingOrb(
                    scenario: .searching,
                    visibleLabel: "Loading sessions"
                )
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .accessibilityIdentifier("sessions.loading")
            } else {
                loadedContent(model: model)
            }
        case .loaded:
            loadedContent(model: model)
        }
    }

    @ViewBuilder
    private func loadedContent(model: SessionsModel) -> some View {
        let unorderedSections = model.filteredSections(organizeByProjects: organizeByProjects)
        let availableProjectKeys = unorderedSections.map(\.key).filter(\.isReorderable)
        let layout = settings.sessionSectionLayout(
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID,
            availableProjectKeys: availableProjectKeys
        )
        let sections = model.filteredSections(
            organizeByProjects: organizeByProjects,
            projectOrder: layout.projectOrder
        )
        if !model.hasLoadedSessions {
            emptyState(
                title: "No sessions yet",
                detail: "Your durable conversations will appear here after you send a message.",
                identifier: "sessions.empty"
            )
        } else if sections.isEmpty {
            emptyState(
                title: "No matching sessions",
                detail: "Try a different keyword, agent, project, or type.",
                identifier: "sessions.empty-results"
            )
        } else {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    if !uiV3Enabled || section.key != .sessions || sections.count > 1 {
                        sectionHeader(
                            section,
                            availableProjectKeys: layout.projectOrder
                        )
                    }
                    if !layout.isCollapsed(section.key) {
                        BighelpShellSection {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(section.sessions.enumerated()), id: \.element.id) { index, session in
                                    Button {
                                        onSelect(session)
                                    } label: {
                                        SessionRow(session: session, agents: agents)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(mutatingSessionIDs.contains(session.id))
                                    .contextMenu {
                                        if model.canManageConversation(session) {
                                            Button {
                                                renameDraft = session.title
                                                actionDialog = .rename(session)
                                            } label: {
                                                Label("Rename", systemImage: "pencil")
                                            }
                                            .accessibilityIdentifier("session.action.rename.\(session.id)")

                                            Button {
                                                performMutation(sessionID: session.id) {
                                                    try await model.setSessionPinned(
                                                        id: session.id,
                                                        pinned: !session.isPinned
                                                    )
                                                }
                                            } label: {
                                                Label(
                                                    session.isPinned ? "Unpin" : "Pin",
                                                    systemImage: session.isPinned ? "pin.slash" : "pin"
                                                )
                                            }
                                            .accessibilityIdentifier("session.action.pin.\(session.id)")

                                            Button {
                                                performMutation(sessionID: session.id) {
                                                    try await model.archiveSession(id: session.id)
                                                }
                                            } label: {
                                                Label("Archive", systemImage: "archivebox")
                                            }
                                            .accessibilityIdentifier("session.action.archive.\(session.id)")

                                            if model.canDeleteConversation {
                                                Divider()
                                                Button(role: .destructive) {
                                                    actionDialog = .delete(session)
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                                .accessibilityIdentifier("session.action.delete.\(session.id)")
                                            }
                                        }
                                    }
                                    if index < section.sessions.count - 1 {
                                        Divider().padding(.vertical, BighelpTokens.space12)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(
        _ section: SessionDaySection,
        availableProjectKeys: [SessionSectionKey]
    ) -> some View {
        if section.isReorderable {
            HStack(spacing: BighelpTokens.space4) {
                Button {
                    let collapsed = settings.sessionSectionPreferences(
                        accountID: sessionOrganizationAccountID,
                        hostID: sessionOrganizationHostID
                    ).isCollapsed(section.key)
                    withAnimation(reduceMotion ? nil : .snappy(duration: BighelpTokens.transitionDuration)) {
                        settings.setSessionSectionCollapsed(
                            !collapsed,
                            sectionKey: section.key,
                            accountID: sessionOrganizationAccountID,
                            hostID: sessionOrganizationHostID
                        )
                    }
                } label: {
                    HStack(spacing: BighelpTokens.space8) {
                        sectionCaption(section.title)
                        Image(systemName: "chevron.right")
                            .font(.system(size: sectionCaptionSize, weight: .bold))
                            .foregroundStyle(theme.tertiaryText)
                            .rotationEffect(.degrees(isSectionCollapsed(section) ? 0 : 90))
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityValue(isSectionCollapsed(section) ? "Collapsed" : "Expanded")
                .accessibilityIdentifier("sessions.section-toggle.\(section.key.rawValue)")

                sectionReorderMenu(
                    section,
                    availableProjectKeys: availableProjectKeys
                )
                .foregroundStyle(theme.tertiaryText)
            }
            .onDrop(
                of: SessionSectionDragPayload.contentTypes,
                delegate: SessionSectionDropDelegate(
                    targetKey: section.key,
                    draggedKey: $draggedSessionSectionKey,
                    lastDropTargetKey: $lastSessionSectionDropTargetKey,
                    move: { source, target in
                        moveSection(
                            source,
                            to: target,
                            availableProjectKeys: availableProjectKeys
                        )
                    }
                )
            )
        } else {
            HStack(spacing: BighelpTokens.space8) {
                // The catch-all section reads as "Recent", matching Messages.
                sectionCaption(section.key == .sessions ? "Recent" : section.title)
                if section.key == .active {
                    BighelpThinkingOrb(scenario: .working, scale: .inline, tint: theme.action)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sessions.section.\(section.key.rawValue)")
        }
    }

    private func sectionReorderMenu(
        _ section: SessionDaySection,
        availableProjectKeys: [SessionSectionKey]
    ) -> some View {
        let index = availableProjectKeys.firstIndex(of: section.key)
        return SessionSectionReorderHandle(
            title: section.title,
            identifier: "sessions.section-reorder.\(section.key.rawValue)",
            canMoveUp: index.map { $0 > 0 } ?? false,
            canMoveDown: index.map { $0 + 1 < availableProjectKeys.count } ?? false,
            move: { moveSection(section, direction: $0, availableProjectKeys: availableProjectKeys) },
            drag: {
                draggedSessionSectionKey = section.key
                lastSessionSectionDropTargetKey = nil
                return SessionSectionDragPayload.provider(for: section.key)
            }
        )
    }

    private func resetSectionDrag() {
        draggedSessionSectionKey = nil
        lastSessionSectionDropTargetKey = nil
    }

    private func isSectionCollapsed(_ section: SessionDaySection) -> Bool {
        settings.sessionSectionPreferences(
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID
        ).isCollapsed(section.key)
    }

    private func moveSection(
        _ section: SessionDaySection,
        direction: SessionSectionMoveDirection,
        availableProjectKeys: [SessionSectionKey]
    ) {
        settings.moveSessionSection(
            section.key,
            direction: direction,
            availableProjectKeys: availableProjectKeys,
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID
        )
    }

    private func moveSection(
        _ sectionKey: SessionSectionKey,
        to targetKey: SessionSectionKey,
        availableProjectKeys: [SessionSectionKey]
    ) {
        settings.moveSessionSection(
            sectionKey,
            to: targetKey,
            availableProjectKeys: availableProjectKeys,
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID
        )
    }

    private func emptyState(title: String, detail: String, identifier: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "clock.arrow.circlepath")
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .accessibilityIdentifier(identifier)
    }

    private func agentFilterTitle(_ filter: SessionAgentFilter, model: SessionsModel) -> String {
        switch filter {
        case .all: "All agents"
        case .agent(let id): model.availableAgents.first(where: { $0.id == id })?.name ?? "Unavailable agent"
        }
    }

    private func emptyDescription(_ model: SessionsModel) -> String {
        switch model.appFilter {
        case .codex where !isSearching(model): "Chats from Codex on this computer show here."
        case .claudeCode where !isSearching(model): "Chats from Claude Code on this computer show here."
        default: "Try a different keyword, agent, project, or type."
        }
    }

    private func hasActiveFilters(_ model: SessionsModel) -> Bool {
        model.typeFilter != .all || model.agentFilter != .all || model.projectFilter != .all
            || model.originFilter != .all
    }

    private func filterAccessibilityValue(_ model: SessionsModel) -> String {
        guard hasActiveFilters(model) else { return "All sessions" }
        return [
            model.typeFilter.title,
            agentFilterTitle(model.agentFilter, model: model),
            projectFilterTitle(model.projectFilter),
            model.originFilter.title,
        ].joined(separator: ", ")
    }

    private var actionDialogTitle: String {
        switch actionDialog {
        case .rename: "Rename chat"
        case .delete: "Delete chat?"
        case .error: "Chat update failed"
        case nil: ""
        }
    }

    private var actionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { actionDialog != nil },
            set: { if !$0 { actionDialog = nil } }
        )
    }

    private func performMutation(
        sessionID: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard mutatingSessionIDs.insert(sessionID).inserted else { return }
        Task { @MainActor in
            defer { mutatingSessionIDs.remove(sessionID) }
            do {
                try await operation()
                mutationSuccesses += 1
            } catch is CancellationError {
                return
            } catch SessionCatalogError.invalidTitle {
                mutationFailures += 1
                actionDialog = .error(
                    "Enter a session name between 1 and \(SessionTitleRules.maximumLength) characters."
                )
            } catch {
                mutationFailures += 1
                actionDialog = .error("bighelp could not update this session. Try again.")
            }
        }
    }

    private func projectFilterTitle(_ filter: SessionProjectFilter) -> String {
        switch filter {
        case .all: "All projects"
        case .project(let project): project.name
        case .unassigned: "Unassigned"
        }
    }

    @BighelpThemeReader private var theme
    @ScaledMetric(relativeTo: .caption2) private var sectionCaptionSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var stripNameSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var pinnedTitleSize: CGFloat = 13

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// A caption row inside the plain list: no separator, no row chrome.
private struct SessionCaptionRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(
                top: BighelpTokens.space12,
                leading: BighelpTokens.space16,
                bottom: 0,
                trailing: BighelpTokens.space8
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// What the Codex and Claude Code list reads: its computer and agent, and the app chosen.
private struct OtherAppsKey: Equatable {
    let id: String?
    let app: SessionAppFilter
}

/// A chat to preview, and the list that can show it.
private struct RequestedPreviewKey: Equatable {
    let item: String?
    let list: String?
}
