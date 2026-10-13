import Foundation

/// Starts Hermes sessions and sends their first message without opening them.
@MainActor
protocol CodeSessionStarting {
    /// A new chat with `agentID` working in exactly `folder`, on `runtime`'s model choices; returns its session ID.
    func startSession(agentID: String, folder: String, title: String, runtime: CodeRuntimeChoice) async throws -> String
    /// Applies `mode`'s session settings (YOLO) before the first message.
    func apply(_ mode: CodeSessionMode, toSession sessionID: String, agentID: String) async throws
    /// Sends `message` as the next turn. A leading slash command runs as a command.
    func send(_ message: String, toSession sessionID: String) async throws
}

/// What one Send in Bighelp IDE asks for.
struct CodeLaunchRequest: Equatable, Sendable {
    let message: String
    let agentID: String
    let project: CodeProject
    let placement: CodePlacement
    /// New worktree: the branch it starts from (nil is the repository's default).
    /// Local: the branch to have checked out (nil keeps the current one).
    let branch: String?
    /// New worktree: the new branch's name; nil names it from the message.
    let newBranch: String?
    var runtime = CodeRuntimeChoice()
    var mode = CodeSessionMode.standard

    /// What the session gets as its first message: Plan mode makes it `/plan …`.
    var firstMessage: String { mode.firstMessage(message) }
}

enum CodeLaunchError: LocalizedError, Equatable {
    case branchExists(String)
    case worktreeNotFound

    var errorDescription: String? {
        switch self {
        case .branchExists(let name): "A branch named \(name) already exists. Pick another name."
        case .worktreeNotFound: "The worktree wasn't confirmed. Check Worktrees, then try again."
        }
    }
}

/// One Send: (1) make the worktree, or switch the local checkout's branch, with the
/// host's own git routes, (2) start a session in that folder on the chosen model,
/// (3) apply the mode and send the message. The session exists as soon as step 2
/// returns, so a failed send still leaves a session to open (`onSessionStarted`). `CodeHomeStore` runs
/// steps 1 and 2 of back-to-back sends one at a time (`start`): Hermes starts one new
/// chat per agent at a time, and a worktree changes the repository the next one reads.
@MainActor
struct CodeLauncher {
    let git: any StockGitManaging
    let sessions: any CodeSessionStarting

    func launch(
        _ request: CodeLaunchRequest,
        progress: (CodeLaunch.Step) -> Void,
        onSessionStarted: (CodeSessionRecord) -> Void
    ) async throws -> CodeSessionRecord {
        let record = try await start(request, progress: progress)
        onSessionStarted(record)
        progress(.sending)
        try await sessions.apply(request.mode, toSession: record.id, agentID: request.agentID)
        try await sessions.send(request.firstMessage, toSession: record.id)
        return record
    }

    /// Steps 1 and 2: the folder, then the session in it.
    func start(_ request: CodeLaunchRequest, progress: (CodeLaunch.Step) -> Void) async throws -> CodeSessionRecord {
        let main = StockGitProjectTarget(profileID: request.agentID, projectID: request.project.id,
                                         cwd: request.project.folder, projectName: request.project.name)
        let folder: String
        let branch: String?
        switch request.placement {
        case .newWorktree:
            progress(.makingWorktree)
            let worktree = try await makeWorktree(request, main: main)
            folder = worktree.folder
            branch = worktree.branch
        case .local:
            branch = try await checkOut(request.branch, in: main, progress: progress)
            folder = request.project.folder
        }
        progress(.startingSession)
        let title = CodeSessionTitle.from(request.message)
        let sessionID = try await sessions.startSession(agentID: request.agentID, folder: folder, title: title,
                                                        runtime: request.runtime)
        return CodeSessionRecord(id: sessionID, agentID: request.agentID, projectID: request.project.id,
                                 projectName: request.project.name, title: title, folder: folder,
                                 branch: branch, placement: request.placement, startedAt: .now, mode: request.mode)
    }

    private func makeWorktree(_ request: CodeLaunchRequest,
                              main: StockGitProjectTarget) async throws -> (folder: String, branch: String) {
        let snapshot = try await git.snapshot(for: main, scope: .uncommitted)
        let taken = Set(snapshot.branches.filter { !$0.isRemote }.map(\.name))
        let branch: String
        if let chosen = request.newBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty {
            guard !taken.contains(chosen) else { throw CodeLaunchError.branchExists(chosen) }
            branch = chosen
        } else {
            branch = CodeBranchName.suggested(for: CodeSessionTitle.withoutCommand(request.message), taken: taken)
        }
        let base = request.branch.flatMap { name in snapshot.baseBranches.contains { $0.name == name } ? name : nil }
        let prepared = try git.prepare(.addWorktree(name: CodeBranchName.worktreeName(for: branch), branch: branch,
                                                    base: base), target: main)
        let result = try await git.execute(prepared, confirmationToken: prepared.confirmationToken)
        guard let worktree = result.snapshot.worktrees.first(where: { $0.branch == branch }) else {
            throw CodeLaunchError.worktreeNotFound
        }
        return (worktree.path, branch)
    }

    /// Switches the main folder to `branch` when it isn't checked out already.
    private func checkOut(_ branch: String?, in main: StockGitProjectTarget,
                          progress: (CodeLaunch.Step) -> Void) async throws -> String? {
        let snapshot = try await git.snapshot(for: main, scope: .uncommitted)
        guard let branch, branch != snapshot.status.branch else { return snapshot.status.branch }
        progress(.switchingBranch)
        let prepared = try git.prepare(.switchBranch(branch), target: main)
        let result = try await git.execute(prepared, confirmationToken: prepared.confirmationToken)
        return result.snapshot.status.branch
    }
}

/// Hermes sessions through the app's own session list and chat models: the same
/// path Shortcuts takes, so nothing opens on screen.
@MainActor
struct CodeChatSessionStarter: CodeSessionStarting {
    let catalog: SessionCatalogStore
    let features: ShellFeatureStore

    func startSession(agentID: String, folder: String, title: String, runtime: CodeRuntimeChoice) async throws -> String {
        let start = SessionStartRuntime(provider: runtime.modelID == nil ? nil : runtime.providerID, model: runtime.modelID,
                                        reasoningEffort: runtime.reasoning, fast: runtime.fastMode)
        return try await catalog.createDirect(agentID: agentID, folder: folder, title: title, runtime: start).id
    }

    func apply(_ mode: CodeSessionMode, toSession sessionID: String, agentID: String) async throws {
        guard mode == .yolo else { return }
        // Demo chats have no Hermes settings; their sample replies need no approvals.
        guard features.hasNativeSessionControls else { return }
        do {
            // The session's chat attaches it to the live connection first, as a send does.
            let chat = try BighelpShortcutWorkspace.chatModel(sessionID: sessionID, in: features)
            try await BighelpShortcutService.awaitTransportReady(chat)
            try await features.setSessionYOLO(true, sessionID: sessionID, agentID: agentID)
        } catch {
            NSLog("bighelp: YOLO for a new IDE session failed: %@", String(describing: error))
            throw CodeStartError.yoloRefused
        }
    }

    func send(_ message: String, toSession sessionID: String) async throws {
        let chat = try BighelpShortcutWorkspace.chatModel(sessionID: sessionID, in: features)
        try await BighelpShortcutService.awaitTransportReady(chat)
        if chat.nativeConversationClient != nil, !message.hasPrefix("/") {
            try await chat.submitWithoutWaiting(message: message, attachments: [])
        } else {
            // A slash command takes the message box's own path, which runs it as a
            // command (`/plan` expands to its planning prompt there). Demo chats have no
            // host queue either: they play their sample reply in place.
            await chat.slashCommandCatalog?.loadIfNeeded(for: message)
            chat.draft = message
            Task { await chat.send() }
        }
    }
}

enum CodeStartError: LocalizedError, Equatable {
    case yoloRefused

    var errorDescription: String? {
        switch self {
        case .yoloRefused: "Hermes didn't turn on YOLO for this session, so nothing was sent. Open it to try again."
        }
    }
}
