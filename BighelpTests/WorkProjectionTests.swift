import Foundation
import Testing
@testable import Bighelp

@MainActor
struct WorkProjectionTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func session(_ id: String, project: String = "app", startedAt: TimeInterval = -60,
                         batchID: UUID? = nil) -> CodeSessionRecord {
        CodeSessionRecord(id: id, agentID: "a", projectID: project, projectName: project, title: "Session \(id)",
                          folder: "/work/\(project)", branch: "b-\(id)", placement: .newWorktree,
                          startedAt: now.addingTimeInterval(startedAt), batchID: batchID)
    }

    private func run(_ id: String, state: WorkflowRunState, updated: TimeInterval = -60) -> WorkflowRunSummary {
        WorkflowRunSummary(id: id, number: 1, workflowID: "w", workflowName: "Run \(id)", revision: nil,
                           state: state, stageKey: nil, stageTitle: nil, stageState: nil, stagesDone: 1,
                           stageCount: 3, startedAt: nil, updatedAt: now.addingTimeInterval(updated), version: 1)
    }

    private func task(_ id: String, _ status: HermesKanbanTaskStatus, project: String? = nil) -> HermesKanbanTask {
        let base = DemoKanbanService.task(id, "Task \(id)", status: status, assignee: "a", priority: 0,
                                          createdAt: now.addingTimeInterval(-120))
        guard let project else { return base }
        return HermesKanbanTask(
            id: base.id, title: base.title, body: nil, assignee: base.assignee, status: status, priority: 0,
            createdBy: nil, createdAt: base.createdAt, startedAt: nil, completedAt: nil, tenant: nil,
            workspaceKind: "scratch", workspacePath: nil, branchName: nil, projectID: project, result: nil,
            idempotencyKey: nil, latestSummary: nil, currentRunID: nil, workerPID: nil, lastHeartbeatAt: nil,
            maxRuntimeSeconds: nil, modelOverride: nil, providerOverride: nil, reasoningEffort: nil,
            workflowTemplateID: nil, currentStepKey: nil, skills: nil, maximumRetries: nil, consecutiveFailures: 0,
            goalMode: false, goalMaximumTurns: nil, completionContract: nil, blockKind: nil, blockRecurrences: 0,
            childCount: 0, parentCount: 0, commentCount: 0)
    }

    private func schedule(_ id: String, status: ScheduledTaskStatus = .active, lastError: String? = nil,
                          nextRun: TimeInterval? = 3_600) -> ScheduledTask {
        ScheduledTask(id: id, agentID: "a", name: "Schedule \(id)", instructions: "",
                      schedule: .naturalLanguage("daily", timeZoneID: "UTC"), scheduleDescription: "Every day",
                      nextRun: nextRun.map { now.addingTimeInterval($0) }, status: status, lastResult: nil,
                      lastError: lastError)
    }

    private func bucket(_ items: [WorkItem], _ id: String) -> WorkBucket? {
        items.first { $0.id == id }?.bucket
    }

    @Test func eachKindLandsInItsBucket() {
        var sources = WorkSources(now: now)
        sources.codeSessions = [
            WorkCodeSession(record: session("ask"), status: .needsYou("Approve a command")),
            WorkCodeSession(record: session("run"), status: .running(nil)),
            WorkCodeSession(record: session("start"), status: .starting("Setting up")),
            WorkCodeSession(record: session("ready"), status: .ready),
            WorkCodeSession(record: session("fail"), status: .failed("Stopped")),
        ]
        sources.chatWork = [DashboardWorkItem(sessionID: "chat", title: "Plan a trip", subtitle: "Making tool calls")]
        sources.background = ["a": BotBackgroundWork(count: 2, title: "Reconcile statements")]
        sources.workflowsWaiting = [run("wait", state: .waitingForYou)]
        sources.workflowsActive = [run("active", state: .running)]
        sources.workflowsRecent = [run("ok", state: .succeeded), run("still", state: .running)]
        sources.tasks = [task("blocked", .blocked), task("running", .running), task("done", .done),
                         task("ready", .ready), task("todo", .todo)]
        sources.schedules = [schedule("upcoming"), schedule("broken", lastError: "Timed out")]

        let items = WorkProjection.items(sources)
        #expect(bucket(items, "coding:ask") == .needsYou)
        #expect(bucket(items, "coding:run") == .working)
        #expect(bucket(items, "coding:start") == .working)
        #expect(bucket(items, "coding:ready") == .done)
        #expect(bucket(items, "coding:fail") == .done)
        #expect(bucket(items, "chat:chat") == .working)
        #expect(bucket(items, "background:a") == .working)
        #expect(bucket(items, "workflow:wait") == .needsYou)
        #expect(bucket(items, "workflow:active") == .working)
        #expect(bucket(items, "workflow:ok") == .done)
        #expect(bucket(items, "workflow:still") == nil, "A recent run that hasn't finished isn't done")
        #expect(bucket(items, "task:blocked") == .needsYou)
        #expect(bucket(items, "task:running") == .working)
        #expect(bucket(items, "task:done") == .done)
        #expect(bucket(items, "task:ready") == nil, "Cards waiting to be picked up stay on the board")
        #expect(bucket(items, "task:todo") == nil)
        #expect(items.first { $0.kind == .schedule && $0.title == "Schedule broken" }?.bucket == .needsYou)
    }

    @Test func aScheduledTaskIsNeverWorking() {
        var sources = WorkSources(now: now)
        sources.schedules = ScheduledTaskStatus.allCases.map { schedule($0.rawValue, status: $0) }
            + [schedule("soon", nextRun: 60), schedule("none", nextRun: nil)]
        let items = WorkProjection.items(sources)
        #expect(items.count == sources.schedules.count)
        #expect(items.allSatisfy { $0.bucket != .working })
        #expect(items.filter { $0.bucket == .needsYou }.map(\.title) == ["Schedule failed"])
        #expect(WorkProjection.visible(items, filter: .working, projectID: nil).isEmpty)
    }

    @Test func chipsCountAndFilterTheirBuckets() {
        var sources = WorkSources(now: now)
        sources.codeSessions = [
            WorkCodeSession(record: session("ask"), status: .needsYou("Answer a question")),
            WorkCodeSession(record: session("run"), status: .running("Editing")),
            WorkCodeSession(record: session("ready"), status: .ready),
        ]
        sources.schedules = [schedule("upcoming")]
        let items = WorkProjection.items(sources)
        let counts = WorkProjection.counts(items, projectID: nil)
        #expect(counts == [.all: 4, .needsYou: 1, .working: 1, .done: 1])
        #expect(WorkProjection.visible(items, filter: .needsYou, projectID: nil).map(\.id) == ["coding:ask"])
        #expect(WorkProjection.visible(items, filter: .done, projectID: nil).map(\.id) == ["coding:ready"])
        #expect(WorkProjection.visible(items, filter: .all, projectID: nil).contains { $0.bucket == .upcoming },
                "Upcoming scheduled tasks show under All only")
    }

    @Test func aProjectShowsOnlyItsOwnWork() {
        var sources = WorkSources(now: now)
        sources.codeSessions = [
            WorkCodeSession(record: session("mine", project: "app"), status: .running(nil)),
            WorkCodeSession(record: session("other", project: "site"), status: .running(nil)),
        ]
        sources.tasks = [task("card", .running, project: "app"), task("loose", .running)]
        sources.schedules = [schedule("daily")]
        sources.chatWork = [DashboardWorkItem(sessionID: "chat", title: "Chat", subtitle: "Working")]
        let items = WorkProjection.items(sources)
        let shown = WorkProjection.visible(items, filter: .all, projectID: "app")
        #expect(Set(shown.map(\.id)) == ["coding:mine", "task:card"])
        #expect(WorkProjection.counts(items, projectID: "app")[.all] == 2)
        #expect(WorkProjection.visible(items, filter: .all, projectID: nil).count == 6)
    }

    @Test func newestActivityComesFirstAndUpcomingGoesLast() {
        var sources = WorkSources(now: now)
        sources.codeSessions = [
            WorkCodeSession(record: session("old", startedAt: -7_200), status: .ready),
            WorkCodeSession(record: session("new", startedAt: -60), status: .ready),
        ]
        sources.workflowsWaiting = [run("mid", state: .waitingForYou, updated: -600)]
        // Running now, with no time from its store: counts as now.
        sources.chatWork = [DashboardWorkItem(sessionID: "live", title: "Live", subtitle: "Working")]
        sources.schedules = [schedule("later", nextRun: 7_200), schedule("sooner", nextRun: 600)]
        let ids = WorkProjection.items(sources).map(\.id)
        let scheduleIDs = WorkProjection.items(sources).filter { $0.kind == .schedule }.map(\.title)
        #expect(Array(ids.prefix(4)) == ["chat:live", "coding:new", "workflow:mid", "coding:old"])
        #expect(scheduleIDs == ["Schedule sooner", "Schedule later"])
        #expect(ids.count == 6)
    }

    @Test func aCodeSessionIsNotListedTwiceAsChatWork() {
        var sources = WorkSources(now: now)
        sources.codeSessions = [WorkCodeSession(record: session("s1"), status: .running(nil))]
        sources.chatWork = [DashboardWorkItem(sessionID: "s1", title: "Session s1", subtitle: "Working")]
        #expect(WorkProjection.items(sources).map(\.id) == ["coding:s1"])
    }

    @Test func aBatchNeedsYouWhenAnyOfItsSessionsDoes() {
        let batch = CodeBatch(id: UUID(), projectID: "app", title: "Batch", createdAt: now, jobCount: 2,
                              sessionIDs: ["x", "y"], messages: [])
        var sources = WorkSources(now: now)
        sources.codeBatches = [WorkCodeBatch(batch: batch, lines: [
            WorkBatchLine(id: "x", title: "X", index: 0, status: .running(nil)),
            WorkBatchLine(id: "y", title: "Y", index: 1, status: .needsYou("Approve a command")),
        ], startedCount: 2)]
        #expect(WorkProjection.items(sources).first?.bucket == .needsYou)
    }

    @Test func storesThatAreNilGiveNoRows() {
        let context = WorkContext(header: nil, onOpen: { _ in }, onRefresh: {})
        let sources = WorkSources(context: context, now: now)
        #expect(WorkProjection.items(sources).isEmpty)
    }
}
