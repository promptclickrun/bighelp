import SwiftUI

/// Bighelp IDE's message box: the text with Send beside it, then a line with the agent
/// (its chip opens the model, reasoning and fast mode for new sessions), the mode
/// (Default, Plan, YOLO) and Stage, each a full-size target. Under it, three chips choose
/// the project, where the session works (a new worktree or the local checkout) and its
/// branch; they stay set after each send, so the next message starts the next session
/// right away. Typing `/` first shows the new session's commands and skills.
/// Orchestration mode: Stage keeps the message (with the chips as they are) in a tray
/// above the box, and Send all starts every staged job as one batch.
struct CodeComposer: View {
    @Bindable var store: CodeHomeStore
    let agents: [AgentProfile]
    var avatarURL: (AgentProfile) -> URL? = { _ in nil }
    let onWorktrees: () -> Void
    @State private var message = ""
    @State private var isPickingProject = false
    @State private var isPickingBranch = false
    @State private var isPickingRuntime = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if isTypingCommand {
                slashList
                    .transition(.opacity)
            }
            if !store.projectStaged.isEmpty {
                stagedTray
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                HStack(alignment: .bottom, spacing: BighelpTokens.space8) {
                    TextField("Describe a change…", text: $message, axis: .vertical)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1...6)
                        .focused($isFocused)
                        .padding(.vertical, BighelpTokens.space8)
                        .bighelpMacFieldArea()
                        .accessibilityIdentifier("code.composer.field")
                    if hasStaged {
                        sendAllButton
                            .fixedSize()
                    } else {
                        sendButton
                            .fixedSize()
                    }
                }
                HStack(spacing: BighelpTokens.space8) {
                    agentChip
                        .layoutPriority(-1)
                    modeMenu
                        .fixedSize()
                    Spacer(minLength: 0)
                    stageButton
                        .fixedSize()
                }
            }
            .padding(.leading, BighelpTokens.space16)
            .padding(.trailing, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space12)
            .bighelpSurface(.composer)
            ScrollView(.horizontal) {
                HStack(spacing: BighelpTokens.space8) {
                    projectChip
                    placementMenu
                    branchChip
                }
                .padding(.horizontal, BighelpTokens.space4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.bottom, BighelpTokens.space8)
        .bighelpSheet(isPresented: $isPickingProject) {
            CodeProjectPicker(store: store)
                .bighelpSheetSize(.standard)
        }
        .bighelpSheet(isPresented: $isPickingBranch) {
            CodeBranchPicker(store: store, message: message)
                .bighelpSheetSize(.standard)
        }
        .bighelpSheet(isPresented: $isPickingRuntime) {
            CodeRuntimePicker(store: store, agents: agents, avatarURL: avatarURL)
                .bighelpSheetSize(.standard)
        }
        .task(id: isTypingCommand) {
            if isTypingCommand { await store.loadCommandsIfNeeded() }
        }
    }

    // MARK: The / list

    /// A `/` with no space after it yet: the list is open.
    private var isTypingCommand: Bool {
        message.hasPrefix("/") && !message.contains(where: \.isWhitespace)
    }

    private var matchingCommands: [SlashCommandDescriptor] {
        SlashCommandIndex(commands: store.commands).suggestions(for: message).sorted { lhs, rhs in
            if (lhs.source == .skill) != (rhs.source == .skill) { return lhs.source == .skill }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var slashList: some View {
        let commands = matchingCommands
        return BighelpSuggestionList(
            suggestions: commands.map { command in
                BighelpSuggestion(id: command.name,
                                  icon: .symbol(command.source == .skill ? "wand.and.stars" : "command"),
                                  sigil: "/", name: command.name, detail: command.description,
                                  tag: command.source == .skill ? "Skill" : "Command")
            },
            identifier: "code.slash",
            emptyText: store.commandsError ?? (store.commands.isEmpty ? "Loading commands…" : "No matching commands."),
            onPick: { picked in
                guard let command = commands.first(where: { $0.name == picked.id }) else { return }
                message = SlashCommandIndex(commands: [command]).draft(selecting: command)
                isFocused = true
            }
        ) {
            BighelpSuggestionHeader(systemImage: "command", title: "Commands and skills",
                                    count: store.commands.isEmpty ? nil : commands.count,
                                    isLoading: store.commands.isEmpty && store.commandsError == nil)
        }
    }

    // MARK: The mode button

    private var modeMenu: some View {
        Menu {
            Section("How should this session work?") {
                ForEach(CodeSessionMode.allCases) { mode in
                    Button {
                        store.mode = mode
                    } label: {
                        Label(mode.title, systemImage: store.mode == mode ? "checkmark" : mode.systemImage)
                        Text(mode.detail)
                    }
                    .accessibilityIdentifier("code.mode.\(mode.rawValue)")
                }
            }
        } label: {
            HStack(spacing: BighelpTokens.space4) {
                Image(systemName: store.mode.systemImage)
                Text(store.mode.title).lineLimit(1)
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(modeTint)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.scaled(44))
            .background(store.mode == .standard ? theme.raisedSurface : modeTint.opacity(0.14), in: .capsule)
            .contentShape(.capsule)
        }
        .accessibilityLabel("Mode: \(store.mode.title)")
        .accessibilityIdentifier("code.composer.mode")
    }

    private var modeTint: Color {
        switch store.mode {
        case .standard: theme.secondaryText
        case .plan: theme.action
        case .yolo: theme.warning
        }
    }

    /// The agent new sessions start with, by name; it opens the agent, model, reasoning and fast mode.
    private var agentChip: some View {
        let agent = agents.first { $0.id == store.agentID }
        return Button { isPickingRuntime = true } label: {
            HStack(spacing: BighelpTokens.space8) {
                if let agent {
                    AgentLiveAvatar(agentID: agent.id, displayName: agent.name, imageURL: avatarURL(agent),
                                    size: BighelpTokens.scaled(26), showsBadge: false)
                } else {
                    Image(systemName: "person.crop.circle")
                }
                Text(agent?.name ?? "Agent")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.caption2).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(theme.primaryText)
            .padding(.leading, BighelpTokens.space8)
            .padding(.trailing, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.scaled(44))
            .background(theme.raisedSurface, in: .capsule)
            .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityLabel("Agent: \(agent?.name ?? "none"), \(runtimeTitle)")
        .accessibilityHint("Changes the agent, model, reasoning and fast mode for new sessions.")
        .accessibilityIdentifier("code.composer.agent")
    }

    private var runtimeTitle: String {
        let runtime = store.runtime
        var parts = [runtime.modelID.map { ModelNameCatalogStore.shared.displayName(for: $0) } ?? "Agent's model"]
        if let reasoning = runtime.reasoning { parts.append(CodeRuntimeChoice.reasoningLabel(reasoning)) }
        if runtime.fastMode == true { parts.append("Fast") }
        return parts.joined(separator: " · ")
    }

    private var canSend: Bool {
        store.project != nil && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Orchestration mode

    private var hasStaged: Bool { !store.projectStaged.isEmpty }

    /// Staged jobs plus the one in the box, if any.
    private var sendAllCount: Int { store.projectStaged.count + (canSend ? 1 : 0) }

    /// Keeps the message for Send all. With jobs staged it shrinks to its icon, so Send all fits.
    private var stageButton: some View {
        Button {
            if store.stage(message) { message = "" }
        } label: {
            HStack(spacing: BighelpTokens.space4) {
                Image(systemName: "rectangle.stack.badge.plus")
                if !hasStaged { Text("Stage") }
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(canSend ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, hasStaged ? 0 : BighelpTokens.space12)
            .frame(minWidth: BighelpTokens.scaled(44), minHeight: BighelpTokens.scaled(44))
            .background(theme.raisedSurface, in: .capsule)
            .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle(.capsule)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .bighelpIconLabel("Stage for Send all", shortcut: "⇧⌘↩")
        .accessibilityIdentifier("code.composer.stage")
    }

    private var sendAllButton: some View {
        Button {
            if store.sendAll(including: message) != nil { message = "" }
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                Text("Send all").lineLimit(1)
                Text("\(sendAllCount)")
                    .font(.bighelp(.caption).weight(.bold))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(theme.actionForeground.opacity(0.25), in: .capsule)
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(theme.actionForeground)
            .padding(.leading, BighelpTokens.space16)
            .padding(.trailing, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.scaled(44))
            .background(theme.action, in: .capsule)
            .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle(.capsule)
        .disabled(store.project == nil || sendAllCount == 0)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Send all \(sendAllCount)")
        .accessibilityIdentifier("code.composer.send-all")
    }

    /// The staged jobs, each with the chips it was staged with; a tap on × takes one out.
    private var stagedTray: some View {
        let jobs = store.projectStaged
        return VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack {
                Text("Staged").font(.bighelp(.subheadline).weight(.semibold))
                    + Text(jobs.count == 1 ? " · 1 job" : " · \(jobs.count) jobs")
                    .font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Button("Clear") { store.clearStaged() }
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("code.staged.clear")
            }
            ScrollView {
                VStack(spacing: BighelpTokens.space8) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        stagedRow(job, number: index + 1)
                    }
                }
            }
            .frame(height: CGFloat(min(jobs.count, 3)) * BighelpTokens.scaled(56)
                   + CGFloat(min(jobs.count, 3) - 1) * BighelpTokens.space8)
            .scrollIndicators(.hidden)
        }
        .padding(BighelpTokens.space12)
        .background(theme.surface, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(theme.border, lineWidth: BighelpTokens.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.staged")
    }

    private func stagedRow(_ job: CodeStagedJob, number: Int) -> some View {
        let color = CodeSessionColor.color(at: number - 1)
        return HStack(spacing: BighelpTokens.space12) {
            Text("\(number)")
                .font(.bighelp(.caption).weight(.bold))
                .foregroundStyle(color)
                .frame(width: BighelpTokens.scaled(22), height: BighelpTokens.scaled(22))
                .background(color.opacity(0.2), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.bighelp(.subheadline).weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Label(stagedDetail(job), systemImage: job.placement.systemImage)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove", systemImage: "xmark") { store.unstage(job.id) }
                .labelStyle(.iconOnly)
                .font(.bighelp(.footnote).weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("code.staged.remove.\(number)")
        }
        .padding(.horizontal, BighelpTokens.space8)
        .frame(minHeight: BighelpTokens.scaled(56))
        .background(theme.raisedSurface, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.staged.job.\(number)")
    }

    private func stagedDetail(_ job: CodeStagedJob) -> String {
        let model = job.runtime.modelID.map { ModelNameCatalogStore.shared.displayName(for: $0) } ?? "Agent's model"
        return [job.placement.title, job.branch, model, job.mode == .standard ? nil : job.mode.title]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var sendButton: some View {
        Button {
            if store.send(message) { message = "" }
        } label: {
            Image(systemName: "arrow.up")
                .font(.bighelp(.body).weight(.bold))
                .foregroundStyle(canSend ? theme.actionForeground : theme.secondaryText)
                .frame(width: BighelpTokens.scaled(44), height: BighelpTokens.scaled(44))
                .background(canSend ? theme.action : theme.raisedSurface, in: .circle)
                .contentShape(.circle)
        }
        .bighelpPlainButtonStyle(.circle)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .bighelpIconLabel("Start session", shortcut: "⌘↩")
        .accessibilityIdentifier("code.composer.send")
    }

    private var projectChip: some View {
        Button { isPickingProject = true } label: {
            CodeChipLabel(systemImage: "folder", text: store.project?.name ?? "Choose a project")
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityLabel("Project: \(store.project?.name ?? "none")")
        .accessibilityIdentifier("code.chip.project")
    }

    private var placementMenu: some View {
        Menu {
            Section("Where should this session run?") {
                ForEach(CodePlacement.allCases) { placement in
                    Button {
                        store.placement = placement
                        store.branch = nil
                    } label: {
                        Label(placement.title, systemImage: store.placement == placement ? "checkmark" : placement.systemImage)
                        Text(subtitle(for: placement))
                    }
                    .accessibilityIdentifier("code.placement.\(placement.rawValue)")
                }
            }
            Button("Manage worktrees", systemImage: "square.stack.3d.up", action: onWorktrees)
        } label: {
            CodeChipLabel(systemImage: store.placement.systemImage, text: store.placement.title)
        }
        .accessibilityLabel("Where it runs: \(store.placement.title)")
        .accessibilityIdentifier("code.chip.placement")
    }

    private func subtitle(for placement: CodePlacement) -> String {
        let busy = store.sessionsInMainFolder
        guard placement == .local, busy > 0 else { return placement.detail }
        return busy == 1 ? "1 session is already working here." : "\(busy) sessions are already working here."
    }

    private var branchChip: some View {
        Button { isPickingBranch = true } label: {
            CodeChipLabel(systemImage: "arrow.triangle.branch", text: store.branchTitle ?? "Branch", monospaced: true)
        }
        .bighelpPlainButtonStyle(.capsule)
        .disabled(store.git == nil)
        .accessibilityLabel("Branch: \(store.branchTitle ?? "default")")
        .accessibilityIdentifier("code.chip.branch")
    }

    @BighelpThemeReader private var theme
}

struct CodeChipLabel: View {
    let systemImage: String
    let text: String
    var monospaced = false

    var body: some View {
        HStack(spacing: BighelpTokens.space4) {
            Image(systemName: systemImage)
            Text(text)
                .font(monospaced ? .system(.subheadline, design: .monospaced).weight(.medium)
                                 : .bighelp(.subheadline).weight(.medium))
                .lineLimit(1)
        }
        .font(.bighelp(.subheadline))
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, BighelpTokens.space12)
        .frame(minHeight: BighelpTokens.scaled(34))
        .bighelpSurface(.capsuleControl, isInteractive: true)
        .contentShape(.capsule)
    }

    @BighelpThemeReader private var theme
}

/// The project chip's sheet: Hermes projects, then git folders it found that can become one.
struct CodeProjectPicker: View {
    @Bindable var store: CodeHomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var addingPath: String?

    var body: some View {
        NavigationStack {
            List {
                BighelpSearchField(text: $search, accessibilityIdentifier: "code.projects.search")
                    .bighelpListSearchRow()
                Section {
                    if store.projects.isEmpty {
                        if store.isLoading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(store.errorMessage ?? "No projects on this computer yet. Add a folder below.")
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    ForEach(matching(store.projects)) { project in
                        Button {
                            Task { await store.selectProject(project.id) }
                            dismiss()
                        } label: {
                            HStack(spacing: BighelpTokens.space12) {
                                ProjectTile(id: project.id, icon: project.icon, color: project.color, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name).font(.bighelp(.body)).foregroundStyle(theme.primaryText)
                                    Text(project.folder)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(theme.secondaryText)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                Spacer(minLength: 0)
                                if project.id == store.projectID {
                                    Image(systemName: "checkmark").foregroundStyle(theme.action)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .bighelpPlainButtonStyle()
                        .accessibilityIdentifier("code.project.\(project.id)")
                    }
                }
                .listRowBackground(theme.surface)
                if !matching(store.found).isEmpty {
                    Section("Found on your computer") {
                        ForEach(matching(store.found)) { folder in
                            HStack(spacing: BighelpTokens.space12) {
                                Image(systemName: "folder").frame(width: 32).foregroundStyle(theme.secondaryText)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name).font(.bighelp(.body)).foregroundStyle(theme.primaryText)
                                    Text(folder.path)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(theme.secondaryText)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                Spacer(minLength: 0)
                                if addingPath == folder.path {
                                    ProgressView()
                                } else {
                                    Button("Add") {
                                        addingPath = folder.path
                                        Task {
                                            await store.addProject(folder)
                                            addingPath = nil
                                            if store.project?.folder == folder.path { dismiss() }
                                        }
                                    }
                                    .font(.bighelp(.subheadline).weight(.semibold))
                                    .accessibilityIdentifier("code.found.add")
                                }
                            }
                        }
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await store.load() }
            .task { if store.projects.isEmpty { await store.load() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.projects")
    }

    private func matching(_ projects: [CodeProject]) -> [CodeProject] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(term) || $0.folder.localizedCaseInsensitiveContains(term) }
    }

    private func matching(_ folders: [CodeFoundFolder]) -> [CodeFoundFolder] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(term) || $0.path.localizedCaseInsensitiveContains(term) }
    }

    @BighelpThemeReader private var theme
}

/// The branch chip's sheet. New worktree: the new branch's name (named from the
/// message unless changed) and the branch it starts from. Local: the branch to
/// check out in the project's folder.
struct CodeBranchPicker: View {
    @Bindable var store: CodeHomeStore
    let message: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var newBranch = ""

    var body: some View {
        NavigationStack {
            List {
                if store.placement == .newWorktree {
                    Section {
                        TextField(suggested, text: $newBranch)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("code.branch.new")
                    } header: {
                        Text("New branch")
                    } footer: {
                        Text("Named from your message unless you type a name.")
                    }
                    .listRowBackground(theme.surface)
                }
                BighelpSearchField(text: $search, prompt: "Search branches", accessibilityIdentifier: "code.branch.search")
                    .bighelpListSearchRow()
                Section(store.placement == .newWorktree ? "Start from" : "Branch") {
                    ForEach(matching(localBranches)) { branch in
                        branchRow(branch)
                    }
                }
                .listRowBackground(theme.surface)
                if store.placement == .local, !matching(remoteBranches).isEmpty {
                    Section("On GitHub") {
                        ForEach(matching(remoteBranches)) { branch in
                            Text(branch.name)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(store.placement == .newWorktree ? "Start from" : "Branch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let name = newBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.newBranchName = name.isEmpty ? nil : name
                        dismiss()
                    }
                    .accessibilityIdentifier("code.branch.done")
                }
            }
            .onAppear { newBranch = store.newBranchName ?? "" }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.branches")
    }

    private var suggested: String {
        let taken = Set(store.git?.branches.map(\.name) ?? [])
        return CodeBranchName.suggested(for: message.isEmpty ? "change" : message, taken: taken)
    }

    /// Worktrees start from base branches; Local checks out a local branch.
    private var localBranches: [StockGitBranch] {
        guard let git = store.git else { return [] }
        return store.placement == .newWorktree ? git.baseBranches : git.branches.filter { !$0.isRemote }
    }

    private var remoteBranches: [StockGitBranch] {
        store.git?.branches.filter(\.isRemote) ?? []
    }

    private func branchRow(_ branch: StockGitBranch) -> some View {
        let selected = branch.name == store.branchTitle
        // A branch checked out in another worktree can't be checked out here too.
        let busyElsewhere = store.placement == .local && branch.worktreePath != nil
            && branch.worktreePath != store.project?.folder
        return Button {
            store.branch = branch.name
            dismiss()
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(theme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(branch.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(busyElsewhere ? theme.secondaryText : theme.primaryText)
                    if let note = note(for: branch) {
                        Text(note).font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(theme.action) }
            }
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .disabled(busyElsewhere)
        .accessibilityIdentifier("code.branch.\(branch.name)")
    }

    private func note(for branch: StockGitBranch) -> String? {
        if branch.isDefault { return "Default" }
        guard let path = branch.worktreePath else { return nil }
        return path == store.project?.folder ? "Checked out in the local folder" : "In a worktree"
    }

    private func matching(_ branches: [StockGitBranch]) -> [StockGitBranch] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    @BighelpThemeReader private var theme
}

/// The agent chip's sheet: the agent new sessions run with, then its model (or the agent's
/// own), reasoning level and fast mode. Each session applies them before its first message.
struct CodeRuntimePicker: View {
    @Bindable var store: CodeHomeStore
    var agents: [AgentProfile] = []
    var avatarURL: (AgentProfile) -> URL? = { _ in nil }
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [BighelpLinkModelProvider] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Form {
                if agents.count > 1 {
                    Section("Agent") {
                        ForEach(agents) { agent in
                            Button {
                                Task { await store.selectAgent(agent.id) }
                            } label: {
                                HStack(spacing: BighelpTokens.space12) {
                                    AgentLiveAvatar(agentID: agent.id, displayName: agent.name, imageURL: avatarURL(agent),
                                                    size: BighelpTokens.scaled(30), showsBadge: false)
                                    Text(agent.name).foregroundStyle(theme.primaryText)
                                    Spacer(minLength: 0)
                                    if agent.id == store.agentID {
                                        Image(systemName: "checkmark").foregroundStyle(theme.action)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .bighelpPlainButtonStyle()
                            .accessibilityIdentifier("code.runtime.agent.\(agent.id)")
                        }
                    }
                    .listRowBackground(theme.surface)
                }
                Section("Model") {
                    NavigationLink {
                        modelList
                    } label: {
                        LabeledContent("Model", value: modelTitle)
                    }
                    .accessibilityIdentifier("code.runtime.model")
                }
                .listRowBackground(theme.surface)
                Section {
                    Picker("Reasoning", selection: $store.runtime.reasoning) {
                        Text("Agent's setting").tag(String?.none)
                        ForEach(CodeRuntimeChoice.reasoningLevels, id: \.value) { level in
                            Text(level.label).tag(Optional(level.value))
                        }
                    }
                    .accessibilityIdentifier("code.runtime.reasoning")
                    Picker("Fast mode", selection: $store.runtime.fastMode) {
                        Text("Agent's setting").tag(Bool?.none)
                        Text("On").tag(Optional(true))
                        Text("Off").tag(Optional(false))
                    }
                    .disabled(fastModeUnavailable != nil)
                    .accessibilityIdentifier("code.runtime.fast")
                } footer: {
                    Text(fastModeUnavailable ?? "Each new session checks these with Hermes before your message goes out.")
                }
                .listRowBackground(theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(agents.first { $0.id == store.agentID }?.name ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // Models are the agent's own: a new agent loads its list.
            .task(id: store.agentID) { await load() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.runtime")
    }

    private var modelTitle: String {
        store.runtime.modelID.map { ModelNameCatalogStore.shared.displayName(for: $0) } ?? "Agent's model"
    }

    /// Fast mode needs a chosen model that supports it.
    private var fastModeUnavailable: String? {
        guard let modelID = store.runtime.modelID else { return "Choose a model to use Fast Mode." }
        return FastMode.unavailableReason(provider: providers.first { $0.id == store.runtime.providerID },
                                          model: modelID)
    }

    private var modelList: some View {
        List {
            BighelpSearchField(text: $search, prompt: "Search models", accessibilityIdentifier: "code.runtime.search")
                .bighelpListSearchRow()
            Section {
                modelRow(title: "Agent's model", providerID: nil, modelID: nil)
            }
            .listRowBackground(theme.surface)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let loadError {
                Text(loadError).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
            }
            ForEach(providers.filter { !matching($0).isEmpty }) { provider in
                Section(provider.name) {
                    ForEach(matching(provider), id: \.self) { model in
                        modelRow(title: ModelNameCatalogStore.shared.displayName(for: model),
                                 providerID: provider.id, modelID: model)
                    }
                }
                .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modelRow(title: String, providerID: String?, modelID: String?) -> some View {
        Button {
            store.runtime.providerID = providerID
            store.runtime.modelID = modelID
            if fastModeUnavailable != nil { store.runtime.fastMode = nil }
        } label: {
            HStack {
                Text(title).foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
                if store.runtime.providerID == providerID && store.runtime.modelID == modelID {
                    Image(systemName: "checkmark").foregroundStyle(theme.action)
                }
            }
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier(providerID.map { "code.runtime.model.\($0).\(modelID ?? "")" } ?? "code.runtime.model.agent")
    }

    private func matching(_ provider: BighelpLinkModelProvider) -> [String] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return provider.models }
        return provider.models.filter {
            $0.localizedCaseInsensitiveContains(term)
                || ModelNameCatalogStore.shared.displayName(for: $0).localizedCaseInsensitiveContains(term)
                || provider.name.localizedCaseInsensitiveContains(term)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            providers = try await store.modelProviders()
            loadError = providers.isEmpty ? "No models found for this agent." : nil
        } catch is CancellationError {
        } catch {
            loadError = "Models couldn't load. \(error.localizedDescription)"
        }
    }

    @BighelpThemeReader private var theme
}
