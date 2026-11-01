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
    let onEditDetails: (AgentProfile) -> Void
    /// The bot's default model and reasoning, where the computer lets the app read and change them.
    var makeModelDefaults: ((String) -> AgentRuntimeDefaultsEditorModel?)? = nil
    /// The bot's default voice (Default Voice): its own voice type here, its speech provider on the
    /// computer; nil without a computer.
    var makeVoiceSettings: ((String) -> SimpleBotVoiceSettings?)? = nil
    /// The bot's own Credential Vault (its logins, cards and addresses); nil without a computer to ask.
    var makeCredentialVault: ((String) -> CredentialVaultModel?)? = nil
    /// The bot's Advanced Options: its settings and Nerd Mode pages; nil without a computer to ask.
    var makeAdvancedOptions: ((String) -> AdvancedOptionsContext?)? = nil
    /// The folder the computer shares (Files); nil without a computer.
    var makeFilesSource: (() -> (any SimpleBotFilesSource)?)? = nil
    /// Photos and videos from the bot's chats (Media); nil while no computer is connected.
    var makeMediaClient: (() -> (any AgentMediaClient)?)? = nil
    /// Nerd Mode shows hidden files (names starting with ".").
    var showsHiddenFiles = false
    /// Feed, Ideas and Goals as piles (Dashboard); nil hides the tab.
    var dashboard: SimpleBotDashboardHooks? = nil
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
    /// Opens the bot's chat and sends the text: only a blueprint's own Send to agent.
    let onSend: (String, String) -> Void
}

/// A bot's profile in Bots mode: its mark, name and role over every tab, then Dashboard (its
/// Feed, Ideas and Goals as piles to swipe), Info (Character, instructions and routines),
/// Computer (its screen, when the host has one), Files (its folder on the computer) and Media
/// (photos and videos from its chats). Holding a tab offers Set Default (the tab profiles open
/// on; Dashboard until one is set) and Rearrange, both the same for every bot.
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
    @State private var isCharacterPresented = false
    @State private var opensStudioAfterCharacter = false
    @State private var dashboard: BoardDashboardModel?
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
    @State private var isModelPresented = false
    @State private var voice: SimpleBotVoiceModel?
    @State private var isVoicePresented = false
    @State private var advancedOptions: AdvancedOptionsContext?
    @State private var isAdvancedPresented = false
    @State private var vault: CredentialVaultModel?
    @State private var isVaultPresented = false
    @State private var files: SimpleBotFilesModel?
    @State private var media = AgentMediaStore()
    @State private var isMediaConnected = false
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
        Group {
            if let profile {
                content(profile)
            } else {
                ContentUnavailableView("This bot isn't here anymore", systemImage: "questionmark.circle")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(theme.canvas.ignoresSafeArea())
        .modifier(BoardDashboardOverlays(model: dashboard, isActive: shownTab == .dashboard,
                                         botName: profile?.name ?? ""))
        .toolbar(.hidden, for: .navigationBar)
        .task(id: agentID) {
            modelDefaults = context.canEdit ? context.makeModelDefaults?(agentID) : nil
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
        .task(id: vault.map { "\($0.id)|\(shownTab == .info)" }) {
            // The row says how many websites the bot has: read once Info shows, not on every open.
            guard shownTab == .info, let vault, vault.state == .loading else { return }
            await vault.load()
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
        .bighelpSheet(isPresented: $isCharacterPresented, onDismiss: {
            // After the sheet has gone, so the studio can show.
            guard opensStudioAfterCharacter else { return }
            opensStudioAfterCharacter = false
            isStudioPresented = true
        }) {
            if let profile {
                SimpleBotCharacterSheet(
                    mark: markBinding(profile), canEdit: context.canEdit, status: markStatus,
                    onReset: { pick(.defaultMark(for: profile.id), for: profile) },
                    onMoreAvatars: {
                        opensStudioAfterCharacter = true
                        isCharacterPresented = false
                    },
                    onDone: { isCharacterPresented = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
            }
        }
        .bighelpSheet(isPresented: $isStudioPresented) {
            if let profile {
                AvatarCreatorView(
                    start: SimpleBotAvatarSaving.start(for: profile, agents: context.agents, companions: companions,
                                                       scope: scope),
                    characters: AvatarCreatorModel.surprise(), agentName: profile.name,
                    faceName: AgentEditorModel.editing(profile, store: context.agents,
                                                       processor: AvatarImageProcessor()).faceName,
                    petSource: PetdexSource(store: context.agents, cacheScope: "\(ObjectIdentifier(context.agents))"),
                    offersBotMarks: true, useTitle: String(localized: "Save")
                ) { result in saveAvatar(result, for: profile) }
                .presentationDragIndicator(.visible)
                #if os(visionOS)
                .presentationSizing(.page)
                #endif
                .bighelpSheetSize(.large)
            }
        }
        .bighelpSheet(isPresented: $isModelPresented) {
            if let profile, let modelDefaults {
                SimpleBotDefaultModelSheet(defaults: modelDefaults, botName: profile.name) { isModelPresented = false }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .bighelpSheetSize(.standard)
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
                    Button("Message", systemImage: "message") { context.onOpenChat(profile.id) }
                    if !isPrimary {
                        Button("Make Primary Bot", systemImage: "star") { _ = context.agents.setPrimaryAgent(profile.id) }
                    }
                    if context.canEdit {
                        Button("Edit Name and Role", systemImage: "pencil") { context.onEditDetails(profile) }
                    }
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

    private func content(_ profile: AgentProfile) -> some View {
        ScrollView {
            VStack(spacing: BighelpTokens.space24) {
                face(profile)
                identityCard(profile)
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
        face(profile, size: 132, isPrimary: isPrimary)
            .padding(.top, BighelpTokens.space8)
            .animation(.snappy, value: mark)
    }

    @ViewBuilder
    private func face(_ profile: AgentProfile, size: CGFloat, isPrimary: Bool) -> some View {
        if let mark {
            SimpleBotMarkView(mark: mark, size: size, isPrimary: isPrimary)
        } else {
            SimpleBotFace(agentID: profile.id, name: profile.name,
                          imageURL: context.agents.avatarURL(for: profile), size: size, isPrimary: isPrimary)
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
        case .character: isCharacterPresented = true
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

    private func info(_ profile: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            SimpleBotsCard {
                // The shape and color picker, Reset to default and More avatars, in a sheet.
                Button { isCharacterPresented = true } label: {
                    SimpleBotsRow(title: String(localized: "Character"), leading: Image(systemName: "face.smiling")) {
                        HStack(spacing: BighelpTokens.space8) {
                            face(profile, size: 28, isPrimary: false)
                                .accessibilityHidden(true)
                            SimpleBotsDisclosure()
                        }
                    }
                }
                .buttonStyle(.plain)
                .driveTarget("simple-bots.profile.character")
                .accessibilityIdentifier("simple-bots.profile.character")
                SimpleBotsDivider()
                Button { isInstructionsPresented = true } label: {
                    SimpleBotsRow(title: String(localized: "Instructions"), leading: Image(systemName: "doc.text"))
                }
                .buttonStyle(.plain)
                .disabled(!context.canEdit)
                .driveTarget("simple-bots.profile.instructions")
                .accessibilityIdentifier("simple-bots.profile.instructions")
                SimpleBotsDivider()
                Button { isPhotoActionsPresented = true } label: {
                    SimpleBotsRow(title: String(localized: "Photo actions"), leading: Image(systemName: "photo.badge.checkmark"))
                }
                .buttonStyle(.plain)
                .disabled(!context.canEdit)
                .driveTarget("simple-bots.profile.photo-actions")
                .accessibilityIdentifier("simple-bots.profile.photo-actions")
                if let modelDefaults {
                    SimpleBotsDivider()
                    Button { isModelPresented = true } label: {
                        SimpleBotsRow(title: String(localized: "Default Model"), leading: Image(systemName: "cpu"),
                                      value: modelName(modelDefaults))
                    }
                    .buttonStyle(.plain)
                    .driveTarget("simple-bots.profile.default-model")
                    .accessibilityIdentifier("simple-bots.profile.default-model")
                }
                if let voice {
                    SimpleBotsDivider()
                    Button { isVoicePresented = true } label: {
                        SimpleBotsRow(title: String(localized: "Default Voice"), leading: Image(systemName: "waveform"),
                                      value: voice.summary)
                    }
                    .buttonStyle(.plain)
                    .driveTarget("simple-bots.profile.default-voice")
                    .accessibilityIdentifier("simple-bots.profile.default-voice")
                }
                if let vault {
                    SimpleBotsDivider()
                    Button { isVaultPresented = true } label: {
                        SimpleBotsRow(title: String(localized: "Credential Vault"), leading: Image(systemName: "lock.shield"),
                                      value: vaultSummary(vault))
                    }
                    .buttonStyle(.plain)
                    .driveTarget("simple-bots.profile.credential-vault")
                    .accessibilityIdentifier("simple-bots.profile.credential-vault")
                }
                if advancedOptions != nil {
                    SimpleBotsDivider()
                    Button { isAdvancedPresented = true } label: {
                        SimpleBotsRow(title: String(localized: "Advanced Options"),
                                      leading: Image(systemName: "slider.horizontal.3"))
                    }
                    .buttonStyle(.plain)
                    .driveTarget("simple-bots.profile.advanced-options")
                    .accessibilityIdentifier("simple-bots.profile.advanced-options")
                }
            }

            routines(profile)
        }
    }

    /// How many websites the bot can sign in or check out on, once the vault has been read.
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
            SimpleBotsCard {
                if tasks.isEmpty {
                    Text("No routines yet")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, BighelpTokens.space20)
                } else {
                    ForEach(tasks) { task in
                        Button { context.onOpenRoutine(task) } label: {
                            SimpleBotsRow(title: task.name, detail: task.scheduleDescription)
                        }
                        .buttonStyle(.plain)
                        SimpleBotsDivider()
                    }
                }
                if tasks.isEmpty { SimpleBotsDivider() }
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

    /// The bot's board as the Feed, Ideas and Goals pages take it. Bots mode has no menu or agent
    /// switcher, so those do nothing; the chat is always this bot's own.
    private func boardContext(_ profile: AgentProfile, hooks: SimpleBotDashboardHooks,
                              store: AgentBoardStore) -> AgentBoardContext {
        let id = profile.id
        return AgentBoardContext(
            agentID: id, agentName: profile.name, imageURL: context.agents.avatarURL(for: profile),
            activity: .idle, store: store,
            onProfile: {}, onSwitchAgent: {},
            onAsk: { hooks.onAsk(id, $0) }, onSend: { hooks.onSend(id, $0) },
            onMenu: {}, onNewChat: { context.onOpenChat(id) }, onPickAgents: {}, tools: [])
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
