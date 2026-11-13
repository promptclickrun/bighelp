import Foundation

/// The two views of the first tab: one row per bot and group chat, or every chat, newest first.
/// The person picks which one the app opens on; the header's switch changes it for this run.
enum HomeConversationsView: String, CaseIterable, Sendable {
    case bots, chats

    var title: String {
        switch self {
        case .bots: String(localized: "Bots")
        case .chats: String(localized: "Chats")
        }
    }
}

/// Where the app opens (Settings › Chat › Opens on). Bots and Chats open the first tab on that view.
enum HomeLanding: String, CaseIterable, Sendable {
    case bots, chats, today, work

    var title: String {
        switch self {
        case .bots: String(localized: "Bots")
        case .chats: String(localized: "Chats")
        case .today: String(localized: "Today")
        case .work: String(localized: "Work")
        }
    }
}

/// The three places of the one home. The first takes the name of the person's default view.
enum HomeTab: String, CaseIterable, Sendable {
    case conversations, today, work
}
