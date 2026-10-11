import Foundation
import Testing
@testable import Bighelp

/// This chat › Compact and Hermes' own compaction show the rail above the message box:
/// compacting while Hermes says so, then Done with what it saved.
@MainActor
struct ChatCompactionTests {
    @Test func hermesStatusTextGivesTheMessagesAndTokens() {
        let counts = ChatCompaction.counts(in: "⠋ compressing 48 messages (~41,200 tok)…")
        #expect(counts.messages == 48)
        #expect(counts.tokens == 41_200)
        let plain = ChatCompaction.counts(in: "Compacting context…")
        #expect(plain.messages == nil && plain.tokens == nil)
    }

    /// Hermes compacts on its own when the context fills during a turn ("compacting"),
    /// and its next status ends it.
    @Test func compactionHermesStartsShowsUntilItsNextStatus() async throws {
        let fixture = try CompactionFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.status("compacting", "Compacting context…")
        #expect(fixture.model.compaction?.phase == .compacting)
        fixture.status("thinking", "Thinking")
        #expect(fixture.model.compaction?.phase == .done)
    }

    @Test func compactAsksHermesAndShowsWhatItSaved() async throws {
        let fixture = try CompactionFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.rpc.compressReceipt = ["status": .string("compressed"), "removed": .integer(40),
                                       "before_tokens": .integer(41_200), "after_tokens": .integer(6_100)]
        try await fixture.client.compact(conversationID: fixture.client.conversationID)
        #expect(fixture.rpc.calls.last?.method == "session.compress")
        #expect(fixture.rpc.calls.last?.params["session_id"] == .string("runtime"))
        #expect(fixture.model.compaction?.phase == .done)
        #expect(fixture.model.compaction?.tokensBefore == 41_200)
        #expect(fixture.model.compaction?.tokensAfter == 6_100)
    }

    @Test func compactWithNothingToFoldShowsNothing() async throws {
        let fixture = try CompactionFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.rpc.compressReceipt = ["status": .string("aborted")]
        try await fixture.client.compact(conversationID: fixture.client.conversationID)
        #expect(fixture.model.compaction == nil)
    }
}

@MainActor
private final class CompactionFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let rpc = CompactionRPC()
    let client: DirectHermesConversationClient
    let model: ChatModel

    init() throws {
        client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        model = ChatModel(conversationID: client.conversationID, client: client)
        client.model = model
    }

    func status(_ kind: String, _ text: String) {
        client.receive(.init(type: "status.update", sessionID: "runtime",
                             payload: ["kind": .string(kind), "text": .string(text)], sequence: nil))
    }

    func close() {
        client.suspend()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class CompactionRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var compressReceipt: [String: BighelpJSONValue] = [:]
    private(set) var calls: [(method: String, params: [String: BighelpJSONValue])] = []

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "session.events.since":
            return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false),
                            "events": .array([]), "count": .integer(0)])
        case "session.activate":
            return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"),
                            "running": .boolean(false), "messages": .array([])])
        case "subagent.list":
            return .object(["subagents": .array([])])
        case "session.compress":
            calls.append((method, params))
            return .object(compressReceipt)
        default:
            throw DirectHermesError.invalidResponse
        }
    }

    func disconnect() async {}
}
