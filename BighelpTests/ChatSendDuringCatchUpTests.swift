import Foundation
import Testing
@testable import Bighelp

/// While agents work together, an open chat rereads what Hermes saved every few seconds, and
/// each reread catches the chat's connection up. Send stays on through that: a message sent
/// meanwhile waits for the catch-up, then goes out.
@MainActor
struct ChatSendDuringCatchUpTests {
    @Test func sendStaysOnWhileAWorkingChatCatchesUp() async throws {
        let fixture = try CatchUpFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.model.draft = "Hello there"
        #expect(fixture.model.canSend)

        fixture.rpc.holdsActivation = true
        let catchUp = Task { try await fixture.client.recover(epoch: "epoch") }
        try await fixture.waitUntil { fixture.rpc.isHoldingActivation }
        #expect(fixture.client.isHydrating)
        #expect(fixture.model.canSend, "Catching up must not grey out Send")
        #expect(fixture.model.sendUnavailableReason == nil)

        let send = Task { await fixture.model.send() }
        for _ in 0..<50 { await Task.yield() }
        #expect(fixture.rpc.submits.isEmpty, "The message waits for the catch-up")
        #expect(fixture.model.draft == "Hello there")
        #expect(!fixture.model.canSend, "A second tap can't send it twice")
        fixture.rpc.releaseActivation()
        try await catchUp.value
        try await fixture.waitUntil { !fixture.rpc.submits.isEmpty }
        #expect(fixture.rpc.submits == ["Hello there"])
        #expect(fixture.model.draft.isEmpty)
        send.cancel()
        await send.value
    }

    /// A chat that hasn't loaded yet keeps Send off until it has.
    @Test func sendStaysOffWhileAChatFirstLoads() async throws {
        let fixture = try CatchUpFixture()
        defer { fixture.close() }
        fixture.model.draft = "Hello there"
        fixture.rpc.holdsActivation = true
        let load = Task { try await fixture.client.recover(epoch: "epoch") }
        try await fixture.waitUntil { fixture.rpc.isHoldingActivation }
        #expect(!fixture.model.canSend)
        fixture.rpc.releaseActivation()
        try await load.value
        #expect(fixture.model.canSend)
    }
}

@MainActor
private final class CatchUpFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let rpc = CatchUpRPC()
    let client: DirectHermesConversationClient
    let model: ChatModel

    init() throws {
        client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    func close() {
        rpc.releaseActivation()
        client.suspend()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class CatchUpRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var holdsActivation = false
    private(set) var submits: [String] = []
    private var heldActivation: CheckedContinuation<Void, Never>?
    var isHoldingActivation: Bool { heldActivation != nil }

    func releaseActivation() {
        holdsActivation = false
        heldActivation?.resume()
        heldActivation = nil
    }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "session.events.since":
            return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false),
                            "events": .array([]), "count": .integer(0)])
        case "session.activate":
            if holdsActivation { await withCheckedContinuation { heldActivation = $0 } }
            return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"),
                            "running": .boolean(false), "messages": .array([])])
        case "prompt.submit":
            if case .string(let text) = params["text"] { submits.append(text) }
            return .object(["status": .string("streaming"), "user_row_id": .integer(41)])
        case "subagent.list":
            return .object(["subagents": .array([])])
        case "session.control.read":
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("fixture"), "updated_at": .integer(0)])])
        default:
            throw DirectHermesError.invalidResponse
        }
    }

    func disconnect() async {}
}
