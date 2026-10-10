import Foundation

/// The small, privacy-bounded view of bighelp the Home Screen and Lock Screen
/// widgets render. The app writes it to the shared App Group; the widget
/// extension only reads it. No message bodies beyond a short preview line.
struct BighelpWidgetSnapshot: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let agentName: String
        let status: String
        let preview: String?
        let isRunning: Bool
        let updatedAt: Date
        var agentID: String? = nil
        /// What the agent is doing (a `BighelpActivityPose` raw value), while running.
        var activity: String? = nil
    }

    /// A Feed post, Idea or Goal from an agent's board.
    struct BoardItem: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let icon: String
        var note: String? = nil
        var isDone = false
        /// The first words of the post or idea, without Markdown.
        var preview: String? = nil
        let date: Date
    }

    /// An agent on this computer, for the widgets' agent choice.
    struct Agent: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    /// A pinned agent, for the Pinned Agents widget: its name, the computer it's
    /// on and its picture in the shared app group. No keys or addresses.
    struct PinnedAgent: Codable, Equatable, Sendable, Identifiable {
        let agentID: String
        let name: String
        /// The computer's ID in bighelp (a UUID) and the name the person gave it.
        var hostID: String? = nil
        var hostName: String? = nil
        /// Its picture (`BighelpPinnedAvatarStore`); nil shows its initial.
        var avatarKey: String? = nil

        /// Agent IDs are only unique on one computer.
        var id: String { (hostID ?? "") + "/" + agentID }
    }

    /// The board of an agent a Feed, Ideas or Goals widget is set to.
    struct AgentBoard: Codable, Equatable, Sendable {
        let agentID: String
        var feed: [BoardItem]
        var ideas: [BoardItem]
        var goals: [BoardItem]
    }

    enum BoardSection: String, CaseIterable, Sendable {
        case feed, ideas, goals
    }

    /// One widget's board: the agent it shows and that agent's items. Not loaded
    /// when the app hasn't read that agent's board yet.
    struct ResolvedBoard: Equatable, Sendable {
        let agentID: String?
        let agentName: String
        let items: [BoardItem]
        let isLoaded: Bool
    }

    /// The app's chosen colors (bubble color, Cream/Paper, Graphite/Black).
    struct Palette: Codable, Equatable, Sendable {
        let canvasHex: String
        let surfaceHex: String
        let primaryTextHex: String
        let secondaryTextHex: String
        let accentHex: String
        let accentForegroundHex: String
    }

    struct Task: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let agentName: String
        let schedule: String
        let nextRun: Date?
        let lastResult: String?
    }

    var defaultAgentID: String?
    var defaultAgentName: String?
    var sessions: [Session]
    var tasks: [Task]
    var generatedAt: Date
    var feed: [BoardItem]? = nil
    var goals: [BoardItem]? = nil
    var ideas: [BoardItem]? = nil
    var agents: [Agent]? = nil
    var boards: [AgentBoard]? = nil
    var lightPalette: Palette? = nil
    var darkPalette: Palette? = nil
    /// Pinned agents of the computer in use, in the person's order.
    var pinnedAgents: [PinnedAgent]? = nil
    /// Pinned agents of every computer, in the order All agents shows them.
    var allPinnedAgents: [PinnedAgent]? = nil
    /// The gateway (computer) this is from: its ID in bighelp (a UUID). Links name
    /// it, so they open there.
    var hostID: String? = nil

    static let empty = BighelpWidgetSnapshot(defaultAgentID: nil, defaultAgentName: nil,
                                            sessions: [], tasks: [], generatedAt: .distantPast)

    static let appGroup = "group.app.loopdy.mobile.buzzkit"
    static let fileName = "loopdy-widget-snapshot-v1.json"
    static let boardWidgetKinds = ["BighelpFeedWidget", "BighelpIdeasWidget", "BighelpGoalsWidget"]
    static let pinnedAgentsWidgetKind = "BighelpPinnedAgentsWidget"
    static let widgetKinds = ["LoopdyAgentWidget", "LoopdyActiveSessionsWidget", "LoopdyScheduledTasksWidget",
                              "LoopdyNewChatWidget", "LoopdyActivityFeedWidget"] + boardWidgetKinds
                              + [pinnedAgentsWidgetKind]
    /// The most pinned agents the snapshot carries per list (a large widget shows 12).
    static let maximumPinnedAgents = 24

    static var fileURL: URL? { fileURL(gateway: nil) }

    /// The gateway in use's file, or (with a gateway's ID) the copy kept for widgets
    /// set to that gateway: its data from the last time it was in use.
    static func fileURL(gateway: String?) -> URL? {
        let name: String
        if let gateway {
            guard let id = UUID(uuidString: gateway) else { return nil }
            name = gatewayFilePrefix + id.uuidString + ".json"
        } else {
            name = fileName
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(name, isDirectory: false)
    }

    static let gatewayFilePrefix = "loopdy-widget-snapshot-v1-"

    /// The gateway in use's data, or (with a gateway's ID) that gateway's. The one in
    /// use reads its live file, so a widget set to it is as fresh as one that follows.
    static func load(gateway: String? = nil) -> BighelpWidgetSnapshot {
        let current = read(fileURL)
        guard let gateway, current.hostID != gateway else { return current }
        return read(fileURL(gateway: gateway))
    }

    private static func read(_ url: URL?) -> BighelpWidgetSnapshot {
        guard let url, let data = try? Data(contentsOf: url),
              data.count <= 262_144,
              let value = try? JSONDecoder.bighelpWidget.decode(Self.self, from: data) else { return .empty }
        return value
    }

    /// Writes the gateway in use's file, and its own copy for widgets set to it.
    func save() throws {
        let data = try JSONEncoder.bighelpWidget.encode(self)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        if let url = Self.fileURL { try data.write(to: url, options: options) }
        if let hostID, let url = Self.fileURL(gateway: hostID) { try data.write(to: url, options: options) }
    }

    var runningSessions: [Session] { sessions.filter(\.isRunning) }

    /// A section of the board for `agentID`, or Auto (nil): the agent picked in the app.
    /// Nil when that agent isn't on this computer anymore.
    func board(_ section: BoardSection, agentID: String?) -> ResolvedBoard? {
        if agentID == nil || agentID == defaultAgentID {
            let items: [BoardItem]? = switch section {
            case .feed: feed
            case .ideas: ideas
            case .goals: goals
            }
            return ResolvedBoard(agentID: defaultAgentID, agentName: defaultAgentName ?? "Your agent",
                                 items: items ?? [], isLoaded: true)
        }
        guard let agentID, let agent = agents?.first(where: { $0.id == agentID }) else { return nil }
        guard let board = boards?.first(where: { $0.agentID == agentID }) else {
            return ResolvedBoard(agentID: agentID, agentName: agent.name, items: [], isLoaded: false)
        }
        let items = switch section {
        case .feed: board.feed
        case .ideas: board.ideas
        case .goals: board.goals
        }
        return ResolvedBoard(agentID: agentID, agentName: agent.name, items: items, isLoaded: true)
    }

    /// Running sessions first, then the most recently active.
    var feedSessions: [Session] {
        sessions.sorted { ($0.isRunning ? 1 : 0, $0.updatedAt) > ($1.isRunning ? 1 : 0, $1.updatedAt) }
    }

    static func chatURL(_ sessionID: String) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "chat"; components.path = "/" + sessionID
        return components.url ?? URL(string: "loopdy://home")!
    }

    static func newChatURL(agentID: String?, hostID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "new-chat"
        if let agentID { components.queryItems = [URLQueryItem(name: "agent", value: agentID)] }
        return link(components.url ?? URL(string: "loopdy://new-chat")!, onGateway: hostID)
    }

    /// A link that opens on a gateway: bighelp switches to it first. Nil keeps the one in use.
    static func link(_ url: URL, onGateway hostID: String?) -> URL {
        guard let hostID, UUID(uuidString: hostID) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "host" }
            + [URLQueryItem(name: "host", value: hostID)]
        return components.url ?? url
    }

    // The links a widget draws open on the gateway its data is from.
    func chatURL(_ sessionID: String) -> URL { Self.link(Self.chatURL(sessionID), onGateway: hostID) }
    func newChatURL(agentID: String?) -> URL { Self.newChatURL(agentID: agentID, hostID: hostID) }
    func taskURL(_ taskID: String) -> URL { Self.link(Self.taskURL(taskID), onGateway: hostID) }
    var tasksURL: URL { Self.link(Self.tasksURL, onGateway: hostID) }
    var sessionsURL: URL { Self.link(Self.sessionsURL, onGateway: hostID) }
    func agentURL(_ tab: String = "chat", agentID: String? = nil) -> URL {
        Self.link(Self.agentURL(tab, agentID: agentID), onGateway: hostID)
    }

    /// A chat with one agent: its latest, or a new one. With a computer, bighelp
    /// switches to it first.
    static func agentChatURL(agentID: String, hostID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "agent-chat"
        components.queryItems = [URLQueryItem(name: "agent", value: agentID)]
            + (hostID.map { [URLQueryItem(name: "host", value: $0)] } ?? [])
        return components.url ?? URL(string: "loopdy://agents")!
    }

    static let tasksURL = URL(string: "loopdy://tasks")!

    static func taskURL(_ taskID: String) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "tasks"; components.path = "/" + taskID
        return components.url ?? tasksURL
    }
    static let sessionsURL = URL(string: "loopdy://sessions")!

    /// The agent home: "chat", "feed", "ideas", "goals" or "apps", for one agent or the picked one.
    static func agentURL(_ tab: String = "chat", agentID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "agent"; components.path = "/" + tab
        if let agentID { components.queryItems = [URLQueryItem(name: "agent", value: agentID)] }
        return components.url ?? URL(string: "loopdy://home")!
    }
}

extension JSONEncoder {
    static var bighelpWidget: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}

extension JSONDecoder {
    static var bighelpWidget: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970; return decoder
    }
}
