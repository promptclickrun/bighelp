import Foundation

/// What the Kanban screens ask of a host. Every write is checked against the
/// host's current revision and read back before it counts; the board model
/// shows the change right away and undoes it if the host says no.
@MainActor
protocol KanbanService: AnyObject {
    /// False when the host has no Kanban plugin; the menu hides Kanban then.
    func isAvailable() async throws -> Bool
    func boards() async throws -> [HermesKanbanBoard]
    func board(_ slug: String) async throws -> HermesKanbanBoardSnapshot
    func task(_ id: String, board: String) async throws -> HermesKanbanTaskDetail
    func activeWorkers(board: String) async throws -> [HermesKanbanActiveWorker]
    func orchestration() async throws -> HermesKanbanOrchestration

    func move(_ taskID: String, to status: HermesKanbanTaskStatus, board: String) async throws -> HermesKanbanTaskDetail
    func edit(_ taskID: String, board: String, patch: HermesKanbanTaskPatch) async throws -> HermesKanbanTaskDetail
    /// Running work is reclaimed first, so it isn't done twice.
    func reassign(_ taskID: String, to profile: String?, board: String) async throws -> HermesKanbanTaskDetail
    func comment(_ body: String, on taskID: String, board: String) async throws -> HermesKanbanTaskDetail
    func create(_ draft: HermesKanbanTaskDraft, board: String) async throws -> HermesKanbanTaskDetail
    func createBoard(named name: String) async throws -> [HermesKanbanBoard]
    /// Asks Hermes to hand Ready work to agents now instead of on its next pass.
    func startReadyWork(board: String) async throws -> HermesKanbanBoardSnapshot
    func setAutoPlan(_ isOn: Bool) async throws -> HermesKanbanOrchestration

    /// A fresh board whenever Hermes reports a change. Ends when the host's
    /// live window ends; the model restarts it while the board is on screen.
    func liveBoards(_ slug: String, since cursor: Int) throws -> AsyncThrowingStream<HermesKanbanBoardSnapshot, any Error>
}

/// Hermes' bundled Kanban plugin (`/api/plugins/kanban/*`) through the
/// owner-scoped native client. It follows reconnects to the same computer
/// (each one is a new owner), so an open board keeps working after the app
/// comes back; another computer needs a new service.
@MainActor
final class LiveKanbanService: KanbanService {
    private let host: WorkspaceAuthority
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let makeClient: @MainActor (WorkspaceOwner) -> DirectHermesKanbanClient?
    private let author: String
    private var cached: (owner: WorkspaceOwner, client: DirectHermesKanbanClient)?

    init(host: WorkspaceAuthority, currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
         makeClient: @escaping @MainActor (WorkspaceOwner) -> DirectHermesKanbanClient?,
         author: String = "Bighelp") {
        self.host = host
        self.currentOwner = currentOwner
        self.makeClient = makeClient
        self.author = author
    }

    /// The client for the current connection to this computer.
    private var client: DirectHermesKanbanClient {
        get throws {
            guard let owner = currentOwner(), owner.authority == host else { throw HermesKanbanError.staleOwner }
            if let cached, cached.owner == owner { return cached.client }
            guard let client = makeClient(owner) else { throw HermesKanbanError.staleOwner }
            cached = (owner, client)
            return client
        }
    }

    func isAvailable() async throws -> Bool { try await client.discoverMount() == .available }
    func boards() async throws -> [HermesKanbanBoard] { try await client.boards() }
    func board(_ slug: String) async throws -> HermesKanbanBoardSnapshot { try await client.board(slug: slug) }
    func task(_ id: String, board: String) async throws -> HermesKanbanTaskDetail { try await client.task(id: id, board: board) }
    func activeWorkers(board: String) async throws -> [HermesKanbanActiveWorker] { try await client.activeWorkers(board: board) }
    func orchestration() async throws -> HermesKanbanOrchestration { try await client.orchestration() }

    func move(_ taskID: String, to status: HermesKanbanTaskStatus, board: String) async throws -> HermesKanbanTaskDetail {
        var patch = HermesKanbanTaskPatch()
        patch.status = .set(status)
        return try await edit(taskID, board: board, patch: patch)
    }

    func edit(_ taskID: String, board: String, patch: HermesKanbanTaskPatch) async throws -> HermesKanbanTaskDetail {
        try await client.edit(approved: client.prepareEdit(taskID: taskID, board: board, patch: patch))
    }

    func reassign(_ taskID: String, to profile: String?, board: String) async throws -> HermesKanbanTaskDetail {
        let current = try await client.task(id: taskID, board: board)
        let review = try await client.prepareReassignment(
            taskID: taskID, board: board, profile: profile,
            reclaimFirst: current.task.status == .running, reason: nil
        )
        guard case .task(let detail?) = try await client.perform(approved: review) else {
            return try await client.task(id: taskID, board: board)
        }
        return detail
    }

    func comment(_ body: String, on taskID: String, board: String) async throws -> HermesKanbanTaskDetail {
        try await client.addComment(approved: client.prepareComment(body, taskID: taskID, board: board), author: author)
    }

    func create(_ draft: HermesKanbanTaskDraft, board: String) async throws -> HermesKanbanTaskDetail {
        try await client.create(approved: client.prepareCreation(draft, board: board))
    }

    func createBoard(named name: String) async throws -> [HermesKanbanBoard] {
        let taken = Set(try await client.boards(includeArchived: true).map(\.slug))
        let draft = HermesKanbanBoardDraft(slug: Self.slug(for: name, avoiding: taken), name: name)
        guard case .boards(let boards) = try await client.perform(approved: client.prepareBoardCreation(draft)) else {
            return try await client.boards()
        }
        return boards
    }

    func startReadyWork(board: String) async throws -> HermesKanbanBoardSnapshot {
        try await client.nudgeDispatcher(approved: client.prepareDispatcherNudge(board: board)).board
    }

    func setAutoPlan(_ isOn: Bool) async throws -> HermesKanbanOrchestration {
        var patch = HermesKanbanOrchestrationPatch()
        patch.automaticallyDecomposes = .set(isOn)
        guard case .orchestration(let value) = try await client.perform(approved: client.prepareOrchestrationEdit(patch)) else {
            return try await client.orchestration()
        }
        return value
    }

    func liveBoards(_ slug: String, since cursor: Int) throws -> AsyncThrowingStream<HermesKanbanBoardSnapshot, any Error> {
        let client = try client
        let updates = try client.liveUpdates(board: slug, since: cursor, maximumPolls: 90)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await update in updates {
                        switch update {
                        case .snapshot(let snapshot): continuation.yield(snapshot)
                        // Events only say something changed; the typed board is the truth.
                        case .events: continuation.yield(try await client.board(slug: slug))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Hermes board slugs are ASCII lowercase letters, digits, "-" and "_" (64 at most).
    static func slug(for name: String, avoiding taken: Set<String> = []) -> String {
        let words = name.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        let base = String((words.isEmpty ? "board" : words.joined(separator: "-")).prefix(58))
        var slug = base
        var suffix = 2
        while taken.contains(slug) {
            slug = "\(base)-\(suffix)"
            suffix += 1
        }
        return slug
    }
}
