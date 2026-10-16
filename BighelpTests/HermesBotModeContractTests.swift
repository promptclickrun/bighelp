import Foundation
import Testing
@testable import Bighelp

@MainActor
struct HermesBotModeContractTests {
    @Test func nativeHandlesUseFriendlyNamesWithoutChangingProfileIdentity() {
        let profiles = [
            AgentProfile(id: "default", name: "Hermes", role: "", summary: "", instructions: "", avatarFileName: nil, isDefault: true),
            AgentProfile(id: "copy", name: "Hermes", role: "", summary: "", instructions: "", avatarFileName: nil, isDefault: false),
            AgentProfile(id: "all", name: "All", role: "", summary: "", instructions: "", avatarFileName: nil, isDefault: false),
            AgentProfile(id: "research", name: "研究", role: "", summary: "", instructions: "", avatarFileName: nil, isDefault: false),
        ]
        let handles = NativeBotModeHandles.directory(for: profiles)
        #expect(handles.map(\.profileID) == ["default", "copy", "all", "research"])
        #expect(handles.map(\.handle) == ["hermes", "hermes-2", "all-agent", "research"])
        #expect(handles.allSatisfy { HermesBotModeWireCodec.identifier($0.handle) })
    }

    @Test func mainRoomThreadRemainsStableAndWithinNativeIdentifierBounds() {
        #expect(HermesBotModeWireCodec.mainThreadID(roomID: "short") == "loopdy-short")
        let longRoom = String(repeating: "a", count: 128)
        let thread = HermesBotModeWireCodec.mainThreadID(roomID: longRoom)
        #expect(HermesBotModeWireCodec.identifier(thread))
        #expect(thread == HermesBotModeWireCodec.mainThreadID(roomID: longRoom))
        #expect(thread != HermesBotModeWireCodec.mainThreadID(roomID: String(repeating: "b", count: 128)))
    }

    @Test func oversizedNativeMessageNeverCreatesRoomOrReservesSend() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)
        await #expect(throws: WorkspaceClientError.invalidRequest) {
            try await store.send(text: String(repeating: "x", count: 65_537), roomID: room.id)
        }
        #expect(client.createdRoomIDs.isEmpty)
        #expect(client.sentEventIDs.isEmpty)
        #expect(store.room(id: room.id)?.nativePendingEventID == nil)
    }

    @Test func unsupportedProtocolCannotAdoptRoomStateBeforeNegotiation() async throws {
        let capabilities = HermesBotModeCapabilities(
            protocolVersion: 3, driver: true, persistentProcess: false, authorityGatewayID: "gateway",
            roomLink: [:], features: HermesBotModeCapabilities.requiredFeatures,
            methods: HermesBotModeCapabilities.requiredOperations, maxLogLimit: 500
        )
        let client = NativeBotModeTestClient(capabilities: capabilities)
        let store = BotModeRoomStore(client: BotModeFixtureClient(), nativeClient: client)
        await #expect(throws: BotModeRoomError.executionUnavailable) {
            try await store.openNativeRoom(roomID: "room")
        }
        #expect(client.stateCallCount == 0)
        #expect(store.rooms.isEmpty)
    }

    @Test func nativeRosterPreservesUnavailableAndSourceQualifiedMembers() {
        let members: [HermesBotModeRoomMember] = [
            .init(memberID: "member-one", profile: "missing", handle: "archivist",
                  displayName: "Archivist", target: ["kind": .string("local"), "profile": .string("missing")]),
            .init(memberID: "member-two", profile: "missing", handle: "archivist-peer",
                  target: ["kind": .string("peer"), "profile": .string("missing")]),
        ]
        let participants = members.map { HermesBotModeParticipant(member: $0, profiles: []) }
        #expect(participants.map(\.id) == ["member-one", "member-two"])
        #expect(participants.map(\.profileID) == ["missing", "missing"])
        #expect(participants[0].displayName == "Archivist")
        #expect(participants[0].availability == .profileUnavailable)
        #expect(participants[1].availability == .unsupportedTarget)
        #expect(participants.allSatisfy { !$0.canOpenAgentChat })
    }

    @Test func nativeRoomSummaryKeepsServerNameTimestampAndCompleteRoster() {
        let room = HermesBotModeRoomState(
            roomID: "room-one", name: "Research room",
            members: [
                .init(memberID: "member-one", profile: "default", handle: "helper",
                      target: ["kind": .string("local"), "profile": .string("default")]),
                .init(memberID: "member-two", profile: "missing", handle: "archivist",
                      target: ["kind": .string("local"), "profile": .string("missing")]),
            ],
            authorityGatewayID: "gateway", authorityEpoch: 1, revision: 2,
            createdAt: 1, updatedAt: 3, latestSequence: 7, disbandedAt: nil, driverStatus: nil
        )
        let summary = HermesBotModeRoomSummary(room: room, capabilities: nil)
        #expect(summary.id == "room-one")
        #expect(summary.name == "Research room")
        #expect(summary.updatedAt == Date(timeIntervalSince1970: 3))
        #expect(summary.memberCount == 2)
        #expect(summary.participants(profiles: []).count == 2)
        #expect(summary.canOpen)
        #expect(!summary.canRename)
        #expect(!summary.canExecute)
    }

    @Test func nativeHumanProvenanceAndOwnDisplaySnapshotSurviveReplay() throws {
        let source = BotModeRoom.fixture(id: "room-identity", memberIDs: ["finance", "research"])
        var room = try BotModeRoom(
            id: source.id, members: source.members, nativeRoomID: source.id
        )
        let owner = BotModeRunOwner(instanceID: "fixture-owner", generation: 1)
        room.prepareNativeTurn(eventID: "client-own", threadID: "thread", text: "Own",
                               owner: owner, senderSnapshot: .init(name: "Alex"))
        room.markNativeDiscussion(eventID: "server-own")
        room.clearNativeTurn()
        room.settleRun()
        for (index, id) in ["server-own", "server-other"].enumerated() {
            let event = HermesBotModeEvent(
                roomID: room.id, sequence: index + 1, eventID: id, kind: "message.user",
                actor: ["kind": .string("user"), "id": .string("desktop")], authorityEpoch: 1,
                payload: ["text": .string("Synthetic"), "thread_id": .string("thread")], createdAt: 1
            )
            room.appendNativeShared(try #require(event.botModeEvent(sourceOrder: index)))
        }
        room.appendNativeShared(.human(text: "Legacy cached message", id: "server-legacy"))
        let restored = try JSONDecoder().decode(BotModeRoom.self, from: JSONEncoder().encode(room))
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [restored], executionEnabled: false)
        let model = ChatModel(
            conversationID: room.id, client: ConversationFixtureClient(),
            userIdentity: .init(name: "Current display", avatarFileName: nil),
            initialItems: [], botModeRoomStore: store, botModeRoomID: room.id
        )
        #expect(model.botModeTimelineItems.map(\.sender.snapshot.name) == ["Alex", "Human participant", "Human participant"])
        #expect(model.botModeTimelineItems[1].sender.id != UserIdentity.stableID)
        #expect(restored.visibleEvents.first(where: { $0.id == "server-other" })?.nativeEvent?.actor["id"] == .string("desktop"))
    }

    @Test func nativeMessagesFromFormerMembersSurviveReloadAndShow() throws {
        // Hermes keeps a removed member's messages in the room's history. The
        // replay cursor is already past them, so a dropped one never returns.
        let source = BotModeRoom.fixture(id: "room-former", memberIDs: ["finance", "research"])
        var room = try BotModeRoom(id: source.id, members: source.members, nativeRoomID: source.id)
        let actors: [(String, [String: BighelpJSONValue])] = [
            ("named", ["kind": .string("member"), "id": .string("former-1"), "display_name": .string("Old helper")]),
            ("unnamed", ["kind": .string("member"), "id": .string("former-2")]),
        ]
        for (index, (id, actor)) in actors.enumerated() {
            let event = HermesBotModeEvent(
                roomID: room.id, sequence: index + 1, eventID: id, kind: "message.member",
                actor: actor, authorityEpoch: 1,
                payload: ["text": .string("Earlier answer"), "thread_id": .string("thread"),
                          "member_id": try #require(actor["id"])],
                createdAt: 1
            )
            room.appendNativeShared(try #require(event.botModeEvent(sourceOrder: index)))
        }
        let restored = try JSONDecoder().decode(BotModeRoom.self, from: JSONEncoder().encode(room))
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [restored], executionEnabled: false)
        let model = ChatModel(
            conversationID: room.id, client: ConversationFixtureClient(),
            userIdentity: .init(name: "Current display", avatarFileName: nil),
            initialItems: [], botModeRoomStore: store, botModeRoomID: room.id
        )

        #expect(restored.visibleEvents.map(\.id).filter { ["named", "unnamed"].contains($0) } == ["named", "unnamed"])
        #expect(model.botModeTimelineItems.map(\.sender.snapshot.name) == ["Old helper", "Former member"])
        #expect(model.botModeTimelineItems.allSatisfy { $0.sender.snapshot.avatarFileName == nil })
    }

    @Test func nativeMetadataPreservesMemberIdentityWithoutPersistingApprovalOffers() throws {
        var room = BotModeRoom.fixture(id: "room-metadata", memberIDs: ["finance", "research"])
        let state = HermesBotModeRoomState(
            roomID: room.id, name: "Server title",
            members: [
                .init(memberID: "first-seat", profile: "finance", handle: "finance",
                      target: ["kind": .string("local"), "profile": .string("finance")]),
                .init(memberID: "second-seat", profile: "finance", handle: "finance-two",
                      target: ["kind": .string("local"), "profile": .string("finance")]),
            ],
            authorityGatewayID: "gateway", authorityEpoch: 1, revision: 3,
            createdAt: 1, updatedAt: 2, latestSequence: 0, disbandedAt: nil,
            driverStatus: ["pending_actions": .array([.object(["request_id": .string("never-persist")])])]
        )
        room.markNativeRoom(state)
        let data = try JSONEncoder().encode(room)
        let restored = try JSONDecoder().decode(BotModeRoom.self, from: data)
        #expect(restored.title == "Server title")
        #expect(restored.memberIDs == ["first-seat", "second-seat"])
        #expect(restored.profileIDs == ["finance"])
        #expect(restored.members.allSatisfy { $0.sessionID.isEmpty })
        #expect(restored.nativeState?.driverStatus == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("never-persist"))
    }

    @Test func sameWorkspaceReconnectKeepsGroupsUntilNativeSyncCompletes() async throws {
        let client = BotModeCatalogFixtureClient()
        let store = BotModeRoomStore(client: BotModeFixtureClient(), executionEnabled: false, nativeClient: client)
        await store.refreshNativeRoomCatalog()
        let ids = store.catalogRooms.map(\.roomID)
        store.configureNativeClient(nil, preservingCatalog: true)
        await store.refreshNativeRoomCatalog()
        #expect(store.catalogRooms.map(\.roomID) == ids)
        #expect(store.catalogState == .loaded)
        #expect(store.isCatalogStale)
        store.configureNativeClient(client, preservingCatalog: true)
        #expect(store.catalogRooms.map(\.roomID) == ids)
        await store.refreshNativeRoomCatalog()
        #expect(store.catalogState == .loaded)
        #expect(store.catalogRooms.map(\.roomID) == ids)
        store.configureNativeClient(nil)
        #expect(store.catalogRooms.isEmpty)
    }

    @Test func readOnlyCatalogFixtureKeepsAllParticipantsAndRetiresOnHostChange() async throws {
        let store = BotModeRoomStore(client: BotModeFixtureClient(), executionEnabled: false,
                                     nativeClient: BotModeCatalogFixtureClient())
        await store.refreshNativeRoomCatalog()
        #expect(store.catalogState == .loaded)
        #expect(store.catalogRooms.map(\.roomID) == ["studio-pair", "research-circle"])
        #expect(store.catalogRooms[1].participants(profiles: []).count == 3)
        #expect(!store.canCreateNativeRoom)
        let room = try await store.openNativeRoom(roomID: "research-circle")
        #expect(room.members.count == 3)
        #expect(room.title == "Research circle")
        store.configureNativeClient(nil)
        #expect(store.catalogRooms.isEmpty)
        #expect(store.catalogState == .idle)
        #expect(!store.nativeExecutionAvailable)
    }

    @Test func lostRetryReceiptIsDurableAndNeverBlindlyReplaysTheBatch() async throws {
        var room = BotModeRoom.fixture(id: "retry-journal", memberIDs: ["finance", "research"])
        room.markNativeRoom(.fixture(roomID: room.id))
        let receipt = HermesBotModeTaskReceipt(
            roomID: room.id, taskID: "task-one", threadID: "thread", turnID: "turn",
            status: "queued", executionGeneration: 2, cancelGeneration: 0
        )
        var journal = HermesBotModeRetryJournal(taskIDs: ["task-one", "task-two"])
        journal.receipts["task-one"] = receipt
        journal.awaitingReceipt.insert("task-two")
        room.setNativeRetryJournal(journal)
        let restored = try JSONDecoder().decode(BotModeRoom.self, from: JSONEncoder().encode(room))
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.retryResults = [.success(.init(retried: true, task: receipt))]
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [restored],
                                     executionEnabled: false, nativeClient: client)
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await store.retry(roomID: room.id)
        }
        #expect(client.retryResults.count == 1)
        #expect(store.room(id: room.id)?.nativeRetryJournal?.receipts["task-one"] == receipt)
        #expect(store.room(id: room.id)?.nativeRetryJournal?.awaitingReceipt == ["task-two"])
    }

    @Test func confirmedGroupDeletionCannotBeUndoneByAnOlderCatalogRead() async throws {
        let client = DeferredGroupCatalogClient()
        let store = BotModeRoomStore(client: BotModeFixtureClient(), executionEnabled: false,
                                     nativeClient: client)
        await store.refreshNativeRoomCatalog()
        client.defersNextList = true
        let refresh = Task { await store.refreshNativeRoomCatalog() }
        while client.pendingList == nil { await Task.yield() }
        try await store.deleteNativeRoom(roomID: "studio-pair")
        client.pendingList?.resume()
        client.pendingList = nil
        await refresh.value
        #expect(store.catalogRooms.map(\.roomID) == ["research-circle"])
        #expect(store.catalogState == .loaded)
    }
}

@MainActor
private final class DeferredGroupCatalogClient: BotModeCatalogFixtureClient {
    var defersNextList = false
    var pendingList: CheckedContinuation<Void, Never>?

    override func groupsList(offset: Int, limit: Int) async throws -> HermesBotModeRoomListPage {
        let snapshot = try await super.groupsList(offset: offset, limit: limit)
        if defersNextList {
            defersNextList = false
            await withCheckedContinuation { pendingList = $0 }
        }
        return snapshot
    }
}
