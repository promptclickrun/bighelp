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
    /// Send asks this first. True means the message went elsewhere (a group chat, a coding session)
    /// and whoever took it empties the box; false sends in this chat as usual. It must not capture a
    /// view: the message box keeps it for as long as the chat is open.
    var sendOverride: (@MainActor () -> Bool)? = nil
    /// False takes + away: a message a group chat or a coding session takes goes as text only.
    var offersAttachments = true
}
