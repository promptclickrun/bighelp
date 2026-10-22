import Foundation
import Testing
@testable import Bighelp

/// Stop in a Hermes room (#517): a stop whose outcome isn't known keeps its
/// cancel ID until Hermes' answer or its room log settles it, and it never
/// keeps the room from taking the next message.
@MainActor
struct BotModeStopTests {
    @Test func stopWhoseAnswerIsLostAfterHermesAppliedItSettlesTheRoom() async throws {
        let room = try stopTestRoom(id: "stop-lost-answer", running: true)
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.stopFailures = [.afterHost]
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        try await store.stopNativeRoom(roomID: room.id, cancelID: "stop-1")

        let stopped = try #require(store.room(id: room.id))
        #expect(client.stopped.map(\.cancelID) == ["stop-1"])
        #expect(stopped.nativePendingCancelID == nil)
        #expect(!stopped.isRunning)
        #expect(stopped.nativePendingEventID == nil)
    }

    @Test func stopThatNeverReachedHermesKeepsItsCancelIDAndTheNextMessageStillGoesOut() async throws {
        let room = try stopTestRoom(id: "stop-never-arrived", running: false)
        let client = NativeBotModeTestClient(capabilities: .fixture())
        replyOnSend(client, roomID: room.id, text: "Here is the next step")
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        client.stopFailures = [.beforeHost, .beforeHost]
        await #expect(throws: NativeBotModeTestError.transport) {
            try await store.stopNativeRoom(roomID: room.id, cancelID: "stop-1")
        }
        #expect(store.room(id: room.id)?.nativePendingCancelID == "stop-1")
        // Pressing Stop again asks for the same stop, never a second one.
        await #expect(throws: NativeBotModeTestError.transport) {
            try await store.stopNativeRoom(roomID: room.id)
        }
        #expect(client.stopped.map(\.cancelID) == ["stop-1", "stop-1"])

        try await store.send(text: "What next?", roomID: room.id)

        let settled = try #require(store.room(id: room.id))
        #expect(client.sentPayloads.map(\.text) == ["What next?"])
        #expect(settled.nativePendingCancelID == nil)
        #expect(settled.visibleEvents.contains { $0.text == "Here is the next step" })
        #expect(client.stopped.count == 2)
    }

    /// Hermes answers a repeated cancel ID with the stop it already made. When
    /// the room log already shows that stop, Stop again doesn't ask at all.
    @Test(arguments: [true, false])
    func stopAgainReusesTheSavedCancelIDAndHermesConfirmationClearsIt(logShowsStop: Bool) async throws {
        let room = try stopTestRoom(id: "stop-again", running: true, cancelID: "stop-old")
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.loggedStopCancelIDs = ["stop-old"]
        if logShowsStop {
            client.logPages = [[stopEvent(roomID: room.id, sequence: 1, cancelID: "stop-old")]]
        }
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        try await store.stopNativeRoom(roomID: room.id)

        let stopped = try #require(store.room(id: room.id))
        #expect(client.stopped.map(\.cancelID) == (logShowsStop ? [] : ["stop-old"]))
        #expect(client.loggedStopCancelIDs == ["stop-old"])
        #expect(stopped.nativePendingCancelID == nil)
        #expect(!stopped.isRunning)
        #expect(stopped.nativePendingEventID == nil)
    }

    @Test func stopWhoseFinalSaveConflictsStillClearsTheSavedIntent() async throws {
        let directory = try stopTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = stopTestRepository(directory)
        let room = try stopTestRoom(id: "stop-save-conflict", running: true)
        try repository.save([room])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.blockGroupsStop = true
        let stopping = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: client)
        try stopping.load()

        let stop = Task { @MainActor in try await stopping.stopNativeRoom(roomID: room.id, cancelID: "stop-1") }
        await client.waitUntilGroupsStopStarts(count: 1)
        // Another store on the same cache saves the room while Hermes stops it.
        let other = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository,
                                     nativeClient: NativeBotModeTestClient(capabilities: .fixture()))
        try other.load()
        try other.persist(room: try #require(other.room(id: room.id)))
        client.releaseBlockedGroupsStop()
        try await stop.value

        let relaunched = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: client)
        try relaunched.load()
        let saved = try #require(relaunched.room(id: room.id))
        #expect(saved.nativePendingCancelID == nil)
        #expect(!saved.isRunning)
        #expect(saved.nativePendingEventID == nil)
    }

    /// The connection changed while Hermes answered, so the answer can't be
    /// used. The room log settles it on the new connection.
    @Test func stopAnswerFromAnOldConnectionIsSettledFromTheRoomLog() async throws {
        let room = try stopTestRoom(id: "stop-old-connection", running: true)
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.blockGroupsStop = true
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        let stop = Task { @MainActor in try await store.stopNativeRoom(roomID: room.id, cancelID: "stop-1") }
        await client.waitUntilGroupsStopStarts(count: 1)
        store.configureNativeClient(client)
        client.releaseBlockedGroupsStop()
        await #expect(throws: CancellationError.self) { try await stop.value }

        try await store.syncNativeRoom(roomID: room.id)

        let stopped = try #require(store.room(id: room.id))
        #expect(stopped.nativePendingCancelID == nil)
        #expect(!stopped.isRunning)
        #expect(client.stopped.map(\.cancelID) == ["stop-1"])
    }

    /// A relaunch keeps the saved stop. Connecting again reads the room log,
    /// with or without a turn still waiting, and settles it there.
    @Test(arguments: [true, false])
    func savedStopSettlesAfterRelaunchOnceTheRoomLogShowsIt(hasPendingTurn: Bool) async throws {
        let directory = try stopTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = stopTestRepository(directory)
        let room = try stopTestRoom(id: "stop-relaunch", running: hasPendingTurn, cancelID: "stop-1")
        try repository.save([room])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.loggedStopCancelIDs = ["stop-1"]
        client.logPages = [[stopEvent(roomID: room.id, sequence: 1, cancelID: "stop-1")]]

        let store = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository)
        try store.load()
        #expect(store.room(id: room.id)?.nativePendingCancelID == "stop-1")
        store.configureNativeClient(client)
        defer { store.configureNativeClient(nil) }
        for _ in 0..<150 where store.room(id: room.id)?.nativePendingCancelID != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let settled = try #require(store.room(id: room.id))
        #expect(settled.nativePendingCancelID == nil)
        #expect(settled.nativePendingEventID == nil)
        #expect(!settled.isRunning)
        #expect(client.stopped.isEmpty)
    }

    // MARK: The chat

    @Test func anUnconfirmedStopNeverBlocksTheNextMessage() async throws {
        let (model, store, client) = try await stopTestChat(draft: "@everyone what next?", cancelID: "stop-1")
        replyOnSend(client, roomID: "bot-fixture", text: "Here is the next step")

        #expect(model.canSend)
        #expect(model.sendUnavailableReason == nil)
        await model.send()

        #expect(client.sentPayloads.map(\.text) == ["@everyone what next?"])
        #expect(model.draft.isEmpty)
        #expect(model.failureMessage == nil)
        #expect(store.room(id: "bot-fixture")?.nativePendingCancelID == nil)
        #expect(client.stopped.isEmpty)
    }

    @Test func stopAgainKeepsTheDraftAndThenTheMessageGoesOut() async throws {
        let (model, store, client) = try await stopTestChat(draft: "@everyone what next?", cancelID: "stop-1")
        replyOnSend(client, roomID: "bot-fixture", text: "Here is the next step")

        #expect(model.canStop)
        await model.stop()

        #expect(client.stopped.map(\.cancelID) == ["stop-1"])
        #expect(store.room(id: "bot-fixture")?.nativePendingCancelID == nil)
        #expect(model.draft == "@everyone what next?")
        #expect(model.failureMessage == nil)
        await model.send()
        #expect(client.sentPayloads.map(\.text) == ["@everyone what next?"])
        #expect(model.failureMessage == nil)
    }

    @Test func aStopAnswerLostAfterHermesAppliedItShowsNoFailure() async throws {
        let (model, store, client) = try await stopTestChat(draft: "", cancelID: nil, running: true)
        client.stopFailures = [.afterHost]

        await model.stop()

        #expect(model.failureMessage == nil)
        #expect(store.room(id: "bot-fixture")?.nativePendingCancelID == nil)
        #expect(store.room(id: "bot-fixture")?.isRunning == false)
    }

    @Test func sendSaysTheRoomIsStoppingWhileAStopIsOnItsWay() async throws {
        let (model, _, client) = try await stopTestChat(draft: "", cancelID: nil, running: true)
        client.blockGroupsStop = true

        let stopping = Task { await model.stop() }
        await client.waitUntilGroupsStopStarts(count: 1)
        model.draft = "@everyone one more thing"

        #expect(!model.canSend)
        #expect(model.sendUnavailableReason == "the room is stopping")
        client.releaseBlockedGroupsStop()
        await stopping.value
        #expect(model.canSend)
    }
}

@MainActor
private func stopTestRoom(id: String, running: Bool, cancelID: String? = nil) throws -> BotModeRoom {
    let source = BotModeRoom.fixture(id: id, memberIDs: ["finance", "research"])
    return try BotModeRoom(
        id: id,
        members: source.members,
        isRunning: running,
        runOwner: running ? BotModeRunOwner(instanceID: "earlier", generation: 1) : nil,
        nativeRoomID: id,
        nativeAuthorityGatewayID: "gateway",
        nativeAuthorityEpoch: 1,
        nativePendingEventID: running ? "client-event" : nil,
        nativePendingThreadID: running ? "loopdy-\(id)" : nil,
        nativePendingText: running ? "@everyone plan the trip" : nil,
        nativePendingDiscussionEventID: running ? "server-client-event" : nil,
        nativePendingCancelID: cancelID
    )
}

private func stopEvent(roomID: String, sequence: Int, cancelID: String) -> HermesBotModeEvent {
    .fixture(roomID: roomID, sequence: sequence, eventID: "room-stop:\(cancelID)",
             kind: "room.stop_requested", payload: ["cancel_id": .string(cancelID)])
}

/// Hermes writes the answer only after the message arrives.
@MainActor
private func replyOnSend(_ client: NativeBotModeTestClient, roomID: String, text: String) {
    client.onSend = {
        let next = (client.logPages.joined().map(\.sequence).max() ?? client.stateLatestSequence) + 10
        client.logPages.append([
            .fixture(roomID: roomID, sequence: next, eventID: "answer-\(next)", kind: "message.member", payload: [
                "member_id": .string("finance"), "text": .string(text),
            ]),
            .fixture(roomID: roomID, sequence: next + 1, eventID: "settled-\(next)", kind: "room.activity", payload: [
                "status": .string("settled"),
            ]),
        ])
    }
}

@MainActor
private func stopTestChat(
    draft: String, cancelID: String?, running: Bool = false
) async throws -> (ChatModel, BotModeRoomStore, NativeBotModeTestClient) {
    let room = try stopTestRoom(id: "bot-fixture", running: running, cancelID: cancelID)
    let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], executionEnabled: false)
    let model = ChatModel(
        conversationID: room.id, client: ConversationFixtureClient(canonicalAgentID: "finance"),
        agentID: "finance", initialItems: [], initialDraft: draft,
        sourceSession: SessionRecord(id: room.id, kind: .botMode, agentIDs: room.memberIDs, title: "Group",
                                     items: [], botModeRoomID: room.id),
        botModeRoomStore: store, botModeRoomID: room.id
    )
    let client = NativeBotModeTestClient(capabilities: .fixture())
    store.configureNativeClient(client)
    await store.refreshNativeCapabilities()
    return (model, store, client)
}

private func stopTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BighelpBotModeStopTests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func stopTestRepository(_ directory: URL) -> DemoRepository<[BotModeRoom]> {
    DemoRepository<[BotModeRoom]>(
        directory: directory, name: "bot-rooms", seed: [],
        migrations: BotModeRoomCacheSchema.migrations,
        currentSchemaVersion: BotModeRoomCacheSchema.currentVersion
    )
}
