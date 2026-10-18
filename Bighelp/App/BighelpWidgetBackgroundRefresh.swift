#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
import WidgetKit

/// Keeps the widgets current while bighelp is closed. iOS wakes the app now and then (Background App
/// Refresh, at times it picks); the app connects to the computer in use the way Shortcuts do, lets the
/// widgets' data publish, and lets go. Only while a bighelp widget is on this device.
@MainActor
enum BighelpWidgetBackgroundRefresh {
    nonisolated static let identifier = "app.loopdy.mobile.widget-refresh"
    /// The soonest iOS may wake the app again; it often waits longer.
    nonisolated static let interval: TimeInterval = 20 * 60
    private static var refresh: (@MainActor () async -> Void)?

    /// Before launch finishes, as iOS requires.
    static func register(_ refresh: @escaping @MainActor () async -> Void) {
        Self.refresh = refresh
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: handle)
    }

    /// BackgroundTasks calls this on its own queue.
    nonisolated private static func handle(_ task: BGTask) {
        nonisolated(unsafe) let task = task
        let work = Task { @MainActor in
            scheduleIfWidgets()
            await refresh?()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Asks iOS for the next wake, if any bighelp widget is on this device.
    nonisolated static func scheduleIfWidgets() {
        WidgetCenter.shared.getCurrentConfigurations { @Sendable result in
            guard !((try? result.get()) ?? []).isEmpty else { return }
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
            try? BGTaskScheduler.shared.submit(request)
        }
    }
}
#endif
