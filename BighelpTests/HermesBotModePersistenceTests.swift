import Foundation
import Testing
@testable import Bighelp

@MainActor
struct HermesBotModePersistenceTests {
    @Test func distinctBasenameProtectsNativeCacheFromAnOldBinaryWriter() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = DemoRepository<[BotModeRoom]>(
            directory: directory, name: BotModeRoomCacheSchema.legacyRepositoryName, seed: []
        )
        try legacy.save([BotModeRoom.fixture(id: "legacy", memberIDs: ["finance", "research"])])
        let current = DemoRepository<[BotModeRoom]>(
            directory: directory, name: BotModeRoomCacheSchema.repositoryName, seed: [],
            migrations: BotModeRoomCacheSchema.migrations, currentSchemaVersion: 2
        )
        let native = BotModeRoom.fixture(id: "current", memberIDs: ["finance", "research"])
        try current.save([native])
        let file = directory.appending(path: "\(BotModeRoomCacheSchema.repositoryName)-v1.json")
        let before = try Data(contentsOf: file)
        try legacy.save([])
        #expect(try Data(contentsOf: file) == before)
        #expect(try current.load() == [native])
        #expect(try legacy.load().isEmpty)
    }

    @Test func migratesLegacyCacheAndOldReadersAndWritersPreserveVersionTwo() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = DemoRepository<[BotModeRoom]>(directory: directory, name: "rooms", seed: [])
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        try legacy.save([room])
        let current = DemoRepository<[BotModeRoom]>(
            directory: directory, name: "rooms", seed: [],
            migrations: BotModeRoomCacheSchema.migrations,
            currentSchemaVersion: BotModeRoomCacheSchema.currentVersion
        )
        #expect(try current.load() == [room])
        let file = directory.appending(path: "rooms-v1.json")
        let original = try Data(contentsOf: file)
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 2, current: 1)) {
            try legacy.load()
        }
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 2, current: 1)) {
            try legacy.save([])
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(legacy.lastRecoveryBackupURL == nil)
    }

    @Test func truthfulNativeMembersRoundTripOnlyThroughVersionTwo() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[BotModeRoom]>(
            directory: directory, name: "rooms", seed: [],
            migrations: BotModeRoomCacheSchema.migrations, currentSchemaVersion: 2
        )
        let state = HermesBotModeRoomState(
            roomID: "room", name: "Research",
            members: [
                .init(memberID: "seat-1", profile: "finance", handle: "finance",
                      target: ["kind": .string("local"), "profile": .string("finance")]),
                .init(memberID: "seat-2", profile: "research", handle: "research",
                      target: ["kind": .string("local"), "profile": .string("research")]),
            ],
            authorityGatewayID: "gateway", authorityEpoch: 1, revision: 1,
            createdAt: 1, updatedAt: 1, latestSequence: 0, disbandedAt: nil, driverStatus: nil
        )
        var room = BotModeRoom.fixture(id: "room", memberIDs: ["finance", "research"])
        room.markNativeRoom(state)
        let persistence = DemoBotModeRoomPersistence(repository: repository)
        _ = try persistence.insert(room)
        let restored = try #require(persistence.load(recoveringRuns: true).first)
        #expect(restored.members.map(\.id) == ["seat-1", "seat-2"])
        #expect(restored.members.allSatisfy { $0.sessionID.isEmpty })
        #expect(restored.memberContexts.isEmpty)
        #expect(restored.nativeState == state)
    }

    @Test func v1StorageRejectsNativeExecutionBeforeAnyRemoteSideEffect() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[BotModeRoom]>(directory: directory, name: "rooms", seed: [])
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        try repository.save([room])
        let before = try Data(contentsOf: directory.appending(path: "rooms-v1.json"))
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository,
                                     rooms: [room], nativeClient: client)
        await #expect(throws: BotModePersistenceError.unsupportedNativeSchema) {
            try await store.send(text: "Do not dispatch", roomID: room.id)
        }
        #expect(client.createdRoomIDs.isEmpty)
        #expect(client.sentEventIDs.isEmpty)
        #expect(try Data(contentsOf: directory.appending(path: "rooms-v1.json")) == before)
    }

    @Test func coldNativeStoreAutomaticallyLoadsExistingRoomBeforeOpeningIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try nativeRepository(in: directory)
        let client = PersistedNativeRoomClient(state: nativeState(roomID: "cold-room"))
        let state = try await client.groupsState(roomID: "cold-room", includeDisbanded: false)
        let persisted = try nativeRoom(from: state, revision: 7)
        try repository.save([persisted])

        let store = BotModeRoomStore(
            client: BotModeFixtureClient(), repository: repository,
            executionEnabled: false, nativeClient: client
        )

        let opened = try await store.openNativeRoom(roomID: persisted.id)

        #expect(opened.id == persisted.id)
        #expect(opened.hasNativeRoom)
        #expect(opened.title == "Persisted room")
        #expect(opened.memberIDs == ["member-finance", "member-research"])
        #expect(opened.persistenceRevision == 8)
        #expect(try repository.load().first?.persistenceRevision == 8)
    }

    @Test func nativeColdLoadPreservesActiveOwnerAndCASRevisionAcrossRepeatedLoads() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try nativeRepository(in: directory)
        let state = nativeState(roomID: "active-room")
        let owner = BotModeRunOwner(instanceID: "prior-process", generation: 4)
        let persisted = try nativeRoom(from: state, revision: 11, owner: owner)
        try repository.save([persisted])

        let store = BotModeRoomStore(
            client: BotModeFixtureClient(), repository: repository,
            executionEnabled: false,
            nativeClient: NativeBotModeTestClient(capabilities: .fixture())
        )

        try store.load()
        let loaded = try #require(store.room(id: persisted.id))
        #expect(loaded.isRunning)
        #expect(loaded.runOwner == owner)
        #expect(loaded.persistenceRevision == 11)

        var changed = loaded
        changed.appendNativeShared(.human(text: "Retained local presentation", id: "retained-event"))
        store.replace(room: changed)
        try store.load()

        let afterRepeatedLoad = try #require(store.room(id: persisted.id))
        let onDisk = try #require(repository.load().first)
        #expect(afterRepeatedLoad.isRunning)
        #expect(afterRepeatedLoad.runOwner == owner)
        #expect(afterRepeatedLoad.persistenceRevision == 12)
        #expect(onDisk.isRunning)
        #expect(onDisk.runOwner == owner)
        #expect(onDisk.persistenceRevision == 12)
    }

    @Test func coldPendingNativeSendReplaysCanonicalDiscussionReceiptAndSettles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try nativeRepository(in: directory)
        let state = nativeState(roomID: "pending-room", latestSequence: 3)
        let client = PersistedNativeRoomClient(state: state, logPages: [[
            nativeEvent(
                roomID: state.roomID, sequence: 1, eventID: "user-event", kind: "message.user",
                actor: ["kind": .string("user"), "id": .string("desktop")],
                payload: ["text": .string("Ask Hermes"), "thread_id": .string("pending-thread")]
            ),
            nativeEvent(
                roomID: state.roomID, sequence: 2, eventID: "member-event", kind: "message.member",
                actor: ["kind": .string("member"), "id": .string("member-finance")],
                payload: [
                    "member_id": .string("member-finance"), "text": .string("Recovered member reply"),
                    "discussion_event_id": .string("discussion-client-event"),
                    "thread_id": .string("pending-thread"),
                ]
            ),
            nativeEvent(
                roomID: state.roomID, sequence: 3, eventID: "activity-event", kind: "room.activity",
                actor: ["kind": .string("gateway"), "id": .string("gateway")],
                payload: [
                    "status": .string("settled"),
                    "discussion_event_id": .string("discussion-client-event"),
                    "thread_id": .string("pending-thread"),
                ]
            ),
        ]])
        let owner = BotModeRunOwner(instanceID: "prior-process", generation: 9)
        let persisted = try nativeRoom(
            from: state, revision: 20, owner: owner,
            pendingEventID: "client-event", pendingThreadID: "pending-thread", pendingText: "Ask Hermes"
        )
        try repository.save([persisted])

        let store = BotModeRoomStore(
            client: BotModeFixtureClient(), repository: repository,
            executionEnabled: false, nativeClient: client
        )

        let opened = try await store.openNativeRoom(roomID: persisted.id)
        let onDisk = try #require(repository.load().first)

        #expect(client.sentEventIDs == ["client-event"])
        #expect(opened.isRunning == false)
        #expect(opened.runOwner == nil)
        #expect(opened.nativePendingEventID == nil)
        #expect(opened.nativePendingDiscussionEventID == nil)
        #expect(opened.nativeLogCursor == 3)
        #expect(opened.visibleEvents.contains { $0.text == "Recovered member reply" })
        #expect(onDisk.nativeLogCursor == 3)
        #expect(onDisk.nativePendingEventID == nil)
        #expect(onDisk.isRunning == false)
    }

    @Test func retiredModelCannotActOnReplacementHostRoomWithMatchingID() async throws {
        let client = NativeBotModeTestClient(capabilities: .fixture())
        var room = BotModeRoom.fixture(id: "shared-id", memberIDs: ["finance", "research"])
        room.markNativeRoom(.fixture(roomID: room.id))
        room.beginRun(owner: .init(instanceID: "old-run", generation: 1))
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)
        await store.refreshNativeCapabilities()
        let model = ChatModel(conversationID: room.id, client: ConversationFixtureClient(),
                              initialItems: [], botModeRoomStore: store, botModeRoomID: room.id)
        model.invalidateReferenceOwnership()
        store.resetForAccountBoundary()
        store.configureNativeClient(client)
        store.replace(room: room)
        await store.refreshNativeCapabilities()
        #expect(model.botModeRoom == nil)
        #expect(model.botModeActivityScope.isEmpty)
        #expect(!model.canStop)
        #expect(!model.canRetry)
        #expect(model.pendingBotModeApprovals.isEmpty)
        await model.stop()
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await model.renameBotModeRoom("Wrong host")
        }
        #expect(client.stopped.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bot-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func nativeRepository(in directory: URL) throws -> DemoRepository<[BotModeRoom]> {
        DemoRepository(
            directory: directory, name: BotModeRoomCacheSchema.repositoryName, seed: [],
            migrations: BotModeRoomCacheSchema.migrations,
            currentSchemaVersion: BotModeRoomCacheSchema.currentVersion
        )
    }

    private func nativeState(roomID: String, latestSequence: Int? = 0) -> HermesBotModeRoomState {
        HermesBotModeRoomState(
            roomID: roomID, name: "Persisted room",
            members: [
                .init(
                    memberID: "member-finance", profile: "finance", handle: "finance",
                    target: ["kind": .string("local"), "profile": .string("finance")]
                ),
                .init(
                    memberID: "member-research", profile: "research", handle: "research",
                    target: ["kind": .string("local"), "profile": .string("research")]
                ),
            ],
            authorityGatewayID: "gateway", authorityEpoch: 1, revision: 3,
            createdAt: 1_788_000_000, updatedAt: 1_788_000_001,
            latestSequence: latestSequence, disbandedAt: nil, driverStatus: nil
        )
    }

    private func nativeRoom(
        from state: HermesBotModeRoomState,
        revision: Int,
        owner: BotModeRunOwner? = nil,
        pendingEventID: String? = nil,
        pendingThreadID: String? = nil,
        pendingText: String? = nil
    ) throws -> BotModeRoom {
        try BotModeRoom(
            id: state.roomID,
            members: state.members.map {
                BotModeMember(
                    profileID: $0.profile, handle: $0.handle, sessionID: "",
                    nativeMemberID: $0.memberID
                )
            },
            visibleEvents: [.botModeStarted(id: "started-\(state.roomID)")],
            isRunning: owner != nil,
            runOwner: owner,
            persistenceRevision: revision,
            nativeRoomID: state.roomID,
            nativeLogCursor: 0,
            nativeAuthorityGatewayID: state.authorityGatewayID,
            nativeAuthorityEpoch: state.authorityEpoch,
            nativePendingEventID: pendingEventID,
            nativePendingThreadID: pendingThreadID,
            nativePendingText: pendingText,
            nativeState: state
        )
    }

    private func nativeEvent(
        roomID: String,
        sequence: Int,
        eventID: String,
        kind: String,
        actor: [String: BighelpJSONValue],
        payload: [String: BighelpJSONValue]
    ) -> HermesBotModeEvent {
        HermesBotModeEvent(
            roomID: roomID, sequence: sequence, eventID: eventID, kind: kind,
            actor: actor, authorityEpoch: 1, payload: payload, createdAt: 1_788_000_002 + Double(sequence)
        )
    }
}

@MainActor
private final class PersistedNativeRoomClient: HermesBotModeClient {
    let state: HermesBotModeRoomState
    var logPages: [[HermesBotModeEvent]]
    private(set) var sentEventIDs: [String] = []

    init(state: HermesBotModeRoomState, logPages: [[HermesBotModeEvent]] = []) {
        self.state = state
        self.logPages = logPages
    }

    func groupsCapabilities() async throws -> HermesBotModeCapabilities {
        HermesBotModeCapabilities(
            protocolVersion: 2, driver: true, persistentProcess: true,
            authorityGatewayID: state.authorityGatewayID, roomLink: [:],
            features: HermesBotModeCapabilities.requiredFeatures,
            methods: HermesBotModeCapabilities.requiredOperations,
            maxLogLimit: 500
        )
    }

    func groupsCreate(
        roomID: String,
        name _: String,
        members _: [HermesBotModeRoomMember]
    ) async throws -> HermesBotModeRoomState {
        guard roomID == state.roomID else { throw BotModeRoomError.roomNotFound }
        return state
    }

    func groupsState(roomID: String, includeDisbanded _: Bool) async throws -> HermesBotModeRoomState {
        guard roomID == state.roomID else { throw BotModeRoomError.roomNotFound }
        return state
    }

    func groupsSend(
        roomID: String,
        eventID: String,
        payload: HermesBotModeUserPayload
    ) async throws -> HermesBotModeSendResult {
        guard roomID == state.roomID else { throw BotModeRoomError.roomNotFound }
        sentEventIDs.append(eventID)
        let discussionEventID = "discussion-\(eventID)"
        return HermesBotModeSendResult(
            event: HermesBotModeEvent(
                roomID: roomID, sequence: 1, eventID: discussionEventID, kind: "message.user",
                actor: ["kind": .string("user"), "id": .string("desktop")], authorityEpoch: 1,
                payload: ["text": .string(payload.text), "thread_id": .string(payload.threadID)],
                createdAt: 1_788_000_003
            ),
            clientEventID: eventID, accepted: true, driverStarted: true
        )
    }

    func groupsLog(
        roomID: String,
        sinceSequence: Int,
        limit _: Int,
        includeDisbanded _: Bool
    ) async throws -> HermesBotModeLogPage {
        guard roomID == state.roomID else { throw BotModeRoomError.roomNotFound }
        let events = logPages.isEmpty ? [] : logPages.removeFirst()
        let cursor = events.last?.sequence ?? sinceSequence
        return HermesBotModeLogPage(
            events: events, cursor: cursor,
            latestSequence: max(state.latestSequence ?? 0, cursor), hasMore: !logPages.isEmpty,
            authority: .init(gatewayID: state.authorityGatewayID, epoch: state.authorityEpoch)
        )
    }

    func groupsStop(roomID: String, cancelID _: String) async throws {
        guard roomID == state.roomID else { throw BotModeRoomError.roomNotFound }
    }

    func groupsRetry(roomID: String, taskID _: String, attempt _: HermesBotModeRetryAttempt?) async throws -> HermesBotModeRetryResult {
        guard roomID == state.roomID else { throw BotModeRoomError.roomNotFound }
        throw BotModeRoomError.noRetryableFailure
    }
}
