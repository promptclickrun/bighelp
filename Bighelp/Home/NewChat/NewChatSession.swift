import Foundation
import Observation

/// What New chat holds while nothing is sent: who it's to, the blank chat the message box belongs
/// to, and the project a coding session would start in. The shell keeps one above every computer's
/// objects, so a pick on another computer (which switches the computer in use) keeps it.
@MainActor
@Observable
final class NewChatSession {
    /// In the order they were picked; the first one's computer is a group's home. Keyed by
    /// `SimpleBotsBot.id`, which is a `FleetID` while every computer's bots show.
    private(set) var recipients: [SimpleBotsBot] = []
    /// The blank chat the message box belongs to (`ChatModel.conversationID`).
    var conversationID: String?
    /// The project a coding session starts in; nil is an ordinary chat. Only with exactly one bot.
    var project: CodeProject?
    /// The To row's field, which filters the people list.
    var query = ""
    /// Why the last pick was refused, until the next change.
    private(set) var refusal: NewChatRecipients.Refusal?

    var kind: NewChatRecipients.Kind { NewChatRecipients.kind(of: recipients) }

    /// A tap in the people list. True when the recipients changed.
    @discardableResult
    func toggle(_ bot: SimpleBotsBot, rules: NewChatGroupRules) -> Bool {
        let change = NewChatRecipients.toggling(bot, in: recipients, rules: rules)
        refusal = change.refusal
        guard change.picked != recipients else { return false }
        setRecipients(change.picked)
        query = ""
        return true
    }

    /// A chip's ×.
    func remove(_ bot: SimpleBotsBot) {
        refusal = nil
        setRecipients(NewChatRecipients.removing(bot, from: recipients))
    }

    /// Starts over with `bots`, as New chat from a bot's page does with that bot.
    func start(with bots: [SimpleBotsBot] = [], conversationID: String? = nil) {
        recipients = Array(bots.prefix(BotModeRoom.maximumMembers))
        self.conversationID = conversationID
        project = nil
        query = ""
        refusal = nil
    }

    /// A project belongs to one bot's coding session: another bot, or a second one, drops it.
    private func setRecipients(_ picked: [SimpleBotsBot]) {
        let sameBot = recipients.count == 1 && picked.count == 1 && picked[0].id == recipients[0].id
        if !sameBot { project = nil }
        recipients = picked
    }
}
