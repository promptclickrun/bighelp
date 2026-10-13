import CryptoKit
import Foundation

struct StockGitProjectTarget: Equatable, Sendable {
    let profileID: String
    let projectID: String
    let cwd: String
    let projectName: String
}

enum StockGitReviewScope: String, CaseIterable, Identifiable, Sendable {
    case uncommitted
    case branch

    var id: Self { self }
    var title: String { self == .uncommitted ? "Working tree" : "Current branch" }
}

struct StockGitFileState: Identifiable, Equatable, Sendable {
    let path: String
    let isStaged: Bool
    let isUnstaged: Bool
    let isUntracked: Bool
    let isConflicted: Bool
    var id: String { path }
}

struct StockGitStatus: Equatable, Sendable {
    let branch: String?
    let defaultBranch: String?
    let isDetached: Bool
    let ahead: Int
    let behind: Int
    let changed: Int
    let added: Int
    let removed: Int
    let files: [StockGitFileState]
    let token: String
}

struct StockGitReviewFile: Identifiable, Equatable, Sendable {
    let path: String
    let added: Int
    let removed: Int
    let status: String
    let isStaged: Bool
    var id: String { path }
}

struct StockGitReview: Equatable, Sendable {
    let scope: StockGitReviewScope
    let base: String?
    let files: [StockGitReviewFile]
}

struct StockGitBranch: Identifiable, Equatable, Sendable {
    let name: String
    let isCheckedOut: Bool
    let isDefault: Bool
    let isRemote: Bool
    let worktreePath: String?
    var id: String { name }
}

struct StockGitWorktree: Identifiable, Equatable, Sendable {
    let path: String
    let branch: String?
    let isMain: Bool
    let isDetached: Bool
    let isLocked: Bool
    var id: String { path }
}

struct StockGitPullRequest: Identifiable, Equatable, Sendable {
    let number: Int
    let branch: String
    let title: String
    let url: URL
    let state: String
    let isDraft: Bool
    var id: Int { number }
}

struct StockGitShipState: Equatable, Sendable {
    let isGitHubCLIReady: Bool
    let currentPullRequest: StockGitPullRequest?
}

struct StockGitGitHubAuthentication: Equatable, Sendable {
    let isAvailable: Bool
    let isAuthenticated: Bool
}

struct StockGitVerification: Equatable, Sendable {
    let status: String
    let command: String?
    let scope: String?
}

struct StockGitCommitContext: Equatable, Sendable {
    let diff: String
    let recentSubjects: [String]
}

struct StockGitProjectFacts: Equatable, Sendable {
    let root: String
    let kind: String?
    let verifyCommands: [String]
}

struct StockGitSnapshot: Equatable, Sendable {
    let target: StockGitProjectTarget
    let status: StockGitStatus
    let review: StockGitReview
    let branches: [StockGitBranch]
    let baseBranches: [StockGitBranch]
    let worktrees: [StockGitWorktree]
    let githubAuthentication: StockGitGitHubAuthentication
    let ship: StockGitShipState
    let pullRequests: [StockGitPullRequest]
    let commitContext: StockGitCommitContext
    let verification: StockGitVerification?
    let facts: StockGitProjectFacts?
}

struct StockGitDiff: Equatable, Sendable {
    let path: String
    let scope: StockGitReviewScope
    let isStaged: Bool
    let text: String
}

enum StockGitAction: Equatable, Sendable {
    case stage(paths: [String])
    case unstage(paths: [String])
    case revert(paths: [String])
    case commit(message: String)
    case push
    case createPullRequest
    case switchBranch(String)
    case addWorktree(name: String, branch: String, base: String?)
    case addExistingWorktree(branch: String)
    case removeWorktree(path: String, force: Bool)

    var title: String {
        switch self {
        case .stage: "Stage selected files"
        case .unstage: "Unstage selected files"
        case .revert: "Revert selected files"
        case .commit: "Commit staged changes"
        case .push: "Push current branch"
        case .createPullRequest: "Create pull request"
        case .switchBranch: "Switch branch"
        case .addWorktree, .addExistingWorktree: "Add worktree"
        case .removeWorktree: "Remove worktree"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .revert, .removeWorktree: true
        default: false
        }
    }
}

struct StockGitPreparedAction: Identifiable, Equatable, Sendable {
    let id: UUID
    let confirmationToken: String
    let target: StockGitProjectTarget
    let statusToken: String
    let action: StockGitAction
    let summary: String
}

struct StockGitActionResult: Equatable, Sendable {
    let action: StockGitAction
    let snapshot: StockGitSnapshot
    let pullRequestURL: URL?
}

@MainActor
protocol StockGitManaging: AnyObject {
    func snapshot(for target: StockGitProjectTarget, scope: StockGitReviewScope) async throws -> StockGitSnapshot
    func diff(for target: StockGitProjectTarget, file: String, scope: StockGitReviewScope, staged: Bool) async throws -> StockGitDiff
    func fileDiffAgainstHead(for target: StockGitProjectTarget, file: String) async throws -> StockGitDiff
    func prepare(_ action: StockGitAction, target: StockGitProjectTarget) throws -> StockGitPreparedAction
    func execute(_ prepared: StockGitPreparedAction, confirmationToken: String) async throws -> StockGitActionResult
}

/// Stock Hermes Git REST client. It deliberately has no command, argv, or freeform
/// route API. Every mutation is selected from `StockGitAction`, reviewed, then
/// followed by an authoritative stock status/review/worktree readback.
@MainActor
final class DirectHermesStockGitClient: StockGitManaging, ProjectGitClient {
    typealias TargetResolver = @MainActor (_ profileID: String, _ sessionID: String, _ projectID: String) -> StockGitProjectTarget?

    private enum RPCMethod: String {
        case projectFacts = "project.facts"
        case verificationStatus = "verification.status"
    }

    private enum Route: String {
        case status = "/api/git/status"
        case branches = "/api/git/branches"
        case baseBranches = "/api/git/base-branches"
        case worktrees = "/api/git/worktrees"
        case githubAuthentication = "/api/git/gh-auth"
        case reviewList = "/api/git/review/list"
        case reviewDiff = "/api/git/review/diff"
        case fileDiff = "/api/git/file-diff"
        case commitContext = "/api/git/review/commit-context"
        case revParse = "/api/git/review/rev-parse"
        case shipInfo = "/api/git/review/ship-info"
        case pullRequests = "/api/git/review/pr-list"
        case stage = "/api/git/review/stage"
        case unstage = "/api/git/review/unstage"
        case revert = "/api/git/review/revert"
        case commit = "/api/git/review/commit"
        case push = "/api/git/review/push"
        case createPullRequest = "/api/git/review/create-pr"
        case switchBranch = "/api/git/branch/switch"
        case addWorktree = "/api/git/worktree/add"
        case removeWorktree = "/api/git/worktree/remove"
    }

    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let resolveTarget: TargetResolver
    private let validateTarget: @MainActor (StockGitProjectTarget) -> Bool
    private var snapshots: [String: StockGitSnapshot] = [:]
    private var preparedActions: [UUID: StockGitPreparedAction] = [:]
    /// Linked worktrees of each registered Project's primary folder, from Hermes's own
    /// worktree list for that folder. Besides the primary folder, these are the only
    /// paths a target may name (Bighelp IDE's sessions each work in one).
    private var projectWorktrees: [String: (primary: StockGitProjectTarget, paths: Set<String>)] = [:]

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        resolveTarget: @escaping TargetResolver,
        validateTarget: @escaping @MainActor (StockGitProjectTarget) -> Bool
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
        self.resolveTarget = resolveTarget
        self.validateTarget = validateTarget
    }

    func snapshot(
        for rawTarget: StockGitProjectTarget,
        scope: StockGitReviewScope = .uncommitted
    ) async throws -> StockGitSnapshot {
        let target = try validated(rawTarget)
        let statusValue = try await get(.status, target: target)
        guard statusValue != .null else {
            throw BighelpLinkWorkspaceClientError.remote(
                status: .failed,
                code: "project_not_repository",
                message: "This Project is not a Git repository."
            )
        }
        let status = try decodeStatus(statusValue)
        let review = try decodeReview(
            try await get(.reviewList, target: target, query: [
                .init(name: "scope", value: scope.rawValue)
            ]),
            scope: scope
        )
        let branches = try decodeBranches(try await get(.branches, target: target))
        let baseBranches = try decodeBranches(try await get(.baseBranches, target: target), baseOnly: true)
        let worktrees = try decodeWorktrees(try await get(.worktrees, target: target))
        let githubAuthentication = try decodeGitHubAuthentication(try await get(
            .githubAuthentication, target: target, includesTargetPath: false
        ))
        let ship = try decodeShip(try await get(.shipInfo, target: target))
        let commitContext = try decodeCommitContext(try await get(
            .commitContext, target: target, maximumResponseBytes: 262_144
        ))
        let branchNames = Array(Set(([status.branch].compactMap { $0 }) + branches.map(\.name))).sorted()
        let pullRequests: [StockGitPullRequest]
        if branchNames.isEmpty {
            pullRequests = []
        } else {
            pullRequests = try decodePullRequests(try await post(
                .pullRequests,
                target: target,
                body: [
                    "branches": .array(branchNames.prefix(300).map(BighelpJSONValue.string)),
                    "numbers": .array([])
                ]
            ))
        }
        let facts = try? await projectFacts(target)
        let verification = try? await verificationStatus(target)
        try check(target)
        let value = StockGitSnapshot(
            target: target,
            status: status,
            review: review,
            branches: branches,
            baseBranches: baseBranches,
            worktrees: worktrees,
            githubAuthentication: githubAuthentication,
            ship: ship,
            pullRequests: pullRequests,
            commitContext: commitContext,
            verification: verification,
            facts: facts
        )
        snapshots[targetKey(target)] = value
        if validateTarget(target) {
            projectWorktrees[projectKey(target)] = (target, Set(worktrees.filter { !$0.isMain }.map(\.path)))
        }
        return value
    }

    func diff(
        for rawTarget: StockGitProjectTarget,
        file: String,
        scope: StockGitReviewScope,
        staged: Bool
    ) async throws -> StockGitDiff {
        let target = try validated(rawTarget)
        let file = try relativePath(file)
        guard let observed = snapshots[targetKey(target)],
              observed.review.files.contains(where: { $0.path == file }) else {
            throw WorkspaceClientError.conflict
        }
        let value = try await get(.reviewDiff, target: target, query: [
            .init(name: "file", value: file),
            .init(name: "scope", value: scope.rawValue),
            .init(name: "staged", value: staged ? "true" : "false")
        ], maximumResponseBytes: 524_288)
        guard let object = value.object, let text = object["diff"]?.string,
              text.utf8.count <= 524_288 else { throw WorkspaceClientError.invalidResponse }
        try check(target)
        return .init(path: file, scope: scope, isStaged: staged, text: text)
    }

    func fileDiffAgainstHead(
        for rawTarget: StockGitProjectTarget,
        file: String
    ) async throws -> StockGitDiff {
        let target = try validated(rawTarget)
        let file = try relativePath(file)
        guard let observed = snapshots[targetKey(target)],
              observed.review.files.contains(where: { $0.path == file }) else {
            throw WorkspaceClientError.conflict
        }
        let value = try await get(.fileDiff, target: target, query: [.init(name: "file", value: file)],
                                  maximumResponseBytes: 524_288)
        guard let text = value.object?["diff"]?.string, text.utf8.count <= 524_288 else {
            throw WorkspaceClientError.invalidResponse
        }
        try check(target)
        return .init(path: file, scope: .uncommitted, isStaged: false, text: text)
    }

    func prepare(_ action: StockGitAction, target rawTarget: StockGitProjectTarget) throws -> StockGitPreparedAction {
        let target = try validated(rawTarget)
        guard let snapshot = snapshots[targetKey(target)] else { throw WorkspaceClientError.conflict }
        if case .stage = action, snapshot.review.scope != .uncommitted { throw WorkspaceClientError.conflict }
        if case .unstage = action, snapshot.review.scope != .uncommitted { throw WorkspaceClientError.conflict }
        if case .revert = action, snapshot.review.scope != .uncommitted { throw WorkspaceClientError.conflict }
        let action = try validated(action, against: snapshot)
        let prepared = StockGitPreparedAction(
            id: UUID(),
            confirmationToken: UUID().uuidString.lowercased(),
            target: target,
            statusToken: snapshot.status.token,
            action: action,
            summary: summary(action, snapshot: snapshot)
        )
        preparedActions[prepared.id] = prepared
        if preparedActions.count > 12, let oldest = preparedActions.keys.first {
            preparedActions.removeValue(forKey: oldest)
        }
        return prepared
    }

    func execute(
        _ requested: StockGitPreparedAction,
        confirmationToken: String
    ) async throws -> StockGitActionResult {
        let target = try validated(requested.target)
        guard let prepared = preparedActions.removeValue(forKey: requested.id),
              prepared == requested,
              prepared.confirmationToken == confirmationToken,
              let before = snapshots[targetKey(target)],
              before.status.token == prepared.statusToken else {
            throw WorkspaceClientError.conflict
        }
        try check(target)
        var pullRequestURL: URL?
        do {
            pullRequestURL = try await perform(prepared.action, target: target)
        } catch {
            try check(target)
            if reconcilableAfterError(prepared.action, before: before),
               let reconciled = try? await snapshot(for: target, scope: before.review.scope),
               confirms(prepared.action, before: before, after: reconciled, pullRequestURL: nil) {
                return .init(action: prepared.action, snapshot: reconciled, pullRequestURL: nil)
            }
            throw error
        }
        let after = try await snapshot(for: target, scope: before.review.scope)
        guard confirms(prepared.action, before: before, after: after, pullRequestURL: pullRequestURL) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return .init(action: prepared.action, snapshot: after, pullRequestURL: pullRequestURL)
    }

    // MARK: Project Changes compatibility

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        let target = try resolvedTarget(agentID: agentID, sessionID: sessionID, workspaceID: workspaceID)
        let current = try await snapshot(for: target, scope: .uncommitted)
        return .init(
            schemaVersion: 1,
            capabilities: .init(status: true, stage: true, commit: true, push: true, fetch: false, pull: false, arbitraryCommand: false),
            workspaces: [.init(
                workspaceID: workspaceID,
                label: target.projectName,
                visibility: "private",
                operations: [.status, .stage, .commit, .push],
                remotes: ["origin"],
                branches: current.branches.map(\.name),
                mutationsEnabled: true
            )]
        )
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        let target = try resolvedTarget(agentID: agentID, sessionID: sessionID, workspaceID: workspaceID)
        return projectStatus(try await snapshot(for: target, scope: .uncommitted))
    }

    func diff(
        agentID: String,
        sessionID: String,
        workspaceID: String,
        path: String,
        side: ProjectGitDiffSide,
        statusToken: String,
        offset: Int,
        limit: Int
    ) async throws -> ProjectGitDiffPage {
        guard offset >= 0, (1...500).contains(limit) else { throw WorkspaceClientError.invalidRequest }
        let target = try resolvedTarget(agentID: agentID, sessionID: sessionID, workspaceID: workspaceID)
        guard snapshots[targetKey(target)]?.status.token == statusToken else { throw WorkspaceClientError.conflict }
        let raw = try await diff(for: target, file: path, scope: .uncommitted, staged: side == .staged)
        let all = parseDiff(raw.text)
        let end = min(all.count, offset + limit)
        guard offset <= end else { throw WorkspaceClientError.invalidRequest }
        return .init(
            path: raw.path,
            side: side,
            availability: raw.text.utf8.count >= 524_288 ? .oversized : .available,
            offset: offset,
            lines: Array(all[offset..<end]),
            nextOffset: end < all.count ? end : nil
        )
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        let target = try resolvedTarget(agentID: request.agentID, sessionID: request.sessionID, workspaceID: request.workspaceID)
        guard snapshots[targetKey(target)]?.status.token == request.statusToken else { throw WorkspaceClientError.conflict }
        let action: StockGitAction
        switch request.mutation {
        case .stage(let mode, let paths): action = mode == .stage ? .stage(paths: paths) : .unstage(paths: paths)
        case .commit(let message): action = .commit(message: message)
        case .push: action = .push
        case .fetch, .pull: throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let prepared = try prepare(action, target: target)
        return .init(
            operation: request.mutation.operation,
            confirmationToken: prepared.confirmationToken,
            operationDigest: prepared.id.uuidString.lowercased(),
            expiresAt: Date().addingTimeInterval(300),
            preview: .init(summary: prepared.summary, paths: action.paths, remote: action.remote, branch: action.branch, commits: nil)
        )
    }

    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        guard let id = UUID(uuidString: request.confirmationToken) ?? UUID(uuidString: request.idempotencyKey) else {
            throw WorkspaceClientError.invalidRequest
        }
        // ProjectChanges carries the confirmation token but not our prepared UUID.
        guard let prepared = preparedActions.values.first(where: {
            $0.confirmationToken == request.confirmationToken && $0.target.projectID == request.mutation.workspaceID
        }) else { throw WorkspaceClientError.conflict }
        _ = id // validates the caller supplied a UUID-form token/key without changing identity.
        let beforeSHA = try? await revision(prepared.target, ref: "HEAD")
        let result = try await execute(prepared, confirmationToken: request.confirmationToken)
        let status = projectStatus(result.snapshot)
        let operationResult: ProjectGitOperationResult
        switch request.mutation.mutation {
        case .stage(let mode, let paths): operationResult = .stage(mode: mode, paths: paths)
        case .commit(let message):
            let afterSHA = try await revision(prepared.target, ref: "HEAD")
            let parent = try await revision(prepared.target, ref: "HEAD^") ?? beforeSHA ?? afterSHA ?? ""
            let tree = try await revision(prepared.target, ref: "HEAD^{tree}") ?? afterSHA ?? ""
            guard let afterSHA else { throw WorkspaceClientError.invalidResponse }
            operationResult = .commit(commitOID: afterSHA, parentOID: parent, treeOID: tree, subject: message)
        case .push:
            guard let sha = try await revision(prepared.target, ref: "HEAD") else { throw WorkspaceClientError.invalidResponse }
            operationResult = .push(remote: "origin", branch: result.snapshot.status.branch ?? "HEAD", commitOID: sha)
        case .fetch, .pull:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        return .init(
            operationID: UUID().uuidString.lowercased(),
            workspaceID: request.mutation.workspaceID,
            operation: request.mutation.mutation.operation,
            result: operationResult,
            status: status
        )
    }

    // MARK: Fixed routes

    private func get(
        _ route: Route,
        target: StockGitProjectTarget,
        query: [URLQueryItem] = [],
        includesTargetPath: Bool = true,
        maximumResponseBytes: Int = DirectHermesWire.maximumMessageBytes
    ) async throws -> BighelpJSONValue {
        try check(target)
        let value = try await http.request(.init(
            path: route.rawValue,
            method: .get,
            query: (includesTargetPath ? [.init(name: "path", value: target.cwd)] : []) + query,
            maximumResponseBytes: maximumResponseBytes
        ))
        try check(target)
        return value
    }

    private func post(
        _ route: Route,
        target: StockGitProjectTarget,
        body: [String: BighelpJSONValue] = [:]
    ) async throws -> BighelpJSONValue {
        try check(target)
        var body = body
        body["path"] = .string(target.cwd)
        let value = try await http.request(.init(path: route.rawValue, method: .post, body: body))
        try check(target)
        return value
    }

    private func perform(_ action: StockGitAction, target: StockGitProjectTarget) async throws -> URL? {
        switch action {
        case .stage(let paths):
            for path in paths { try requireOK(try await post(.stage, target: target, body: ["file": .string(path)])) }
        case .unstage(let paths):
            for path in paths { try requireOK(try await post(.unstage, target: target, body: ["file": .string(path)])) }
        case .revert(let paths):
            for path in paths { try requireOK(try await post(.revert, target: target, body: ["file": .string(path)])) }
        case .commit(let message):
            try requireOK(try await post(.commit, target: target, body: [
                "message": .string(message), "push": .boolean(false)
            ]))
        case .push:
            try requireOK(try await post(.push, target: target))
        case .createPullRequest:
            let value = try await post(.createPullRequest, target: target)
            guard let raw = value.object?["url"]?.string, let url = validPullRequestURL(raw) else {
                throw WorkspaceClientError.invalidResponse
            }
            return url
        case .switchBranch(let branch):
            let value = try await post(.switchBranch, target: target, body: ["branch": .string(branch)])
            guard value.object?["branch"]?.string == branch else { throw WorkspaceClientError.invalidResponse }
        case .addWorktree(let name, let branch, let base):
            var body: [String: BighelpJSONValue] = ["name": .string(name), "branch": .string(branch)]
            if let base { body["base"] = .string(base) }
            _ = try decodeAddedWorktree(try await post(.addWorktree, target: target, body: body))
        case .addExistingWorktree(let branch):
            _ = try decodeAddedWorktree(try await post(.addWorktree, target: target, body: ["existingBranch": .string(branch)]))
        case .removeWorktree(let path, let force):
            let value = try await post(.removeWorktree, target: target, body: [
                "worktreePath": .string(path), "force": .boolean(force)
            ])
            guard value.object?["removed"]?.string == path else { throw WorkspaceClientError.invalidResponse }
        }
        return nil
    }

    private func projectFacts(_ target: StockGitProjectTarget) async throws -> StockGitProjectFacts? {
        let value = try await rpc.request(RPCMethod.projectFacts.rawValue, params: ["cwd": .string(target.cwd)])
        try check(target)
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        if object["facts"] == .null { return nil }
        guard let facts = object["facts"]?.object,
              let root = facts["root"]?.string,
              try absoluteHostPath(root) == target.cwd || contains(root: try absoluteHostPath(root), path: target.cwd) else {
            throw WorkspaceClientError.invalidResponse
        }
        let commands = try stringArray(facts["verifyCommands"], maximum: 20, itemMaximum: 2_000)
        return .init(root: root, kind: try optionalText(facts["kind"], maximum: 80), verifyCommands: commands)
    }

    private func verificationStatus(_ target: StockGitProjectTarget) async throws -> StockGitVerification? {
        let value = try await rpc.request(RPCMethod.verificationStatus.rawValue, params: [
            "profile": .string(target.profileID), "cwd": .string(target.cwd)
        ])
        try check(target)
        guard let root = value.object, let verification = root["verification"]?.object,
              let status = verification["status"]?.string, status.utf8.count <= 40 else {
            throw WorkspaceClientError.invalidResponse
        }
        let evidence = verification["evidence"]?.object
        return .init(
            status: status,
            command: try optionalText(evidence?["canonical_command"] ?? evidence?["command"], maximum: 2_000),
            scope: try optionalText(evidence?["scope"], maximum: 40)
        )
    }

    private func revision(_ target: StockGitProjectTarget, ref: String) async throws -> String? {
        let value = try await get(.revParse, target: target, query: [.init(name: "ref", value: ref)])
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        if object["sha"] == .null { return nil }
        guard let sha = object["sha"]?.string, [40, 64].contains(sha.count), sha.allSatisfy({ $0.isHexDigit }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return sha.lowercased()
    }

    // MARK: Ownership and validation

    private func resolvedTarget(agentID: String, sessionID: String, workspaceID: String) throws -> StockGitProjectTarget {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let project = try DirectHermesCoreRequestScope.identifier(workspaceID)
        guard !sessionID.isEmpty, sessionID.utf8.count <= 512,
              let target = resolveTarget(profile, sessionID, project) else {
            throw WorkspaceClientError.unavailable(.identityContextUnavailable)
        }
        return try validated(target)
    }

    private func validated(_ target: StockGitProjectTarget) throws -> StockGitProjectTarget {
        try checkOwner()
        let profile = try DirectHermesCoreRequestScope.profile(target.profileID)
        let project = try DirectHermesCoreRequestScope.identifier(target.projectID)
        let cwd = try absoluteHostPath(target.cwd)
        let name = try text(target.projectName, maximum: 200)
        guard profile == target.profileID, project == target.projectID, cwd == target.cwd, name == target.projectName else {
            throw WorkspaceClientError.invalidRequest
        }
        guard validateTarget(target) || isProjectWorktree(target) else { throw WorkspaceClientError.ownerChanged }
        return target
    }

    /// A linked worktree the Project's primary folder listed in its latest snapshot,
    /// while that primary folder is still the Project's.
    private func isProjectWorktree(_ target: StockGitProjectTarget) -> Bool {
        guard let known = projectWorktrees[projectKey(target)],
              known.primary.projectName == target.projectName,
              known.paths.contains(target.cwd) else { return false }
        return validateTarget(known.primary)
    }

    private func check(_ target: StockGitProjectTarget) throws {
        try checkOwner()
        guard let known = snapshots[targetKey(target)]?.target else { return }
        guard known == target else {
            snapshots.removeAll()
            preparedActions.removeAll()
            throw WorkspaceClientError.ownerChanged
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard owner.authority.kind == .direct, currentOwner() == owner else {
            snapshots.removeAll()
            preparedActions.removeAll()
            projectWorktrees.removeAll()
            throw WorkspaceClientError.ownerChanged
        }
    }

    private func projectKey(_ target: StockGitProjectTarget) -> String {
        [target.profileID, target.projectID].joined(separator: "\u{0}")
    }

    private func targetKey(_ target: StockGitProjectTarget) -> String {
        [target.profileID, target.projectID, target.cwd].joined(separator: "\u{0}")
    }

    private func validated(_ action: StockGitAction, against snapshot: StockGitSnapshot) throws -> StockGitAction {
        switch action {
        case .stage(let paths):
            let paths = try selected(paths, in: snapshot) { path in
                guard let review = snapshot.review.files.first(where: { $0.path == path }) else { return false }
                return !review.isStaged || snapshot.status.files.first(where: { $0.path == path })?.isUnstaged == true
            }
            return .stage(paths: paths)
        case .unstage(let paths):
            return .unstage(paths: try selected(paths, in: snapshot) { path in
                snapshot.review.files.first(where: { $0.path == path })?.isStaged == true
            })
        case .revert(let paths):
            return .revert(paths: try selected(paths, in: snapshot) { _ in true })
        case .commit(let raw):
            let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty, message.utf8.count <= 10_000,
                  !message.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }),
                  snapshot.review.files.contains(where: \.isStaged) else { throw WorkspaceClientError.invalidRequest }
            return .commit(message: message)
        case .push:
            guard snapshot.status.branch != nil, !snapshot.status.isDetached else { throw WorkspaceClientError.conflict }
            return .push
        case .createPullRequest:
            guard snapshot.ship.isGitHubCLIReady, snapshot.status.branch != nil,
                  snapshot.ship.currentPullRequest == nil else { throw WorkspaceClientError.conflict }
            return .createPullRequest
        case .switchBranch(let raw):
            let branch = try refName(raw)
            guard snapshot.branches.contains(where: { $0.name == branch && !$0.isCheckedOut }) else {
                throw WorkspaceClientError.conflict
            }
            return .switchBranch(branch)
        case .addWorktree(let rawName, let rawBranch, let rawBase):
            let name = try worktreeName(rawName)
            let branch = try refName(rawBranch)
            let base = try rawBase.map { try refName($0) }
            guard !snapshot.branches.contains(where: { $0.name == branch }),
                  base == nil || snapshot.baseBranches.contains(where: { $0.name == base }) else {
                throw WorkspaceClientError.conflict
            }
            return .addWorktree(name: name, branch: branch, base: base)
        case .addExistingWorktree(let raw):
            let branch = try refName(raw)
            guard snapshot.branches.contains(where: { $0.name == branch && !$0.isCheckedOut }) else {
                throw WorkspaceClientError.conflict
            }
            return .addExistingWorktree(branch: branch)
        case .removeWorktree(let path, let force):
            guard let worktree = snapshot.worktrees.first(where: { $0.path == path }),
                  !worktree.isMain, !worktree.isLocked else { throw WorkspaceClientError.conflict }
            return .removeWorktree(path: try absoluteHostPath(path), force: force)
        }
    }

    private func selected(
        _ raw: [String],
        in snapshot: StockGitSnapshot,
        where eligible: (String) -> Bool
    ) throws -> [String] {
        guard !raw.isEmpty, raw.count <= 200 else { throw WorkspaceClientError.invalidRequest }
        let paths = try raw.map(relativePath)
        guard Set(paths).count == paths.count,
              paths.allSatisfy({ path in
                  snapshot.review.files.contains { $0.path == path } && eligible(path)
              }) else {
            throw WorkspaceClientError.conflict
        }
        return paths
    }

    private func confirms(
        _ action: StockGitAction,
        before: StockGitSnapshot,
        after: StockGitSnapshot,
        pullRequestURL: URL?
    ) -> Bool {
        switch action {
        case .stage(let paths): return paths.allSatisfy { path in after.review.files.first(where: { $0.path == path })?.isStaged == true }
        case .unstage(let paths): return paths.allSatisfy { path in after.review.files.first(where: { $0.path == path })?.isStaged != true }
        case .revert(let paths): return paths.allSatisfy { path in !after.review.files.contains(where: { $0.path == path }) }
        case .commit: return before.status.token != after.status.token && after.status.files.filter(\.isStaged).isEmpty
        case .push: return after.status.ahead == 0 || after.status.token != before.status.token
        case .createPullRequest:
            return pullRequestURL != nil && (after.ship.currentPullRequest != nil || after.pullRequests.contains { $0.url == pullRequestURL })
        case .switchBranch(let branch): return after.status.branch == branch
        case .addWorktree(_, let branch, _), .addExistingWorktree(let branch):
            return after.worktrees.contains { $0.branch == branch }
        case .removeWorktree(let path, _): return !after.worktrees.contains { $0.path == path }
        }
    }

    private func reconcilableAfterError(_ action: StockGitAction, before: StockGitSnapshot) -> Bool {
        switch action {
        case .push:
            return before.status.ahead > 0
        case .stage, .unstage, .revert, .commit, .createPullRequest, .switchBranch,
             .addWorktree, .addExistingWorktree, .removeWorktree:
            return true
        }
    }

    // MARK: Decoding

    private func decodeStatus(_ value: BighelpJSONValue) throws -> StockGitStatus {
        guard let row = value.object,
              let detached = row["detached"]?.boolean,
              let ahead = count(row["ahead"]), let behind = count(row["behind"]),
              let changed = count(row["changed"]), let added = count(row["added"]), let removed = count(row["removed"]),
              let rawFiles = row["files"]?.array, rawFiles.count <= 200 else { throw WorkspaceClientError.invalidResponse }
        let branch = try optionalText(row["branch"], maximum: 300)
        let files = try rawFiles.map { raw -> StockGitFileState in
            guard let file = raw.object,
                  let staged = file["staged"]?.boolean,
                  let unstaged = file["unstaged"]?.boolean,
                  let untracked = file["untracked"]?.boolean,
                  let conflicted = file["conflicted"]?.boolean else { throw WorkspaceClientError.invalidResponse }
            return .init(path: try relativePath(textValue(file["path"], maximum: 4_096)), isStaged: staged, isUnstaged: unstaged, isUntracked: untracked, isConflicted: conflicted)
        }
        guard Set(files.map(\.path)).count == files.count, changed >= files.count,
              detached == (branch == nil) else { throw WorkspaceClientError.invalidResponse }
        let seed = ([branch ?? "", String(detached), String(ahead), String(behind), String(changed), String(added), String(removed)]
            + files.flatMap { [$0.path, String($0.isStaged), String($0.isUnstaged), String($0.isUntracked), String($0.isConflicted)] })
            .joined(separator: "\u{0}")
        let token = "sha256:" + SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(branch: branch, defaultBranch: try optionalText(row["defaultBranch"], maximum: 300), isDetached: detached, ahead: ahead, behind: behind, changed: changed, added: added, removed: removed, files: files, token: token)
    }

    private func decodeReview(_ value: BighelpJSONValue, scope: StockGitReviewScope) throws -> StockGitReview {
        guard let row = value.object, let rawFiles = row["files"]?.array, rawFiles.count <= 500 else {
            throw WorkspaceClientError.invalidResponse
        }
        let files = try rawFiles.map { raw -> StockGitReviewFile in
            guard let file = raw.object, let added = count(file["added"]), let removed = count(file["removed"]),
                  let staged = file["staged"]?.boolean else { throw WorkspaceClientError.invalidResponse }
            let status = try textValue(file["status"], maximum: 4)
            guard status.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0.unicodeScalars.first!) }) else {
                throw WorkspaceClientError.invalidResponse
            }
            return .init(path: try relativePath(textValue(file["path"], maximum: 4_096)), added: added, removed: removed, status: status, isStaged: staged)
        }
        guard Set(files.map(\.path)).count == files.count else { throw WorkspaceClientError.invalidResponse }
        return .init(scope: scope, base: try optionalText(row["base"], maximum: 512), files: files)
    }

    private func decodeBranches(_ value: BighelpJSONValue, baseOnly: Bool = false) throws -> [StockGitBranch] {
        guard let rows = value.object?["branches"]?.array, rows.count <= 600 else { throw WorkspaceClientError.invalidResponse }
        let branches = try rows.map { raw -> StockGitBranch in
            guard let row = raw.object, let isDefault = row["isDefault"]?.boolean,
                  let remote = row["isRemote"]?.boolean else { throw WorkspaceClientError.invalidResponse }
            let name = try refName(textValue(row["name"], maximum: 300))
            let checked = baseOnly ? false : (row["checkedOut"]?.boolean ?? false)
            return .init(name: name, isCheckedOut: checked, isDefault: isDefault, isRemote: remote, worktreePath: try optionalHostPath(row["worktreePath"]))
        }
        guard Set(branches.map(\.name)).count == branches.count else { throw WorkspaceClientError.invalidResponse }
        return branches
    }

    private func decodeWorktrees(_ value: BighelpJSONValue) throws -> [StockGitWorktree] {
        guard let rows = value.object?["worktrees"]?.array, rows.count <= 200 else { throw WorkspaceClientError.invalidResponse }
        let worktrees = try rows.map { raw -> StockGitWorktree in
            guard let row = raw.object, let main = row["isMain"]?.boolean,
                  let detached = row["detached"]?.boolean, let locked = row["locked"]?.boolean else {
                throw WorkspaceClientError.invalidResponse
            }
            return .init(path: try absoluteHostPath(textValue(row["path"], maximum: 4_096)), branch: try optionalText(row["branch"], maximum: 300), isMain: main, isDetached: detached, isLocked: locked)
        }
        guard Set(worktrees.map(\.path)).count == worktrees.count, worktrees.filter(\.isMain).count <= 1 else {
            throw WorkspaceClientError.invalidResponse
        }
        return worktrees
    }

    private func decodeGitHubAuthentication(_ value: BighelpJSONValue) throws -> StockGitGitHubAuthentication {
        guard let row = value.object,
              let available = row["available"]?.boolean,
              let authenticated = row["authenticated"]?.boolean,
              available || !authenticated else { throw WorkspaceClientError.invalidResponse }
        return .init(isAvailable: available, isAuthenticated: authenticated)
    }

    private func decodeShip(_ value: BighelpJSONValue) throws -> StockGitShipState {
        guard let row = value.object, let ready = row["ghReady"]?.boolean else { throw WorkspaceClientError.invalidResponse }
        let pullRequest: StockGitPullRequest?
        if row["pr"] == .null { pullRequest = nil }
        else if let pr = row["pr"]?.object {
            guard let number = count(pr["number"], maximum: 100_000_000),
                  let url = try validPullRequestURL(textValue(pr["url"], maximum: 2_048)) else {
                throw WorkspaceClientError.invalidResponse
            }
            pullRequest = .init(number: number, branch: "", title: "", url: url, state: try optionalText(pr["state"], maximum: 40) ?? "unknown", isDraft: false)
        } else { throw WorkspaceClientError.invalidResponse }
        guard ready || pullRequest == nil else { throw WorkspaceClientError.invalidResponse }
        return .init(isGitHubCLIReady: ready, currentPullRequest: pullRequest)
    }

    private func decodePullRequests(_ value: BighelpJSONValue) throws -> [StockGitPullRequest] {
        guard let object = value.object, let ready = object["ghReady"]?.boolean,
              let rows = object["prs"]?.array, rows.count <= 600 else { throw WorkspaceClientError.invalidResponse }
        guard ready || rows.isEmpty else { throw WorkspaceClientError.invalidResponse }
        let values = try rows.map { raw -> StockGitPullRequest in
            guard let row = raw.object, let number = count(row["number"], maximum: 100_000_000),
                  let draft = row["draft"]?.boolean,
                  let url = try validPullRequestURL(textValue(row["url"], maximum: 2_048)) else {
                throw WorkspaceClientError.invalidResponse
            }
            return .init(number: number, branch: try refName(textValue(row["branch"], maximum: 300)), title: try textValue(row["title"], maximum: 2_000, allowsEmpty: true), url: url, state: try textValue(row["state"], maximum: 40), isDraft: draft)
        }
        guard Set(values.map(\.number)).count == values.count else { throw WorkspaceClientError.invalidResponse }
        return values
    }

    private func decodeCommitContext(_ value: BighelpJSONValue) throws -> StockGitCommitContext {
        guard let row = value.object,
              let diff = row["diff"]?.string, diff.utf8.count <= 140_000,
              let recent = row["recent"]?.string, recent.utf8.count <= 20_000 else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            diff: diff,
            recentSubjects: recent.split(separator: "\n").prefix(10).map(String.init)
        )
    }

    private func decodeAddedWorktree(_ value: BighelpJSONValue) throws -> StockGitWorktree {
        guard let row = value.object else { throw WorkspaceClientError.invalidResponse }
        return .init(path: try absoluteHostPath(textValue(row["path"], maximum: 4_096)), branch: try optionalText(row["branch"], maximum: 300), isMain: false, isDetached: false, isLocked: false)
    }

    private func requireOK(_ value: BighelpJSONValue) throws {
        guard value.object?["ok"]?.boolean == true else { throw WorkspaceClientError.invalidResponse }
    }

    private func projectStatus(_ snapshot: StockGitSnapshot) -> ProjectGitStatus {
        let reviews = Dictionary(uniqueKeysWithValues: snapshot.review.files.map { ($0.path, $0) })
        let files = snapshot.status.files.map { file -> ProjectGitFileChange in
            let review = reviews[file.path]
            let kind: ProjectGitFileKind = file.isConflicted ? .unmerged : (file.isUntracked ? .untracked : .ordinary)
            return .init(
                path: file.path,
                originalPath: nil,
                indexStatus: file.isStaged ? (review?.status ?? "M") : ".",
                worktreeStatus: file.isUntracked ? "?" : (file.isUnstaged || file.isConflicted ? (review?.status ?? "M") : "."),
                kind: kind,
                insertions: review?.added ?? 0,
                deletions: review?.removed ?? 0,
                isBinary: false
            )
        }
        let stagedFiles = files.filter { $0.indexStatus != "." }
        let page = ProjectGitPageMetadata(
            offset: 0,
            limit: max(files.count, 1),
            returned: files.count,
            total: snapshot.status.changed,
            nextOffset: nil,
            isComplete: files.count == snapshot.status.changed
        )
        return .init(
            workspaceID: snapshot.target.projectID,
            statusToken: snapshot.status.token,
            head: .init(oid: nil, branch: snapshot.status.branch, isDetached: snapshot.status.isDetached, upstream: nil, ahead: snapshot.status.ahead, behind: snapshot.status.behind),
            files: files,
            filesPage: page,
            staged: .init(files: stagedFiles.count, insertions: stagedFiles.reduce(0) { $0 + $1.insertions }, deletions: stagedFiles.reduce(0) { $0 + $1.deletions }),
            changes: .init(files: snapshot.status.changed, insertions: snapshot.status.added, deletions: snapshot.status.removed),
            conflicts: snapshot.status.files.filter(\.isConflicted).map(\.path),
            conflictsPage: .init(offset: 0, limit: max(files.count, 1), returned: snapshot.status.files.filter(\.isConflicted).count, total: snapshot.status.files.filter(\.isConflicted).count, nextOffset: nil, isComplete: true),
            isDirty: snapshot.status.changed > 0
        )
    }

    private func parseDiff(_ text: String) -> [ProjectGitDiffLine] {
        var oldLine: Int?
        var newLine: Int?
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { offset, raw in
            let line = String(raw)
            let kind: ProjectGitDiffLineKind
            let content: String
            let old: Int?
            let new: Int?
            if line.hasPrefix("@@") {
                kind = .hunk; content = line; old = nil; new = nil
                let fields = line.split(separator: " ")
                oldLine = fields.first(where: { $0.hasPrefix("-") }).flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") }
                newLine = fields.first(where: { $0.hasPrefix("+") }).flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") }
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                kind = .header; content = line; old = nil; new = nil
            } else if line.hasPrefix("+") {
                kind = .addition; content = String(line.dropFirst()); old = nil; new = newLine; newLine = newLine.map { $0 + 1 }
            } else if line.hasPrefix("-") {
                kind = .deletion; content = String(line.dropFirst()); old = oldLine; new = nil; oldLine = oldLine.map { $0 + 1 }
            } else if line.hasPrefix("\\ No newline") {
                kind = .noNewline; content = line; old = nil; new = nil
            } else {
                kind = .context; content = line.hasPrefix(" ") ? String(line.dropFirst()) : line; old = oldLine; new = newLine
                oldLine = oldLine.map { $0 + 1 }; newLine = newLine.map { $0 + 1 }
            }
            return .init(offset: offset, kind: kind, oldLine: old, newLine: new, content: content)
        }
    }

    private func summary(_ action: StockGitAction, snapshot: StockGitSnapshot) -> String {
        switch action {
        case .stage(let paths): "Stage \(paths.count) selected file\(paths.count == 1 ? "" : "s") in \(snapshot.target.projectName)."
        case .unstage(let paths): "Unstage \(paths.count) selected file\(paths.count == 1 ? "" : "s") without discarding their contents."
        case .revert(let paths): "Permanently discard the selected changes in \(paths.count) file\(paths.count == 1 ? "" : "s")."
        case .commit(let message): "Create one local commit from the staged changes: \(message)"
        case .push: "Push \(snapshot.status.branch ?? "the current branch") to its configured upstream."
        case .createPullRequest: "Push the current branch if needed, then ask GitHub CLI to create a pull request from the repository defaults."
        case .switchBranch(let branch): "Switch this checkout to \(branch)."
        case .addWorktree(_, let branch, let base): "Create worktree branch \(branch)\(base.map { " from \($0)" } ?? "")."
        case .addExistingWorktree(let branch): "Check out existing branch \(branch) in a separate worktree."
        case .removeWorktree(let path, let force): "Remove \(path) from this repository\(force ? ", including uncommitted work" : "")."
        }
    }

    private func text(_ value: String, maximum: Int) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private func textValue(_ value: BighelpJSONValue?, maximum: Int, allowsEmpty: Bool = false) throws -> String {
        guard let value = value?.string, value.utf8.count <= maximum,
              allowsEmpty || !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else { throw WorkspaceClientError.invalidResponse }
        return value
    }

    private func optionalText(_ value: BighelpJSONValue?, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        return try textValue(value, maximum: maximum, allowsEmpty: true)
    }

    private func stringArray(_ value: BighelpJSONValue?, maximum: Int, itemMaximum: Int) throws -> [String] {
        guard let rows = value?.array, rows.count <= maximum else { return [] }
        return try rows.map { try textValue($0, maximum: itemMaximum, allowsEmpty: false) }
    }

    private func count(_ value: BighelpJSONValue?, maximum: Int = 100_000_000) -> Int? {
        guard let value = value?.integer, (0...maximum).contains(value) else { return nil }
        return value
    }

    private func relativePath(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.hasPrefix("/"), !value.hasPrefix("-"),
              !value.contains("\\"), !value.contains("://"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidRequest
        }
        // Git names an untracked folder with one trailing "/" (`.worktrees/`, beside every worktree).
        let body = value.hasSuffix("/") ? value.dropLast() : Substring(value)
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private func absoluteHostPath(_ value: String) throws -> String {
        let isPOSIX = value.hasPrefix("/") && !value.hasPrefix("//")
        let isWindowsDrive = value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
        let isUNC = value.hasPrefix("\\\\")
        guard value.utf8.count <= 4_096, isPOSIX || isWindowsDrive || isUNC,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains(where: { $0 == "." || $0 == ".." }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private func optionalHostPath(_ value: BighelpJSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        return try absoluteHostPath(textValue(value, maximum: 4_096))
    }

    private func contains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") || root.hasSuffix("\\") ? root : root + (root.contains("\\") ? "\\" : "/"))
    }

    private func refName(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 300, !value.hasPrefix("-"), !value.hasPrefix("/"),
              !value.hasSuffix("/"), !value.hasSuffix("."), !value.contains(".."),
              !value.contains(":"), !value.contains("\\"), !value.contains(where: \.isWhitespace),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private func worktreeName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 80,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " ._-".contains($0)) }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return trimmed
    }

    private func validPullRequestURL(_ value: String) -> URL? {
        guard value.utf8.count <= 2_048, let url = URL(string: value), url.scheme == "https",
              url.host?.lowercased() == "github.com",
              url.path.range(of: #"^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*/*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return url
    }
}

private extension StockGitAction {
    var paths: [String] {
        switch self {
        case .stage(let paths), .unstage(let paths), .revert(let paths): paths
        default: []
        }
    }

    var remote: String? {
        switch self {
        case .push, .createPullRequest: "origin"
        default: nil
        }
    }

    var branch: String? {
        switch self {
        case .switchBranch(let branch), .addExistingWorktree(let branch): branch
        case .addWorktree(_, let branch, _): branch
        default: nil
        }
    }
}
