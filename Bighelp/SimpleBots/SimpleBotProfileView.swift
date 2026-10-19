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
    /// The folder the computer shares (Files); nil without a computer.
    var makeFilesSource: (() -> (any SimpleBotFilesSource)?)? = nil
    /// Photos and videos from the bot's chats (Media); nil while no computer is connected.
    var makeMediaClient: (() -> (any AgentMediaClient)?)? = nil
    /// Nerd Mode shows hidden files (names starting with ".").
    var showsHiddenFiles = false
}

/// A bot's profile in Simple Bot mode: its mark, name and role, then Info
/// (its look, instructions and routines), Computer (its screen, when the
/// host has one), Files (its folder on the computer) and Media (photos and
/// videos from its chats).
@MainActor
struct SimpleBotProfileView: View {
    let agentID: String
    let context: SimpleBotProfileContext

    private typealias Tab = SimpleBotProfileTab

    @State private var tab: Tab = .info
    @State private var mark: SimpleBotMark?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveState: String?
    @State private var isInstructionsPresented = false
    @State private var newRoutine = false
    @State private var screen: BotScreenTabModel?
    @State private var templateNotice: String?
    @State private var isSavingTemplate = false
    @State private var savedTemplateTitle: String?
    @State private var isStudioPresented = false
    @State private var modelDefaults: AgentRuntimeDefaultsEditorModel?
    @State private var isModelPresented = false
    @State private var files: SimpleBotFilesModel?
    @State private var media = AgentMediaStore()
    @State private var isMediaConnected = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.companionAgentScope) private var scope
    @Environment(\.companionStore) private var companions
    @BighelpThemeReader private var theme

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
        .toolbar(.hidden, for: .navigationBar)
        .task(id: agentID) {
            modelDefaults = context.canEdit ? context.makeModelDefaults?(agentID) : nil
            await modelDefaults?.loadIfNeeded()
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
        .bighelpSheet(isPresented: $isStudioPresented) {
            if let profile {
                AvatarCreatorView(
                    start: SimpleBotAvatarSaving.start(for: profile, agents: context.agents, companions: companions,
                                                       scope: scope),
                    characters: AvatarCreatorModel.surprise(), agentName: profile.name,
                    faceName: AgentEditorModel.editing(profile, store: context.agents,
                                                       processor: AvatarImageProcessor()).faceName,
                    petSource: PetdexSource(store: context.agents, cacheScope: "\(ObjectIdentifier(context.agents))"),
                    offersBotMarks: true, useTitle: "Save"
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
            templateNotice = "“\(title)” is saved on your computer. Pick it from Templates when you make a new bot."
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.profile")
    }

    private var header: some View {
        HStack(spacing: BighelpTokens.space8) {
            SimpleBotsCircleButton(systemImage: "chevron.left", label: "Back", identifier: "simple-bots.profile.back") {
                dismiss()
            }
            Spacer()
            if let profile {
                SimpleBotsCircleButton(systemImage: "square.and.arrow.up", label: "Save as Template",
                                       identifier: "simple-bots.profile.template") { isSavingTemplate = true }
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
                switch shownTab {
                case .info: info(profile)
                case .computer: computer(profile)
                case .files: filesTab(profile)
                case .media: mediaTab(profile)
                }
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func face(_ profile: AgentProfile) -> some View {
        Group {
            if let mark {
                SimpleBotMarkView(mark: mark, size: 132, isPrimary: isPrimary)
            } else {
                SimpleBotFace(agentID: profile.id, name: profile.name,
                              imageURL: context.agents.avatarURL(for: profile), size: 132, isPrimary: isPrimary)
            }
        }
        .padding(.top, BighelpTokens.space8)
        .animation(.snappy, value: mark)
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
        Tab.available(showsComputer: screen?.showsTab == true)
    }

    /// Info when the chosen tab went away (the screen closed).
    private var shownTab: Tab {
        availableTabs.contains(tab) ? tab : .info
    }

    @ViewBuilder
    private var tabBar: some View {
        if availableTabs.count > 1 {
            // Scrolls sideways only when large text makes the tabs wider than the screen.
            ScrollView(.horizontal) {
                HStack(spacing: BighelpTokens.space24) {
                    ForEach(availableTabs) { item in
                        Button { tab = item } label: {
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
                        .accessibilityAddTraits(shownTab == item ? .isSelected : [])
                        .accessibilityIdentifier("simple-bots.profile.tab.\(item.rawValue)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.separator).frame(height: BighelpTokens.hairline)
            }
        }
    }

    private func info(_ profile: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            SimpleBotsSectionLabel(title: "Character")
            SimpleBotsCard {
                SimpleBotMarkPicker(mark: Binding(
                    get: { mark ?? SimpleBotMarkStore.shared.mark(scope: scope, agentID: profile.id)
                        ?? .defaultMark(for: profile.id) },
                    set: { pick($0, for: profile) }))
                    .padding(.vertical, BighelpTokens.space24)
                    .padding(.horizontal, BighelpTokens.space8)
                    .disabled(!context.canEdit)
                SimpleBotsDivider()
                Button { pick(.defaultMark(for: profile.id), for: profile) } label: {
                    Text("Reset to default")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.information)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, BighelpTokens.space20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!context.canEdit)
                .accessibilityIdentifier("simple-bots.profile.reset-mark")
                SimpleBotsDivider()
                Button { isStudioPresented = true } label: {
                    Text("More avatars")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.information)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, BighelpTokens.space20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!context.canEdit)
                .accessibilityIdentifier("simple-bots.profile.more-avatars")
            }
            Text(saveState ?? (context.canEdit ? "How this Bot's mark looks everywhere"
                                               : "This computer doesn't let the app change this bot."))
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.tertiaryText)
                .padding(.horizontal, BighelpTokens.space20)
                .accessibilityIdentifier("simple-bots.profile.mark-status")

            SimpleBotsCard {
                Button { isInstructionsPresented = true } label: {
                    SimpleBotsRow(title: "Instructions", leading: Image(systemName: "doc.text"))
                }
                .buttonStyle(.plain)
                .disabled(!context.canEdit)
                .accessibilityIdentifier("simple-bots.profile.instructions")
                if let modelDefaults {
                    SimpleBotsDivider()
                    Button { isModelPresented = true } label: {
                        SimpleBotsRow(title: "Default Model", leading: Image(systemName: "cpu"),
                                      value: modelName(modelDefaults))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("simple-bots.profile.default-model")
                }
            }
            .padding(.top, BighelpTokens.space12)

            routines(profile)
        }
    }

    @ViewBuilder
    private func routines(_ profile: AgentProfile) -> some View {
        if let store = context.scheduledTasks {
            let tasks = store.tasks.filter { $0.agentID == profile.id }
            SimpleBotsSectionLabel(title: "Routines")
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
            SimpleBotFilesTab(model: files, botName: profile.name) { id in
                context.agents.profiles.first { $0.id == id }?.name ?? "another bot"
            }
        } else {
            SimpleBotsMessageCard(systemImage: "wifi.slash", title: "Your computer isn't connected",
                                  detail: "\(profile.name)'s files show up here once it's back.")
        }
    }

    private func mediaTab(_ profile: AgentProfile) -> some View {
        SimpleBotMediaTab(agentID: profile.id, botName: profile.name, store: media, isConnected: isMediaConnected)
    }

    /// Shows the pick at once; saves it to the host once picking settles.
    private func pick(_ newMark: SimpleBotMark, for profile: AgentProfile) {
        mark = newMark
        SimpleBotMarkStore.shared.set(newMark, scope: scope, agentID: profile.id)
        saveTask?.cancel()
        saveState = "Saving…"
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
                saveState = "Saved. This is how \(profile.name) looks everywhere."
            } catch {
                guard !Task.isCancelled else { return }
                saveState = "Saved on this device. The computer didn't take the picture; try again later."
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
        saveState = "Saving…"
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
                saveState = "Saved. This is how \(profile.name) looks everywhere."
            } catch {
                guard !Task.isCancelled else { return }
                saveState = "The computer didn't take the new avatar. Try again."
            }
        }
    }

    private func modelName(_ defaults: AgentRuntimeDefaultsEditorModel) -> String {
        let modelID = defaults.draft[.mainChats].modelID
        return modelID.isEmpty ? "Automatic" : ModelNameCatalog.empty.displayName(for: modelID)
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
                TextEditor(text: $text)
                    .font(.bighelp(.body))
                    .scrollContentBackground(.hidden)
                    .padding(BighelpTokens.space12)
                    .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
                    .accessibilityIdentifier("simple-bots.instructions.editor")
                if let errorMessage {
                    Text(errorMessage).font(.bighelp(.subheadline)).foregroundStyle(theme.danger)
                }
            }
            .padding(BighelpTokens.space16)
            .background(theme.canvas.ignoresSafeArea())
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
            errorMessage = "The computer didn't save that. Your text is still here; try again."
        }
    }
}
