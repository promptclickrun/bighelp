import SwiftUI

@MainActor
struct StockGitReviewView: View {
    @Bindable var store: StockGitStore
    @State private var commitMessage = ""
    @State private var showsCommit = false
    @State private var diffChoice: StockGitReviewFile?

    var body: some View {
        List {
            repositoryStatus
            reviewControls
            feedback
            files
            shipping
            verification
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Project Changes")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { if store.snapshot == nil { await store.load() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    WorktreeManagementView(store: store)
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .disabled(store.snapshot == nil)
                .accessibilityLabel("Manage branches and worktrees")
            }
        }
        .bighelpSheet(isPresented: $showsCommit) { commitSheet.bighelpSheetSize(.standard) }
        .bighelpSheet(item: Binding(
            get: { store.diff.map { IdentifiedStockGitDiff(value: $0) } },
            set: { if $0 == nil { store.closeDiff() } }
        )) { identified in
            StockGitDiffView(diff: identified.value)
                .presentationDetents([.medium, .large])
                .bighelpSheetSize(.large)
        }
        .confirmationDialog(
            "Choose a diff",
            isPresented: Binding(get: { diffChoice != nil }, set: { if !$0 { diffChoice = nil } }),
            titleVisibility: .visible,
            presenting: diffChoice
        ) { file in
            if file.isStaged {
                Button("Staged changes") {
                    diffChoice = nil
                    Task { await store.loadDiff(path: file.path, staged: true) }
                }
            }
            Button("Working tree changes") {
                diffChoice = nil
                Task { await store.loadDiff(path: file.path, staged: false) }
            }
            Button("Cancel", role: .cancel) { diffChoice = nil }
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
        .accessibilityIdentifier("stock-git.review")
    }

    @ViewBuilder
    private var repositoryStatus: some View {
        Section("Repository") {
            LabeledContent("Project", value: store.target.projectName)
            if let status = store.snapshot?.status {
                LabeledContent("Branch", value: status.branch ?? "Detached HEAD")
                LabeledContent("Changes", value: "\(status.changed) files · +\(status.added) −\(status.removed)")
                if status.ahead > 0 || status.behind > 0 {
                    LabeledContent("Upstream", value: "\(status.ahead) ahead · \(status.behind) behind")
                }
            } else if store.isLoading {
                ProgressView("Loading repository")
            }
        }
    }

    @ViewBuilder
    private var reviewControls: some View {
        if let snapshot = store.snapshot {
            Section("Select changes") {
                Picker("Change set", selection: Binding(
                    get: { store.reviewScope },
                    set: { scope in Task { await store.selectScope(scope) } }
                )) {
                    ForEach(StockGitReviewScope.allCases) { scope in Text(scope.title).tag(scope) }
                }
                .bighelpSegmentedPicker()

                if !store.selectedPaths.isEmpty {
                    HStack {
                        Text("\(store.selectedPaths.count) selected")
                        Spacer()
                        Button("Clear") { store.clearSelection() }
                    }
                    if canStage(snapshot) {
                        Button("Review stage", systemImage: "plus.circle") { store.reviewSelectedStage() }
                    }
                    if canUnstage(snapshot) {
                        Button("Review unstage", systemImage: "minus.circle") { store.reviewSelectedUnstage() }
                    }
                    Button("Review revert", systemImage: "arrow.uturn.backward", role: .destructive) {
                        store.reviewSelectedRevert()
                    }
                } else {
                    Text("Select files below to stage, unstage, or revert only those changes.")
                        .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if store.isSaving {
            Section { ProgressView("Applying Git operation") }
        }
        if let success = store.successMessage {
            Section { Label(success, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
        }
        if let error = store.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Refresh repository") { Task { await store.load() } }
                    .disabled(store.isLoading || store.isSaving)
            }
        }
    }

    @ViewBuilder
    private var files: some View {
        if let snapshot = store.snapshot {
            Section("Files") {
                if snapshot.review.files.isEmpty {
                    ContentUnavailableView("Working tree clean", systemImage: "checkmark.circle")
                }
                ForEach(snapshot.review.files) { file in
                    HStack(spacing: BighelpTokens.space12) {
                        Button {
                            store.toggle(file.path)
                        } label: {
                            Image(systemName: store.selectedPaths.contains(file.path) ? "checkmark.circle.fill" : "circle")
                                .font(.bighelp(.title3))
                                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.reviewScope != .uncommitted)
                        .accessibilityLabel(store.selectedPaths.contains(file.path) ? "Deselect \(file.path)" : "Select \(file.path)")

                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(file.path).lineLimit(2)
                            HStack {
                                Text(file.status).font(.bighelp(.caption)).foregroundStyle(.secondary)
                                if file.isStaged { Text("Staged").font(.bighelp(.caption)).foregroundStyle(.secondary) }
                                Text("+\(file.added) −\(file.removed)").font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            diffChoice = file
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View diff for \(file.path)")
                    }
                    .contentShape(Rectangle())
                }
            }
        }
    }

    @ViewBuilder
    private var shipping: some View {
        if let snapshot = store.snapshot {
            Section {
                Button("Commit staged changes", systemImage: "checkmark.circle") {
                    commitMessage = ""
                    showsCommit = true
                }
                .disabled(!snapshot.review.files.contains(where: \.isStaged) || !store.canAct)

                Button("Review push", systemImage: "arrow.up.circle") {
                    store.review(.push)
                }
                .disabled(snapshot.status.branch == nil || !store.canAct)

                if let current = snapshot.ship.currentPullRequest {
                    Link("Open PR #\(current.number)", destination: current.url)
                } else {
                    Button("Review pull request creation", systemImage: "arrow.triangle.pull") {
                        store.review(.createPullRequest)
                    }
                    .disabled(!snapshot.ship.isGitHubCLIReady || snapshot.status.branch == nil || !store.canAct)
                }
            } header: {
                Text("Commit and share")
            } footer: {
                Text("GitHub CLI availability does not grant permission. Push and pull request creation each require an explicit review and confirmation.")
            }
        }
    }

    @ViewBuilder
    private var verification: some View {
        if let verification = store.snapshot?.verification {
            Section("Verification evidence") {
                LabeledContent("Status", value: verification.status.capitalized)
                if let scope = verification.scope { LabeledContent("Scope", value: scope.capitalized) }
                if verification.command != nil {
                    Text("Hermes has recorded verification evidence for this repository. This screen does not run commands.")
                        .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var commitSheet: some View {
        NavigationStack {
            Form {
                Section("Commit message") {
                    TextEditor(text: $commitMessage)
                        .frame(minHeight: 140)
                }
                Section("Before you commit") {
                    Text("Only changes already staged in the repository will be committed. Pushing remains a separate confirmed action.")
                        .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                    if let subjects = store.snapshot?.commitContext.recentSubjects, !subjects.isEmpty {
                        DisclosureGroup("Recent commit subjects") {
                            ForEach(subjects, id: \.self) { subject in
                                Text(subject).font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Commit Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsCommit = false }.keyboardShortcut(.cancelAction)
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        let message = commitMessage
                        showsCommit = false
                        store.review(.commit(message: message))
                    }
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commitMessage.utf8.count > 10_000)
                }
            }
        }
    }

    private func canStage(_ snapshot: StockGitSnapshot) -> Bool {
        store.selectedPaths.allSatisfy { path in
            guard let review = snapshot.review.files.first(where: { $0.path == path }) else { return false }
            return !review.isStaged || snapshot.status.files.first(where: { $0.path == path })?.isUnstaged == true
        }
    }

    private func canUnstage(_ snapshot: StockGitSnapshot) -> Bool {
        store.selectedPaths.allSatisfy { path in
            snapshot.review.files.first(where: { $0.path == path })?.isStaged == true
        }
    }
}

private struct IdentifiedStockGitDiff: Identifiable {
    let value: StockGitDiff
    var id: String { "\(value.scope.rawValue):\(value.isStaged):\(value.path)" }
}

private struct StockGitDiffView: View {
    let diff: StockGitDiff

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(diff.text.isEmpty ? "No diff content was returned for this selection." : diff.text)
                    .font(.bighelp(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(BighelpTokens.space16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(diff.path)
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("stock-git.diff")
    }
}
