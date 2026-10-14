import Foundation
import Testing
@testable import Bighelp

/// Failed turns: Hermes' `error_surface` read tolerantly, the plain sentence
/// and fixes for each kind, and the chat staying usable after a failure.
@MainActor
struct ChatTurnFailureTests {
    /// Hermes v0.22 refuses a turn before it starts when it can't build the
    /// agent (no provider): no `message.start`, only `error`, a failed
    /// `message.complete` and `session.info running: false`. The send must end.
    @Test func aTurnRefusedBeforeItStartsEndsTheSendAndKeepsTheChatUsable() async throws {
        let harness = try FailureHarness()
        defer { harness.close() }
        harness.model.draft = "Hello there"
        let send = Task { await harness.model.send() }
        try await harness.waitForSubmit()
        harness.emit("error", ["message": .string("Hermes could not start the assistant for this session.")])
        harness.emit("message.complete", FailureHarness.failedComplete(surface: [
            "layer": .string("runtime"), "code": .string("agent_init_failed"), "retryable": .boolean(true),
        ]))
        harness.emit("session.info", ["running": .boolean(false)])
        try await harness.settle(send)

        #expect(!harness.model.isSending)
        #expect(!harness.client.needsRecovery)
        #expect(harness.client.journal.unresolved.isEmpty)
        #expect(harness.client.isReadyForSubmission)
        #expect(harness.model.failedTurn?.failure.code == "agent_init_failed")
        #expect(harness.model.failedTurn?.message == "Hello there")
    }

    /// The refused turn's text is a reply of its own: it never overwrites the
    /// previous turn's answer.
    @Test func aRefusedTurnDoesNotReplaceTheEarlierReply() async throws {
        let harness = try FailureHarness()
        defer { harness.close() }
        harness.model.draft = "First"
        var send = Task { await harness.model.send() }
        try await harness.waitForSubmit()
        harness.emit("message.start", [:])
        harness.emit("message.complete", ["text": .string("First answer"), "status": .string("complete")])
        harness.emit("session.info", ["running": .boolean(false)])
        try await harness.settle(send)

        harness.model.draft = "Second"
        send = Task { await harness.model.send() }
        try await harness.waitForSubmit(count: 2)
        harness.emit("message.complete", FailureHarness.failedComplete(surface: [
            "layer": .string("runtime"), "code": .string("agent_init_failed"),
        ]))
        harness.emit("session.info", ["running": .boolean(false)])
        try await harness.settle(send)

        let replies = harness.model.items.filter { $0.role == .assistant }.map(\.content)
        #expect(replies == [.message("First answer"), .message("The request failed. Your message was not answered.")])
        #expect(!harness.model.isSending)
    }

    /// A rate limit mid-turn: the send ends, the card names the reset, and Try
    /// again sends the same message once more without a second bubble.
    @Test func tryAgainSendsTheFailedMessageAgainWithoutASecondBubble() async throws {
        let harness = try FailureHarness()
        defer { harness.close() }
        try await harness.failATurn(code: "rate_limit")
        #expect(harness.model.failedTurn?.message == "Hello there")
        #expect(harness.client.isReadyForSubmission)

        let retry = Task { _ = await harness.model.retryFailedTurn() }
        try await harness.waitForSubmit(count: 2)
        #expect(harness.rpc.requests.last(where: { $0.method == "prompt.submit" })?.params["text"] == .string("Hello there"))
        #expect(harness.model.failedTurn == nil)
        harness.emit("message.start", [:])
        harness.emit("message.complete", ["text": .string("Here you go"), "status": .string("complete")])
        harness.emit("session.info", ["running": .boolean(false)])
        try await harness.settle(retry)
        #expect(harness.model.items.filter { $0.role == .human }.count == 1)
        #expect(harness.model.items.last?.content == .message("Here you go"))
        #expect(harness.model.failedTurn == nil)
    }

    // MARK: Reading Hermes' payload

    @Test func theErrorSurfaceAndBillingBlockAreRead() throws {
        let failure = try #require(ChatTurnFailure(completePayload: FailureHarness.failedComplete(
            surface: ["layer": .string("billing"), "code": .string("billing"), "retryable": .boolean(false),
                      "provider": .string("demo"), "provider_label": .string("Demo Cloud"),
                      "resets_at": .number(1_791_990_000), "auth_kind": .string("api_key"),
                      "a_field_from_the_future": .object([:])],
            extra: ["billing": .object(["provider_label": .string("Other"),
                                        "billing_url": .string("https://billing.example.com/top-up")])])))
        #expect(failure.layer == "billing")
        #expect(failure.code == "billing")
        #expect(!failure.retryable)
        #expect(failure.providerLabel == "Demo Cloud")
        #expect(failure.resetsAt == Date(timeIntervalSince1970: 1_791_990_000))
        #expect(failure.billingURL?.absoluteString == "https://billing.example.com/top-up")
    }

    @Test func aBrokenOrMissingErrorSurfaceIsReadAsAbsent() throws {
        #expect(ChatTurnFailure(completePayload: ["text": .string("Done"), "status": .string("complete")]) == nil)
        #expect(ChatTurnFailure(completePayload: ["text": .string("Done")]) == nil)
        let bare = try #require(ChatTurnFailure(completePayload: FailureHarness.failedComplete(surface: nil)))
        #expect(bare == ChatTurnFailure())
        let broken = try #require(ChatTurnFailure(completePayload: FailureHarness.failedComplete(
            surface: ["layer": .integer(4), "code": .string("has space"), "retryable": .string("no"),
                      "provider_label": .string("\u{0007}"), "resets_at": .string("tomorrow")],
            extra: ["billing": .object(["billing_url": .string("http://billing.example.com")]),
                    "failure_reason": .string("rate_limit")])))
        #expect(broken.layer == nil)
        // An unreadable code falls back to the turn's own failure reason.
        #expect(broken.code == "rate_limit")
        #expect(broken.retryable)
        #expect(broken.providerLabel == nil)
        #expect(broken.resetsAt == nil)
        #expect(broken.billingURL == nil, "Only an https page opens.")
    }

    // MARK: What the card says and offers

    private static let utc = TimeZone(identifier: "UTC")!
    private static let english = Locale(identifier: "en_US")
    /// 1:25 PM UTC on a made-up day.
    private static let now = Date(timeIntervalSince1970: 1_791_984_300)
    private static let threePM = Date(timeIntervalSince1970: 1_791_990_000)

    private static func presentation(_ failure: ChatTurnFailure, canResend: Bool = true)
        -> (sentence: String, fixes: [ChatTurnFailureFix])? {
        ChatTurnFailurePresentation.resolve(failure, canResend: canResend, now: now, locale: english, timeZone: utc)
            .map { ($0.sentence.replacingOccurrences(of: "\u{202F}", with: " "), $0.fixes) }
    }

    @Test func aLimitSaysWhenItResetsAndOffersToTryThenOrSwitch() throws {
        let timed = try #require(Self.presentation(.init(layer: "provider", code: "rate_limit", resetsAt: Self.threePM)))
        #expect(timed.sentence == "You've reached your limit. It resets at 3:00 PM.")
        #expect(timed.fixes == [.tryAgainAt(Self.threePM), .useAnotherModel])

        let untimed = try #require(Self.presentation(.init(layer: "provider", code: "rate_limit")))
        #expect(untimed.sentence == "You've reached your limit for now.")
        #expect(untimed.fixes == [.tryAgain, .useAnotherModel])

        // A reset days away isn't worth waiting for in an open chat.
        let far = Self.now.addingTimeInterval(3 * 24 * 3600)
        let distant = try #require(Self.presentation(.init(code: "rate_limit", resetsAt: far)))
        #expect(distant.fixes == [.useAnotherModel])
    }

    @Test(arguments: [
        ("overloaded", "provider", "Demo Cloud is busy right now.", [ChatTurnFailureFix.tryAgain]),
        ("timeout", "provider", "Demo Cloud didn't answer in time.", [.tryAgain]),
        ("stream_drop", "streaming", "The connection dropped before the reply finished.", [.tryAgain]),
        ("auth", "auth", "Sign-in to Demo Cloud stopped working.", [.fixSignIn]),
        ("auth_permanent", "auth", "Sign-in to Demo Cloud stopped working.", [.fixSignIn]),
        ("model_not_found", "provider", "This model isn't available.", [.pickAnotherModel]),
        ("context_overflow", "provider", "This chat is too long for the model.", [.startNewChat]),
        ("agent_init_failed", "runtime", "Hermes couldn't start the agent. Check that an AI provider is set up.",
         [.tryAgain, .checkProviders]),
    ])
    func eachKindHasItsSentenceAndFix(code: String, layer: String, sentence: String, fixes: [ChatTurnFailureFix]) throws {
        let shown = try #require(Self.presentation(.init(layer: layer, code: code, providerLabel: "Demo Cloud")))
        #expect(shown.sentence == sentence)
        #expect(shown.fixes == fixes)
    }

    @Test func billingOffersAnotherModelAndOnlyAnHttpsTopUp() throws {
        let url = try #require(URL(string: "https://billing.example.com/top-up"))
        let withPage = try #require(Self.presentation(.init(layer: "billing", code: "billing", providerLabel: "Demo Cloud",
                                                            billingURL: url)))
        #expect(withPage.sentence == "Demo Cloud has no credit left.")
        #expect(withPage.fixes == [.useAnotherModel, .addCredit(url)])
        let withoutPage = try #require(Self.presentation(.init(layer: "billing", code: "billing")))
        #expect(withoutPage.sentence == "This AI provider has no credit left.")
        #expect(withoutPage.fixes == [.useAnotherModel])
    }

    @Test func aFailureWithoutWordsKeepsTheChatAsItWas() {
        #expect(Self.presentation(.init(layer: "provider", code: "something_new")) == nil)
        #expect(Self.presentation(.init(layer: "gateway", code: "loop_error")) == nil)
        #expect(Self.presentation(.init()) == nil)
        // A layer alone still says enough.
        #expect(Self.presentation(.init(layer: "auth", code: "something_new"))?.fixes == [.fixSignIn])
    }

    @Test func aTurnThisChatDidNotSendOffersNoResend() throws {
        let shown = try #require(Self.presentation(.init(code: "rate_limit", resetsAt: Self.threePM), canResend: false))
        #expect(shown.fixes == [.useAnotherModel])
    }

    // MARK: Try again at a time

    @Test func aTimedRetrySendsAgainAtTheResetWhileTheChatIsOpen() async throws {
        let harness = try FailureHarness()
        defer { harness.close() }
        try await harness.failATurn(code: "rate_limit")
        harness.model.scheduleRetry(at: Date().addingTimeInterval(60))
        #expect(harness.model.scheduledRetry != nil)
        try await harness.waitForReminder()
        #expect(harness.reminders.scheduled.count == 1)

        try await harness.passScheduledTime()
        try await harness.waitForSubmit(count: 2)
        #expect(harness.model.scheduledRetry == nil)
        #expect(harness.reminders.cancelled.count == 1, "The reminder isn't needed once it sent.")
    }

    @Test func sendingSomethingElseCancelsTheTimedRetry() async throws {
        let harness = try FailureHarness()
        defer { harness.close() }
        try await harness.failATurn(code: "rate_limit")
        harness.model.scheduleRetry(at: Date().addingTimeInterval(60))
        try await harness.waitForReminder()

        harness.model.draft = "Never mind, something else"
        let send = Task { await harness.model.send() }
        try await harness.waitForSubmit(count: 2)
        #expect(harness.model.scheduledRetry == nil)
        #expect(harness.model.failedTurn == nil)
        #expect(harness.reminders.cancelled.count == 1)
        try await harness.passScheduledTime()
        #expect(harness.submits == 2, "The cancelled retry never sends.")
        harness.emit("message.start", [:])
        harness.emit("session.info", ["running": .boolean(false)])
        try await harness.settle(send)
        #expect(harness.submits == 2)
    }

    @Test func aChatThatChangedOwnerNeverSendsTheTimedRetry() async throws {
        let harness = try FailureHarness()
        defer { harness.close() }
        try await harness.failATurn(code: "rate_limit")
        harness.model.scheduleRetry(at: Date().addingTimeInterval(60))
        harness.model.invalidateReferenceOwnership()
        try await harness.passScheduledTime()
        #expect(harness.submits == 1)
    }

    @Test func leavingTheChatCancelsTheTimedRetry() async throws {
        let harness = try FailureHarness()
        defer { harness.close() }
        try await harness.failATurn(code: "rate_limit")
        harness.model.scheduleRetry(at: Date().addingTimeInterval(60))
        harness.model.cancelScheduledRetry()
        try await harness.passScheduledTime()
        #expect(harness.submits == 1)
        #expect(harness.model.failedTurn != nil, "Try again stays for later.")
    }

    @Test func atTheResetInTheBackgroundOnlyTheReminderSpeaks() async throws {
        let harness = try FailureHarness()
        defer { harness.close() }
        try await harness.failATurn(code: "rate_limit")
        harness.model.scheduleRetry(at: Date().addingTimeInterval(60))
        try await harness.waitForReminder()
        harness.appIsActive = false
        try await harness.passScheduledTime()
        #expect(harness.submits == 1, "Nothing is sent while bighelp is away.")
        #expect(harness.reminders.cancelled.isEmpty, "The reminder tells the person instead.")

        // Back after the reset: Try again is theirs to tap.
        harness.appIsActive = true
        harness.now = Date().addingTimeInterval(120)
        harness.model.resumeScheduledRetry()
        #expect(harness.model.scheduledRetry == nil)
        #expect(harness.model.failedTurn != nil)
        #expect(harness.submits == 1)
    }

    @Test func anotherTurnStartingClearsTheFailureAndItsTimedRetry() async throws {
        let harness = try FailureHarness()
        defer { harness.close() }
        try await harness.failATurn(code: "rate_limit")
        harness.model.scheduleRetry(at: Date().addingTimeInterval(60))
        // Voice or another device starts a turn in this chat.
        harness.emit("message.start", [:])
        #expect(harness.model.failedTurn == nil)
        #expect(harness.model.scheduledRetry == nil)
        try await harness.passScheduledTime()
        #expect(harness.submits == 1)
    }
}

/// A native chat over a scripted Hermes: `prompt.submit` answers `streaming`
/// like a real host, and the test sends the turn's events itself.
@MainActor
final class FailureHarness {
    let root: URL
    let rpc = FailureTestRPC()
    let client: DirectHermesConversationClient
    let model: ChatModel
    let reminders = ReminderLog()
    var appIsActive = true
    var now = Date()
    /// The timed retry's wait, released by `passScheduledTime`.
    private var waits: [CheckedContinuation<Void, any Error>] = []
    private var sequence = 0

    var submits: Int { rpc.requests.filter { $0.method == "prompt.submit" }.count }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let reminders = reminders
        model.retryScheduling = ChatRetryScheduling(
            now: { [unowned self] in self.now },
            wait: { [unowned self] _ in
                try await withCheckedThrowingContinuation { self.waits.append($0) }
                try Task.checkCancellation()
            },
            appIsActive: { [unowned self] in self.appIsActive },
            remind: { reminder, _ in reminders.scheduled.append(reminder) },
            cancelReminder: { reminders.cancelled.append($0) })
    }

    /// Sends "Hello there" and fails the turn after it starts, with `code`.
    func failATurn(code: String) async throws {
        model.draft = "Hello there"
        let send = Task { await model.send() }
        try await waitForSubmit()
        emit("message.start", [:])
        emit("message.complete", Self.failedComplete(surface: [
            "layer": .string("provider"), "code": .string(code), "retryable": .boolean(true),
            "provider_label": .string("Demo Cloud"),
        ]))
        emit("session.info", ["running": .boolean(false)])
        try await settle(send)
        #expect(!model.isSending)
        #expect(model.failedTurn?.failure.code == code)
    }

    func waitForReminder() async throws {
        for _ in 0..<500 where reminders.scheduled.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    }

    /// Lets every pending timed-retry wait finish, then lets the chat act.
    func passScheduledTime() async throws {
        for _ in 0..<50 { await Task.yield() }
        let pending = waits
        waits = []
        for wait in pending { wait.resume() }
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
    }

    func waitForSubmit(count: Int = 1) async throws {
        for _ in 0..<2_000 where rpc.requests.filter({ $0.method == "prompt.submit" }).count < count {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.count == count)
        // Let the admission receipt land before the turn's events.
        for _ in 0..<20 { await Task.yield() }
    }

    /// Waits a moment for a send to end; one that never would is cancelled so
    /// the test reports it instead of hanging.
    func settle(_ send: Task<Void, Never>) async throws {
        for _ in 0..<500 where model.isSending { try await Task.sleep(for: .milliseconds(2)) }
        if model.isSending { send.cancel() }
        await send.value
    }

    func emit(_ type: String, _ payload: [String: BighelpJSONValue]) {
        sequence += 1
        client.receive(.init(type: type, sessionID: "runtime", payload: payload, sequence: sequence))
    }

    static func failedComplete(surface: [String: BighelpJSONValue]?,
                               extra: [String: BighelpJSONValue] = [:]) -> [String: BighelpJSONValue] {
        var payload: [String: BighelpJSONValue] = [
            "text": .string("The request failed. Your message was not answered."),
            "status": .string("error"), "error": .string("Provider said no"), "recoverable": .boolean(true),
        ]
        if let surface { payload["error_surface"] = .object(surface) }
        payload.merge(extra) { $1 }
        return payload
    }

    func close() {
        client.suspend()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class ReminderLog {
    var scheduled: [ChatRetryReminder] = []
    var cancelled: [UUID] = []
}

@MainActor
final class FailureTestRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var requests: [(method: String, params: [String: BighelpJSONValue])] = []
    var userRow = 40

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        requests.append((method, params))
        switch method {
        case "prompt.submit":
            userRow += 1
            return .object(["status": .string("streaming"), "user_row_id": .integer(userRow)])
        case "session.control.read":
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("fixture"), "updated_at": .integer(0)])])
        case "subagent.list":
            return .object(["subagents": .array([])])
        default:
            throw DirectHermesError.invalidResponse
        }
    }

    func disconnect() async {}
}
