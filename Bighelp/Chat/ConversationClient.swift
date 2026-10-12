import Foundation

/// Bounded recovery for requests made while bighelp Link is re-establishing
/// its authenticated socket. The operation stays serial: a retry is not
/// started until the previous request has settled, so one Hermes request
/// slot cannot be consumed by duplicate picker/catalog calls.
@MainActor
enum BighelpLinkTransientRetry {
    static let defaultDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(750),
    ]

    static func perform<Value>(
        delays: [Duration] = defaultDelays,
        operation: () async throws -> Value
    ) async throws -> Value {
        var retry = 0
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isRecoverable(error), retry < delays.count else {
                    throw error
                }
                let delay = delays[retry]
                retry += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    static func isRecoverable(_ error: Error) -> Bool {
        guard let error = error as? BighelpLinkLiveSocketError else { return false }
        return switch error {
        case .timedOut, .disconnected:
            true
        default:
            false
        }
    }
}

@MainActor
protocol ConversationClient {
    var allowsLocalAgentReassignment: Bool { get }
    func send(message: String, conversationID: String) async throws -> ConversationResponse
    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse
}

extension ConversationClient {
    var allowsLocalAgentReassignment: Bool { true }
}

@MainActor
protocol StreamingConversationClient: ConversationClient {
    func send(
        message: String,
        conversationID: String,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> ConversationResponse
}

@MainActor
protocol AttachmentConversationClient: ConversationClient {
    var supportedAttachmentKinds: Set<ChatAttachment.Kind> { get }
    func send(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> ConversationResponse
}

extension AttachmentConversationClient {
    var supportedAttachmentKinds: Set<ChatAttachment.Kind> { [.image, .file] }
}

@MainActor
protocol MidSessionConversationClient: ConversationClient {
    func sendMidSession(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String,
        behavior: MidSessionChatBehavior,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> MidSessionSubmissionOutcome
}

@MainActor
protocol QueuedConversationClient: ConversationClient {
    func submit(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String
    ) async throws
}

@MainActor
protocol StoppableConversationClient: ConversationClient {
    /// Stops the currently running Hermes turn for this exact session through
    /// Hermes' registered `/stop` command.
    func stop(conversationID: String) async throws
}

/// Advanced › Compact: the host folds a chat's earlier messages into a summary, the same chat
/// with a lighter memory. The client shows the work on its chat's `compaction` rail.
@MainActor
protocol CompactingConversationClient: ConversationClient {
    func compact(conversationID: String) async throws
}

@MainActor
protocol InactiveSessionReconciliationConversationClient: ConversationClient {
    /// Retires only the local waiter for a turn Hermes already reports as
    /// inactive. This must not send `/stop` or otherwise mutate Hermes.
    func reconcileInactiveSession(conversationID: String)
    func pendingMessageID(conversationID: String) -> String?
}

extension InactiveSessionReconciliationConversationClient {
    func pendingMessageID(conversationID: String) -> String? { nil }
}

@MainActor
protocol DemoSleeper {
    func sleep() async
}

struct ImmediateDemoSleeper: DemoSleeper {
    func sleep() async {}
}

struct VisibleDemoSleeper: DemoSleeper {
    let duration: Duration

    init(duration: Duration = .milliseconds(420)) {
        self.duration = duration
    }

    func sleep() async {
        try? await Task.sleep(for: duration)
    }
}
