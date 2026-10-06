import SwiftUI

@MainActor
struct HermesKanbanView: View {
    @Bindable var store: HermesKanbanStore
    @State private var showsBoardCreator = false
    @State private var showsBoardImporter = false

    var body: some View {
        Group {
            if !store.ownsScope {
                ContentUnavailableView(
                    "Workspace changed", systemImage: "rectangle.3.group.bubble.left",
                    description: Text("Return to Workspace and reopen Kanban on the selected host.")
                )
            } else if store.mount == .unavailable {
                ContentUnavailableView(
                    "Kanban unavailable", systemImage: "rectangle.3.group.slash",
                    description: Text("This destination appears only when the selected Hermes host mounts the bundled Kanban dashboard plugin.")
                )
            } else {
                List {
                    Section("Workspace") {
                        LabeledContent("Host", value: store.hostName)
                        Text("bighelp reads the mounted Hermes Kanban board directly. Bot Mode rooms are not used as task data.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    feedback
                    if store.mount == .available {
                        Section("Boards") {
                            ForEach(store.boards) { board in
                                NavigationLink {
                                    HermesKanbanBoardView(store: store, slug: board.slug)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(board.name).font(.bighelp(.headline))
                                            if board.isCurrent {
                                                Text("Current").font(.bighelp(.caption)).foregroundStyle(.secondary)
                                            }
                                        }
                                        if !board.summary.isEmpty {
                                            Text(board.summary).font(.bighelp(.subheadline)).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Text("\(board.total) active task\(board.total == 1 ? "" : "s")")
                                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityIdentifier("kanban.board.\(board.slug)")
                            }
                            if store.boards.isEmpty && !store.isLoading {
                                Text("The mounted plugin has no boards.").foregroundStyle(.secondary)
                            }
                        }
                        if let administrationBoard = store.boards.first(where: \.isCurrent) ?? store.boards.first {
                            Section("Advanced") {
                                NavigationLink("Kanban Administration") {
                                    HermesKanbanAdministrationView(store: store, boardSlug: administrationBoard.slug)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await store.load() }
            }
        }
        .navigationTitle("Kanban")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.mount == .available {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New Board", systemImage: "plus.rectangle.on.rectangle") { showsBoardCreator = true }
                        Button("Import Host Archive", systemImage: "square.and.arrow.down") { showsBoardImporter = true }
                    } label: {
                        Label("Board Actions", systemImage: "ellipsis.circle")
                    }
                    .disabled(!store.canAct)
                }
            }
        }
        .bighelpSheet(isPresented: $showsBoardCreator) {
            NavigationStack { HermesKanbanBoardCreatorView(store: store) { showsBoardCreator = false } }
                .bighelpSheetSize(.standard)
        }
        .bighelpSheet(isPresented: $showsBoardImporter) {
            NavigationStack { HermesKanbanBoardImportView(store: store) { showsBoardImporter = false } }
                .bighelpSheetSize(.standard)
        }
        .task { if store.mount == .unknown { await store.load() } }
        .modifier(HermesKanbanReviewModifier(store: store))
        .onChange(of: store.ownsScope) { _, current in if !current { store.retire() } }
        .accessibilityIdentifier("hermes.kanban")
    }

    @ViewBuilder
    private var feedback: some View {
        if store.isLoading || store.isMutating {
            Section {
                ProgressView(store.isMutating ? "Waiting for verified Hermes readback" : "Discovering mounted Kanban API")
            }
        }
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                Button("Refresh") { Task { await store.refresh() } }
                    .disabled(store.isLoading || store.isMutating)
            }
        }
        if let message = store.successMessage {
            Section { Label(message, systemImage: "checkmark.circle") }
        }
        if let receipt = store.importReceipt {
            Section("Latest import") {
                LabeledContent("Board", value: receipt.name)
                LabeledContent("Slug", value: receipt.boardSlug)
                LabeledContent("Attachments restored", value: String(receipt.restoredAttachmentCount))
                LabeledContent("Tasks parked", value: String(receipt.parkedTaskCount))
                if !receipt.warnings.isEmpty {
                    Text("Hermes reported \(receipt.warnings.count) relocation warning\(receipt.warnings.count == 1 ? "" : "s").")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor
private struct HermesKanbanBoardView: View {
    @Bindable var store: HermesKanbanStore
    let slug: String
    @State private var showsCreate = false
    @State private var workflowTemplateID = ""
    @State private var workflowStepKey = ""

    var body: some View {
        // One container, so the load below isn't attached to (and restarted by)
        // whichever of the loading/unavailable/board views is showing.
        ZStack {
            if let snapshot = store.boardSnapshot, snapshot.board.slug == slug {
                List {
                    if let live = store.liveStatusMessage {
                        Section {
                            Label(live, systemImage: store.usesPollingFallback ? "arrow.clockwise" : "bolt.horizontal.circle")
                                .font(.bighelp(.footnote))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(snapshot.columns) { column in
                        Section {
                            ForEach(column.tasks) { task in
                                NavigationLink {
                                    HermesKanbanTaskView(store: store, boardSlug: slug, taskID: task.id)
                                } label: {
                                    HermesKanbanTaskRow(task: task)
                                }
                                .accessibilityIdentifier("kanban.task.\(task.id)")
                            }
                            if column.tasks.isEmpty {
                                Text("No tasks").foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("\(column.status.label) · \(column.tasks.count)")
                        }
                    }
                    Section("Board") {
                        NavigationLink("Manage Board") {
                            HermesKanbanBoardManagementView(store: store, board: snapshot.board)
                        }
                        NavigationLink("Administration") {
                            HermesKanbanAdministrationView(store: store, boardSlug: slug)
                        }
                    }
                    Section {
                        TextField("Workflow template ID", text: $workflowTemplateID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Current step key", text: $workflowStepKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Apply Workflow Filter") {
                            Task {
                                await store.openBoard(
                                    slug,
                                    workflowTemplateID: workflowTemplateID.isEmpty ? nil : workflowTemplateID,
                                    currentStepKey: workflowStepKey.isEmpty ? nil : workflowStepKey
                                )
                            }
                        }
                        Button("Clear Workflow Filter") {
                            workflowTemplateID = ""
                            workflowStepKey = ""
                            Task { await store.openBoard(slug) }
                        }
                    } header: { Text("Advanced · Workflow filter") } footer: {
                        Text("The mounted API exposes exact workflow ID and step filters, but no template management route.")
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await store.openBoard(slug) }
                .navigationTitle(snapshot.board.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            Task { await store.reviewDispatch(board: slug) }
                        } label: {
                            Label("Dispatch", systemImage: "paperplane")
                        }
                        .disabled(!store.canAct)
                        Button {
                            showsCreate = true
                        } label: {
                            Label("New Task", systemImage: "plus")
                        }
                        .disabled(!store.canAct)
                    }
                }
                .bighelpSheet(isPresented: $showsCreate) {
                    NavigationStack {
                        HermesKanbanTaskCreator(store: store, boardSlug: slug) {
                            showsCreate = false
                        }
                    }
                    .bighelpSheetSize(.standard)
                }
            } else if store.isLoading {
                ProgressView("Loading board")
            } else {
                ContentUnavailableView(
                    "Board unavailable", systemImage: "rectangle.3.group.slash",
                    description: Text(store.errorMessage ?? "Refresh the mounted board.")
                )
            }
        }
        .task { if store.boardSnapshot?.board.slug != slug { await store.openBoard(slug) } }
        .accessibilityIdentifier("kanban.board.detail")
    }
}

private struct HermesKanbanTaskRow: View {
    let task: HermesKanbanTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title).font(.bighelp(.headline))
            HStack(spacing: 8) {
                Text(task.assignee ?? "Unassigned")
                Text("Priority \(task.priority)")
                if task.currentRunID != nil { Label("Running", systemImage: "bolt.fill") }
            }
            .font(.bighelp(.caption))
            .foregroundStyle(.secondary)
            if let summary = task.latestSummary, !summary.isEmpty {
                Text(summary).font(.bighelp(.subheadline)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct HermesKanbanTaskView: View {
    @Bindable var store: HermesKanbanStore
    let boardSlug: String
    let taskID: String
    @State private var showsEditor = false
    @State private var comment = ""

    var body: some View {
        Group {
            if let detail = store.taskDetail, detail.task.id == taskID {
                List {
                    Section("Task") {
                        LabeledContent("State", value: detail.task.status.label)
                        LabeledContent("Assignee", value: detail.task.assignee ?? "Unassigned")
                        LabeledContent("Priority", value: String(detail.task.priority))
                        if let body = detail.task.body, !body.isEmpty {
                            Text(body).textSelection(.enabled)
                        }
                        if let summary = detail.task.latestSummary, !summary.isEmpty {
                            LabeledContent("Latest handoff") { Text(summary).textSelection(.enabled) }
                        }
                        if let result = detail.task.result, !result.isEmpty {
                            LabeledContent("Result") { Text(result).textSelection(.enabled) }
                        }
                        if let workflow = detail.task.workflowTemplateID {
                            LabeledContent("Workflow", value: workflow)
                        }
                        if let step = detail.task.currentStepKey {
                            LabeledContent("Workflow step", value: step)
                        }
                        if let contract = detail.task.completionContract, !contract.isEmpty {
                            LabeledContent("Completion contract") { Text(contract).textSelection(.enabled) }
                        }
                    }
                    if !detail.parentIDs.isEmpty || !detail.childIDs.isEmpty {
                        Section("Links") {
                            if !detail.parentIDs.isEmpty {
                                LabeledContent("Parents", value: detail.parentIDs.joined(separator: ", "))
                            }
                            if !detail.childIDs.isEmpty {
                                LabeledContent("Children", value: detail.childIDs.joined(separator: ", "))
                            }
                        }
                    }
                    Section("Advanced · Execution policy") {
                        if let skills = detail.task.skills {
                            LabeledContent("Skills", value: skills.isEmpty ? "None" : skills.joined(separator: ", "))
                        }
                        if let model = detail.task.modelOverride { LabeledContent("Model override", value: model) }
                        if let provider = detail.task.providerOverride { LabeledContent("Provider override", value: provider) }
                        if let effort = detail.task.reasoningEffort { LabeledContent("Reasoning", value: effort) }
                        if let retries = detail.task.maximumRetries { LabeledContent("Maximum retries", value: String(retries)) }
                        LabeledContent("Consecutive failures", value: String(detail.task.consecutiveFailures))
                        if detail.task.goalMode {
                            LabeledContent("Goal mode", value: detail.task.goalMaximumTurns.map { String($0) } ?? "Host default")
                        }
                        if let blockKind = detail.task.blockKind { LabeledContent("Block kind", value: blockKind) }
                        if detail.task.blockRecurrences > 0 {
                            LabeledContent("Block recurrences", value: String(detail.task.blockRecurrences))
                        }
                    }
                    Section("Runs") {
                        ForEach(detail.runs.reversed()) { run in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Run \(run.id)").font(.bighelp(.headline))
                                    Spacer()
                                    Text(run.isActive ? "Active" : (run.outcome ?? run.status)).foregroundStyle(.secondary)
                                }
                                if let profile = run.profile { LabeledContent("Profile", value: profile) }
                                LabeledContent("Started", value: run.startedAt.formatted())
                                if let ended = run.endedAt { LabeledContent("Ended", value: ended.formatted()) }
                                if let summary = run.summary, !summary.isEmpty { Text(summary).font(.bighelp(.footnote)) }
                                if run.isActive {
                                    Button("Terminate Run", role: .destructive) {
                                        Task { await store.reviewRunTermination(runID: run.id, board: boardSlug) }
                                    }
                                    .disabled(!store.canAct)
                                    .frame(minHeight: BighelpTokens.hitTarget)
                                }
                            }
                        }
                        if detail.runs.isEmpty { Text("No attempts recorded.").foregroundStyle(.secondary) }
                    }
                    Section("Attachments") {
                        ForEach(detail.attachments) { attachment in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(attachment.filename).font(.bighelp(.headline))
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                Button("Remove", role: .destructive) {
                                    Task {
                                        await store.reviewAttachmentRemoval(
                                            attachmentID: attachment.id, taskID: taskID, board: boardSlug
                                        )
                                    }
                                }
                                .disabled(!store.canAct)
                            }
                        }
                        if detail.attachments.isEmpty { Text("No attachments.").foregroundStyle(.secondary) }
                        if !store.supportsAttachmentTransfer {
                            Text("Upload and download stay hidden until the fixed authenticated multipart/binary transport is wired. Listing and reviewed removal remain available.")
                                .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                        }
                    }
                    Section("Comments") {
                        ForEach(detail.comments) { comment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(comment.author).font(.bighelp(.caption)).foregroundStyle(.secondary)
                                Text(comment.body).textSelection(.enabled)
                                Text(comment.createdAt.formatted()).font(.bighelp(.caption2)).foregroundStyle(.tertiary)
                            }
                        }
                        TextField("Add a comment", text: $comment, axis: .vertical)
                            .lineLimit(2...6)
                        Button("Add Comment") {
                            let value = comment
                            Task {
                                await store.reviewComment(value, taskID: taskID, board: boardSlug)
                                if store.review == nil, store.errorMessage == nil { comment = "" }
                            }
                        }
                        .disabled(!store.canAct || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Section("Advanced") {
                        NavigationLink("Task Controls") {
                            HermesKanbanTaskAdministrationView(
                                store: store, boardSlug: boardSlug, task: detail.task
                            )
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await store.openTask(taskID, board: boardSlug) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { showsEditor = true }.disabled(!store.canAct)
                    }
                }
                .bighelpSheet(isPresented: $showsEditor) {
                    NavigationStack {
                        HermesKanbanTaskEditor(store: store, boardSlug: boardSlug, task: detail.task) {
                            showsEditor = false
                        }
                    }
                    .bighelpSheetSize(.standard)
                }
            } else if store.isLoading {
                ProgressView("Loading task")
            } else {
                ContentUnavailableView(
                    "Task unavailable", systemImage: "checklist.unchecked",
                    description: Text(store.errorMessage ?? "Refresh the task from its mounted board.")
                )
            }
        }
        .navigationTitle(store.taskDetail?.task.id == taskID ? store.taskDetail?.task.title ?? "Task" : "Task")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.taskDetail?.task.id != taskID { await store.openTask(taskID, board: boardSlug) } }
        .accessibilityIdentifier("kanban.task.detail")
    }
}

@MainActor
private struct HermesKanbanTaskEditor: View {
    @Bindable var store: HermesKanbanStore
    let boardSlug: String
    let task: HermesKanbanTask
    let dismiss: () -> Void
    @State private var title: String
    @State private var bodyText: String
    @State private var assignee: String
    @State private var priority: Int
    @State private var status: HermesKanbanTaskStatus
    @State private var blockReason = ""
    @State private var handoffSummary = ""
    @State private var completionResult = ""

    init(store: HermesKanbanStore, boardSlug: String, task: HermesKanbanTask, dismiss: @escaping () -> Void) {
        self.store = store
        self.boardSlug = boardSlug
        self.task = task
        self.dismiss = dismiss
        _title = State(initialValue: task.title)
        _bodyText = State(initialValue: task.body ?? "")
        _assignee = State(initialValue: task.assignee ?? "")
        _priority = State(initialValue: task.priority)
        _status = State(initialValue: task.status)
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Title", text: $title)
                TextField("Description", text: $bodyText, axis: .vertical).lineLimit(4...12)
                TextField("Assignee", text: $assignee)
                Stepper("Priority: \(priority)", value: $priority, in: -1_000...1_000)
            }
            Section("State") {
                Picker("State", selection: $status) {
                    ForEach(HermesKanbanTaskStatus.allCases.filter(\.canBeSetDirectly)) { state in
                        Text(state.label).tag(state)
                    }
                }
                if status == .blocked || status == .scheduled {
                    TextField(status == .blocked ? "Block reason" : "Schedule reason", text: $blockReason, axis: .vertical)
                        .lineLimit(2...6)
                }
                if status == .review || status == .done {
                    TextField("Handoff summary", text: $handoffSummary, axis: .vertical)
                        .lineLimit(3...8)
                }
                if status == .done {
                    TextField("Completion result", text: $completionResult, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
        }
        .navigationTitle("Edit Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction).bighelpToolbarText() }
            ToolbarItem(placement: .confirmationAction) {
                Button("Review") {
                    var patch = HermesKanbanTaskPatch()
                    let normalizedAssignee = assignee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : assignee
                    if title != task.title { patch.title = .set(title) }
                    if bodyText != (task.body ?? "") { patch.body = .set(bodyText) }
                    if normalizedAssignee != task.assignee { patch.assignee = .set(normalizedAssignee) }
                    if priority != task.priority { patch.priority = .set(priority) }
                    if status != task.status { patch.status = .set(status) }
                    if status != task.status, status == .blocked || status == .scheduled {
                        patch.blockReason = .set(blockReason)
                    }
                    if status != task.status, status == .review || status == .done {
                        patch.summary = .set(handoffSummary)
                    }
                    if status != task.status, status == .done { patch.result = .set(completionResult) }
                    Task {
                        await store.reviewEdit(taskID: task.id, board: boardSlug, patch: patch)
                        if store.review != nil { dismiss() }
                    }
                }
                .disabled(
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (status != task.status && (status == .blocked || status == .scheduled) && blockReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                    (status != task.status && (status == .review || status == .done) && handoffSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                    !store.canAct
                )
            }
        }
    }
}

@MainActor
private struct HermesKanbanTaskCreator: View {
    @Bindable var store: HermesKanbanStore
    let boardSlug: String
    let dismiss: () -> Void
    @State private var title = ""
    @State private var bodyText = ""
    @State private var assignee = ""
    @State private var priority = 0
    @State private var startsInTriage = false

    var body: some View {
        Form {
            Section("Task") {
                TextField("Title", text: $title)
                TextField("Description", text: $bodyText, axis: .vertical).lineLimit(4...12)
                TextField("Assignee", text: $assignee)
                Stepper("Priority: \(priority)", value: $priority, in: -1_000...1_000)
                Toggle("Needs triage", isOn: $startsInTriage)
            }
            Section("Estimate") {
                if store.isLoading { ProgressView("Waiting for Hermes estimate") }
                Button("Estimate Draft") {
                    Task { await store.estimateDraft(title: title, body: bodyText) }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canAct)
                if let estimate = store.estimate {
                    if estimate.succeeded {
                        LabeledContent("Estimated tokens", value: String(estimate.estimatedTokens ?? 0))
                        if let complexity = estimate.complexity {
                            LabeledContent("Complexity", value: complexity.rawValue)
                        }
                        if let rationale = estimate.rationale {
                            Text(rationale).font(.bighelp(.footnote)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(estimate.reason ?? "No estimate returned.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("New Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction).bighelpToolbarText() }
            ToolbarItem(placement: .confirmationAction) {
                Button("Review") {
                    var draft = HermesKanbanTaskDraft(title: title)
                    draft.body = bodyText
                    draft.assignee = assignee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : assignee
                    draft.priority = priority
                    draft.startsInTriage = startsInTriage
                    Task {
                        await store.reviewCreation(draft, board: boardSlug)
                        if store.review != nil { dismiss() }
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canAct)
            }
        }
    }
}

@MainActor
private struct HermesKanbanReviewModifier: ViewModifier {
    @Bindable var store: HermesKanbanStore

    func body(content: Content) -> some View {
        content.confirmationDialog(
            store.review?.title ?? "Review Kanban change",
            isPresented: Binding(
                get: { store.review != nil },
                set: { if !$0 { store.review = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let review = store.review {
                Button(review.actionTitle, role: review.isDestructive ? .destructive : nil) {
                    Task { await store.confirm(review) }
                }
                Button("Cancel", role: .cancel) { store.review = nil }
            }
        } message: {
            if let review = store.review { Text(review.message) }
        }
    }
}
