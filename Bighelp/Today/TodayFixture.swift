#if DEBUG
import SwiftUI

/// Today alone on made-up data, behind `-test-today-home`, before the shell shows it.
/// Three made-up bots read their boards from the demo's board client; Needs you and a share wait.
struct TodayFixture: View {
    static let launchArgument = "-test-today-home"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    private struct SeeAll: Hashable {
        let kind: AgentBoardItem.Kind
        let agentID: String?
    }

    @State private var shellBoard = AgentBoardStore()
    @State private var boards = TodayBoardsStore()
    @State private var layout = TodayPanelLayoutStore(
        defaults: UserDefaults(suiteName: "bighelp.today.fixture") ?? .standard)
    @State private var isEditing = false
    @State private var path: [SeeAll] = []

    private static let bots = [
        SimpleBotsBot(id: "mina", profileID: "mina", name: "Mina", role: "Travel", isDefault: true),
        SimpleBotsBot(id: "avery", profileID: "avery", name: "Avery", role: "Money"),
        SimpleBotsBot(id: "jordan", profileID: "jordan", name: "Jordan", role: "Home"),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            TodayView(context: context)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: SeeAll.self) { seeAll in
                    TodayBoardPage(context: boardsContext, kind: seeAll.kind, agentID: seeAll.agentID,
                                   makeBoardContext: boardContext,
                                   shellBoardKey: {
                                       RootShellView.AgentBoardClientKey(
                                           owner: nil, board: .available, feedback: true, goalCategories: true,
                                           files: false, answers: true, today: true, todayDetail: true,
                                           fixtures: true, reconnects: false)
                                   },
                                   configureShellBoard: { _ in }, onBack: { path.removeLast() })
                }
        }
        .task { await shellBoard.connect(client: DemoAgentBoardClient(), scope: "today-fixture") }
    }

    private var context: TodayContext {
        TodayContext(
            header: AnyView(header),
            needsYou: TodayNeedsYouSummary(count: 3, agentID: "mina", botName: "Mina",
                                           line: "Book the 7:40 AM flight for $412?"),
            onOpenNeedsYou: {},
            pendingShares: TodayPendingShares(count: 1, open: {}),
            panels: [TodayBoardsPanel.descriptor],
            makePanel: { descriptor in
                AnyView(TodayBoardsPanel(context: boardsContext, size: descriptor.size))
            },
            layout: layout,
            isEditing: $isEditing)
    }

    private var boardsContext: TodayBoardsContext {
        TodayBoardsContext(store: boards, bots: Self.bots, shellBoard: shellBoard,
                           onOpenItem: { _, _ in },
                           onSeeAll: { kind, agentID in path.append(SeeAll(kind: kind, agentID: agentID)) },
                           onAsk: { _, _ in })
    }

    private func boardContext(_ bot: SimpleBotsBot, _ store: AgentBoardStore) -> AgentBoardContext {
        AgentBoardContext(agentID: bot.profileID, agentName: bot.name, imageURL: nil, activity: .idle, store: store,
                          onProfile: {}, onSwitchAgent: {}, onAsk: { _ in }, onSend: { _ in }, onBlueprint: { _ in })
    }

    private var header: some View {
        HStack {
            Text("Today")
                .font(.bighelp(.title2, weight: .bold))
            Spacer()
            TodayEditButton(isEditing: $isEditing)
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
    }
}
#endif
