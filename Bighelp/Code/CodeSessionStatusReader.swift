import Foundation

/// Reads a Bighelp IDE session's status from its live chat, where the app keeps one,
/// and otherwise from the session list (which Hermes's active sessions refresh).
@MainActor
protocol CodeSessionStatusReading {
    func status(of sessionID: String) -> CodeSessionStatus
}

@MainActor
struct CodeChatStatusReader: CodeSessionStatusReading {
    let catalog: SessionCatalogStore
    let features: ShellFeatureStore

    func status(of sessionID: String) -> CodeSessionStatus {
        let chat = features.preparedChatModel(id: sessionID)
        if let prompt = chat?.nativeConversationClient?.prompts.first {
            return .needsYou(prompt.kind == .approval ? "Approve a command" : "Answer a question")
        }
        let record = catalog.session(id: sessionID)
        let isRunning = chat?.isSending == true
            || chat?.nativeConversationClient?.sessionActionsAreRunning == true
            || record?.hasActiveWork == true
        guard isRunning else { return .ready }
        let events = chat?.activityLedger.allEvents ?? record?.activityEvents ?? []
        guard let last = events.last, !last.lifecycle.isTerminal else { return .running(nil) }
        let title = last.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .running(title.isEmpty ? nil : title)
    }
}
