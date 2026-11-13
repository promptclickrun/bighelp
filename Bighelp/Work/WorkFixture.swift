#if DEBUG
import SwiftUI

/// Work alone on made-up data, before the shell shows it: launch with `-test-work-screen`
/// (add `-test-work-project` for Work filtered to a project). Nothing here reaches a computer.
enum WorkFixture {
    static let launchArgument = "-test-work-screen"
    static let projectArgument = "-test-work-project"
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    static let projectID = "demo-app"

    @MainActor
    static func view() -> some View {
        WorkFixtureView(filtered: ProcessInfo.processInfo.arguments.contains(projectArgument))
    }

    @MainActor
    static func sources(now: Date = .now) -> WorkSources {
        var sources = WorkSources(now: now)
        sources.botNames = ["avery": "Avery", "jordan": "Jordan"]
        sources.codeSessions = [
            WorkCodeSession(record: session("s1", "Fix the widget tap when asleep", branch: "fix-widget-tap",
                                            startedAt: now.addingTimeInterval(-600)),
                            status: .running("Running the tests")),
            WorkCodeSession(record: session("s2", "Tighten the Usage chart", branch: "tighten-usage-chart",
                                            startedAt: now.addingTimeInterval(-7_200)),
                            status: .ready,
                            pullRequest: StockGitPullRequest(number: 128, branch: "tighten-usage-chart",
                                                             title: "Tighten the Usage chart",
                                                             url: URL(string: "https://example.com/pull/128")!,
                                                             state: "open", isDraft: false)),
        ]
        sources.background = ["jordan": BotBackgroundWork(count: 1, title: "Compare three plumbers")]
        sources.workflowsWaiting = [
            WorkflowRunSummary(id: "run-1", number: 4, workflowID: "monthly", workflowName: "Monthly report",
                               revision: 1, state: .waitingForYou, stageKey: "review", stageTitle: "Review",
                               stageState: .waitingForYou, stagesDone: 2, stageCount: 4,
                               startedAt: now.addingTimeInterval(-3_600), updatedAt: now.addingTimeInterval(-300),
                               waiting: .init(kind: "signoff", stageKey: "review", since: now.addingTimeInterval(-300)),
                               version: 1),
        ]
        sources.tasks = [
            DemoKanbanService.task("t1", "Draft the trip budget", status: .done, assignee: "avery", priority: 0,
                                   createdAt: now.addingTimeInterval(-86_400),
                                   completedAt: now.addingTimeInterval(-10_800)),
        ]
        sources.schedules = [
            ScheduledTask(id: "brief", agentID: "avery", name: "Morning brief", instructions: "",
                          schedule: .naturalLanguage("every weekday at 7", timeZoneID: "UTC"),
                          scheduleDescription: "Every weekday", nextRun: now.addingTimeInterval(36_000),
                          status: .active, lastResult: nil),
        ]
        return sources
    }

    private static func session(_ id: String, _ title: String, branch: String, startedAt: Date) -> CodeSessionRecord {
        CodeSessionRecord(id: id, agentID: "avery", projectID: projectID, projectName: "demo-app", title: title,
                          folder: "/work/demo-app/.worktrees/\(branch)", branch: branch, placement: .newWorktree,
                          startedAt: startedAt)
    }
}

private struct WorkFixtureView: View {
    let filtered: Bool
    @State private var filter: WorkFilter = .all

    var body: some View {
        let header = HomeHeaderBar(context: HomeHeaderContext(
            personName: "Sam", personImageURL: nil, onOpenSettings: {},
            title: filtered ? "demo-app" : String(localized: "Work"),
            trailing: filtered ? AnyView(WorkProjectMenu(actions: WorkProjectActions(
                onPullRequests: {}, onWorktrees: {}, onDevFactory: {}, openPullRequests: 1))) : nil))
        WorkList(context: WorkContext(
            header: AnyView(header), projectID: filtered ? WorkFixture.projectID : nil, onOpen: { _ in },
            doors: WorkDoor.Kind.allCases.map { kind in
                WorkDoor(kind: kind, count: kind == .schedules ? 1 : kind == .projects ? 1 : nil, open: {})
            },
            onRefresh: {}),
                 items: WorkProjection.items(WorkFixture.sources()), filter: $filter)
            .toolbar(.hidden, for: .navigationBar)
    }
}
#endif
