import Foundation

@MainActor
final class ScheduledTasksFixtureClient: ScheduledTasksClient {
    private var tasks: [ScheduledTask]
    private let now: Date
    var naturalLanguageFailure = false
    private(set) var lastMutation: ScheduledTaskMutation?

    init(tasks: [ScheduledTask] = ScheduledTasksFixtureClient.defaultTasks, now: Date = .now) {
        self.tasks = tasks
        self.now = now
    }

    func list(agentID: String?) async throws -> [ScheduledTask] {
        if let agentID {
            return tasks.filter { $0.agentID == agentID }
        }
        return tasks
    }

    func deliveryTargets() async throws -> [ScheduledTaskDeliveryTarget] {
        [
            .local,
            ScheduledTaskDeliveryTarget(id: "loopdy", name: "Bighelp", homeTargetSet: true),
            ScheduledTaskDeliveryTarget(id: "slack", name: "Slack", homeTargetSet: false),
        ]
    }

    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask {
        guard !draft.agentID.isEmpty else { throw ScheduledTasksError.agentRequired }
        if case .naturalLanguage = draft.schedule, naturalLanguageFailure {
            throw ScheduledTasksError.unrecognizedDescription
        }
        let task = ScheduledTask(
            id: UUID().uuidString,
            agentID: draft.agentID,
            name: draft.name,
            instructions: draft.instructions,
            schedule: draft.schedule,
            deliveryTarget: draft.deliveryTarget,
            scheduleDescription: try ScheduleRequestBuilder.request(for: draft.schedule),
            nextRun: try? ScheduleRequestBuilder.nextRun(for: draft.schedule, after: now),
            status: .active,
            lastResult: nil
        )
        tasks.append(task)
        lastMutation = ScheduledTaskMutation(id: task.id, agentID: task.agentID)
        return task
    }

    func update(id: String, agentID: String, changes: ScheduledTaskChanges) async throws -> ScheduledTask {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.agentID == agentID }) else {
            throw ScheduledTasksError.taskNotFound
        }
        if case .naturalLanguage = changes.schedule, naturalLanguageFailure {
            throw ScheduledTasksError.unrecognizedDescription
        }
        tasks[index].name = changes.name
        tasks[index].instructions = changes.instructions
        tasks[index].schedule = changes.schedule
        tasks[index].deliveryTarget = changes.deliveryTarget
        tasks[index].scheduleDescription = try ScheduleRequestBuilder.request(for: changes.schedule)
        tasks[index].nextRun = try? ScheduleRequestBuilder.nextRun(for: changes.schedule, after: now)
        lastMutation = ScheduledTaskMutation(id: id, agentID: agentID)
        return tasks[index]
    }

    func setPaused(_ paused: Bool, id: String, agentID: String) async throws -> ScheduledTask {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.agentID == agentID }) else {
            throw ScheduledTasksError.taskNotFound
        }
        tasks[index].status = paused ? .paused : .active
        lastMutation = ScheduledTaskMutation(id: id, agentID: agentID)
        return tasks[index]
    }

    func runNow(id: String, agentID: String) async throws -> ScheduledTask {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.agentID == agentID }) else {
            throw ScheduledTasksError.taskNotFound
        }
        tasks[index].lastResult = "Ran just now"
        if case .once = tasks[index].schedule {
            tasks[index].status = .completed
            tasks[index].nextRun = nil
        } else {
            tasks[index].status = .active
        }
        lastMutation = ScheduledTaskMutation(id: id, agentID: agentID)
        return tasks[index]
    }

    func delete(id: String, agentID: String) async throws {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.agentID == agentID }) else {
            throw ScheduledTasksError.taskNotFound
        }
        tasks.remove(at: index)
        lastMutation = ScheduledTaskMutation(id: id, agentID: agentID)
    }

    static let defaultTasks: [ScheduledTask] = [
        .fixture(
            id: "task-finance-brief",
            agentID: "finance",
            name: "Morning market brief",
            instructions: "Summarize relevant market movement and today’s priorities.",
            nextRun: Date(timeIntervalSinceReferenceDate: 900_000_000),
            lastResult: "Completed yesterday"
        ),
        .fixture(
            id: "task-travel-watch",
            agentID: "travel",
            name: "Trip check-in",
            instructions: "Review upcoming itinerary changes.",
            schedule: .weekly(
                day: .friday,
                time: DateComponents(hour: 15, minute: 0),
                timeZoneID: "America/Chicago"
            ),
            isPaused: true,
            nextRun: Date(timeIntervalSinceReferenceDate: 900_200_000)
        )
    ]
}
