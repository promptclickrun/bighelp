// Feed, Ideas and Goals on the Home Screen, each for the agent picked in the app
// (Auto) or for one chosen agent. The app writes the boards; widgets only read.
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Configuration

struct BoardWidgetAgent: AppEntity {
    static let autoID = "auto"
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let defaultQuery = BoardWidgetAgentQuery()
    static let auto = BoardWidgetAgent(id: autoID, name: "Auto")

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        id == Self.autoID
            ? DisplayRepresentation(title: "Auto", subtitle: "The agent you're using in bighelp")
            : DisplayRepresentation(title: "\(name)")
    }
}

struct BoardWidgetAgentQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BoardWidgetAgent] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BoardWidgetAgent] {
        [.auto] + (BighelpWidgetSnapshot.load().agents ?? []).map { BoardWidgetAgent(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> BoardWidgetAgent? { .auto }
}

struct BoardWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agent"
    static let description = IntentDescription("Choose whose board to show, or Auto for the agent you're using.")

    @Parameter(title: "Agent")
    var agent: BoardWidgetAgent?
}

extension BighelpWidgetSnapshot.BoardSection {
    var title: String {
        switch self {
        case .feed: "Feed"
        case .ideas: "Ideas"
        case .goals: "Goals"
        }
    }

    var symbol: String {
        switch self {
        case .feed: "newspaper.fill"
        case .ideas: "lightbulb.fill"
        case .goals: "target"
        }
    }

    var kind: String {
        switch self {
        case .feed: "BighelpFeedWidget"
        case .ideas: "BighelpIdeasWidget"
        case .goals: "BighelpGoalsWidget"
        }
    }

    func emptyText(name: String) -> String {
        switch self {
        case .feed: "Nothing in \(name)'s Feed yet. Ask \(name) to post updates here."
        case .ideas: "No ideas yet. Ask \(name) what it could do for you."
        case .goals: "No goals yet. Ask \(name) to track something for you."
        }
    }
}

// MARK: - Timeline

struct BoardWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BighelpWidgetSnapshot
    /// Nil is Auto.
    let agentID: String?
}

struct BoardWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BoardWidgetEntry {
        BoardWidgetEntry(date: .now, snapshot: .previewBoards, agentID: nil)
    }

    func snapshot(for configuration: BoardWidgetIntent, in context: Context) async -> BoardWidgetEntry {
        let snapshot = BighelpWidgetSnapshot.load()
        return context.isPreview && snapshot.defaultAgentID == nil
            ? placeholder(in: context) : entry(snapshot, configuration)
    }

    func timeline(for configuration: BoardWidgetIntent, in context: Context) async -> Timeline<BoardWidgetEntry> {
        // The app reloads these whenever a board changes; this is only a safety net.
        Timeline(entries: [entry(.load(), configuration)], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func entry(_ snapshot: BighelpWidgetSnapshot, _ configuration: BoardWidgetIntent) -> BoardWidgetEntry {
        let id = configuration.agent?.id
        return BoardWidgetEntry(date: .now, snapshot: snapshot, agentID: id == BoardWidgetAgent.autoID ? nil : id)
    }
}

extension BighelpWidgetSnapshot {
    static let previewIdeas: [BoardItem] = [
        .init(id: "i1", title: "I can plan Sam's birthday dinner", icon: "🎂",
              preview: "Shortlist three restaurants · Check the family calendar · Book the table", date: .now),
        .init(id: "i2", title: "I can find a cheaper phone plan", icon: "📱",
              preview: "Two plans would save about $22 a month.", date: .now.addingTimeInterval(-7200)),
        .init(id: "i3", title: "I can make your sleep goal trackable again", icon: "🌙", date: .now.addingTimeInterval(-86_400)),
    ]

    static var previewBoards: BighelpWidgetSnapshot {
        var snapshot = preview
        snapshot.ideas = previewIdeas
        return snapshot
    }
}

// MARK: - Views

struct BighelpBoardWidgetView: View {
    let section: BighelpWidgetSnapshot.BoardSection
    let snapshot: BighelpWidgetSnapshot
    let agentID: String?
    /// Set by render tests; WidgetKit supplies the family otherwise.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.bighelpWidgetColors) private var colors

    private var family: WidgetFamily { familyOverride ?? environmentFamily }
    private var board: BighelpWidgetSnapshot.ResolvedBoard? { snapshot.board(section, agentID: agentID) }
    private var link: URL { BighelpWidgetSnapshot.agentURL(section.rawValue, agentID: agentID) }

    var body: some View {
        content.widgetURL(link)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular: rectangular
        #endif
        case .systemMedium: list(limit: 3, previewLines: 1)
        case .systemLarge: list(limit: 6, previewLines: 2)
        default: small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(compact: true)
            if let board, board.isLoaded, !board.items.isEmpty {
                ForEach(board.items.prefix(section == .goals ? 3 : 2)) { item in
                    row(item, previewLines: 0, titleLines: section == .goals ? 1 : 2)
                }
            } else {
                message
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func list(limit: Int, previewLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            header(compact: false)
            if let board, board.isLoaded, !board.items.isEmpty {
                ForEach(board.items.prefix(limit)) { item in
                    Link(destination: link) { row(item, previewLines: previewLines, titleLines: 1) }
                }
            } else {
                message
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    #if os(iOS)
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("\(section.title) · \(board?.agentName ?? "bighelp")", systemImage: section.symbol)
                .font(.headline).lineLimit(1).widgetAccentable()
            if let first = board?.items.first {
                Text(first.title).font(.caption).lineLimit(2)
            } else {
                Text(board?.isLoaded == false ? "Open bighelp to load it" : "Nothing yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

    private func header(compact: Bool) -> some View {
        HStack(spacing: 7) {
            BighelpWidgetAvatar(agentID: board?.agentID, name: board?.agentName ?? "bighelp", diameter: compact ? 22 : 26)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: section.symbol).foregroundStyle(colors.accent).widgetAccentable()
                    Text(section.title).foregroundStyle(colors.primary)
                }
                .font(.caption.weight(.bold))
                Text(board?.agentName ?? "Pick an agent")
                    .font(.caption2)
                    .foregroundStyle(colors.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Why there's nothing to list: an empty board, one the app hasn't read yet,
    /// or an agent no longer on this computer.
    private var message: some View {
        let text: String
        if let board {
            text = board.isLoaded ? section.emptyText(name: board.agentName)
                : "Open bighelp to load \(board.agentName)'s \(section.title)."
        } else {
            text = "This agent isn't on your computer anymore. Edit the widget to pick another."
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(colors.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(4)
    }

    private func row(_ item: BighelpWidgetSnapshot.BoardItem, previewLines: Int, titleLines: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            marker(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.isDone ? colors.secondary : colors.primary)
                    .strikethrough(item.isDone, color: colors.secondary)
                    .lineLimit(titleLines)
                    .multilineTextAlignment(.leading)
                if previewLines > 0, let detail = detail(item) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(colors.secondary)
                        .lineLimit(previewLines)
                        .multilineTextAlignment(.leading)
                } else if previewLines > 0, section != .goals {
                    Text(item.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func detail(_ item: BighelpWidgetSnapshot.BoardItem) -> String? {
        section == .goals ? item.note : item.preview ?? item.note
    }

    @ViewBuilder
    private func marker(_ item: BighelpWidgetSnapshot.BoardItem) -> some View {
        if section == .goals {
            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(item.isDone ? colors.accent : colors.secondary)
                .widgetAccentable()
                .frame(width: 24, height: 24)
        } else {
            Group {
                if item.icon.isEmpty {
                    Image(systemName: section == .feed ? "newspaper" : "lightbulb")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.accent)
                } else {
                    Text(item.icon).font(.system(size: 14))
                }
            }
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(colors.accent.opacity(0.14)))
            .widgetAccentable()
        }
    }
}

// MARK: - Widgets

private struct BoardWidgetConfiguration {
    @MainActor
    static func make(_ section: BighelpWidgetSnapshot.BoardSection, description: String) -> some WidgetConfiguration {
        AppIntentConfiguration(kind: section.kind, intent: BoardWidgetIntent.self, provider: BoardWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.snapshot) {
                BighelpBoardWidgetView(section: section, snapshot: entry.snapshot, agentID: entry.agentID)
            }
        }
        .configurationDisplayName(section.title)
        .description(description)
        .supportedFamilies(families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemSmall, .systemMedium, .systemLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular]
        #endif
    }
}

struct BighelpFeedWidget: Widget {
    var body: some WidgetConfiguration {
        BoardWidgetConfiguration.make(.feed, description: "Your agent's latest Feed posts. Pick an agent, or Auto.")
    }
}

struct BighelpIdeasWidget: Widget {
    var body: some WidgetConfiguration {
        BoardWidgetConfiguration.make(.ideas, description: "Things your agent offers to do for you. Pick an agent, or Auto.")
    }
}

struct BighelpGoalsWidget: Widget {
    var body: some WidgetConfiguration {
        BoardWidgetConfiguration.make(.goals, description: "The goals your agent is tracking. Pick an agent, or Auto.")
    }
}
