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
    /// Why Send sent nothing, or what it waits for, until the next change (`NewChatSend.Note`).
    private(set) var note: NewChatSend.Note?
    /// Goes up each time a note is said, the same one too, so VoiceOver hears every press of Send.
    private(set) var noteCount = 0
    /// Goes up when Send needs someone in the To row: its field takes the cursor.
    private(set) var fieldFocusRequests = 0
    /// What Send left for the shell on screen to do (`NewChatSendRelay`); `NewChatToRow` hands it
    /// over. Send itself holds no view, so it can only ask.
    private(set) var pendingRequest: NewChatRequest?
    private(set) var requestCount = 0
    /// A group chat is being made from this New chat. Send waits for it: a second press would
    /// make a second group chat.
    private(set) var isStartingGroup = false

    var kind: NewChatRecipients.Kind { NewChatRecipients.kind(of: recipients) }

    /// A tap in the people list. True when the recipients changed.
    @discardableResult
    func toggle(_ bot: SimpleBotsBot, rules: NewChatGroupRules) -> Bool {
        let change = NewChatRecipients.toggling(bot, in: recipients, rules: rules)
        refusal = change.refusal
        note = nil
        guard change.picked != recipients else { return false }
        setRecipients(change.picked)
        query = ""
        return true
    }

    /// A chip's ×.
    func remove(_ bot: SimpleBotsBot) {
        refusal = nil
        note = nil
        setRecipients(NewChatRecipients.removing(bot, from: recipients))
    }

    /// Starts over with `bots`, as New chat from a bot's page does with that bot.
    func start(with bots: [SimpleBotsBot] = [], conversationID: String? = nil) {
        recipients = Array(bots.prefix(BotModeRoom.maximumMembers))
        self.conversationID = conversationID
        project = nil
        query = ""
        refusal = nil
        note = nil
        pendingRequest = nil
        isStartingGroup = false
    }

    // MARK: Send

    /// Says why Send sent nothing; nil takes the line away.
    func show(_ note: NewChatSend.Note?) {
        self.note = note
        if note != nil { noteCount += 1 }
    }

    /// Send with nobody picked: it says so, and the To row's field takes the cursor.
    func askWho() {
        show(.nobody)
        fieldFocusRequests += 1
    }

    /// Leaves `request` for the shell on screen. A group chat counts as starting from here on, so a
    /// second Send before the shell has taken the request waits too.
    func ask(_ request: NewChatRequest) {
        if request == .startGroup {
            isStartingGroup = true
            show(.starting)
        }
        pendingRequest = request
        requestCount += 1
    }

    func takeRequest() -> NewChatRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }

    /// The group chat opened, or making it failed: Send is free again. Every way it can end calls this.
    func groupEnded() {
        isStartingGroup = false
        if note == .starting { note = nil }
    }

    /// A project belongs to one bot's coding session: another bot, or a second one, drops it.
    private func setRecipients(_ picked: [SimpleBotsBot]) {
        let sameBot = recipients.count == 1 && picked.count == 1 && picked[0].id == recipients[0].id
        if !sameBot { project = nil }
        recipients = picked
    }
}
