import Foundation

struct ChatMentionIdentity: Equatable, Sendable {
    let handle: String
    let name: String
}

extension ChatModel {
    var messageMentionIdentities: [ChatMentionIdentity] {
        if isBotMode {
            return nativeRoomParticipants.map { .init(handle: $0.handle, name: $0.displayName) }
        }
        return (agentDirectory?.profiles ?? []).map {
            .init(handle: AgentHandle.normalized($0.name), name: $0.name)
        }
    }
}
