import SwiftUI

@MainActor
struct ProjectsLifecycleView: View {
    @Bindable var store: ProjectLifecycleStore
    private let stockGitCoordinator: NativeStockGitCoordinator?
    @State private var createRepository: HermesDiscoveredRepository?
    @State private var projectName = ""

    init(
        store: ProjectLifecycleStore,
        stockGitCoordinator: NativeStockGitCoordinator? = nil
    ) {
        _store = Bindable(wrappedValue: store)
        self.stockGitCoordinator = stockGitCoordinator
    }

    var body: some View {
        List {
            statusSection
            if let overview = store.overview {
                registeredProjects(overview)
                automaticProjects(overview)
                discoveredRepositories(overview)
            } else if store.isLoading {
                Section { ProgressView("Loading projects") }
            } else {
                Section {
                    ContentUnavailableView(
                        "Projects unavailable",
                        systemImage: "folder",
                        description: Text("Pull down to reload projects from the selected Hermes host.")
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { if store.overview == nil { await store.load() } }
        .bighelpSheet(item: $createRepository) { repository in
            createProjectSheet(repository)
                .presentationDetents([.medium])
        }
        .alert(item: Binding(
            get: { store.preparedAction },
            set: { if $0 == nil { store.cancelPreparedAction() } }
        )) { prepared in
            Alert(
                title: Text(prepared.action.title),
                message: Text(prepared.summary),
                primaryButton: .cancel { store.cancelPreparedAction() },
                secondaryButton: prepared.action.isDestructive
                    ? .destructive(Text("Confirm")) { Task { await store.confirmPreparedAction() } }
                    : .default(Text("Confirm")) { Task { await store.confirmPreparedAction() } }
            )
        }
        .accessibilityIdentifier("workspace.projects.lifecycle")
    }

    private var statusSection: some View {
        Section("Workspace") {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
            if store.isSaving { ProgressView("Applying project change") }
            if let success = store.successMessage {
                Label(success, systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Retry") { Task { await store.load() } }
                    .disabled(store.isLoading || store.isSaving)
            }
        }
    }

    @ViewBuilder
    private func registeredProjects(_ overview: HermesProjectOverview) -> some View {
        let nodes = Dictionary(uniqueKeysWithValues: overview.tree.map { ($0.id, $0) })
        Section("Projects") {
            if overview.registeredProjects.isEmpty {
                Text("No registered projects.").foregroundStyle(.secondary)
            }
            ForEach(overview.registeredProjects.filter { !$0.isArchived }) { project in
                NavigationLink {
                    ProjectLifecycleDetailView(
                        store: store,
                        projectID: project.id,
                        stockGitCoordinator: stockGitCoordinator
                    )
                } label: {
                    projectRow(project: project, node: nodes[project.id], isActive: overview.activeProjectID == project.id)
                }
                .accessibilityIdentifier("workspace.project.lifecycle.\(project.id)")
            }
        }
    }

    @ViewBuilder
    private func automaticProjects(_ overview: HermesProjectOverview) -> some View {
        let rows = overview.tree.filter { $0.isAutomatic || $0.isHome }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { node in
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Label(node.label, systemImage: node.isHome ? "house" : "externaldrive")
                        Text("\(node.sessionCount) session\(node.sessionCount == 1 ? "" : "s")")
                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                        if let path = node.path {
                            Text(path).font(.bighelp(.caption2)).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                    .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
                }
            } header: {
                Text("Automatic workspaces")
            } footer: {
                Text("Automatic workspaces group existing sessions. Register a discovered repository to manage its folders explicitly.")
            }
        }
    }

    @ViewBuilder
    private func discoveredRepositories(_ overview: HermesProjectOverview) -> some View {
        let registered = Set(overview.registeredProjects.flatMap(\.folders).map(\.path))
        let rows = overview.discoveredRepositories.filter { !registered.contains($0.root) }
        if !rows.isEmpty {
            Section("Add a project") {
                ForEach(rows) { repository in
                    Button {
                        projectName = repository.label
                        createRepository = repository
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(repository.label)
                                Text("\(repository.sessionCount) session\(repository.sessionCount == 1 ? "" : "s")")
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .disabled(!store.canMutate)
                    .accessibilityHint("Reviews a new project registration for this discovered host repository.")
                }
            }
        }
    }

    private func projectRow(
        project: WorkspaceProject,
        node: HermesProjectTreeNode?,
        isActive: Bool
    ) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: isActive ? "folder.fill" : "folder")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(project.name)
                Text("\(project.folders.count) folder\(project.folders.count == 1 ? "" : "s") · \(node?.sessionCount ?? 0) sessions")
                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                if !project.summary.isEmpty {
                    Text(project.summary).font(.bighelp(.caption)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
    }

    private func createProjectSheet(_ repository: HermesDiscoveredRepository) -> some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Project name", text: $projectName)
                        .textInputAutocapitalization(.words)
                    LabeledContent("Discovered folder", value: repository.label)
                    Text(repository.root).font(.bighelp(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section {
                    Text("The folder was reported by the selected Hermes host. Creating a project registers it; no files are copied or modified.")
                        .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { createRepository = nil }
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        let name = projectName
                        createRepository = nil
                        store.review(.create(name: name, discoveredRoot: repository.root))
                    }
                    .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectName.utf8.count > 200)
                }
            }
        }
    }
}

@MainActor
private struct ProjectLifecycleDetailView: View {
    @Bindable var store: ProjectLifecycleStore
    let projectID: String
    private let stockGitCoordinator: NativeStockGitCoordinator?
    @State private var stockGitReview: NativeStockGitProjectReviewCoordinator?

    init(
        store: ProjectLifecycleStore,
        projectID: String,
        stockGitCoordinator: NativeStockGitCoordinator?
    ) {
        _store = Bindable(wrappedValue: store)
        self.projectID = projectID
        self.stockGitCoordinator = stockGitCoordinator
        _stockGitReview = State(initialValue: stockGitCoordinator?.projectReview(
            projectID: projectID,
            projects: store
        ))
    }

    private var detail: HermesProjectDetail? {
        store.detail?.project.id == projectID ? store.detail : nil
    }

    var body: some View {
        List {
            if let detail {
                summary(detail)
                sourceControl
                folders(detail)
                sessionTree(detail.tree)
                deleteSection(detail.project)
            } else if store.isLoadingDetail {
                ProgressView("Loading project")
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(detail?.project.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: projectID) {
            await store.loadDetail(projectID: projectID)
            refreshStockGitReview()
        }
        .refreshable { await store.loadDetail(projectID: projectID) }
        .onChange(of: store.overview) { _, _ in refreshStockGitReview() }
        .accessibilityIdentifier("workspace.project.lifecycle.detail")
    }

    @ViewBuilder
    private var sourceControl: some View {
        if let stockGitReview {
            Section {
                NavigationLink {
                    StockGitReviewView(store: stockGitReview.store)
                } label: {
                    Label("Review project changes", systemImage: "arrow.triangle.branch")
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .accessibilityHint("Opens stock Hermes Git review for this Project's registered primary folder.")
            } header: {
                Text("Source control")
            } footer: {
                Text("Git is limited to the current registered primary folder. No host path can be entered here.")
            }
        }
    }

    private func refreshStockGitReview() {
        guard let stockGitCoordinator else {
            stockGitReview?.retire()
            stockGitReview = nil
            return
        }
        let target = store.stockGitTarget(projectID: projectID)
        guard stockGitReview?.store.target != target else { return }
        stockGitReview?.retire()
        stockGitReview = stockGitCoordinator.projectReview(projectID: projectID, projects: store)
    }

    private func summary(_ detail: HermesProjectDetail) -> some View {
        Section("Overview") {
            LabeledContent("Sessions", value: String(detail.tree.sessionCount))
            LabeledContent("Repositories", value: String(detail.tree.repositories.count))
            if let facts = detail.facts {
                LabeledContent("Repository root", value: facts.root)
                if let kind = facts.kind { LabeledContent("Project type", value: kind) }
                if !facts.verifyCommands.isEmpty {
                    LabeledContent("Verification", value: "\(facts.verifyCommands.count) host command\(facts.verifyCommands.count == 1 ? "" : "s")")
                }
            }
            if !detail.project.summary.isEmpty { Text(detail.project.summary) }
        }
    }

    private func folders(_ detail: HermesProjectDetail) -> some View {
        Section {
            ForEach(detail.project.folders) { folder in
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    HStack {
                        Label(folder.label ?? (folder.isPrimary ? "Primary folder" : "Folder"), systemImage: folder.isPrimary ? "star.fill" : "folder")
                        Spacer()
                        if folder.isPrimary { Text("Primary").font(.bighelp(.caption)).foregroundStyle(.secondary) }
                    }
                    Text(folder.path).font(.bighelp(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                    if store.canMutate {
                        HStack {
                            if !folder.isPrimary {
                                Button("Make primary") {
                                    store.review(.setPrimary(projectID: detail.project.id, path: folder.path))
                                }
                                .buttonStyle(.bordered)
                            }
                            if detail.project.folders.count > 1 {
                                Button("Remove", role: .destructive) {
                                    store.review(.removeFolder(projectID: detail.project.id, path: folder.path))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(.vertical, BighelpTokens.space4)
            }

            let existing = Set(detail.project.folders.map(\.path))
            let choices = store.overview?.discoveredRepositories.filter { !existing.contains($0.root) } ?? []
            if store.canMutate && !choices.isEmpty {
                Menu("Add discovered folder", systemImage: "folder.badge.plus") {
                    ForEach(choices) { repository in
                        Button(repository.label) {
                            store.review(.addFolder(
                                projectID: detail.project.id,
                                discoveredRoot: repository.root,
                                label: repository.label,
                                makePrimary: false
                            ))
                        }
                    }
                }
                .frame(minHeight: BighelpTokens.hitTarget)
            }
        } header: {
            Text("Folders")
        } footer: {
            Text("Folders can only be selected from paths reported by this host. Removing a registration never deletes files.")
        }
    }

    @ViewBuilder
    private func sessionTree(_ tree: HermesProjectTreeNode) -> some View {
        ForEach(tree.repositories) { repository in
            Section(repository.label) {
                if repository.lanes.isEmpty {
                    Text("No sessions in this repository yet.").foregroundStyle(.secondary)
                }
                ForEach(repository.lanes) { lane in
                    DisclosureGroup {
                        if lane.sessions.isEmpty {
                            Text("No loaded sessions in this lane.").foregroundStyle(.secondary)
                        }
                        ForEach(lane.sessions) { session in
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(session.title)
                                if !session.preview.isEmpty {
                                    Text(session.preview).font(.bighelp(.caption)).foregroundStyle(.secondary).lineLimit(2)
                                }
                                HStack {
                                    if let branch = session.branch { Text(branch).font(.bighelp(.caption2)).foregroundStyle(.tertiary) }
                                    Spacer()
                                    if let pullRequest = session.pullRequest {
                                        Link("PR #\(pullRequest.number)", destination: pullRequest.url)
                                            .font(.bighelp(.caption))
                                    }
                                }
                            }
                            .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
                        }
                    } label: {
                        Label(lane.label, systemImage: lane.isKanban ? "rectangle.3.group" : (lane.isMain ? "arrow.triangle.branch" : "point.3.connected.trianglepath.dotted"))
                    }
                }
            }
        }
    }

    private func deleteSection(_ project: WorkspaceProject) -> some View {
        Section {
            Button("Delete project registration", role: .destructive) {
                store.review(.delete(projectID: project.id))
            }
            .disabled(!store.canMutate || store.overview?.activeProjectID == project.id)
            .frame(minHeight: BighelpTokens.hitTarget)
        } header: { Text("Remove project") } footer: {
            Text(store.overview?.activeProjectID == project.id
                ? "Select a different active Project before deleting this registration."
                : "This removes the Hermes project record and folder associations. It does not delete repositories, worktrees, or files.")
        }
    }
}
