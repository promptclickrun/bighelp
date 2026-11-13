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

@MainActor
@Observable
final class AppState {
    /// The home's tab and view, and what New chat and Today hold. One for the whole app: every
    /// computer has its own `AppState`, and a chat opened on another computer keeps the tab.
    let home: HomeSelection
    /// The bar's tab. A pushed page stays over it; `select` clears the path.
    var selectedTab: HomeTab {
        get { home.tab }
        set { home.tab = newValue }
    }
    var path: [AppRoute] = []
    /// The chat last opened (`activateConversation`).
    private var activatedConversationID: String?
    /// The chat the person opened last, while it is still on the stack. Back, a tab or anything
    /// else that takes it off ends it: it once kept naming a chat that had closed, and the phone
    /// tools and Needs you went on treating that chat as the open one.
    var activeConversationID: String? {
        guard let id = activatedConversationID, path.contains(.chat(conversationID: id)) else { return nil }
        return id
    }
    /// The chat whose bot reaches this phone's tools: the chat opened last, also after Back to a list
    /// while that bot still works. A bot that goes on working must not lose the phone's tools
    /// because the person stepped out of its chat.
    var deviceToolConversationID: String? { activatedConversationID }
    private(set) var pendingVoiceConversationID: String?
    /// Text a board "Ask" or "Discuss" leaves in the next new chat's composer.
    var pendingComposerText: String?
    /// The open chat's agent and text when the app left, while that chat had sent nothing.
    /// Hermes saves a chat only on its first message, so it can be gone on return.
    var suspendedChat: SuspendedChat?
    /// `pendingComposerText` is a blueprint: its `[blanks]` show as chips to fill in (`ChatBlueprintDraft`).
    var pendingComposerFillsBlanks = false
    /// `pendingComposerText` is a message to send, not a draft (Let's do it): the chat that takes
    /// it sends it and leaves its message box alone.
    var pendingComposerSendsAtOnce = false
    /// The bot whose own chat may take `pendingComposerText` even though it has history: a bot's
    /// Dashboard opens that bot's Bot Chat, never a new one. Only an empty message box takes it.
    var pendingComposerAgentID: String?
    /// Chats that send their draft once connected: a branch made when Hermes refused a
    /// message because another Hermes process held the original (`continueInBranch`).
    var sendsDraftOnOpen: Set<String> = []
    /// A share from another app on its way to the message box of the chat the person picked
    /// (`PendingShareCenter`). Only that chat takes it, never another computer's.
    private(set) var pendingShare: PendingShareHandoff?

    /// The Settings sheet. It lives here, not in the shell's view state, so code outside the
    /// view (an agent's drive) can open it straight to a page: `openSettings(at:)`.
    var isSettingsPresented = false
    /// What the Settings sheet's stack shows above its first page: `SettingsDestination` values.
    var settingsPath = NavigationPath()
    /// Set by `openNeedsYou()`, before the shell is on screen too; kept until the shell settles it
    /// (`RootShellView.settleNeedsYouRequest`). One for the whole app (`HomeSelection`), so the shell
    /// on screen sees a request whichever computer's `AppState` took it.
    var isNeedsYouRequested: Bool {
        get { home.isNeedsYouRequested }
        set { home.isNeedsYouRequested = newValue }
    }

    /// Tests and previews get a selection of their own; the app passes `HomeSelection.shared`.
    init(home: HomeSelection = HomeSelection()) {
        self.home = home
    }

    /// A tab is a root, never another level in the current route: whatever was pushed closes.
    func select(_ tab: HomeTab) {
        selectedTab = tab
        path.removeAll()
    }

    /// The first tab on one of its views (a link to Bots or to Chats).
    func select(_ view: HomeConversationsView) {
        home.view = view
        select(.conversations)
    }

    func open(_ route: AppRoute) {
        path.append(route)
    }

    /// Switches to `tab` and opens `routes` on it. On the Mac they open a moment
    /// after the switch: pushed in the same update, the tab's title-bar search
    /// field stayed drawn over the pushed page's Back button and blocked it.
    func select(_ tab: HomeTab, thenOpen routes: [AppRoute]) {
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
    /// pages it opens the first screen. Replaces the pages when Settings is already open.
    func openSettings(at pages: [SettingsDestination] = []) {
        var next = NavigationPath()
        for page in pages { next.append(page) }
        settingsPath = next
        isSettingsPresented = true
    }

    func closeSettings() {
        isSettingsPresented = false
        settingsPath = NavigationPath()
    }

    /// An alert that names no chat: the shell opens Needs you when something waits, else Today
    /// (`RootShellView.settleNeedsYouRequest`).
    func openNeedsYou() {
        isNeedsYouRequested = true
    }

    func activateConversation(id: String, source: ConversationActivationSource) {
        let route = AppRoute.chat(conversationID: id)
        // Already open (a notification, widget or link about it): go back to that copy. A second
        // copy would share its model, both would redraw every change, and Back would show it again.
        if let open = path.lastIndex(of: route) {
            path.removeSubrange(path.index(after: open)...)
            activatedConversationID = id
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
        activatedConversationID = id
    }

    /// New chat's blank chat leaves the stack once the chat that takes its place (a group chat) is
    /// over it, so Back doesn't show an empty New chat. `isBlank`: nothing was sent in it. A chat
    /// with a message is an ordinary chat and stays, whatever opens over it.
    func dropBlankChat(_ blankID: String, under conversationID: String, isBlank: Bool) {
        guard isBlank, blankID != conversationID,
              path.contains(.chat(conversationID: conversationID)) else { return }
        path.removeAll { $0 == .chat(conversationID: blankID) }
    }

    /// The chat the person is in: the active one, else the chat on top of the path.
    var chatOnScreen: String? {
        if let activeConversationID { return activeConversationID }
        if case .chat(let id)? = path.last { return id }
        return nil
    }

    func requestVoiceMode(for conversationID: String) {
        pendingVoiceConversationID = conversationID
    }

    /// Another computer: its pages close and the tab stays. The connections screen stays up while
    /// you switch computers from it.
    func resetForHostBoundary() {
        let showsOnlyConnections = !path.isEmpty && path.allSatisfy { $0 == .workspaceConnections }
        if !showsOnlyConnections { path.removeAll() }
        activatedConversationID = nil
        pendingVoiceConversationID = nil
        clearComposerText()
        dropPendingShare()
    }

    func resetForAccountBoundary() {
        path.removeAll()
        activatedConversationID = nil
        pendingVoiceConversationID = nil
        clearComposerText()
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
    /// `sendsAtOnce`: the chat sends the text as a message of its own (Let's do it).
    func leaveComposerText(_ text: String, fillsBlanks: Bool = false, sendsAtOnce: Bool = false,
                           agentID: String? = nil, now: Date = .now) {
        pendingComposerText = text
        pendingComposerFillsBlanks = fillsBlanks
        pendingComposerSendsAtOnce = sendsAtOnce
        pendingComposerShown = false
        pendingComposerAgentID = agentID
        pendingComposerSince = now
    }

    /// The text for a new chat's blank canvas to show while Hermes makes the chat: read, not taken.
    /// The canvas is thrown away when the chat arrives and its draft doesn't always get across in
    /// time, so the text stays here for that chat to take.
    func showComposerText(now: Date = .now) -> (text: String, fillsBlanks: Bool)? {
        // A message to send isn't a draft: the canvas leaves it for the chat that sends it.
        guard pendingComposerAgentID == nil, !pendingComposerSendsAtOnce, let text = pendingComposerText,
              let since = pendingComposerSince, now.timeIntervalSince(since) <= Self.pendingComposerLifetime
        else { return nil }
        pendingComposerShown = true
        return (text, pendingComposerFillsBlanks)
    }

    /// The text, if this chat should take it: a new chat on top, or the named bot's own chat on top.
    /// `wasShown`: a blank canvas already showed it, so this chat may hold it (and what the person
    /// changed) from the canvas's draft.
    func takeComposerText(isNewChat: Bool, isNamedBotChat: Bool, now: Date = .now)
        -> (text: String, fillsBlanks: Bool, sendsAtOnce: Bool, wasShown: Bool)? {
        guard let text = pendingComposerText else { return nil }
        guard let since = pendingComposerSince, now.timeIntervalSince(since) <= Self.pendingComposerLifetime else {
            clearComposerText()
            return nil
        }
        guard pendingComposerAgentID == nil ? isNewChat : isNamedBotChat else { return nil }
        let taken = (text, pendingComposerFillsBlanks, pendingComposerSendsAtOnce, pendingComposerShown)
        clearComposerText()
        return taken
    }

    private func clearComposerText() {
        pendingComposerText = nil
        pendingComposerFillsBlanks = false
        pendingComposerSendsAtOnce = false
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
