import SwiftUI

/// One entry in a bot page's ⋯ menu.
enum BotProfileAction: String, CaseIterable, Identifiable, Sendable {
    case message, newChat, chats, makePrimary, pin, unpin, shortcuts, duplicate
    case showRoutines
    case manageBots
    case delete

    var id: String { rawValue }

    /// Actions on the bot, then managing the computer's bots, then Delete, each after a divider.
    enum Group: Int, Comparable, Sendable {
        case bot, manage, delete
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var group: Group {
        switch self {
        case .manageBots: .manage
        case .delete: .delete
        default: .bot
        }
    }

    var title: String {
        switch self {
        case .message: String(localized: "Message")
        case .newChat: String(localized: "New chat")
        case .chats: String(localized: "Chats with this bot")
        case .makePrimary: String(localized: "Make Primary Bot")
        case .pin: String(localized: "Pin")
        case .unpin: String(localized: "Unpin")
        case .shortcuts: String(localized: "Use with Siri")
        case .duplicate: String(localized: "Duplicate")

        case .showRoutines: String(localized: "Show routines")
        case .manageBots: String(localized: "Manage bots")
        case .delete: String(localized: "Delete bot")
        }
    }

    var systemImage: String {
        switch self {
        case .message: "message"
        case .newChat: "square.and.pencil"
        case .chats: "clock.arrow.circlepath"
        case .makePrimary: "star"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .shortcuts: "waveform"
        case .duplicate: "plus.square.on.square"

        case .showRoutines: "calendar.badge.clock"
        case .manageBots: "person.2.badge.gearshape"
        case .delete: "trash"
        }
    }

    /// `simple-bots.profile.more.<action>`; Show routines keeps the id it had.
    var identifier: String {
        self == .showRoutines ? "simple-bots.profile.show-routines" : "simple-bots.profile.more.\(rawValue)"
    }
}

/// What a bot page can offer right now, from its context and the bot's state.
struct BotProfileMenuCapabilities: Equatable, Sendable {
    /// False while the page waits for the bot's computer to be the one in use: nothing on it can run yet.
    var isOnComputerInUse = true
    var isPrimary = false
    var offersNewChat = false
    var offersChats = false
    var offersPinning = false
    var isPinned = false
    /// Room for one more pin; a bot past the limit offers no Pin.
    var canPinAnother = true
    var offersShortcuts = false
    var offersDuplicate = false

    /// The Dashboard is the tab on screen, where routines show.
    var showsRoutinesToggle = false
    var offersManage = false
    var offersDelete = false
    /// Hermes never deletes its default bot (`AgentDeletionPresentation.canDelete`).
    var isDefaultBot = false
    var isDeleting = false
}

enum BotProfileMenu {
    /// The ⋯ menu's entries in order: actions on the bot, Manage bots, then Delete bot.
    static func actions(_ can: BotProfileMenuCapabilities) -> [BotProfileAction] {
        guard can.isOnComputerInUse else { return [] }
        var actions: [BotProfileAction] = [.message]
        if can.offersNewChat { actions.append(.newChat) }
        if can.offersChats { actions.append(.chats) }
        if !can.isPrimary { actions.append(.makePrimary) }
        if can.offersPinning {
            if can.isPinned { actions.append(.unpin) } else if can.canPinAnother { actions.append(.pin) }
        }
        if can.offersShortcuts { actions.append(.shortcuts) }
        if can.offersDuplicate { actions.append(.duplicate) }

        if can.showsRoutinesToggle { actions.append(.showRoutines) }
        if can.offersManage { actions.append(.manageBots) }
        if can.offersDelete, !can.isDefaultBot, !can.isDeleting { actions.append(.delete) }
        return actions
    }
}

/// The ⋯ menu's items, with a divider between groups. The same items serve the ⋯ button and,
/// on the Mac, a right-click on the bot's face and name.
struct BotProfileMoreMenuItems: View {
    let actions: [BotProfileAction]
    @Binding var showsRoutines: Bool
    let perform: (BotProfileAction) -> Void

    var body: some View {
        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
            if index > 0, actions[index - 1].group != action.group { Divider() }
            if action == .showRoutines {
                Toggle(action.title, systemImage: action.systemImage, isOn: $showsRoutines)
                    .accessibilityIdentifier(action.identifier)
            } else {
                Button(action.title, systemImage: action.systemImage,
                       role: action == .delete ? .destructive : nil) { perform(action) }
                    .accessibilityIdentifier(action.identifier)
            }
        }
    }
}
