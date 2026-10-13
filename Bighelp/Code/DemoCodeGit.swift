import Foundation

/// Demo mode's git: each sample project's main folder on `main`, plus the worktrees
/// Bighelp IDE makes. A new worktree comes with three sample changed files (one is the
/// plan `DemoHostTextFiles` serves), so Changes, its Markdown preview and Ship have
/// something to show; commit, push and PR move them along.
@MainActor
final class DemoCodeGit: StockGitManaging {
    private struct Folder {
        var branch: String
        var isMain: Bool
        var root: String
        var changed: [StockGitReviewFile] = []
        var staged: Set<String> = []
        var commits = 0
        var pushed = false
        var pullRequest: StockGitPullRequest?
    }

    private var folders: [String: Folder] = [:]
    private var prepared: [UUID: StockGitPreparedAction] = [:]
    private var nextPullRequest = 342
    private static let otherBranches = ["feat/code-mode", "fix/widget-asleep", "release/2.6"]

    func snapshot(for target: StockGitProjectTarget, scope: StockGitReviewScope) async throws -> StockGitSnapshot {
        try snapshot(target, scope: scope)
    }

    func diff(for target: StockGitProjectTarget, file: String, scope: StockGitReviewScope,
              staged: Bool) async throws -> StockGitDiff {
        StockGitDiff(path: file, scope: scope, isStaged: staged, text: Self.sampleDiff(file))
    }

    func fileDiffAgainstHead(for target: StockGitProjectTarget, file: String) async throws -> StockGitDiff {
        StockGitDiff(path: file, scope: .uncommitted, isStaged: false, text: Self.sampleDiff(file))
    }

    func prepare(_ action: StockGitAction, target: StockGitProjectTarget) throws -> StockGitPreparedAction {
        let current = try snapshot(target, scope: .uncommitted)
        let value = StockGitPreparedAction(id: UUID(), confirmationToken: UUID().uuidString, target: target,
                                           statusToken: current.status.token, action: action, summary: action.title)
        prepared[value.id] = value
        return value
    }

    func execute(_ requested: StockGitPreparedAction, confirmationToken: String) async throws -> StockGitActionResult {
        guard let action = prepared.removeValue(forKey: requested.id), action.confirmationToken == confirmationToken
        else { throw WorkspaceClientError.conflict }
        let target = action.target
        var folder = folder(for: target)
        var pullRequestURL: URL?
        switch action.action {
        case .addWorktree(let name, let branch, _):
            let path = "\(folder.root)/.worktrees/\(name)"
            folders[path] = Folder(branch: branch, isMain: false, root: folder.root, changed: Self.sampleChanges)
        case .stage(let paths):
            folder.staged.formUnion(paths)
        case .unstage(let paths):
            folder.staged.subtract(paths)
        case .commit:
            folder.changed.removeAll { folder.staged.contains($0.path) }
            folder.staged.removeAll()
            folder.commits += 1
            folder.pushed = false
        case .push:
            folder.pushed = true
        case .createPullRequest:
            let url = URL(string: "https://github.com/demo/\(target.projectName)/pull/\(nextPullRequest)")!
            folder.pullRequest = StockGitPullRequest(number: nextPullRequest, branch: folder.branch,
                                                     title: "Demo change", url: url, state: "open", isDraft: false)
            nextPullRequest += 1
            pullRequestURL = url
        case .switchBranch(let branch):
            folder.branch = branch
        case .removeWorktree(let path, _):
            folders[path] = nil
        case .revert(let paths):
            folder.changed.removeAll { paths.contains($0.path) }
        case .addExistingWorktree:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        folders[target.cwd] = folder
        return StockGitActionResult(action: action.action, snapshot: try snapshot(target, scope: .uncommitted),
                                    pullRequestURL: pullRequestURL)
    }

    private func folder(for target: StockGitProjectTarget) -> Folder {
        if let known = folders[target.cwd] { return known }
        let main = Folder(branch: "main", isMain: true, root: target.cwd)
        folders[target.cwd] = main
        return main
    }

    private func snapshot(_ target: StockGitProjectTarget, scope: StockGitReviewScope) throws -> StockGitSnapshot {
        let folder = folder(for: target)
        let linked = folders.filter { $0.value.root == folder.root && !$0.value.isMain }
            .sorted { $0.key < $1.key }
        let mainPath = folders.first { $0.value.root == folder.root && $0.value.isMain }?.key ?? folder.root
        let mainBranch = folders[mainPath]?.branch ?? "main"
        let worktrees = [StockGitWorktree(path: mainPath, branch: mainBranch, isMain: true, isDetached: false, isLocked: false)]
            + linked.map { StockGitWorktree(path: $0.key, branch: $0.value.branch, isMain: false, isDetached: false, isLocked: false) }
        let names = ["main"] + Self.otherBranches + linked.map(\.value.branch)
        let branches = names.map { name in
            StockGitBranch(name: name, isCheckedOut: worktrees.contains { $0.branch == name }, isDefault: name == "main",
                           isRemote: false, worktreePath: worktrees.first { $0.branch == name }?.path)
        } + [StockGitBranch(name: "origin/release/2.6", isCheckedOut: false, isDefault: false, isRemote: true, worktreePath: nil)]
        let files = folder.changed.map {
            StockGitFileState(path: $0.path, isStaged: folder.staged.contains($0.path), isUnstaged: true,
                              isUntracked: $0.status == "A", isConflicted: false)
        }
        let review = StockGitReview(scope: scope, base: folder.isMain ? nil : "main", files: folder.changed.map {
            StockGitReviewFile(path: $0.path, added: $0.added, removed: $0.removed, status: $0.status,
                               isStaged: folder.staged.contains($0.path))
        })
        let status = StockGitStatus(branch: folder.branch, defaultBranch: "main", isDetached: false,
                                    ahead: folder.pushed ? 0 : folder.commits, behind: 0, changed: folder.changed.count,
                                    added: folder.changed.reduce(0) { $0 + $1.added },
                                    removed: folder.changed.reduce(0) { $0 + $1.removed }, files: files,
                                    token: "\(folder.branch)-\(folder.changed.count)-\(folder.staged.count)-\(folder.commits)-\(folder.pushed)")
        return StockGitSnapshot(
            target: target, status: status, review: review, branches: branches,
            baseBranches: branches.filter { !$0.isRemote && !$0.name.hasPrefix(CodeBranchName.prefix) },
            worktrees: worktrees,
            githubAuthentication: StockGitGitHubAuthentication(isAvailable: true, isAuthenticated: true),
            ship: StockGitShipState(isGitHubCLIReady: true, currentPullRequest: folder.pullRequest),
            pullRequests: folders.values.compactMap(\.pullRequest),
            commitContext: StockGitCommitContext(diff: "", recentSubjects: ["Build 115"]),
            verification: nil, facts: nil
        )
    }

    private static let sampleChanges = [
        StockGitReviewFile(path: "Bighelp/App/BighelpIncomingLinkCenter.swift", added: 18, removed: 4, status: "M", isStaged: false),
        StockGitReviewFile(path: "BighelpTests/IncomingLinkQueueTests.swift", added: 21, removed: 0, status: "A", isStaged: false),
        StockGitReviewFile(path: DemoHostTextFiles.planPath, added: 19, removed: 0, status: "A", isStaged: false),
    ]

    private static func sampleDiff(_ file: String) -> String {
        """
        diff --git a/\(file) b/\(file)
        @@ -41,9 +41,14 @@
             func post(_ link: URL) {
        -        open(link)
        +        guard runtime.isReady else {
        +            pending.append(link)
        +            return
        +        }
        +        open(link)
             }
        """
    }
}
