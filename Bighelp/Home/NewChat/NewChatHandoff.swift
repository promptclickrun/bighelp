import Foundation

/// New chat's text and To row on their way to another computer with a pick: the blank chat or the
/// group chat made there takes them (`RootShellView.performFleetOpen`). The box they came from
/// keeps its text until then, so a switch that fails loses nothing.
@MainActor
struct NewChatHandoff {
    /// The box's text; nil when it held none.
    let text: String?
    /// The chat about to start on the other computer is New chat's own blank chat (its To row).
    let followsPick: Bool
    /// The blank chat the text came from.
    private(set) weak var source: ChatModel?

    init(text: String?, followsPick: Bool, source: ChatModel?) {
        self.text = text
        self.followsPick = followsPick
        self.source = source
    }

    /// The other computer has the text: the box it came from lets it go, unless the person has
    /// changed it since.
    func delivered() {
        guard let source, let text, !text.isEmpty, source.draft == text else { return }
        source.draft = ""
    }
}

/// How a tap that needed another computer ended (`RootShellView.openFleet`).
enum FleetOpenEnd: Equatable, Sendable {
    /// That computer is the one in use and what was tapped opens.
    case opened
    /// It can't be switched to (the demo's sample computers).
    case refused
    /// The person cancelled the wait.
    case cancelled
    /// It didn't answer, and the computer the tap came from is in use again.
    case unanswered
}

extension HomeSelection {
    /// A New chat pick on another computer: what goes there with the switch.
    func handOffNewChat(_ handoff: NewChatHandoff) {
        newChatHandoff = handoff
    }

    /// The switch ended: only one that opened gets New chat's text and To row. Every other end
    /// drops them (the box still has the text), so a later New chat on that computer never starts
    /// with an old message and To row. A group chat that was on its way counts as ended.
    func takeNewChatHandoff(after end: FleetOpenEnd) -> NewChatHandoff? {
        guard let handoff = newChatHandoff else { return nil }
        newChatHandoff = nil
        guard end == .opened else {
            newChat.groupEnded()
            return nil
        }
        return handoff
    }
}
