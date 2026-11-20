import Foundation
import Observation

/// Coding sessions for one computer: what the three chips under the message box
/// hold (project, where it runs, branch), the agent that runs the sessions, and
/// the sessions sent from here. Each Send starts its own session and returns at
/// once, so several can be sent back to back. Orchestration mode stages jobs (each
/// with its own chips) and Send all starts them as one batch.
@MainActor
@Observable
final class CodeHomeStore {
    private(set) var agentID: String
    private(set) var projects: [CodeProject] = []
    private(set) var found: [CodeFoundFolder] = []
    private(set) var projectID: String?
    var placement: CodePlacement = .newWorktree { didSet { save() } }
    /// New worktree: the branch it starts from. Local: the branch to work on. Nil is the default.
    var branch: String? { didSet { save() } }
    /// New worktree: the new branch's name; nil names it from the message.
    var newBranchName: String?
    /// The model chip: model, reasoning and fast mode for new sessions.
    var runtime = CodeRuntimeChoice() { didSet { save() } }
    /// The mode button: Default, Plan or YOLO for new sessions.
    var mode = CodeSessionMode.standard { didSet { save() } }
    /// The slash commands a new session will have, for the message box's / list.
    private(set) var commands: [SlashCommandDescriptor] = []
    private(set) var commandsError: String?
    /// The selected project's main folder, as git sees it now.
    private(set) var git: StockGitSnapshot?
    private(set) var isLoading = false
    private(set) var sessions: [CodeSessionRecord] = []
    private(set) var launches: [CodeLaunch] = []
    /// Jobs staged for Send all, for any project.
    private(set) var staged: [CodeStagedJob] = []
    /// Batches sent with Send all, newest first.
    private(set) var batches: [CodeBatch] = []
    var filter: CodeSessionFilter = .all
    var errorMessage: String?

    /// The computer (`cacheScopeID`) this home belongs to.
    @ObservationIgnored let scopeID: String
    @ObservationIgnored private let source: any CodeProjectSource
    /// The host's git, looked up for each use: a reconnect brings a new one.
    @ObservationIgnored let gitClient: @MainActor () throws -> any StockGitManaging
    @ObservationIgnored private let starter: any CodeSessionStarting
    @ObservationIgnored private let loadModels: @MainActor (String) async throws -> [BighelpLinkModelProvider]
    @ObservationIgnored private let loadCommands: @MainActor (_ agentID: String, _ folder: String?) async throws
        -> [SlashCommandDescriptor]
    /// The agent and folder `commands` were loaded for.
    @ObservationIgnored private var commandsKey: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var gitRequest: UUID?
    /// The last send still making its folder and session; the next one waits for it.
    @ObservationIgnored private var setupTail: Task<Void, Never>?
    @ObservationIgnored private var reconcilingLaunches: Set<UUID> = []

    init(scopeID: String, agentID: String, source: any CodeProjectSource,
         git: @escaping @MainActor () throws -> any StockGitManaging,
         starter: any CodeSessionStarting,
         loadModels: @escaping @MainActor (String) async throws -> [BighelpLinkModelProvider] = { _ in [] },
         loadCommands: @escaping @MainActor (String, String?) async throws -> [SlashCommandDescriptor] = { _, _ in [] },
         defaults: UserDefaults = .standard) {
        self.scopeID = scopeID
        self.source = source
        gitClient = git
        self.starter = starter
        self.loadModels = loadModels
        self.loadCommands = loadCommands
        self.defaults = defaults
        let saved = Self.saved(scopeID, in: defaults)
        self.agentID = saved?.agentID ?? agentID
        projectID = saved?.projectID
        placement = saved?.placement ?? .newWorktree
        branch = saved?.branch
        runtime = saved?.runtime ?? CodeRuntimeChoice()
        mode = saved?.mode ?? .standard
        sessions = saved?.sessions ?? []
        staged = saved?.staged ?? []
        batches = saved?.batches ?? []
        // A process-local request cannot continue after relaunch. Git destinations saved before
        // mutation are safe to retry; a lost create/send receipt stays unconfirmed until read back.
        launches = (saved?.launches ?? []).map { saved in
            var launch = saved
            if !launch.step.isFailed, !launch.step.needsRecovery {
                switch launch.step {
                case .makingWorktree, .switchingBranch where launch.destination != nil:
                    launch.step = .failed(CodeLaunch.interruptedReason)
                case .readyToSend:
                    launch.step = .failed(
                        "The app closed after the session started, before this message was sent."
                    )
                default:
                    launch.step = .needsRecovery(CodeLaunch.interruptedReason)
                }
            }
            return launch
        }
    }

    var project: CodeProject? { projects.first { $0.id == projectID } }

    /// Sessions for the selected project, newest first.
    var projectSessions: [CodeSessionRecord] {
        sessions.filter { $0.projectID == projectID }
    }

    /// Sends for the selected project, including a session-backed recovery card. A batch's own
    /// sends stay on the batch.
    var projectLaunches: [CodeLaunch] {
        launches.filter { $0.projectID == projectID && $0.batchID == nil }
    }

    /// The selected project's sessions that aren't in a batch: each has its own card.
    var projectSingleSessions: [CodeSessionRecord] {
        projectSessions.filter { $0.batchID == nil }
    }

    /// The selected project's staged jobs, in the order they were staged.
    var projectStaged: [CodeStagedJob] {
        staged.filter { $0.projectID == projectID }
    }

    /// The selected project's batches, newest first.
    var projectBatches: [CodeBatch] {
        batches.filter { $0.projectID == projectID }
    }

    func batch(id: UUID) -> CodeBatch? {
        batches.first { $0.id == id }
    }

    /// A batch's jobs that haven't become sessions yet.
    func pendingLaunches(of batch: CodeBatch) -> [CodeLaunch] {
        launches.filter { $0.batchID == batch.id && $0.sessionID == nil }
    }

    /// A session's own send while it's still under way or failed: shown instead of the chat's status.
    func launch(for session: CodeSessionRecord) -> CodeLaunch? {
        launches.first { $0.sessionID == session.id }
    }

    /// The branch the chip shows: the picked one, else the default (new worktree)
    /// or the current one (local).
    var branchTitle: String? {
        if let branch { return branch }
        switch placement {
        case .newWorktree: return git?.status.defaultBranch ?? git?.baseBranches.first(where: \.isDefault)?.name
        case .local: return git?.status.branch
        }
    }

    /// Other sessions already working in the main folder: Local warns about them.
    var sessionsInMainFolder: Int {
        guard let project else { return 0 }
        return projectSessions.filter { $0.folder == project.folder }.count
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await source.load(agentID: agentID)
            projects = loaded.projects
            found = loaded.found
            errorMessage = nil
            if project == nil {
                projectID = projects.first?.id
                branch = nil
            }
            await loadGit()
            await reconcileInterruptedLaunches()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectProject(_ id: String) async {
        guard id != projectID else { return }
        projectID = id
        branch = nil
        newBranchName = nil
        git = nil
        save()
        await loadGit()
    }

    func selectAgent(_ id: String) async {
        guard id != agentID else { return }
        agentID = id
        // Models and projects are the agent's own.
        runtime = CodeRuntimeChoice()
        projectID = nil
        projects = []
        git = nil
        save()
        await load()
    }

    /// Makes a folder Hermes found a project, then selects it.
    func addProject(_ folder: CodeFoundFolder) async {
        do {
            let id = try await source.addProject(folder, agentID: agentID)
            await load()
            await selectProject(id)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads the / list for the agent and project once; a later call for the same pair does nothing.
    func loadCommandsIfNeeded() async {
        let key = agentID + "\n" + (project?.folder ?? "")
        guard commandsKey != key else { return }
        commandsKey = key
        do {
            commands = try await loadCommands(agentID, project?.folder)
            commandsError = nil
        } catch is CancellationError {
            commandsKey = nil
        } catch {
            commandsKey = nil
            commandsError = "Commands couldn't load from Hermes."
        }
    }

    /// The models this agent can use, grouped by provider.
    func modelProviders() async throws -> [BighelpLinkModelProvider] {
        try await loadModels(agentID)
    }

    func loadGit() async {
        guard let project else { git = nil; return }
        let request = UUID()
        gitRequest = request
        let target = StockGitProjectTarget(profileID: agentID, projectID: project.id, cwd: project.folder,
                                           projectName: project.name)
        do {
            let snapshot = try await gitClient().snapshot(for: target, scope: .uncommitted)
            guard gitRequest == request, projectID == project.id else { return }
            git = snapshot
        } catch is CancellationError {
        } catch {
            guard gitRequest == request else { return }
            git = nil
            errorMessage = "Git isn't available for \(project.name). \(error.localizedDescription)"
        }
    }

    // MARK: Sending

    /// Starts a session for `message` and returns at once. False when there's no project to send to.
    @discardableResult
    func send(_ message: String) -> Bool {
        guard let job = job(for: message) else { return false }
        return launch(job, batchID: nil)
    }

    /// Stages `message` with the chips as they are now, for Send all. False when there's nothing to stage.
    @discardableResult
    func stage(_ message: String) -> Bool {
        guard let job = job(for: message) else { return false }
        staged.append(job)
        if !save() { staged.removeAll { $0.id == job.id }; return false }
        return true
    }

    func unstage(_ id: UUID) {
        staged.removeAll { $0.id == id }
        save()
    }

    func clearStaged() {
        staged.removeAll { $0.projectID == projectID }
        save()
    }

    /// Starts the selected project's staged jobs, then `message` if there is one, as one batch.
    @discardableResult
    func sendAll(including message: String = "") -> CodeBatch? {
        var jobs = projectStaged
        if let last = job(for: message) { jobs.append(last) }
        guard let project, !jobs.isEmpty, (try? gitClient()) != nil else { return nil }
        let batch = CodeBatch(id: UUID(), projectID: project.id, title: CodeBatch.title(for: jobs), createdAt: .now,
                              jobCount: jobs.count, sessionIDs: [], messages: [])
        let transferred = jobs.compactMap { launch(for: $0, project: project, batchID: batch.id) }
        guard transferred.count == jobs.count else { return nil }
        let previousBatches = batches
        batches.insert(batch, at: 0)
        if batches.count > Self.maximumBatches { batches.removeLast(batches.count - Self.maximumBatches) }
        launches.insert(contentsOf: transferred.reversed(), at: 0)
        let previousStaged = staged
        staged.removeAll { job in jobs.contains { $0.id == job.id } }
        // One atomic saved handoff: no staged job disappears unless every launch intent is durable too.
        guard save() else {
            staged = previousStaged
            launches.removeAll { launch in transferred.contains { $0.id == launch.id } }
            batches = previousBatches
            return nil
        }
        for launch in transferred { run(launch) }
        return batch
    }

    /// Keeps a message sent from a batch chat.
    func record(_ message: CodeBatchMessage, in batchID: UUID) {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else { return }
        batches[index].messages.append(message)
        if batches[index].messages.count > CodeBatch.maximumMessages { batches[index].messages.removeFirst() }
        save()
    }

    func rename(_ batch: CodeBatch, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = batches.firstIndex(where: { $0.id == batch.id }) else { return }
        batches[index].title = String(title.prefix(80))
        save()
    }

    /// Forgets a batch's card, its retained launches and its local session cards.
    /// The sessions themselves stay on the computer.
    func forget(_ batch: CodeBatch) {
        batches.removeAll { $0.id == batch.id }
        launches.removeAll { $0.batchID == batch.id }
        sessions.removeAll { $0.batchID == batch.id }
        save()
    }

    /// A job from `message` and the chips as they are now; nil when there's nothing to send or no project.
    private func job(for message: String) -> CodeStagedJob? {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let project else { return nil }
        defer { newBranchName = nil }
        return CodeStagedJob(id: UUID(), message: message, agentID: agentID, projectID: project.id,
                             placement: placement, branch: branch,
                             newBranch: placement == .newWorktree ? newBranchName : nil, runtime: runtime, mode: mode)
    }

    @discardableResult
    private func launch(_ job: CodeStagedJob, batchID: UUID?) -> Bool {
        guard let project = projects.first(where: { $0.id == job.projectID }),
              (try? gitClient()) != nil,
              let launch = launch(for: job, project: project, batchID: batchID) else {
            return false
        }
        launches.insert(launch, at: 0)
        guard save() else {
            launches.removeAll { $0.id == launch.id }
            return false
        }
        run(launch)
        return true
    }

    private func launch(for job: CodeStagedJob, project: CodeProject, batchID: UUID?) -> CodeLaunch? {
        guard project.id == job.projectID else { return nil }
        return CodeLaunch(id: UUID(), title: job.title, projectID: project.id, projectName: project.name,
                          projectFolder: project.folder, job: job,
                          step: job.placement == .newWorktree ? .makingWorktree : .startingSession,
                          startedAt: .now, destination: nil, batchID: batchID,
                          branchLabel: job.placement == .local ? (job.branch ?? branchTitle) : nil)
    }

    private func run(_ launch: CodeLaunch) {
        let previous = setupTail
        let setup = Task { @MainActor [weak self] () throws -> CodeSessionRecord in
            await previous?.value
            guard let self else { throw CancellationError() }
            if let sessionID = launch.sessionID {
                if let record = self.sessions.first(where: { $0.id == sessionID }) { return record }
                guard let request = self.request(for: launch), let destination = launch.destination else {
                    throw WorkspaceClientError.invalidResponse
                }
                return CodeSessionRecord(
                    id: sessionID, agentID: request.agentID, projectID: request.project.id,
                    projectName: request.project.name, title: launch.title, folder: destination.folder,
                    branch: destination.branch, placement: destination.placement,
                    startedAt: launch.startedAt ?? .now, mode: request.mode, batchID: launch.batchID
                )
            }
            guard let request = self.request(for: launch) else { throw WorkspaceClientError.invalidRequest }
            let launcher = CodeLauncher(git: try self.gitClient(), sessions: self.starter)
            return try await launcher.start(
                request,
                destination: launch.destination,
                creationID: launch.id,
                progress: { step in
                    self.update(launch.id) { $0.step = step }
                    self.save()
                },
                onDestination: { destination in
                    self.update(launch.id) {
                        $0.destination = destination
                        $0.branchLabel = destination.branch
                    }
                    self.save()
                }
            )
        }
        setupTail = Task { _ = try? await setup.value }
        Task { @MainActor [weak self, starter] in
            do {
                var record = try await setup.value
                record.batchID = launch.batchID
                self?.update(launch.id) {
                    $0.sessionID = record.id
                    $0.step = .readyToSend
                    $0.submissionID = nil
                }
                self?.remember(record)
                if let batchID = launch.batchID { self?.add(record.id, toBatch: batchID) }
                guard let request = self?.request(for: launch) else { throw WorkspaceClientError.invalidRequest }
                try await starter.apply(request.mode, toSession: record.id, agentID: request.agentID)
                let submissionID = UUID()
                self?.update(launch.id) {
                    $0.submissionID = submissionID
                    $0.step = .sending
                }
                self?.save()
                try await starter.send(request.firstMessage, toSession: record.id, submissionID: submissionID)
                self?.launches.removeAll { $0.id == launch.id }
                self?.save()
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "Hermes couldn't start this session."
                self?.update(launch.id) {
                    $0.step = Self.outcomeIsUnknown(error)
                        ? .needsRecovery(reason)
                        : .failed(reason)
                }
                // The card keeps the message. It's saved, so it's still here after a relaunch.
                self?.save()
            }
            if launch.placement == .newWorktree { await self?.loadGit() }
        }
    }

    /// Hides a send that failed. Its message goes with it: the card is the only copy kept here.
    func dismiss(_ launch: CodeLaunch) {
        launches.removeAll { $0.id == launch.id }
        save()
    }

    /// Sends a failed launch's own message again, with the chips it was sent with.
    func retry(_ failed: CodeLaunch) {
        guard let current = launches.first(where: { $0.id == failed.id }) else { return }
        if current.step.needsRecovery {
            reconcile(current, retryAfterRead: true)
            return
        }
        guard current.step.isFailed else { return }
        update(current.id) {
            $0.step = current.sessionID == nil
                ? (current.placement == .newWorktree ? .makingWorktree : .startingSession)
                : .readyToSend
            $0.submissionID = nil
        }
        save()
        run(current)
    }

    /// Forgets a session's card. The session stays on the computer.
    func forget(_ session: CodeSessionRecord) {
        sessions.removeAll { $0.id == session.id }
        save()
    }

    private func update(_ id: UUID, _ change: (inout CodeLaunch) -> Void) {
        guard let index = launches.firstIndex(where: { $0.id == id }) else { return }
        change(&launches[index])
    }

    private func add(_ sessionID: String, toBatch batchID: UUID) {
        guard let index = batches.firstIndex(where: { $0.id == batchID }),
              !batches[index].sessionIDs.contains(sessionID) else { return }
        batches[index].sessionIDs.append(sessionID)
        save()
    }

    private func request(for launch: CodeLaunch) -> CodeLaunchRequest? {
        let project: CodeProject?
        if let loaded = projects.first(where: { $0.id == launch.projectID }) {
            project = loaded
        } else if let name = launch.projectName, let folder = launch.projectFolder {
            project = CodeProject(id: launch.projectID, name: name, folder: folder)
        } else {
            project = nil
        }
        guard let project else { return nil }
        return CodeLaunchRequest(
            message: launch.job.message, agentID: launch.job.agentID, project: project,
            placement: launch.job.placement, branch: launch.job.branch, newBranch: launch.job.newBranch,
            runtime: launch.job.runtime, mode: launch.job.mode
        )
    }

    private func reconcile(_ launch: CodeLaunch, retryAfterRead: Bool = false) {
        guard reconcilingLaunches.insert(launch.id).inserted else { return }
        Task { @MainActor [weak self, starter] in
            defer { self?.reconcilingLaunches.remove(launch.id) }
            do {
                if let sessionID = launch.sessionID {
                    if let submissionID = launch.submissionID {
                        switch try await starter.deliveryEvidence(
                            for: submissionID, message: launch.job.mode.firstMessage(launch.job.message),
                            sessionID: sessionID
                        ) {
                        case .sent:
                            self?.launches.removeAll { $0.id == launch.id }
                        case .unsent(let reason):
                            self?.update(launch.id) { $0.step = .failed(reason) }
                        case .unknown(let reason):
                            self?.update(launch.id) { $0.step = .needsRecovery(reason) }
                        }
                    } else {
                        self?.update(launch.id) {
                            $0.step = .needsRecovery(
                                "The app cannot prove that this session's first message was sent. Open it before continuing."
                            )
                        }
                    }
                } else if let destination = launch.destination, let request = self?.request(for: launch) {
                    let requestedAt = launch.startedAt ?? .distantPast
                    if let record = try await starter.existingSession(
                        for: request, at: destination, requestedAt: requestedAt
                    ) {
                        self?.remember(record)
                        if let batchID = launch.batchID { self?.add(record.id, toBatch: batchID) }
                        self?.update(launch.id) {
                            $0.sessionID = record.id
                            $0.step = .failed("Hermes made the session, but the first message was not confirmed. Try again to send it.")
                        }
                    } else if let startedAt = launch.startedAt,
                              Date().timeIntervalSince(startedAt) <= Self.sessionCreateIdempotencyWindow {
                        self?.update(launch.id) {
                            $0.step = .needsRecovery(
                                "Hermes did not show this session yet. Check the original request before continuing."
                            )
                        }
                        if retryAfterRead, let current = self?.launches.first(where: { $0.id == launch.id }) {
                            self?.update(launch.id) {
                                $0.step = launch.placement == .newWorktree ? .makingWorktree : .startingSession
                            }
                            self?.run(current)
                        }
                    } else {
                        self?.update(launch.id) {
                            $0.step = .needsRecovery(
                                "The session was not confirmed. Its message is retained; open Work to check the computer before continuing."
                            )
                        }
                    }
                } else {
                    self?.update(launch.id) {
                        $0.step = .needsRecovery(
                            "The original worktree could not be verified. Its message is retained; check Worktrees before continuing."
                        )
                    }
                }
                self?.save()
            } catch {
                self?.update(launch.id) {
                    $0.step = .needsRecovery(
                        "The computer could not confirm this send. Its complete message is retained."
                    )
                }
                self?.save()
            }
        }
    }

    private func reconcileInterruptedLaunches() async {
        let interrupted = launches.filter(\.step.needsRecovery)
        for launch in interrupted { reconcile(launch) }
    }

    private static func outcomeIsUnknown(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if error as? WorkspaceClientError == .outcomeUnknown
            || error as? WorkspaceClientError == .invalidResponse {
            return true
        }
        if let direct = error as? DirectHermesError {
            return direct.outcomeIsUnknown || direct == .invalidResponse
        }
        return false
    }

    private func remember(_ record: CodeSessionRecord) {
        sessions.removeAll { $0.id == record.id }
        sessions.insert(record, at: 0)
        if sessions.count > Self.maximumSessions { sessions.removeLast(sessions.count - Self.maximumSessions) }
        save()
    }

    // MARK: Saved per computer

    private struct Saved: Codable {
        var agentID: String
        var projectID: String?
        var placement: CodePlacement
        var branch: String?
        var runtime: CodeRuntimeChoice?
        var mode: CodeSessionMode?
        var sessions: [CodeSessionRecord]
        var staged: [CodeStagedJob]?
        var batches: [CodeBatch]?
        /// Sends that haven't finished, or failed. Older saves have none.
        var launches: [CodeLaunch]?
    }

    static let savedKey = "bighelp.code.by-scope"
    private static let maximumSessions = 60
    private static let maximumBatches = 20
    private static let sessionCreateIdempotencyWindow: TimeInterval = 5 * 60

    private static func saved(_ scopeID: String, in defaults: UserDefaults) -> Saved? {
        guard let data = defaults.data(forKey: savedKey),
              let all = try? JSONDecoder().decode([String: Saved].self, from: data) else { return nil }
        return all[scopeID]
    }

    @discardableResult
    private func save() -> Bool {
        var all: [String: Saved] = (defaults.data(forKey: Self.savedKey))
            .flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
        all[scopeID] = Saved(agentID: agentID, projectID: projectID, placement: placement, branch: branch,
                             runtime: runtime, mode: mode, sessions: sessions, staged: staged, batches: batches,
                             launches: launches)
        // A handful of computers at most; drop the oldest beyond that.
        if all.count > 16, let stale = all.keys.first(where: { $0 != scopeID }) { all[stale] = nil }
        guard let data = try? JSONEncoder().encode(all) else { return false }
        defaults.set(data, forKey: Self.savedKey)
        return true
    }
}
