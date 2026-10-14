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

/// Stop and Steer for a running helper, over this chat's own connection.
extension ChatModel {
    /// What came of a Stop or a Steer, in the person's words.
    enum SubagentControlOutcome: Equatable, Sendable {
        case steerQueued
        case steerRejected
        case stopping
        /// Hermes has no such helper running for this chat: it already ended.
        case alreadyEnded
        /// This chat's connection isn't the one the helper answers to (it reconnected).
        case unreachable
        case unsupported
        case failed

        var message: String {
            switch self {
            case .steerQueued: "Sent. It reads your message before its next step."
            case .steerRejected: "It isn't taking messages right now."
            case .stopping: "Stopping…"
            case .alreadyEnded: "It had already finished."
            case .unreachable: "This chat can't reach that helper anymore."
            case .unsupported: "Hermes on this computer can't do that."
            case .failed: "Couldn't reach it. Try again."
            }
        }

        var isProblem: Bool {
            switch self {
            case .steerQueued, .stopping: false
            default: true
            }
        }
    }

    static let maximumSteerLength = 4_000

    var canStopSubagents: Bool { supportsSubagentControl(.subagentStop) }
    var canSteerSubagents: Bool { supportsSubagentControl(.subagentSteer) }

    private func supportsSubagentControl(_ capability: WorkspaceCapability) -> Bool {
        guard !referenceOwnerRetired, !isBotMode, let native = nativeConversationClient else { return false }
        return native.supportsCapability?(capability) ?? false
    }

    /// Asks Hermes which helpers take a message now. A failed read keeps what
    /// the chat knew.
    func refreshSubagentSteering() async {
        guard canSteerSubagents, let native = nativeConversationClient else { return }
        guard let steering = try? await native.subagentSteering(),
              !referenceOwnerRetired, nativeConversationClient === native else { return }
        subagentCanvases.adoptSteering(steering)
    }

    func steerSubagent(id: String, text: String) async -> SubagentControlOutcome {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= Self.maximumSteerLength else { return .failed }
        guard canSteerSubagents, let native = nativeConversationClient else { return .unsupported }
        do {
            let queued = try await native.steerSubagent(id: id, text: message)
            guard nativeConversationClient === native else { return .unreachable }
            // A refused message means it stopped taking them.
            if !queued { subagentCanvases.setAcceptsSteering(false, for: id) }
            return queued ? .steerQueued : .steerRejected
        } catch {
            return Self.subagentControlOutcome(for: error)
        }
    }

    func stopSubagent(id: String) async -> SubagentControlOutcome {
        guard canStopSubagents, let native = nativeConversationClient else { return .unsupported }
        do {
            let found = try await native.interruptSubagent(id: id)
            guard nativeConversationClient === native else { return .unreachable }
            return found ? .stopping : .alreadyEnded
        } catch {
            return Self.subagentControlOutcome(for: error)
        }
    }

    static func subagentControlOutcome(for error: any Error) -> SubagentControlOutcome {
        guard case .rpcRejected(let code, _)? = error as? DirectHermesError else { return .failed }
        switch code {
        case -32601: return .unsupported
        case 4001: return .unreachable
        default: return .failed
        }
    }
}
