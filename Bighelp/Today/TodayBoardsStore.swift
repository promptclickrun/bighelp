import Foundation
import Observation

/// One Feed post, idea or goal on Today, with the bot it's from.
struct TodayBoardsEntry: Identifiable, Equatable {
    let agentID: String
    let item: AgentBoardItem

    var id: String { agentID + "/" + item.id }
}

/// Feed, Ideas and Goals for every bot on the computer in use. There is no route for every bot's
/// board at once, so it reads one bot after another on the same client, as the widgets' loader
/// does (`BighelpWidgetBoardLoader`). Reads only: no bot runs.
@MainActor
@Observable
final class TodayBoardsStore {
    static let maximumBots = 24
    /// A read that worked holds the next one off this long.
    static let freshness: TimeInterval = 60

    /// The boards of the computer shown, by bot (profile) ID.
    private(set) var boards: [String: [AgentBoardItem]] = [:]
    /// The computer shown (its cache scope); nil before the first read.
    private(set) var scope: String?
    /// The computer shown has answered at least once, in this run.
    private(set) var hasRead = false
    private(set) var isReading = false
    /// Unread dots show only when the computer keeps read state (`supportsFeedback`).
    private(set) var tracksUnread = false

    @ObservationIgnored private var byScope: [String: [String: [AgentBoardItem]]] = [:]
    @ObservationIgnored private var readAt: [String: Date] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Shown bots first in the order given, then the hidden ones, at most `maximumBots`.
    static func readOrder(botIDs: [String], hiddenIDs: Set<String>) -> [String] {
        var seen: Set<String> = []
        let unique = botIDs.filter { seen.insert($0).inserted }
        return Array((unique.filter { !hiddenIDs.contains($0) } + unique.filter { hiddenIDs.contains($0) })
            .prefix(maximumBots))
    }

    /// Reads the boards of `botIDs` on `client`, at most once a minute per computer unless `force`.
    /// Another computer shows its last read at once while this one runs; a bot whose read fails
    /// keeps what it had.
    func refresh(client: any AgentBoardClient, scope: String, botIDs: [String], hiddenIDs: Set<String> = [],
                 force: Bool = false) async {
        if scope != self.scope {
            generation &+= 1
            isReading = false
            self.scope = scope
            boards = byScope[scope] ?? [:]
            hasRead = byScope[scope] != nil
        }
        if !force, let last = readAt[scope], now().timeIntervalSince(last) < Self.freshness { return }
        if isReading, !force { return }
        generation &+= 1
        let generation = generation
        isReading = true
        tracksUnread = client.supportsFeedback
        let wanted = Self.readOrder(botIDs: botIDs, hiddenIDs: hiddenIDs)
        let previous = byScope[scope] ?? [:]
        var next: [String: [AgentBoardItem]] = [:]
        var allWorked = true
        for id in wanted {
            guard generation == self.generation else { return }
            guard !Task.isCancelled else { isReading = false; return }
            if let items = try? await client.items(agentID: id) {
                next[id] = items
            } else {
                allWorked = false
                if let kept = previous[id] { next[id] = kept }
            }
            guard generation == self.generation else { return }
            // Each bot shows as it arrives; bots not read yet keep what they had.
            var shown = previous.filter { wanted.contains($0.key) }
            shown.merge(next) { _, new in new }
            byScope[scope] = shown
            if shown != boards { boards = shown }
        }
        guard generation == self.generation else { return }
        guard !Task.isCancelled else { isReading = false; return }
        byScope[scope] = next
        if next != boards { boards = next }
        hasRead = true
        isReading = false
        // Only a read where every bot answered counts, so a dropping connection doesn't hold off the next.
        if allWorked { readAt[scope] = now() }
    }

    /// The newest items of `kind` across bots, as each bot's own board lists them.
    func entries(_ kind: AgentBoardItem.Kind, agentIDs: [String]? = nil) -> [TodayBoardsEntry] {
        Self.entries(kind, boards: boards, agentIDs: agentIDs)
    }

    static func entries(_ kind: AgentBoardItem.Kind, boards: [String: [AgentBoardItem]],
                        agentIDs: [String]? = nil) -> [TodayBoardsEntry] {
        let ids = agentIDs ?? Array(boards.keys)
        // In named steps: as one expression the Vision Pro build couldn't type-check it in time.
        let entries: [TodayBoardsEntry] = ids.flatMap { id -> [TodayBoardsEntry] in
            let items: [AgentBoardItem] = boards[id] ?? []
            // Ideas answered with Let's do it are under Completed on the bot's own board, not here.
            let shown = items.filter { $0.kind == kind && !$0.dismissed && !$0.isCompleted }
            return shown.map { TodayBoardsEntry(agentID: id, item: $0) }
        }
        return entries.sorted { first, second in
            if first.item.createdAt != second.item.createdAt { return first.item.createdAt > second.item.createdAt }
            return first.id < second.id
        }
    }
}
