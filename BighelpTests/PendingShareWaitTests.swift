import Foundation
import Testing
@testable import Bighelp

/// The share sheet waits on each shared item for its answer, its deadline or Cancel
/// (`PendingShareWait`), and an answer that came in time is never taken for a timeout. Foundation
/// only: these run on any platform Swift runs on.
@Suite(.serialized)
struct PendingShareWaitTests {
    private enum Failure: Error, Equatable { case timedOut, cancelled }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private func wait<T: Sendable>(deadline: Duration, cancellation: PendingShareCancellation = .init(),
                                   _ start: (_ finish: @escaping @Sendable (Result<T, Failure>) -> Void) -> Void)
        async -> Result<T, Failure> {
        await PendingShareWait.first(deadline: deadline, timedOut: Failure.timedOut, cancelled: Failure.cancelled,
                                     cancellation: cancellation, start)
    }

    @Test func aStoppedTimerNeverFires() async throws {
        // An answer stops the timer. Its sleep then ends early, which must not count as the deadline.
        let fired = Flag()
        let timer = PendingShareWait.expiry(after: .seconds(30)) { fired.set() }
        timer.cancel()
        await timer.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(!fired.isSet)
    }

    @Test func answersInTimeAlwaysWin() async {
        for index in 0..<300 {
            let now: Result<Int, Failure> = await wait(deadline: .seconds(30)) { finish in finish(.success(index)) }
            #expect(now == .success(index))
            let later: Result<Int, Failure> = await wait(deadline: .seconds(30)) { finish in
                DispatchQueue.global().async { finish(.success(index)) }
            }
            #expect(later == .success(index), "Answer \(index), from another thread")
        }
    }

    @Test func noAnswerTimesOutOnlyOnceTheDeadlinePasses() async {
        let start = ContinuousClock.now
        let result: Result<Int, Failure> = await wait(deadline: .milliseconds(80)) { _ in }
        #expect(result == .failure(.timedOut))
        #expect(start.duration(to: .now) >= .milliseconds(80))
    }

    @Test func aLateAnswerIsIgnored() async throws {
        let result: Result<Int, Failure> = await wait(deadline: .milliseconds(20)) { finish in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { finish(.success(1)) }
        }
        #expect(result == .failure(.timedOut))
        // The late answer arrives and is dropped, not resumed a second time.
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test func cancelEndsTheWaitAtOnce() async {
        let cancellation = PendingShareCancellation()
        let start = ContinuousClock.now
        let result: Result<Int, Failure> = await wait(deadline: .seconds(30), cancellation: cancellation) { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { cancellation.cancel() }
        }
        #expect(result == .failure(.cancelled))
        #expect(start.duration(to: .now) < .seconds(5))

        // Cancelled already: the next item doesn't wait at all.
        let next: Result<Int, Failure> = await wait(deadline: .seconds(30), cancellation: cancellation) { _ in }
        #expect(next == .failure(.cancelled))
    }
}
