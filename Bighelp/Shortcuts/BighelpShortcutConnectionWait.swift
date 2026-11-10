import Foundation

/// What a Shortcut waits for after it asks the host to reconnect. When a Shortcut picks
/// a gateway that isn't in use, the app starts connecting it the moment it switches, and
/// `reconnect()` returns at once while another connection is under way. Without waiting,
/// the Shortcut found nothing connected and failed. This waits, bounded, for that
/// connection to finish and for the host's workspace to be ready.
enum BighelpShortcutConnectionWait {
    struct Host {
        /// The Shortcut still wants this host (the gateway didn't change again).
        var isWanted: @MainActor () -> Bool
        var isConnecting: @MainActor () -> Bool
        var isConnected: @MainActor () -> Bool
        /// The host's workspace is ready for what the caller needs.
        var isReady: @MainActor () -> Bool
        /// Sets the workspace up on the connection, and returns when everything is loaded.
        var synchronize: @MainActor () async -> Void
        /// `isReady` can turn true while `synchronize` still runs (a caller that needs only to start
        /// a chat): the wait ends then. It must answer for this connection, never an earlier one.
        var readyDuringSetup = false
    }

    /// One run of `Host.synchronize`, so the wait can look at readiness while it runs.
    @MainActor private final class Setup {
        private(set) var isRunning = false

        func start(_ synchronize: @escaping @MainActor () async -> Void) {
            guard !isRunning else { return }
            isRunning = true
            Task { @MainActor in
                await synchronize()
                self.isRunning = false
            }
        }
    }

    /// True once the workspace is ready. False at once when the connection failed or the host
    /// isn't wanted any more, and after `timeout` when it never got ready. With
    /// `readyDuringSetup`, the setup it started is the app's own and goes on after this returns.
    @MainActor static func untilReady(
        _ host: Host,
        timeout: Duration = .seconds(15),
        step: Duration = .milliseconds(50)
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        let setup = Setup()
        while true {
            guard host.isWanted() else { return false }
            if !host.isConnecting() {
                guard host.isConnected() else { return false }
                if host.readyDuringSetup {
                    if host.isReady() { return true }
                    setup.start(host.synchronize)
                } else {
                    await host.synchronize()
                    if host.isReady() { return true }
                }
            }
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: step)
        }
    }
}
