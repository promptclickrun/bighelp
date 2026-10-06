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
    /// "loopdy://workflows": the Workflows home, from Shortcuts.
    case workflows
    /// "loopdy://workflows/<id>?host=…&run=1": one workflow, on its computer, or straight to its Run sheet.
    case workflow(id: String, hostID: UUID?, startsRun: Bool)
    /// "loopdy://workflow-run/<id>": one run, from the Workflows widget.
    case workflowRun(id: String)
    /// "loopdy://usage": ☰ › Usage, from the Usage widget.
    case usage

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
        if url.host?.lowercased() == "workflows" {
            return parseWorkflow(url)
        }
        if url.host?.lowercased() == "workflow-run" {
            guard url.pathComponents.count == 2, url.query == nil, let id = url.pathComponents.last,
                  isPlainID(id, maximum: 128) else { return nil }
            return .workflowRun(id: id)
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
            case "usage": return .usage
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

    /// The home, or one workflow by its ID with at most one computer and one `run`. Anything odd isn't a link.
    private static func parseWorkflow(_ url: URL) -> BighelpIncomingURLRoute? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.pathComponents.count <= 1 { return items.isEmpty ? .workflows : nil }
        guard url.pathComponents.count == 2, let id = url.pathComponents.last, !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-".contains(Character($0))) })
        else { return nil }
        let hosts = items.filter { $0.name == "host" }, runs = items.filter { $0.name == "run" }
        guard hosts.count <= 1, runs.count <= 1, items.count == hosts.count + runs.count else { return nil }
        var hostID: UUID?
        if let host = hosts.first {
            guard let value = host.value, value.utf8.count <= 36, let id = UUID(uuidString: value) else { return nil }
            hostID = id
        }
        if let run = runs.first, run.value != "1" { return nil }
        return .workflow(id: id, hostID: hostID, startsRun: !runs.isEmpty)
    }

    /// Letters, digits, "_" and "-" only. Byte checks, not CharacterSet, which misread
    /// some characters on device.
    private static func isPlainID(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x5F || byte == 0x2D
        }
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
