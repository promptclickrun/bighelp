import Foundation

enum BighelpIncomingURLRoute: Equatable, Sendable {
    case home
    case chat(sessionID: String)
    case newChat(agentID: String?)
    case scheduledTasks
    case scheduledTask(id: String)
    case sessions
    /// "loopdy://agent/feed?agent=…": a tab of the agent home (chat, feed, ideas,
    /// goals, apps), optionally for one agent.
    case agent(tab: String, agentID: String? = nil)
    /// "loopdy://approval/<id>": one approval, from the Watch.
    case approval(id: String)
    /// "loopdy://kanban?board=…&task=…": Kanban, a board, or one card.
    case kanban(board: String?, task: String?)
    /// "loopdy://group/<room>": a group chat hosted on the computer, from Shortcuts.
    case group(roomID: String)
    /// "loopdy://agent-chat?agent=…&host=…": a chat with one agent, from the
    /// Pinned Agents widget. With a host, on that computer.
    case agentChat(agentID: String, hostID: UUID?)
    /// "loopdy://agents", "loopdy://projects", "loopdy://settings": ☰'s pages.
    case agents
    case projects
    case settings

    static func parse(_ url: URL) -> BighelpIncomingURLRoute? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "loopdy" || scheme == "app.loopdy.mobile" else { return nil }
        let legacyDestination = url.host?.lowercased()
            ?? url.pathComponents.dropFirst().first?.lowercased()
        if
            legacyDestination == "inbox" || legacyDestination == "dashboard",
            url.pathComponents.count <= 2
        {
            return .home
        }
        if url.host?.lowercased() == "new-chat", url.pathComponents.count <= 1 {
            let agent = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "agent" })?.value
            return .newChat(agentID: agent.flatMap { $0.isEmpty || $0.count > 96 ? nil : $0 })
        }
        if url.host?.lowercased() == "tasks", url.pathComponents.count <= 1 { return .scheduledTasks }
        if url.host?.lowercased() == "tasks", url.pathComponents.count == 2,
           let id = url.pathComponents.last, !id.isEmpty, id.utf8.count <= 256 {
            return .scheduledTask(id: id)
        }
        if url.host?.lowercased() == "sessions", url.pathComponents.count <= 1 { return .sessions }
        if url.host?.lowercased() == "kanban", url.pathComponents.count <= 1 {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value.flatMap { $0.isEmpty || $0.utf8.count > 240 ? nil : $0 }
            }
            return .kanban(board: value("board"), task: value("task"))
        }
        if url.host?.lowercased() == "agent", url.pathComponents.count <= 2 {
            let tab = url.pathComponents.dropFirst().first?.lowercased() ?? "chat"
            let agent = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "agent" })?.value
                .flatMap { $0.isEmpty || $0.utf8.count > 96 ? nil : $0 }
            return .agent(tab: ["chat", "feed", "ideas", "goals", "apps"].contains(tab) ? tab : "chat", agentID: agent)
        }
        if url.host?.lowercased() == "agent-chat" {
            return parseAgentChat(url)
        }
        if url.host?.lowercased() == "approval", url.pathComponents.count == 2,
           let id = url.pathComponents.last, !id.isEmpty, id.utf8.count <= 240 {
            return .approval(id: id)
        }
        if url.host?.lowercased() == "group", url.pathComponents.count == 2,
           let id = url.pathComponents.last, !id.isEmpty, id != "/", id.utf8.count <= 240 {
            return .group(roomID: id)
        }
        if url.pathComponents.count <= 1 {
            switch url.host?.lowercased() {
            case "agents": return .agents
            case "projects": return .projects
            case "settings": return .settings
            default: break
            }
        }
        guard
            url.host?.lowercased() == "chat",
            url.pathComponents.count == 2,
            let sessionID = url.pathComponents.dropFirst().first,
            !sessionID.isEmpty
        else { return nil }
        return .chat(sessionID: sessionID)
    }

    /// One agent, and at most one computer given by its ID. Anything odd isn't a link.
    private static func parseAgentChat(_ url: URL) -> BighelpIncomingURLRoute? {
        guard url.pathComponents.count <= 1 else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let agents = items.filter { $0.name == "agent" }, hosts = items.filter { $0.name == "host" }
        guard agents.count == 1, hosts.count <= 1, let agent = agents[0].value,
              !agent.isEmpty, agent.utf8.count <= 96,
              agent == agent.trimmingCharacters(in: .whitespacesAndNewlines),
              !agent.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        guard let host = hosts.first else { return .agentChat(agentID: agent, hostID: nil) }
        guard let value = host.value, value.utf8.count <= 36, let hostID = UUID(uuidString: value) else { return nil }
        return .agentChat(agentID: agent, hostID: hostID)
    }
}
