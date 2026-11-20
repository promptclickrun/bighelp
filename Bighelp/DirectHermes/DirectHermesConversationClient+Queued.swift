import Foundation

/// Send-and-return admission for callers that must not hold the turn open,
/// such as a Shortcut run with "Wait for response" turned off. The ordinary
/// submission still owns the turn and its settlement; this returns as soon as
/// Hermes has definitely admitted the prompt, or throws if it did not.
extension DirectHermesConversationClient: QueuedConversationClient {
    func submit(message: String, attachments: [ChatAttachment], conversationID: String) async throws {
        try await submit(message: message, attachments: attachments, conversationID: conversationID,
                         submissionID: UUID())
    }

    func submit(message: String, attachments: [ChatAttachment], conversationID: String,
                submissionID: UUID) async throws {
        let owner = generation
        let outcome = QueuedSubmissionOutcome()
        let turn = Task { @MainActor in
            defer { outcome.finished = true }
            do {
                _ = try await self.send(message: message, attachments: attachments,
                                        conversationID: conversationID, onDraft: { _ in },
                                        submissionID: submissionID)
            } catch {
                outcome.error = error
            }
        }
        // Admission normally lands within a second. Bound the wait so a lost
        // receipt reports failure instead of hanging the Shortcut.
        let deadline = ContinuousClock.now + .seconds(45)
        while !outcome.finished {
            if Task.isCancelled { turn.cancel(); throw CancellationError() }
            guard generation == owner else { throw WorkspaceClientError.outcomeUnknown }
            // `admitted` is reset by submit(); only trust it once this send owns
            // the pending slot.
            if pendingID != nil, admitted { return }
            guard ContinuousClock.now < deadline else { throw WorkspaceClientError.outcomeUnknown }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let error = outcome.error { throw error }
    }
}

@MainActor
private final class QueuedSubmissionOutcome {
    var finished = false
    var error: Error?
}
