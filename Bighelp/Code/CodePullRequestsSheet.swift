import SwiftUI

/// ☰ › Pull requests in Bighelp IDE: the selected project's pull requests that
/// GitHub knows for its branches. Each opens on GitHub.
struct CodePullRequestsSheet: View {
    let projectName: String
    let pullRequests: [StockGitPullRequest]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if pullRequests.isEmpty {
                    Text("No pull requests for \(projectName)'s branches yet. Ship a session to open one.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .listRowBackground(theme.surface)
                }
                ForEach(pullRequests) { pullRequest in
                    Button { openURL(pullRequest.url) } label: {
                        HStack(spacing: BighelpTokens.space12) {
                            Image(systemName: "arrow.triangle.pull")
                                .foregroundStyle(pullRequest.state == "open" ? theme.success : theme.secondaryText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pullRequest.title).font(.bighelp(.body)).foregroundStyle(theme.primaryText)
                                Text("#\(pullRequest.number) · \(pullRequest.branch) · \(pullRequest.isDraft ? "draft" : pullRequest.state)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").foregroundStyle(theme.secondaryText)
                        }
                        .contentShape(.rect)
                    }
                    .bighelpPlainButtonStyle()
                    .listRowBackground(theme.surface)
                    .accessibilityIdentifier("code.pull-request.\(pullRequest.number)")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Pull requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.pull-requests.sheet")
    }

    @BighelpThemeReader private var theme
}

/// ☰ › Worktrees in Bighelp IDE: the project's branches and worktrees, where
/// finished ones are removed (Hermes keeps a worktree until someone does).
struct CodeWorktreesSheet: View {
    @State var store: StockGitStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WorktreeManagementView(store: store)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .task { await store.load() }
        }
    }
}
