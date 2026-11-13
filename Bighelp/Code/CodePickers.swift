import SwiftUI

// The chips a new chat's choices row uses for a coding session, and the pickers they open.

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
            .bighelpRefreshable { await store.load() }
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
