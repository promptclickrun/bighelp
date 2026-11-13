import Foundation

/// The Bots view's unread dots (#862). On a computer that keeps read state, a bot shows its Bot Chat's,
/// a group chat its own, and Mark Read and Mark Unread go to Hermes, so every client agrees. The
/// marks kept on this device (`SimpleBotsUnreadStore`) stand in where Hermes has none: a computer
/// without read state, another gateway's bots, group chats that aren't Hermes chats.
@MainActor
enum SimpleBotsReadState {
    /// The bot's Bot Chat (the one a tap on the bot opens) when Hermes keeps its read state.
    static func botChat(_ profileID: String, in records: [SessionRecord]) -> SessionRecord? {
        guard let chat = records.first(where: { $0.isBotChat && $0.agentIDs == [profileID] }),
              chat.isUnread != nil else { return nil }
        return chat
    }
}
