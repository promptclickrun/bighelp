import Foundation

/// Reads a coding session's status from its live chat, where the app keeps one,
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
            return .needsYou(prompt.kind == .approval ? Self.approveCommand : Self.answerQuestion)
        }
        // A chat that isn't open has no prompts here; the dashboard's list (what Today's Needs you
        // reads) still says it waits. The chat is never opened or resumed to find out.
        if let ask = Self.waitingAsk(for: sessionID, in: features.dashboardModel.snapshot?.attentionItems ?? []) {
            return .needsYou(ask)
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

    private static var approveCommand: String { String(localized: "Approve a command") }
    private static var answerQuestion: String { String(localized: "Answer a question") }

    /// What the dashboard lists as waiting on the person in this session: an approval or a question.
    static func waitingAsk(for sessionID: String, in items: [DashboardAttentionItem]) -> String? {
        for item in items where item.sessionID == sessionID {
            switch item.interaction {
            case .approval: return approveCommand
            case .clarification: return answerQuestion
            case .none: continue
            }
        }
        return nil
    }
}
