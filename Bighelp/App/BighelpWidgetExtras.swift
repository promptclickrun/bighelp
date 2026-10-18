import Foundation
import Observation

/// What the widgets show beyond chats and tasks: the default agent's latest
/// Feed posts, Ideas and Goals, the boards of agents a widget is set to, pinned
/// agents, and the colors picked in Settings. The shell keeps it current; the widget snapshot
/// publisher reads it.
@MainActor
@Observable
final class BighelpWidgetExtras {
    static let shared = BighelpWidgetExtras()

    var feed: [BighelpWidgetSnapshot.BoardItem] = [] { didSet { markFilled(.board) } }
    var ideas: [BighelpWidgetSnapshot.BoardItem] = [] { didSet { markFilled(.board) } }
    var goals: [BighelpWidgetSnapshot.BoardItem] = [] { didSet { markFilled(.board) } }
    /// Boards of other agents that Feed, Ideas or Goals widgets are set to, by agent.
    var agentBoards: [String: BighelpWidgetSnapshot.AgentBoard] = [:] { didSet { markFilled(.boards) } }
    var lightPalette: BighelpWidgetSnapshot.Palette? { didSet { markFilled(.palettes) } }
    var darkPalette: BighelpWidgetSnapshot.Palette? { didSet { markFilled(.palettes) } }
    /// Pinned agents of the computer in use, and of every computer
    /// (`BighelpPinnedAgentsWidgetFeed`).
    var pinnedAgents: [BighelpWidgetSnapshot.PinnedAgent] = [] { didSet { markFilled(.pins) } }
    var allPinnedAgents: [BighelpWidgetSnapshot.PinnedAgent] = [] { didSet { markFilled(.pins) } }

    /// The parts this run has filled in. A run with no screens (bighelp woken in the background for a
    /// Shortcut, the Watch or a widget refresh) fills few or none, and the widgets keep the rest from
    /// their saved copy instead of losing them.
    enum Part: Hashable { case board, boards, palettes, pins }
    private(set) var filled: Set<Part> = []

    func markFilled(_ part: Part) {
        if !filled.contains(part) { filled.insert(part) }
    }

    func update(board: AgentBoardStore) {
        // A board not read yet says nothing about the agent's posts.
        guard board.state == .loaded || !board.items.isEmpty else { return }
        let board = Self.board(agentID: board.agentID ?? "", items: board.items)
        if board.feed != feed { feed = board.feed }
        if board.ideas != ideas { ideas = board.ideas }
        if board.goals != goals { goals = board.goals }
        markFilled(.board)
    }

    /// The newest few of each section, small enough for the widget file.
    static func board(agentID: String, items: [AgentBoardItem]) -> BighelpWidgetSnapshot.AgentBoard {
        let shown = items.filter { !$0.dismissed }
        let feed = shown.filter { $0.kind == .feed }.sorted { $0.createdAt > $1.createdAt }.prefix(6).map {
            BighelpWidgetSnapshot.BoardItem(id: $0.id, title: clip($0.title, 70), icon: String($0.icon.prefix(1)),
                                           note: $0.source.isEmpty ? nil : clip($0.source, 40),
                                           preview: preview($0.body), date: $0.createdAt)
        }
        let ideas = shown.filter { $0.kind == .idea }.sorted { $0.createdAt > $1.createdAt }.prefix(6).map {
            BighelpWidgetSnapshot.BoardItem(id: $0.id, title: clip($0.title, 70), icon: String($0.icon.prefix(1)),
                                           note: $0.section.isEmpty ? nil : clip($0.section, 40),
                                           preview: preview($0.body), date: $0.createdAt)
        }
        let goals = shown.filter { $0.kind == .goal }
            .sorted { ($0.isDone ? 1 : 0, $0.createdAt) < ($1.isDone ? 1 : 0, $1.createdAt) }
            .prefix(6).map {
                BighelpWidgetSnapshot.BoardItem(id: $0.id, title: clip($0.title, 60), icon: String($0.icon.prefix(1)),
                                               note: $0.note.isEmpty ? nil : clip($0.note, 80),
                                               isDone: $0.isDone, date: $0.updatedAt)
            }
        return .init(agentID: agentID, feed: Array(feed), ideas: Array(ideas), goals: Array(goals))
    }

    /// Posts and ideas are Markdown; a widget line shows only their words, one line after another.
    private static func preview(_ body: String) -> String? {
        let lines = MarkdownDocument(body).visiblePlainText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : clip(lines.joined(separator: " · "), 120)
    }

    func update(appearance context: BighelpAppearanceContext) {
        func palette(_ scheme: AppAppearance) -> BighelpWidgetSnapshot.Palette {
            let theme = BighelpTheme.resolve(
                appearance: BighelpAppearanceContext(
                    appearance: scheme,
                    lightBackground: context.lightBackground, darkBackground: context.darkBackground,
                    bubbleColor: context.bubbleColor, customBubbleHex: context.customBubbleHex),
                colorScheme: scheme == .dark ? .dark : .light, contrast: .standard)
            return .init(canvasHex: theme.canvasHex, surfaceHex: theme.surfaceHex,
                         primaryTextHex: theme.primaryTextHex, secondaryTextHex: theme.secondaryTextHex,
                         accentHex: theme.actionHex, accentForegroundHex: theme.actionForegroundHex)
        }
        let light = palette(.light), dark = palette(.dark)
        if light != lightPalette { lightPalette = light }
        if dark != darkPalette { darkPalette = dark }
        markFilled(.palettes)
    }

    private static func clip(_ value: String, _ limit: Int) -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit - 1)) + "…"
    }
}
