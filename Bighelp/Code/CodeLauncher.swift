import Foundation

/// Starts Hermes sessions and sends their first message without opening them.
@MainActor
protocol CodeSessionStarting {
    /// A new chat with `agentID` working in exactly `folder`, on `runtime`'s model choices; returns its session ID.
    func startSession(agentID: String, folder: String, title: String, runtime: CodeRuntimeChoice,
                      creationID: UUID) async throws -> String
    /// Applies `mode`'s session settings (YOLO) before the first message.
    func apply(_ mode: CodeSessionMode, toSession sessionID: String, agentID: String) async throws
    /// Sends `message` as the next turn. A leading slash command runs as a command.
    func send(_ message: String, toSession sessionID: String, submissionID: UUID) async throws
    /// Reconciles a create whose reply was lost from the authoritative session list.
    func existingSession(for request: CodeLaunchRequest, at destination: CodeLaunchDestination,
                         requestedAt: Date) async throws -> CodeSessionRecord?
    /// Reconciles one exact local send identity from the chat's durable journal or acknowledged row.
    func deliveryEvidence(for submissionID: UUID, message: String,
                          sessionID: String) async throws -> CodeLaunchDeliveryEvidence
}

enum CodeLaunchDeliveryEvidence: Equatable, Sendable {
    case sent
    case unsent(String)
    case unknown(String)
}

extension CodeSessionStarting {
    func startSession(agentID: String, folder: String, title: String,
                      runtime: CodeRuntimeChoice) async throws -> String {
        try await startSession(agentID: agentID, folder: folder, title: title,
                               runtime: runtime, creationID: UUID())
    }

    func send(_ message: String, toSession sessionID: String) async throws {
        try await send(message, toSession: sessionID, submissionID: UUID())
    }

    func existingSession(for request: CodeLaunchRequest, at destination: CodeLaunchDestination,
                         requestedAt: Date) async throws -> CodeSessionRecord? { nil }

    func deliveryEvidence(for submissionID: UUID, message: String,
                          sessionID: String) async throws -> CodeLaunchDeliveryEvidence {
        .unknown("The computer has not confirmed this message yet. Open the session before sending again.")
    }
}

/// What one Send of a coding session asks for.
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
    case destinationChanged

    var errorDescription: String? {
        switch self {
        case .branchExists(let name): "A branch named \(name) already exists. Pick another name."
        case .worktreeNotFound: "The worktree wasn't confirmed. Check Worktrees, then try again."
        case .destinationChanged:
            "The saved project, branch or folder changed. Check Worktrees before continuing."
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
        try await sessions.send(request.firstMessage, toSession: record.id, submissionID: UUID())
        return record
    }

    /// Steps 1 and 2: the folder, then the session in it.
    func start(_ request: CodeLaunchRequest, progress: (CodeLaunch.Step) -> Void) async throws -> CodeSessionRecord {
        try await start(request, destination: nil, creationID: UUID(), progress: progress, onDestination: { _ in })
    }

    /// Starts in `destination` when one was already persisted. Git is reconciled by exact project,
    /// branch and path; an unrelated branch or folder is never adopted.
    func start(
        _ request: CodeLaunchRequest,
        destination: CodeLaunchDestination?,
        creationID: UUID,
        progress: (CodeLaunch.Step) -> Void,
        onDestination: (CodeLaunchDestination) -> Void
    ) async throws -> CodeSessionRecord {
        let main = StockGitProjectTarget(profileID: request.agentID, projectID: request.project.id,
                                         cwd: request.project.folder, projectName: request.project.name)
        let confirmed: CodeLaunchDestination
        switch request.placement {
        case .newWorktree:
            progress(.makingWorktree)
            confirmed = try await makeWorktree(request, main: main, destination: destination,
                                               onDestination: onDestination)
        case .local:
            confirmed = try await checkOut(request.branch, in: main, destination: destination,
                                           progress: progress, onDestination: onDestination)
        }
        progress(.startingSession)
        let title = CodeSessionTitle.from(request.message)
        let sessionID = try await sessions.startSession(
            agentID: request.agentID, folder: confirmed.folder, title: title,
            runtime: request.runtime, creationID: creationID
        )
        return CodeSessionRecord(id: sessionID, agentID: request.agentID, projectID: request.project.id,
                                 projectName: request.project.name, title: title, folder: confirmed.folder,
                                 branch: confirmed.branch, placement: request.placement, startedAt: .now,
                                 mode: request.mode)
    }

    private func makeWorktree(_ request: CodeLaunchRequest,
                              main: StockGitProjectTarget,
                              destination: CodeLaunchDestination?,
                              onDestination: (CodeLaunchDestination) -> Void)
        async throws -> CodeLaunchDestination {
        let snapshot = try await git.snapshot(for: main, scope: .uncommitted)
        if let destination {
            guard destination.placement == .newWorktree, let branch = destination.branch,
                  destination.folder == main.cwd + "/.worktrees/" + CodeBranchName.worktreeName(for: branch) else {
                throw CodeLaunchError.destinationChanged
            }
            if let worktree = snapshot.worktrees.first(where: { $0.path == destination.folder }) {
                guard worktree.branch == branch, !worktree.isMain else { throw CodeLaunchError.destinationChanged }
                return destination
            }
            guard !snapshot.branches.contains(where: { !$0.isRemote && $0.name == branch }) else {
                throw CodeLaunchError.destinationChanged
            }
            let name = CodeBranchName.worktreeName(for: branch)
            let base = request.branch.flatMap { branch in snapshot.baseBranches.contains { $0.name == branch } ? branch : nil }
            let prepared = try git.prepare(.addWorktree(name: name, branch: branch, base: base), target: main)
            let result = try await git.execute(prepared, confirmationToken: prepared.confirmationToken)
            guard let worktree = result.snapshot.worktrees.first(where: { $0.branch == branch }) else {
                throw CodeLaunchError.worktreeNotFound
            }
            let confirmed = CodeLaunchDestination(folder: worktree.path, branch: branch, placement: .newWorktree)
            onDestination(confirmed)
            return confirmed
        }
        let taken = Set(snapshot.branches.filter { !$0.isRemote }.map(\.name))
        let branch: String
        if let chosen = request.newBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty {
            guard !taken.contains(chosen) else { throw CodeLaunchError.branchExists(chosen) }
            branch = chosen
        } else {
            branch = CodeBranchName.suggested(for: CodeSessionTitle.withoutCommand(request.message), taken: taken)
        }
        let attempted = CodeLaunchDestination(
            folder: main.cwd + "/.worktrees/" + CodeBranchName.worktreeName(for: branch),
            branch: branch, placement: .newWorktree
        )
        onDestination(attempted)
        let base = request.branch.flatMap { name in snapshot.baseBranches.contains { $0.name == name } ? name : nil }
        let prepared = try git.prepare(.addWorktree(name: CodeBranchName.worktreeName(for: branch), branch: branch,
                                                    base: base), target: main)
        let result = try await git.execute(prepared, confirmationToken: prepared.confirmationToken)
        guard let worktree = result.snapshot.worktrees.first(where: { $0.branch == branch }) else {
            throw CodeLaunchError.worktreeNotFound
        }
        let confirmed = CodeLaunchDestination(folder: worktree.path, branch: branch, placement: .newWorktree)
        onDestination(confirmed)
        return confirmed
    }

    /// Switches the main folder to `branch` when it isn't checked out already.
    private func checkOut(_ branch: String?, in main: StockGitProjectTarget,
                          destination: CodeLaunchDestination?,
                          progress: (CodeLaunch.Step) -> Void,
                          onDestination: (CodeLaunchDestination) -> Void) async throws -> CodeLaunchDestination {
        let snapshot = try await git.snapshot(for: main, scope: .uncommitted)
        let selected = destination?.branch ?? branch ?? snapshot.status.branch
        if let destination {
            guard destination.placement == .local, destination.folder == main.cwd,
                  destination.branch == selected else { throw CodeLaunchError.destinationChanged }
        } else {
            onDestination(CodeLaunchDestination(folder: main.cwd, branch: selected, placement: .local))
        }
        guard let branch = selected else {
            return CodeLaunchDestination(folder: main.cwd, branch: nil, placement: .local)
        }
        guard branch != snapshot.status.branch else {
            return CodeLaunchDestination(folder: main.cwd, branch: branch, placement: .local)
        }
        progress(.switchingBranch)
        let prepared = try git.prepare(.switchBranch(branch), target: main)
        let result = try await git.execute(prepared, confirmationToken: prepared.confirmationToken)
        guard result.snapshot.status.branch == branch else { throw CodeLaunchError.destinationChanged }
        return CodeLaunchDestination(folder: main.cwd, branch: branch, placement: .local)
    }
}

/// Hermes sessions through the app's own session list and chat models: the same
/// path Shortcuts takes, so nothing opens on screen.
@MainActor
struct CodeChatSessionStarter: CodeSessionStarting {
    let catalog: SessionCatalogStore
    let features: ShellFeatureStore

    func startSession(agentID: String, folder: String, title: String, runtime: CodeRuntimeChoice,
                      creationID: UUID) async throws -> String {
        let start = SessionStartRuntime(provider: runtime.modelID == nil ? nil : runtime.providerID, model: runtime.modelID,
                                        reasoningEffort: runtime.reasoning, fast: runtime.fastMode)
        return try await catalog.createDirect(agentID: agentID, folder: folder, title: title, runtime: start,
                                              creationID: creationID).id
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
            NSLog("Bighelp: YOLO for a new IDE session failed: %@", String(describing: error))
            throw CodeStartError.yoloRefused
        }
    }

    func send(_ message: String, toSession sessionID: String, submissionID: UUID) async throws {
        let chat = try BighelpShortcutWorkspace.chatModel(sessionID: sessionID, in: features)
        try await BighelpShortcutService.awaitTransportReady(chat)
        if chat.nativeConversationClient != nil {
            try await chat.submitWithoutWaiting(message: message, attachments: [], submissionID: submissionID)
        } else {
            // A slash command takes the message box's own path, which runs it as a
            // command (`/plan` expands to its planning prompt there). Demo chats have no
            // host queue either: they play their sample reply in place.
            await chat.slashCommandCatalog?.loadIfNeeded(for: message)
            chat.draft = message
            Task { await chat.send() }
        }
    }

    func existingSession(for request: CodeLaunchRequest, at destination: CodeLaunchDestination,
                         requestedAt: Date) async throws -> CodeSessionRecord? {
        try await catalog.load(requireAuthoritativeRefresh: true)
        let matches = catalog.records.filter { record in
            record.kind == .direct
                && record.agentIDs == [request.agentID]
                && record.title == CodeSessionTitle.from(request.message)
                && record.createdAt >= requestedAt.addingTimeInterval(-1)
                && catalog.sessionFolder(for: record.id) == destination.folder
        }
        guard matches.count == 1, let record = matches.first else { return nil }
        return CodeSessionRecord(
            id: record.id, agentID: request.agentID, projectID: request.project.id,
            projectName: request.project.name, title: record.title, folder: destination.folder,
            branch: destination.branch, placement: destination.placement,
            startedAt: record.createdAt, mode: request.mode
        )
    }

    func deliveryEvidence(for submissionID: UUID, message: String,
                          sessionID: String) async throws -> CodeLaunchDeliveryEvidence {
        let chat = try BighelpShortcutWorkspace.chatModel(sessionID: sessionID, in: features)
        if chat.items.contains(where: { $0.id == ChatSubmissionIdentity.itemID(submissionID) }) {
            return .sent
        }
        if let submission = chat.nativeConversationClient?.journal.unresolved.first(where: { $0.id == submissionID }) {
            if let code = submission.rejectionCode {
                return .unsent("Hermes refused this message (code \(code)). Your message is still here.")
            }
            return .unknown("Hermes may have accepted this message. Its outcome is still unconfirmed; open the session before sending again.")
        }
        return .unknown("The app cannot prove whether Hermes accepted this message. Open the session before sending again.")
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
