import SwiftUI

/// One card, opened: what's happening, what the agent needs from you, and a
/// short thread with its runs and messages. Everything here is Hermes' own.
struct KanbanTaskSheet: View {
    @Bindable var model: KanbanBoardModel
    let taskID: String
    var isNerdMode = false

    @Environment(\.dismiss) private var dismiss
    @State private var detail: HermesKanbanTaskDetail?
    @State private var message = ""
    @State private var isSending = false
    @State private var isEditing = false
    @State private var draftTitle = ""
    @State private var draftDetails = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let task {
                    ScrollView {
                        VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                            header(task)
                            if task.lane == .needsYou { KanbanNeedsYouCard(model: model, task: task, detail: detail,
                                                                          answer: { composerFocused = true }) }
                            if let summary = task.latestSummary, !summary.isEmpty, task.lane != .needsYou {
                                section("Latest") { Text(summary).bighelpFont(.body) }
                            }
                            details(task)
                            if let detail, !thread(detail).isEmpty {
                                section("Activity") { KanbanThread(model: model, items: thread(detail)) }
                            }
                            relations(task)
                            if isNerdMode { KanbanNerdDetails(task: task, detail: detail) }
                        }
                        .padding(BighelpTokens.space20)
                        .padding(.bottom, BighelpTokens.space24)
                    }
                    .dismissesKeyboardOnScroll(true)
                    .safeAreaInset(edge: .bottom) { composer(task) }
                    .toolbar { toolbar(task) }
                } else {
                    ContentUnavailableView("This card is gone", systemImage: "rectangle.dashed",
                                           description: Text("It may have been archived on your computer."))
                }
            }
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .task { await reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban.task-sheet")
    }

    private var task: HermesKanbanTask? { model.task(taskID) }

    // MARK: Sections

    private func header(_ task: HermesKanbanTask) -> some View {
        let lane = task.lane ?? .later
        return VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(spacing: BighelpTokens.space8) {
                Label(lane.title, systemImage: lane.symbol)
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(lane.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(lane.tint.opacity(0.13), in: .capsule)
                if let note = task.statusNote {
                    Text(note).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                priorityMenu(task)
            }
            if isEditing {
                TextField("Title", text: $draftTitle, axis: .vertical)
                    .font(.bighelp(.title2).weight(.bold))
                    .accessibilityIdentifier("kanban.task.title-field")
            } else {
                Text(task.title)
                    .font(.bighelp(.title2).weight(.bold))
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
            }
            agentMenu(task)
        }
    }

    private func priorityMenu(_ task: HermesKanbanTask) -> some View {
        Menu {
            ForEach(KanbanPriority.allCases.reversed()) { priority in
                Button { Task { await model.setPriority(task, priority) } } label: {
                    Label(priority.title, systemImage: task.urgency == priority ? "checkmark" : "flag")
                }
            }
        } label: {
            Label(task.urgency.title, systemImage: task.urgency.rawValue > 0 ? "flag.fill" : "flag")
                .font(.bighelp(.subheadline).weight(.medium))
                .foregroundStyle(task.urgency == .urgent ? KanbanLane.needsYou.tint
                                 : task.urgency == .high ? theme.warning : theme.secondaryText)
        }
        .kanbanMacMenu(.bordered)
        .accessibilityLabel("Priority: \(task.urgency.title)")
        .accessibilityIdentifier("kanban.task.priority")
    }

    private func agentMenu(_ task: HermesKanbanTask) -> some View {
        Menu {
            Button { Task { await model.assign(task, to: nil) } } label: {
                Label("Anyone", systemImage: task.assignee == nil ? "checkmark" : "person.crop.circle.badge.questionmark")
            }
            ForEach(model.assignableAgents) { agent in
                Button { Task { await model.assign(task, to: agent.id) } } label: {
                    Label(agent.name, systemImage: task.assignee == agent.id ? "checkmark" : "person")
                }
            }
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                if let agent = model.agent(task.assignee) {
                    AvatarView(stableID: agent.id, displayName: agent.name, imageURL: agent.imageURL, size: 30)
                    Text(agent.name).font(.bighelp(.body).weight(.semibold)).foregroundStyle(theme.primaryText)
                } else {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.bighelp(.title2)).foregroundStyle(theme.secondaryText)
                    Text("Anyone can take this").font(.bighelp(.body).weight(.semibold)).foregroundStyle(theme.primaryText)
                }
                Image(systemName: "chevron.up.chevron.down").font(.bighelp(.caption).weight(.semibold)).foregroundStyle(theme.tertiaryText)
                Spacer(minLength: 0)
                Text(task.createdAt, format: .relative(presentation: .named))
                    .font(.bighelp(.caption)).foregroundStyle(theme.tertiaryText)
            }
            .contentShape(.rect)
        }
        .kanbanMacMenu(.asDrawn)
        .accessibilityLabel("Bot: \(model.agent(task.assignee)?.name ?? "anyone")")
        .accessibilityHint("Give this card to another bot.")
        .accessibilityIdentifier("kanban.task.agent")
    }

    @ViewBuilder private func details(_ task: HermesKanbanTask) -> some View {
        if isEditing {
            section("Details") {
                TextField("Add details for the bot", text: $draftDetails, axis: .vertical)
                    .lineLimit(3...12)
                    .accessibilityIdentifier("kanban.task.details-field")
            }
        } else if let body = task.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            section("Details") {
                MarkdownMessageView(document: MarkdownDocument(body)).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func relations(_ task: HermesKanbanTask) -> some View {
        if task.childCount > 0 || task.parentCount > 0 {
            section("Connected cards") {
                VStack(alignment: .leading, spacing: 6) {
                    if task.childCount > 0 {
                        Label("Split into \(task.childCount) smaller task\(task.childCount == 1 ? "" : "s")",
                              systemImage: "square.stack.3d.up")
                    }
                    if task.parentCount > 0 {
                        Label("Waits on \(task.parentCount) other task\(task.parentCount == 1 ? "" : "s")",
                              systemImage: "arrow.turn.down.right")
                    }
                }
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(title.uppercased())
                .font(.bighelp(.caption).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(theme.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Composer

    private func composer(_ task: HermesKanbanTask) -> some View {
        let name = model.agent(task.assignee)?.name.split(separator: " ").first.map(String.init)
        let prompt = task.status == .review ? "What should change?"
            : task.status == .blocked && task.blockKind == "needs_input" ? "Answer \(name ?? "the bot")…"
            : "Tell \(name ?? "the bot") something…"
        return HStack(alignment: .bottom, spacing: BighelpTokens.space8) {
            TextField(prompt, text: $message, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, BighelpTokens.space12)
                .padding(.vertical, 10)
                .background(theme.surface, in: .rect(cornerRadius: 20, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border, lineWidth: BighelpTokens.hairline) }
                .accessibilityIdentifier("kanban.task.composer")
            Button { Task { await send(task) } } label: {
                Image(systemName: "arrow.up")
                    .font(.bighelp(.body).weight(.bold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(width: 38, height: 38)
                    .background(theme.action, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            .opacity(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("kanban.task.send")
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .background(.bar)
    }

    private func send(_ task: HermesKanbanTask) async {
        isSending = true
        defer { isSending = false }
        // A reply to a question or a review goes back to the agent to act on.
        let sent = task.lane == .needsYou
            ? await model.reply(message, to: task)
            : await model.comment(message, on: task) != nil
        if sent {
            message = ""
            await reload()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private func toolbar(_ task: HermesKanbanTask) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isEditing {
                Button("Cancel") { isEditing = false }.keyboardShortcut(.cancelAction).bighelpToolbarText()
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .bighelpToolbarText()
                    .accessibilityIdentifier("kanban.task.done")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isEditing {
                Button("Save") {
                    isEditing = false
                    Task { await model.rename(task, title: draftTitle, details: draftDetails) }
                }
                .fontWeight(.semibold)
                .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Menu {
                    Button {
                        draftTitle = task.title
                        draftDetails = task.body ?? ""
                        isEditing = true
                    } label: { Label("Edit", systemImage: "pencil") }
                    Menu {
                        ForEach(KanbanLane.allCases.filter { $0.accepts(task) }) { lane in
                            Button { Task { await model.move(task, to: lane) } } label: {
                                Label(lane.title, systemImage: lane.symbol)
                            }
                        }
                    } label: { Label("Move to", systemImage: "arrow.right.square") }
                    Divider()
                    Button(role: .destructive) {
                        Task { await model.archive(task); dismiss() }
                    } label: { Label("Archive", systemImage: "archivebox") }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Card options")
                .accessibilityIdentifier("kanban.task.options")
            }
        }
    }

    // MARK: Data

    private func reload() async {
        guard let task else { return }
        if let value = await model.detail(task) { detail = value }
    }

    private func thread(_ detail: HermesKanbanTaskDetail) -> [KanbanThread.Item] {
        (detail.comments.map(KanbanThread.Item.comment) + detail.runs.map(KanbanThread.Item.run)
            + KanbanThread.notableEvents(detail).map(KanbanThread.Item.event))
            .sorted { $0.date < $1.date }
    }

    @BighelpThemeReader private var theme
}

// MARK: - Needs you

/// What the agent is waiting on, with the one-tap answers.
struct KanbanNeedsYouCard: View {
    @Bindable var model: KanbanBoardModel
    let task: HermesKanbanTask
    let detail: HermesKanbanTaskDetail?
    let answer: () -> Void

    var body: some View {
        let name = model.agent(task.assignee)?.name.split(separator: " ").first.map(String.init) ?? "Your bot"
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Label(title(name), systemImage: symbol)
                .font(.bighelp(.headline))
                .foregroundStyle(KanbanLane.needsYou.tint)
            if let context {
                Text(context)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
            }
            actions(name)
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanbanLane.needsYou.tint.opacity(0.09), in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                .strokeBorder(KanbanLane.needsYou.tint.opacity(0.3), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban.needs-you")
    }

    private func title(_ name: String) -> String {
        if task.status == .review { return "Ready for your review" }
        if task.blockKind == "needs_input" { return "\(name) has a question" }
        if task.gotStuck { return "\(name) got stuck" }
        if task.blockKind == "dependency" { return "Waiting on another task" }
        return "On hold"
    }

    private var symbol: String {
        task.status == .review ? "checkmark.seal" : task.blockKind == "needs_input" ? "questionmark.bubble" : "exclamationmark.triangle"
    }

    /// A question is in the agent's latest message; a review or a stall is
    /// best told by its summary, then the agent's last note, then why the
    /// last run failed. The full thread is under Activity.
    private var context: String? {
        let agentNote = detail?.comments.last(where: { $0.author == task.assignee })?.body
        if task.blockKind == "needs_input", let agentNote { return agentNote }
        if let summary = task.latestSummary, !summary.isEmpty { return summary }
        if let agentNote { return agentNote }
        guard let error = detail?.runs.last(where: { $0.error != nil })?.error else { return nil }
        let tries = task.consecutiveFailures > 1 ? " Hermes stopped after \(task.consecutiveFailures) tries in a row." : ""
        return KanbanFailure.explain(error) + tries
    }

    /// The main answer and its alternative side by side; giving the card to
    /// someone else is a quieter choice underneath.
    private func actions(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space8) { primaryButtons }
                VStack(alignment: .leading, spacing: BighelpTokens.space8) { primaryButtons }
            }
            .lineLimit(1)
            Menu {
                ForEach(model.assignableAgents.filter { $0.id != task.assignee }) { agent in
                    Button(agent.name) { Task { await model.assign(task, to: agent.id) } }
                }
            } label: {
                Label("Give it to another bot", systemImage: "arrow.turn.up.right")
                    .font(.bighelp(.subheadline).weight(.medium))
            }
            .kanbanMacMenu(.bordered)
            .accessibilityIdentifier("kanban.give-to")
        }
    }

    @ViewBuilder private var primaryButtons: some View {
        Group {
            if task.status == .review {
                Button { Task { await model.approve(task) } } label: { Label("Approve", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .tint(KanbanLane.done.tint)
                    .accessibilityIdentifier("kanban.approve")
                Button("Ask for changes", action: answer)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("kanban.ask-for-changes")
            } else if task.blockKind == "needs_input" {
                Button { answer() } label: { Label("Answer", systemImage: "arrowshape.turn.up.left") }
                    .buttonStyle(.borderedProminent)
                    .tint(KanbanLane.needsYou.tint)
                    .accessibilityIdentifier("kanban.answer")
            } else {
                Button { Task { await model.tryAgain(task) } } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                    .tint(KanbanLane.ready.tint)
                    .accessibilityIdentifier("kanban.try-again")
            }
        }
        .controlSize(.large)
        .fixedSize()
    }

    @BighelpThemeReader private var theme
}

// MARK: - Thread

/// Messages, runs and the moments that explain a stall, in the order they happened.
struct KanbanThread: View {
    enum Item: Identifiable {
        case comment(HermesKanbanComment)
        case run(HermesKanbanRun)
        case event(HermesKanbanEvent)

        var id: String {
            switch self {
            case .comment(let value): "comment:\(value.id)"
            case .run(let value): "run:\(value.id)"
            case .event(let value): "event:\(value.id)"
            }
        }

        var date: Date {
            switch self {
            case .comment(let value): value.createdAt
            case .run(let value): value.startedAt
            case .event(let value): value.createdAt
            }
        }
    }

    @Bindable var model: KanbanBoardModel
    let items: [Item]
    @State private var shownErrors: Set<Int> = []

    /// Hermes giving up, and a block whose reason isn't already a run's summary.
    static func notableEvents(_ detail: HermesKanbanTaskDetail) -> [HermesKanbanEvent] {
        let summaries = Set(detail.runs.compactMap(\.summary))
        return detail.events.filter { event in
            switch event.kind {
            case "gave_up": true
            case "blocked": event.reason.map { !$0.isEmpty && !summaries.contains($0) } ?? false
            default: false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            ForEach(items) { item in
                switch item {
                case .comment(let comment): bubble(comment)
                case .run(let run): runRow(run)
                case .event(let event): eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: HermesKanbanEvent) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space8) {
            Image(systemName: event.kind == "gave_up" ? "hand.raised.circle" : "pause.circle")
                .foregroundStyle(KanbanLane.needsYou.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind == "gave_up"
                     ? "Hermes stopped trying after \(event.failures ?? 2) failed runs in a row"
                     : "Paused for you")
                    .font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                if event.kind == "blocked", let reason = event.reason {
                    Text(reason).font(.bighelp(.subheadline)).foregroundStyle(theme.primaryText).textSelection(.enabled)
                }
            }
        }
    }

    private func bubble(_ comment: HermesKanbanComment) -> some View {
        let agent = model.assignableAgents.first { $0.id == comment.author }
        let fromYou = agent == nil
        return HStack(alignment: .bottom, spacing: BighelpTokens.space8) {
            if fromYou { Spacer(minLength: 40) }
            if let agent {
                AvatarView(stableID: agent.id, displayName: agent.name, imageURL: agent.imageURL, size: 26)
            }
            VStack(alignment: fromYou ? .trailing : .leading, spacing: 2) {
                Text(comment.body)
                    .bighelpFont(.body)
                    .foregroundStyle(fromYou ? theme.outgoingMessageForeground : theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(fromYou ? theme.outgoingMessageBackground : theme.incomingMessageBackground,
                                in: .rect(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
                Text(comment.createdAt, format: .relative(presentation: .named))
                    .font(.bighelp(.caption2)).foregroundStyle(theme.tertiaryText)
            }
            if !fromYou { Spacer(minLength: 40) }
        }
    }

    private func runRow(_ run: HermesKanbanRun) -> some View {
        let name = model.agent(run.profile)?.name ?? "A bot"
        return HStack(alignment: .top, spacing: BighelpTokens.space8) {
            Image(systemName: run.isActive ? "bolt.circle.fill" : run.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(run.isActive ? KanbanLane.working.tint : run.error == nil ? theme.secondaryText : KanbanLane.needsYou.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(runText(run, name: name)).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                if let summary = run.summary, !summary.isEmpty {
                    Text(summary).font(.bighelp(.subheadline)).foregroundStyle(theme.primaryText).textSelection(.enabled)
                }
                if let error = run.error, !error.isEmpty {
                    Text(KanbanFailure.explain(error))
                        .font(.bighelp(.subheadline)).foregroundStyle(theme.primaryText)
                        .accessibilityIdentifier("kanban.run.\(run.id).why")
                    errorDetails(run.id, error)
                }
            }
        }
    }

    /// The raw error, a tap away and selectable, to copy into a fix.
    @ViewBuilder
    private func errorDetails(_ id: Int, _ error: String) -> some View {
        let shown = shownErrors.contains(id)
        Button(shown ? "Hide details" : "Show details") {
            withAnimation(.snappy) {
                if shown { shownErrors.remove(id) } else { shownErrors.insert(id) }
            }
        }
        .font(.bighelp(.caption).weight(.semibold))
        .buttonStyle(.borderless)
        .accessibilityIdentifier("kanban.run.\(id).details")
        if shown {
            Text(error)
                .font(.bighelp(.caption).monospaced())
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
                .padding(BighelpTokens.space8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.primaryText.opacity(0.05), in: .rect(cornerRadius: BighelpTokens.radius8))
        }
    }

    private func runText(_ run: HermesKanbanRun, name: String) -> String {
        guard let ended = run.endedAt else {
            return "\(name) is working on it · started \(KanbanWhen.short(Date.now.timeIntervalSince(run.startedAt))) ago"
        }
        let seconds = ended.timeIntervalSince(run.startedAt)
        let outcome = run.outcome ?? run.status
        // A worker that died in its first minute never got to the task.
        if run.error != nil, seconds < 60, ["crashed", "spawn_failed", "failed"].contains(outcome) {
            return "\(name) couldn't start"
        }
        let minutes = max(1, Int(seconds / 60))
        let ending = switch outcome {
        case "done", "completed": "and finished"
        case "review": "and asked for review"
        case "blocked": "and paused for you"
        case "reclaimed": "and was stopped"
        case "crashed", "failed": "and stopped unexpectedly"
        case "timed_out": "and ran out of time"
        default: ""
        }
        return "\(name) worked \(minutes) min \(ending)".trimmingCharacters(in: .whitespaces)
    }

    @BighelpThemeReader private var theme
}

// MARK: - Nerd Mode

struct KanbanNerdDetails: View {
    let task: HermesKanbanTask
    let detail: HermesKanbanTaskDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NERD MODE").font(.bighelp(.caption).weight(.bold)).tracking(0.6).foregroundStyle(theme.secondaryText)
            row("Task", task.id)
            row("Status", task.status.rawValue + (task.blockKind.map { " (\($0))" } ?? ""))
            row("Priority", "\(task.priority)")
            if let run = task.currentRunID { row("Run", "\(run)") }
            if let pid = task.workerPID { row("Worker PID", "\(pid)") }
            if let model = task.modelOverride { row("Model", model + (task.providerOverride.map { " · \($0)" } ?? "")) }
            if let effort = task.reasoningEffort { row("Reasoning", effort) }
            row("Folder", task.workspacePath ?? task.workspaceKind)
            if task.consecutiveFailures > 0 { row("Failures", "\(task.consecutiveFailures)") }
            if let detail {
                ForEach(detail.runs) { run in
                    row("Run \(run.id)", "\(run.status)\(run.workerPID.map { " · pid \($0)" } ?? "")")
                }
                ForEach(detail.events.suffix(8)) { event in
                    row("Event \(event.id)", "\(event.kind) · \(event.createdAt.formatted(date: .omitted, time: .shortened))")
                }
            }
        }
        .font(.bighelp(.caption).monospaced())
        .foregroundStyle(theme.secondaryText)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban.nerd-details")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 90, alignment: .leading)
            Text(value)
        }
    }

    @BighelpThemeReader private var theme
}
