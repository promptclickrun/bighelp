import SwiftUI

/// What a bot's profile needs from the shell.
@MainActor
struct SimpleBotProfileContext {
    let agents: AgentDirectoryStore
    let scheduledTasks: ScheduledTasksStore?
    let screenService: (any BotScreenService)?
    let screenChats: [ChatModel]
    let canEdit: Bool
    let onOpenChat: (String) -> Void
    let onOpenRoutine: (ScheduledTask) -> Void

    /// The bot's default model and reasoning, where the computer lets the app read and change them.
    var makeModelDefaults: ((String) -> AgentRuntimeDefaultsEditorModel?)? = nil
    /// The bot's helper task models (Default Model › Advanced); nil where the computer can't list them.
    var makeHelperModels: ((String) -> AgentHelperModelsModel?)? = nil
    /// The bot's default voice (Default Voice): its own voice type here, its speech provider on the
    /// computer; nil without a computer.
    var makeVoiceSettings: ((String) -> SimpleBotVoiceSettings?)? = nil
    /// The bot's own Credential Vault (its logins, cards and addresses); nil without a computer to ask.
    var makeCredentialVault: ((String) -> CredentialVaultModel?)? = nil
    /// The bot's Advanced Options: its settings and Nerd Mode pages; nil without a computer to ask.
    var makeAdvancedOptions: ((String) -> AdvancedOptionsContext?)? = nil
    /// The bot's own Marketplace (its skills, apps and messaging apps, and the computer's plugins).
    var makeMarketplace: ((String) -> MarketplaceContext)? = nil
    /// The bot's SOUL.md, USER.md, MEMORY.md and its chat's AGENTS.md; nil without a computer.
    var makeCoreFiles: ((String) -> (any CoreFilesSource)?)? = nil
    /// The bot's projects and the one its new chats start in (Active Project); nil without a computer.
    var makeProjects: ((String) -> HermesWorkspaceStore?)? = nil
    /// The bot's Active Project changed (its ID), so the shell's Projects read again.
    var onProjectChanged: (String) -> Void = { _ in }
    /// The bot's Connections page: this device's access and its apps.
    var makeConnections: ((String) -> AnyView)? = nil
    /// The folder the computer shares (Files); nil without a computer.
    var makeFilesSource: (() -> (any SimpleBotFilesSource)?)? = nil
    /// Photos and videos from the bot's chats (Media); nil while no computer is connected.
    var makeMediaClient: (() -> (any AgentMediaClient)?)? = nil
    /// Nerd Mode shows hidden files (names starting with ".").
    var showsHiddenFiles = false
    /// Feed, Ideas and Goals as piles (Dashboard); nil hides the tab. Its shell board also reads
    /// the bot's approvals for Info's Approvals row.
    var dashboard: SimpleBotDashboardHooks? = nil
    /// Why the computer won't let the app edit this bot, shown on About's rows; nil uses a general reason.
    var editUnavailableReason: String? = nil
    /// The model About saves a field through, with the shell's check that the computer is still the
    /// same; nil makes one with no check. A closure that returns nil opens nothing.
    var makeEditor: ((AgentProfile) -> AgentEditorModel?)? = nil
    /// The name of the bot's computer while it isn't the one in use yet (a door pushed the page before
    /// the switch finished). The page then shows "Opening <name>…" and reads nothing, so a bot with
    /// the same ID on the computer in use never shows in its place. Nil once it's in use.
    var openingComputer: String? = nil
    /// ⋯ › New chat with the bot (its ID); nil hides it.
    var onNewChat: ((String) -> Void)? = nil
    /// ⋯ › Chats with this bot; nil hides it.
    var onOpenChats: ((String) -> Void)? = nil
    /// ⋯ › Pin and Unpin, by the rules of the screen the bot is pinned on; nil hides them.
    var pinning: BotProfilePinning? = nil
    /// ⋯ › Use with Siri: its Shortcuts, which need a computer that can run them.
    var offersShortcuts = false
    /// ⋯ › Duplicate: a copy of the bot made on its computer; nil where it can't clone.
    var makeDuplicate: ((AgentProfile) -> AgentDuplicateModel?)? = nil
    /// ⋯ › Manage bots: export, import and the computer's default, opened on this bot; nil hides it.
    var onManageBots: ((String) -> Void)? = nil
    /// ⋯ › Delete bot; nil where the computer can't delete bots. The page closes once its bot is gone.
    var deletion: AgentDeletionAction? = nil
}

/// Pinning from a bot page: the screen whose pins they are decides the limit.
@MainActor
struct BotProfilePinning {
    let isPinned: (String) -> Bool
    /// Room for this bot's pin.
    let canPin: (String) -> Bool
    let setPinned: (String, Bool) -> Void
}

/// What a bot's Dashboard needs from the shell.
@MainActor
struct SimpleBotDashboardHooks {
    /// The shell's board store; the Dashboard's own store follows its connection.
    let shellBoard: AgentBoardStore
    /// The connection the shell's board should be on now, and setting it up for that one.
    let shellBoardKey: @MainActor () -> RootShellView.AgentBoardClientKey
    let configureShellBoard: @MainActor (RootShellView.AgentBoardClientKey) async -> Void
    /// Opens the bot's chat with the text in its message box (bot ID, text); nothing is sent.
    let onAsk: (String, String) -> Void
    /// Opens the bot's chat and sends the text there (Let's do it).
    let onSend: (String, String) -> Void
    /// Opens the bot's chat with a blueprint in its message box, its blanks as chips.
    let onBlueprint: (String, String) -> Void
}

/// A bot's page, from every door: its mark, name and role over every tab, then Dashboard (its
/// Feed, Ideas and Goals as piles to swipe), Info (About, Character, instructions and routines),
/// Computer (its screen, when the host has one), Files (its folder on the computer) and Media
/// (photos and videos from its chats). Holding a tab offers Set Default (the tab profiles open
/// on; Dashboard until one is set) and Rearrange, both the same for every bot. ⋯ holds what's
/// done to the bot itself (`BotProfileMenu`).
@MainActor
struct SimpleBotProfileView: View {
    let agentID: String
    let context: SimpleBotProfileContext
    /// Where code asked this profile to open (an agent's drive); nil for a tap.
    let opening: BotProfileOpening?

    private typealias Tab = SimpleBotProfileTab

    /// Nil until a tab is picked: the profile shows the one it opens on. An opening starts it on
    /// its own tab; this is never saved as the default.
    @State private var tab: Tab?
    @State private var openedRoute = false
    @State private var appliedDriveSerial: Int?
    @AppStorage(SimpleBotProfileTabs.orderKey) private var tabOrder = ""
    @AppStorage(SimpleBotProfileTabs.defaultKey) private var defaultTab: String?
    @State private var heldTab: Tab?
    /// The tab the bar was last shown over: it keeps its place and buttons while it fades away.
    @State private var popoverTab: Tab?
    @State private var tabFrames = SimpleBotTabFrameStore()
    @State private var isArrangingTabs = false
    @State private var tabNotice: String?
    @State private var dashboard: BoardDashboardModel?
    /// ⋯ › Show routines (on the Dashboard): scheduled task runs in Activities.
    @AppStorage(AgentTodayModel.showsRoutinesKey) private var showsRoutines = false
    @State private var mark: SimpleBotMark?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveState: String?
    @State private var isInstructionsPresented = false
    @State private var isPhotoActionsPresented = false
    @State private var newRoutine = false
    @State private var screen: BotScreenTabModel?
    @State private var templateNotice: String?
    @State private var isSavingTemplate = false
    @State private var savedTemplateTitle: String?
    @State private var isStudioPresented = false
    @State private var modelDefaults: AgentRuntimeDefaultsEditorModel?
    @State private var helperModels: AgentHelperModelsModel?
    @State private var isModelPresented = false
    @State private var voice: SimpleBotVoiceModel?
    @State private var isVoicePresented = false
    @State private var advancedOptions: AdvancedOptionsContext?
    @State private var isAdvancedPresented = false
    @State private var marketplace: MarketplaceContext?
    @State private var coreFiles: CoreFilesPresentation?
    @State private var projects: HermesWorkspaceStore?
    @State private var isProjectPresented = false
    @State private var isConnectionsPresented = false
    @State private var vault: CredentialVaultModel?
    @State private var isVaultPresented = false
    @State private var files: SimpleBotFilesModel?
    @State private var media = AgentMediaStore()
    @State private var isMediaConnected = false
    /// About: the field being edited and the model it saves through.
    @State private var aboutEditing: AboutEditing?
    /// The bot's approvals, on the shell board's connection; read once Info shows.
    @State private var approvals = AgentBoardStore()
    @State private var approvalsClient: ObjectIdentifier?
    @State private var isApprovalsPresented = false
    @State private var isShortcutsPresented = false
    @State private var duplicate: AgentDuplicateModel?
    @State private var isDeleteConfirmationPresented = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.companionAgentScope) private var scope
    @Environment(\.companionStore) private var companions
    @BighelpThemeReader private var theme

    init(agentID: String, context: SimpleBotProfileContext, opening: BotProfileOpening? = nil) {
        self.agentID = agentID
        self.context = context
        self.opening = opening
        _tab = State(initialValue: opening?.wantedTab)
    }

    private var profile: AgentProfile? { context.agents.profiles.first { $0.id == agentID } }
    private var isPrimary: Bool {
        context.agents.isPrimary(agentID) || (context.agents.primaryAgentID == nil && profile?.isDefault == true)
    }

    var body: some View {
        if let computer = context.openingComputer {
            // Nothing below runs until the bot's computer is in use: every task and sheet starts then.
            BotProfileOpeningView(computerName: computer)
                .safeAreaInset(edge: .top, spacing: 0) { openingHeader }
                .background(theme.canvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
        } else {
            page
        }
    }

    private var openingHeader: some View {
        HStack {
            SimpleBotsCircleButton(systemImage: "chevron.left", label: "Back", identifier: "simple-bots.profile.back") {
                dismiss()
            }
            Spacer()
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .background { SimpleBotsHeaderFade() }
    }

    private var page: some View {
        actionPresentations(Group {
            if let profile {
                content(profile)
            } else {
                ContentUnavailableView("This bot isn't here anymore", systemImage: "questionmark.circle")
            }
        })
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(theme.canvas.ignoresSafeArea())
        // Deleted, here or on another device: back to where it opened from. Only once the agent
        // list is the computer's own, so a reconnect's moment without one closes nothing.
        .onChange(of: profile == nil && context.agents.knowsProfiles) { _, gone in if gone { dismiss() } }
        .modifier(BoardDashboardOverlays(model: dashboard, isActive: shownTab == .dashboard,
                                         botName: profile?.name ?? ""))
        .toolbar(.hidden, for: .navigationBar)
        .task(id: agentID) {
            modelDefaults = context.canEdit ? context.makeModelDefaults?(agentID) : nil
            helperModels = modelDefaults == nil ? nil : context.makeHelperModels?(agentID)
            await modelDefaults?.loadIfNeeded()
        }
        .task(id: "\(agentID)|\(context.canEdit)") {
            // Made once the computer lets the app edit this bot; kept through a reconnect's moment without one.
            guard context.canEdit, voice?.agentID != agentID else { return }
            voice = context.makeVoiceSettings?(agentID).map { SimpleBotVoiceModel(agentID: agentID, voice: $0) }
        }
        // A new connection (back from the background) gets a store of its own.
        .task(id: voice.map { "\($0.agentID)|\($0.connection ?? "")" }) { await voice?.follow() }
        .task(id: "\(agentID)|\(context.canEdit)") {
            // Made once the computer says the app may edit this bot, which can come after the
            // profile opens; kept through a reconnect's moment without a connection.
            guard context.canEdit, advancedOptions?.store.profile != agentID else { return }
            advancedOptions = context.makeAdvancedOptions?(agentID)
        }
        .task(id: "\(agentID)|\(context.canEdit)") {
            // Like Advanced Options: made once the computer lets the app edit this bot.
            guard context.canEdit, vault?.agentID != agentID else { return }
            vault = context.makeCredentialVault?(agentID)
        }
        .task(id: "\(agentID)|\(context.canEdit)") {
            // Choosing a project is an edit: made once the computer lets the app edit this bot.
            guard context.canEdit, projects == nil else { return }
            projects = context.makeProjects?(agentID)
        }
        .task(id: "\(projects != nil)|\(shownTab == .info)") {
            // The row names the current project: read once Info shows.
            guard shownTab == .info, let projects, projects.catalogAgentID != agentID else { return }
            await projects.load(agentID: agentID)
        }
        .task(id: vault.map { "\($0.id)|\(shownTab == .info)" }) {
            // The row says how many websites the bot has: read once Info shows, not on every open.
            guard shownTab == .info, let vault, vault.state == .loading else { return }
            await vault.load()
        }
        .task(id: approvalsKey) {
            // The row's count: read once Info shows, and again only on a new connection.
            guard shownTab == .info, let hooks = context.dashboard else { return }
            guard let connection = hooks.shellBoard.followableConnection else {
                // The shell sets its board up in a root task, which waits while this page covers the
                // root; as the Dashboard does, bring it to the connection of the moment. Its own task,
                // so this one ending for the new connection never cuts it short.
                let key = hooks.shellBoardKey()
                await Task { await hooks.configureShellBoard(key) }.value
                return
            }
            let client = ObjectIdentifier(connection.client)
            guard approvalsClient != client || approvals.logState != .loaded else { return }
            await approvals.connect(client: connection.client, scope: connection.scope)
            await approvals.loadLogs(agentID: agentID)
            guard !Task.isCancelled else { return }
            approvalsClient = client
        }
        .task(id: agentID) {
            if context.dashboard != nil, dashboard?.agentID != agentID {
                dashboard = BoardDashboardModel(agentID: agentID)
            }
        }
        .task(id: agentID) {
            // Cheap to make; each tab loads only once it's opened.
            files = context.makeFilesSource?().map {
                SimpleBotFilesModel(agentID: agentID, source: $0, showsHidden: context.showsHiddenFiles)
            }
            let mediaClient = context.makeMediaClient?()
            media.configure(client: mediaClient)
            isMediaConnected = mediaClient != nil
        }
        // Each opening is shown once: coming back to this profile later keeps the person's own choices.
        .task(id: opening) {
            guard !openedRoute else { return }
            openedRoute = true
            await applyOpening(opening)
        }
        // A drive already on this profile sends its next step here instead of pushing again.
        .task(id: driveRequest) {
            guard let driveRequest, driveRequest.serial != appliedDriveSerial else { return }
            appliedDriveSerial = driveRequest.serial
            await applyOpening(driveRequest.opening)
        }
        .task(id: agentID) {
            guard let service = context.screenService else { return }
            let model = BotScreenTabModel(agentID: agentID, service: service)
            screen = model
            await model.load()
        }
        .bighelpSheet(isPresented: $isInstructionsPresented) {
            if let profile {
                SimpleBotInstructionsEditor(profile: profile, agents: context.agents)
                    .bighelpSheetSize(.large)
            }
        }
        .bighelpSheet(isPresented: $isPhotoActionsPresented) {
            if let profile {
                SimpleBotPhotoActionsSheet(agentID: profile.id, agentName: profile.name)
                    .bighelpSheetSize(.large)
            }
        }
        .bighelpSheet(isPresented: $isStudioPresented) {
            if let profile {
                AvatarChooserView(
                    start: SimpleBotAvatarSaving.start(for: profile, agents: context.agents, companions: companions,
                                                       scope: scope),
                    characters: AvatarCreatorModel.surprise(), agentName: profile.name,
                    faceName: AgentEditorModel.editing(profile, store: context.agents,
                                                       processor: AvatarImageProcessor()).faceName,
                    petSource: PetdexSource(store: context.agents, cacheScope: "\(ObjectIdentifier(context.agents))"),
                    useTitle: String(localized: "Save")
                ) { result in saveAvatar(result, for: profile) }
                .presentationDragIndicator(.visible)
                #if os(visionOS)
                .presentationSizing(.page)
                #endif
                .bighelpSheetSize(.large)
            }
        }
        // A page of its own on the profile's stack: its lists open in place, never in a sheet over it.
        .navigationDestination(isPresented: $isModelPresented) {
            if let profile, let modelDefaults {
                AgentDefaultModelsView(defaults: modelDefaults, helpers: helperModels, botName: profile.name)
                    .toolbar(.visible, for: .navigationBar)
            }
        }
        .bighelpSheet(isPresented: $isVoicePresented) {
            if let profile, let voice {
                SimpleBotDefaultVoiceSheet(model: voice, botName: profile.name) { isVoicePresented = false }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .bighelpSheetSize(.standard)
            }
        }
        .bighelpSheet(isPresented: $isVaultPresented) {
            if let vault {
                CredentialVaultView(model: vault)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .bighelpSheetSize(.standard)
            }
        }
        .bighelpSheet(item: $coreFiles) { presentation in
            NavigationStack {
                CoreFilesView(source: presentation.source, botName: presentation.botName)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { coreFiles = nil }
                                .accessibilityIdentifier("core-files.done")
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .bighelpSheetSize(.standard)
        }
        .bighelpSheet(isPresented: $isProjectPresented) {
            if let projects, let profile {
                NavigationStack {
                    BotActiveProjectView(store: projects, agentID: agentID, botName: profile.name) {
                        context.onProjectChanged(agentID)
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { isProjectPresented = false }
                                .accessibilityIdentifier("bot-project.done")
                        }
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
            }
        }
        .bighelpSheet(isPresented: $isConnectionsPresented) {
            if let makeConnections = context.makeConnections {
                NavigationStack {
                    makeConnections(agentID)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "Done")) { isConnectionsPresented = false }
                                    .accessibilityIdentifier("bot.connections.done")
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
            }
        }
        .bighelpSheet(item: $marketplace) { marketplace in
            NavigationStack {
                MarketplaceView(context: marketplace)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { self.marketplace = nil }
                                .accessibilityIdentifier("marketplace.done")
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .bighelpSheetSize(.standard)
        }
        .bighelpSheet(isPresented: $isAdvancedPresented) {
            if let profile, let advancedOptions {
                AdvancedOptionsSheet(context: advancedOptions, botName: profile.name) { isAdvancedPresented = false }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .bighelpSheetSize(.standard)
            }
        }
        .bighelpSheet(isPresented: $newRoutine) {
            if let profile, let store = context.scheduledTasks {
                NavigationStack {
                    ScheduledTaskEditorView(store: store, agent: profile, directory: context.agents)
                }
                .bighelpSheetSize(.standard)
            }
        }
        .bighelpSheet(isPresented: $isSavingTemplate, onDismiss: {
            // After the sheet has gone, so the alert can show.
            guard let title = savedTemplateTitle else { return }
            savedTemplateTitle = nil
            templateNotice = String(localized: "“\(title)” is saved on your computer. Pick it from Templates when you make a new bot.")
        }) {
            if let profile {
                SimpleBotSaveTemplateSheet(profile: profile) { savedTemplateTitle = $0.title }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.compact)
            }
        }
        .alert("Saved as a template", isPresented: Binding(get: { templateNotice != nil },
                                                          set: { if !$0 { templateNotice = nil } })) {
            Button("OK") { templateNotice = nil }
        } message: { Text(templateNotice ?? "") }
        .overlay(alignment: .bottom) { tabNoticeBar }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.profile")
    }

    private var header: some View {
        HStack(spacing: BighelpTokens.space8) {
            SimpleBotsCircleButton(systemImage: "chevron.left", label: "Back", identifier: "simple-bots.profile.back") {
                dismiss()
            }
            Spacer()
            if isArrangingTabs {
                Button { finishArranging() } label: {
                    Text("Done")
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, BighelpTokens.space20)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(Capsule())
                        .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("simple-bots.profile.tabs.done")
            } else if let profile {
                SimpleBotsCircleButton(systemImage: "square.and.arrow.up", label: "Save as Template",
                                       identifier: "simple-bots.profile.template") { isSavingTemplate = true }
                    .driveTarget("simple-bots.profile.template")
                Menu {
                    moreMenuItems(profile)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.bighelp(.title3, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.circle)
                        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More")
                .accessibilityIdentifier("simple-bots.profile.more")
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .background { SimpleBotsHeaderFade() }
    }

    private func moreMenuItems(_ profile: AgentProfile) -> some View {
        BotProfileMoreMenuItems(actions: BotProfileMenu.actions(menuCapabilities(profile)),
                                showsRoutines: $showsRoutines) { perform($0, on: profile) }
    }

    private func menuCapabilities(_ profile: AgentProfile) -> BotProfileMenuCapabilities {
        BotProfileMenuCapabilities(
            isOnComputerInUse: context.openingComputer == nil,
            isPrimary: isPrimary,
            offersNewChat: context.onNewChat != nil,
            offersChats: context.onOpenChats != nil,
            offersPinning: context.pinning != nil,
            isPinned: context.pinning?.isPinned(profile.id) == true,
            canPinAnother: context.pinning?.canPin(profile.id) == true,
            offersShortcuts: context.offersShortcuts,
            offersDuplicate: context.makeDuplicate != nil,

            showsRoutinesToggle: shownTab == .dashboard,
            offersManage: context.onManageBots != nil,
            offersDelete: context.deletion != nil,
            isDefaultBot: !AgentDeletionPresentation.canDelete(profile),
            isDeleting: isDeleting)
    }

    private func perform(_ action: BotProfileAction, on profile: AgentProfile) {
        let id = profile.id
        switch action {
        case .message: context.onOpenChat(id)
        case .newChat: context.onNewChat?(id)
        case .chats: context.onOpenChats?(id)
        case .makePrimary: _ = context.agents.setPrimaryAgent(id)
        case .pin, .unpin: context.pinning?.setPinned(id, action == .pin)
        case .shortcuts: isShortcutsPresented = true
        case .duplicate: duplicate = context.makeDuplicate?(profile)

        case .showRoutines: showsRoutines.toggle()
        case .manageBots: context.onManageBots?(id)
        case .delete: isDeleteConfirmationPresented = true
        }
    }

    /// What ⋯ and About open: an About field's editor, Use with Siri, Duplicate, the Approvals page
    /// and Delete bot's confirmation, progress and error. Kept apart from `page`'s own modifiers,
    /// which are already as many as the type checker takes in one expression.
    private func actionPresentations(_ content: some View) -> some View {
        content
            .bighelpSheet(item: $aboutEditing) { editing in
                BotProfileFieldEditor(field: editing.field, model: editing.model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .bighelpSheetSize(.compact)
            }
            .bighelpSheet(isPresented: $isShortcutsPresented) {
                if let profile {
                    AgentShortcutsView(agent: profile)
                        .bighelpSheetSize(.standard)
                }
            }
            .bighelpSheet(item: $duplicate) { model in
                AgentDuplicateView(model: model) {
                    duplicate = nil
                    let agents = context.agents
                    Task { await agents.loadReportingErrors() }
                }
                .bighelpSheetSize(.standard)
            }
            .navigationDestination(isPresented: $isApprovalsPresented) {
                BotApprovalsPage(store: approvals, botName: profile?.name ?? "")
                    .toolbar(.visible, for: .navigationBar)
            }
            .confirmationDialog(profile.map(AgentDeletionPresentation.title) ?? "",
                                isPresented: $isDeleteConfirmationPresented,
                                titleVisibility: .visible, presenting: profile) { profile in
                Button("Delete bot", role: .destructive) { delete(profile) }
                    .accessibilityIdentifier("simple-bots.profile.delete.confirm")
            } message: { profile in
                // Says what goes from the computer, at the control, every time.
                Text(AgentDeletionPresentation.message(profile))
            }
            .alert("Couldn't delete this bot", isPresented: Binding(get: { deleteError != nil },
                                                                    set: { if !$0 { deleteError = nil } })) {
                Button("OK") { deleteError = nil }
            } message: { Text(deleteError ?? "") }
            .overlay(alignment: .bottom) {
                if isDeleting, let profile {
                    // Still: the computer takes up to ten seconds, and nothing here needs to move meanwhile.
                    Text(AgentDeletionPresentation.progress(profile))
                        .font(.bighelp(.subheadline, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, BighelpTokens.space20)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .bighelpNavigationGlass(in: Capsule())
                        .padding(.bottom, BighelpTokens.space24)
                        .accessibilityIdentifier("simple-bots.profile.deleting")
                }
            }
    }

    /// After the confirmation. On success the shell closes the page (`closeScreens(ofDeletedAgent:)`),
    /// and the page closes itself once its bot leaves the list anyway.
    private func delete(_ profile: AgentProfile) {
        guard let deletion = context.deletion, !isDeleting else { return }
        isDeleting = true
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                try await deletion.run(profile.id)
            } catch {
                deleteError = AgentDeletionPresentation.errorMessage(error)
            }
        }
    }

    private func content(_ profile: AgentProfile) -> some View {
        ScrollView {
            VStack(spacing: BighelpTokens.space24) {
                VStack(spacing: BighelpTokens.space24) {
                    face(profile)
                    identityCard(profile)
                }
                #if targetEnvironment(macCatalyst)
                // The Mac's way to ⋯: a right-click on the bot's face or name.
                .contextMenu { moreMenuItems(profile) }
                #endif
                tabBar
                Group {
                    switch shownTab {
                    case .dashboard: dashboardTab(profile)
                    case .info: info(profile)
                    case .computer: computer(profile)
                    case .files: filesTab(profile)
                    case .media: mediaTab(profile)
                    }
                }
                // Rearranging is about the tabs; what's under them waits behind a veil of the page.
                .overlay {
                    if isArrangingTabs { theme.canvas.opacity(0.6).transition(.opacity) }
                }
                .allowsHitTesting(!isArrangingTabs)
                .accessibilityHidden(isArrangingTabs)
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        // A drag moves a tab, not the page.
        .scrollDisabled(isArrangingTabs)
        .driveScrolls()
    }

    private func face(_ profile: AgentProfile) -> some View {
        face(profile, size: 132)
            .padding(.top, BighelpTokens.space8)
            .animation(.snappy, value: mark)
    }

    @ViewBuilder
    private func face(_ profile: AgentProfile, size: CGFloat) -> some View {
        if let mark {
            SimpleBotMarkView(mark: mark, size: size)
        } else {
            SimpleBotFace(agentID: profile.id, name: profile.name,
                          imageURL: context.agents.avatarURL(for: profile), size: size)
        }
    }

    private func identityCard(_ profile: AgentProfile) -> some View {
        SimpleBotsCard {
            Text(profile.name)
                .font(.bighelp(.title, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(BighelpTokens.space20)
            if !profile.role.isEmpty {
                SimpleBotsDivider()
                Text(profile.role)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(BighelpTokens.space16)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var availableTabs: [Tab] {
        Tab.available(showsComputer: screen?.showsTab == true, showsDashboard: context.dashboard != nil,
                      order: SimpleBotProfileTabs.order(tabOrder))
    }

    /// The picked tab while it's there (the screen can close), else the one profiles open on.
    private var shownTab: Tab {
        SimpleBotProfileTabs.shown(picked: tab, defaultTab: defaultTab, in: availableTabs)
    }

    /// Shows an opening's sheet. The tab is already on screen (`tab` started on it, and falls
    /// back to the usual one while it isn't there). The sheet waits for the push to settle, since
    /// one presented during it can drop, then for the parts behind it to load; if they never
    /// come (no Dashboard, no screen, a computer that won't edit), nothing is shown.
    private func applyOpening(_ opening: BotProfileOpening?) async {
        if let wanted = opening?.wantedTab { tab = wanted }
        if let file = opening?.file {
            // The Files model is made in its own task as the profile appears.
            for _ in 0..<30 where files == nil && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await files?.reveal(path: file)
            return
        }
        guard let sheet = opening?.sheet else { return }
        try? await Task.sleep(for: .milliseconds(500))
        for _ in 0..<30 {
            guard !Task.isCancelled else { return }
            if sheet.canPresent(readiness) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, sheet.canPresent(readiness) else { return }
        present(sheet)
    }

    /// A drive's step for this bot (`DriveNavigator.profileRequest`), while one is under way.
    private var driveRequest: DriveNavigator.ProfileRequest? {
        DriveNavigator.shared.profileRequest.flatMap { $0.agentID == agentID ? $0 : nil }
    }

    private var readiness: BotProfileReadiness {
        BotProfileReadiness(
            shownTab: shownTab, canEdit: context.canEdit,
            hasDashboard: dashboard?.agentID == agentID && context.dashboard != nil,
            hasModelDefaults: modelDefaults != nil, hasVoice: voice != nil,
            hasAdvancedOptions: advancedOptions != nil, hasRoutines: context.scheduledTasks != nil)
    }

    private func present(_ sheet: BotProfileSheet) {
        switch sheet {
        case .templates(let kind): dashboard?.sheet = .templates(kind)
        case .blueprints(let kind): dashboard?.sheet = .blueprints(kind)
        case .seeAll(let kind): dashboard?.sheet = .seeAll(kind)
        case .character: isStudioPresented = true
        case .instructions: isInstructionsPresented = true
        case .photoActions: isPhotoActionsPresented = true
        case .defaultModel: isModelPresented = true
        case .defaultVoice: isVoicePresented = true
        case .advancedOptions: isAdvancedPresented = true
        case .avatarStudio: isStudioPresented = true
        case .addRoutine: newRoutine = true
        case .saveAsTemplate: isSavingTemplate = true
        }
    }

    private static let tabSpace = "simple-bots.profile.tabs"

    @ViewBuilder
    private var tabBar: some View {
        if isArrangingTabs {
            SimpleBotTabArranger(tabs: availableTabs) { moveTab($0, to: $1) }
        } else if availableTabs.count > 1 {
            // Every label whole, always: on one line, closer together where they must be (with
            // Dashboard there are five), and on two lines when larger text can't fit them on one.
            // A row that scrolled cut the last label at the screen's edge (#645 and again).
            ViewThatFits(in: .horizontal) {
                tabRow(AnyLayout(HStackLayout(spacing: BighelpTokens.space24)))
                tabRow(AnyLayout(HStackLayout(spacing: BighelpTokens.space16)))
                tabRow(AnyLayout(HStackLayout(spacing: BighelpTokens.space12)))
                tabRow(AnyLayout(BighelpFlowLayout(spacing: BighelpTokens.space16, lineSpacing: 0)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.separator).frame(height: BighelpTokens.hairline)
            }
            .coordinateSpace(.named(Self.tabSpace))
            .onPreferenceChange(SimpleBotTabFrames.self) { tabFrames.frames = $0 }
            // One popover for the row, over the held tab: Set Default and Rearrange.
            .popover(isPresented: Binding(get: { heldTab != nil }, set: { if !$0 { heldTab = nil } }),
                     attachmentAnchor: .rect(.rect(popoverTab.flatMap { tabFrames.frames[$0] } ?? .zero)),
                     arrowEdge: .bottom) {
                if let popoverTab {
                    tabActions(popoverTab)
                        .presentationCompactAdaptation(.popover)
                        .bighelpPopoverDismissal(isPresented: Binding(get: { self.heldTab != nil },
                                                                      set: { if !$0 { self.heldTab = nil } }))
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: heldTab) { _, held in held != nil }
        }
    }

    private func tabRow(_ layout: AnyLayout) -> some View {
        layout {
            ForEach(availableTabs) { item in
                Button {
                    // Letting go of a hold isn't a tap.
                    guard heldTab == nil else { return }
                    tab = item
                } label: {
                    VStack(spacing: BighelpTokens.space8) {
                        Text(item.title)
                            .font(.bighelp(.body))
                            .foregroundStyle(shownTab == item ? theme.primaryText : theme.tertiaryText)
                        Rectangle()
                            .fill(shownTab == item ? theme.primaryText : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SimpleBotTabFrames.self,
                                               value: [item: proxy.frame(in: .named(Self.tabSpace))])
                    }
                }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    popoverTab = item
                    heldTab = item
                })
                #if targetEnvironment(macCatalyst)
                // The Mac's way to the same choices.
                .contextMenu {
                    Button("Set Default", systemImage: "pin") { setDefaultTab(item) }
                    Button("Rearrange", systemImage: "arrow.left.arrow.right") { startArrangingTabs() }
                }
                #endif
                .driveTarget("simple-bots.profile.tab.\(item.rawValue)")
                .accessibilityAddTraits(shownTab == item ? .isSelected : [])
                .accessibilityAction(named: Text("Set Default")) { setDefaultTab(item) }
                .accessibilityAction(named: Text("Rearrange")) { startArrangingTabs() }
                .accessibilityIdentifier("simple-bots.profile.tab.\(item.rawValue)")
            }
        }
    }

    /// What holding a tab offers, in a small glass bar above it.
    private func tabActions(_ item: Tab) -> some View {
        // The saved choice only: the tab a profile falls back to can still be chosen.
        let isDefault = (defaultTab.flatMap(Tab.init(rawValue:)) ?? .dashboard) == item
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            Button { setDefaultTab(item) } label: {
                Label("Set Default", systemImage: isDefault ? "checkmark" : "pin")
                    .foregroundStyle(isDefault ? theme.secondaryText : theme.primaryText)
                    .padding(.horizontal, BighelpTokens.space16)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .disabled(isDefault)
            .accessibilityValue(isDefault ? Text("Profiles open on this tab") : Text(""))
            .accessibilityIdentifier("simple-bots.profile.tab-actions.default")
            Rectangle().fill(theme.separator)
                .frame(width: stacked ? nil : BighelpTokens.hairline, height: stacked ? BighelpTokens.hairline : 24)
            Button { startArrangingTabs() } label: {
                Label("Rearrange", systemImage: "arrow.left.arrow.right")
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, BighelpTokens.space16)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("simple-bots.profile.tab-actions.rearrange")
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .font(.bighelp(.subheadline, weight: .semibold))
        .fixedSize()
    }

    private func setDefaultTab(_ item: Tab) {
        // Stay on the tab shown now; the new default is for the next profile opened.
        if tab == nil { tab = shownTab }
        defaultTab = item.rawValue
        heldTab = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            tabNotice = String(localized: "Profiles now open on \(item.title)")
        }
    }

    private func startArrangingTabs() {
        if tab == nil { tab = shownTab }
        heldTab = nil
        withAnimation(reduceMotion ? nil : .snappy) { isArrangingTabs = true }
        AccessibilityNotification.Announcement(String(localized: "Drag a tab to move it, then tap Done.")).post()
    }

    private func finishArranging() {
        withAnimation(reduceMotion ? nil : .snappy) { isArrangingTabs = false }
    }

    private func moveTab(_ item: Tab, to index: Int) {
        let shown = SimpleBotProfileTabs.moving(item, to: index, in: availableTabs)
        let order = SimpleBotProfileTabs.merging(shown, into: SimpleBotProfileTabs.order(tabOrder))
        tabOrder = SimpleBotProfileTabs.saved(order)
    }

    @ViewBuilder
    private var tabNoticeBar: some View {
        if let tabNotice {
            Text(tabNotice)
                .font(.bighelp(.subheadline, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space20)
                .frame(minHeight: BighelpTokens.hitTarget)
                .bighelpNavigationGlass(in: Capsule())
                .padding(.bottom, BighelpTokens.space24)
                .transition(.opacity)
                .task(id: tabNotice) {
                    AccessibilityNotification.Announcement(tabNotice).post()
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { self.tabNotice = nil }
                }
                .accessibilityIdentifier("simple-bots.profile.tab-notice")
        }
    }

    private func markBinding(_ profile: AgentProfile) -> Binding<SimpleBotMark> {
        Binding(get: { mark ?? SimpleBotMarkStore.shared.mark(scope: scope, agentID: profile.id)
                    ?? .defaultMark(for: profile.id) },
                set: { pick($0, for: profile) })
    }

    private var markStatus: String {
        saveState ?? (context.canEdit ? String(localized: "How this Bot's mark looks everywhere")
                                      : String(localized: "This computer doesn't let the app change this bot."))
    }

    /// Info: About, Personality, Defaults and What it can use, then Routines and, last, Advanced
    /// Options. A group shows only the rows this computer offers, and none of a group that has none.
    private func info(_ profile: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            about(profile)
            infoGroup(String(localized: "Personality"), [.character, .instructions, .coreFiles], profile: profile)
            infoGroup(String(localized: "Defaults"), [.defaultModel, .defaultVoice, .activeProject], profile: profile)
            infoGroup(String(localized: "What it can use"),
                      [.connections, .marketplace, .credentialVault, .photoActions, .approvals], profile: profile)
            routines(profile)
            infoGroup(nil, [.advancedOptions], profile: profile)
        }
    }

    /// Name, Role, Summary and Handle, each with its value as its second line. A tap edits that one
    /// field in a small sheet; a computer that won't take edits says why instead.
    private func about(_ profile: AgentProfile) -> some View {
        let rows = BotProfileAbout.rows(
            name: profile.name, role: profile.role, summary: profile.summary,
            handle: AgentHandle.unique(base: profile.name, excluding: profile.id, profiles: context.agents.profiles),
            canEdit: context.canEdit, unavailableReason: context.editUnavailableReason)
        return VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            SimpleBotsSectionLabel(title: String(localized: "About"))
            SimpleBotsCard {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SimpleBotsDivider() }
                    aboutRow(row, profile: profile)
                }
            }
        }
    }

    @ViewBuilder
    private func aboutRow(_ row: BotProfileAboutRow, profile: AgentProfile) -> some View {
        if case .field(let field) = row.kind {
            Button { editAbout(field, of: profile) } label: {
                SimpleBotsRow(title: row.title, detail: row.detail) {
                    if row.isEditable { SimpleBotsDisclosure() }
                }
            }
            .buttonStyle(.plain)
            .disabled(!row.isEditable)
            .driveTarget(row.identifier)
            .accessibilityIdentifier(row.identifier)
        } else {
            SimpleBotsRow(title: row.title, detail: row.detail) { EmptyView() }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(row.identifier)
        }
    }

    private func editAbout(_ field: BotProfileAboutField, of profile: AgentProfile) {
        let model: AgentEditorModel?
        if let makeEditor = context.makeEditor {
            model = makeEditor(profile)
        } else {
            model = AgentEditorModel.editing(profile, store: context.agents, processor: AvatarImageProcessor())
        }
        guard let model else { return }
        aboutEditing = AboutEditing(field: field, model: model)
    }

    private struct AboutEditing: Identifiable {
        let field: BotProfileAboutField
        let model: AgentEditorModel
        var id: ObjectIdentifier { ObjectIdentifier(model) }
    }

    /// Info's Approvals load again for a new connection, never for each look at the tab.
    private struct ApprovalsKey: Hashable {
        let isInfo: Bool
        let client: ObjectIdentifier?
    }

    private var approvalsKey: ApprovalsKey {
        ApprovalsKey(isInfo: shownTab == .info,
                     client: context.dashboard?.shellBoard.followableConnection.map { ObjectIdentifier($0.client) })
    }

    /// How many approvals the bot has asked for, once read.
    private var approvalsCount: String? {
        approvals.logState == .loaded && approvalsClient != nil ? approvals.approvals.count.formatted() : nil
    }

    private enum InfoRow: Hashable {
        case character, instructions, coreFiles, defaultModel, defaultVoice, activeProject
        case connections, marketplace, credentialVault, photoActions, approvals, advancedOptions
    }

    private func offers(_ row: InfoRow) -> Bool {
        switch row {
        case .character, .instructions, .photoActions: true
        case .approvals: context.dashboard != nil
        case .coreFiles: context.makeCoreFiles != nil
        case .defaultModel: modelDefaults != nil
        case .defaultVoice: voice != nil
        case .activeProject: projects != nil
        case .connections: context.makeConnections != nil
        case .marketplace: context.makeMarketplace != nil
        case .credentialVault: vault != nil
        case .advancedOptions: advancedOptions != nil
        }
    }

    @ViewBuilder
    private func infoGroup(_ title: String?, _ rows: [InfoRow], profile: AgentProfile) -> some View {
        let shown = rows.filter(offers)
        if !shown.isEmpty {
            // Spaced like Routines, whose label and card sit straight in the tab's stack.
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                if let title { SimpleBotsSectionLabel(title: title) }
                SimpleBotsCard {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, row in
                        if index > 0 { SimpleBotsDivider() }
                        infoRow(row, profile: profile)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ row: InfoRow, profile: AgentProfile) -> some View {
        switch row {
        case .character:
            // Edit avatar: Bot Studio, PetDex or a photo.
            Button { isStudioPresented = true } label: {
                SimpleBotsRow(title: String(localized: "Character"), leading: Image(systemName: "face.smiling")) {
                    HStack(spacing: BighelpTokens.space8) {
                        face(profile, size: 28)
                            .accessibilityHidden(true)
                        SimpleBotsDisclosure()
                    }
                }
            }
            .buttonStyle(.plain)
            .driveTarget("simple-bots.profile.character")
            .accessibilityIdentifier("simple-bots.profile.character")
        case .instructions:
            Button { isInstructionsPresented = true } label: {
                SimpleBotsRow(title: String(localized: "Instructions"), leading: Image(systemName: "doc.text"))
            }
            .buttonStyle(.plain)
            .disabled(!context.canEdit)
            .driveTarget("simple-bots.profile.instructions")
            .accessibilityIdentifier("simple-bots.profile.instructions")
        case .coreFiles:
            if let makeCoreFiles = context.makeCoreFiles {
                Button {
                    coreFiles = makeCoreFiles(profile.id).map { CoreFilesPresentation(source: $0, botName: profile.name) }
                } label: {
                    SimpleBotsRow(title: String(localized: "Core Files"), leading: Image(systemName: "doc.text.magnifyingglass"))
                }
                .buttonStyle(.plain)
                .driveTarget("simple-bots.profile.core-files")
                .accessibilityIdentifier("simple-bots.profile.core-files")
            }
        case .defaultModel:
            if let modelDefaults {
                Button { isModelPresented = true } label: {
                    SimpleBotsRow(title: String(localized: "Default Model"), leading: Image(systemName: "cpu"),
                                  value: modelName(modelDefaults))
                }
                .buttonStyle(.plain)
                .driveTarget("simple-bots.profile.default-model")
                .accessibilityIdentifier("simple-bots.profile.default-model")
            }
        case .defaultVoice:
            if let voice {
                Button { isVoicePresented = true } label: {
                    SimpleBotsRow(title: String(localized: "Default Voice"), leading: Image(systemName: "waveform"),
                                  value: voice.summary)
                }
                .buttonStyle(.plain)
                .driveTarget("simple-bots.profile.default-voice")
                .accessibilityIdentifier("simple-bots.profile.default-voice")
            }
        case .activeProject:
            if let projects {
                Button { isProjectPresented = true } label: {
                    SimpleBotsRow(title: String(localized: "Active Project"), leading: Image(systemName: "folder"),
                                  value: activeProjectName(projects))
                }
                .buttonStyle(.plain)
                .driveTarget("simple-bots.profile.active-project")
                .accessibilityIdentifier("simple-bots.profile.active-project")
            }
        case .connections:
            Button { isConnectionsPresented = true } label: {
                SimpleBotsRow(title: String(localized: "Connections"),
                              leading: Image(systemName: "app.connected.to.app.below.fill"))
            }
            .buttonStyle(.plain)
            .driveTarget("simple-bots.profile.connections")
            .accessibilityIdentifier("simple-bots.profile.connections")
        case .marketplace:
            if let makeMarketplace = context.makeMarketplace {
                // Made when it opens, so its plugin list is read only then.
                Button { marketplace = makeMarketplace(profile.id) } label: {
                    SimpleBotsRow(title: String(localized: "Marketplace"), leading: Image(systemName: "storefront"))
                }
                .buttonStyle(.plain)
                .driveTarget("simple-bots.profile.marketplace")
                .accessibilityIdentifier("simple-bots.profile.marketplace")
            }
        case .credentialVault:
            if let vault {
                Button { isVaultPresented = true } label: {
                    SimpleBotsRow(title: String(localized: "Credential Vault"), leading: Image(systemName: "lock.shield"),
                                  value: vaultSummary(vault))
                }
                .buttonStyle(.plain)
                .driveTarget("simple-bots.profile.credential-vault")
                .accessibilityIdentifier("simple-bots.profile.credential-vault")
            }
        case .photoActions:
            Button { isPhotoActionsPresented = true } label: {
                SimpleBotsRow(title: String(localized: "Photo actions"), leading: Image(systemName: "photo.badge.checkmark"))
            }
            .buttonStyle(.plain)
            .disabled(!context.canEdit)
            .driveTarget("simple-bots.profile.photo-actions")
            .accessibilityIdentifier("simple-bots.profile.photo-actions")
        case .approvals:
            Button { isApprovalsPresented = true } label: {
                SimpleBotsRow(title: String(localized: "Approvals"), leading: Image(systemName: "checkmark.shield"),
                              value: approvalsCount)
            }
            .buttonStyle(.plain)
            .driveTarget("simple-bots.profile.approvals")
            .accessibilityIdentifier("simple-bots.profile.approvals")
        case .advancedOptions:
            Button { isAdvancedPresented = true } label: {
                SimpleBotsRow(title: String(localized: "Advanced Options"),
                              leading: Image(systemName: "slider.horizontal.3"))
            }
            .buttonStyle(.plain)
            .driveTarget("simple-bots.profile.advanced-options")
            .accessibilityIdentifier("simple-bots.profile.advanced-options")
        }
    }

    /// How many websites the bot can sign in or check out on, once the vault has been read.
    /// The project the bot's new chats start in; nothing until its projects are read.
    private func activeProjectName(_ projects: HermesWorkspaceStore) -> String? {
        guard projects.catalogAgentID == agentID, let catalog = projects.catalog else { return nil }
        return catalog.workspaces.first { $0.id == catalog.activeWorkspaceID }?.name ?? String(localized: "None")
    }

    private func vaultSummary(_ vault: CredentialVaultModel) -> String? {
        guard vault.state == .ready else { return nil }
        return switch vault.sites.count {
        case 0: nil
        case 1: String(localized: "1 website")
        case let count: String(localized: "\(count) websites")
        }
    }

    @ViewBuilder
    private func routines(_ profile: AgentProfile) -> some View {
        if let store = context.scheduledTasks {
            let tasks = store.tasks.filter { $0.agentID == profile.id }
            SimpleBotsSectionLabel(title: String(localized: "Routines"))
            // Add routine first, so it stays in the same place however many routines there are.
            SimpleBotsCard {
                Button { newRoutine = true } label: {
                    Label("Add routine", systemImage: "plus")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.information)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, BighelpTokens.space20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .driveTarget("simple-bots.profile.add-routine")
                .accessibilityIdentifier("simple-bots.profile.add-routine")
                SimpleBotsDivider()
                if tasks.isEmpty {
                    Text("No routines yet")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, BighelpTokens.space20)
                } else {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { SimpleBotsDivider() }
                        Button { context.onOpenRoutine(task) } label: {
                            SimpleBotsRow(title: task.name, detail: task.scheduleDescription)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .task { if store.loadState == .idle { await store.load() } }
        }
    }

    @ViewBuilder
    private func computer(_ profile: AgentProfile) -> some View {
        if let screen, screen.showsTab {
            AgentScreenTab(model: screen, agentName: profile.name, chats: context.screenChats)
        }
    }

    @ViewBuilder
    private func filesTab(_ profile: AgentProfile) -> some View {
        if let files {
            SimpleBotFilesTab(model: files, botName: profile.name)
        } else {
            SimpleBotsMessageCard(systemImage: "wifi.slash", title: String(localized: "Your computer isn't connected"),
                                  detail: String(localized: "\(profile.name)'s files show up here once it's back."))
        }
    }

    @ViewBuilder
    private func dashboardTab(_ profile: AgentProfile) -> some View {
        if let hooks = context.dashboard, let dashboard, dashboard.agentID == profile.id {
            BoardDashboardView(model: dashboard, context: boardContext(profile, hooks: hooks, store: dashboard.store),
                               shellBoard: hooks.shellBoard, shellBoardKey: hooks.shellBoardKey,
                               configureShellBoard: hooks.configureShellBoard)
        }
    }

    /// The bot's board as the Feed, Ideas and Goals pages take it. The chat is always this bot's own.
    private func boardContext(_ profile: AgentProfile, hooks: SimpleBotDashboardHooks,
                              store: AgentBoardStore) -> AgentBoardContext {
        let id = profile.id
        return AgentBoardContext(
            agentID: id, agentName: profile.name, imageURL: context.agents.avatarURL(for: profile),
            activity: .idle, store: store,
            onProfile: {}, onSwitchAgent: {},
            onAsk: { hooks.onAsk(id, $0) }, onSend: { hooks.onSend(id, $0) }, onBlueprint: { hooks.onBlueprint(id, $0) },
            onNewChat: { context.onOpenChat(id) })
    }

    private func mediaTab(_ profile: AgentProfile) -> some View {
        SimpleBotMediaTab(agentID: profile.id, botName: profile.name, store: media, isConnected: isMediaConnected)
    }

    /// Shows the pick at once; saves it to the host once picking settles.
    private func pick(_ newMark: SimpleBotMark, for profile: AgentProfile) {
        mark = newMark
        SimpleBotMarkStore.shared.set(newMark, scope: scope, agentID: profile.id)
        saveTask?.cancel()
        saveState = String(localized: "Saving…")
        let agents = context.agents
        let companions = companions
        let scope = scope
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            do {
                let current = agents.profiles.first { $0.id == profile.id } ?? profile
                try await SimpleBotMarkSaving.save(newMark, for: current, agents: agents,
                                                   companions: companions, scope: scope)
                guard !Task.isCancelled else { return }
                saveState = String(localized: "Saved. This is how \(profile.name) looks everywhere.")
            } catch {
                guard !Task.isCancelled else { return }
                saveState = String(localized: "Saved on this device. The computer didn't take the picture; try again later.")
            }
        }
    }

    /// The studio's pick, saved at once; the face at the top changes as soon as it's in.
    private func saveAvatar(_ result: AvatarCreatorResult, for profile: AgentProfile) {
        if case .mark(let newMark) = result {
            pick(newMark, for: profile)
            return
        }
        saveTask?.cancel()
        mark = nil
        saveState = String(localized: "Saving…")
        let agents = context.agents
        let companions = companions
        let scope = scope
        let look = SimpleBotAvatarSaving.Look(appearance: appearance, colorScheme: colorScheme, contrast: contrast)
        saveTask = Task { @MainActor in
            do {
                let current = agents.profiles.first { $0.id == profile.id } ?? profile
                try await SimpleBotAvatarSaving.save(result, for: current, agents: agents, companions: companions,
                                                     scope: scope, look: look)
                guard !Task.isCancelled else { return }
                saveState = String(localized: "Saved. This is how \(profile.name) looks everywhere.")
            } catch {
                guard !Task.isCancelled else { return }
                saveState = String(localized: "The computer didn't take the new avatar. Try again.")
            }
        }
    }

    private func modelName(_ defaults: AgentRuntimeDefaultsEditorModel) -> String {
        let modelID = defaults.draft[.mainChats].modelID
        return modelID.isEmpty ? String(localized: "Automatic") : ModelNameCatalog.empty.displayName(for: modelID)
    }

}

/// A bot's Photo actions, in a sheet of their own like its instructions.
@MainActor
private struct SimpleBotPhotoActionsSheet: View {
    let agentID: String
    let agentName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PhotoActionsSettingsView(agentID: agentID, agentName: agentName)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("simple-bots.photo-actions.done")
                    }
                }
        }
    }
}

/// A bot's instructions (its SOUL), edited and saved straight to the host.
@MainActor
private struct SimpleBotInstructionsEditor: View {
    let profile: AgentProfile
    let agents: AgentDirectoryStore

    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(profile: AgentProfile, agents: AgentDirectoryStore) {
        self.profile = profile
        self.agents = agents
        _text = State(initialValue: profile.instructions)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                // Above the text: the editor runs on under the keyboard.
                if let errorMessage {
                    Text(errorMessage).font(.bighelp(.subheadline)).foregroundStyle(theme.danger)
                }
                LongTextEditor(text: $text, accessibilityLabel: String(localized: "Instructions"),
                               identifier: "simple-bots.instructions.editor")
                    .padding(.horizontal, BighelpTokens.space12)
                    .padding(.vertical, BighelpTokens.space4)
                    .background(theme.surface)
                    // Text scrolled to the edge stays inside the rounded corners.
                    .clipShape(.rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
            }
            .padding(BighelpTokens.space16)
            // The editor keeps the caret above the keyboard itself, so its frame stays put.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background(theme.canvas.ignoresSafeArea())
            // A swipe down never throws away unsaved instructions.
            .interactiveDismissDisabled(isSaving || text != profile.instructions)
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || text == profile.instructions
                                  || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("simple-bots.instructions.save")
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let current = agents.profiles.first { $0.id == profile.id } ?? profile
        var draft = AgentDraft(name: current.name, role: current.role, summary: current.summary,
                               instructions: text, avatarFileName: current.avatarFileName,
                               avatar: current.avatar, isDefault: current.isDefault)
        draft.look = nil
        do {
            _ = try await agents.update(id: profile.id, draft: draft)
            dismiss()
        } catch {
            errorMessage = String(localized: "The computer didn't save that. Your text is still here; try again.")
        }
    }
}
