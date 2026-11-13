import SwiftUI

// MARK: - Scheduled task alerts

extension RootShellView {
    /// The scheduled tasks a tapped alert may name, read from the computer; nil when they can't load now.
    func scheduledTasksForAlert() async -> [ScheduledTask]? {
        guard let store = featureStore.scheduledTasks else { return nil }
        await store.load()
        return store.loadState == .loaded ? store.tasks : nil
    }

    /// A tapped scheduled task alert's job, where Scheduled tasks shows it with its runs.
    func openScheduledAlertTask(_ task: ScheduledTask) {
        // The bot's routines open over where the person is, and the task over them.
        performFleetOpen(.task(jobID: task.id, profileID: task.agentID))
    }

    /// A tapped scheduled task alert whose job is gone, or whose job the phone can't find: the
    /// agent's Scheduled tasks, never another chat.
    func openScheduledAlertTasks(agentID: String) {
        performFleetOpen(.routines(profileID: agentID))
    }
}
