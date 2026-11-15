import Foundation

/// A chat this device holds whose agent is working now.
struct WorkingChat: Equatable, Sendable {
    let conversationID: String
    let agentID: String
    let kind: AgentActivityKind
}

/// Which working chat a place shows. `working` comes newest first.
enum WorkingChatPick {
    /// The Dynamic Island's: the chat on screen while it works, else the home agent's newest
    /// working chat.
    static func island(openConversationID: String?, working: [WorkingChat], homeAgentID: String?) -> WorkingChat? {
        if let open = working.first(where: { $0.conversationID == openConversationID }) { return open }
        return working.first { $0.agentID == homeAgentID && $0.kind.isWorking }
    }

    /// A chat's side column on the iPhone Duo: the newest work in a chat that isn't this one,
    /// whichever agent's it is. This chat says its own work itself.
    static func elsewhere(than conversationID: String?, working: [WorkingChat]) -> WorkingChat? {
        working.first { $0.conversationID != conversationID && $0.kind.isWorking }
    }
}

/// Where "go to the chat that is working" leads from the chat on screen.
enum WorkingChatDestination: Equatable {
    /// The working chat is the one on screen.
    case stay
    case chat(conversationID: String)
    /// The agent's own chat, for work that names no chat.
    case agentChat(agentID: String)

    /// Goes by the chat, never by the agent alone: one agent can work in a chat while another of its
    /// chats is on screen. Comparing agents left that tap doing nothing.
    static func resolve(workingConversationID: String?, agentID: String,
                        openConversationID: String?, openAgentID: String?) -> WorkingChatDestination {
        if let workingConversationID {
            return workingConversationID == openConversationID ? .stay : .chat(conversationID: workingConversationID)
        }
        return agentID == openAgentID ? .stay : .agentChat(agentID: agentID)
    }
}
