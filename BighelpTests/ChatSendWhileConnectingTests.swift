import Foundation
import Testing
@testable import Bighelp

/// Send doesn't wait for the connection. A message sent while the chat comes back from the
/// background, waits for its computer, or catches up with what Hermes saved waits in the chat
/// with "Sending…" under it, and goes out once the chat can take it.
@MainActor
struct ChatSendWhileConnectingTests {
    @Test func aMessageSentWhileTheChatCatchesUpWaitsInTheChat() async throws {
        let fixture = try ConnectingFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.rpc.holdsActivation = true
        let catchUp = Task { try await fixture.client.recover(epoch: "epoch") }
        try await fixture.waitUntil { fixture.rpc.isHoldingActivation }

        fixture.model.draft = "Hello there"
        #expect(fixture.model.canSend, "Catching up must not grey out Send")
        await fixture.model.send()
        #expect(fixture.rpc.submits.isEmpty, "Nothing goes out while the chat catches up")
        #expect(fixture.model.draft.isEmpty, "The box is free for the next message")
        let staged = try #require(fixture.model.stagedSends.first)
        #expect(staged.item.content == .message("Hello there"))
        #expect(!fixture.model.items.contains { $0.id == staged.id },
                "It waits outside the transcript, which the catch-up rereads")

        fixture.rpc.releaseActivation()
        try await catchUp.value
        try await fixture.waitUntil { !fixture.rpc.submits.isEmpty }
        #expect(fixture.rpc.submits == ["Hello there"])
        #expect(fixture.model.stagedSends.isEmpty)
        #expect(fixture.model.items.last?.id == staged.id, "It goes out as the row it waited in")
    }

    @Test func aMessageSentBeforeTheComputerConnectsGoesOutOnceItDoes() async throws {
        let fixture = try ConnectingFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        let model = ChatModel(conversationID: fixture.client.conversationID, client: NativeWorkspaceUnavailableClient(),
                              initialItems: [])
        model.draft = "Hello there"
        #expect(model.canSend, "A computer still connecting must not grey out Send")
        await model.send()
        #expect(model.stagedSends.count == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.rpc.submits.isEmpty)

        model.client = fixture.client
        fixture.client.model = model
        try await fixture.waitUntil { !fixture.rpc.submits.isEmpty }
        #expect(fixture.rpc.submits == ["Hello there"])
        #expect(model.stagedSends.isEmpty)
    }

    @Test func aMessageSentAsTheAppComesBackGoesOutOnceTheChatReconnects() async throws {
        let fixture = try ConnectingFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.client.suspend()
        fixture.model.draft = "Hello there"
        #expect(fixture.model.canSend, "Coming back to the app must not grey out Send")
        await fixture.model.send()
        #expect(fixture.model.stagedSends.count == 1)

        fixture.client.rebind(fixture.rpc)
        try await fixture.client.recover(epoch: "epoch")
        try await fixture.waitUntil { !fixture.rpc.submits.isEmpty }
        #expect(fixture.rpc.submits == ["Hello there"])
    }

    /// Texting two lines in a row before the chat connects: the first starts a turn and the
    /// second steers it once Hermes says the turn is live, the way two quick Sends would.
    @Test func twoQuickMessagesGoOutInOrder() async throws {
        let fixture = try ConnectingFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        fixture.client.suspend()
        fixture.model.draft = "First"
        await fixture.model.send()
        fixture.model.draft = "Second"
        #expect(fixture.model.canSend)
        await fixture.model.send()
        #expect(fixture.model.stagedSends.map(\.outgoing.message) == ["First", "Second"])

        fixture.client.rebind(fixture.rpc)
        try await fixture.client.recover(epoch: "epoch")
        try await fixture.waitUntil { !fixture.rpc.submits.isEmpty }
        #expect(fixture.rpc.submits == ["First"])
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.rpc.steers.isEmpty, "The second waits until the first turn is live")
        #expect(fixture.model.stagedSends.map(\.outgoing.message) == ["Second"])

        fixture.emit("message.start", [:])
        try await fixture.waitUntil { !fixture.rpc.steers.isEmpty }
        #expect(fixture.rpc.steers == ["Second"])
        #expect(fixture.model.stagedSends.isEmpty)
        #expect(fixture.model.items.filter { $0.role == .human }.map(\.content) == [.message("First"), .message("Second")])
    }

    @Test func sendGoesOffOnlyOnceTheConnectionIsOverdue() {
        let model = ChatModel(conversationID: "connecting", client: NativeWorkspaceUnavailableClient(), initialItems: [])
        model.draft = "Hello there"
        #expect(model.canSend)
        model.connectionIsOverdue = true
        #expect(!model.canSend)
        #expect(model.sendUnavailableReason == "not connected to your computer")
    }

    @Test func messagesTheChatNeverTakesGoBackInTheBox() async throws {
        let model = ChatModel(conversationID: "connecting", client: NativeWorkspaceUnavailableClient(), initialItems: [])
        model.draft = "First"
        await model.send()
        model.draft = "Second"
        await model.send()
        model.draft = "Still typing"
        model.connectionIsOverdue = true
        for _ in 0..<200 where !model.stagedSends.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.stagedSends.isEmpty)
        #expect(model.draft == "First\n\nSecond\n\nStill typing")
        #expect(model.failureMessage == "Your computer didn't answer, so your messages are back in the message box.")
    }

    /// A reload while messages wait resets the chat's counts. The waiting rows keep IDs of their
    /// own, and the one that goes out sorts after the reloaded history, not into it.
    @Test func aReloadWhileMessagesWaitKeepsThemApartAndLast() async throws {
        let fixture = try ConnectingFixture()
        defer { fixture.close() }
        try await fixture.client.recover(epoch: "epoch")
        let model = ChatModel(conversationID: fixture.client.conversationID, client: NativeWorkspaceUnavailableClient(),
                              initialItems: [])
        model.draft = "First"
        await model.send()
        var saved = SessionRecord(id: model.conversationID, kind: .direct, agentIDs: ["default"], title: "Chat",
                                  hasAcceptedMessage: true)
        model.beginHistoryHydration(from: saved)
        saved.items = [TimelineItem(id: "hermes:saved:answer", role: .assistant,
                                    sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                                    content: .message("An earlier answer"),
                                    metadata: .init(source: "Hermes", delivery: "Saved", sourceOrder: 20))]
        model.reconcileHydratedSession(saved)
        model.finishHistoryHydration()
        model.draft = "Second"
        await model.send()
        #expect(Set(model.stagedSends.map(\.id)).count == 2, "Two waiting rows may never share an ID")

        model.client = fixture.client
        fixture.client.model = model
        try await fixture.waitUntil { !fixture.rpc.submits.isEmpty }
        #expect(model.transcriptEntries.last?.id == ChatTranscriptEntry.message(
            model.items.first { $0.content == .message("First") }!).id)
    }

    @Test func aWaitingNewChatShowsItsMessageNotTheWelcome() async {
        let model = ChatModel(conversationID: "connecting", client: NativeWorkspaceUnavailableClient(), initialItems: [])
        #expect(model.shouldShowNewConversationWelcome)
        model.draft = "Hello there"
        await model.send()
        #expect(!model.shouldShowNewConversationWelcome)
    }

    /// Files go into a running turn only through the queue, whatever Send's choice was.
    @Test func aWaitingFileGoesIntoTheQueue() throws {
        let model = ChatModel(conversationID: "connecting", client: NativeWorkspaceUnavailableClient(), initialItems: [])
        let file = try ChatAttachment(id: "attachment_waiting_file", fileName: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
        model.draft = "Look at this"
        model.draftAttachments = [file]
        model.orderedDraftAttachments = [.attachment(file)]
        let withFile = ChatStagedSend(item: model.humanItem(content: "Look at this", attachments: [file]),
                                      outgoing: ChatOutgoingMessage(composerOf: model), midSessionBehavior: .steer)
        #expect(model.stagedMidSessionBehavior(withFile) == .queued)
        model.draftAttachments = []
        model.orderedDraftAttachments = []
        let plain = ChatStagedSend(item: model.humanItem(content: "Look at this"),
                                   outgoing: ChatOutgoingMessage(composerOf: model), midSessionBehavior: .interruptAndSend)
        #expect(model.stagedMidSessionBehavior(plain) == .interruptAndSend)
    }

    /// A command is read by the connection (`/…`), so it waits in the box until the chat connects.
    @Test func aCommandWaitsInTheBox() {
        let model = ChatModel(conversationID: "connecting", client: NativeWorkspaceUnavailableClient(), initialItems: [])
        model.draft = "/compress"
        #expect(!model.canSend)
    }
}

@MainActor
private final class ConnectingFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let rpc = ConnectingRPC()
    let client: DirectHermesConversationClient
    let model: ChatModel
    private var sequence = 0

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

    func emit(_ type: String, _ payload: [String: BighelpJSONValue]) {
        sequence += 1
        client.receive(.init(type: type, sessionID: "runtime", payload: payload, sequence: sequence))
    }

    func close() {
        rpc.releaseActivation()
        model.stagedSendDrain?.task.cancel()
        client.suspend()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ConnectingRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var holdsActivation = false
    private(set) var submits: [String] = []
    private(set) var steers: [String] = []
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
            return .object(["status": .string("streaming"), "user_row_id": .integer(41 + submits.count)])
        case "session.steer":
            // Stock Hermes confirms a steer with `queued`.
            if case .string(let text) = params["text"] { steers.append(text) }
            return .object(["status": .string("queued")])
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
