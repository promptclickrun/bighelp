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
        /// The host's workspace is ready for chats.
        var isReady: @MainActor () -> Bool
        var synchronize: @MainActor () async -> Void
    }

    /// True once the workspace is ready. False at once when the connection failed or the
    /// host isn't wanted any more, and after `timeout` when it never got ready.
    @MainActor static func untilReady(
        _ host: Host,
        timeout: Duration = .seconds(15),
        step: Duration = .milliseconds(200)
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            guard host.isWanted() else { return false }
            if !host.isConnecting() {
                guard host.isConnected() else { return false }
                await host.synchronize()
                if host.isReady() { return true }
            }
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: step)
        }
    }
}
