import SwiftUI

/// What the choices row under New chat's message box needs. The shell gives one only for exactly one
/// picked bot on a computer with a `CodeHomeStore`; without it there's no row.
@MainActor
struct NewChatChoicesContext {
    let session: NewChatSession
    let store: CodeHomeStore
    /// The picked bot's profile on the store's computer. Projects are each bot's own.
    let agentID: String
    /// The message box holds text (from `ChatModel.draftShape`): Stage needs it, Send all counts it.
    let hasText: Bool
    /// The box's text, read only when a chip needs it: Stage, and the branch name the picker suggests.
    let draft: @MainActor () -> String
    /// Empties the box once Stage has taken its text.
    let clearDraft: @MainActor () -> Void
    let onWorktrees: @MainActor () -> Void
    /// Starts the staged jobs and the box's text as one batch (`CodeHomeStore.sendAll(including:)`).
    let onSendAll: @MainActor () -> Void
}

/// New chat's choices for one bot, in one row that scrolls sideways and never wraps: Project (none is
/// an ordinary chat), then, once a project is picked, where it runs (a new worktree or local), the
/// branch, the mode (Hermes' Plan and YOLO) and Stage. It reads and writes `CodeHomeStore` as Code
/// mode's message box does. Staged jobs show in a tray above it, with Send all. Equatable, so the
/// chat's redraws leave it alone: a chip change redraws only the row, through Observation.
struct NewChatChoicesRow: View, Equatable {
    let context: NewChatChoicesContext
    @State private var isPickingProject = false
    @State private var isPickingBranch = false
    /// The box's text when the branch picker opened, for the name it suggests.
    @State private var branchMessage = ""
    /// The store's project when its picker opened: a pick there becomes the chat's project.
    @State private var projectBeforePicker: String?
    @BighelpThemeReader private var theme

    /// What `==` compares, kept apart from the context's closures, which it never reads.
    private let session: NewChatSession
    private let store: CodeHomeStore
    private let agentID: String
    private let hasText: Bool

    init(context: NewChatChoicesContext) {
        self.context = context
        session = context.session
        store = context.store
        agentID = context.agentID
        hasText = context.hasText
    }

    nonisolated static func == (lhs: NewChatChoicesRow, rhs: NewChatChoicesRow) -> Bool {
        lhs.session === rhs.session && lhs.store === rhs.store
            && lhs.agentID == rhs.agentID && lhs.hasText == rhs.hasText
    }

    var body: some View {
        if session.recipients.count == 1 {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                if session.project != nil, !store.projectStaged.isEmpty {
                    NewChatStagedTray(store: store, hasText: hasText, onSendAll: context.onSendAll)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: BighelpTokens.space8) {
                        projectChip
                        if session.project != nil {
                            placementMenu
                            branchChip
                            modeMenu
                            stageChip
                        }
                    }
                    .padding(.horizontal, BighelpTokens.space4)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.bottom, BighelpTokens.space8)
            .bighelpSheet(isPresented: $isPickingProject, onDismiss: adoptPickedProject) {
                CodeProjectPicker(store: store)
                    .bighelpSheetSize(.standard)
            }
            .bighelpSheet(isPresented: $isPickingBranch) {
                CodeBranchPicker(store: store, message: branchMessage)
                    .bighelpSheetSize(.standard)
            }
            // Work or another chat changed the store's project: this chat's follows while it has one.
            .onChange(of: store.projectID) { _, _ in
                if session.project != nil, let project = store.project { session.project = project }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("new-chat.choices")
        }
    }

    // MARK: Project

    /// The store's projects are its bot's: until it's on this one, the chip opens the picker after
    /// switching it, so nothing changes until the person taps.
    @ViewBuilder
    private var projectChip: some View {
        let label = CodeChipLabel(systemImage: "folder", text: session.project?.name ?? String(localized: "Project"))
        if store.agentID == agentID {
            Menu {
                Button { session.project = nil } label: {
                    Label("No project", systemImage: session.project == nil ? "checkmark" : "bubble.left")
                }
                .accessibilityIdentifier("new-chat.project.none")
                if !store.projects.isEmpty {
                    Section("Projects") {
                        ForEach(store.projects) { project in
                            Button { pick(project) } label: {
                                Label(project.name, systemImage: session.project?.id == project.id ? "checkmark" : "folder")
                            }
                            .accessibilityIdentifier("new-chat.project.\(project.id)")
                        }
                    }
                }
                Button("More projects…", systemImage: "ellipsis.circle") { openProjectPicker() }
                    .accessibilityIdentifier("new-chat.project.more")
            } label: {
                label
            }
            .accessibilityLabel(projectLabel)
            .accessibilityIdentifier("new-chat.chip.project")
            .task(id: agentID) { if store.projects.isEmpty { await store.load() } }
        } else {
            Button {
                Task {
                    await store.selectAgent(agentID)
                    openProjectPicker()
                }
            } label: {
                label
            }
            .bighelpPlainButtonStyle(.capsule)
            .accessibilityLabel(projectLabel)
            .accessibilityIdentifier("new-chat.chip.project")
        }
    }

    private var projectLabel: String {
        session.project.map { String(localized: "Project: \($0.name)") } ?? String(localized: "Project: none")
    }

    private func pick(_ project: CodeProject) {
        session.project = project
        Task { await store.selectProject(project.id) }
    }

    private func openProjectPicker() {
        projectBeforePicker = store.projectID
        isPickingProject = true
    }

    /// The picker selects in the store; a project picked there (or added) becomes this chat's.
    private func adoptPickedProject() {
        guard store.projectID != projectBeforePicker, let project = store.project else { return }
        session.project = project
    }

    // MARK: Where it runs, branch, mode

    private var placementMenu: some View {
        Menu {
            Section("Where should this chat run?") {
                ForEach(CodePlacement.allCases) { placement in
                    Button {
                        store.placement = placement
                        store.branch = nil
                    } label: {
                        Label(placement.title,
                              systemImage: store.placement == placement ? "checkmark" : placement.systemImage)
                        Text(detail(for: placement))
                    }
                    .accessibilityIdentifier("new-chat.placement.\(placement.rawValue)")
                }
            }
            Button("Manage worktrees", systemImage: "square.stack.3d.up") { context.onWorktrees() }
        } label: {
            CodeChipLabel(systemImage: store.placement.systemImage, text: store.placement.title)
        }
        .accessibilityLabel(String(localized: "Where it runs: \(store.placement.title)"))
        .accessibilityIdentifier("new-chat.chip.placement")
    }

    /// Local warns about the chats already working in the project's folder.
    private func detail(for placement: CodePlacement) -> String {
        let busy = store.sessionsInMainFolder
        guard placement == .local, busy > 0 else { return placement.detail }
        return busy == 1 ? String(localized: "1 chat is already working here.")
                         : String(localized: "\(busy) chats are already working here.")
    }

    private var branchChip: some View {
        Button {
            branchMessage = context.draft()
            isPickingBranch = true
        } label: {
            CodeChipLabel(systemImage: "arrow.triangle.branch",
                          text: store.branchTitle ?? String(localized: "Branch"), monospaced: true)
        }
        .bighelpPlainButtonStyle(.capsule)
        .disabled(store.git == nil)
        .accessibilityLabel(String(localized: "Branch: \(store.branchTitle ?? String(localized: "default"))"))
        .accessibilityIdentifier("new-chat.chip.branch")
    }

    private var modeMenu: some View {
        Menu {
            Section("How should this chat work?") {
                ForEach(CodeSessionMode.allCases) { mode in
                    Button {
                        store.mode = mode
                    } label: {
                        Label(mode.title, systemImage: store.mode == mode ? "checkmark" : mode.systemImage)
                        Text(mode.detail)
                    }
                    .accessibilityIdentifier("new-chat.mode.\(mode.rawValue)")
                }
            }
        } label: {
            CodeChipLabel(systemImage: store.mode.systemImage, text: store.mode.title)
        }
        .accessibilityLabel(String(localized: "Mode: \(store.mode.title)"))
        .accessibilityIdentifier("new-chat.chip.mode")
    }

    /// Keeps the box's text, with the chips as they are, for Send all.
    private var stageChip: some View {
        Button {
            if store.stage(context.draft()) { context.clearDraft() }
        } label: {
            CodeChipLabel(systemImage: "rectangle.stack.badge.plus", text: String(localized: "Stage"))
        }
        .bighelpPlainButtonStyle(.capsule)
        .disabled(!hasText || store.project == nil)
        .accessibilityIdentifier("new-chat.chip.stage")
    }
}

/// The project's staged jobs over the choices row, each with the chips it was staged with, and Send
/// all. Send all is in this tray: New chat's own Send
/// button never changes for it.
private struct NewChatStagedTray: View {
    let store: CodeHomeStore
    let hasText: Bool
    let onSendAll: @MainActor () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        let jobs = store.projectStaged
        let count = jobs.count + (hasText ? 1 : 0)
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                Text("Staged").font(.bighelp(.subheadline).weight(.semibold))
                    + Text(jobs.count == 1 ? " · 1 job" : " · \(jobs.count) jobs")
                    .font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Button("Clear") { store.clearStaged() }
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .bighelpPlainButtonStyle()
                    .accessibilityIdentifier("new-chat.staged.clear")
                sendAll(count)
            }
            ScrollView {
                VStack(spacing: BighelpTokens.space8) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        row(job, number: index + 1)
                    }
                }
            }
            .frame(height: CGFloat(min(jobs.count, 3)) * BighelpTokens.scaled(56)
                   + CGFloat(max(min(jobs.count, 3) - 1, 0)) * BighelpTokens.space8)
            .scrollIndicators(.hidden)
        }
        .padding(BighelpTokens.space12)
        .background(theme.surface, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(theme.border, lineWidth: BighelpTokens.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-chat.staged")
    }

    private func sendAll(_ count: Int) -> some View {
        Button(action: onSendAll) {
            Text("Send all \(count)")
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(theme.actionForeground)
                .lineLimit(1)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: BighelpTokens.scaled(34))
                .background(theme.action, in: .capsule)
                .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle(.capsule)
        .disabled(store.project == nil || count == 0)
        .accessibilityIdentifier("new-chat.staged.send-all")
    }

    private func row(_ job: CodeStagedJob, number: Int) -> some View {
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
                Label(detail(job), systemImage: job.placement.systemImage)
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
                .accessibilityIdentifier("new-chat.staged.remove.\(number)")
        }
        .padding(.horizontal, BighelpTokens.space8)
        .frame(minHeight: BighelpTokens.scaled(56))
        .background(theme.raisedSurface, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-chat.staged.job.\(number)")
    }

    private func detail(_ job: CodeStagedJob) -> String {
        let model = job.runtime.modelID.map { ModelNameCatalogStore.shared.displayName(for: $0) }
            ?? String(localized: "Bot's model")
        return [job.placement.title, job.branch, model, job.mode == .standard ? nil : job.mode.title]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
