import SwiftUI

@MainActor
struct WorktreeManagementView: View {
    @Bindable var store: StockGitStore
    @State private var showsNewWorktree = false
    @State private var worktreeName = ""
    @State private var branchName = ""
    @State private var baseBranch: String?

    var body: some View {
        List {
            currentBranch
            branches
            worktrees
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Branches & Worktrees")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let defaultBase = store.snapshot?.baseBranches.first(where: \.isDefault)?.name
                    baseBranch = defaultBase
                    worktreeName = ""
                    branchName = ""
                    showsNewWorktree = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!store.canAct || store.snapshot == nil)
                .accessibilityLabel("Add worktree")
            }
        }
        .bighelpSheet(isPresented: $showsNewWorktree) {
            newWorktreeSheet
                .presentationDetents([.medium])
                .bighelpSheetSize(.compact)
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
        .accessibilityIdentifier("stock-git.worktrees")
    }

    @ViewBuilder
    private var currentBranch: some View {
        Section("Current branch") {
            if let status = store.snapshot?.status {
                LabeledContent("Branch", value: status.branch ?? "Detached HEAD")
                LabeledContent("Changes", value: String(status.changed))
                if status.ahead > 0 || status.behind > 0 {
                    LabeledContent("Upstream", value: "\(status.ahead) ahead · \(status.behind) behind")
                }
            } else {
                ProgressView("Loading checkout")
            }
        }
    }

    @ViewBuilder
    private var branches: some View {
        if let snapshot = store.snapshot {
            Section {
                ForEach(snapshot.branches) { branch in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        HStack {
                            Label(branch.name, systemImage: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                            Spacer()
                            if branch.isDefault { Text("Default").font(.bighelp(.caption)).foregroundStyle(.secondary) }
                            if branch.isCheckedOut { Text("Checked out").font(.bighelp(.caption)).foregroundStyle(.secondary) }
                        }
                        if !branch.isCheckedOut && store.canAct {
                            HStack {
                                Button("Review switch") {
                                    store.review(.switchBranch(branch.name))
                                }
                                .buttonStyle(.bordered)
                                Button("Review separate worktree") {
                                    store.review(.addExistingWorktree(branch: branch.name))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
            } header: {
                Text("Branches")
            } footer: {
                Text("Switching changes only this checkout. A separate worktree keeps the current checkout in place.")
            }
        }
    }

    @ViewBuilder
    private var worktrees: some View {
        if let snapshot = store.snapshot {
            Section {
                ForEach(snapshot.worktrees) { worktree in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        HStack {
                            Label(worktree.branch ?? (worktree.isDetached ? "Detached HEAD" : "Worktree"), systemImage: worktree.isMain ? "house" : "point.3.connected.trianglepath.dotted")
                            Spacer()
                            if worktree.isLocked { Image(systemName: "lock.fill").accessibilityLabel("Locked") }
                        }
                        Text(worktree.path).font(.bighelp(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                        if !worktree.isMain && !worktree.isLocked {
                            Button("Review removal", role: .destructive) {
                                store.review(.removeWorktree(path: worktree.path, force: false))
                            }
                            .buttonStyle(.bordered)
                            .disabled(!store.canAct)
                        }
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
            } header: {
                Text("Worktrees")
            } footer: {
                Text("Removal is non-force by default and never targets the main or a locked worktree. Hermes refuses worktrees with uncommitted changes.")
            }
        }
    }

    private var newWorktreeSheet: some View {
        NavigationStack {
            Form {
                Section("New worktree") {
                    TextField("Worktree name", text: $worktreeName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("New branch", text: $branchName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let bases = store.snapshot?.baseBranches, !bases.isEmpty {
                        Picker("Base branch", selection: $baseBranch) {
                            Text("Repository default").tag(String?.none)
                            ForEach(bases) { branch in Text(branch.name).tag(Optional(branch.name)) }
                        }
                    }
                }
                Section("Location") {
                    Text("Hermes chooses the worktree folder under the repository. This form cannot enter a host path or command.")
                        .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsNewWorktree = false }.keyboardShortcut(.cancelAction)
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        let action = StockGitAction.addWorktree(
                            name: worktreeName,
                            branch: branchName,
                            base: baseBranch
                        )
                        showsNewWorktree = false
                        store.review(action)
                    }
                    .disabled(worktreeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
