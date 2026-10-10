// A widget can follow the gateway in use (the default) or stay on one gateway: it
// shows that gateway's data from the last time it was in use, and its taps open
// there, switching bighelp to it first. The app writes the list of gateways.
import AppIntents
import WidgetKit

/// The gateways set up in bighelp, for widgets' Gateway choice. Names only:
/// no addresses or keys.
struct BighelpWidgetGatewayList: Codable, Equatable, Sendable {
    struct Gateway: Codable, Equatable, Sendable, Identifiable {
        /// Its ID in bighelp (a UUID).
        let id: String
        let name: String
    }

    var gateways: [Gateway]

    static let fileName = "loopdy-widget-gateways-v1.json"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BighelpWidgetSnapshot.appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> [Gateway] {
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count <= 65_536,
              let list = try? JSONDecoder().decode(Self.self, from: data) else { return [] }
        return list.gateways
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// A widget's gateway: one computer, or the one in use.
struct BighelpWidgetGateway: AppEntity {
    static let inUseID = "in-use"
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Gateway")
    static let defaultQuery = BighelpWidgetGatewayQuery()
    static let inUse = BighelpWidgetGateway(id: inUseID, name: "Gateway in use")

    let id: String
    let name: String

    /// The gateway's ID in bighelp; nil is the one in use.
    var hostID: String? { id == Self.inUseID ? nil : id }

    var displayRepresentation: DisplayRepresentation {
        id == Self.inUseID
            ? DisplayRepresentation(title: "Gateway in use", subtitle: "The one you're using in bighelp")
            : DisplayRepresentation(title: "\(name)")
    }
}

struct BighelpWidgetGatewayQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BighelpWidgetGateway] {
        let known = try await suggestedEntities()
        // A gateway removed from bighelp keeps its place; its widget shows nothing.
        return identifiers.map { id in known.first { $0.id == id } ?? BighelpWidgetGateway(id: id, name: "Removed gateway") }
    }

    func suggestedEntities() async throws -> [BighelpWidgetGateway] {
        [.inUse] + BighelpWidgetGatewayList.load().map { BighelpWidgetGateway(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> BighelpWidgetGateway? { .inUse }
}

/// The Gateway choice of widgets that have only that one.
struct GatewayWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Gateway"
    static let description = IntentDescription("Show one gateway, or the one you're using in bighelp.")

    @Parameter(title: "Gateway")
    var gateway: BighelpWidgetGateway?
}

/// Your Agent, Recent Chats, Active Chats and Scheduled Tasks: the chosen gateway's data.
struct GatewayWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BighelpWidgetEntry {
        BighelpWidgetEntry(date: .now, snapshot: .preview)
    }

    func snapshot(for configuration: GatewayWidgetIntent, in context: Context) async -> BighelpWidgetEntry {
        let snapshot = BighelpWidgetSnapshot.load(gateway: configuration.gateway?.hostID)
        return BighelpWidgetEntry(date: .now, snapshot: context.isPreview && snapshot.sessions.isEmpty ? .preview : snapshot)
    }

    func timeline(for configuration: GatewayWidgetIntent, in context: Context) async -> Timeline<BighelpWidgetEntry> {
        let snapshot = BighelpWidgetSnapshot.load(gateway: configuration.gateway?.hostID)
        // The app reloads timelines on every change; this is only a safety net.
        let refresh = Date.now.addingTimeInterval(snapshot.runningSessions.isEmpty ? 30 * 60 : 5 * 60)
        return Timeline(entries: [BighelpWidgetEntry(date: .now, snapshot: snapshot)], policy: .after(refresh))
    }
}

/// New Chat: a gateway, and an agent on it (Auto is that gateway's default agent).
struct NewChatWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "New chat"
    static let description = IntentDescription("Choose the gateway and the agent a new chat starts with.")

    @Parameter(title: "Gateway")
    var gateway: BighelpWidgetGateway?

    @Parameter(title: "Agent")
    var agent: BoardWidgetAgent?
}

struct NewChatWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BighelpWidgetSnapshot
    /// Nil is Auto.
    let agentID: String?
}

struct NewChatWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NewChatWidgetEntry {
        NewChatWidgetEntry(date: .now, snapshot: .preview, agentID: nil)
    }

    func snapshot(for configuration: NewChatWidgetIntent, in context: Context) async -> NewChatWidgetEntry {
        let entry = entry(configuration)
        return context.isPreview && entry.snapshot.defaultAgentID == nil ? placeholder(in: context) : entry
    }

    func timeline(for configuration: NewChatWidgetIntent, in context: Context) async -> Timeline<NewChatWidgetEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func entry(_ configuration: NewChatWidgetIntent) -> NewChatWidgetEntry {
        let id = configuration.agent?.id
        return NewChatWidgetEntry(date: .now, snapshot: .load(gateway: configuration.gateway?.hostID),
                                  agentID: id == BoardWidgetAgent.autoID ? nil : id)
    }
}
