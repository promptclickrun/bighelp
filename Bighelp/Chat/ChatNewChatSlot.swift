import SwiftUI

/// One home: what the shell gives the one chat that is New chat's blank chat, so the ordinary chat
/// screen is also the New chat screen. The chat draws these only while nothing is sent in it: from
/// its first message on (staged, sending or sent) it is an ordinary chat, whatever is still passed.
///
/// The shell decides which chat gets one from the chat's id (`NewChatSession.conversationID`), never
/// from its messages. The parts are the shell's own views (`NewChatToRow`, `NewChatPeopleList`,
/// `NewChatChoicesRow`), each with its own state: a change in one redraws that part, not the chat.
@MainActor
struct ChatNewChatSlot {
    /// "To:" and the picked bots, the whole width under Back and ⋯, where the bot's name would be.
    let toRow: AnyView
    /// The bots to pick from, over the empty messages, between the To row and the message box.
    var people: AnyView? = nil
    /// The choices under the message box that can make the chat a coding session (one picked bot).
    var choicesRow: AnyView? = nil
    /// Send asks this first, saying whether the box holds references. True means the message went
    /// elsewhere (a group chat, a coding session), which empties the box once it has the message, or
    /// that it can't go yet, which leaves the box as it was and says why under the To row; false
    /// sends in this chat as usual. It must not capture a view: the message box keeps it for as long
    /// as the chat is open (`NewChatSendRelay`).
    var sendOverride: (@MainActor (_ holdsReferences: Bool) -> Bool)? = nil
    /// False takes + away: a message a group chat or a coding session takes goes as text only.
    var offersAttachments = true
    /// The To row holds exactly one bot and this chat is that bot's. False hides what acts on the
    /// chat's own bot (voice, ⋯ › Bot page): with nobody picked, or two or more, that is another bot
    /// than the To row shows.
    var isOneBotsChat = true
}

extension ChatModel {
    /// Nothing is sent here and nothing failed: New chat's blank chat still draws its To row. A
    /// first message (waiting, on its way or sent) makes it an ordinary chat.
    var isBlankForNewChat: Bool {
        transcriptEntries.isEmpty && stagedSends.isEmpty && bigFileSends.isEmpty && !isSending
            && !hasPreviousHistory && failureMessage == nil
    }

    /// The box holds more than text: attachments (also ones still being added, or that didn't
    /// attach) or references. Only this chat's own send carries them; they can't move to another chat.
    var holdsAttachmentsOrReferences: Bool {
        hasDraftAttachmentActivity || !referenceSelections.isEmpty
    }
}
