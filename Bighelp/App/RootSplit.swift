import SwiftUI

// The iPhone Duo open (`BighelpSplitColumn`): Bots mode's home, the chat list or Code's home beside
// the page, and the chat they open pushed beside them on the one navigation stack.
extension RootShellView {
    enum SplitList: Hashable {
        case bots, chats, code
        /// Any other page, while a chat opened from it is open: the page stays left of the fold.
        case page(AppTab)

        /// A list that stays beside the page; the stack's own root shows a placeholder instead.
        var isList: Bool {
            if case .page = self { return false }
            return true
        }
    }

    /// What the open Duo shows left of the fold for the tab showing now; nil anywhere else. Bots
    /// mode's home, the chat list and Code's home always; any other page while one of its chats is
    /// open, so a chat never lies across the fold.
    var splitList: SplitList? {
        guard screen.posture == .open else { return nil }
        switch appState.selectedTab {
        case .sessions, .sessionList:
            if simpleBotsOn { return .bots }
            // All agents has its own wide home.
            if !fleetModeOn { return .chats }
        case .code:
            if !simpleBotsOn { return .code }
        default:
            break
        }
        return showsChatOverPage ? .page(appState.selectedTab) : nil
    }

    /// A chat (or Code's batch chat) is open over a page.
    private var showsChatOverPage: Bool {
        switch appState.path.first {
        case .chat?, .codeBatch?: true
        default: false
        }
    }

    /// Changes when another list, or another computer's, should show.
    var splitColumnKey: String {
        let list: String = switch splitList {
        case .bots: "bots"
        case .chats: "chats"
        case .code: "code"
        case .page(let tab): "page:\(tab.rawValue)"
        case nil: "none"
        }
        // A new shell (another computer, all hosts on or off, a new runtime) brings its own stores,
        // and the chat list and Code's home are made once the computer answers. Their stores don't
        // tell the column when that happens, so the column is drawn again then.
        let ready: String = switch splitList {
        case .chats: featureStore.preparedModel(for: .sessions) == nil ? "loading" : "ready"
        case .code: codeHome?.scopeID ?? "loading"
        default: ""
        }
        return [list, currentWorkspaceOwner?.cacheScopeID ?? "local", splitColumnShellID.uuidString,
                nativeRuntime.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-", fleet == nil ? "" : "fleet", ready]
            .joined(separator: "|")
    }

    func updateSplitColumn() {
        guard let splitColumn else { return }
        guard let list = splitList else {
            splitColumn.hide()
            return
        }
        // The list the root would have made, made before the column first draws it.
        if list == .chats, featureStore.preparedModel(for: .sessions) == nil {
            _ = featureStore.prepareSessions(filteredTo: nil)
        }
        splitColumn.show(splitColumnKey) {
            AnyView(splitColumnList(list)
                .environment(\.agentDeletion, agentDeletionAction)
                .environment(\.providerUsage, providerUsage))
        }
    }

    @ViewBuilder
    private func splitColumnList(_ list: SplitList) -> some View {
        switch list {
        case .bots:
            // Bots mode's home draws its own header.
            BighelpLiveColumn { simpleBotsHome }
                .toolbar(.hidden, for: .navigationBar)
        case .chats:
            BighelpLiveColumn { sessionsRootTab }
                .navigationTitle(String(localized: "Sessions"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { splitColumnToolbar }
        case .code:
            BighelpLiveColumn { codeRootTab }
                .navigationTitle(String(localized: "Code"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { splitColumnToolbar }
        case .page:
            // Boards draw their own header; the rest have the page's title and ☰.
            BighelpLiveColumn { rootTabs }
                .toolbar(showsAgentBoard(appState.selectedTab) ? .hidden : .automatic, for: .navigationBar)
                .navigationTitle(rootNavigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { splitColumnToolbar }
        }
    }

    /// ☰ and the brand (or the Unified Mode Toggle) move from the page's bar to the list's.
    @ToolbarContentBuilder
    private var splitColumnToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { rootMenuButton }
        if let barModeSwitch {
            ToolbarItem(placement: .principal) { BighelpModePill(modeSwitch: barModeSwitch) }
        }
    }

    /// The page beside the list before anything is open in it.
    func splitPlaceholder(_ list: SplitList) -> some View {
        let message = switch list {
        case .bots: String(localized: "Pick a bot to chat with.")
        case .chats: String(localized: "Pick a chat, or start a new one.")
        case .code: String(localized: "Pick a session, or send a new one.")
        case .page: ""
        }
        return BighelpSplitPlaceholder(message: message)
    }
}
