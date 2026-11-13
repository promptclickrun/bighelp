import SwiftUI

// The iPhone Duo open (`BighelpSplitColumn`): the tab's root left of the fold, and the chat it opens
// pushed beside it on the one navigation stack.
extension RootShellView {
    enum SplitList: Hashable {
        /// The first tab (Bots or Chats) and Work: always beside the page.
        case conversations, work
        /// Today, while a chat opened from it is open: it stays left of the fold.
        case page(HomeTab)

        /// A list that stays beside the page; the stack's own root shows a placeholder instead.
        var isList: Bool {
            if case .page = self { return false }
            return true
        }
    }

    /// What the open Duo shows left of the fold for the tab showing now; nil anywhere else. The
    /// first tab and Work always; Today while one of its chats is open, so a chat never lies
    /// across the fold.
    var splitList: SplitList? {
        guard screen.posture == .open else { return nil }
        switch appState.selectedTab {
        case .conversations: return .conversations
        case .work: return .work
        case .today: return showsChatOverPage ? .page(.today) : nil
        }
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
        case .conversations: "conversations:\(home.view.rawValue)"
        case .work: "work"
        case .page(let tab): "page:\(tab.rawValue)"
        case nil: "none"
        }
        // A new shell (another computer, a new runtime) brings its own stores, which don't tell
        // the column when that happens, so the column is drawn again then.
        return [list, currentWorkspaceOwner?.cacheScopeID ?? "local", splitColumnShellID.uuidString,
                nativeRuntime.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-", fleet == nil ? "" : "fleet"]
            .joined(separator: "|")
    }

    func updateSplitColumn() {
        guard let splitColumn else { return }
        guard let list = splitList else {
            splitColumn.hide()
            return
        }
        let tab: HomeTab = switch list {
        case .conversations: .conversations
        case .work: .work
        case .page(let tab): tab
        }
        splitColumn.show(splitColumnKey) {
            // Every root draws its own header, so the column's bar stays hidden.
            AnyView(BighelpLiveColumn { homeRoot(tab) }
                .toolbar(.hidden, for: .navigationBar)
                .environment(\.agentDeletion, agentDeletionAction)
                .environment(\.providerUsage, providerUsage))
        }
    }

    /// The page beside the list before anything is open in it.
    func splitPlaceholder(_ list: SplitList) -> some View {
        let message = switch list {
        case .conversations where home.view == .bots: String(localized: "Pick a bot to chat with.")
        case .conversations: String(localized: "Pick a chat, or start a new one.")
        case .work: String(localized: "Pick something to open.")
        case .page: ""
        }
        return BighelpSplitPlaceholder(message: message)
    }
}
