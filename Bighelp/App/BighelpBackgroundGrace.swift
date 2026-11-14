import UIKit

/// Quick trips away from bighelp (a widget, a notification, the app switcher)
/// shouldn't cost a reconnect. Going to the background keeps the host
/// connection for a short grace period, with background time from iOS, and
/// only then closes it. Coming back in time cancels the close, so the chat,
/// Projects and links find a live connection instead of rebuilding everything.
@MainActor
final class BighelpBackgroundGrace {
    static let shared = BighelpBackgroundGrace()

    /// Inside iOS's background allowance (about 30 seconds), so closing is never cut off.
    static let duration: Duration = .seconds(25)

    private var closers: [String: @MainActor () -> Void] = [:]
    private var timer: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// True while the app is in the background but still holding its connection.
    var isHolding: Bool { timer != nil }

    /// Schedules `close` for when the grace period ends. Each caller names its
    /// closer, so the two scene handlers can register without replacing each other.
    func begin(_ name: String, close: @escaping @MainActor () -> Void) {
        closers[name] = close
        guard timer == nil else { return }
        // The Mac doesn't suspend the app in the background, and it won't quit while a
        // background task runs: Quit (and an update's relaunch) waited out the whole grace.
        if backgroundTask == .invalid, !BighelpPlatform.isMac {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Bighelp keeps its connection") {
                // iOS wants its time back early: close now rather than be frozen mid-socket.
                MainActor.assumeIsolated { BighelpBackgroundGrace.shared.expire() }
            }
        }
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    /// Back in the foreground: keep the connection as it is.
    func cancel() {
        timer?.cancel()
        timer = nil
        closers.removeAll()
        endBackgroundTask()
    }

    private func expire() {
        timer?.cancel()
        timer = nil
        let pending = closers
        closers.removeAll()
        for name in pending.keys.sorted() { pending[name]?() }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
