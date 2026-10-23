import Foundation

/// Asks the host for a full list's pages and folder lookups ahead of the list, a few at a
/// time. Taps from notifications, widgets and Shortcuts wait for that list after the app
/// returns, and on a remote host one request after another took seconds (#535).
///
/// The list still reads every answer itself, in the host's order, so what it keeps, where
/// it fails and when it stops are what they were. An answer it never reads (a page past
/// the end, the folder of a chat it skips) is dropped, its error too.
@MainActor
final class DirectHermesCatalogPrefetch {
    typealias Response = [String: BighelpJSONValue]
    typealias Fetch = @MainActor (WorkspaceOperation, Response) async throws -> Response

    enum Key: Hashable {
        case page(profile: String, offset: Int)
        case folder(String)
    }

    /// URLSession keeps at most four connections to one host on iOS.
    static let width = 4

    private let fetch: Fetch
    private let isCurrent: @MainActor () -> Bool
    private var started: [Key: Task<Response, any Error>] = [:]
    /// Read by the list and dropped, so its answer isn't held to the end or asked for again.
    private var consumed: Set<Key> = []
    private var finished = false
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(fetch: @escaping Fetch, isCurrent: @escaping @MainActor () -> Bool) {
        self.fetch = fetch
        self.isCurrent = isCurrent
    }

    /// Starts `key` ahead of the list unless it already has; `then` sees its answer as it arrives.
    func start(_ key: Key, _ operation: WorkspaceOperation, _ payload: Response,
               then: (@MainActor (Response) -> Void)? = nil) {
        guard !finished, started[key] == nil, !consumed.contains(key) else { return }
        launch(key, operation, payload, then: then)
    }

    /// The answer for `key`, asked for now if nothing started it.
    func value(_ key: Key, _ operation: WorkspaceOperation, _ payload: Response) async throws -> Response {
        guard !finished else { throw CancellationError() }
        if started[key] == nil { launch(key, operation, payload, then: nil) }
        guard let task = started[key] else { throw CancellationError() }
        consumed.insert(key)
        defer { started[key] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stops what the list didn't read, and anything an answer arriving later would start.
    /// Call once the list is done, either way.
    func finish() {
        finished = true
        for task in started.values { task.cancel() }
        started = [:]
    }

    private func launch(_ key: Key, _ operation: WorkspaceOperation, _ payload: Response,
                        then: (@MainActor (Response) -> Void)?) {
        started[key] = Task { @MainActor in
            await acquire()
            defer { release() }
            guard !finished, isCurrent() else { throw CancellationError() }
            try Task.checkCancellation()
            let response = try await fetch(operation, payload)
            // A request cancelled after it reached the host can still answer.
            if !finished, !Task.isCancelled { then?(response) }
            return response
        }
    }

    private func acquire() async {
        guard running >= Self.width else {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            // The slot goes straight to the next request, in the order they asked.
            waiting.removeFirst().resume()
        }
    }
}
