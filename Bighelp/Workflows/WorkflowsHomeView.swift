import SwiftUI

/// An agent a role can be given to.
struct WorkflowAgent: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// What every Workflows screen needs. Pushed screens don't inherit the root's
/// environment, so the root passes this at each push.
@MainActor
struct WorkflowsContext {
    let store: WorkflowsStore
    let agents: [WorkflowAgent]
    let isNerdMode: Bool
    /// The computer's name, as people call it.
    let hostName: String
    let open: (AppRoute) -> Void

    var client: any WorkflowsClient { store.client }
    /// Connections, places, your templates and pins (`native-workflows-edit-v1`).
    var canEdit: Bool { store.canEdit }

    func agentName(_ id: String?) -> String? {
        guard let id else { return nil }
        return agents.first { $0.id == id }?.name ?? id
    }

    /// The Mac shows runs in its three-column monitor; elsewhere a run has its own page.
    func openRun(_ id: String) {
        open(BighelpPlatform.isMac ? .workflowRuns(selected: id) : .workflowRun(id: id))
    }
}

/// ☰ › Workflows: what waits for you, what's running, and your workflows.
struct WorkflowsHomeView: View {
    let context: WorkflowsContext
    @State private var isUsingTemplate = false
    @State private var isNamingNew = false
    @State private var newName = ""
    @State private var templateSource: WorkflowSummary?
    @State private var isArchivedPresented = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @BighelpThemeReader private var theme

    private var store: WorkflowsStore { context.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                if !isCantRunHere { BighelpDeferredSection { statusLine } }
                if case .cantRunHere = store.state {
                    WorkflowLoadStateView(state: store.state) { Task { await store.load() } }
                } else if store.list == nil, store.state != .loaded {
                    WorkflowLoadStateView(state: store.state) { Task { await store.load() } }
                } else {
                    if [.needsPluginUpdate, .needsHermesUpdate].contains(store.state) {
                        WorkflowLoadStateView(state: store.state)
                    }
                    if !store.waiting.isEmpty { BighelpDeferredSection { waitingSection } }
                    if !store.active.isEmpty { BighelpDeferredSection { activeSection } }
                    BighelpDeferredSection { workflowsSection }
                    if !store.recentRuns.isEmpty, store.active.isEmpty {
                        BighelpDeferredSection { recentSection }
                    }
                    BighelpDeferredSection { templatesSection }
                    Text("Runs keep going when you close the app. Nothing runs until you tap Run.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.tertiaryText)
                        .padding(.horizontal, BighelpTokens.space4)
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space8)
            .padding(.bottom, BighelpTokens.space48)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workflows.home")
        }
        .scrollIndicators(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle("Workflows")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { newMenu }
        }
        .refreshable { await store.load() }
        .onAppear { store.setOnScreen(true) }
        .onDisappear { store.setOnScreen(false) }
        // One alert per view: SwiftUI presents only one of several on the same view.
        .background {
            Color.clear
                .alert("New workflow", isPresented: $isNamingNew) {
                    TextField("Name", text: $newName)
                    Button("Cancel", role: .cancel) {}
                    Button("Create") { createFromScratch() }
                } message: {
                    Text("An empty workflow. Add its inputs and stages next.")
                }
                .allowsHitTesting(false)
        }
        .background {
            Color.clear
                .modifier(WorkflowSaveTemplatePrompt(store: store, source: $templateSource))
                .allowsHitTesting(false)
        }
        .alert("Workflows", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.message ?? "")
        }
        .sheet(isPresented: $isArchivedPresented) {
            WorkflowsArchivedView(context: context)
                .bighelpSheetSize(.standard)
        }
    }

    // MARK: Status

    private var statusLine: some View {
        HStack(spacing: BighelpTokens.space8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BighelpTokens.space4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workflows.status")
    }

    private var statusColor: Color {
        switch store.status?.coordinator {
        case .online?: theme.success
        case .starting?: theme.warning
        case .offline?: theme.danger
        default: theme.tertiaryText
        }
    }

    private var statusText: String {
        let host = store.status?.hostName ?? context.hostName
        guard let status = store.status else { return "Asking \(host)…" }
        var text: String
        switch status.coordinator {
        case .online: text = "Workflows are on, on \(host)"
        case .starting: text = "Workflows are starting on \(host)"
        case .offline: text = "Workflows are off on \(host). They start again with the next run."
        case .unknown: text = host
        }
        if context.isNerdMode {
            text += " · \(status.slotsUsed) of \(status.slotsTotal) slots"
            if let heartbeat = status.heartbeatAt { text += " · heartbeat \(WorkflowWords.ago(heartbeat)) ago" }
            if let epoch = status.epoch { text += " · epoch \(epoch)" }
        }
        return text
    }

    private var isCantRunHere: Bool {
        if case .cantRunHere = store.state { return true }
        return false
    }

    @ViewBuilder
    private var newMenu: some View {
        if !isCantRunHere {
            Menu {
                if context.canEdit {
                    Button("Create from scratch", systemImage: "square.and.pencil") { askNewName() }
                        .accessibilityIdentifier("workflows.new.scratch")
                }
                if !store.builtinTemplates.isEmpty {
                    Section("Start from a template") {
                        ForEach(store.builtinTemplates) { template in
                            Button(template.name, systemImage: "square.on.square") { use(template) }
                        }
                    }
                }
                if !store.yourTemplates.isEmpty {
                    Section("Your templates") {
                        ForEach(store.yourTemplates) { template in
                            Button(template.name, systemImage: "person.crop.square") { use(template) }
                        }
                    }
                }
            } label: {
                Label("New", systemImage: "plus")
                    .bighelpToolbarText()
            }
            .disabled((store.templates.isEmpty && !context.canEdit) || isUsingTemplate)
            .accessibilityIdentifier("workflows.new")
        }
    }

    private func askNewName() {
        newName = ""
        isNamingNew = true
    }

    private func createFromScratch() {
        let name = newName
        isUsingTemplate = true
        Task {
            defer { isUsingTemplate = false }
            do {
                let id = try await store.create(name: name)
                context.open(.workflow(id: id, startsRun: false))
            } catch {
                store.message = WorkflowsStore.reason(error)
            }
        }
    }

    private func use(_ template: WorkflowTemplate) {
        isUsingTemplate = true
        Task {
            defer { isUsingTemplate = false }
            if let id = try? await store.use(template) { context.open(.workflow(id: id, startsRun: false)) }
        }
    }

    // MARK: Waiting for you

    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            WorkflowSectionHeader(title: "Waiting for you", count: store.waiting.count)
            ForEach(store.waiting) { run in
                waitingCard(run)
            }
        }
    }

    private func waitingCard(_ run: WorkflowRunSummary) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Button { context.openRun(run.id) } label: {
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    WorkflowStageIcon(kind: .signoff, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready for your sign-off")
                            .font(.bighelp(.headline))
                            .foregroundStyle(theme.primaryText)
                        Text("\(run.workflowName) · Run \(run.number)")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                        Text(waitingText(run))
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.primaryText)
                            .padding(.top, BighelpTokens.space4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("workflows.waiting.\(run.id)")
            HStack(spacing: BighelpTokens.space8) {
                Button { withAnimation(.snappy) { store.setAside(run) } } label: {
                    Text("Later").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("workflows.waiting.later")
                Button { context.open(.workflowSignoff(runID: run.id)) } label: {
                    Text("Review").frame(maxWidth: .infinity)
                }
                .workflowProminent(theme)
                .accessibilityIdentifier("workflows.waiting.review")
            }
            .controlSize(.large)
            .font(.bighelp(.body).weight(.semibold))
        }
        .workflowCard(theme)
        .contextMenu {
            Button("Review", systemImage: "doc.text.magnifyingglass") { context.open(.workflowSignoff(runID: run.id)) }
            Button("Open run", systemImage: "arrow.right.circle") { context.openRun(run.id) }
            Button("Later", systemImage: "clock") { store.setAside(run) }
        }
    }

    private func waitingText(_ run: WorkflowRunSummary) -> String {
        let since = run.waiting?.since ?? run.updatedAt
        let waited = since.map { "Waiting \(WorkflowWords.duration(Date.now.timeIntervalSince($0)))" } ?? "Waiting"
        return "\(waited), with no agent running while it waits."
    }

    // MARK: Runs

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            WorkflowSectionHeader(title: "Active runs",
                                  link: ("All runs", "workflows.all-runs", { context.open(.workflowRuns(selected: nil)) }))
            runList(store.active)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            WorkflowSectionHeader(title: "Recent runs",
                                  link: ("All runs", "workflows.all-runs", { context.open(.workflowRuns(selected: nil)) }))
            runList(Array(store.recentRuns.prefix(3)))
        }
    }

    private func runList(_ runs: [WorkflowRunSummary]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 { Divider().overlay(theme.separator) }
                WorkflowRunRow(run: run) { context.openRun(run.id) }
                    .padding(.horizontal, BighelpTokens.space16)
            }
        }
        .workflowCard(theme, padding: 0)
    }

    // MARK: Workflows

    private var workflowsSection: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            WorkflowSectionHeader(title: "Your workflows")
            if store.workflows.isEmpty {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    Text("No workflows yet")
                        .font(.bighelp(.headline))
                    Text(context.canEdit
                         ? "A workflow passes work from one agent to the next and asks you before anything is final. Create one from scratch, or start from a template below."
                         : "A workflow passes work from one agent to the next and asks you before anything is final. Start from a template below.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .workflowCard(theme)
            }
            ForEach(store.workflows) { workflow in
                workflowCard(workflow)
            }
            if context.canEdit {
                Button { isArchivedPresented = true } label: {
                    Label("Archived workflows", systemImage: "archivebox")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.action)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(Rectangle())
                }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("workflows.archived")
            }
        }
    }

    private func workflowCard(_ workflow: WorkflowSummary) -> some View {
        let needsSetup = !workflow.needsSetupRoles.isEmpty
        return HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Button { context.open(.workflow(id: workflow.id, startsRun: false)) } label: {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: BighelpTokens.space4) {
                            if workflow.pinned {
                                Image(systemName: "pin.fill")
                                    .font(.bighelp(.caption).weight(.semibold))
                                    .foregroundStyle(theme.action)
                                    .accessibilityLabel("Pinned")
                                    .accessibilityIdentifier("workflows.workflow.pinned")
                            }
                            Text(workflow.name)
                                .font(.bighelp(.headline))
                                .foregroundStyle(theme.primaryText)
                        }
                        Text(workflowLine(workflow))
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(needsSetup || workflow.revision == nil ? theme.warning : theme.secondaryText)
                    }
                    if !workflow.stageKinds.isEmpty {
                        WorkflowMiniRail(kinds: workflow.stageKinds, unboundAgentStages: needsSetup)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("workflows.workflow.\(workflow.id)")
            if needsSetup {
                Button("Set up") { context.open(.workflow(id: workflow.id, startsRun: false)) }
                    .buttonStyle(.bordered)
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("workflows.workflow.setup")
            } else {
                Button { context.open(.workflow(id: workflow.id, startsRun: true)) } label: {
                    Image(systemName: "play.fill")
                        .font(.bighelp(.body))
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12))
                        .contentShape(Rectangle())
                }
                .bighelpPlainButtonStyle()
                .disabled(!workflow.valid)
                .bighelpIconLabel("Run \(workflow.name)")
                .accessibilityIdentifier("workflows.workflow.run")
            }
        }
        .workflowCard(theme)
        .contextMenu { workflowMenu(workflow, needsSetup: needsSetup) }
    }

    /// The long-press menu: Open, Run, then Pin, Save as template and Archive.
    @ViewBuilder
    private func workflowMenu(_ workflow: WorkflowSummary, needsSetup: Bool) -> some View {
        Button("Open", systemImage: "arrow.right.circle") { context.open(.workflow(id: workflow.id, startsRun: false)) }
        if workflow.valid, !needsSetup {
            Button("Run", systemImage: "play") { context.open(.workflow(id: workflow.id, startsRun: true)) }
        }
        if context.canEdit {
            Button(workflow.pinned ? "Unpin" : "Pin", systemImage: workflow.pinned ? "pin.slash" : "pin") {
                Task { await store.setPinned(workflow, !workflow.pinned) }
            }
            Button("Save as template", systemImage: "square.on.square") { templateSource = workflow }
        }
        Button("Archive", systemImage: "archivebox", role: .destructive) {
            Task { await store.archive(workflow) }
        }
    }

    private func workflowLine(_ workflow: WorkflowSummary) -> String {
        var parts: [String] = []
        if let revision = workflow.revision {
            parts.append(workflow.hasDraft ? "rev \(revision), changes not published" : "rev \(revision)")
        } else {
            parts.append("Draft")
        }
        let roles = workflow.needsSetupRoles.count
        if roles > 0 {
            parts.append(roles == 1 ? "1 role needs an agent" : "\(roles) roles need an agent")
        } else {
            parts.append(workflow.stageCount == 1 ? "1 stage" : "\(workflow.stageCount) stages")
            if let last = workflow.lastRunAt { parts.append("last run \(WorkflowWords.ago(last)) ago") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Templates

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if !store.templates.isEmpty || context.canEdit {
                WorkflowSectionHeader(title: "Templates")
            }
            if context.canEdit {
                Button { askNewName() } label: {
                    HStack(spacing: BighelpTokens.space12) {
                        Image(systemName: "square.and.pencil")
                            .font(.bighelp(.body).weight(.semibold))
                            .foregroundStyle(theme.action)
                            .frame(width: 36, height: 36)
                            .background(theme.action.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Create from scratch")
                                .font(.bighelp(.headline))
                                .foregroundStyle(theme.primaryText)
                            Text("Start empty, then add inputs and stages.")
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.bighelp(.footnote).weight(.semibold))
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .bighelpPlainButtonStyle()
                .disabled(isUsingTemplate)
                .workflowCard(theme)
                .accessibilityIdentifier("workflows.template.scratch")
            }
            if !store.builtinTemplates.isEmpty, !store.yourTemplates.isEmpty {
                templateGroupTitle("Built-in")
            }
            ForEach(store.builtinTemplates) { template in templateCard(template) }
            if !store.yourTemplates.isEmpty {
                templateGroupTitle("Yours")
                ForEach(store.yourTemplates) { template in templateCard(template) }
            }
        }
    }

    private func templateGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, BighelpTokens.space4)
            .accessibilityAddTraits(.isHeader)
    }

    private func templateCard(_ template: WorkflowTemplate) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.bighelp(.headline))
                Text(template.description.isEmpty
                     ? (template.stageCount == 1 ? "1 stage" : "\(template.stageCount) stages")
                     : template.description)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Use") { use(template) }
                .buttonStyle(.bordered)
                .disabled(isUsingTemplate)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("workflows.template.use")
        }
        .workflowCard(theme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflows.template.\(template.id)")
        .contextMenu {
            Button("Use", systemImage: "plus.square.on.square") { use(template) }
            if template.source == .yours, context.canEdit {
                Button("Delete template", systemImage: "trash", role: .destructive) {
                    Task { await store.deleteTemplate(template) }
                }
            }
        }
    }
}

/// Save as template: asks for a name (the workflow's, to start with).
struct WorkflowSaveTemplatePrompt: ViewModifier {
    let store: WorkflowsStore
    @Binding var source: WorkflowSummary?
    /// Before saving: an editor saves its waiting changes first.
    var prepare: (() async -> Void)?
    /// After saving: true when it was saved.
    var finished: ((Bool) -> Void)?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            // `presenting`: Save gets the workflow the alert opened for.
            .alert("Save as template", isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }),
                   presenting: source) { workflow in
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { source = nil }
                Button("Save") {
                    let chosen = name
                    source = nil
                    Task {
                        await prepare?()
                        // Not inside `finished?(…)`: with no `finished` the call would be skipped.
                        let saved = await store.saveTemplate(workflowID: workflow.id, name: chosen)
                        finished?(saved)
                    }
                }
            } message: { _ in
                Text("A template keeps the stages and inputs, not which agent does each role.")
            }
            .onChange(of: source?.id, initial: true) { _, _ in
                if let source { name = String(source.name.prefix(WorkflowTemplate.nameLimit)) }
            }
    }
}

/// Archived workflows: open one, or Unarchive it (also in its long-press menu).
struct WorkflowsArchivedView: View {
    let context: WorkflowsContext
    @State private var workflows: [WorkflowSummary]?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            List {
                if let workflows, workflows.isEmpty {
                    Text("No archived workflows.")
                        .foregroundStyle(theme.secondaryText)
                }
                ForEach(workflows ?? []) { workflow in
                    HStack(spacing: BighelpTokens.space12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.name).font(.bighelp(.headline))
                            Text(workflow.stageCount == 1 ? "1 stage" : "\(workflow.stageCount) stages")
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                        Button("Unarchive") { unarchive(workflow) }
                            .buttonStyle(.bordered)
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .accessibilityIdentifier("workflows.archived.unarchive")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("workflows.archived.\(workflow.id)")
                    .contextMenu {
                        Button("Unarchive", systemImage: "tray.and.arrow.up") { unarchive(workflow) }
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(theme.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .overlay { if workflows == nil, failure == nil { ProgressView() } }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bighelpDefaultAction()
                }
            }
            .task { await load() }
        }
        .accessibilityIdentifier("workflows.archived-list")
    }

    private func load() async {
        do {
            workflows = try await context.store.archived()
            failure = nil
        } catch {
            failure = WorkflowsStore.reason(error)
        }
    }

    private func unarchive(_ workflow: WorkflowSummary) {
        Task {
            await context.store.unarchive(workflow.id)
            await load()
        }
    }
}

/// One run in a list: its state, workflow, stage and age.
struct WorkflowRunRow: View {
    let run: WorkflowRunSummary
    var isSelected = false
    let open: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        Button(action: open) {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: run.state.symbol)
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(run.state.color(theme))
                    .frame(width: 32, height: 32)
                    .background(run.state.color(theme).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.workflowName)
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Text("Run \(run.number) · \(Text(run.stateLine).foregroundStyle(run.state.color(theme)))\(detail)")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: BighelpTokens.space8)
                Text(WorkflowWords.ago(run.startedAt))
                    .font(.bighelp(.caption).monospacedDigit())
                    .foregroundStyle(theme.tertiaryText)
            }
            .padding(.vertical, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(Rectangle())
        }
        .bighelpPlainButtonStyle()
        .background(isSelected ? theme.action.opacity(0.1) : .clear)
        .accessibilityIdentifier("workflows.run.\(run.id)")
    }

    private var detail: String {
        if run.state.isWorking, run.stageCount > 0 { return " · \(run.stagesDone) of \(run.stageCount) done" }
        if run.state == .needsAttention, let attention = run.attention {
            return " · " + attention.code.replacingOccurrences(of: "_", with: " ")
        }
        return ""
    }
}
