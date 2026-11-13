import SwiftUI

/// What Work needs from the shell, for the computer in use. A store that's nil (its page was never
/// made, or the computer lacks the feature) just gives no rows of its kind.
@MainActor
struct WorkContext {
    /// The home header (`HomeHeaderBar`), drawn on top; nil on a pushed page that has its own.
    let header: AnyView?
    /// Work filtered to a project: what Code home shows for that project.
    var projectID: String? = nil
    var code: CodeHomeStore? = nil
    var codeStatus: (any CodeSessionStatusReading)? = nil
    var dashboard: DashboardModel? = nil
    /// Bots' background work, kept current while Work shows.
    var activity: BotChatActivityStore? = nil
    var activitySource: BotChatActivitySource? = nil
    var workflows: WorkflowsStore? = nil
    var kanban: KanbanBoardModel? = nil
    var schedules: ScheduledTasksStore? = nil
    /// Bot names for the rows.
    var agents: AgentDirectoryStore? = nil
    let onOpen: (WorkTarget) -> Void
    /// Projects, Tasks, Workflows, Schedules: only the ones this computer can open.
    var doors: [WorkDoor] = []
    /// Work filtered to a project; the shell puts `WorkProjectMenu(actions:)` in the header.
    var projectActions: WorkProjectActions? = nil
    /// Reads every store again (pull to refresh, and each time Work shows on a new connection).
    let onRefresh: () async -> Void
    /// Changes with each connection to the computer, so Work reads again once it's up.
    var connectionKey: String? = nil
}

/// The Work tab: what the bots are doing on the computer in use, newest first, in Code home's cards,
/// with the four boards one tap down.
struct WorkView: View {
    let context: WorkContext
    @State private var filter: WorkFilter = .all
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Read in the body, so every store it touches is observed.
        let items = WorkProjection.items(WorkSources(context: context))
        WorkList(context: context, items: items, isLoading: isLoading, filter: $filter)
            .botChatActivityUpdates(context.activity, source: context.activitySource,
                                    isActive: scenePhase == .active)
            .task(id: context.connectionKey) { await refresh() }
    }

    private func refresh() async {
        await context.onRefresh()
    }

    /// A first read still under way: the list draws a still placeholder, not the empty state.
    private var isLoading: Bool {
        context.code?.isLoading == true || context.dashboard?.state == .loading
            || context.workflows?.state == .loading || context.schedules?.loadState == .loading
    }
}

/// Work's list, given its rows. `WorkView` reads them from the stores; the fixture hands in samples.
struct WorkList: View {
    let context: WorkContext
    let items: [WorkItem]
    var isLoading = false
    @Binding var filter: WorkFilter

    var body: some View {
        let projectItems = WorkProjection.visible(items, filter: .all, projectID: context.projectID)
        let shown = WorkProjection.visible(items, filter: filter, projectID: context.projectID)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BighelpTokens.space12) {
                WorkFilterChips(filter: $filter, counts: WorkProjection.counts(items, projectID: context.projectID))
                if projectItems.isEmpty {
                    if isLoading { WorkLoadingPlaceholder() } else { empty }
                } else if shown.isEmpty {
                    emptyFilter
                }
                ForEach(shown) { item in
                    WorkItemCard(item: item, onOpen: context.onOpen, code: context.code)
                }
                if context.projectID == nil, !context.doors.isEmpty {
                    WorkDoorsSection(doors: context.doors)
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space4)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .bighelpRefreshable { await refresh() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let header = context.header { header }
        }
        .background(theme.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.screen")
    }

    private func refresh() async {
        await context.onRefresh()
    }

    private var empty: some View {
        VStack(spacing: BighelpTokens.space8) {
            Text("Nothing in progress")
                .font(.bighelp(.title3).weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text("Start a coding session from New chat.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, BighelpTokens.space32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("work.empty")
    }

    private var emptyFilter: some View {
        Group {
            switch filter {
            case .needsYou: Text("Nothing needs you")
            case .working: Text("Nothing working")
            case .done, .all: Text("Nothing done yet")
            }
        }
        .font(.bighelp(.subheadline))
        .foregroundStyle(theme.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, BighelpTokens.space24)
        .accessibilityIdentifier("work.empty-filter")
    }

    @BighelpThemeReader private var theme
}

/// Three still cards while the first read is under way: no loop runs.
private struct WorkLoadingPlaceholder: View {
    var body: some View {
        VStack(spacing: BighelpTokens.space12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                    .fill(theme.surface)
                    .frame(height: BighelpTokens.scaled(92))
                    .overlay {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                            .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                    }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
        .accessibilityIdentifier("work.loading")
    }

    @BighelpThemeReader private var theme
}
