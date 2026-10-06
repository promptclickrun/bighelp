import SwiftUI

@MainActor
struct HermesKanbanAdministrationView: View {
    @Bindable var store: HermesKanbanStore
    let boardSlug: String


    var body: some View {
        List {
            operationStatus
            if let configuration = store.configuration {
                Section {
                    LabeledContent("Default tenant", value: configuration.defaultTenant.isEmpty ? "None" : configuration.defaultTenant)
                    LabeledContent("Profile lanes", value: configuration.laneByProfile ? "On" : "Off")
                    LabeledContent("Archived by default", value: configuration.includesArchivedByDefault ? "Included" : "Hidden")
                    LabeledContent("Markdown", value: configuration.rendersMarkdown ? "Rendered" : "Plain text")
                } header: {
                    Text("Dashboard policy")
                } footer: {
                    Text("The mounted API exposes this dashboard policy read-only. Writable routing policy is under Orchestration.")
                }
            }
            if let statistics = store.statistics {
                Section("Board status") {
                    ForEach(HermesKanbanTaskStatus.allCases) { status in
                        if let count = statistics.countsByStatus[status], count > 0 {
                            LabeledContent(status.label, value: String(count))
                        }
                    }
                    if let age = statistics.oldestReadyAgeSeconds {
                        LabeledContent("Oldest ready", value: "\(age) seconds")
                    }
                }
            }
            Section("Routing") {
                NavigationLink("Orchestration policy") {
                    HermesKanbanOrchestrationEditor(store: store)
                }
                ForEach(store.profiles) { profile in
                    NavigationLink {
                        HermesKanbanProfileEditor(store: store, profile: profile)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.bighelp(.headline))
                            Text(profile.summary.isEmpty ? "No routing description" : profile.summary)
                                .font(.bighelp(.caption)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                if store.profiles.isEmpty { Text("No routing profiles returned.").foregroundStyle(.secondary) }
            }
            Section("Assignees") {
                ForEach(store.assignees, id: \.self) { Text($0) }
                if store.assignees.isEmpty { Text("No known assignees.").foregroundStyle(.secondary) }
            }
            Section("Projects") {
                ForEach(store.projects) { project in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name).font(.bighelp(.headline))
                        Text(project.slug).font(.bighelp(.caption)).foregroundStyle(.secondary)
                    }
                }
                if store.projects.isEmpty { Text("No live projects available for board scoping.").foregroundStyle(.secondary) }
            }
            Section("Advanced · Models") {
                ForEach(store.modelProviders) { provider in
                    DisclosureGroup("\(provider.label) · \(provider.models.count)") {
                        ForEach(provider.models, id: \.self) { Text($0).font(.bighelp(.caption)) }
                    }
                }
                if store.modelProviders.isEmpty {
                    Text("The host returned no curated model choices. Task editing can still inherit its profile model.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Attention needed") {
                ForEach(store.diagnostics) { diagnostic in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(diagnostic.title, systemImage: diagnostic.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle")
                            .font(.bighelp(.headline))
                        Text(diagnostic.taskTitle ?? diagnostic.taskID).font(.bighelp(.subheadline))
                        Text(diagnostic.detail).font(.bighelp(.caption)).foregroundStyle(.secondary)
                    }
                }
                if store.diagnostics.isEmpty { Text("No active diagnostics.").foregroundStyle(.secondary) }
            }
            Section("Operations") {
                ForEach(store.activeWorkers) { worker in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(worker.taskTitle).font(.bighelp(.headline))
                        Text("Run \(worker.runID) · PID \(worker.processID)").font(.bighelp(.caption)).foregroundStyle(.secondary)
                    }
                }
                if store.activeWorkers.isEmpty { Text("No active workers.").foregroundStyle(.secondary) }
            }
            Section {
                Text("This mounted API has no template CRUD, workflow CRUD, or separate review-policy route. bighelp preserves workflow IDs/steps on tasks, filters board reads by those exact fields, and uses the typed task Review state for handoff.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
            } header: { Text("Advanced · Host limits") }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Kanban Administration")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.loadAdministration(board: boardSlug) }
        .task { await store.loadAdministration(board: boardSlug) }
        .accessibilityIdentifier("kanban.administration")
    }

    @ViewBuilder
    private var operationStatus: some View {
        if let operation = store.operationStatus {
            Section("Latest operation") {
                switch operation.phase {
                case .pending:
                    Label("Pending host response", systemImage: "clock")
                    ProgressView()
                case .completed(let message):
                    Label(message, systemImage: "checkmark.circle")
                case .refused(let message):
                    Label(message, systemImage: "xmark.circle")
                case .unverified:
                    Label("Outcome unverified. Refresh before acting again.", systemImage: "questionmark.circle")
                }
            }
        }
    }
}

@MainActor
struct HermesKanbanBoardCreatorView: View {
    @Bindable var store: HermesKanbanStore
    let dismiss: () -> Void
    @State private var draft = HermesKanbanBoardDraft(slug: "")

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Board slug", text: $draft.slug)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Name", text: $draft.name)
                TextField("Description", text: $draft.summary, axis: .vertical).lineLimit(3...8)
            }
            Section("Advanced · Appearance") {
                TextField("Symbol name", text: $draft.icon)
                TextField("Color", text: $draft.color)
            }
            Section {
                Picker("Project", selection: $draft.projectID) {
                    Text("No project").tag("")
                    ForEach(store.projects) { Text($0.name).tag($0.id) }
                }
                TextField("Host default work directory", text: $draft.defaultWorkdir)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Make host-active board", isOn: $draft.switchAfterCreation)
            } header: { Text("Scope") } footer: {
                Text("Paths name directories on the selected Hermes host, not on this \(BighelpPlatform.isMac ? "Mac" : "iPhone").")
            }
        }
        .navigationTitle("New Board")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let slug = store.boards.first(where: \.isCurrent)?.slug ?? store.boards.first?.slug {
                await store.loadAdministration(board: slug)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction).bighelpToolbarText() }
            ToolbarItem(placement: .confirmationAction) {
                Button("Review") {
                    Task {
                        await store.reviewBoardCreation(draft)
                        if store.review != nil { dismiss() }
                    }
                }
                .disabled(draft.slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canAct)
            }
        }
    }
}

@MainActor
struct HermesKanbanBoardImportView: View {
    @Bindable var store: HermesKanbanStore
    let dismiss: () -> Void
    @State private var request = HermesKanbanBoardImportRequest(hostArchivePath: "")

    var body: some View {
        Form {
            Section {
                TextField("Archive path on selected host", text: $request.hostArchivePath)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("New slug (optional)", text: $request.slugOverride)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Make host-active board", isOn: $request.switchAfterImport)
            } header: { Text("Host archive") } footer: {
                Text("The mounted API accepts an existing .tar.gz path on the Hermes host. It does not accept \(BighelpPlatform.isMac ? "Mac" : "iPhone") file bytes; \(BighelpPlatform.isMac ? "Mac" : "phone") transfer remains a separate parent-owned transport feature.")
            }
        }
        .navigationTitle("Import Board")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction).bighelpToolbarText() }
            ToolbarItem(placement: .confirmationAction) {
                Button("Review") {
                    Task {
                        await store.reviewBoardImport(request)
                        if store.review != nil { dismiss() }
                    }
                }
                .disabled(request.hostArchivePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canAct)
            }
        }
    }
}

@MainActor
struct HermesKanbanBoardManagementView: View {
    @Bindable var store: HermesKanbanStore
    let board: HermesKanbanBoard
    @State private var name: String
    @State private var summary: String
    @State private var icon: String
    @State private var color: String
    @State private var defaultWorkdir: String
    @State private var projectID: String
    @State private var includesAttachments = true
    @State private var includesLogs = false
    @State private var dispatchMaximum = 8

    init(store: HermesKanbanStore, board: HermesKanbanBoard) {
        self.store = store
        self.board = board
        _name = State(initialValue: board.name)
        _summary = State(initialValue: board.summary)
        _icon = State(initialValue: board.icon ?? "")
        _color = State(initialValue: board.color ?? "")
        _defaultWorkdir = State(initialValue: board.defaultWorkdir ?? "")
        _projectID = State(initialValue: board.projectID ?? "")
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $name)
                TextField("Description", text: $summary, axis: .vertical).lineLimit(3...8)
            }
            Section("Advanced · Appearance & scope") {
                TextField("Symbol name", text: $icon)
                TextField("Color", text: $color)
                Picker("Project", selection: $projectID) {
                    Text("No project").tag("")
                    ForEach(store.projects) { Text($0.name).tag($0.id) }
                }
                TextField("Host default work directory", text: $defaultWorkdir)
                Button("Review Metadata Changes") { Task { await reviewEdit() } }
                    .disabled(!store.canAct || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Host-active board") {
                LabeledContent("Current", value: board.isCurrent ? "Yes" : "No")
                if !board.isCurrent {
                    Button("Review Switch to This Board") { Task { await store.reviewBoardSwitch(slug: board.slug) } }
                        .disabled(!store.canAct)
                }
            }
            Section {
                Toggle("Include attachments", isOn: $includesAttachments)
                Toggle("Include worker logs", isOn: $includesLogs)
                Button("Review Staged Export") {
                    Task {
                        await store.reviewBoardExport(
                            slug: board.slug,
                            options: .init(includesAttachments: includesAttachments, includesLogs: includesLogs)
                        )
                    }
                }
                if let receipt = store.exportReceipt, receipt.boardSlug == board.slug {
                    LabeledContent("Archive", value: receipt.archiveFilename)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(receipt.byteCount), countStyle: .file))
                }
            } header: { Text("Advanced · Portable export") } footer: {
                Text("The archive is created in the plugin-owned staging directory on the selected host. Downloading it to this \(BighelpPlatform.isMac ? "Mac" : "phone") requires the separate fixed binary transfer integration.")
            }
            Section("Advanced · Bulk changes") {
                NavigationLink("Select Tasks and Change") {
                    HermesKanbanBulkEditor(store: store, boardSlug: board.slug)
                }
            }
            Section("Advanced · Dispatcher") {
                Stepper("Maximum tasks: \(dispatchMaximum)", value: $dispatchMaximum, in: 1...32)
                Button("Review Dispatch") {
                    Task { await store.reviewDispatch(board: board.slug, maximum: dispatchMaximum) }
                }
                .disabled(!store.canAct)
                if let receipt = store.dispatchReceipt {
                    LabeledContent("Spawned", value: String(receipt.spawnedTaskIDs.count))
                    LabeledContent("Promoted", value: String(receipt.promoted))
                    LabeledContent("Reclaimed", value: String(receipt.reclaimed))
                    if receipt.wasLocked {
                        Text("Another dispatcher held the board lock.").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Remove board") {
                Button("Review Archive", role: .destructive) {
                    Task { await store.reviewBoardRemoval(slug: board.slug, mode: .archive) }
                }
                .disabled(board.slug == "default" || !store.canAct)
                Button("Review Permanent Delete", role: .destructive) {
                    Task { await store.reviewBoardRemoval(slug: board.slug, mode: .delete) }
                }
                .disabled(board.slug == "default" || !store.canAct)
            }
        }
        .navigationTitle("Manage \(board.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadAdministration(board: board.slug) }
    }

    private func reviewEdit() async {
        var patch = HermesKanbanBoardPatch()
        if name != board.name { patch.name = .set(name) }
        if summary != board.summary { patch.summary = .set(summary) }
        if icon != (board.icon ?? "") { patch.icon = .set(icon) }
        if color != (board.color ?? "") { patch.color = .set(color) }
        if defaultWorkdir != (board.defaultWorkdir ?? "") { patch.defaultWorkdir = .set(defaultWorkdir) }
        if projectID != (board.projectID ?? "") { patch.projectID = .set(projectID) }
        await store.reviewBoardEdit(slug: board.slug, patch: patch)
    }
}

@MainActor
private struct HermesKanbanOrchestrationEditor: View {
    @Bindable var store: HermesKanbanStore
    @State private var orchestrator = ""
    @State private var defaultAssignee = ""
    @State private var autoDecompose = true
    @State private var autoPromote = true
    @State private var adopted = false

    var body: some View {
        Form {
            Section("Profiles") {
                Picker("Orchestrator", selection: $orchestrator) {
                    Text("Automatic").tag("")
                    ForEach(store.profiles) { Text($0.name).tag($0.name) }
                }
                Picker("Default assignee", selection: $defaultAssignee) {
                    Text("Automatic").tag("")
                    ForEach(store.profiles) { Text($0.name).tag($0.name) }
                }
            }
            Section("Advanced · Automation") {
                Toggle("Automatically decompose", isOn: $autoDecompose)
                Toggle("Automatically promote children", isOn: $autoPromote)
            }
            Section {
                Button("Review Policy Changes") {
                    var patch = HermesKanbanOrchestrationPatch()
                    patch.orchestratorProfile = .set(orchestrator)
                    patch.defaultAssignee = .set(defaultAssignee)
                    patch.automaticallyDecomposes = .set(autoDecompose)
                    patch.automaticallyPromotesChildren = .set(autoPromote)
                    Task { await store.reviewOrchestration(patch) }
                }
                .disabled(!store.canAct)
            }
        }
        .navigationTitle("Orchestration")
        .navigationBarTitleDisplayMode(.inline)
        .task { adopt() }
    }

    private func adopt() {
        guard !adopted, let value = store.orchestration else { return }
        adopted = true
        orchestrator = value.orchestratorProfile
        defaultAssignee = value.defaultAssignee
        autoDecompose = value.automaticallyDecomposes
        autoPromote = value.automaticallyPromotesChildren
    }
}

@MainActor
private struct HermesKanbanProfileEditor: View {
    @Bindable var store: HermesKanbanStore
    let profile: HermesKanbanProfile
    @State private var summary: String
    @State private var overwriteAutomatic = false

    init(store: HermesKanbanStore, profile: HermesKanbanProfile) {
        self.store = store
        self.profile = profile
        _summary = State(initialValue: profile.summary)
    }

    var body: some View {
        Form {
            Section("Routing identity") {
                LabeledContent("Profile", value: profile.name)
                LabeledContent("Provider", value: profile.provider.isEmpty ? "Inherited" : profile.provider)
                LabeledContent("Model", value: profile.model.isEmpty ? "Inherited" : profile.model)
                LabeledContent("Skills", value: String(profile.skillCount))
            }
            Section("Description") {
                TextField("Routing description", text: $summary, axis: .vertical).lineLimit(4...12)
                Button("Review Description") { Task { await store.reviewProfile(name: profile.name, summary: summary) } }
                    .disabled(!store.canAct)
                Button("Review Automatic Description") {
                    Task {
                        await store.reviewAutomaticProfileDescription(
                            name: profile.name,
                            overwrite: overwriteAutomatic || profile.summaryIsAutomatic
                        )
                    }
                }
                .disabled(!store.canAct || (!profile.summary.isEmpty && !profile.summaryIsAutomatic && !overwriteAutomatic))
                if !profile.summary.isEmpty && !profile.summaryIsAutomatic {
                    Toggle("Allow automatic overwrite", isOn: $overwriteAutomatic)
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct HermesKanbanBulkEditor: View {
    @Bindable var store: HermesKanbanStore
    let boardSlug: String
    @State private var selectedIDs: [String] = []
    @State private var status = HermesKanbanTaskStatus.ready
    @State private var changesStatus = true
    @State private var assignee = ""
    @State private var changesAssignee = false
    @State private var priority = 0
    @State private var changesPriority = false
    @State private var archives = false
    @State private var reclaimsFirst = false
    @State private var changesModel = false
    @State private var providerOverride = ""
    @State private var modelOverride = ""
    @State private var clearsModelOverride = false
    @State private var isModelPickerPresented = false
    @State private var changesReasoning = false
    @State private var reasoningEffort = "none"
    @State private var clearsReasoningEffort = false

    var body: some View {
        Form {
            Section("Selected tasks") {
                ForEach(store.boardSnapshot?.tasks ?? []) { task in
                    Toggle(isOn: Binding(
                        get: { isSelected(task.id) },
                        set: { selected in
                            setSelected(task.id, selected: selected)
                        }
                    )) { Text(task.title).lineLimit(2) }
                }
            }
            Section("Change") {
                Toggle("Change state", isOn: $changesStatus)
                if changesStatus {
                    Picker("State", selection: $status) {
                        ForEach(HermesKanbanTaskStatus.allCases.filter { $0.canBeSetDirectly && $0 != .archived }) { Text($0.label).tag($0) }
                    }
                }
                Toggle("Change assignee", isOn: $changesAssignee)
                if changesAssignee {
                    Picker("Assignee", selection: $assignee) {
                        Text("Unassigned").tag("")
                        ForEach(store.assignees, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Reclaim active tasks first", isOn: $reclaimsFirst)
                }
                Toggle("Change priority", isOn: $changesPriority)
                if changesPriority { Stepper("Priority: \(priority)", value: $priority, in: -1_000...1_000) }
            }
            Section("Advanced · Overrides") {
                Toggle("Change model override", isOn: $changesModel)
                if changesModel {
                    Toggle("Clear model override", isOn: $clearsModelOverride)
                    if !clearsModelOverride {
                        BighelpModelChoiceRow(
                            providerID: providerOverride,
                            providerName: store.modelProviders.first(where: {
                                $0.slug.utf8.elementsEqual(providerOverride.utf8)
                            })?.label ?? providerOverride,
                            modelID: modelOverride,
                            emptyTitle: "Choose a model",
                            isEnabled: !store.modelProviders.isEmpty
                        ) {
                            isModelPickerPresented = true
                        }
                        .accessibilityIdentifier("kanban.bulk.model")
                    }
                }
                Toggle("Change reasoning override", isOn: $changesReasoning)
                if changesReasoning {
                    Toggle("Clear reasoning override", isOn: $clearsReasoningEffort)
                    if !clearsReasoningEffort {
                        Picker("Reasoning", selection: $reasoningEffort) {
                            ForEach(["none", "minimal", "low", "medium", "high", "xhigh", "ultra"], id: \.self) {
                                Text($0.capitalized).tag($0)
                            }
                        }
                    }
                }
                Toggle("Archive selected tasks", isOn: $archives)
            }
            Button("Review Bulk Change") {
                var patch = HermesKanbanBulkPatch()
                patch.status = changesStatus ? status : nil
                patch.changesAssignee = changesAssignee
                patch.assignee = assignee.isEmpty ? nil : assignee
                patch.priority = changesPriority ? priority : nil
                patch.archives = archives
                patch.reclaimsFirst = reclaimsFirst
                if changesModel {
                    patch.clearsModelOverride = clearsModelOverride
                    patch.providerOverride = clearsModelOverride ? nil : providerOverride
                    patch.modelOverride = clearsModelOverride ? nil : modelOverride
                }
                if changesReasoning {
                    patch.clearsReasoningEffort = clearsReasoningEffort
                    patch.reasoningEffort = clearsReasoningEffort ? nil : reasoningEffort
                }
                Task { await store.reviewBulk(ids: selectedIDs, board: boardSlug, patch: patch) }
            }
            .disabled(
                selectedIDs.isEmpty || !store.canAct ||
                (changesModel && !clearsModelOverride && (providerOverride.isEmpty || modelOverride.isEmpty))
            )
            if let result = store.bulkResult {
                Section("Latest receipt") {
                    ForEach(result.items) { item in
                        Label(
                            item.id,
                            systemImage: item.succeeded ? "checkmark.circle" : "xmark.circle"
                        )
                        if let message = item.safeError { Text(message).font(.bighelp(.caption)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Bulk Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpSheet(isPresented: $isModelPickerPresented) {
            // The chat's model picker; the override is applied when the bulk change is reviewed.
            BighelpModelPickerSheet(
                title: "Model override",
                scopeLabel: "Selected tasks",
                providers: store.modelProviders.map(BighelpLinkModelProvider.init(kanban:)),
                currentProviderID: modelOverride.isEmpty ? nil : providerOverride,
                currentModelID: modelOverride.isEmpty ? nil : modelOverride,
                isLoading: false,
                isApplying: false,
                errorMessage: nil,
                onClearError: {},
                onRetry: nil,
                onSelect: { _, _ in },
                applyTitle: "Use this model",
                defaultModelTitle: "No model chosen",
                onApply: { draft in
                    guard let providerID = draft.providerID, let modelID = draft.modelID else { return }
                    providerOverride = providerID
                    modelOverride = modelID
                    isModelPickerPresented = false
                }
            )
            .presentationDetents([.large])
            .bighelpSheetSize(.standard)
        }
    }

    private func isSelected(_ id: String) -> Bool {
        selectedIDs.contains { $0.utf8.elementsEqual(id.utf8) }
    }

    private func setSelected(_ id: String, selected: Bool) {
        selectedIDs.removeAll { $0.utf8.elementsEqual(id.utf8) }
        if selected { selectedIDs.append(id) }
    }

}

@MainActor
struct HermesKanbanTaskAdministrationView: View {
    @Bindable var store: HermesKanbanStore
    let boardSlug: String
    let task: HermesKanbanTask
    @State private var assignee = ""
    @State private var reclaimFirst = false
    @State private var reason = ""
    @State private var parentID = ""

    var body: some View {
        List {
            Section("Routing") {
                Picker("Assignee", selection: $assignee) {
                    Text("Unassigned").tag("")
                    ForEach(store.assignees, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Reclaim active claim first", isOn: $reclaimFirst)
                TextField("Reason (optional)", text: $reason, axis: .vertical).lineLimit(2...5)
                Button("Review Reassignment") {
                    Task {
                        await store.reviewReassignment(
                            taskID: task.id, board: boardSlug,
                            profile: assignee.isEmpty ? nil : assignee,
                            reclaimFirst: reclaimFirst, reason: reason.isEmpty ? nil : reason
                        )
                    }
                }
                .disabled(!store.canAct)
                if task.status == .running {
                    Button("Review Reclaim", role: .destructive) {
                        Task { await store.reviewReclaim(taskID: task.id, board: boardSlug, reason: reason.isEmpty ? nil : reason) }
                    }
                    .disabled(!store.canAct)
                }
            }
            if task.status == .triage {
                Section("Advanced · Triage automation") {
                    Button("Review Specify") { Task { await store.reviewSpecify(taskID: task.id, board: boardSlug) } }
                    Button("Review Decompose") { Task { await store.reviewDecompose(taskID: task.id, board: boardSlug) } }
                }
                .disabled(!store.canAct)
            }
            Section("Advanced · Estimate") {
                if store.isLoading { ProgressView("Waiting for Hermes estimate") }
                Button("Estimate Existing Task") { Task { await store.estimateTask(taskID: task.id, board: boardSlug) } }
                    .disabled(!store.canAct)
                if let estimate = store.estimate {
                    if estimate.succeeded {
                        LabeledContent("Tokens", value: String(estimate.estimatedTokens ?? 0))
                        if let complexity = estimate.complexity { LabeledContent("Complexity", value: complexity.rawValue) }
                        if let rationale = estimate.rationale { Text(rationale).font(.bighelp(.footnote)).foregroundStyle(.secondary) }
                    } else {
                        Text(estimate.reason ?? "No estimate returned.").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Advanced · Home updates") {
                ForEach(store.homeChannels) { channel in
                    Button(channel.isSubscribed ? "Review Disable \(channel.name)" : "Review Enable \(channel.name)") {
                        Task {
                            await store.reviewHomeSubscription(
                                taskID: task.id, board: boardSlug, platform: channel.platform,
                                subscribed: !channel.isSubscribed
                            )
                        }
                    }
                    .disabled(!store.canAct)
                }
                if store.homeChannels.isEmpty { Text("No host home channels configured.").foregroundStyle(.secondary) }
            }
            Section("Advanced · Dependencies") {
                TextField("Parent task ID", text: $parentID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Review Add Parent") {
                    Task { await store.reviewTaskLink(parentID: parentID, childID: task.id, board: boardSlug, remove: false) }
                }
                .disabled(parentID.isEmpty || !store.canAct)
                ForEach(store.taskDetail?.parentIDs ?? [], id: \.self) { parent in
                    Button("Review Remove Parent \(parent)", role: .destructive) {
                        Task { await store.reviewTaskLink(parentID: parent, childID: task.id, board: boardSlug, remove: true) }
                    }
                    .disabled(!store.canAct)
                }
            }
            Section {
                if let log = store.taskLog {
                    LabeledContent("Exists", value: log.exists ? "Yes" : "No")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(log.byteCount), countStyle: .file))
                    LabeledContent("Bounded response", value: log.isTruncated ? "Truncated" : "Complete")
                } else {
                    Text("No worker log metadata returned.").foregroundStyle(.secondary)
                }
            } header: { Text("Advanced · Worker log") } footer: {
                Text("bighelp intentionally discards raw worker log content because this mounted route has no redacted mode; secret-bearing output is never displayed.")
            }
            Section("Delete task") {
                Button("Review Permanent Delete", role: .destructive) {
                    Task { await store.reviewTaskDeletion(taskID: task.id, board: boardSlug) }
                }
                .disabled(!store.canAct)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Task Controls")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            assignee = task.assignee ?? ""
            await store.loadAdministration(board: boardSlug)
            await store.loadTaskAdministration(taskID: task.id, board: boardSlug)
        }
    }
}
