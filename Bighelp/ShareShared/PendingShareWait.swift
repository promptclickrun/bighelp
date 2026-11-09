import Foundation

/// Cancel for a share being saved, seen by every item it waits on and by a copy between megabytes.
final class PendingShareCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [@Sendable () -> Void] = []

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let handlers = lock.withLock { () -> [@Sendable () -> Void] in
            guard !cancelled else { return [] }
            cancelled = true
            defer { self.handlers = [] }
            return self.handlers
        }
        handlers.forEach { $0() }
    }

    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runsNow = lock.withLock { () -> Bool in
            if cancelled { return true }
            handlers.append(handler)
            return false
        }
        if runsNow { handler() }
    }
}

/// Waits for one answer from a callback API (`NSItemProvider`'s loads): the answer, `timedOut` once
/// `deadline` has really passed, or `cancelled` on Cancel, whichever comes first. A later answer is
/// ignored. `start` runs at once, on the caller's actor.
enum PendingShareWait {
    static func first<Success: Sendable, Failure: Error>(
        deadline: Duration, timedOut: Failure, cancelled: Failure, cancellation: PendingShareCancellation,
        isolation: isolated (any Actor)? = #isolation,
        _ start: (_ finish: @escaping @Sendable (Result<Success, Failure>) -> Void) -> Void
    ) async -> Result<Success, Failure> {
        let once = PendingShareOnce<Result<Success, Failure>>()
        return await withCheckedContinuation { continuation in
            once.arm(continuation)
            let timer = expiry(after: deadline) { once.finish(.failure(timedOut)) }
            cancellation.onCancel { once.finish(.failure(cancelled)) }
            start { result in
                // The answer is in before the timer stops, so a stopping timer can't take its place.
                once.finish(result)
                timer.cancel()
            }
        }
    }

    /// Runs `fire` once `deadline` has passed, and never when it's cancelled first: a cancelled
    /// sleep ends early, which isn't the deadline passing.
    static func expiry(after deadline: Duration, _ fire: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            fire()
        }
    }
}

/// A continuation resumed once, by whichever answer comes first.
final class PendingShareOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: T?
    private var isFinished = false

    func arm(_ continuation: CheckedContinuation<T, Never>) {
        let ready = lock.withLock { () -> T? in
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func finish(_ value: T) {
        let waiting = lock.withLock { () -> CheckedContinuation<T, Never>? in
            guard !isFinished else { return nil }
            isFinished = true
            if continuation == nil { early = value }
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
