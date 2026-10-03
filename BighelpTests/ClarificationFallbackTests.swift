import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ClarificationFallbackTests {
    @Test(arguments: [false, true])
    func rejectedClarificationKeepsAnswerAndOriginalDraft(active: Bool) async throws {
        let harness = Harness(active: active)
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Use TestFlight")
        #expect(harness.source.responses == ["Use TestFlight"])
        #expect(harness.client.messages.isEmpty)
        #expect(harness.source.dismissedIDs.isEmpty)
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.count == 1)
        #expect(harness.store.dashboardModel.mutationErrorMessage != nil)
        #expect(harness.chat.draft == "Unsent composer draft")
        #expect(harness.chat.isSending == active)
        #expect(harness.chat.items.isEmpty)
        #expect(harness.chat.transcriptEntries.isEmpty)
    }

    @Test func expiredClarificationNeverSubmitsOrSendsLateText() async throws {
        let harness = Harness(expired: true)
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Late answer")
        #expect(harness.source.responses.isEmpty)
        #expect(harness.client.messages.isEmpty)
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.isEmpty == true)
    }

    @Test func acceptedClarificationDoesNotAlsoSendChatTextOrReplaceDraft() async throws {
        let harness = Harness()
        harness.source.accepts = true
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "TestFlight")
        #expect(harness.source.responses == ["TestFlight"])
        #expect(harness.client.messages.isEmpty)
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.isEmpty == true)
        #expect(harness.chat.draft == "Unsent composer draft")
        await harness.store.dashboardModel.load()
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.isEmpty == true)
    }

    @Test func definitiveRejectionCanRetryStructuredAnswerWithoutFallback() async throws {
        let harness = Harness()
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Keep this answer")
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.count == 1)
        harness.source.accepts = true
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Keep this answer")
        #expect(harness.source.responses == ["Keep this answer", "Keep this answer"])
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.isEmpty == true)
        #expect(harness.client.messages.isEmpty)
        #expect(harness.chat.items.isEmpty)
    }

    @Test func accountResetDuringStructuredFailureDoesNotSendFallback() async throws {
        let harness = Harness()
        harness.source.beforeFailure = { harness.store.resetForAccountBoundary() }
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Private answer")
        #expect(harness.client.messages.isEmpty)
        #expect(harness.store.dashboardModel.snapshot == nil)
    }

    @Test(arguments: ["timeout", "invalid", "failed", "mismatch"])
    func ambiguousOutcomeOnlyReadsBackAndNeverResubmits(kind: String) async throws {
        let harness = Harness()
        harness.source.ambiguousKind = kind
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Only once")
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Only once")
        #expect(harness.source.responses == ["Only once"])
        #expect(harness.client.messages.isEmpty)
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.count == 1)
        #expect(harness.store.dashboardModel.mutationErrorMessage != nil)
    }

    @Test func failedReadbackDoesNotAuthorizeAnotherSubmission() async throws {
        let harness = Harness()
        harness.source.ambiguousKind = "timeout"
        harness.source.beforeFailure = { harness.source.loadFails = true }
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Once")
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Once")
        #expect(harness.source.responses == ["Once"])
        #expect(harness.client.messages.isEmpty)
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.count == 1)
    }

    @Test func cancelledResponseNeverBecomesAnOrdinaryChatMessage() async throws {
        let harness = Harness()
        harness.source.cancel = true
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Only once")
        #expect(harness.client.messages.isEmpty)
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.count == 1)
    }

    @Test(arguments: [true, false])
    func resolvedCardReadbackSettlesWithoutSendingText(unknownOutcome: Bool) async throws {
        let harness = Harness()
        if unknownOutcome { harness.source.ambiguousKind = "timeout" }
        harness.source.beforeFailure = { harness.source.dismissedIDs.append("clarify-event") }
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Once")
        #expect(harness.source.responses == ["Once"])
        #expect(harness.client.messages.isEmpty)
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.isEmpty == true)
    }

    @Test func missingOriginalChatNeverRedirectsToAnotherChat() async throws {
        let harness = Harness()
        harness.source.sessionID = "missing-original"
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Private answer")
        #expect(harness.client.messages.isEmpty)
        #expect(harness.store.dashboardModel.snapshot?.attentionItems.count == 1)
    }

    @Test func concurrentTapAndAccountResetPreventDuplicateAndLatePublication() async throws {
        let harness = Harness()
        harness.source.accepts = true
        var release: CheckedContinuation<Void, Never>?
        harness.source.beforeResponse = { await withCheckedContinuation { release = $0 } }
        await harness.store.dashboardModel.load()
        let task = Task { await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Private answer") }
        for _ in 0..<1_000 where release == nil { await Task.yield() }
        guard let release else { task.cancel(); Issue.record("Structured request did not start"); return }
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: "Duplicate tap")
        #expect(harness.source.responses == ["Private answer"])
        harness.store.resetForAccountBoundary()
        release.resume()
        await task.value
        #expect(harness.chat.items.isEmpty)
        #expect(harness.client.messages.isEmpty)
        #expect(harness.store.dashboardModel.snapshot == nil)
    }

    @Test func multiSelectSubmitsExactStructuredAnswerOnly() async throws {
        let harness = Harness()
        harness.source.accepts = true
        let answer = "[\"TestFlight\",\"App Store\"]"
        await harness.store.dashboardModel.load()
        await harness.store.dashboardModel.respondToClarification(itemID: "clarify-event", response: answer)
        #expect(harness.source.responses == [answer])
        #expect(harness.client.messages.isEmpty)
        #expect(harness.chat.draft == "Unsent composer draft")
    }
}

@MainActor
private final class Harness {
    let source: FallbackSource
    let client = FallbackConversationClient()
    let store: ShellFeatureStore
    let chat: ChatModel

    init(active: Bool = false, expired: Bool = false) {
        source = FallbackSource(expired: expired)
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient(), records: [
            SessionRecord(id: "visible-original", kind: .direct, agentIDs: ["default"], title: "Original", remoteStoredID: "stored-original", remoteSource: "loopdy", draft: "Unsent composer draft", isActive: active),
            SessionRecord(id: "other-chat", kind: .direct, agentIDs: ["other-agent"], title: "Other")
        ])
        let client = self.client
        store = ShellFeatureStore(timing: .immediate, catalog: catalog, dashboardSource: source, conversationClient: { _, _ in client })
        _ = store.prepare(.chat(conversationID: "visible-original"))
        guard case .chat(let chat) = store.preparedModel(for: .chat(conversationID: "visible-original")) else { fatalError("Missing chat") }
        self.chat = chat
        _ = store.prepare(.chat(conversationID: "other-chat"))
    }
}

@MainActor
private final class FallbackSource: DashboardDataSource, DashboardClarificationClient {
    var ambiguousKind: String?
    var loadFails = false
    var accepts = false
    var dismissFails = false
    var cancel = false
    var sessionID = "stored-original"
    var beforeFailure: (() -> Void)?
    var beforeResponse: (() async -> Void)?
    var responses: [String] = []
    var dismissedIDs: [String] = []
    let expiresAt: Date?
    init(expired: Bool) { self.expiresAt = expired ? Date().addingTimeInterval(-60) : nil }
    func loadDashboard() async throws -> DashboardSnapshot {
        if loadFails { throw Failure.rejected }
        let request = DashboardClarificationRequest(eventID: "clarify-event", requestID: "clarify-request", sessionID: sessionID, question: "Which release channel?", choices: ["TestFlight", "App Store"], allowsCustomResponse: true, isMultiSelect: true, expiresAt: expiresAt)
        return DashboardSnapshot(inbox: [], attentionItems: dismissedIDs.contains(request.eventID) ? [] : [DashboardAttentionItem(id: request.eventID, title: "Clarification", detail: request.question, urgency: .important, sessionID: request.sessionID, interaction: .clarification(request), createdAt: .now)], completedItems: [], agents: [])
    }
    func respond(to request: DashboardClarificationRequest, response: String) async throws -> DashboardClarificationReceipt {
        responses.append(response)
        await beforeResponse?()
        if accepts { return DashboardClarificationReceipt(eventID: request.eventID, requestID: request.requestID) }
        beforeFailure?()
        if cancel { throw CancellationError() }
        switch ambiguousKind {
        case "timeout": throw URLError(.timedOut)
        case "invalid": throw BighelpLinkWorkspaceClientError.invalidResponse
        case "failed": throw BighelpLinkWorkspaceClientError.remote(status: .failed, code: "workspace_unavailable", message: "Unavailable")
        case "mismatch": return DashboardClarificationReceipt(eventID: "wrong-event", requestID: request.requestID)
        default: throw BighelpLinkWorkspaceClientError.remote(status: .conflict, code: "workspace_conflict", message: "The workspace changed. Refresh and try again.")
        }
    }
    func dismissDashboardEvent(id: String) async throws {
        if dismissFails { throw Failure.rejected }
        dismissedIDs.append(id)
    }
}

@MainActor
private final class FallbackConversationClient: QueuedConversationClient, MidSessionConversationClient {
    var messages: [String] = []
    var sessionIDs: [String] = []
    var fails = false
    var attempts = 0
    var beforeAcceptance: (() async -> Void)?
    func submit(message: String, attachments: [ChatAttachment], conversationID: String) async throws {
        attempts += 1
        if fails { throw Failure.rejected }
        await beforeAcceptance?()
        messages.append(message)
        sessionIDs.append(conversationID)
    }
    func sendMidSession(message: String, attachments: [ChatAttachment], conversationID: String, behavior: MidSessionChatBehavior, onDraft: @escaping (TimelineItem) -> Void) async throws -> MidSessionSubmissionOutcome {
        try await submit(message: message, attachments: attachments, conversationID: conversationID)
        return .accepted
    }
    func send(message: String, conversationID: String) async throws -> ConversationResponse { throw Failure.rejected }
    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse { throw Failure.rejected }
}

private enum Failure: Error { case rejected }
