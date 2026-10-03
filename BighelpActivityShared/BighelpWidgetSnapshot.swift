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

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> BighelpWidgetSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              data.count <= 262_144,
              let value = try? JSONDecoder.bighelpWidget.decode(Self.self, from: data) else { return .empty }
        return value
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        let data = try JSONEncoder.bighelpWidget.encode(self)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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

    static func newChatURL(agentID: String?) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "new-chat"
        if let agentID { components.queryItems = [URLQueryItem(name: "agent", value: agentID)] }
        return components.url ?? URL(string: "loopdy://new-chat")!
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
