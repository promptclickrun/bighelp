import AppIntents
import Foundation
import Observation
import SwiftUI

/// A screen a Shortcut opens. It's handed to the visible shell as a
/// `loopdy://` link, so it takes the same path as a widget tap: it waits until
/// the host runtime is ready, then opens once.
struct BighelpIncomingLink: Equatable, Sendable {
    let id = UUID()
    let url: URL
}

@MainActor
@Observable
final class BighelpIncomingLinkCenter {
    static let shared = BighelpIncomingLinkCenter()
    init() {}
    private(set) var pending: BighelpIncomingLink?

    /// The latest one wins, like links tapped while the app starts.
    func open(_ url: URL) {
        pending = BighelpIncomingLink(url: url)
    }

    func consume(_ link: BighelpIncomingLink) -> Bool {
        guard pending == link else { return false }
        pending = nil
        return true
    }
}

/// Links for the screens Shortcuts open. Chats and tabs reuse the widget links.
enum BighelpShortcutLinks {
    static func chat(_ sessionID: String) -> URL { BighelpWidgetSnapshot.chatURL(sessionID) }

    /// A hosted group chat by its room on the host.
    static func group(_ roomID: String) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "group"; components.path = "/" + roomID
        return components.url ?? URL(string: "loopdy://agents")!
    }

    /// One workflow, on its computer when it's known; `startsRun` opens its Run sheet.
    static func workflow(_ id: String, hostID: UUID?, startsRun: Bool) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "workflows"; components.path = "/" + id
        var items: [URLQueryItem] = []
        if let hostID { items.append(URLQueryItem(name: "host", value: hostID.uuidString)) }
        if startsRun { items.append(URLQueryItem(name: "run", value: "1")) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? BighelpShortcutDestination.workflows.url
    }

    /// The agent's home: its latest chat, with it as the home agent.
    static func agentHome(_ agentID: String) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "agent"; components.path = "/chat"
        components.queryItems = [URLQueryItem(name: "agent", value: agentID)]
        return components.url ?? BighelpWidgetSnapshot.agentURL()
    }
}

/// The places "Open in bighelp" goes: the bottom bar's tabs and ☰'s rows.
/// Group chats aren't here: they're listed on Agents, and Open group chat
/// opens one directly.
enum BighelpShortcutDestination: String, CaseIterable, Sendable {
    case chats, agents, feed, ideas, goals, projects, kanban, workflows, scheduledTasks, settings

    var url: URL {
        switch self {
        case .chats: BighelpWidgetSnapshot.sessionsURL
        case .agents: URL(string: "loopdy://agents")!
        case .feed: BighelpWidgetSnapshot.agentURL("feed")
        case .ideas: BighelpWidgetSnapshot.agentURL("ideas")
        case .goals: BighelpWidgetSnapshot.agentURL("goals")
        case .projects: URL(string: "loopdy://projects")!
        case .kanban: URL(string: "loopdy://kanban")!
        case .workflows: URL(string: "loopdy://workflows")!
        case .scheduledTasks: BighelpWidgetSnapshot.tasksURL
        case .settings: URL(string: "loopdy://settings")!
        }
    }
}

/// What the ready-made Shortcut tiles are made of: agent, scheduled task and
/// group chat names. Tiles refresh only when this changes.
struct BighelpShortcutParameterSignature: Equatable, Sendable {
    let values: [String]

    init(agents: [AgentProfile], tasks: [ScheduledTask], groups: [String]) {
        let limit = BighelpShortcutService.listLimit
        values = agents.prefix(limit).map { "a\u{1F}\($0.id)\u{1F}\($0.name)" }
            + tasks.prefix(limit).map { "t\u{1F}\($0.agentID)\u{1F}\($0.id)\u{1F}\($0.name)" }
            + groups.prefix(limit).map { "g\u{1F}\($0)" }
    }
}

/// Keeps the tiles in step with the host in use. Its own modifier, so a
/// changing chat list re-reads only these names, not the whole shell.
struct BighelpShortcutParameterUpdates: ViewModifier {
    let agents: AgentDirectoryStore
    let scheduledTasks: ScheduledTasksStore?
    let rooms: BotModeRoomStore
    let catalog: SessionCatalogStore

    func body(content: Content) -> some View {
        let groups = rooms.catalogRooms.filter { !$0.isDisbanded }.map(\.name)
            + catalog.presentedRecords.filter { $0.kind == .botMode }.map(\.title)
        let signature = BighelpShortcutParameterSignature(
            agents: agents.profiles, tasks: scheduledTasks?.tasks ?? [], groups: groups)
        content.onChange(of: signature, initial: true) { _, value in
            BighelpShortcutParameters.refresh(value)
        }
    }
}

/// Asks Shortcuts and Spotlight to rebuild the per-agent, per-task and
/// per-group tiles. Loads arrive in bursts (agents, then tasks, then groups),
/// so changes are gathered for a moment and sent once.
@MainActor
enum BighelpShortcutParameters {
    private static var last: BighelpShortcutParameterSignature?
    private static var pending: Task<Void, Never>?

    static func refresh(_ signature: BighelpShortcutParameterSignature) {
        guard !signature.values.isEmpty, signature != last else { return }
        last = signature
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            BighelpAppShortcuts.updateAppShortcutParameters()
        }
    }
}
