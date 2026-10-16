import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BotModeRoomStoreTests {
    @Test func secondAgentStartsPrivateBotModeSection() throws {
        let room = try BotModeRoom.fromDirect(session: .directFixture, adding: "research")

        #expect(room.memberIDs == ["finance", "research"])
        #expect(room.visibleEvents.contains(where: { $0.kind == .botModeStarted }))
        #expect(room.privateHistory.map(\.id) == ["private-human"])
        #expect(room.memberContexts["research"]?.messages.isEmpty == true)
        #expect(room.memberContexts["finance"]?.messages.map(\.id) == ["private-human"])
    }

    @Test func rosterIsIdempotentBoundedAndNeverDropsLastMember() throws {
        var room = BotModeRoom.fixture(memberIDs: ["finance", "research"])

        #expect(try room.add(memberID: "research") == .alreadyMember)
        #expect(try room.add(memberID: "travel") == .added)
        #expect(try room.add(memberID: "home") == .added)
        #expect(try room.add(memberID: "legal") == .added)
        #expect(try room.add(memberID: "ops") == .added)
        #expect(try room.add(memberID: "seven") == .atCapacity)
        #expect(room.memberIDs == ["finance", "research", "travel", "home", "legal", "ops"])

        for id in ["research", "travel", "home", "legal", "ops"] {
            #expect(try room.remove(memberID: id) == .removed)
        }
        #expect(try room.remove(memberID: "finance") == .wouldBecomeEmpty)
        #expect(room.memberIDs == ["finance"])
    }

    @Test func removedMemberRejoinsAtEndWithOriginalStableHandle() throws {
        var room = BotModeRoom.fixture(memberIDs: ["finance", "research", "travel"])
        let originalHandle = try #require(room.member(id: "research")?.handle)

        #expect(try room.remove(memberID: "research") == .removed)
        #expect(try room.add(memberID: "research") == .added)
        #expect(room.memberIDs == ["finance", "travel", "research"])
        #expect(room.member(id: "research")?.handle == originalHandle)
    }

    @Test func profileHandlesAreCollisionSafeAndRemainStableAfterRejoin() throws {
        var room = BotModeRoom.fixture(memberIDs: ["finance", "research-one"])
        let duplicateName = AgentProfile(
            id: "research-two",
            name: "Research",
            role: "Specialist",
            summary: "",
            instructions: "",
            avatarFileName: nil,
            isDefault: false
        )
        let firstName = AgentProfile(
            id: "research-one",
            name: "Research",
            role: "Specialist",
            summary: "",
            instructions: "",
            avatarFileName: nil,
            isDefault: false
        )
        room = try BotModeRoom(id: room.id, members: [
            .init(profileID: "finance", handle: "finance", sessionID: "hidden-finance"),
            .init(profileID: firstName.id, handle: AgentHandle.normalized(firstName.name), sessionID: "hidden-one")
        ])

        #expect(try room.add(profile: duplicateName) == .added)
        #expect(room.member(id: duplicateName.id)?.handle == "research-2")
        #expect(try room.remove(memberID: duplicateName.id) == .removed)
        #expect(try room.add(profile: duplicateName) == .added)
        #expect(room.member(id: duplicateName.id)?.handle == "research-2")
    }

    @Test func persistedRosterAndBoundedHistoryReload() throws {
        let directory = try botModeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[BotModeRoom]>(directory: directory, name: "bot-rooms", seed: [])
        var room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        room.appendVisible(.human(text: "one"))
        room.appendVisible(.human(text: "two"))
        try repository.save([room])

        let store = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository)
        try store.load()

        #expect(store.room(id: room.id)?.memberIDs == ["finance", "research"])
        #expect(Array(store.room(id: room.id)?.visibleEvents.suffix(2).map(\.text) ?? []) == ["one", "two"])
    }

    @Test func reloadSettlesPersistedRunAndRetainsSharedWatermark() throws {
        let directory = try botModeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[BotModeRoom]>(directory: directory, name: "bot-rooms", seed: [])
        var room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let event = BotModeEvent.human(text: "Durable context", id: "watermark-event")
        room.appendShared(event)
        room.isRunning = true
        try repository.save([room])

        let store = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository)
        try store.load()

        #expect(store.room(id: room.id)?.isRunning == false)
        #expect(store.room(id: room.id)?.memberContexts["research"]?.sharedWatermark == "watermark-event")
    }

    @Test func removingMemberPrunesPrivateStateBeforePersistence() throws {
        let directory = try botModeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[BotModeRoom]>(directory: directory, name: "bot-rooms", seed: [])
        var room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        room.appendShared(.human(text: "Shared"))
        room.replaceFailures(with: [.init(memberID: "research", message: "retry")])

        #expect(try room.remove(memberID: "research") == .removed)
        try repository.save([room])
        let restored = try #require(try repository.load().first)

        #expect(restored.member(id: "research") == nil)
        #expect(restored.memberContexts["research"] == nil)
        #expect(!restored.memberFailures.contains(where: { $0.memberID == "research" }))
    }

    @Test func unresolvedMentionPreservesDraftAndDoesNotOfferRetry() async {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room])
        let model = ChatModel(
            conversationID: room.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            initialDraft: "Ask @claude for help",
            botModeRoomStore: store,
            botModeRoomID: room.id
        )

        await model.send()

        #expect(model.failureMessage == "No agent named @claude in this chat. Edit the mention and try again.")
        #expect(model.draft == "Ask @claude for help")
        #expect(model.canRetry == false)
        #expect(store.room(id: room.id)?.visibleEvents == room.visibleEvents)
    }

    @Test func executionDisabledRoomRemainsReadableButSendDoesNotMutateOrCallClient() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let client = BotModeFixtureClient()
        let store = BotModeRoomStore(client: client, rooms: [room], executionEnabled: false)
        let before = try #require(store.room(id: room.id))

        #expect(store.executionEnabled == false)
        #expect(store.room(id: room.id)?.visibleEvents == before.visibleEvents)

        await #expect(throws: BotModeRoomError.executionUnavailable) {
            try await store.send(text: "@everyone check in", roomID: room.id)
        }

        #expect(store.room(id: room.id)?.visibleEvents == before.visibleEvents)
        #expect(store.room(id: room.id)?.memberFailures == before.memberFailures)
        #expect(client.requests.isEmpty)
    }

    @Test func executionDisabledRoomCannotRetryPersistedFailure() async throws {
        var room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        room.replaceFailures(with: [.init(memberID: "research", message: "Unavailable")])
        let client = BotModeFixtureClient()
        let store = BotModeRoomStore(client: client, rooms: [room], executionEnabled: false)
        let before = try #require(store.room(id: room.id))

        await #expect(throws: BotModeRoomError.executionUnavailable) {
            try await store.retry(roomID: room.id)
        }

        #expect(store.room(id: room.id) == before)
        #expect(client.requests.isEmpty)
    }

    @Test func nativeDriverMustBeReadyBeforeExecutionIsAvailable() async throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture(driver: false))
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        await #expect(throws: BotModeRoomError.executionUnavailable) {
            try await store.send(text: "@everyone check in", roomID: room.id)
        }

        #expect(client.createdRoomIDs.isEmpty)
        #expect(store.nativeExecutionAvailable == false)
        #expect(store.room(id: room.id)?.visibleEvents == room.visibleEvents)
    }

    @Test func nativeCreateRequiresHermesMinimumRoster() async throws {
        let room = BotModeRoom.fixture(id: "native-one-member", memberIDs: ["finance"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        await #expect(throws: BotModeRoomError.invalidMember) {
            try await store.send(text: "Needs a room", roomID: room.id)
        }

        #expect(client.createdRoomIDs.isEmpty)
        #expect(store.room(id: room.id)?.nativeRoomID == nil)
    }

    @Test func nativeLogAuthorityMustMatchThePersistedRoomOwner() async throws {
        let source = BotModeRoom.fixture(id: "native-authority", memberIDs: ["finance", "research"])
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            nativeRoomID: source.id,
            nativeAuthorityGatewayID: "gateway",
            nativeAuthorityEpoch: 1
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.logAuthorityGatewayID = "different-gateway"
        client.logPages = [[
            .fixture(roomID: room.id, sequence: 1, eventID: "history", kind: "message.user", payload: [
                "text": .string("Must not apply"), "thread_id": .string("thread")
            ])
        ]]
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        await #expect(throws: BotModeRoomError.nativeAuthorityMismatch) {
            try await store.syncNativeRoom(roomID: room.id)
        }

        #expect(store.room(id: room.id)?.nativeLogCursor == 0)
        #expect(store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Must not apply" }) == false)
    }

    @Test func nativeSendCreatesStableRoomAndReplaysTypedLog() async throws {
        let room = BotModeRoom.fixture(id: "bot-native-room", memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.logPages = [[
            .fixture(roomID: room.id, sequence: 2, eventID: "member-event", kind: "message.member", payload: [
                "member_id": .string("finance"), "text": .string("Native answer")
            ]),
            .fixture(roomID: room.id, sequence: 3, eventID: "activity", kind: "room.activity", payload: [
                "status": .string("settled"), "discussion_event_id": .string("pending")
            ])
        ]]
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        var activities: [BotModeRunActivity] = []
        try await store.send(
            text: "@everyone check in",
            roomID: room.id,
            activitySink: { activities.append($0) }
        )

        #expect(client.createdRoomIDs == [room.id])
        #expect(client.sentRoomIDs == [room.id])
        #expect(client.sentEventIDs.count == 1)
        #expect(client.sentPayloads == [.init(text: "@everyone check in", threadID: "loopdy-\(room.id)")])
        #expect(store.room(id: room.id)?.nativeRoomID == room.id)
        #expect(store.room(id: room.id)?.nativeLogCursor == 3)
        #expect(store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Native answer" }) == true)
        #expect(store.room(id: room.id)?.isRunning == false)
        #expect(store.room(id: room.id)?.canEditMembership == false)
        #expect(activities.map(\.lifecycle) == [.succeeded])
    }

    /// Hermes appends a message sent during a member turn and queues it behind
    /// the active room drive (`groups.send` answers `accepted` while the room
    /// works). The app must send it then, not refuse until the room is quiet.
    @Test func nativeRoomAcceptsAFollowUpWhileMembersAreStillWorking() async throws {
        let room = BotModeRoom.fixture(id: "native-follow-up", memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)
        let thread = HermesBotModeWireCodec.mainThreadID(roomID: room.id)

        let first = Task { @MainActor in
            try await store.send(text: "@everyone plan the trip", roomID: room.id)
        }
        for _ in 0..<200 where store.room(id: room.id)?.nativePendingDiscussionEventID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(store.room(id: room.id)?.isRunning == true)

        try await store.send(text: "@finance keep it under budget", roomID: room.id)

        #expect(client.sentPayloads.map(\.text) == ["@everyone plan the trip", "@finance keep it under budget"])
        #expect(Set(client.sentEventIDs).count == 2)
        let follow = try #require(store.room(id: room.id)?.nativeFollowUps.first)
        #expect(follow.eventID == client.sentEventIDs[1])
        #expect(follow.discussionEventID == "server-\(client.sentEventIDs[1])")

        // Like Hermes: the newer message supersedes the turn still running for
        // the first one (cancelled, not failed), and only the newest settles.
        let firstID = "server-\(client.sentEventIDs[0])", secondID = "server-\(client.sentEventIDs[1])"
        client.logPages = [[
            .fixture(roomID: room.id, sequence: 1, eventID: firstID, kind: "message.user", payload: [
                "text": .string("@everyone plan the trip"), "thread_id": .string(thread)
            ]),
            .fixture(roomID: room.id, sequence: 2, eventID: "answer-1", kind: "message.member", payload: [
                "member_id": .string("finance"), "text": .string("Here is a plan"),
                "discussion_event_id": .string(firstID), "thread_id": .string(thread)
            ]),
            .fixture(roomID: room.id, sequence: 3, eventID: secondID, kind: "message.user", payload: [
                "text": .string("@finance keep it under budget"), "thread_id": .string(thread)
            ]),
            .fixture(roomID: room.id, sequence: 4, eventID: "superseded", kind: "turn.cancelled", payload: [
                "member_id": .string("research"), "task_id": .string("task-research"),
                "reason": .string("superseded_by_newer_user_event"),
                "discussion_event_id": .string(firstID), "thread_id": .string(thread)
            ]),
        ]]
        for _ in 0..<200 where store.room(id: room.id)?.nativeLogCursor != 4 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(store.room(id: room.id)?.isRunning == true)
        #expect(store.room(id: room.id)?.nativeFollowUps.count == 1)
        #expect(store.room(id: room.id)?.memberFailures.isEmpty == true)

        client.logPages = [[
            .fixture(roomID: room.id, sequence: 5, eventID: "answer-2", kind: "message.member", payload: [
                "member_id": .string("finance"), "text": .string("Budget noted"),
                "discussion_event_id": .string(secondID), "thread_id": .string(thread)
            ]),
            .fixture(roomID: room.id, sequence: 6, eventID: "settled-2", kind: "room.activity", payload: [
                "status": .string("settled"), "discussion_event_id": .string(secondID), "thread_id": .string(thread)
            ]),
        ]]
        try await first.value

        let settled = try #require(store.room(id: room.id))
        #expect(!settled.isRunning)
        #expect(settled.nativeFollowUps.isEmpty)
        #expect(settled.nativePendingEventID == nil)
        #expect(settled.visibleEvents.filter { $0.kind == .human }.map(\.text) == [
            "@everyone plan the trip", "@finance keep it under budget"
        ])
        #expect(settled.visibleEvents.contains { $0.text == "Budget noted" })
        #expect(settled.memberFailures.isEmpty)
        #expect(client.stopped.isEmpty)
    }

    /// A follow-up whose answer was lost keeps its identity: sending the same
    /// text again reuses it, so Hermes never sees a second human message.
    @Test func lostFollowUpReceiptRetriesWithTheSameClientEventID() async throws {
        let room = BotModeRoom.fixture(id: "native-follow-up-retry", memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)
        let first = Task { @MainActor in try await store.send(text: "@everyone start", roomID: room.id) }
        for _ in 0..<200 where store.room(id: room.id)?.nativePendingDiscussionEventID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        client.acceptedResponseLostRemaining = 1
        await #expect(throws: NativeBotModeTestError.transport) {
            try await store.send(text: "And this", roomID: room.id)
        }
        let pending = try #require(store.room(id: room.id)?.nativeFollowUps.first)
        #expect(pending.discussionEventID == nil)
        try await store.send(text: "And this", roomID: room.id)

        #expect(client.sentEventIDs.count == 3)
        #expect(client.sentEventIDs[1] == pending.eventID)
        #expect(client.sentEventIDs[2] == pending.eventID)
        #expect(store.room(id: room.id)?.nativeFollowUps.count == 1)
        #expect(store.room(id: room.id)?.nativeFollowUps.first?.discussionEventID == "server-\(pending.eventID)")
        try await store.stopNativeRoom(roomID: room.id, cancelID: "test-stop")
        _ = try? await first.value
    }

    /// Hermes drives only a thread's newest message. When the answer to a
    /// message sent mid-turn was lost, the room still finishes: the receipt
    /// is recovered under the same key and its discussion settles the turn.
    @Test func lostFollowUpReceiptIsRecoveredSoTheRoomStillFinishes() async throws {
        let room = BotModeRoom.fixture(id: "native-follow-up-lost", memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)
        let thread = HermesBotModeWireCodec.mainThreadID(roomID: room.id)
        let first = Task { @MainActor in try await store.send(text: "@everyone start", roomID: room.id) }
        for _ in 0..<200 where store.room(id: room.id)?.nativePendingDiscussionEventID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        client.acceptedResponseLostRemaining = 1
        await #expect(throws: NativeBotModeTestError.transport) {
            try await store.send(text: "Actually, stop and summarize", roomID: room.id)
        }
        let lost = try #require(store.room(id: room.id)?.nativeFollowUps.first)
        let secondID = "server-\(lost.eventID)"
        client.logPages = [[
            .fixture(roomID: room.id, sequence: 1, eventID: secondID, kind: "message.user", payload: [
                "text": .string("Actually, stop and summarize"), "thread_id": .string(thread)
            ]),
            .fixture(roomID: room.id, sequence: 2, eventID: "settled-2", kind: "room.activity", payload: [
                "status": .string("settled"), "discussion_event_id": .string(secondID), "thread_id": .string(thread)
            ]),
        ]]
        try await first.value

        #expect(client.sentEventIDs.filter { $0 == lost.eventID }.count == 2)
        #expect(client.sentEventIDs.count == 3)
        let settled = try #require(store.room(id: room.id))
        #expect(!settled.isRunning)
        #expect(settled.nativeFollowUps.isEmpty)
        #expect(settled.nativePendingEventID == nil)
    }

    /// While a message sent mid-turn is still being worked on, the next
    /// message is another follow-up, not a fresh turn that would leave the
    /// earlier one waiting forever.
    @Test func messageAfterTheTurnEndsButBeforeFollowUpsSettleIsAFollowUp() async throws {
        let source = BotModeRoom.fixture(id: "native-follow-up-tail", memberIDs: ["finance", "research"])
        let thread = HermesBotModeWireCodec.mainThreadID(roomID: source.id)
        // As after a relaunch: the turn's owner is gone, its follow-up isn't settled.
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            nativeRoomID: source.id,
            nativeAuthorityGatewayID: "gateway",
            nativeAuthorityEpoch: 1,
            nativeFollowUps: [HermesBotModeFollowUp(
                eventID: "bot-user-earlier", threadID: thread, text: "One more thing",
                senderSnapshot: nil, discussionEventID: "server-bot-user-earlier"
            )]
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)
        #expect(store.room(id: room.id)?.isRunning == false)
        #expect(store.room(id: room.id)?.isNativeWorking == true)

        try await store.send(text: "And another", roomID: room.id)

        let sent = try #require(store.room(id: room.id))
        #expect(sent.nativeFollowUps.map(\.text) == ["One more thing", "And another"])
        #expect(sent.nativePendingEventID == nil)
        #expect(client.sentPayloads.map(\.text) == ["And another"])
        try await store.stopNativeRoom(roomID: room.id, cancelID: "test-stop")
        #expect(store.room(id: room.id)?.isNativeWorking == false)
    }

    @Test func nativeStateSnapshotDoesNotSkipUncachedLogHistory() async throws {
        let source = BotModeRoom.fixture(id: "bot-native-replay", memberIDs: ["finance", "research"])
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            visibleEvents: source.visibleEvents,
            nativeRoomID: source.id,
            nativeLogCursor: 0
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.stateLatestSequence = 50
        client.logPages = [[
            .fixture(roomID: room.id, sequence: 1, eventID: "history-user", kind: "message.user", payload: [
                "text": .string("Recovered"), "thread_id": .string("thread")
            ])
        ]]
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        try await store.syncNativeRoom(roomID: room.id)

        #expect(client.loggedSinceSequences == [0])
        #expect(store.room(id: room.id)?.nativeLogCursor == 1)
        #expect(store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Recovered" }) == true)
    }

    @Test func nativeReplayAsksForNoMoreThanTheHostsLogLimit() async throws {
        let source = BotModeRoom.fixture(id: "bot-native-limit", memberIDs: ["finance", "research"])
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            visibleEvents: source.visibleEvents,
            nativeRoomID: source.id,
            nativeLogCursor: 0
        )
        // Hermes refuses a page larger than the limit it advertises.
        let client = NativeBotModeTestClient(capabilities: .fixture(maxLogLimit: 100))
        client.logPages = [[
            .fixture(roomID: room.id, sequence: 1, eventID: "limit-user", kind: "message.user", payload: [
                "text": .string("Hello"), "thread_id": .string("thread")
            ])
        ]]
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        try await store.syncNativeRoom(roomID: room.id)

        #expect(client.loggedLimits == [100])
    }

    @Test func nativeRoomRetainsFullTypedTranscriptAcrossReload() throws {
        let members = [
            BotModeMember(profileID: "finance", handle: "finance", sessionID: "finance-session"),
            BotModeMember(profileID: "research", handle: "research", sessionID: "research-session"),
        ]
        let nativeEvents: [BotModeEvent] = (1...205).map { rawIndex in
            let index: Int = rawIndex
            return BotModeEvent.agent(
                memberID: "finance",
                text: "Native message \(index)",
                id: "native-event-\(index)",
                sourceOrder: index
            )
        }
        let events: [BotModeEvent] = [.botModeStarted(id: "started")] + nativeEvents
        let room = try BotModeRoom(
            id: "native-long-transcript",
            members: members,
            visibleEvents: events,
            nativeRoomID: "native-long-transcript"
        )
        #expect(room.visibleEvents.count == 206)

        let reloaded = try JSONDecoder().decode(
            BotModeRoom.self,
            from: JSONEncoder().encode(room)
        )
        #expect(reloaded.visibleEvents.count == 206)
        #expect(reloaded.visibleEvents.last?.text == "Native message 205")
    }

    @Test func nativeStopIsExplicitAndClearsLocalRunWithoutUsingCancellationPath() async throws {
        let source = BotModeRoom.fixture(id: "native-stop", memberIDs: ["finance", "research"])
        let owner = BotModeRunOwner(instanceID: "test", generation: 1)
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            isRunning: true,
            runOwner: owner,
            nativeRoomID: source.id,
            nativePendingEventID: "client-event",
            nativePendingThreadID: "thread",
            nativePendingText: "running",
            nativePendingDiscussionEventID: "server-event"
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        try await store.stopNativeRoom(roomID: room.id, cancelID: "explicit-stop")

        #expect(client.stopped.count == 1)
        #expect(client.stopped.first?.roomID == room.id)
        #expect(client.stopped.first?.cancelID == "explicit-stop")
        #expect(store.room(id: room.id)?.isRunning == false)
        #expect(store.room(id: room.id)?.nativePendingEventID == nil)
    }

    @Test func nativeApprovalIsOwnerBoundAndReadBackAfterExactDecision() async throws {
        let room = BotModeRoom.fixture(id: "native-approval", memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.driverStatus = approvalFixtureStatus()
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        try await store.syncNativeRoom(roomID: room.id)
        let approval = try #require(store.pendingApprovals(roomID: room.id).first)
        #expect(approval.command == "rm -rf /tmp/example")

        client.driverStatusAfterApproval = nil
        let receipt = try await store.resolveNativeApproval(
            roomID: room.id,
            approval: approval,
            choice: .once
        )

        #expect(receipt.approved)
        #expect(client.approvals.count == 1)
        #expect(client.approvals.first?.roomID == room.id)
        #expect(client.approvals.first?.memberID == "finance")
        #expect(client.approvals.first?.taskID == "task-1")
        #expect(client.approvals.first?.executionGeneration == 1)
        #expect(client.approvals.first?.requestID == "request-1")
        #expect(client.approvals.first?.choice == .once)
        #expect(store.pendingApprovals(roomID: room.id).isEmpty)
        #expect(client.stateCallCount >= 3)
    }

    @Test func nativeStateRetryActionPromotesMatchingPersistedFailureWithoutInventingIdentity() async throws {
        let source = BotModeRoom.fixture(id: "native-state-retry", memberIDs: ["finance", "research"])
        let existingFailure = BotModeMemberFailure(
            memberID: "finance",
            message: "The hosted task is uncertain.",
            taskID: "task-1",
            status: "failed",
            discussionEventID: "discussion-1",
            threadID: "thread-1",
            turnID: "turn-1",
            executionGeneration: 3
        )
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            memberFailures: [existingFailure],
            nativeRoomID: source.id,
            nativeAuthorityGatewayID: "gateway",
            nativeAuthorityEpoch: 1
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.driverStatus = retryFixtureStatus(taskID: "task-1")
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        try await store.syncNativeRoom(roomID: room.id)

        let failure = try #require(store.room(id: room.id)?.memberFailures.first)
        #expect(failure.memberID == "finance")
        #expect(failure.taskID == "task-1")
        #expect(failure.executionGeneration == 3)
        #expect(["indeterminate", "deferred"].contains(failure.status))
    }

    @Test func nativeStateOnlyRetryActionIsRetryableWithoutInventingMemberFailure() async throws {
        let source = BotModeRoom.fixture(id: "native-state-only-retry", memberIDs: ["finance", "research"])
        let discussion = BotModeEvent.human(text: "Retry the interrupted task", id: "discussion", sourceOrder: 1)
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            visibleEvents: [source.visibleEvents[0], discussion],
            nativeRoomID: source.id,
            nativeAuthorityGatewayID: "gateway",
            nativeAuthorityEpoch: 1
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.driverStatus = retryFixtureStatus(taskID: "task-only")
        client.driverStatusAfterRetry = nil
        client.retryResult = HermesBotModeRetryResult(
            retried: true,
            task: HermesBotModeTaskReceipt(
                roomID: room.id,
                taskID: "task-only",
                threadID: "thread-only",
                turnID: "turn-only",
                status: "queued",
                executionGeneration: 1,
                cancelGeneration: 0
            )
        )
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        try await store.syncNativeRoom(roomID: room.id)
        #expect(store.pendingNativeRetryTaskIDs(roomID: room.id) == ["task-only"])
        #expect(store.room(id: room.id)?.memberFailures.isEmpty == true)

        client.logPages = [[
            .fixture(roomID: room.id, sequence: 1, eventID: "settled", kind: "turn.settled", payload: [
                "discussion_event_id": .string(discussion.id),
                "thread_id": .string("thread-only"),
                "task_id": .string("task-only"),
                "turn_id": .string("turn-only"),
                "execution_generation": .integer(1),
            ]),
            .fixture(roomID: room.id, sequence: 2, eventID: "activity", kind: "room.activity", payload: [
                "status": .string("settled"),
                "discussion_event_id": .string(discussion.id),
                "thread_id": .string("thread-only"),
                "task_id": .string("task-only"),
                "turn_id": .string("turn-only"),
                "execution_generation": .integer(1),
            ]),
        ]]

        let retry = Task { try await store.retry(roomID: room.id) }
        let deadline = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            retry.cancel()
        }
        defer { deadline.cancel() }
        try await retry.value

        #expect(store.room(id: room.id)?.memberFailures.isEmpty == true)
        #expect(store.room(id: room.id)?.isRunning == false)
    }

    @Test func nativeRetryTransportFailurePreservesUnattemptedFailures() async throws {
        let source = BotModeRoom.fixture(id: "native-partial-retry", memberIDs: ["finance", "research"])
        let failures = [
            BotModeMemberFailure(memberID: "finance", message: "uncertain", taskID: "task-1", status: "deferred", executionGeneration: 1),
            BotModeMemberFailure(memberID: "research", message: "indeterminate", taskID: "task-2", status: "indeterminate", executionGeneration: 2),
        ]
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            memberFailures: failures,
            nativeRoomID: source.id,
            nativeAuthorityGatewayID: "gateway",
            nativeAuthorityEpoch: 1
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.retryResults = [
            .success(HermesBotModeRetryResult(
                retried: true,
                task: HermesBotModeTaskReceipt(
                    roomID: room.id, taskID: "task-1", threadID: "thread-1", turnID: "turn-1",
                    status: "queued", executionGeneration: 1, cancelGeneration: 0
                )
            )),
            .failure(NativeBotModeTestError.transport),
        ]
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        await #expect(throws: NativeBotModeTestError.transport) {
            try await store.retry(roomID: room.id)
        }

        #expect(store.room(id: room.id)?.memberFailures.compactMap(\.taskID) == ["task-1", "task-2"])
        #expect(store.room(id: room.id)?.memberFailures.compactMap(\.executionGeneration) == [1, 2])
    }

    @Test func recreatedStoreRecoversAcceptedSendWithOriginalIdempotencyKey() async throws {
        let directory = try botModeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[BotModeRoom]>(
            directory: directory, name: "bot-rooms", seed: [],
            migrations: BotModeRoomCacheSchema.migrations,
            currentSchemaVersion: BotModeRoomCacheSchema.currentVersion
        )
        let room = BotModeRoom.fixture(id: "native-lost-receipt", memberIDs: ["finance", "research"])
        try repository.save([room])

        let firstClient = NativeBotModeTestClient(capabilities: .fixture())
        // Keep the first store's recovery observer from consuming the
        // accepted receipt before the simulated relaunch boundary. The
        // second store must be the first caller to receive that canonical ID.
        firstClient.acceptedResponseLostRemaining = .max
        configureNativeReply(firstClient, roomID: room.id, text: "Lost receipt")
        let firstStore = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: firstClient)
        try firstStore.load()

        await #expect(throws: NativeBotModeTestError.transport) {
            try await firstStore.send(text: "Lost receipt", roomID: room.id)
        }
        let originalEventID = try #require(firstClient.sentEventIDs.first)
        firstStore.invalidateNativeExecutionBoundary()

        let secondClient = NativeBotModeTestClient(capabilities: .fixture())
        configureNativeReply(secondClient, roomID: room.id, text: "Lost receipt")
        let secondStore = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: secondClient)
        try secondStore.load()
        secondStore.beginNativeRoomObservation(roomID: room.id)

        for _ in 0..<60 {
            if secondStore.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Recovered after relaunch" }) == true {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(secondClient.sentEventIDs == [originalEventID])
        #expect(secondStore.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Recovered after relaunch" }) == true)
        #expect(secondStore.room(id: room.id)?.nativePendingEventID == nil)
    }

    @Test func concurrentNativeReceiptRecoveryConvergesOnOneCanonicalDiscussion() async throws {
        let source = BotModeRoom.fixture(id: "native-overlapping-receipt", memberIDs: ["finance", "research"])
        let remoteState = HermesBotModeRoomState(
            roomID: source.id,
            name: "Bot Mode",
            members: source.members.map(HermesBotModeRoomMember.init(member:)),
            authorityGatewayID: "gateway",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 0,
            latestSequence: 2,
            disbandedAt: nil,
            driverStatus: ["working": .boolean(false)]
        )
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            nativeRoomID: source.id,
            nativeAuthorityGatewayID: "gateway",
            nativeAuthorityEpoch: 1,
            nativePendingEventID: "client-event",
            nativePendingThreadID: "thread",
            nativePendingText: "Pending message",
            nativeState: remoteState
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.stateResponse = remoteState
        client.logPages = [[
            .fixture(roomID: room.id, sequence: 1, eventID: "member-event", kind: "message.member", payload: [
                "discussion_event_id": .string("server-client-event"),
                "member_id": .string("finance"),
                "thread_id": .string("thread"),
                "text": .string("Completed before the second receipt")
            ]),
            .fixture(roomID: room.id, sequence: 2, eventID: "activity", kind: "room.activity", payload: [
                "discussion_event_id": .string("server-client-event"),
                "thread_id": .string("thread"),
                "status": .string("settled")
            ])
        ]]
        client.blockGroupsSend = true
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        let first = Task { try await store.syncNativeRoom(roomID: room.id) }
        await client.waitUntilGroupsSendStarts(count: 1)
        let second = Task { try await store.syncNativeRoom(roomID: room.id) }
        await client.waitUntilGroupsSendStarts(count: 2)
        client.releaseNextBlockedGroupsSend()
        for _ in 0..<100 where store.room(id: room.id)?.nativePendingEventID != nil {
            await Task.yield()
        }
        client.releaseBlockedGroupsSend()

        var failures = 0
        do { try await first.value } catch { failures += 1 }
        do { try await second.value } catch { failures += 1 }

        #expect(failures == 0)
        #expect(store.room(id: room.id)?.nativePendingDiscussionEventID == nil)
        #expect(client.sentEventIDs == ["client-event", "client-event"])
    }

    @Test func concurrentOpenAndObservationDoNotSurfaceRevisionConflict() async throws {
        let source = BotModeRoom.fixture(id: "native-overlapping-open", memberIDs: ["finance", "research"])
        let remoteState = HermesBotModeRoomState(
            roomID: source.id,
            name: "Bot Mode",
            members: source.members.map(HermesBotModeRoomMember.init(member:)),
            authorityGatewayID: "gateway",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 0,
            latestSequence: 0,
            disbandedAt: nil,
            driverStatus: ["working": .boolean(false)]
        )
        // The room is known locally, but its native metadata has not yet been
        // persisted. This makes both sync callers attempt the same metadata
        // CAS after they capture the original revision.
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            visibleEvents: source.visibleEvents,
            nativeRoomID: source.id
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.stateResponse = remoteState
        client.blockGroupsState = true
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        let opening = Task { try await store.openNativeRoom(roomID: room.id) }
        await client.waitUntilGroupsStateStarts(count: 1)
        let observing = Task { try await store.syncNativeRoom(roomID: room.id) }
        await client.waitUntilGroupsStateStarts(count: 2)

        // openNativeRoom persists the refreshed metadata before its supplied
        // state replay. The observer has already captured the old revision;
        // its later metadata CAS currently reports persistenceConflict.
        client.releaseNextBlockedGroupsState()
        let opened = try? await opening.value
        client.releaseNextBlockedGroupsState()
        let observed = try? await observing.value

        #expect(opened?.id == room.id)
        #expect(observed != nil)
    }

    @Test func staleConcurrentObservationCannotRegressNativeMetadataRevision() async throws {
        let source = BotModeRoom.fixture(id: "native-overlapping-open-revision", memberIDs: ["finance", "research"])
        let newerState = HermesBotModeRoomState(
            roomID: source.id,
            name: "Newer room name",
            members: source.members.map(HermesBotModeRoomMember.init(member:)),
            authorityGatewayID: "gateway",
            authorityEpoch: 1,
            revision: 2,
            createdAt: 0,
            updatedAt: 2,
            latestSequence: 0,
            disbandedAt: nil,
            driverStatus: ["working": .boolean(false)]
        )
        let staleState = HermesBotModeRoomState(
            roomID: source.id,
            name: "Older room name",
            members: source.members.map(HermesBotModeRoomMember.init(member:)),
            authorityGatewayID: "gateway",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 1,
            latestSequence: 0,
            disbandedAt: nil,
            driverStatus: ["working": .boolean(false)]
        )
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            visibleEvents: source.visibleEvents,
            nativeRoomID: source.id
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.stateResponses = [newerState, staleState]
        client.blockGroupsState = true
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        let opening = Task { try await store.openNativeRoom(roomID: room.id) }
        await client.waitUntilGroupsStateStarts(count: 1)
        let observing = Task { try await store.syncNativeRoom(roomID: room.id) }
        await client.waitUntilGroupsStateStarts(count: 2)

        client.releaseNextBlockedGroupsState()
        _ = try? await opening.value
        client.releaseNextBlockedGroupsState()
        let observed = try? await observing.value

        #expect(observed != nil)
        #expect(store.room(id: room.id)?.nativeState?.revision == newerState.revision)
        #expect(store.room(id: room.id)?.nativeState?.name == newerState.name)
    }

    @Test func rebindingNativeClientRestartsObservationForInterruptedRun() async throws {
        let source = BotModeRoom.fixture(id: "native-foreground-recovery", memberIDs: ["finance", "research"])
        let remoteState = HermesBotModeRoomState(
            roomID: source.id,
            name: "Bot Mode",
            members: source.members.map(HermesBotModeRoomMember.init(member:)),
            authorityGatewayID: "gateway",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 0,
            latestSequence: 2,
            disbandedAt: nil,
            driverStatus: ["working": .boolean(false)]
        )
        let owner = BotModeRunOwner(instanceID: "interrupted", generation: 1)
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            isRunning: true,
            runOwner: owner,
            nativeRoomID: source.id,
            nativeLogCursor: 0,
            nativeAuthorityGatewayID: "gateway",
            nativeAuthorityEpoch: 1,
            nativePendingEventID: "client-event",
            nativePendingThreadID: "thread",
            nativePendingText: "Pending message",
            nativePendingDiscussionEventID: "server-client-event",
            nativeState: remoteState
        )
        let oldClient = NativeBotModeTestClient(capabilities: .fixture())
        let newClient = NativeBotModeTestClient(capabilities: .fixture())
        newClient.stateResponse = remoteState
        newClient.logPages = [[
            .fixture(roomID: room.id, sequence: 1, eventID: "member-event", kind: "message.member", payload: [
                "discussion_event_id": .string("server-client-event"),
                "member_id": .string("finance"),
                "thread_id": .string("thread"),
                "text": .string("Recovered after foreground")
            ]),
            .fixture(roomID: room.id, sequence: 2, eventID: "activity", kind: "room.activity", payload: [
                "discussion_event_id": .string("server-client-event"),
                "thread_id": .string("thread"),
                "status": .string("settled")
            ])
        ]]
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: oldClient)

        store.configureNativeClient(newClient)
        for _ in 0..<100 {
            if store.room(id: room.id)?.isRunning == false { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(newClient.loggedSinceSequences == [0])
        #expect(store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Recovered after foreground" }) == true)
        #expect(store.room(id: room.id)?.isRunning == false)
        #expect(store.room(id: room.id)?.nativePendingEventID == nil)
    }

    @Test func cancellingNativeSenderLeavesDurableWorkRunningWithoutGroupsStop() async throws {
        let room = BotModeRoom.fixture(id: "native-cancel", memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        let sending = Task { @MainActor in
            try await store.send(text: "Keep working", roomID: room.id)
        }
        await client.waitUntilSendStarts()
        sending.cancel()
        _ = try? await sending.value

        #expect(client.stopped.isEmpty)
        #expect(store.room(id: room.id)?.isRunning == true)
        #expect(store.room(id: room.id)?.nativePendingEventID != nil)
    }

    @Test func staleNativeBoundaryCannotPublishReceiptOrCompletion() async throws {
        let room = BotModeRoom.fixture(id: "native-stale", memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)
        client.onSend = { store.invalidateNativeExecutionBoundary() }

        await #expect(throws: CancellationError.self) {
            try await store.send(text: "Old host", roomID: room.id)
        }

        #expect(store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Old host" }) == false)
        #expect(store.room(id: room.id)?.isRunning == true)
        #expect(client.stopped.isEmpty)
    }

    @Test func uncertainNativeSendRetriesWithTheSameClientEventID() async throws {
        let room = BotModeRoom.fixture(id: "native-retry-id", memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.sendFailuresRemaining = 1
        // The sender's defer starts a recovery observer after the transport
        // error. Hold its first state read so the explicit retry below owns
        // the original idempotency key deterministically.
        client.stateFailuresRemaining = 1
        client.logPages = [[]]
        client.onSend = {
            client.logPages = [[
                .fixture(roomID: room.id, sequence: 1, eventID: "user-event", kind: "message.user", payload: [
                    "text": .string("Retry me"), "thread_id": .string("thread")
                ]),
                .fixture(roomID: room.id, sequence: 2, eventID: "member-event", kind: "message.member", payload: [
                    "member_id": .string("finance"), "text": .string("Recovered answer")
                ]),
                .fixture(roomID: room.id, sequence: 3, eventID: "activity", kind: "room.activity", payload: [
                    "status": .string("settled"), "discussion_event_id": .string("pending")
                ])
            ]]
        }
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        await #expect(throws: NativeBotModeTestError.transport) {
            try await store.send(text: "Retry me", roomID: room.id)
        }
        for _ in 0..<50 where client.stateCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let pendingID = try #require(store.room(id: room.id)?.nativePendingEventID)
        try await store.send(text: "Retry me", roomID: room.id)

        #expect(client.sentEventIDs == [pendingID, pendingID])
        #expect(store.room(id: room.id)?.isRunning == false)
        #expect(store.room(id: room.id)?.nativePendingEventID == nil)
    }

    @Test func nativeReceiptTransportFailureIsRecoveredByStoreObserver() async throws {
        let room = BotModeRoom.fixture(id: "native-receipt-recovery", memberIDs: ["finance", "research"])
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.logFailuresRemaining = 1
        client.onSend = {
            client.logPages = [[
                .fixture(roomID: room.id, sequence: 1, eventID: "user-event", kind: "message.user", payload: [
                    "text": .string("Recover this"), "thread_id": .string("thread")
                ]),
                .fixture(roomID: room.id, sequence: 2, eventID: "member-event", kind: "message.member", payload: [
                    "member_id": .string("finance"), "text": .string("Recovered answer")
                ]),
                .fixture(roomID: room.id, sequence: 3, eventID: "activity", kind: "room.activity", payload: [
                    "status": .string("settled")
                ])
            ]]
        }
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        await #expect(throws: NativeBotModeTestError.transport) {
            try await store.send(text: "Recover this", roomID: room.id)
        }
        #expect(client.returnedServerEventIDs.count == 1)

        for _ in 0..<30 {
            if store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Recovered answer" }) == true {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Recovered answer" }) == true)
        #expect(store.room(id: room.id)?.nativePendingEventID == nil)
    }

    @Test func nativeSyncReplaysEveryLogPageAndSettlesRecoveredPendingWork() async throws {
        let source = BotModeRoom.fixture(id: "native-pages", memberIDs: ["finance", "research"])
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            visibleEvents: source.visibleEvents,
            nativeRoomID: source.id,
            nativePendingEventID: "client-event",
            nativePendingDiscussionEventID: "server-event"
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.logPages = [[
            .fixture(roomID: room.id, sequence: 1, eventID: "user-event", kind: "message.user", payload: [
                "text": .string("Recovered"), "thread_id": .string("thread")
            ])], [
            .fixture(roomID: room.id, sequence: 2, eventID: "activity", kind: "room.activity", payload: [
                "status": .string("settled"), "discussion_event_id": .string("server-event")
            ])
        ]]
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        try await store.syncNativeRoom(roomID: room.id)

        #expect(client.loggedSinceSequences == [0, 1])
        #expect(store.room(id: room.id)?.nativeLogCursor == 2)
        #expect(store.room(id: room.id)?.visibleEvents.contains(where: { $0.text == "Recovered" }) == true)
        #expect(store.room(id: room.id)?.nativePendingEventID == nil)
    }

    @Test func nativeRetryRejectsReceiptForAnotherTask() async throws {
        let source = BotModeRoom.fixture(id: "native-retry-receipt", memberIDs: ["finance", "research"])
        let discussion = BotModeEvent.human(text: "Retry this", id: "discussion", sourceOrder: 1)
        let room = try BotModeRoom(
            id: source.id,
            members: source.members,
            visibleEvents: [source.visibleEvents[0], discussion],
            memberFailures: [BotModeMemberFailure(
                memberID: "finance",
                message: "The turn was deferred.",
                taskID: "task-1",
                status: "deferred",
                discussionEventID: discussion.id,
                threadID: "thread-1",
                turnID: "turn-1",
                executionGeneration: 1
            )],
            nativeRoomID: source.id,
            nativeAuthorityGatewayID: "gateway",
            nativeAuthorityEpoch: 1,
            nativePendingThreadID: "thread-1"
        )
        let client = NativeBotModeTestClient(capabilities: .fixture())
        client.retryResult = HermesBotModeRetryResult(
            retried: true,
            task: HermesBotModeTaskReceipt(
                roomID: room.id,
                taskID: "different-task",
                threadID: "thread-1",
                turnID: "turn-1",
                status: "queued",
                executionGeneration: 2,
                cancelGeneration: 0
            )
        )
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: client)

        await #expect(throws: BotModeRoomError.nativeRetryRejected) {
            try await store.retry(roomID: room.id)
        }

        #expect(store.room(id: room.id)?.isRunning == false)
    }

    @Test func decodingRejectsDuplicateMemberIDs() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance"])
        var payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any]
        )
        var members = try #require(payload["members"] as? [[String: Any]])
        members.append(try #require(members.first))
        payload["members"] = members
        let data = try JSONSerialization.data(withJSONObject: payload)

        #expect(throws: BotModeRoomError.invalidMember) {
            try JSONDecoder().decode(BotModeRoom.self, from: data)
        }
    }

    @Test func decodingRejectsRoomsAboveMemberCapacity() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance"])
        var payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any]
        )
        var members = try #require(payload["members"] as? [[String: Any]])
        let template = try #require(members.first)
        for index in 2...7 {
            var member = template
            member["profileID"] = "member-\(index)"
            member["handle"] = "member-\(index)"
            member["sessionID"] = "hidden-member-\(index)"
            members.append(member)
        }
        payload["members"] = members
        let data = try JSONSerialization.data(withJSONObject: payload)

        #expect(throws: BotModeRoomError.invalidMember) {
            try JSONDecoder().decode(BotModeRoom.self, from: data)
        }
    }

    @Test func decodingQuarantinesInconsistentRunState() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance"])
        var payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any]
        )
        payload["isRunning"] = true
        payload.removeValue(forKey: "runOwner")

        let missingOwner = try JSONDecoder().decode(
            BotModeRoom.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        #expect(missingOwner.isRunning == false)
        #expect(missingOwner.runOwner == nil)

        payload["isRunning"] = false
        payload["runOwner"] = ["instanceID": "persisted", "generation": 1]
        let unexpectedOwner = try JSONDecoder().decode(
            BotModeRoom.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        #expect(unexpectedOwner.isRunning == false)
        #expect(unexpectedOwner.runOwner == nil)
    }

    @Test func decodingDefaultsMissingOptionalPersistedFields() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance"])
        var payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any]
        )
        for key in [
            "directSessionID",
            "privateHistory",
            "visibleEvents",
            "memberContexts",
            "retiredHandles",
            "memberFailures",
            "isRunning",
            "runOwner",
            "persistenceRevision"
        ] {
            payload.removeValue(forKey: key)
        }

        let decoded = try JSONDecoder().decode(
            BotModeRoom.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )

        #expect(decoded.id == room.id)
        #expect(decoded.memberIDs == ["finance"])
        #expect(decoded.privateHistory.isEmpty)
        #expect(decoded.visibleEvents.map(\.kind) == [.botModeStarted])
        #expect(decoded.memberContexts["finance"]?.sessionID == "hidden-finance")
        #expect(decoded.memberFailures.isEmpty)
        #expect(decoded.isRunning == false)
        #expect(decoded.runOwner == nil)
        #expect(decoded.persistenceRevision == 0)
    }
}

enum NativeBotModeTestError: Error, Equatable {
    case transport
    case timedOut
}

@MainActor
final class NativeBotModeTestClient: HermesBotModeClient, HermesBotModeApprovalClient {
    var capabilities: HermesBotModeCapabilities
    var createdRoomIDs: [String] = []
    var sentRoomIDs: [String] = []
    var sentEventIDs: [String] = []
    private(set) var returnedServerEventIDs: [String] = []
    var sentPayloads: [HermesBotModeUserPayload] = []
    var logPages: [[HermesBotModeEvent]] = []
    var loggedSinceSequences: [Int] = []
    var loggedLimits: [Int] = []
    var stateLatestSequence: Int = 0
    var stateResponse: HermesBotModeRoomState?
    var stateResponses: [HermesBotModeRoomState] = []
    var blockGroupsState = false
    private var blockedGroupsStateContinuations: [CheckedContinuation<Void, Never>] = []
    var driverStatus: [String: BighelpJSONValue]?
    var driverStatusAfterApproval: [String: BighelpJSONValue]?
    private(set) var stateCallCount = 0
    var sendFailuresRemaining = 0
    var stateFailuresRemaining = 0
    var acceptedResponseLostRemaining = 0
    var blockGroupsSend = false
    private var blockedGroupsSendContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var groupsSendStartedCount = 0
    var logFailuresRemaining = 0
    var retryResult: HermesBotModeRetryResult?
    var retryResults: [Result<HermesBotModeRetryResult, Error>] = []
    var driverStatusAfterRetry: [String: BighelpJSONValue]?
    var onSend: (() -> Void)?
    private(set) var stopped: [(roomID: String, cancelID: String)] = []
    private(set) var approvals: [(
        roomID: String,
        memberID: String,
        taskID: String,
        executionGeneration: Int,
        requestID: String,
        choice: HermesBotModeApprovalChoice
    )] = []
    var logAuthorityGatewayID = "gateway"
    var logAuthorityEpoch = 1

    init(capabilities: HermesBotModeCapabilities) {
        self.capabilities = capabilities
    }

    func groupsCapabilities() async throws -> HermesBotModeCapabilities { capabilities }

    func groupsCreate(
        roomID: String,
        name _: String,
        members _: [HermesBotModeRoomMember]
    ) async throws -> HermesBotModeRoomState {
        createdRoomIDs.append(roomID)
        return .fixture(roomID: roomID, latestSequence: 0)
    }

    func groupsState(roomID: String, includeDisbanded _: Bool) async throws -> HermesBotModeRoomState {
        stateCallCount += 1
        if blockGroupsState {
            await withCheckedContinuation { continuation in
                blockedGroupsStateContinuations.append(continuation)
            }
        }
        if stateFailuresRemaining > 0 {
            stateFailuresRemaining -= 1
            throw NativeBotModeTestError.transport
        }
        if !stateResponses.isEmpty {
            return stateResponses.removeFirst()
        }
        return stateResponse ?? .fixture(roomID: roomID, latestSequence: stateLatestSequence, driverStatus: driverStatus)
    }

    func groupsSend(
        roomID: String,
        eventID: String,
        payload: HermesBotModeUserPayload
    ) async throws -> HermesBotModeSendResult {
        sentRoomIDs.append(roomID)
        sentEventIDs.append(eventID)
        sentPayloads.append(payload)
        groupsSendStartedCount += 1
        if blockGroupsSend {
            await withCheckedContinuation { continuation in
                blockedGroupsSendContinuations.append(continuation)
            }
        }
        if sendFailuresRemaining > 0 {
            sendFailuresRemaining -= 1
            throw NativeBotModeTestError.transport
        }
        onSend?()
        let serverEventID = "server-\(eventID)"
        returnedServerEventIDs.append(serverEventID)
        let payloadThreadID = payload.threadID
        logPages = logPages.map { events in
            events.map { event in
                var payload = event.payload
                if ["message.member", "turn.failed", "turn.deferred", "turn.cancelled", "room.activity"].contains(event.kind) {
                    payload["discussion_event_id"] = .string(serverEventID)
                    payload["thread_id"] = .string(payload["thread_id"]?.string ?? payloadThreadID)
                }
                return HermesBotModeEvent(
                    roomID: event.roomID,
                    sequence: event.sequence,
                    eventID: event.eventID,
                    kind: event.kind,
                    actor: event.actor,
                    authorityEpoch: event.authorityEpoch,
                    payload: payload,
                    createdAt: event.createdAt
                )
            }
        }
        if acceptedResponseLostRemaining > 0 {
            acceptedResponseLostRemaining -= 1
            throw NativeBotModeTestError.transport
        }
        return HermesBotModeSendResult(
            event: .fixture(roomID: roomID, sequence: 1, eventID: serverEventID, kind: "message.user", payload: [
                "text": .string(payload.text), "thread_id": .string(payload.threadID)
            ]),
            clientEventID: eventID,
            accepted: true,
            driverStarted: true
        )
    }

    func groupsLog(
        roomID _: String,
        sinceSequence: Int,
        limit: Int,
        includeDisbanded _: Bool
    ) async throws -> HermesBotModeLogPage {
        loggedSinceSequences.append(sinceSequence)
        loggedLimits.append(limit)
        if logFailuresRemaining > 0 {
            logFailuresRemaining -= 1
            throw NativeBotModeTestError.transport
        }
        let events = logPages.isEmpty ? [] : logPages.removeFirst()
        return HermesBotModeLogPage(
            events: events,
            cursor: events.last?.sequence ?? sinceSequence,
            latestSequence: max(stateLatestSequence, events.last?.sequence ?? sinceSequence),
            hasMore: !logPages.isEmpty,
            authority: .init(gatewayID: logAuthorityGatewayID, epoch: logAuthorityEpoch)
        )
    }

    func groupsStop(roomID: String, cancelID: String) async throws {
        stopped.append((roomID: roomID, cancelID: cancelID))
    }

    func waitUntilSendStarts() async {
        while sentEventIDs.isEmpty { await Task.yield() }
    }

    func waitUntilGroupsSendStarts(count: Int) async {
        while groupsSendStartedCount < count { await Task.yield() }
    }

    func waitUntilGroupsStateStarts(count: Int) async {
        while stateCallCount < count { await Task.yield() }
    }

    func releaseNextBlockedGroupsState() {
        guard !blockedGroupsStateContinuations.isEmpty else { return }
        blockedGroupsStateContinuations.removeFirst().resume()
    }

    func releaseNextBlockedGroupsSend() {
        guard !blockedGroupsSendContinuations.isEmpty else { return }
        blockedGroupsSendContinuations.removeFirst().resume()
    }

    func releaseBlockedGroupsSend() {
        blockGroupsSend = false
        let continuations = blockedGroupsSendContinuations
        blockedGroupsSendContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func groupsRetry(roomID _: String, taskID _: String) async throws -> HermesBotModeRetryResult {
        if !retryResults.isEmpty {
            let result = try retryResults.removeFirst().get()
            driverStatus = driverStatusAfterRetry
            return result
        }
        guard let retryResult else { fatalError("unused by native Bot Mode store tests") }
        driverStatus = driverStatusAfterRetry
        return retryResult
    }

    func groupsApprove(
        roomID: String,
        memberID: String,
        taskID: String,
        executionGeneration: Int,
        requestID: String,
        choice: HermesBotModeApprovalChoice
    ) async throws -> HermesBotModeApprovalReceipt {
        approvals.append((roomID, memberID, taskID, executionGeneration, requestID, choice))
        driverStatus = driverStatusAfterApproval
        return HermesBotModeApprovalReceipt(approved: true, result: [:])
    }
}

extension HermesBotModeCapabilities {
    static func fixture(driver: Bool = true, maxLogLimit: Int = 500) -> Self {
        Self(
            protocolVersion: 2,
            driver: driver,
            persistentProcess: false,
            authorityGatewayID: "gateway",
            roomLink: [:],
            features: Self.requiredFeatures,
            methods: Self.requiredOperations,
            maxLogLimit: maxLogLimit
        )
    }
}

extension HermesBotModeRoomState {
    static func fixture(
        roomID: String,
        latestSequence: Int? = nil,
        driverStatus: [String: BighelpJSONValue]? = nil
    ) -> Self {
        Self(
            roomID: roomID,
            name: "Bot Mode",
            members: [],
            authorityGatewayID: "gateway",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 0,
            latestSequence: latestSequence,
            disbandedAt: nil,
            driverStatus: driverStatus
        )
    }
}

private func approvalFixtureStatus() -> [String: BighelpJSONValue] {
    [
        "pending_actions": .array([.object([
            "kind": .string("approval"),
            "member_id": .string("finance"),
            "task_id": .string("task-1"),
            "execution_generation": .integer(1),
            "request_id": .string("request-1"),
            "approval": .object([
                "request_id": .string("request-1"),
                "command": .string("rm -rf /tmp/example"),
                "description": .string("Remove the generated example files."),
                "choices": .array([.string("once"), .string("deny")]),
            ]),
        ])]),
    ]
}

private func retryFixtureStatus(taskID: String) -> [String: BighelpJSONValue] {
    [
        "pending_actions": .array([.object([
            "kind": .string("retry"),
            "task_id": .string(taskID),
        ])]),
    ]
}

@MainActor
private func configureNativeReply(
    _ client: NativeBotModeTestClient,
    roomID: String,
    text: String
) {
    client.onSend = {
        guard client.logPages.isEmpty else { return }
        client.logPages = [[
            .fixture(roomID: roomID, sequence: 1, eventID: "user-event", kind: "message.user", payload: [
                "text": .string(text), "thread_id": .string("loopdy-\(roomID)")
            ]),
            .fixture(roomID: roomID, sequence: 2, eventID: "member-event", kind: "message.member", payload: [
                "member_id": .string("finance"), "text": .string("Recovered after relaunch")
            ]),
            .fixture(roomID: roomID, sequence: 3, eventID: "activity", kind: "room.activity", payload: [
                "status": .string("settled")
            ]),
        ]]
    }
}

extension HermesBotModeEvent {
    static func fixture(
        roomID: String,
        sequence: Int,
        eventID: String,
        kind: String,
        payload: [String: BighelpJSONValue]
    ) -> Self {
        Self(
            roomID: roomID,
            sequence: sequence,
            eventID: eventID,
            kind: kind,
            actor: [:],
            authorityEpoch: 1,
            payload: payload,
            createdAt: 0
        )
    }
}

private extension SessionRecord {
    static let directFixture = SessionRecord(
        id: "direct-finance",
        kind: .direct,
        agentIDs: ["finance"],
        title: "Finance",
        items: [
            TimelineItem(
                id: "private-human",
                role: .human,
                sender: .user(snapshot: .init(name: "You")),
                content: .message("Private finance history"),
                metadata: .init(delivery: "Sent")
            )
        ]
    )
}

private func botModeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BighelpBotModeTests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
