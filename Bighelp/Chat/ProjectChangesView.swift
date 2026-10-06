import SwiftUI

enum ProjectChangesDiffDisplayMode: Equatable {
    case diff
    case preview
}

struct ProjectChangesDiffDisplayState: Equatable {
    private(set) var mode: ProjectChangesDiffDisplayMode = .diff

    mutating func select(_ mode: ProjectChangesDiffDisplayMode) {
        self.mode = mode
    }

    mutating func prepareForFileSelection() {
        mode = .diff
    }
}

enum ProjectChangesPanelWidthPolicy {
    static let minimum: CGFloat = 520

    static func clamp(width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        min(max(width, minimum), containerWidth)
    }

    static func snap(width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        width >= containerWidth * 0.7 ? containerWidth : minimum
    }

    static func snappedWidth(
        startWidth: CGFloat,
        translation: CGFloat,
        containerWidth: CGFloat
    ) -> CGFloat {
        snap(
            width: startWidth - translation,
            containerWidth: containerWidth
        )
    }
}

enum ProjectChangesMarkdownPreview: Equatable {
    case content(String)
    case unavailable(String)
}

enum ProjectChangesMarkdownPreviewBuilder {
    static func preview(
        for diff: ProjectGitDiffPage,
        file: ProjectGitFileChange
    ) -> ProjectChangesMarkdownPreview {
        guard isPreviewableText(path: diff.path) else {
            return .unavailable("Preview is available only for Markdown and plain-text files.")
        }
        guard diff.path == file.path else {
            return .unavailable("A complete Markdown preview is not available for this diff.")
        }
        if let previewContent = diff.previewContent {
            return .content(previewContent)
        }
        switch diff.availability {
        case .binary:
            return .unavailable("Binary Markdown files cannot be previewed.")
        case .oversized:
            return .unavailable("This Markdown diff is too large to preview safely.")
        case .available:
            break
        }
        guard diff.nextOffset == nil else {
            return .unavailable("Load every diff page before previewing this Markdown file.")
        }
        let representsCompleteSelectedFile = switch diff.side {
        case .worktree:
            file.kind == .untracked
        case .staged:
            file.indexStatus == "A"
        }
        guard representsCompleteSelectedFile else {
            return .unavailable("Tracked diffs contain changed hunks, not the complete file.")
        }
        guard
            diff.offset == 0
        else {
            return .unavailable("A complete Markdown preview is not available for this diff.")
        }

        var content: [String] = []
        var expectedNewLine = 1
        for line in diff.lines {
            switch line.kind {
            case .addition:
                guard line.newLine == expectedNewLine else {
                    return .unavailable("A complete Markdown preview is not available for this diff.")
                }
                content.append(line.content)
                expectedNewLine += 1
            case .header, .hunk, .noNewline:
                continue
            case .context, .deletion:
                return .unavailable("A complete Markdown preview is not available for this diff.")
            }
        }
        return .content(content.joined(separator: "\n"))
    }

    static func isMarkdown(path: String) -> Bool {
        guard let extensionSeparator = path.lastIndex(of: ".") else { return false }
        let pathExtension = path[path.index(after: extensionSeparator)...].lowercased()
        return pathExtension == "md" || pathExtension == "markdown"
    }

    static func isPreviewableText(path: String) -> Bool {
        if isMarkdown(path: path) { return true }
        guard let extensionSeparator = path.lastIndex(of: ".") else { return false }
        return path[path.index(after: extensionSeparator)...].lowercased() == "txt"
    }
}

struct ProjectChangesView: View {
    @Bindable var store: ProjectChangesStore
    let showsCloseButton: Bool
    let onClose: () -> Void
    var isExpanded = false
    var onToggleExpansion: (() -> Void)?

    @State private var isCommitPresented = false
    @State private var commitMessage = ""
    @State private var isConfirmationPresented = false
    @State private var diffSideSelection: ProjectGitFileChange?
    @State private var diffDisplayState = ProjectChangesDiffDisplayState()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if showsCloseButton {
                panelHeader
                Divider()
            }
            Group {
                if let status = store.status {
                    project(status)
                } else if store.isLoading {
                    ProgressView("Loading project changes")
                        .tint(theme.action)
                        .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.railSummary?.state == .unavailable {
                    ContentUnavailableView(
                        "Project changes unavailable",
                        systemImage: "arrow.triangle.branch",
                        description: Text("This Project is not a Git repository.")
                    )
                } else {
                    VStack(spacing: BighelpTokens.space16) {
                        ContentUnavailableView(
                            "Project changes unavailable",
                            systemImage: "arrow.triangle.branch",
                            description: Text(store.errorMessage
                                ?? "Pin this chat to a Hermes Project to review its Git changes.")
                        )
                        if store.target != nil {
                            Button("Retry", systemImage: "arrow.clockwise") {
                                Task { await store.refresh() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.isLoading)
                        }
                    }
                }
            }
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-changes.panel")
        .navigationTitle("Project Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsCloseButton ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !showsCloseButton {
                ToolbarItemGroup(placement: .primaryAction) {

                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading || store.isMutating)
                    .accessibilityLabel("Refresh project changes")
                }
            }
        }
        .bighelpSheet(isPresented: $isCommitPresented) {
            commitSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: store.preparedOperation) { _, prepared in
            isConfirmationPresented = prepared != nil
        }
        .confirmationDialog(
            "Confirm Git operation",
            isPresented: $isConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Confirm \(store.preparedOperation?.operation.rawValue.capitalized ?? "operation")") {
                Task { await store.executePrepared() }
            }
            Button("Cancel", role: .cancel) {
                store.cancelPreparedOperation()
            }
        } message: {
            Text(store.preparedOperation?.preview.summary ?? "Review this operation before it runs.")
        }
        .confirmationDialog(
            "Choose which diff to view",
            isPresented: Binding(
                get: { diffSideSelection != nil },
                set: { if !$0 { diffSideSelection = nil } }
            ),
            titleVisibility: .visible,
            presenting: diffSideSelection
        ) { file in
            ForEach(file.availableDiffSides, id: \.rawValue) { side in
                Button(side == .staged ? "Staged changes" : "Working tree changes") {
                    diffSideSelection = nil
                    loadDiff(file, side: side)
                }
            }
            Button("Cancel", role: .cancel) {
                diffSideSelection = nil
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: BighelpTokens.space8) {
            BighelpHeaderActionButton(
                systemImage: "xmark",
                accessibilityLabel: "Close project changes",
                action: onClose
            )
            Spacer(minLength: BighelpTokens.space8)
            Text("Project Changes")
                .bighelpFont(.sectionTitle, weight: .semibold)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: BighelpTokens.space8)
            if let onToggleExpansion {
                BighelpHeaderActionButton(
                    systemImage: isExpanded
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    accessibilityLabel: isExpanded
                        ? "Restore project changes panel"
                        : "Expand project changes",
                    action: onToggleExpansion
                )
            }
            BighelpHeaderActionButton(
                systemImage: "arrow.clockwise",
                accessibilityLabel: "Refresh project changes",
                isEnabled: !store.isLoading && !store.isMutating,
                action: { Task { await store.refresh() } }
            )
        }
        .padding(.horizontal, BighelpTokens.space12)
        .frame(minHeight: 56)
        .background(theme.canvas)
    }

    private func project(_ status: ProjectGitStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                statusHeader(status)
                commandBar(status)

                if let error = store.errorMessage {
                    Text(error)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(BighelpTokens.space12)
                        .bighelpSurface(.card)
                }

                if let diff = store.diff {
                    diffView(diff)
                }

                if status.files.isEmpty {
                    ContentUnavailableView(
                        "Working tree clean",
                        systemImage: "checkmark.circle",
                        description: Text("No staged or unstaged changes in this Project.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(status.files.enumerated()), id: \.element.id) { index, file in
                            fileRow(file)
                            if index < status.files.count - 1 {
                                Divider().padding(.leading, BighelpTokens.space16)
                            }
                        }
                    }
                    .bighelpSurface(.card)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(BighelpTokens.space16)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
    }

    private func statusHeader(_ status: ProjectGitStatus) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                if let workspaceName = store.target?.workspaceName {
                    Text(workspaceName)
                        .bighelpFont(.label, weight: .semibold)
                        .foregroundStyle(theme.action)
                }
                Text(status.head.branch ?? "Detached HEAD")
                    .bighelpFont(.sectionTitle, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text("\(status.changes.files) files · +\(status.changes.insertions) −\(status.changes.deletions)")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                if let upstream = status.head.upstream {
                    Text("\(upstream) · \(status.head.ahead) ahead · \(status.head.behind) behind")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(BighelpTokens.space16)
        .bighelpSurface(.card)
    }

    private func commandBar(_ status: ProjectGitStatus) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BighelpTokens.space8) {
                if allows(.stage) {
                    command("Stage all", systemImage: "plus.circle") {
                        let paths = status.files.map(\.path)
                        Task { await store.prepare(.stage(mode: .stage, paths: paths)) }
                    }
                    .disabled(!status.filesPage.isComplete)
                    .accessibilityHint(status.filesPage.isComplete
                        ? "Stages every changed file shown in this Project."
                        : "Refresh after the complete file list is available.")
                }
                if allows(.commit) {
                    command("Commit", systemImage: "checkmark.circle") {
                        commitMessage = ""
                        isCommitPresented = true
                    }
                }
                if allows(.fetch), let remote {
                    command("Fetch", systemImage: "arrow.down.circle") {
                        Task { await store.prepare(.fetch(remote: remote)) }
                    }
                }
                if allows(.pull), let remote, let branch {
                    command("Pull", systemImage: "arrow.down.to.line") {
                        Task { await store.prepare(.pull(remote: remote, branch: branch)) }
                    }
                }
                if allows(.push), let remote, let branch {
                    command("Push", systemImage: "arrow.up.to.line") {
                        Task { await store.prepare(.push(remote: remote, branch: branch)) }
                    }
                }
            }
            .padding(.horizontal, BighelpTokens.space4)
        }
        .scrollIndicators(.hidden)
    }

    private func command(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .bighelpFont(.label)
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.capsule)
                .bighelpSurface(.capsuleControl, isInteractive: true)
        }
        .buttonStyle(.plain)
        .disabled(store.isMutating)
    }

    private func fileRow(_ file: ProjectGitFileChange) -> some View {
        Button {
            if file.availableDiffSides.count == 1,
               let side = file.availableDiffSides.first {
                loadDiff(file, side: side)
            } else {
                diffSideSelection = file
            }
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: file.isBinary ? "doc.fill" : "doc.text")
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(file.kind.rawValue.capitalized)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("+\(file.insertions)")
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.success)
                Text("−\(file.deletions)")
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.danger)
            }
            .padding(.horizontal, BighelpTokens.space16)
            .frame(minHeight: 58)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.path), \(file.insertions) additions, \(file.deletions) deletions")
    }

    private func diffView(_ diff: ProjectGitDiffPage) -> some View {
        let preview = ProjectChangesMarkdownPreviewBuilder.preview(
            for: diff,
            file: store.status?.files.first { $0.path == diff.path }
                ?? ProjectGitFileChange(
                    path: diff.path, originalPath: nil, indexStatus: ".", worktreeStatus: ".",
                    kind: .ordinary, insertions: 0, deletions: 0, isBinary: diff.availability == .binary
                )
        )
        let isMarkdownPreview = ProjectChangesMarkdownPreviewBuilder.isMarkdown(path: diff.path)
        let canPreview = ProjectChangesMarkdownPreviewBuilder.isPreviewableText(path: diff.path)
        let showingPreview = diffDisplayState.mode == .preview

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(diff.path)
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                Spacer(minLength: BighelpTokens.space8)
                if canPreview {
                    Picker("Diff display", selection: Binding(
                        get: { diffDisplayState.mode },
                        set: { diffDisplayState.select($0) }
                    )) {
                        Text("Diff").tag(ProjectChangesDiffDisplayMode.diff)
                        Text("Preview").tag(ProjectChangesDiffDisplayMode.preview)
                    }
                    .bighelpSegmentedPicker()
                    .frame(width: 156)
                    .accessibilityLabel("Text file display")
                    .accessibilityHint("Switch between the raw diff and a complete file preview.")
                }
            }
            .padding(BighelpTokens.space16)

            Divider()

            if showingPreview {
                switch preview {
                case .content(let content):
                    ScrollView {
                        if isMarkdownPreview {
                            MarkdownMessageView(document: MarkdownDocument(content))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(BighelpTokens.space16)
                        } else {
                            Text(content)
                                .font(.bighelp(.body, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(BighelpTokens.space16)
                        }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                case .unavailable(let reason):
                    ContentUnavailableView("Preview unavailable", systemImage: "doc.text.magnifyingglass", description: Text(reason))
                        .frame(maxWidth: .infinity)
                        .padding(BighelpTokens.space16)
                }
            } else if diff.availability != .available {
                Text(diff.availability == .binary
                    ? "Binary diff is not available."
                    : "This diff is too large to display safely.")
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .padding(BighelpTokens.space16)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { line in
                        HStack(alignment: .top, spacing: BighelpTokens.space8) {
                            HStack(spacing: 2) {
                                Text(line.oldLine.map(String.init) ?? "")
                                Text(line.newLine.map(String.init) ?? "")
                            }
                            .frame(width: 76, alignment: .trailing)
                            .foregroundStyle(theme.tertiaryText)
                            Text(prefix(for: line.kind) + line.content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.bighelp(.caption, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, BighelpTokens.space8)
                        .padding(.vertical, 3)
                        .background(diffBackground(line.kind))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let nextOffset = diff.nextOffset {
                    Button {
                        Task { await store.loadDiff(path: diff.path, side: diff.side, offset: nextOffset) }
                    } label: {
                        HStack(spacing: BighelpTokens.space8) {
                            if store.isLoadingDiff { BighelpThinkingOrb(scenario: .working, scale: .inline) }
                            Text(store.isLoadingDiff ? "Loading more" : "Load more diff")
                                .bighelpFont(.label, weight: .semibold)
                        }
                        .foregroundStyle(theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                        .contentShape(.capsule)
                        .bighelpSurface(.capsuleControl, isInteractive: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isLoadingDiff)
                    .accessibilityLabel("Load more diff lines")
                    .padding(BighelpTokens.space12)
                }
            }
        }
        .bighelpSurface(.card)
        .onChange(of: diff.path) { _, _ in diffDisplayState = ProjectChangesDiffDisplayState() }
    }

    private func loadDiff(_ file: ProjectGitFileChange, side: ProjectGitDiffSide) {
        diffDisplayState.prepareForFileSelection()
        Task {
            await store.loadDiff(path: file.path, side: side)
        }
    }

    private var commitSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                Text("Commit message")
                    .bighelpFont(.sectionTitle, weight: .semibold)
                TextEditor(text: $commitMessage)
                    .bighelpFont(.body)
                    .scrollContentBackground(.hidden)
                    .padding(BighelpTokens.space12)
                    .frame(minHeight: 140)
                    .bighelpSurface(.input, isInteractive: true)
                Spacer(minLength: 0)
            }
            .padding(BighelpTokens.space20)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Commit Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isCommitPresented = false }
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        isCommitPresented = false
                        Task { await store.prepare(.commit(message: message)) }
                    }
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func allows(_ operation: ProjectGitOperation) -> Bool {
        guard let capability = ProjectGitCapabilityOperation(rawValue: operation.rawValue) else {
            return false
        }
        return workspaceCapabilities?.mutationsEnabled == true
            && workspaceCapabilities?.operations.contains(capability) == true
    }

    private var workspaceCapabilities: ProjectGitWorkspaceCapabilities? {
        guard let target = store.target else { return nil }
        return store.capabilities?.workspaces.first { $0.workspaceID == target.workspaceID }
    }

    private var remote: String? { workspaceCapabilities?.remotes.first }
    private var branch: String? { store.status?.head.branch ?? workspaceCapabilities?.branches.first }

    private func prefix(for kind: ProjectGitDiffLineKind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        case .header, .hunk, .noNewline: ""
        }
    }

    private func diffBackground(_ kind: ProjectGitDiffLineKind) -> Color {
        switch kind {
        case .addition: theme.success.opacity(0.14)
        case .deletion: theme.danger.opacity(0.14)
        case .header, .hunk: theme.raisedSurface
        case .context, .noNewline: .clear
        }
    }

    @BighelpThemeReader private var theme

}
