import SwiftUI

/// A Bighelp IDE session's changes in its worktree (or the local folder), and
/// shipping them: commit, push and a pull request, with the host's own git.
@MainActor
@Observable
final class CodeChangesModel {
    let session: CodeSessionRecord
    /// The folder as git sees it now: uncommitted files, the branch, its pull request.
    private(set) var snapshot: StockGitSnapshot?
    /// A worktree's committed changes against where its branch started.
    private(set) var branchFiles: [StockGitReviewFile] = []
    private(set) var diff: StockGitDiff?
    /// A Markdown file's rendered view, beside its diff.
    private(set) var preview: MarkdownFileModel?
    private(set) var isLoading = false
    private(set) var isShipping = false
    private(set) var shipStep: String?
    private(set) var pullRequestURL: URL?
    var errorMessage: String?

    @ObservationIgnored private let main: StockGitProjectTarget
    @ObservationIgnored private let git: @MainActor () throws -> any StockGitManaging
    @ObservationIgnored private let sendToSession: @MainActor (String) async throws -> Void
    @ObservationIgnored private let textFiles: (any HostTextFileAccess)?

    init(session: CodeSessionRecord, projectFolder: String, git: @escaping @MainActor () throws -> any StockGitManaging,
         textFiles: (any HostTextFileAccess)? = nil,
         sendToSession: @escaping @MainActor (String) async throws -> Void) {
        self.session = session
        main = StockGitProjectTarget(profileID: session.agentID, projectID: session.projectID, cwd: projectFolder,
                                     projectName: session.projectName)
        self.git = git
        self.textFiles = textFiles
        self.sendToSession = sendToSession
    }

    var target: StockGitProjectTarget {
        StockGitProjectTarget(profileID: main.profileID, projectID: main.projectID, cwd: session.folder,
                              projectName: main.projectName)
    }

    var hasUncommittedChanges: Bool { !Self.work(snapshot?.status.files.map(\.path) ?? []).isEmpty }

    /// The session's own files: never `.worktrees/`, where Hermes keeps the project's
    /// worktrees (git sees it as an untracked folder of the main checkout).
    static func work(_ paths: [String]) -> [String] {
        paths.filter { !$0.hasPrefix(".worktrees/") && $0 != ".worktrees" }
    }

    /// The files Changes lists: what isn't committed yet, then what the branch has committed.
    var files: [StockGitReviewFile] {
        let uncommitted = (snapshot?.review.files ?? []).filter { !Self.work([$0.path]).isEmpty }
        let listed = Set(uncommitted.map(\.path))
        return uncommitted + branchFiles.filter { !listed.contains($0.path) && !Self.work([$0.path]).isEmpty }
    }

    private var uncommittedPaths: Set<String> { Set(snapshot?.review.files.map(\.path) ?? []) }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try git()
            // The main folder's worktree list is what lets git act in this session's worktree.
            if session.folder != main.cwd { _ = try await client.snapshot(for: main, scope: .uncommitted) }
            if session.placement == .newWorktree {
                branchFiles = try await client.snapshot(for: target, scope: .branch).review.files
            }
            // Last, so the client's current read is the one Ship and diffs start from.
            snapshot = try await client.snapshot(for: target, scope: .uncommitted)
            pullRequestURL = snapshot?.ship.currentPullRequest?.url
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "Changes couldn't load. \(error.localizedDescription)"
        }
    }

    func open(_ file: StockGitReviewFile) async {
        preview = nil
        if let textFiles, HostFileLink.isMarkdown(file.path), file.status != "D" {
            preview = MarkdownFileModel(path: HostFileLink.resolve(file.path, in: session.folder), access: textFiles)
        }
        do {
            let client = try git()
            if uncommittedPaths.contains(file.path) {
                diff = try await client.fileDiffAgainstHead(for: target, file: file.path)
            } else {
                // A diff is read against the client's latest look at that scope.
                _ = try await client.snapshot(for: target, scope: .branch)
                diff = try await client.diff(for: target, file: file.path, scope: .branch, staged: false)
                snapshot = try await client.snapshot(for: target, scope: .uncommitted)
            }
        } catch is CancellationError {
        } catch {
            errorMessage = "This file's changes couldn't load. \(error.localizedDescription)"
        }
    }

    func closeDiff() {
        diff = nil
        preview = nil
    }

    /// Commits everything uncommitted with `message`, then pushes and opens a pull
    /// request when asked. Each step is the host's own git route, confirmed by a
    /// fresh read before the next.
    func ship(message: String, push: Bool, openPullRequest: Bool) async -> Bool {
        isShipping = true
        defer { isShipping = false; shipStep = nil }
        do {
            let client = try git()
            if session.folder != main.cwd { _ = try await client.snapshot(for: main, scope: .uncommitted) }
            var current = try await client.snapshot(for: target, scope: .uncommitted)
            let paths = Self.work(current.status.files.map(\.path))
            if !paths.isEmpty {
                shipStep = "Committing…"
                let unstaged = Self.work(current.status.files.filter { !$0.isStaged }.map(\.path))
                if !unstaged.isEmpty {
                    current = try await run(.stage(paths: unstaged), client: client).snapshot
                }
                current = try await run(.commit(message: message), client: client).snapshot
            }
            if push || openPullRequest {
                shipStep = "Pushing…"
                current = try await run(.push, client: client).snapshot
            }
            if openPullRequest, current.ship.currentPullRequest == nil {
                shipStep = "Opening the pull request…"
                let result = try await run(.createPullRequest, client: client)
                pullRequestURL = result.pullRequestURL
            }
            await load()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Shipping didn't finish. Check Changes, then try again."
            await load()
            return false
        }
    }

    /// The agent commits, pushes and writes the pull request itself, in its session.
    func askAgentToShip() async -> Bool {
        do {
            try await sendToSession("Commit your changes with a clear message, push the branch, and open a pull request "
                                    + "with the GitHub CLI. Write a short title and a description of what changed and why.")
            return true
        } catch {
            errorMessage = "The message couldn't be sent. Open the session to try again."
            return false
        }
    }

    private func run(_ action: StockGitAction, client: any StockGitManaging) async throws -> StockGitActionResult {
        let prepared = try client.prepare(action, target: target)
        return try await client.execute(prepared, confirmationToken: prepared.confirmationToken)
    }
}

struct CodeChangesView: View {
    @State private var model: CodeChangesModel
    @State private var isShipping = false
    @Environment(\.openURL) private var openURL

    init(model: CodeChangesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            Section {
                summary
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: BighelpTokens.space16, bottom: 0, trailing: BighelpTokens.space16))
            if !model.files.isEmpty {
                let files = model.files
                Section("Files") {
                    ForEach(files) { file in
                        Button { Task { await model.open(file) } } label: { fileRow(file) }
                            .bighelpPlainButtonStyle()
                            .accessibilityIdentifier("code.changes.file")
                    }
                }
                .listRowBackground(theme.surface)
            } else if model.snapshot != nil {
                Text("No changes yet.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .listRowBackground(theme.surface)
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle(model.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { shipBar }
        .refreshable { await model.load() }
        .task { await model.load() }
        .bighelpSheet(item: Binding(get: { model.diff }, set: { if $0 == nil { model.closeDiff() } })) { diff in
            CodeDiffSheet(diff: diff, preview: model.preview).bighelpSheetSize(.large)
        }
        .bighelpSheet(isPresented: $isShipping) {
            CodeShipSheet(model: model).bighelpSheetSize(.standard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.changes")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            CodeWhereLine(placement: model.session.placement, branch: model.session.branch)
            if let status = model.snapshot?.status {
                Text(summaryText(status))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let url = model.pullRequestURL {
                Button { openURL(url) } label: {
                    Label("Pull request #\(url.lastPathComponent)", systemImage: "arrow.triangle.pull")
                        .font(.bighelp(.subheadline).weight(.semibold))
                }
                .accessibilityIdentifier("code.changes.pull-request")
            }
        }
        .padding(.vertical, BighelpTokens.space4)
    }

    private func summaryText(_ status: StockGitStatus) -> String {
        let files = model.files
        let added = files.reduce(0) { $0 + $1.added }
        let removed = files.reduce(0) { $0 + $1.removed }
        let state = model.hasUncommittedChanges ? "not committed" : (status.ahead > 0 ? "\(status.ahead) not pushed" : "committed")
        return "\(files.count == 1 ? "1 file" : "\(files.count) files") +\(added) −\(removed) · \(state)"
    }

    private func fileRow(_ file: StockGitReviewFile) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Text(file.status)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(file.status == "A" ? theme.success : theme.secondaryText)
                .frame(width: 22)
            Text(file.path)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            Text("+\(file.added)").foregroundStyle(theme.success)
            Text("−\(file.removed)").foregroundStyle(theme.danger)
        }
        .font(.system(.footnote, design: .monospaced))
        .contentShape(.rect)
    }

    private var shipBar: some View {
        Button { isShipping = true } label: {
            Label("Ship", systemImage: "arrow.triangle.pull")
                .font(.bighelp(.headline))
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
        }
        .bighelpProminentButtonStyle()
        .buttonBorderShape(.capsule)
        .tint(theme.action)
        .foregroundStyle(theme.actionForeground)
        .disabled(model.snapshot == nil)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.bottom, BighelpTokens.space8)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("code.changes.ship")
    }

    @BighelpThemeReader private var theme
}

extension StockGitDiff: Identifiable {
    var id: String { path }
}

/// One file's diff, added lines green and removed ones red. A Markdown file opens on
/// its rendered Preview (with Edit), and Changes shows the diff.
struct CodeDiffSheet: View {
    let diff: StockGitDiff
    var preview: MarkdownFileModel?
    @Environment(\.dismiss) private var dismiss
    @State private var showsPreview = true

    var body: some View {
        NavigationStack {
            Group {
                if let preview, showsPreview {
                    MarkdownFileContent(model: preview)
                } else {
                    diffText
                }
            }
            .navigationTitle((diff.path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if preview != nil {
                    ToolbarItem(placement: .principal) {
                        Picker("Show", selection: $showsPreview) {
                            Text("Preview").tag(true)
                            Text("Changes").tag(false)
                        }
                        .bighelpSegmentedPicker()
                        .fixedSize()
                        .accessibilityIdentifier("code.diff.mode")
                    }
                }
            }
        }
        .interactiveDismissDisabled(preview?.hasChanges == true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.diff")
    }

    private var diffText: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                        id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, BighelpTokens.space12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: line))
                }
            }
            .padding(.vertical, BighelpTokens.space8)
        }
        .background(theme.canvas.ignoresSafeArea())
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return theme.success.opacity(0.14) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return theme.danger.opacity(0.12) }
        return .clear
    }

    @BighelpThemeReader private var theme
}

/// Ship: commit, push and open a pull request in one go, or ask the agent to.
struct CodeShipSheet: View {
    let model: CodeChangesModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var push = true
    @State private var openPullRequest = true

    var body: some View {
        NavigationStack {
            Form {
                if let branch = model.session.branch {
                    Section {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .listRowBackground(theme.surface)
                }
                if model.hasUncommittedChanges {
                    Section("Commit message") {
                        TextField("What changed", text: $message, axis: .vertical)
                            .lineLimit(2...6)
                            .accessibilityIdentifier("code.ship.message")
                    }
                    .listRowBackground(theme.surface)
                }
                Section {
                    Toggle("Push to GitHub", isOn: $push)
                        .accessibilityIdentifier("code.ship.push")
                    Toggle("Open a pull request", isOn: $openPullRequest)
                        .disabled(model.snapshot?.ship.currentPullRequest != nil)
                        .accessibilityIdentifier("code.ship.pull-request")
                } footer: {
                    Text(footer)
                }
                .listRowBackground(theme.surface)
                Section {
                    Button { Task { if await model.ship(message: commitMessage, push: push,
                                                         openPullRequest: openPullRequest) { dismiss() } } } label: {
                        HStack {
                            Spacer()
                            if let step = model.shipStep { ProgressView(); Text(step) } else { Text(primaryTitle) }
                            Spacer()
                        }
                        .font(.bighelp(.headline))
                    }
                    .disabled(model.isShipping || (!model.hasUncommittedChanges && !push && !openPullRequest))
                    .accessibilityIdentifier("code.ship.go")
                    Button {
                        Task { if await model.askAgentToShip() { dismiss() } }
                    } label: {
                        HStack { Spacer(); Text("Ask the agent to open it"); Spacer() }
                    }
                    .disabled(model.isShipping)
                    .accessibilityIdentifier("code.ship.ask-agent")
                } footer: {
                    if let error = model.errorMessage { Text(error) }
                }
                .listRowBackground(theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Ship")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if message.isEmpty { message = commitSubject } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.ship")
    }

    private var commitMessage: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? commitSubject : trimmed
    }

    /// The session's name without the "…" a long one gets on its card.
    private var commitSubject: String {
        let title = model.session.title
        return title.hasSuffix("…") ? String(title.dropLast()) : title
    }

    private var primaryTitle: String {
        switch (model.hasUncommittedChanges, push || openPullRequest, openPullRequest) {
        case (true, _, true): "Commit, push and open PR"
        case (true, true, false): "Commit and push"
        case (true, false, _): "Commit"
        case (false, _, true): "Push and open PR"
        case (false, _, false): "Push"
        }
    }

    private var footer: String {
        guard let ship = model.snapshot?.ship, let auth = model.snapshot?.githubAuthentication else { return "" }
        if let current = ship.currentPullRequest { return "Pull request #\(current.number) is already open for this branch." }
        if !auth.isAuthenticated || !ship.isGitHubCLIReady {
            return "Sign in to the GitHub CLI on your computer (gh auth login) to open pull requests."
        }
        return "The pull request's title and description come from your commits."
    }

    @BighelpThemeReader private var theme
}
