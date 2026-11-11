import Foundation
import Observation
import SwiftUI

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

/// The chat the person was in when they left it for another place (Feed, Agents, Kanban…). The bar
/// tab it was under opens it again, as any tab keeps its place.
struct HeldChat: Equatable {
    let conversationID: String
    /// Picked from the full chat list: with Sessions in the bar, Sessions holds it, not Chat.
    let openedFromList: Bool

    /// The bar tab that opens it again: Chat (`.sessions`) or Sessions (`.sessionList`).
    func tab(sessionsInBar: Bool) -> AppTab {
        openedFromList && sessionsInBar ? .sessionList : .sessions
    }

    /// Chat is the chat of the agent in use, so it opens a 1:1 chat again only while that chat's
    /// agent is in use (a board opened from it makes its agent the one in use). A group chat isn't
    /// any one agent's.
    static func fitsChat(members: [String], agentInUse: String?) -> Bool {
        members.count != 1 || members.first == agentInUse
    }
}

@MainActor
@Observable
final class AppState {
    var selectedTab: AppTab = .sessions
    /// The root a host or account change returns to: Chat, or Code in Code mode.
    var homeTab: AppTab = .sessions
    var path: [AppRoute] = []
    private(set) var activeConversationID: String?
    private(set) var pendingVoiceConversationID: String?
    /// Text a board "Ask" or "Discuss" leaves in the next new chat's composer.
    var pendingComposerText: String?
    /// The chat left for another place; opening a chat, or another computer or account, forgets it.
    private(set) var heldChat: HeldChat?
    /// The open chat's agent and text when the app left, while that chat had sent nothing.
    /// Hermes saves a chat only on its first message, so it can be gone on return.
    var suspendedChat: SuspendedChat?
    /// `pendingComposerText` is a blueprint: its `[blanks]` show as chips to fill in (`ChatBlueprintDraft`).
    var pendingComposerFillsBlanks = false
    /// The bot whose own chat may take `pendingComposerText` even though it has history: a bot's
    /// Dashboard opens that bot's Bot Chat, never a new one. Only an empty message box takes it.
    var pendingComposerAgentID: String?
    /// A chat picked from the full chat list isn't the Chat tab's own chat
    /// (auto-opened, ☰ › New chat, the switcher, an agent tapped on Agents), so
    /// tapping Chat leaves it. Both have ☰, the tab bar and the big-avatar header.
    var chatOpenedFromList = false
    /// Chats that send their draft once connected: a branch made when Hermes refused a
    /// message because another Hermes process held the original (`continueInBranch`).
    var sendsDraftOnOpen: Set<String> = []
    /// A share from another app on its way to the message box of the chat the person picked
    /// (`PendingShareCenter`). Only that chat takes it, never another computer's.
    private(set) var pendingShare: PendingShareHandoff?

    /// The Settings sheet. It lives here, not in the shell's view state, so code outside the
    /// view (an agent's drive) can open it straight to a page: `openSettings(at:)`.
    var isSettingsPresented = false
    /// What the Settings sheet's stack shows above its first page. Type-erased: Bots mode pushes
    /// `SimpleBotsSettingsPage` values and the full Settings pushes `SettingsDestination` values
    /// on the same stack.
    var settingsPath = NavigationPath()

    /// The drawer reflects the destination on screen, while `selectedTab`
    /// deliberately retains the root to return to when a pushed route closes.
    var drawerSelectedTab: AppTab? {
        path.isEmpty ? selectedTab : nil
    }

    func select(_ tab: AppTab) {
        // Leaving a chat for another place: the tab it was under opens it again. Chat and
        // Sessions share a root, so moving between them leaves nothing behind.
        if selectedTab == .sessions, tab != .sessions, tab != .sessionList, case .chat(let id)? = path.last {
            heldChat = HeldChat(conversationID: id, openedFromList: chatOpenedFromList)
        }
        switch tab {
        case .home, .inbox:
            selectedTab = .workspace
            path = [.workspaceActivity]
            return
        case .sessionList:
            selectedTab = .sessions
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

    /// Switches to `tab` and opens `routes` on it. On the Mac they open a moment
    /// after the switch: pushed in the same update, the tab's title-bar search
    /// field stayed drawn over the pushed page's Back button and blocked it.
    func select(_ tab: AppTab, thenOpen routes: [AppRoute]) {
        guard selectedTab != tab || !path.isEmpty else {
            path = routes
            return
        }
        guard !routes.isEmpty else {
            select(tab)
            return
        }
        select(tab)
        #if targetEnvironment(macCatalyst)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.selectedTab == tab, self.path.isEmpty else { return }
            self.path = routes
        }
        #else
        path = routes
        #endif
    }

    /// Opens Settings with `pages` pushed one after another, so Back steps through them. With no
    /// pages it opens the first screen (Bots mode's short Settings in Bots mode). Replaces the
    /// pages when Settings is already open.
    func openSettings(at pages: [SettingsDestination] = []) {
        var next = NavigationPath()
        for page in pages {
            // Bots mode's own screen registers its page type, not `SettingsDestination`.
            if case .bots(let botsPage) = page { next.append(botsPage) } else { next.append(page) }
        }
        settingsPath = next
        isSettingsPresented = true
    }

    func closeSettings() {
        isSettingsPresented = false
        settingsPath = NavigationPath()
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
        // The chat on screen now is the one a tab holds when the person leaves it.
        heldChat = nil
        let route = AppRoute.chat(conversationID: id)
        // Already open (a notification, widget or link about it): go back to that copy. A second
        // copy would share its model, both would redraw every change, and Back would show it again.
        if let open = path.lastIndex(of: route) {
            path.removeSubrange(path.index(after: open)...)
            activeConversationID = id
            return
        }
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

    /// The chat the person is in: the active one, else the chat on top of the path (the Chat tab's own
    /// chat opens without activating).
    var chatOnScreen: String? {
        if let activeConversationID { return activeConversationID }
        if case .chat(let id)? = path.last { return id }
        return nil
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
            selectedTab = homeTab
            path.removeAll()
        }
        activeConversationID = nil
        pendingVoiceConversationID = nil
        clearComposerText()
        chatOpenedFromList = false
        // Its chat is the other computer's.
        heldChat = nil
        dropPendingShare()
    }

    func resetForAccountBoundary() {
        selectedTab = homeTab
        path.removeAll()
        activeConversationID = nil
        pendingVoiceConversationID = nil
        clearComposerText()
        chatOpenedFromList = false
        heldChat = nil
        dropPendingShare()
    }

    /// Sends a share to the chat about to open. It replaces any earlier one, which is offered again.
    func handOff(_ share: PendingShareHandoff) {
        dropPendingShare()
        pendingShare = share
    }

    /// The share, if this chat is the one it's for: on top, and the very chat its destination names
    /// (a new chat's only once Hermes has made it, never its local canvas), within
    /// `pendingComposerLifetime`.
    func takePendingShare(conversationID: String, isOnTop: Bool, now: Date = .now) -> PendingShareHandoff? {
        guard let share = pendingShare else { return nil }
        guard now.timeIntervalSince(share.since) <= Self.pendingComposerLifetime else {
            dropPendingShare()
            return nil
        }
        guard isOnTop, share.destination.isTaken(by: conversationID) else { return nil }
        pendingShare = nil
        return share
    }

    private func dropPendingShare() {
        guard let share = pendingShare else { return }
        pendingShare = nil
        share.onDropped(share.share.id)
    }

    /// When `pendingComposerText` was left. A chat that opens much later (its open failed, or the
    /// person went elsewhere) doesn't take it.
    private var pendingComposerSince: Date?
    /// A new chat's blank canvas is showing `pendingComposerText` (`showComposerText`).
    private var pendingComposerShown = false
    static let pendingComposerLifetime: TimeInterval = 30

    /// Leaves text for the next chat's message box. Each request replaces the last one whole, so
    /// an earlier bot or blueprint never sticks to new text. Only a blueprint sets `fillsBlanks`:
    /// brackets in anything else (a post's title, text the person typed) are just text.
    func leaveComposerText(_ text: String, fillsBlanks: Bool = false, agentID: String? = nil, now: Date = .now) {
        pendingComposerText = text
        pendingComposerFillsBlanks = fillsBlanks
        pendingComposerShown = false
        pendingComposerAgentID = agentID
        pendingComposerSince = now
    }

    /// The text for a new chat's blank canvas to show while Hermes makes the chat: read, not taken.
    /// The canvas is thrown away when the chat arrives and its draft doesn't always get across in
    /// time, so the text stays here for that chat to take.
    func showComposerText(now: Date = .now) -> (text: String, fillsBlanks: Bool)? {
        guard pendingComposerAgentID == nil, let text = pendingComposerText, let since = pendingComposerSince,
              now.timeIntervalSince(since) <= Self.pendingComposerLifetime else { return nil }
        pendingComposerShown = true
        return (text, pendingComposerFillsBlanks)
    }

    /// The text, if this chat should take it: a new chat on top, or the named bot's own chat on top.
    /// `wasShown`: a blank canvas already showed it, so this chat may hold it (and what the person
    /// changed) from the canvas's draft.
    func takeComposerText(isNewChat: Bool, isNamedBotChat: Bool,
                          now: Date = .now) -> (text: String, fillsBlanks: Bool, wasShown: Bool)? {
        guard let text = pendingComposerText else { return nil }
        guard let since = pendingComposerSince, now.timeIntervalSince(since) <= Self.pendingComposerLifetime else {
            clearComposerText()
            return nil
        }
        guard pendingComposerAgentID == nil ? isNewChat : isNamedBotChat else { return nil }
        let taken = (text, pendingComposerFillsBlanks, pendingComposerShown)
        clearComposerText()
        return taken
    }

    private func clearComposerText() {
        pendingComposerText = nil
        pendingComposerFillsBlanks = false
        pendingComposerShown = false
        pendingComposerAgentID = nil
        pendingComposerSince = nil
    }

    @discardableResult
    func consumeVoiceRequest(for conversationID: String) -> Bool {
        guard pendingVoiceConversationID == conversationID else { return false }
        pendingVoiceConversationID = nil
        return true
    }
}

/// A share from another app handed to the chat it's for (`AppState.handOff`).
struct PendingShareHandoff: Identifiable {
    let id = UUID()
    let share: PendingShare
    let inbox: PendingShareInbox
    let destination: PendingShareDestination
    let since: Date
    /// No chat took it (a host or account change, or it waited too long); it's offered again.
    let onDropped: @MainActor (String) -> Void
}
