import Foundation
import WatchConnectivity

/// How the Watch reaches bighelp on the iPhone.
@MainActor
protocol WatchPhoneTalking: AnyObject {
    func ask(_ request: WatchRequest) async -> WatchReply
    var onPush: ((WatchPush) -> Void)? { get set }
}

/// WatchConnectivity to the paired iPhone. Asking wakes bighelp there if it
/// isn't running; the phone then talks to the host.
@MainActor
final class WatchPhone: NSObject, WatchPhoneTalking {
    var onPush: ((WatchPush) -> Void)?
    private let session: WCSession
    private var activation: [CheckedContinuation<Void, Never>] = []

    init(session: WCSession = .default) {
        self.session = session
        super.init()
        session.delegate = self
        session.activate()
    }

    func ask(_ request: WatchRequest) async -> WatchReply {
        await activated()
        guard session.activationState == .activated else { return .failed(Self.notNearby) }
        guard session.isReachable else { return .failed(Self.notNearby) }
        guard let message = try? WatchWire.encode(request, key: WatchWire.requestKey) else {
            return .failed("That's too long to send from your Watch.")
        }
        // A message can take the phone a while (reconnecting to the host), but
        // the Watch never waits forever.
        let seconds: Double = if case .send = request { 25 } else { 30 }
        return await withCheckedContinuation { continuation in
            let once = WatchOnce(continuation)
            session.sendMessage(message, replyHandler: Self.replyHandler(once), errorHandler: Self.errorHandler(once))
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(.failed("Your iPhone didn't answer in time. Try again."))
            }
        }
    }

    // Built outside the main actor: WatchConnectivity calls them on its own
    // queue, and a main-actor closure would trap there.
    private nonisolated static func replyHandler(_ once: WatchOnce) -> @Sendable ([String: Any]) -> Void {
        { reply in
            let decoded = (try? WatchWire.decode(WatchReply.self, key: WatchWire.replyKey, from: reply))
                ?? .failed("Update Bighelp on your iPhone and Watch.")
            once.resume(decoded)
        }
    }

    private nonisolated static func errorHandler(_ once: WatchOnce) -> @Sendable (any Error) -> Void {
        { _ in once.resume(.failed(WatchPhone.notNearby)) }
    }

    nonisolated static let notNearby = "Your iPhone isn't reachable. Keep it nearby with Bluetooth on."

    private func activated() async {
        guard session.activationState != .activated else { return }
        await withCheckedContinuation { activation.append($0) }
    }

    fileprivate func finishActivation() {
        let waiting = activation
        activation = []
        waiting.forEach { $0.resume() }
    }
}

extension WatchPhone: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: (any Error)?) {
        Task { @MainActor [weak self] in self?.finishActivation() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        receive(userInfo)
    }

    /// Decoded here: WatchConnectivity calls in on its own queue.
    private nonisolated func receive(_ dictionary: [String: Any]) {
        guard let push = try? WatchWire.decode(WatchPush.self, key: WatchWire.pushKey, from: dictionary) else { return }
        Task { @MainActor [weak self] in self?.onPush?(push) }
    }
}

/// Resumes a continuation once, whichever answer comes first.
final class WatchOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WatchReply, Never>?

    init(_ continuation: CheckedContinuation<WatchReply, Never>) {
        self.continuation = continuation
    }

    func resume(_ reply: WatchReply) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: reply)
    }
}
