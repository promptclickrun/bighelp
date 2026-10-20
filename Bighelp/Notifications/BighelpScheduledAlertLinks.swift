import Foundation

/// Where a tapped scheduled task alert goes.
///
/// A scheduled run happens in a session of its own that no chat list shows. A host that knows
/// where the job was made (the bighelp plugin's `scheduled_links.py`) names that chat as
/// `scheduled.chat.<session>`, or the job itself as `scheduled.job.<job>`, hashed with the agent
/// like any chat. It does so only for phones that asked (`scheduledLinks` in this phone's
/// preferences on the host). These names never equal a chat's own reference, so a scheduled alert
/// is never taken for a reply in the chat it names: that chat doesn't show the run's text.
enum BighelpScheduledAlertLinks {
    static let chatPrefix = "scheduled.chat."
    static let jobPrefix = "scheduled.job."

    enum Place: Equatable {
        /// The chat the job was made in, or (from an older plugin) the run's own session.
        case chat(SessionRecord)
        /// The job, in Scheduled tasks.
        case task(ScheduledTask)
        /// The agent's Scheduled tasks: the job is gone, or the alert named a run the phone can't find.
        case tasks(agentID: String)
    }

    static func isScheduledRun(_ eventType: String?) -> Bool {
        eventType == "scheduled.completed" || eventType == "scheduled.failed"
    }

    /// The saved one-agent chat a scheduled alert names.
    static func chat(reference: String, profileID: String, in records: [SessionRecord]) -> SessionRecord? {
        let matches = records.filter { record in
            record.kind == .direct && record.agentIDs == [profileID]
                && record.remoteStoredID.map {
                    ManagedNotificationValidation.sessionReference(profile: profileID, session: chatPrefix + $0) == reference
                } == true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The agent's job a scheduled alert names.
    static func task(reference: String, profileID: String, in tasks: [ScheduledTask]) -> ScheduledTask? {
        let matches = tasks.filter { task in
            task.agentID.utf8.elementsEqual(profileID.utf8)
                && ManagedNotificationValidation.sessionReference(profile: profileID, session: jobPrefix + task.id) == reference
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Where an alert's reference leads, from what the phone has. Any alert opens a chat it names.
    /// A scheduled run's alert also opens its job and, once the agent's tasks are known (`tasks`
    /// isn't nil) and nothing matched, that agent's Scheduled tasks. Nil: nothing yet.
    static func place(reference: String, profileID: String, records: [SessionRecord],
                      tasks: [ScheduledTask]?, isScheduledRun: Bool) -> Place? {
        if let record = SessionRecord.matching(reference: reference, profileID: profileID, in: records) {
            return .chat(record)
        }
        guard isScheduledRun else { return nil }
        if let record = chat(reference: reference, profileID: profileID, in: records) { return .chat(record) }
        guard let tasks else { return nil }
        if let task = task(reference: reference, profileID: profileID, in: tasks) { return .task(task) }
        return .tasks(agentID: profileID)
    }
}
