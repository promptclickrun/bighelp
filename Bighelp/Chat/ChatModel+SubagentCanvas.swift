import Foundation

/// Helpers (`delegate_task` children) this chat can watch.
extension ChatModel {
    enum SubagentHistoryRead: Equatable, Sendable {
        case adopted
        /// Not saved yet, or the host couldn't be read; the live steps stay.
        case unavailable
        /// Nothing to read: no child session yet, a group chat, or a replaced chat.
        case skipped
    }

    /// A group chat shows what its members say, not their work, so it keeps no
    /// helper canvases, like it shows no helper rail.
    func acceptSubagentEvent(type: String, payload: [String: BighelpJSONValue],
                             from client: DirectHermesConversationClient) {
        guard !referenceOwnerRetired, !isBotMode, nativeConversationClient === client else { return }
        subagentCanvases.accept(type: type, payload: payload)
    }

    /// Reads the helper's saved session through this chat's own connection and
    /// adopts it only if the chat still belongs to that connection.
    @discardableResult
    func refreshSubagentHistory(id: String) async -> SubagentHistoryRead {
        guard !referenceOwnerRetired, !isBotMode, let native = nativeConversationClient,
              let state = subagentCanvases[id], let child = state.childSessionID else { return .skipped }
        let finished = state.isFinished
        do {
            let history = try await native.subagentHistory(childSessionID: child, subagentID: id)
            guard !referenceOwnerRetired, nativeConversationClient === native else { return .skipped }
            subagentCanvases.adoptHistory(history, for: id, readAfterFinish: finished)
            return .adopted
        } catch {
            return .unavailable
        }
    }
}
