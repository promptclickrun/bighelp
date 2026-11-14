import AppIntents
import SwiftUI
import WidgetKit

/// The five columns of a bighelp board. Shared with the widget, which reads
/// only this and the small snapshot below; the app maps Hermes' statuses.
enum KanbanLane: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case later, ready, working, needsYou, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .later: "Later"
        case .ready: "Ready"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .done: "Done"
        }
    }

    /// One line under the lane name, in plain words.
    var subtitle: String {
        switch self {
        case .later: "Planned, not started"
        case .ready: "A bot picks these up next"
        case .working: "Bots on it now"
        case .needsYou: "Waiting on your answer or review"
        case .done: "Finished"
        }
    }

    var symbol: String {
        switch self {
        case .later: "tray"
        case .ready: "play.circle"
        case .working: "bolt.circle"
        case .needsYou: "hand.raised.circle"
        case .done: "checkmark.circle"
        }
    }

    /// Each lane's own color, the same in the app and on widgets.
    var tintHex: String {
        switch self {
        case .later: "8E8781"
        case .ready: "7B52E0"
        case .working: "3E8EDB"
        case .needsYou: "E5624F"
        case .done: "2FA58B"
        }
    }

    var tint: Color { Color(widgetHex: tintHex) }
}

/// What the Kanban widget shows: every board the app has seen, bounded and
/// without task descriptions. The app writes it; the widget only reads it.
struct BighelpKanbanSnapshot: Codable, Equatable, Sendable {
    struct Board: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        var colorHex: String?
    }

    struct Agent: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    struct Card: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let board: String
        let title: String
        let lane: KanbanLane
        var note: String?
        var assignee: String?
        var priority: Int
        let updatedAt: Date
    }

    var boards: [Board] = []
    var agents: [Agent] = []
    var cards: [Card] = []
    var generatedAt: Date = .distantPast

    static let empty = BighelpKanbanSnapshot()
    static let kind = "BighelpKanbanWidget"
    static let fileName = "bighelp-kanban-widget-v1.json"
    static let maximumCards = 400

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BighelpWidgetSnapshot.appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> BighelpKanbanSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count <= 524_288,
              let value = try? JSONDecoder.bighelpWidget.decode(Self.self, from: data) else { return .empty }
        return value
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try JSONEncoder.bighelpWidget.encode(self)
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func agentName(_ id: String?) -> String? {
        guard let id else { return nil }
        return agents.first { $0.id == id }?.name ?? id
    }

    func boardName(_ id: String) -> String { boards.first { $0.id == id }?.name ?? id }

    /// "loopdy://kanban?board=…&task=…" opens the board, or one of its cards.
    static func url(board: String? = nil, task: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"
        components.host = "kanban"
        components.queryItems = [board.map { URLQueryItem(name: "board", value: $0) },
                                 task.map { URLQueryItem(name: "task", value: $0) }].compactMap { $0 }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url ?? URL(string: "loopdy://kanban")!
    }
}

// MARK: - Configuration

struct KanbanWidgetBoard: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Board")
    static let defaultQuery = KanbanWidgetBoardQuery()
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct KanbanWidgetBoardQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [KanbanWidgetBoard] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [KanbanWidgetBoard] {
        BighelpKanbanSnapshot.load().boards.map { KanbanWidgetBoard(id: $0.id, name: $0.name) }
    }
}

struct KanbanWidgetAgent: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bot")
    static let defaultQuery = KanbanWidgetAgentQuery()
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct KanbanWidgetAgentQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [KanbanWidgetAgent] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [KanbanWidgetAgent] {
        let snapshot = BighelpKanbanSnapshot.load()
        let working = Set(snapshot.cards.compactMap(\.assignee))
        return snapshot.agents.filter { working.contains($0.id) || snapshot.agents.count <= 12 }
            .map { KanbanWidgetAgent(id: $0.id, name: $0.name) }
    }
}

enum KanbanWidgetStatus: String, AppEnum {
    case open, needsYou, working, ready, later, done

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Status")
    static let caseDisplayRepresentations: [KanbanWidgetStatus: DisplayRepresentation] = [
        .open: "Everything not done",
        .needsYou: "Needs you",
        .working: "Working",
        .ready: "Ready",
        .later: "Later",
        .done: "Done",
    ]

    var lanes: [KanbanLane] {
        switch self {
        case .open: [.needsYou, .working, .ready, .later]
        case .needsYou: [.needsYou]
        case .working: [.working]
        case .ready: [.ready]
        case .later: [.later]
        case .done: [.done]
        }
    }
}

enum KanbanWidgetGrouping: String, AppEnum {
    case status, agent, board

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Group by")
    static let caseDisplayRepresentations: [KanbanWidgetGrouping: DisplayRepresentation] = [
        .status: "Status", .agent: "Bot", .board: "Board",
    ]
}

struct KanbanWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Kanban"
    static let description = IntentDescription("Your bots' tasks, filtered the way you like.")

    @Parameter(title: "Board", description: "Leave empty for every board.")
    var board: KanbanWidgetBoard?

    @Parameter(title: "Status", default: .open)
    var status: KanbanWidgetStatus

    @Parameter(title: "Bot", description: "Leave empty for every bot.")
    var agent: KanbanWidgetAgent?

    @Parameter(title: "Group by", default: .status)
    var grouping: KanbanWidgetGrouping
}

// MARK: - Timeline

struct KanbanWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BighelpKanbanSnapshot
    let palette: BighelpWidgetSnapshot
    let board: String?
    let boardName: String?
    let lanes: [KanbanLane]
    let agent: String?
    let grouping: KanbanWidgetGrouping

    var cards: [BighelpKanbanSnapshot.Card] {
        snapshot.cards.filter { card in
            lanes.contains(card.lane) && (board == nil || card.board == board)
                && (agent == nil || card.assignee == agent)
        }.sorted { lhs, rhs in
            let left = lanes.firstIndex(of: lhs.lane) ?? 0, right = lanes.firstIndex(of: rhs.lane) ?? 0
            if left != right { return left < right }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Cards in labeled groups, in the order chosen.
    var groups: [(title: String, lane: KanbanLane?, cards: [BighelpKanbanSnapshot.Card])] {
        let cards = cards
        switch grouping {
        case .status:
            return lanes.compactMap { lane in
                let inLane = cards.filter { $0.lane == lane }
                return inLane.isEmpty ? nil : (lane.title, lane, inLane)
            }
        case .agent:
            let keys = Array(Set(cards.map { $0.assignee ?? "" })).sorted {
                (snapshot.agentName($0) ?? "~") < (snapshot.agentName($1) ?? "~")
            }
            return keys.map { key in
                (key.isEmpty ? "Anyone" : snapshot.agentName(key) ?? key, nil, cards.filter { ($0.assignee ?? "") == key })
            }
        case .board:
            let keys = snapshot.boards.map(\.id).filter { id in cards.contains { $0.board == id } }
            return keys.map { key in (snapshot.boardName(key), nil, cards.filter { $0.board == key }) }
        }
    }

    var title: String {
        if lanes.count == 1, let lane = lanes.first { return lane.title }
        return boardName ?? "Kanban"
    }

    static let preview = KanbanWidgetEntry(
        date: .now,
        snapshot: BighelpKanbanSnapshot(
            boards: [.init(id: "launch", name: "Launch")],
            agents: [.init(id: "juno", name: "Juno"), .init(id: "rex", name: "Rex")],
            cards: [
                .init(id: "a", board: "launch", title: "Approve the launch budget", lane: .needsYou,
                      note: "Ready for review", assignee: "juno", priority: 2, updatedAt: .now),
                .init(id: "b", board: "launch", title: "Compare hosting costs", lane: .working,
                      assignee: "rex", priority: 1, updatedAt: .now),
                .init(id: "c", board: "launch", title: "Pick three testimonials", lane: .ready,
                      assignee: "juno", priority: 0, updatedAt: .now),
                .init(id: "d", board: "launch", title: "Draft the App Store text", lane: .later,
                      assignee: nil, priority: 0, updatedAt: .now),
            ],
            generatedAt: .now),
        palette: .empty, board: "launch", boardName: "Launch", lanes: KanbanWidgetStatus.open.lanes,
        agent: nil, grouping: .status)
}

struct KanbanWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> KanbanWidgetEntry { .preview }

    func snapshot(for configuration: KanbanWidgetIntent, in context: Context) async -> KanbanWidgetEntry {
        let entry = entry(for: configuration)
        return context.isPreview && entry.snapshot.cards.isEmpty ? .preview : entry
    }

    func timeline(for configuration: KanbanWidgetIntent, in context: Context) async -> Timeline<KanbanWidgetEntry> {
        // The app reloads this whenever a board changes; this is only a safety net.
        Timeline(entries: [entry(for: configuration)], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: KanbanWidgetIntent) -> KanbanWidgetEntry {
        let snapshot = BighelpKanbanSnapshot.load()
        let board = configuration.board?.id
        return KanbanWidgetEntry(
            date: .now, snapshot: snapshot, palette: BighelpWidgetSnapshot.load(),
            board: board, boardName: board.map(snapshot.boardName),
            lanes: configuration.status.lanes, agent: configuration.agent?.id, grouping: configuration.grouping)
    }
}

// MARK: - Views

struct BighelpKanbanWidgetView: View {
    let entry: KanbanWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.bighelpWidgetColors) private var colors

    var body: some View {
        Group {
            if family.isAccessory {
                accessory
            } else {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 10) {
                    header
                    if entry.cards.isEmpty {
                        Spacer(minLength: 0)
                        Text(entry.snapshot.cards.isEmpty ? "Open Kanban in Bighelp to see your boards here."
                             : "Nothing here right now.")
                            .font(.caption).foregroundStyle(colors.secondary)
                        Spacer(minLength: 0)
                    } else if family == .systemSmall {
                        small
                    } else {
                        list
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .widgetURL(BighelpKanbanSnapshot.url(board: entry.board))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.lanes.count == 1 ? entry.lanes[0].symbol : "rectangle.split.3x1")
                .font(.caption.weight(.bold))
                .foregroundStyle(entry.lanes.count == 1 ? entry.lanes[0].tint : colors.accent)
            Text(entry.title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(entry.cards.count)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(colors.secondary)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            let needsYou = entry.cards.filter { $0.lane == .needsYou }.count
            if needsYou > 0, entry.lanes.count > 1 {
                Text("\(needsYou) need\(needsYou == 1 ? "s" : "") you")
                    .font(.headline).foregroundStyle(KanbanLane.needsYou.tint)
            }
            ForEach(entry.cards.prefix(needsYou > 0 && entry.lanes.count > 1 ? 2 : 3)) { card in
                row(card, compact: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var list: some View {
        let limit = switch family {
        case .systemMedium: 3
        case .systemLarge: 8
        default: 12
        }
        let showsHeaders = family != .systemMedium || entry.groups.count > 1
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.fitting(entry.groups, limit: limit).enumerated()), id: \.offset) { _, group in
                if showsHeaders {
                    HStack(spacing: 5) {
                        if let lane = group.lane { Circle().fill(lane.tint).frame(width: 6, height: 6) }
                        Text(group.title.uppercased()).font(.caption2.weight(.bold)).tracking(0.4)
                            .foregroundStyle(colors.secondary)
                        Text("\(group.total)").font(.caption2.monospacedDigit()).foregroundStyle(colors.secondary)
                    }
                    .padding(.top, 2)
                }
                ForEach(group.cards) { card in row(card, compact: false) }
            }
            Spacer(minLength: 0)
        }
    }

    /// The first groups' cards until the widget is full; later groups drop out.
    static func fitting(_ groups: [(title: String, lane: KanbanLane?, cards: [BighelpKanbanSnapshot.Card])],
                        limit: Int) -> [(title: String, lane: KanbanLane?, total: Int, cards: [BighelpKanbanSnapshot.Card])] {
        var room = limit
        var result: [(title: String, lane: KanbanLane?, total: Int, cards: [BighelpKanbanSnapshot.Card])] = []
        for group in groups where room > 0 {
            let cards = Array(group.cards.prefix(room))
            room -= cards.count
            result.append((group.title, group.lane, group.cards.count, cards))
        }
        return result
    }

    private func row(_ card: BighelpKanbanSnapshot.Card, compact: Bool) -> some View {
        Link(destination: BighelpKanbanSnapshot.url(board: card.board, task: card.id)) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(card.lane.tint).frame(width: 3).widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.caption.weight(.semibold)).foregroundStyle(colors.primary).lineLimit(compact ? 2 : 1)
                    if !compact, let detail = detail(card) {
                        Text(detail).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !compact, let assignee = card.assignee {
                    BighelpWidgetAvatar(agentID: assignee, name: entry.snapshot.agentName(assignee) ?? assignee, diameter: 20)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ card: BighelpKanbanSnapshot.Card) -> String? {
        var parts: [String] = []
        if entry.grouping != .status || entry.lanes.count > 1 { parts.append(card.note ?? card.lane.title) }
        if entry.grouping != .agent, let name = entry.snapshot.agentName(card.assignee) { parts.append(name) }
        if entry.board == nil, entry.grouping != .board { parts.append(entry.snapshot.boardName(card.board)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var accessory: some View {
        let needsYou = entry.cards.filter { $0.lane == .needsYou }
        VStack(alignment: .leading, spacing: 2) {
            Text(needsYou.isEmpty ? "\(entry.cards.count) on \(entry.title)" : "\(needsYou.count) need\(needsYou.count == 1 ? "s" : "") you")
                .font(.headline).lineLimit(1).widgetAccentable()
            Text((needsYou.first ?? entry.cards.first)?.title ?? "Nothing waiting").font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BighelpKanbanWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: BighelpKanbanSnapshot.kind, intent: KanbanWidgetIntent.self,
                               provider: KanbanWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.palette) {
                BighelpKanbanWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("Kanban")
        .description("Tasks from your boards. Pick a board, a status and a bot.")
        .supportedFamilies(Self.families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular]
        #endif
    }
}
