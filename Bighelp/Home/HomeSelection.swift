import Foundation
import Observation

/// Where the one home is and what it holds above any one computer: the bar's tab, the first tab's
/// view (Bots or Chats), New chat's picks, and Today's panels and boards. Every computer has its own
/// `AppState`, stores and chats (`NativeWorkspaceRuntime`); these stay when the computer in use
/// changes, so a bot picked on another computer keeps the tab, the view and the To row.
@MainActor
@Observable
final class HomeSelection {
    /// The app's own. Tests and previews make one of their own (`AppState()`).
    static let shared = HomeSelection()

    var tab: HomeTab = .conversations
    /// The first tab's view. The header's switch changes it for this run; a launch starts on
    /// `SettingsStore.homeView`.
    var view: HomeConversationsView = .chats

    /// New chat's text and To row on their way to another computer with a pick (`handOffNewChat`,
    /// `takeNewChatHandoff(after:)`).
    @ObservationIgnored var newChatHandoff: NewChatHandoff?
    /// An alert that names no chat asked for Needs you (`AppState.openNeedsYou`). Here, not in an
    /// `AppState`: every computer has its own, and the one that got the tap isn't always the one
    /// the shell on screen reads.
    var isNeedsYouRequested = false

    @ObservationIgnored private(set) lazy var newChat = NewChatSession()
    @ObservationIgnored private(set) lazy var todayLayout = TodayPanelLayoutStore()
    @ObservationIgnored private(set) lazy var todayBoards = TodayBoardsStore()

    /// Where the app opens (Settings › Chat › Opens on), applied once as the app starts: Bots and
    /// Chats are the first tab's views. No chat opens by itself.
    func land(on landing: HomeLanding, view defaultView: HomeConversationsView) {
        switch landing {
        case .bots: (tab, view) = (.conversations, .bots)
        case .chats: (tab, view) = (.conversations, .chats)
        case .today: (tab, view) = (.today, defaultView)
        case .work: (tab, view) = (.work, defaultView)
        }
    }
}
