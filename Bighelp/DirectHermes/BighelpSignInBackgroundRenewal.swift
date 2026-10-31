#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
import UIKit

/// Keeps browser sign-ins (the Nous Portal's lasts a day) alive while bighelp stays closed. iOS wakes
/// the app now and then (Background App Refresh, at times it picks); each wake renews every saved
/// computer whose access token would run out before the next likely wake, then asks for the next one.
/// It needs no widget. The host's quiet "renew sign-in" push does the same job when it arrives.
@MainActor
enum BighelpSignInBackgroundRenewal {
    nonisolated static let identifier = "app.loopdy.mobile.sign-in-renewal"
    /// The soonest iOS may wake the app again; it often waits longer. Also how far ahead a wake
    /// looks: a token that outlasts it waits for a later wake.
    nonisolated static let interval: TimeInterval = 4 * 60 * 60
    private static var registry: BighelpHostRegistry?

    /// Before launch finishes, as iOS requires. Going to the background asks for the next wake.
    static func register(registry: BighelpHostRegistry) {
        Self.registry = registry
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: handle)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { scheduleIfNeeded() }
        }
    }

    /// BackgroundTasks calls this on its own queue. When iOS's time runs out the task is reported done
    /// at once, not when the renewal on its way times out; a renewal cut off keeps its token anyway.
    nonisolated private static func handle(_ task: BGTask) {
        nonisolated(unsafe) let task = task
        let completion = BackgroundTaskCompletion(task)
        let work = Task { @MainActor in
            scheduleIfNeeded()
            if let registry { await renew(registry, deadline: Date(timeIntervalSinceNow: interval)) }
            completion.finish(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
            completion.finish(success: false)
        }
    }


    /// Renews each computer that isn't connected and whose access token ends before `deadline`.
    static func renew(_ registry: BighelpHostRegistry, deadline: Date) async {
        for host in registry.hosts {
            guard !Task.isCancelled else { return }
            _ = await registry.workspace(for: host).renewSignInWhileAway(before: deadline)
        }
    }

    /// Asks iOS for the next wake, if any saved computer has a sign-in that needs renewing.
    static func scheduleIfNeeded() {
        guard let registry,
              registry.hosts.contains(where: { registry.workspace(for: $0).hasRenewableSignIn }) else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }
}
/// Reports a background task done exactly once, from whichever side finishes first: the work, or
/// iOS's time running out (then at once, not when the work on its way stops).
final class BackgroundTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var finished = false
    init(_ task: BGTask) { self.task = task }

    func finish(success: Bool) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        if first { task.setTaskCompleted(success: success) }
    }
}
#endif
