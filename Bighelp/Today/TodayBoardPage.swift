import SwiftUI

/// See all from Today's boards panel: a row of bot chips (All bots first) over that kind's board.
/// All bots lists every bot's items newest first; one bot shows its own full board (`AgentFeedView`,
/// `AgentIdeasView`, `AgentGoalsView`) from a store of this page's that follows the shell's connection,
/// so the shell's board, which the widgets publish, stays on its own bot.
struct TodayBoardPage: View {
    let context: TodayBoardsContext
    let kind: AgentBoardItem.Kind
    /// The board for one bot, as the shell builds it for a bot's Dashboard. Its header buttons are
    /// this page's, so the shell turns the board's own off.
    let makeBoardContext: (SimpleBotsBot, AgentBoardStore) -> AgentBoardContext
    let onBack: () -> Void
    /// The bot picked; nil is All bots.
    @State private var agentID: String?
    @State private var store = AgentBoardStore()

    init(context: TodayBoardsContext, kind: AgentBoardItem.Kind, agentID: String? = nil,
         makeBoardContext: @escaping (SimpleBotsBot, AgentBoardStore) -> AgentBoardContext,
         onBack: @escaping () -> Void) {
        self.context = context
        self.kind = kind
        self.makeBoardContext = makeBoardContext
        self.onBack = onBack
        _agentID = State(initialValue: agentID)
    }

    var body: some View {
        Group {
            if let bot = agentID.flatMap({ context.bot($0) }) {
                board(for: bot)
                    .id(bot.id)
                    .task(id: TodayBoardFollowKey(agentID: bot.profileID, shell: context.shellBoard)) {
                        await follow(bot.profileID)
                    }
            } else {
                TodayBoardAllBots(context: context, kind: kind)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(theme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.board-page")
    }

    @ViewBuilder
    private func board(for bot: SimpleBotsBot) -> some View {
        let boardContext = makeBoardContext(bot, store)
        switch kind {
        case .feed: AgentFeedView(context: boardContext)
        case .idea: AgentIdeasView(context: boardContext)
        case .goal: AgentGoalsView(context: boardContext)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.bighelp(.title3, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(Rectangle())
                }
                .bighelpPlainButtonStyle()
                .accessibilityLabel("Back")
                .accessibilityIdentifier("today.board-page.back")
                Text(kind.todayTitle)
                    .font(.bighelp(.headline, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BighelpTokens.space8)
            chips
        }
        .padding(.bottom, BighelpTokens.space8)
        .background(theme.canvas.ignoresSafeArea(edges: .top))
    }

    /// One row that scrolls sideways, never two.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BighelpTokens.space8) {
                BoardFilterChip(title: String(localized: "All bots"), isSelected: agentID == nil) { agentID = nil }
                    .accessibilityIdentifier("today.board-page.chip.all")
                ForEach(context.localBots) { bot in
                    BoardFilterChip(title: bot.name, isSelected: agentID == bot.profileID) { agentID = bot.profileID }
                        .accessibilityIdentifier("today.board-page.chip.\(bot.profileID)")
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.board-page.chips")
    }

    /// Uses the shell's connection: the same computer and client, this bot's board.
    private func follow(_ agentID: String) async {
        let shell = context.shellBoard
        if let connection = shell.followableConnection {
            await store.connect(client: connection.client, scope: connection.scope)
            if store.agentID != agentID || store.state == .idle { await store.load(agentID: agentID) }
        } else if shell.isWaitingForConnection {
            store.waitForConnection()
            await store.load(agentID: agentID)
        } else {
            store.configure(client: nil, isDisconnected: shell.isDisconnected)
        }
    }

    @BighelpThemeReader private var theme
}

/// What following the shell's board depends on.
private struct TodayBoardFollowKey: Equatable {
    let agentID: String
    let client: ObjectIdentifier?
    let waiting: Bool
    let disconnected: Bool

    @MainActor
    init(agentID: String, shell: AgentBoardStore) {
        self.agentID = agentID
        client = shell.followableConnection.map { ObjectIdentifier($0.client) }
        waiting = shell.isWaitingForConnection
        disconnected = shell.isDisconnected
    }
}

/// All bots: every bot's items of one kind, newest first, from `TodayBoardsStore`.
private struct TodayBoardAllBots: View {
    let context: TodayBoardsContext
    let kind: AgentBoardItem.Kind

    var body: some View {
        let entries = context.store.entries(kind, agentIDs: context.localBots.map(\.profileID))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BighelpTokens.space12) {
                if entries.isEmpty {
                    Text(context.store.hasRead ? kind.todayEmptyPage : String(localized: "Your computer isn't connected."))
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("today.board-page.empty")
                }
                ForEach(entries) { entry in
                    TodayBoardsRow(entry: entry, bot: context.bot(entry.agentID),
                                   showsUnread: context.store.tracksUnread) {
                        context.onOpenItem(entry.agentID, entry.item)
                    }
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space8)
            .frame(maxWidth: ChatCanvasLayout.regularLaneMaximumWidth)
            .frame(maxWidth: .infinity)
        }
        .task { await TodayBoardsReading.refresh(context) }
        .bighelpRefreshable { await TodayBoardsReading.refresh(context, force: true) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.board-page.all")
    }

    @BighelpThemeReader private var theme
}

private extension AgentBoardItem.Kind {
    var todayEmptyPage: String {
        switch self {
        case .feed: String(localized: "No posts from any bot yet.")
        case .idea: String(localized: "No ideas from any bot yet.")
        case .goal: String(localized: "No goals from any bot yet.")
        }
    }
}
