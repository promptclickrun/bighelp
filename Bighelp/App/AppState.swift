import Observation

enum ConversationActivationSource: Sendable {
    case newChat
    case quickSwitch
    case sessions
    case fork
}

struct SuspendedChat: Equatable {
    let chatID: String
    let agentID: String
    let text: String
}

@MainActor
@Observable
final class AppState {
    var selectedTab: AppTab = .sessions
    var path: [AppRoute] = []
    private(set) var activeConversationID: String?
    private(set) var pendingVoiceConversationID: String?
    /// Text a board "Ask" or "Discuss" leaves in the next new chat's composer.
    var pendingComposerText: String?
    /// The open chat's agent and text when the app left, while that chat had sent nothing.
    /// Hermes saves a chat only on its first message, so it can be gone on return.
    var suspendedChat: SuspendedChat?
    /// A blueprint's Send to agent: the next new chat sends `pendingComposerText` once it can.
    var pendingComposerSends = false
    /// A chat picked from the full chat list isn't the Chat tab's own chat
    /// (auto-opened, ☰ › New chat, the switcher, an agent tapped on Agents), so
    /// tapping Chat leaves it. Both have ☰, the tab bar and the big-avatar header.
    var chatOpenedFromList = false

    /// The drawer reflects the destination on screen, while `selectedTab`
    /// deliberately retains the root to return to when a pushed route closes.
    var drawerSelectedTab: AppTab? {
        path.isEmpty ? selectedTab : nil
    }

    func select(_ tab: AppTab) {
        switch tab {
        case .home, .inbox:
            selectedTab = .workspace
            path = [.workspaceActivity]
            return
        default:
            selectedTab = tab
        }
        // Root tabs are destinations, not another level in the current route.
        // Clearing the path prevents a stale pushed chat/session from winning
        // the NavigationStack presentation after a tab or drawer selection.
        path.removeAll()
    }

    func open(_ route: AppRoute) {
        path.append(route)
    }

    func openSessions() {
        select(.sessions)
    }

    func openScheduledTasks() {
        select(.scheduledTasks)
    }

    func openInbox() {
        select(.inbox)
    }

    func activateConversation(id: String, source: ConversationActivationSource) {
        let route = AppRoute.chat(conversationID: id)
        switch source {
        case .newChat, .quickSwitch:
            if case .chat = path.last {
                path.removeLast()
            }
            path.append(route)
        case .sessions, .fork:
            path.append(route)
        }
        activeConversationID = id
    }

    func requestVoiceMode(for conversationID: String) {
        pendingVoiceConversationID = conversationID
    }

    /// `keepsAllHostsScreens`: with every computer showing, its lists (All agents, All sessions,
    /// every computer's tasks) stay up while the working computer changes; that computer's own
    /// pages above them go.
    func resetForHostBoundary(keepsAllHostsScreens: Bool = false) {
        // The connections screen stays up while you switch hosts from it.
        // Host-owned routes do not.
        let showsOnlyConnections = !path.isEmpty && path.allSatisfy { $0 == .workspaceConnections }
        if keepsAllHostsScreens {
            if ![.sessions, .scheduledTasks].contains(selectedTab) { selectedTab = .sessions }
            path = Array(path.prefix { $0.isAllHosts })
        } else if !showsOnlyConnections {
            selectedTab = .sessions
            path.removeAll()
        }
        activeConversationID = nil
        pendingVoiceConversationID = nil
        pendingComposerText = nil
        pendingComposerSends = false
        chatOpenedFromList = false
    }

    func resetForAccountBoundary() {
        selectedTab = .sessions
        path.removeAll()
        activeConversationID = nil
        pendingVoiceConversationID = nil
        pendingComposerText = nil
        pendingComposerSends = false
        chatOpenedFromList = false
    }

    func consumeComposerText() -> String? {
        defer { pendingComposerText = nil }
        return pendingComposerText
    }

    func consumeComposerSend() -> Bool {
        defer { pendingComposerSends = false }
        return pendingComposerSends
    }

    @discardableResult
    func consumeVoiceRequest(for conversationID: String) -> Bool {
        guard pendingVoiceConversationID == conversationID else { return false }
        pendingVoiceConversationID = nil
        return true
    }
}
