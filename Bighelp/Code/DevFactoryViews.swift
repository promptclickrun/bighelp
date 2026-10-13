import SwiftUI

/// What Dev Factory's screens open, from the root.
struct DevFactoryContext {
    let store: DevFactoryStore
    /// The IDE's projects (Hermes projects with a folder), for new recipes.
    let projects: [CodeProject]
    let agents: [AgentProfile]
    let defaultAgentID: String
    let onOpenGroup: (String) -> Void
    let onOpenRecipe: (String) -> Void
    /// The recipe's steps in the Workflows editor.
    let onEditRecipe: (String) -> Void
}

/// Dev Factory's home (approved 4.1): what runs now, then your recipes, then the templates
/// new ones start from. ☰ › Dev Factory in Bighelp IDE.
struct DevFactoryHomeView: View {
    let context: DevFactoryContext
    @State private var newFrom: WorkflowTemplate?
    @State private var running: WorkflowSummary?

    var body: some View {
        let store = context.store
        List {
            if store.isAvailable == false {
                Section {
                    ContentUnavailableView("Update the bighelp plugin", systemImage: "shippingbox",
                        description: Text("Dev Factory needs a newer bighelp plugin on this computer. Update it in Settings › Hermes plugin."))
                }
            } else {
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .listRowBackground(Color.clear)
                }
                let now = store.groups.filter { $0.isWorking || $0.needsYou > 0 }
                if !now.isEmpty {
                    Section("Running now") {
                        ForEach(now) { group in groupRow(group) }
                    }
                    .listRowBackground(theme.surface)
                }
                Section("Recipes") {
                    if store.recipes.isEmpty, !store.isLoading {
                        Text("No recipes yet. Start one from a template below.")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                    }
                    ForEach(store.recipes) { recipe in recipeRow(recipe) }
                }
                .listRowBackground(theme.surface)
                if !store.templates.isEmpty {
                    Section {
                        ForEach(store.templates) { template in templateRow(template) }
                    } header: {
                        Text("Start from a template")
                    } footer: {
                        Text("Or ask an agent to write one: it can make and run recipes too.")
                    }
                    .listRowBackground(theme.surface)
                }
                let earlier = store.groups.filter { !$0.isWorking && $0.needsYou == 0 }.prefix(10)
                if !earlier.isEmpty {
                    Section("Earlier") {
                        ForEach(Array(earlier)) { group in groupRow(group) }
                    }
                    .listRowBackground(theme.surface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle("Dev Factory")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await store.load() }
        .task { await store.load() }
        .bighelpSheet(item: $newFrom) { template in
            DevFactoryNewRecipeSheet(context: context, template: template)
                .bighelpSheetSize(.large)
        }
        .bighelpSheet(item: $running) { recipe in
            DevFactoryRunSheet(context: context, recipe: recipe)
                .bighelpSheetSize(.standard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("devfactory.home")
    }

    private func groupRow(_ group: WorkflowCodeGroup) -> some View {
        Button { context.onOpenGroup(group.id) } label: {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                HStack(spacing: BighelpTokens.space12) {
                    Image(systemName: "hammer")
                        .foregroundStyle(theme.action)
                        .frame(width: BighelpTokens.scaled(30), height: BighelpTokens.scaled(30))
                        .background(theme.action.opacity(0.14), in: .rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.bighelp(.headline)).foregroundStyle(theme.primaryText).lineLimit(1)
                        Text(groupSubtitle(group)).font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    if group.needsYou > 0 {
                        CodePill(text: group.needsYou == 1 ? "1 needs you" : "\(group.needsYou) need you",
                                 tint: theme.warning)
                    }
                }
                ForEach(group.runs) { run in
                    HStack(spacing: BighelpTokens.space8) {
                        Text(run.code?.project.label ?? run.workflowName)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                        Spacer(minLength: 0)
                        Text(DevFactoryWords.line(run, detail: nil))
                            .font(.bighelp(.caption))
                            .foregroundStyle(DevFactoryWords.tint(run, theme))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, BighelpTokens.space4)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("devfactory.group-row")
    }

    private func groupSubtitle(_ group: WorkflowCodeGroup) -> String {
        let count = group.runs.count == 1 ? "1 project" : "\(group.runs.count) projects"
        guard let started = group.startedAt else { return count }
        return count + " · started " + started.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func recipeRow(_ recipe: WorkflowSummary) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Button { context.onOpenRecipe(recipe.id) } label: {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(recipe.name).font(.bighelp(.headline)).foregroundStyle(theme.primaryText).lineLimit(1)
                    HStack(spacing: BighelpTokens.space4) {
                        ForEach(recipe.projects.prefix(3)) { project in
                            Text(project.label)
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.raisedSurface, in: .rect(cornerRadius: 5))
                        }
                        if recipe.projects.count > 3 {
                            Text("+\(recipe.projects.count - 3)").font(.bighelp(.caption2))
                        }
                    }
                    .foregroundStyle(theme.primaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("devfactory.recipe.\(recipe.id)")
            Button { running = recipe } label: {
                Image(systemName: "play.fill")
                    .font(.bighelp(.caption).weight(.bold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(width: BighelpTokens.scaled(34), height: BighelpTokens.scaled(34))
                    .background(recipe.revision == nil ? theme.secondaryText : theme.action, in: .circle)
            }
            .bighelpPlainButtonStyle(.circle)
            .disabled(recipe.revision == nil)
            .bighelpIconLabel("Run \(recipe.name)")
            .accessibilityIdentifier("devfactory.run.\(recipe.id)")
        }
    }

    private func templateRow(_ template: WorkflowTemplate) -> some View {
        Button { newFrom = template } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name).font(.bighelp(.body).weight(.semibold)).foregroundStyle(theme.primaryText)
                Text(template.description).font(.bighelp(.caption)).foregroundStyle(theme.secondaryText).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("devfactory.template.\(template.id)")
    }

    @BighelpThemeReader private var theme
}

/// Run a recipe: its inputs, and which of its projects (all by default).
struct DevFactoryRunSheet: View {
    let context: DevFactoryContext
    let recipe: WorkflowSummary
    @Environment(\.dismiss) private var dismiss
    @State private var detail: WorkflowDetail?
    @State private var values: [String: String] = [:]
    @State private var chosen: Set<String> = []
    @State private var isStarting = false

    var body: some View {
        NavigationStack {
            Form {
                if let detail {
                    if !detail.definition.inputs.isEmpty {
                        Section("For this run") {
                            WorkflowInputFields(inputs: detail.definition.inputs, values: $values,
                                                identifier: "devfactory.run-sheet")
                        }
                        .listRowBackground(theme.surface)
                    }
                    Section("Projects") {
                        ForEach(detail.definition.codeProjects) { project in
                            Toggle(isOn: Binding(get: { chosen.contains(project.key) }, set: { on in
                                if on { chosen.insert(project.key) } else { chosen.remove(project.key) }
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.label)
                                    if let path = project.path {
                                        Text(path).font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(theme.secondaryText).lineLimit(1).truncationMode(.head)
                                    }
                                }
                            }
                            .accessibilityIdentifier("devfactory.run-sheet.project.\(project.key)")
                        }
                    }
                    .listRowBackground(theme.surface)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error = context.store.errorMessage {
                    Text(error).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(recipe.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { start() } label: { if isStarting { ProgressView() } else { Text("Run").bold() } }
                        .disabled(!canStart)
                        .accessibilityIdentifier("devfactory.run-sheet.start")
                }
            }
            .task { await load() }
        }
    }

    private var canStart: Bool {
        guard let detail, !isStarting, !chosen.isEmpty else { return false }
        return WorkflowInputFields.isComplete(detail.definition.inputs, values)
    }

    private func load() async {
        guard detail == nil, let loaded = try? await context.store.client.workflow(id: recipe.id, revision: .latest)
        else { return }
        detail = loaded
        values = WorkflowInputFields.values(for: loaded.definition.inputs)
        chosen = Set(loaded.definition.codeProjects.map(\.key))
    }

    private func start() {
        guard let detail else { return }
        isStarting = true
        let all = detail.definition.codeProjects.map(\.key)
        let projects = chosen.count == all.count ? nil : all.filter(chosen.contains)
        Task {
            let group = await context.store.start(recipe, inputs: WorkflowInputFields.json(detail.definition.inputs, values),
                                                  projects: projects)
            isStarting = false
            if let group {
                dismiss()
                context.onOpenGroup(group)
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// A new recipe from a template: its name, projects, the command each runs, where runs
/// work, and the agent that codes. Create saves it, binds the agent and publishes it.
struct DevFactoryNewRecipeSheet: View {
    let context: DevFactoryContext
    let template: WorkflowTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var setup: DevFactoryRecipeSetup
    @State private var chosen: [String] = []
    @State private var isCreating = false

    init(context: DevFactoryContext, template: WorkflowTemplate) {
        self.context = context
        self.template = template
        var setup = DevFactoryRecipeSetup(name: template.name, projects: [])
        // The nightly sweep tests what's checked out; the others work in a worktree each.
        setup.placement = template.id == "test-sweep" ? "local" : "worktree"
        setup.agentID = context.defaultAgentID
        _setup = State(initialValue: setup)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $setup.name)
                        .accessibilityIdentifier("devfactory.new.name")
                }
                .listRowBackground(theme.surface)
                Section {
                    if context.projects.isEmpty {
                        Text("No projects on this computer yet. Add one from the IDE's project chip.")
                            .font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                    }
                    ForEach(context.projects) { project in
                        Toggle(isOn: Binding(get: { chosen.contains(project.id) }, set: { on in
                            if on { chosen.append(project.id) } else { chosen.removeAll { $0 == project.id } }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                Text(project.folder).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText).lineLimit(1).truncationMode(.head)
                            }
                        }
                        .accessibilityIdentifier("devfactory.new.project.\(project.id)")
                    }
                } header: {
                    Text("Projects")
                } footer: {
                    Text("Each run works in one project: up to 10.")
                }
                .listRowBackground(theme.surface)
                Section {
                    TextField("Command", text: $setup.sharedCommand, prompt: Text("make test").bighelpFieldHint(theme))
                        .font(.bighelp(.body).monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("devfactory.new.command")
                    ForEach(selectedProjects) { project in
                        LabeledContent(project.label) {
                            TextField(project.label, text: Binding(get: { setup.commands[project.key] ?? "" },
                                                                   set: { setup.commands[project.key] = $0 }),
                                      prompt: Text("Same as above").bighelpFieldHint(theme))
                                .font(.bighelp(.callout).monospaced())
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } header: {
                    Text("Tests")
                } footer: {
                    Text("Runs in each project's folder, without a shell. It passes when it exits with 0.")
                }
                .listRowBackground(theme.surface)
                Section("Runs work in") {
                    Picker("Folder", selection: $setup.placement) {
                        Text("A new worktree each").tag("worktree")
                        Text("The local checkout").tag("local")
                    }
                    .accessibilityIdentifier("devfactory.new.placement")
                    TextField("Start from", text: Binding(get: { setup.base ?? "" },
                                                          set: { setup.base = $0.isEmpty ? nil : $0 }),
                              prompt: Text("The current branch").bighelpFieldHint(theme))
                        .font(.bighelp(.body).monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .listRowBackground(theme.surface)
                Section("Agent") {
                    Picker("Codes with", selection: Binding(get: { setup.agentID ?? "" },
                                                            set: { setup.agentID = $0.isEmpty ? nil : $0 })) {
                        ForEach(context.agents) { agent in Text(agent.name).tag(agent.id) }
                    }
                }
                .listRowBackground(theme.surface)
                if let error = context.store.errorMessage {
                    Text(error).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { create() } label: { if isCreating { ProgressView() } else { Text("Create").bold() } }
                        .disabled(chosen.isEmpty || isCreating || setup.sharedCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("devfactory.new.create")
                }
            }
        }
    }

    /// The chosen projects in the order they were picked, with keys no two share.
    private var selectedProjects: [WorkflowCodeProject] {
        var taken = Set<String>()
        return chosen.compactMap { id in
            guard let project = context.projects.first(where: { $0.id == id }) else { return nil }
            let key = WorkflowCodeProject.key(for: project.name, taken: taken)
            taken.insert(key)
            return WorkflowCodeProject(key: key, label: project.name, path: project.folder)
        }
    }

    private func create() {
        isCreating = true
        var setup = setup
        setup.projects = selectedProjects
        Task {
            let id = await context.store.createRecipe(from: template, setup: setup)
            isCreating = false
            if let id {
                dismiss()
                context.onOpenRecipe(id)
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// One recipe (approved 4.2): its projects, where runs work, its steps, and Run.
struct DevFactoryRecipeView: View {
    let context: DevFactoryContext
    let recipeID: String
    @State private var detail: WorkflowDetail?
    @State private var running: WorkflowSummary?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let detail {
                let definition = detail.definition
                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: BighelpTokens.space8) {
                            ForEach(definition.codeProjects) { project in
                                Text(project.label)
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(theme.raisedSurface, in: .rect(cornerRadius: 6))
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    Label(placementLine(definition), systemImage: definition.codeWorkspace.placement == "local"
                          ? "laptopcomputer" : "square.on.square")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
                .listRowBackground(Color.clear)
                Section("Steps") {
                    ForEach(definition.stages) { stage in
                        stepRow(stage, bindings: detail.bindings)
                    }
                }
                .listRowBackground(theme.surface)
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(theme.secondaryText)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle(detail?.name ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit steps", systemImage: "pencil") { context.onEditRecipe(recipeID) }
                } label: {
                    Image(systemName: "ellipsis").bighelpToolbarIcon()
                }
                .accessibilityIdentifier("devfactory.recipe.more")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                running = context.store.recipes.first { $0.id == recipeID }
            } label: {
                Label("Run", systemImage: "play.fill")
                    .font(.bighelp(.headline))
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            }
            .bighelpProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .tint(theme.action)
            .foregroundStyle(theme.actionForeground)
            .disabled(context.store.recipes.first { $0.id == recipeID }?.revision == nil)
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.bottom, BighelpTokens.space8)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("devfactory.recipe.run")
        }
        .bighelpSheet(item: $running) { recipe in
            DevFactoryRunSheet(context: context, recipe: recipe).bighelpSheetSize(.standard)
        }
        .task { await load() }
        .bighelpRefreshable { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("devfactory.recipe")
    }

    private func load() async {
        do {
            detail = try await context.store.client.workflow(id: recipeID, revision: .latest)
            errorMessage = nil
        } catch {
            errorMessage = WorkflowsStore.reason(error)
        }
    }

    private func placementLine(_ definition: WorkflowDefinition) -> String {
        let workspace = definition.codeWorkspace
        if workspace.placement == "local" { return "Each project: its local checkout, on the branch it's on" }
        return "Each project: a new worktree from " + (workspace.base ?? "its current branch")
    }

    private func stepRow(_ stage: WorkflowStage, bindings: [WorkflowBinding]) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: stage.kind.symbol)
                .foregroundStyle(stage.kind.color(theme))
                .frame(width: BighelpTokens.scaled(34), height: BighelpTokens.scaled(34))
                .background(stage.kind.color(theme).opacity(0.14), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(stepKind(stage).uppercased())
                    .font(.bighelp(.caption2).weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.secondaryText)
                Text(stage.title).font(.bighelp(.body).weight(.semibold)).foregroundStyle(theme.primaryText)
                let detail = stage.subtitle { role in
                    bindings.first { $0.role == role }?.agentID.flatMap { id in context.agents.first { $0.id == id }?.name }
                }
                if !detail.isEmpty {
                    Text(detail).font(.system(.caption, design: .monospaced)).foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .combine)
    }

    private func stepKind(_ stage: WorkflowStage) -> String {
        switch stage.kind {
        case .agent: "Agent task · each project"
        case .command: "Check · each project"
        case .signoff: stage.signsChanges ? "Your sign-off on the changes" : "Your sign-off"
        case .pullRequest: "Pull request · each project"
        default: stage.kind.title
        }
    }

    @BighelpThemeReader private var theme
}

