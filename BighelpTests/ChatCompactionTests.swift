import Foundation
import Testing
@testable import Bighelp

/// Advanced › Compact and Hermes' own compaction show the rail above the message box:
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

    /// Hermes announces an automatic attempt before it knows there's anything to fold. On a
    /// host with a fixed `compression.threshold_tokens` (or a context engine such as LCM) that
    /// happens on chats with most of their window left; with nothing folded, the rail never shows.
    @Test func anAttemptWithNothingToFoldNeverShows() async throws {
        let fixture = try CompactionFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.status("compacting", "📦 Preflight compression: ~114,586 tokens >= 96,000 threshold. This may take a moment.")
        #expect(fixture.model.compaction?.phase == .announced)
        #expect(fixture.model.compaction?.isShown == false)
        fixture.status("compacting", "🗜️ Compacting context — summarizing earlier conversation so I can continue...")
        fixture.status("thinking", "Thinking")
        #expect(fixture.model.compaction == nil, "No commit from Hermes: no Done")
    }

    /// A real compaction is still running after the wait, so it shows, and Hermes' commit
    /// ("compacted") turns it into Done.
    @Test func aRealCompactionShowsThenHermesCommitSaysDone() async throws {
        let fixture = try CompactionFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.status("compacting", "🗜️ Compacting context — summarizing earlier conversation so I can continue...")
        try await Task.sleep(for: ChatCompaction.showAfter + .milliseconds(300))
        #expect(fixture.model.compaction?.phase == .compacting)
        #expect(fixture.model.compaction?.isShown == true)
        fixture.status("compacting", "🗜️ Compacting context — still summarizing earlier conversation so I can continue...")
        #expect(fixture.model.compaction?.phase == .compacting)
        fixture.status("compacted", "✓ Context compaction complete — continuing turn...")
        #expect(fixture.model.compaction?.phase == .done)
    }

    /// Hermes tags notices "compacting" too: they say something about compaction, not that it runs.
    @Test func noticesAboutCompactionStartNothing() async throws {
        let fixture = try CompactionFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        for notice in [
            "⚠️  Session compressed 3 times — accuracy may degrade. Consider /new to start fresh.",
            "⚠ Compression model sonnet (helper) context is 120,000 tokens, but the main model's compression "
                + "threshold was 825,000 tokens. Auto-lowered this session's threshold to 120,000 tokens so compression can run.",
            "⚠ Configured auxiliary compression provider 'helper' is unavailable, so older messages in long chats "
                + "will be cut without a summary.",
            "❌ Context compression failed: the summary model refused",
            "Context is over the threshold but compression is currently blocked",
        ] {
            fixture.status("compacting", notice)
            #expect(fixture.model.compaction == nil, "\(notice)")
        }
        #expect(ChatCompaction.isProgress("📦 Pre-API compression: ~90,000 tokens near the context/output limit. Compacting before the next model call."))
        #expect(ChatCompaction.isProgress("💤 Resumed after 3600s idle — compacting ~120,000 tokens before continuing."))
        #expect(ChatCompaction.isProgress("🗜️ Context too large (~250,000 tokens) — compressing (1/3)..."))
    }

    /// A commit whose start went unseen (or was a notice) still says Done: Hermes only sends it for real work.
    @Test func aCommitAloneSaysDone() async throws {
        let fixture = try CompactionFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.status("compacted", "✓ Context compaction complete — continuing turn...")
        #expect(fixture.model.compaction?.phase == .done)
    }

    /// Advanced › Compact: Hermes says "ready" just before its receipt, which must not end it.
    @Test func compactWaitsForItsReceipt() async throws {
        let fixture = try CompactionFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.model.beginCompaction()
        fixture.status("compressing", "⠋ compressing 48 messages (~41,200 tok)…")
        fixture.status("ready", "ready")
        #expect(fixture.model.compaction?.phase == .compacting)
        #expect(fixture.model.compaction?.messages == 48)
        fixture.model.finishCompaction(tokensBefore: 41_200, tokensAfter: 6_100)
        #expect(fixture.model.compaction?.phase == .done)
    }

    /// Done never shows the chat's unchanged usage as what's left.
    @Test func doneNeverReportsAnUnchangedReadingAsWhatsLeft() {
        let model = ChatModel(conversationID: "c", client: ConversationFixtureClient(), initialItems: [])
        model.sessionContext = .init(sessionId: "s", model: "m", contextUsed: 103_000, contextMax: 1_000_000,
                                     contextPercent: 10, compressions: 0, isCompacting: false, updatedAt: 0)
        model.announceCompaction(status: "🗜️ Compacting context — summarizing earlier conversation so I can continue...")
        model.confirmCompaction()
        #expect(model.compaction?.phase == .done)
        #expect(model.compaction?.tokensBefore == 103_000)
        #expect(model.compaction?.tokensAfter == nil)
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
