import SwiftUI

/// What the Feed, Ideas and Goals panel and its See all page need from the shell.
@MainActor
struct TodayBoardsContext {
    let store: TodayBoardsStore
    /// The bots on the computer in use, in the order the home shows them.
    let bots: [SimpleBotsBot]
    /// The shell's board (`RootShellView.agentBoard`): its connection is the one read here, and
    /// See all's board for one bot follows it.
    let shellBoard: AgentBoardStore
    /// Opens an item in full, by its bot's profile ID.
    let onOpenItem: (String, AgentBoardItem) -> Void
    /// See all: the kind, and the bot picked (nil for all bots). The shell pushes `TodayBoardPage`.
    let onSeeAll: (AgentBoardItem.Kind, String?) -> Void
    /// Opens a chat with a bot (by profile ID) with the text in its message box. Nothing is sent.
    let onAsk: (String, String) -> Void

    /// Bots on the computer in use (with every computer shown, the others' bots are left out:
    /// their boards aren't read here).
    var localBots: [SimpleBotsBot] { bots.filter { $0.fleetAgent == nil || $0.isOnGatewayInUse } }

    func bot(_ agentID: String) -> SimpleBotsBot? { localBots.first { $0.profileID == agentID } }
}

extension AgentBoardItem.Kind {
    /// The panel's and See all's name for it.
    var todayTitle: String {
        switch self {
        case .feed: String(localized: "Feed")
        case .idea: String(localized: "Ideas")
        case .goal: String(localized: "Goals")
        }
    }

    fileprivate var emptyLine: String {
        switch self {
        case .feed: String(localized: "Nothing yet. Ask a bot for posts.")
        case .idea: String(localized: "Nothing yet. Ask a bot for ideas.")
        case .goal: String(localized: "Nothing yet. Ask a bot for a goal.")
        }
    }

    /// What Ask leaves in the message box, as the bot's own empty board words it.
    fileprivate var askText: String {
        switch self {
        case .feed: String(localized: "Every evening, post the top three AI stories to my feed.")
        case .idea: String(localized: "Look through my week and suggest a few things you could take off my plate.")
        case .goal: String(localized: "Help me set one goal for this month, and track it on my Goals.")
        }
    }
}

/// Today's built-in panel: the newest Feed posts, ideas or goals across bots, each with its bot.
struct TodayBoardsPanel: View {
    static let kind = "boards"
    /// Its place on Today, Tall to start with.
    static var descriptor: TodayPanelDescriptor {
        TodayPanelDescriptor(id: "today.boards", kind: kind, title: String(localized: "Feed, Ideas, Goals"), size: .tall)
    }

    let context: TodayBoardsContext
    let size: TodayPanelSize
    @State private var kind: AgentBoardItem.Kind = .feed
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let entries = context.store.entries(kind, agentIDs: context.localBots.map(\.profileID))
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Picker("Board", selection: $kind) {
                ForEach([AgentBoardItem.Kind.feed, .idea, .goal], id: \.self) { kind in
                    Text(kind.todayTitle).tag(kind)
                }
            }
            .labelsHidden()
            .bighelpSegmentedPicker()
            .accessibilityIdentifier("today.boards.kind")

            content(entries)

            if !entries.isEmpty {
                Button {
                    context.onSeeAll(kind, nil)
                } label: {
                    Text("See all")
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(Rectangle())
                }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("today.boards.see-all")
            }
        }
        .task(id: TodayBoardsReadKey(context: context, isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await TodayBoardsReading.refresh(context)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.boards")
    }

    @ViewBuilder
    private func content(_ entries: [TodayBoardsEntry]) -> some View {
        let store = context.store
        if entries.isEmpty {
            if !store.hasRead {
                if store.isReading || context.shellBoard.followableConnection != nil {
                    TodayBoardsPlaceholder(rows: rowLimit)
                } else {
                    Text("Your computer isn't connected.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("today.boards.offline")
                }
            } else {
                empty
            }
        } else {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                ForEach(entries.prefix(rowLimit)) { entry in
                    TodayBoardsRow(entry: entry, bot: context.bot(entry.agentID),
                                   showsUnread: store.tracksUnread, compact: size == .small) {
                        context.onOpenItem(entry.agentID, entry.item)
                    }
                }
            }
        }
    }

    /// One sentence and Ask: boards start empty, and nothing runs until the person asks.
    @ViewBuilder
    private var empty: some View {
        let bot = context.localBots.first { !$0.isHidden } ?? context.localBots.first
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(kind.emptyLine)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let bot {
                Button {
                    context.onAsk(bot.profileID, kind.askText)
                } label: {
                    Text("Ask \(bot.name)")
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(Rectangle())
                }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("today.boards.ask")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.boards.empty")
    }

    private var rowLimit: Int {
        switch size {
        case .small: 2
        case .wide: 3
        case .tall: 6
        }
    }

    @BighelpThemeReader private var theme
}

/// What a read depends on: the computer, its connection and the bots on it.
private struct TodayBoardsReadKey: Equatable {
    let scope: String?
    let client: ObjectIdentifier?
    let bots: [String]
    let isActive: Bool

    @MainActor
    init(context: TodayBoardsContext, isActive: Bool) {
        let connection = context.shellBoard.followableConnection
        scope = connection?.scope
        client = connection.map { ObjectIdentifier($0.client) }
        bots = context.localBots.map(\.profileID)
        self.isActive = isActive
    }
}

@MainActor
enum TodayBoardsReading {
    /// Reads the boards on the shell's connection; nothing while there is none (what was read stays).
    static func refresh(_ context: TodayBoardsContext, force: Bool = false) async {
        guard let connection = context.shellBoard.followableConnection else { return }
        let bots = context.localBots
        await context.store.refresh(client: connection.client, scope: connection.scope,
                                    botIDs: bots.map(\.profileID),
                                    hiddenIDs: Set(bots.filter(\.isHidden).map(\.profileID)), force: force)
    }
}

/// An item with its bot's face and name, and a dot while it's new.
struct TodayBoardsRow: View {
    let entry: TodayBoardsEntry
    let bot: SimpleBotsBot?
    let showsUnread: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        let item = entry.item
        Button(action: action) {
            HStack(alignment: .top, spacing: BighelpTokens.space8) {
                SimpleBotFace(agentID: entry.agentID, name: bot?.name ?? "", imageURL: bot?.imageURL,
                              size: compact ? 24 : 32)
                VStack(alignment: .leading, spacing: 2) {
                    if let name = bot?.name, !name.isEmpty {
                        Text(name)
                            .font(.bighelp(.caption, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Text(item.title)
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(compact ? 2 : 3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if showsUnread, !item.read {
                    Circle()
                        .fill(theme.action)
                        .frame(width: 8, height: 8)
                        .padding(.top, BighelpTokens.space4)
                        .accessibilityLabel("New")
                }
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("today.boards.item.\(entry.id)")
    }

    @BighelpThemeReader private var theme
}

/// Still rows while the first read runs: no motion.
private struct TodayBoardsPlaceholder: View {
    let rows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: BighelpTokens.space8) {
                    Circle().fill(theme.separator).frame(width: 28, height: 28)
                    RoundedRectangle(cornerRadius: BighelpTokens.radius8, style: .continuous)
                        .fill(theme.separator)
                        .frame(height: 14)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
        .accessibilityIdentifier("today.boards.loading")
    }

    @BighelpThemeReader private var theme
}
