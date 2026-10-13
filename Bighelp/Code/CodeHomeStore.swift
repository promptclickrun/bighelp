import Foundation
import Observation

/// Bighelp IDE's home for one computer: what the three chips under the message box
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
    }

    var project: CodeProject? { projects.first { $0.id == projectID } }

    /// Sessions for the selected project, newest first.
    var projectSessions: [CodeSessionRecord] {
        sessions.filter { $0.projectID == projectID }
    }

    /// Sends for the selected project that have no session yet (or never got one); a
    /// batch's own show on its card.
    var projectLaunches: [CodeLaunch] {
        launches.filter { $0.projectID == projectID && $0.sessionID == nil && $0.batchID == nil }
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
        save()
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
        batches.insert(batch, at: 0)
        if batches.count > Self.maximumBatches { batches.removeLast(batches.count - Self.maximumBatches) }
        staged.removeAll { job in jobs.contains { $0.id == job.id } }
        save()
        for job in jobs { launch(job, batchID: batch.id) }
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

    /// Forgets a batch's card and its sessions' cards. The sessions stay on the computer.
    func forget(_ batch: CodeBatch) {
        batches.removeAll { $0.id == batch.id }
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
        guard let project = projects.first(where: { $0.id == job.projectID }), let git = try? gitClient() else {
            return false
        }
        let request = CodeLaunchRequest(message: job.message, agentID: job.agentID, project: project,
                                        placement: job.placement, branch: job.branch, newBranch: job.newBranch,
                                        runtime: job.runtime, mode: job.mode)
        let launch = CodeLaunch(id: UUID(), title: job.title, projectID: project.id, placement: job.placement,
                                branch: job.placement == .local ? (job.branch ?? branchTitle) : nil,
                                step: job.placement == .newWorktree ? .makingWorktree : .startingSession,
                                batchID: batchID)
        launches.insert(launch, at: 0)
        let launcher = CodeLauncher(git: git, sessions: starter)
        let previous = setupTail
        let setup = Task { @MainActor [weak self] () throws -> CodeSessionRecord in
            await previous?.value
            return try await launcher.start(request) { step in self?.update(launch.id) { $0.step = step } }
        }
        setupTail = Task { _ = try? await setup.value }
        Task { @MainActor [weak self, starter] in
            do {
                var record = try await setup.value
                record.batchID = batchID
                self?.update(launch.id) { $0.sessionID = record.id; $0.step = .sending }
                self?.remember(record)
                if let batchID { self?.add(record.id, toBatch: batchID) }
                try await starter.apply(request.mode, toSession: record.id, agentID: request.agentID)
                try await starter.send(request.firstMessage, toSession: record.id)
                self?.launches.removeAll { $0.id == launch.id }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "Hermes couldn't start this session."
                self?.update(launch.id) { $0.step = .failed(reason) }
            }
            if request.placement == .newWorktree { await self?.loadGit() }
        }
        return true
    }

    /// Hides a send that failed.
    func dismiss(_ launch: CodeLaunch) {
        launches.removeAll { $0.id == launch.id }
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
    }

    static let savedKey = "bighelp.code.by-scope"
    private static let maximumSessions = 60
    private static let maximumBatches = 20

    private static func saved(_ scopeID: String, in defaults: UserDefaults) -> Saved? {
        guard let data = defaults.data(forKey: savedKey),
              let all = try? JSONDecoder().decode([String: Saved].self, from: data) else { return nil }
        return all[scopeID]
    }

    private func save() {
        var all: [String: Saved] = (defaults.data(forKey: Self.savedKey))
            .flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
        all[scopeID] = Saved(agentID: agentID, projectID: projectID, placement: placement, branch: branch,
                             runtime: runtime, mode: mode, sessions: sessions, staged: staged, batches: batches)
        // A handful of computers at most; drop the oldest beyond that.
        if all.count > 16, let stale = all.keys.first(where: { $0 != scopeID }) { all[stale] = nil }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.savedKey) }
    }
}
