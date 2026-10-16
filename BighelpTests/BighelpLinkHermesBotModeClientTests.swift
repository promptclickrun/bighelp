import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpLinkHermesBotModeClientTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BIGHELP_REAL_GROUP_CAPTURE"] != nil,
                   "Requires an authorized captured real-host group response."))
    func capturedRealHostRoomOpensThroughProductionCodecAndStore() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BIGHELP_REAL_GROUP_CAPTURE"])
        let capture = try JSONDecoder().decode([String: BighelpJSONValue].self,
                                              from: Data(contentsOf: URL(fileURLWithPath: path)))
        let owner = BighelpLinkHermesBotModeOwner(accountID: "capture", hostID: "host", connectionID: "direct")
        let state = try #require(capture["state"]?.object)
        let roomID = try #require(state["room"]?.object?["room_id"]?.string)
        let log = try #require(capture["log"]?.object)
        for raw in try #require(log["events"]?.array) {
            let event = try JSONDecoder().decode(HermesBotModeEvent.self, from: JSONEncoder().encode(raw))
            do { try HermesBotModeWireCodec.event(event) }
            catch { Issue.record("Captured event rejected: sequence \(event.sequence), kind \(event.kind)"); throw error }
        }
        let messaging = HermesBotModeMessagingStub { request in
            let payload: [String: BighelpJSONValue]
            switch request.operation {
            case .groupsCapabilities: payload = try #require(capture["capabilities"]?.object)
            case .groupsState: payload = state
            case .groupsLog:
                var page = log
                let since = request.payload["since_seq"]?.integer ?? 0
                page["events"] = .array((log["events"]?.array ?? []).filter { ($0.object?["seq"]?.integer ?? 0) > since })
                payload = page
            default: throw BighelpLinkWorkspaceClientError.invalidRequest
            }
            return try Self.result(for: request, payload: payload)
        }
        let client = BighelpLinkHermesBotModeClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging),
                                                  owner: owner, currentOwner: { owner })
        _ = try await client.groupsState(roomID: roomID, includeDisbanded: true)
        _ = try await client.groupsLog(roomID: roomID, sinceSequence: 0, limit: 500, includeDisbanded: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[BotModeRoom]>(directory: directory, name: BotModeRoomCacheSchema.repositoryName,
            seed: [], currentSchemaVersion: BotModeRoomCacheSchema.currentVersion)
        let store = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: client)
        let opened = try await store.openNativeRoom(roomID: roomID)
        #expect(opened.nativeLogCursor == log["cursor"]?.integer)
        #expect(!opened.visibleEvents.isEmpty)
        let restored = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: client)
        let reopened = try await restored.openNativeRoom(roomID: roomID)
        #expect(reopened.visibleEvents.map(\.id) == opened.visibleEvents.map(\.id))
    }

    @Test(arguments: ["valid", "wrong-room", "null-time", "history-expired", "owner-changed"])
    func disbandRequiresAnExactDurableTombstone(mode: String) async throws {
        let owner = BighelpLinkHermesBotModeOwner(accountID: "account", hostID: "host", connectionID: "connection")
        var current: BighelpLinkHermesBotModeOwner? = owner
        let messaging = HermesBotModeMessagingStub { request in
            if request.operation == .groupsDisband {
                #expect(request.payload == ["room_id": .string("group")])
                if mode == "owner-changed" { current = nil }
                return try Self.result(for: request, payload: ["tombstone": .object([
                    "room_id": .string(mode == "wrong-room" ? "other" : "group"),
                    "disbanded_at": mode == "null-time" ? .null : .number(1788000002),
                    "history_expired": .boolean(mode == "history-expired")
                ])])
            }
            #expect(request.operation == .groupsState)
            #expect(request.payload["include_disbanded"] == .boolean(true))
            var room = try #require(Self.room(roomID: "group").object)
            room["disbanded_at"] = .number(1788000002)
            return try Self.result(for: request, payload: ["room": .object(room)])
        }
        let client = BighelpLinkHermesBotModeClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging),
                                                  owner: owner, currentOwner: { current })
        if mode == "valid" || mode == "history-expired" {
            try await client.groupsDisband(roomID: "group")
            #expect(messaging.requests.count == (mode == "valid" ? 2 : 1))
        } else {
            await #expect(throws: (any Error).self) { try await client.groupsDisband(roomID: "group") }
            #expect(messaging.requests.count == 1)
        }
    }

    @Test
    func groupsClientUsesOfficialPayloadsAndTypedResponses() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let roomID = "room-1"
        let eventID = "event-1"
        let taskID = "task-1"
        let room = Self.room(roomID: roomID)
        let event = Self.event(roomID: roomID, eventID: eventID)
        var currentOwner: BighelpLinkHermesBotModeOwner? = owner
        let messaging = HermesBotModeMessagingStub { request in
            switch request.operation {
            case .groupsCapabilities:
                #expect(request.payload.isEmpty)
                return try Self.result(for: request, payload: Self.capabilities)
            case .groupsCreate:
                #expect(request.payload["room_id"] == .string(roomID))
                #expect(request.payload["name"] == .string("Household"))
                #expect(request.payload["members"]?.array?.count == 2)
                return try Self.result(for: request, payload: ["room": room])
            case .groupsState:
                #expect(request.payload == [
                    "room_id": .string(roomID),
                    "include_disbanded": .boolean(false),
                ])
                return try Self.result(for: request, payload: ["room": room])
            case .groupsSend:
                #expect(request.payload["room_id"] == .string(roomID))
                #expect(request.payload["event_id"] == .string(eventID))
                #expect(request.payload["payload"] == .object([
                    "text": .string("Hello"),
                    "thread_id": .string("thread-1"),
                ]))
                return try Self.result(for: request, payload: [
                    "event": event,
                    "client_event_id": .string(eventID),
                    "accepted": .boolean(true),
                    "driver_started": .boolean(true),
                ])
            case .groupsLog:
                #expect(request.payload == [
                    "room_id": .string(roomID),
                    "since_seq": .integer(0),
                    "limit": .integer(20),
                    "include_disbanded": .boolean(false),
                ])
                return try Self.result(for: request, payload: [
                    "events": .array([event]),
                    "cursor": .integer(1),
                    "latest_seq": .integer(1),
                    "has_more": .boolean(false),
                    "authority": .object([
                        "gateway_id": .string("gateway-1"),
                        "epoch": .integer(3),
                    ]),
                ])
            case .groupsStop:
                #expect(request.payload == [
                    "room_id": .string(roomID),
                    "cancel_id": .string("cancel-1"),
                ])
                return try Self.result(for: request, payload: ["cancelled": .integer(1)])
            case .groupsRetry:
                #expect(request.payload == [
                    "room_id": .string(roomID),
                    "task_id": .string(taskID),
                ])
                return try Self.result(for: request, payload: [
                    "retried": .boolean(true),
                    "task": .object([
                        "room_id": .string(roomID),
                        "task_id": .string(taskID),
                        "thread_id": .string("thread-1"),
                        "turn_id": .string("turn-1"),
                        "status": .string("queued"),
                        "execution_generation": .integer(2),
                        "cancel_generation": .integer(1),
                    ]),
                ])
            default:
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
        }
        let workspace = BighelpLinkWorkspaceClient(messaging: messaging)
        let client = BighelpLinkHermesBotModeClient(
            workspace: workspace,
            owner: owner,
            currentOwner: { currentOwner }
        )

        let capabilities = try await client.groupsCapabilities()
        #expect(capabilities.protocolVersion == 2)
        #expect(capabilities.supportsNativeExecution)
        let member = HermesBotModeRoomMember(member: BotModeMember(
            profileID: "default",
            handle: "Juno",
            sessionID: "session-1"
        ))
        let otherMember = HermesBotModeRoomMember(member: BotModeMember(
            profileID: "research", handle: "research", sessionID: "research-session"
        ))
        #expect(try await client.groupsCreate(roomID: roomID, name: "Household", members: [member, otherMember]).roomID == roomID)
        #expect(try await client.groupsState(roomID: roomID, includeDisbanded: false).name == "Household")
        #expect(try await client.groupsSend(
            roomID: roomID,
            eventID: eventID,
            payload: HermesBotModeUserPayload(text: "Hello", threadID: "thread-1")
        ).clientEventID == eventID)
        #expect(try await client.groupsLog(roomID: roomID, sinceSequence: 0, limit: 20, includeDisbanded: false).latestSequence == 1)
        try await client.groupsStop(roomID: roomID, cancelID: "cancel-1")
        #expect(try await client.groupsRetry(roomID: roomID, taskID: taskID).task.taskID == taskID)
        #expect(messaging.requests.map(\.operation) == [
            .groupsCapabilities, .groupsCreate, .groupsState, .groupsSend,
            .groupsLog, .groupsStop, .groupsRetry,
        ])
        currentOwner = nil
    }

    @Test
    func groupsClientDiscardsResultWhenAccountHostOrConnectionChangesDuringRequest() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        var currentOwner: BighelpLinkHermesBotModeOwner? = owner
        let messaging = HermesBotModeMessagingStub { request in
            currentOwner = BighelpLinkHermesBotModeOwner(
                accountID: "account-1",
                hostID: "host-2",
                connectionID: "connection-2"
            )
            return try Self.result(for: request, payload: ["cancelled": .integer(1)])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { currentOwner }
        )

        await #expect(throws: BighelpLinkHermesBotModeClientError.ownerChanged) {
            try await client.groupsStop(roomID: "room-1", cancelID: "cancel-1")
        }
    }

    @Test
    func groupsClientPreservesSendIdempotencyAndRejectsMismatchedReceipt() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = HermesBotModeMessagingStub { request in
            #expect(request.operation == .groupsSend)
            return try Self.result(for: request, payload: [
                "event": Self.event(roomID: "room-1", eventID: "server-event"),
                "client_event_id": .string("different-event"),
                "accepted": .boolean(true),
                "driver_started": .boolean(false),
            ])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsSend(
                roomID: "room-1",
                eventID: "client-event",
                payload: HermesBotModeUserPayload(text: "Retry safely", threadID: "thread-1")
            )
        }
        #expect(messaging.requests.first?.payload["event_id"] == .string("client-event"))
    }

    @Test(arguments: ["Hello", "Hello ", " Hello\r\n", "\u{00A0}Hello\u{3000}"])
    func groupsSendAcceptsHostNormalizedTextWithoutChangingRetryPayload(text: String) async throws {
        let workspace = try SessionWorkspaceStub()
        let owner = try #require(workspace.owner)
        let client = HermesHostedRoomClient(workspace: workspace, owner: owner)
        var sends = 0
        workspace.handler = { operation, payload in
            #expect(operation == .groupsSend)
            #expect(payload["event_id"] == .string("client-event"))
            #expect(payload["payload"]?.object?["text"] == .string(text))
            var event = try #require(Self.event(roomID: "room-1", eventID: "server-event").object)
            event["idempotent"] = .boolean(sends > 0)
            sends += 1
            return [
                "event": .object(event), "client_event_id": .string("client-event"),
                "accepted": .boolean(true), "driver_started": .boolean(true),
            ]
        }
        for _ in 0..<2 {
            let result = try await client.groupsSend(
                roomID: "room-1", eventID: "client-event",
                payload: .init(text: text, threadID: "thread-1")
            )
            #expect(result.event.text == "Hello")
            #expect(result.event.eventID == "server-event")
        }
        #expect(sends == 2)
    }

    @Test
    func hostTextNormalizationPreservesInteriorAndNonWhitespaceScalars() {
        #expect(HermesBotModeWireCodec.canonicalUserText("  First\n  second  ") == "First\n  second")
        #expect(HermesBotModeWireCodec.canonicalUserText(" \u{200B}Hello\u{200B} ") == "\u{200B}Hello\u{200B}")
        #expect(HermesBotModeWireCodec.canonicalUserText(" \u{FEFF}Hello\u{FEFF} ") == "\u{FEFF}Hello\u{FEFF}")
        let pythonWhitespace: [UInt32] = [
            0x9, 0xA, 0xB, 0xC, 0xD, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0,
            0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
            0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
        ]
        for value in pythonWhitespace {
            let whitespace = String(Unicode.Scalar(value)!)
            #expect(HermesBotModeWireCodec.canonicalUserText(whitespace + "Hello" + whitespace) == "Hello")
        }
    }

    @Test
    func groupsSendRejectsUnicodeEquivalentButByteChangedReceipt() async throws {
        let workspace = try SessionWorkspaceStub()
        let client = HermesHostedRoomClient(workspace: workspace, owner: try #require(workspace.owner))
        workspace.handler = { _, _ in
            [
                "event": Self.event(roomID: "room-1", eventID: "server-event", text: "caf\u{00E9}"),
                "client_event_id": .string("client-event"),
                "accepted": .boolean(true), "driver_started": .boolean(true),
            ]
        }
        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsSend(
                roomID: "room-1", eventID: "client-event",
                payload: .init(text: "cafe\u{0301}", threadID: "thread-1")
            )
        }
    }

    @Test(arguments: ["First\nsecond", "First\n  changed", "First\n  second "])
    func groupsSendRejectsChangesBeyondHostNormalization(returnedText: String) async throws {
        let workspace = try SessionWorkspaceStub()
        let client = HermesHostedRoomClient(workspace: workspace, owner: try #require(workspace.owner))
        workspace.handler = { _, _ in
            [
                "event": Self.event(roomID: "room-1", eventID: "server-event", text: returnedText),
                "client_event_id": .string("client-event"),
                "accepted": .boolean(true), "driver_started": .boolean(true),
            ]
        }
        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsSend(
                roomID: "room-1", eventID: "client-event",
                payload: .init(text: "  First\n  second  ", threadID: "thread-1")
            )
        }
    }

    @Test
    func pendingNativeSendRecoversNormalizedReceiptAndReopensWithoutDuplication() async throws {
        let workspace = try SessionWorkspaceStub()
        let client = HermesHostedRoomClient(workspace: workspace, owner: try #require(workspace.owner))
        var stateValue = try #require(Self.room(roomID: "room-1").object)
        stateValue["latest_seq"] = .integer(3)
        let state = try JSONDecoder().decode(HermesBotModeRoomState.self, from: JSONEncoder().encode(stateValue))
        let userEvent = Self.event(roomID: "room-1", eventID: "server-event")
        var reply = try #require(Self.event(
            roomID: "room-1", eventID: "reply", sequence: 2, kind: "message.member",
            text: "Recovered answer", actor: .object(["kind": .string("member"), "id": .string("default")])
        ).object)
        reply["payload"] = .object([
            "text": .string("Recovered answer"), "member_id": .string("default"),
            "discussion_event_id": .string("server-event"), "thread_id": .string("thread-1"),
        ])
        var terminal = try #require(Self.event(
            roomID: "room-1", eventID: "settled", sequence: 3, kind: "room.activity",
            actor: .object(["kind": .string("gateway"), "id": .string("gateway-1")])
        ).object)
        terminal["payload"] = .object([
            "status": .string("settled"), "discussion_event_id": .string("server-event"),
            "thread_id": .string("thread-1"),
        ])
        let events = [userEvent, .object(reply), .object(terminal)]
        let originalText = " Hello \r\n"
        workspace.handler = { operation, payload in
            switch operation {
            case .groupsCapabilities: return Self.capabilities
            case .groupsState: return ["room": .object(stateValue), "driver_status": .object(["working": .boolean(false)])]
            case .groupsSend:
                #expect(payload["event_id"] == .string("client-event"))
                #expect(payload["payload"]?.object?["text"] == .string(originalText))
                #expect(payload["payload"]?.object?["thread_id"] == .string("thread-1"))
                return [
                    "event": userEvent, "client_event_id": .string("client-event"),
                    "accepted": .boolean(true), "driver_started": .boolean(true),
                ]
            case .groupsLog:
                let since = payload["since_seq"]?.integer ?? 0
                return [
                    "events": .array(events.filter { ($0.object?["seq"]?.integer ?? 0) > since }),
                    "cursor": .integer(3), "latest_seq": .integer(3), "has_more": .boolean(false),
                    "authority": .object(["gateway_id": .string("gateway-1"), "epoch": .integer(3)]),
                ]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        var room = BotModeRoom.fixture(id: "room-1", memberIDs: ["default", "research"])
        room.markNativeRoom(state)
        room.prepareNativeTurn(
            eventID: "client-event", threadID: "thread-1", text: originalText,
            owner: .init(instanceID: "interrupted-process", generation: 1), senderSnapshot: nil
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[BotModeRoom]>(
            directory: directory, name: BotModeRoomCacheSchema.repositoryName,
            seed: [], currentSchemaVersion: BotModeRoomCacheSchema.currentVersion
        )
        try repository.save([room])
        let store = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: client)
        let opened = try await store.openNativeRoom(roomID: room.id)
        #expect(!opened.isRunning)
        #expect(opened.nativePendingEventID == nil)
        #expect(opened.nativeCompletedDiscussionEventIDs.contains("server-event"))
        #expect(opened.visibleEvents.filter { $0.kind == .human }.count == 1)
        #expect(opened.visibleEvents.filter { $0.kind == .agent }.map(\.text) == ["Recovered answer"])
        #expect(store.nativeRoomSyncErrors[room.id] == nil)
        #expect(try repository.load().first?.nativePendingEventID == nil)
        let restored = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: client)
        let reopened = try await restored.openNativeRoom(roomID: room.id)
        #expect(reopened.visibleEvents.map(\.id) == opened.visibleEvents.map(\.id))
        #expect(workspace.calls.filter { $0.operation == .groupsSend }.count == 1)
    }

    @Test
    func groupsClientChecksCancellationAroundDeferredStop() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = DeferredHermesBotModeMessagingStub()
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )
        let operation = Task { @MainActor in
            try await client.groupsStop(roomID: "room-1", cancelID: "cancel-1")
        }

        await messaging.waitUntilRequestStarts()
        operation.cancel()
        messaging.resume(with: .success(try Self.result(
            for: try #require(messaging.request),
            payload: ["cancelled": .integer(1)]
        )))

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
    }

    @Test
    func groupsSendRejectsUnacceptedOrUnstartedEventProjection() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = HermesBotModeMessagingStub { request in
            #expect(request.operation == .groupsSend)
            return try Self.result(for: request, payload: [
                "event": Self.event(
                    roomID: "room-1",
                    eventID: "server-event",
                    kind: "message.member",
                    text: "unexpected"
                ),
                "client_event_id": .string("client-event"),
                "accepted": .boolean(false),
                "driver_started": .boolean(false),
            ])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsSend(
                roomID: "room-1",
                eventID: "client-event",
                payload: HermesBotModeUserPayload(text: "Hello", threadID: "thread-1")
            )
        }
    }

    @Test
    func groupsSendRejectsReceiptWithMismatchedThread() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = HermesBotModeMessagingStub { request in
            #expect(request.operation == .groupsSend)
            return try Self.result(for: request, payload: [
                "event": Self.event(roomID: "room-1", eventID: "server-event", threadID: "other-thread"),
                "client_event_id": .string("client-event"),
                "accepted": .boolean(true),
                "driver_started": .boolean(true),
            ])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsSend(
                roomID: "room-1",
                eventID: "client-event",
                payload: HermesBotModeUserPayload(text: "Hello", threadID: "thread-1")
            )
        }
    }

    @Test
    func groupsSendRejectsReceiptWithNonUserActor() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = HermesBotModeMessagingStub { request in
            #expect(request.operation == .groupsSend)
            return try Self.result(for: request, payload: [
                "event": Self.event(
                    roomID: "room-1",
                    eventID: "server-event",
                    actor: .object(["kind": .string("gateway"), "id": .string("gateway-1")])
                ),
                "client_event_id": .string("client-event"),
                "accepted": .boolean(true),
                "driver_started": .boolean(true),
            ])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsSend(
                roomID: "room-1",
                eventID: "client-event",
                payload: HermesBotModeUserPayload(text: "Hello", threadID: "thread-1")
            )
        }
    }

    @Test
    func groupsRetryRejectsReceiptWithoutSuccessfulRetry() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = HermesBotModeMessagingStub { request in
            #expect(request.operation == .groupsRetry)
            return try Self.result(for: request, payload: [
                "retried": .boolean(false),
                "task": Self.retryTask(roomID: "room-1", taskID: "task-1", status: "queued"),
            ])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsRetry(roomID: "room-1", taskID: "task-1")
        }
    }

    @Test
    func groupsRetryRejectsReceiptWithInvalidTaskState() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = HermesBotModeMessagingStub { request in
            #expect(request.operation == .groupsRetry)
            return try Self.result(for: request, payload: [
                "retried": .boolean(true),
                "task": Self.retryTask(
                    roomID: "room-1",
                    taskID: "task-1",
                    status: "indeterminate",
                    executionGeneration: 0,
                    cancelGeneration: 0
                ),
            ])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsRetry(roomID: "room-1", taskID: "task-1")
        }
    }

    @Test
    func groupsLogRejectsSequenceGapsAndImpossibleCursorProgress() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = HermesBotModeMessagingStub { request in
            #expect(request.operation == .groupsLog)
            if request.payload["since_seq"]?.integer == 0 {
                return try Self.result(for: request, payload: [
                    "events": .array([Self.event(roomID: "room-1", eventID: "event-2", sequence: 2)]),
                    "cursor": .integer(2),
                    "latest_seq": .integer(2),
                    "has_more": .boolean(false),
                    "authority": Self.authority,
                ])
            }
            return try Self.result(for: request, payload: [
                "events": .array([]),
                "cursor": .integer(1),
                "latest_seq": .integer(2),
                "has_more": .boolean(true),
                "authority": Self.authority,
            ])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsLog(
                roomID: "room-1",
                sinceSequence: 0,
                limit: 20,
                includeDisbanded: false
            )
        }
        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsLog(
                roomID: "room-1",
                sinceSequence: 1,
                limit: 20,
                includeDisbanded: false
            )
        }
    }

    @Test
    func groupsLogRejectsAuthorityEpochMismatches() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = HermesBotModeMessagingStub { request in
            return try Self.result(for: request, payload: [
                "events": .array([Self.event(roomID: "room-1", eventID: "event-1", authorityEpoch: 4)]),
                "cursor": .integer(1),
                "latest_seq": .integer(1),
                "has_more": .boolean(false),
                "authority": Self.authority,
            ])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsLog(
                roomID: "room-1",
                sinceSequence: 0,
                limit: 20,
                includeDisbanded: false
            )
        }
    }

    @Test
    func groupsStatePreservesOuterDriverStatus() async throws {
        let owner = BighelpLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let driverStatus: [String: BighelpJSONValue] = [
            "running": .boolean(true),
            "stopping": .boolean(false),
        ]
        let messaging = HermesBotModeMessagingStub { request in
            return try Self.result(for: request, payload: [
                "room": Self.room(roomID: "room-1"),
                "driver_status": .object(driverStatus),
            ])
        }
        let client = BighelpLinkHermesBotModeClient(
            workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        let state = try await client.groupsState(roomID: "room-1", includeDisbanded: false)

        #expect(state.driverStatus == driverStatus)
    }

    @Test
    func roomMembersWithoutATargetReadAsLocalToTheirProfile() async throws {
        // Hermes reads a member without a target as local to its profile, and
        // rooms saved before targets were stored come back without one.
        let owner = BighelpLinkHermesBotModeOwner(accountID: "account", hostID: "host", connectionID: "connection")
        var room = try #require(Self.room(roomID: "room-1").object)
        room["members"] = .array(try #require(room["members"]?.array).compactMap(\.object).map { member in
            .object(member.filter { $0.key != "target" })
        })
        let olderRoom = BighelpJSONValue.object(room)
        let messaging = HermesBotModeMessagingStub { request in
            if request.operation == .groupsList {
                return try Self.result(for: request, payload: ["rooms": .array([olderRoom]), "next_offset": .null])
            }
            return try Self.result(for: request, payload: ["room": olderRoom])
        }
        let client = HermesHostedRoomClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging),
                                            owner: owner, currentOwner: { owner })

        let listed = try await client.groupsList(offset: 0, limit: 50)
        let state = try await client.groupsState(roomID: "room-1", includeDisbanded: false)

        let local: [[String: BighelpJSONValue]] = [
            ["kind": .string("local"), "profile": .string("default")],
            ["kind": .string("local"), "profile": .string("research")],
        ]
        #expect(listed.rooms.first?.members.map(\.target) == local)
        #expect(state.members.map(\.target) == local)
    }

    @Test
    func groupsLogIgnoresPageFieldsItDoesNotUse() async throws {
        let owner = BighelpLinkHermesBotModeOwner(accountID: "account", hostID: "host", connectionID: "connection")
        let messaging = HermesBotModeMessagingStub { request in
            try Self.result(for: request, payload: [
                "events": .array([Self.event(roomID: "room-1", eventID: "event-1")]),
                "cursor": .integer(1),
                "latest_seq": .integer(1),
                "has_more": .boolean(false),
                "authority": Self.authority,
                "earliest_seq": .integer(1),
                "history_scope": .string("retained"),
            ])
        }
        let client = HermesHostedRoomClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging),
                                            owner: owner, currentOwner: { owner })

        let page = try await client.groupsLog(roomID: "room-1", sinceSequence: 0, limit: 20, includeDisbanded: false)

        #expect(page.events.map(\.eventID) == ["event-1"])
        #expect(page.cursor == 1)
    }

    @Test
    func groupsSendRejectsAReceiptWithFieldsItCannotRead() async throws {
        // A receipt field the app doesn't know may change what the receipt
        // means (a delivery Hermes isn't sure of), so it never counts as sent.
        let owner = BighelpLinkHermesBotModeOwner(accountID: "account", hostID: "host", connectionID: "connection")
        let messaging = HermesBotModeMessagingStub { request in
            try Self.result(for: request, payload: [
                "event": Self.event(roomID: "room-1", eventID: "event-1"),
                "client_event_id": .string("event-1"),
                "accepted": .boolean(true),
                "driver_started": .boolean(true),
                "delivery_state": .string("uncertain"),
            ])
        }
        let client = HermesHostedRoomClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging),
                                            owner: owner, currentOwner: { owner })

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            try await client.groupsSend(roomID: "room-1", eventID: "event-1",
                                        payload: HermesBotModeUserPayload(text: "Hello", threadID: "thread-1"))
        }
    }

    @Test(arguments: ["rename-1", "wrong-event"])
    func groupsRenameVerifiesOriginalEventAfterAnotherRename(returnedEventID: String) async throws {
        let owner = BighelpLinkHermesBotModeOwner(accountID: "account", hostID: "host", connectionID: "connection")
        let roomID = "room-rename"
        let requestedName = "Requested title"
        var room = try #require(Self.room(roomID: roomID).object)
        room["name"] = .string("Changed again")
        var event = try #require(Self.event(
            roomID: roomID, eventID: returnedEventID, kind: "room.renamed",
            actor: .object(["kind": .string("system"), "id": .string("room-control")])
        ).object)
        event["payload"] = .object(["name": .string(requestedName)])
        room["event"] = .object(event)
        let responseRoom = room
        let messaging = HermesBotModeMessagingStub { request in
            #expect(request.operation == .groupsRename)
            #expect(request.payload == [
                "room_id": .string(roomID), "event_id": .string("rename-1"), "name": .string(requestedName),
            ])
            return try Self.result(for: request, payload: ["room": .object(responseRoom)])
        }
        let client = HermesHostedRoomClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging),
                                            owner: owner, currentOwner: { owner })
        if returnedEventID == "rename-1" {
            #expect(try await client.groupsRename(roomID: roomID, eventID: "rename-1", name: requestedName).name == "Changed again")
        } else {
            await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
                try await client.groupsRename(roomID: roomID, eventID: "rename-1", name: requestedName)
            }
        }
    }

    private static let capabilities: [String: BighelpJSONValue] = [
        "protocol_version": .integer(2),
        "driver": .boolean(true),
        "persistent_process": .boolean(true),
        "authority_gateway_id": .string("gateway-1"),
        "room_link": .object(["kind": .string("hosted")]),
        "features": .array([
            .string("typed_events"), .string("idempotent_send"),
            .string("monotonic_log"), .string("coordinator_fencing"),
        ]),
        "methods": .array([
            .string("groups.capabilities"), .string("groups.create"),
            .string("groups.state"), .string("groups.send"), .string("groups.log"),
            .string("groups.stop"), .string("groups.retry"), .string("groups.approve"),
        ]),
        "max_log_limit": .integer(200),
    ]

    private static let authority: BighelpJSONValue = .object([
        "gateway_id": .string("gateway-1"),
        "epoch": .integer(3),
    ])

    private static func room(roomID: String) -> BighelpJSONValue {
        .object([
            "room_id": .string(roomID),
            "name": .string("Household"),
            "members": .array([.object([
                "member_id": .string("default"),
                "profile": .string("default"),
                "handle": .string("Juno"),
                "target": .object(["kind": .string("local"), "profile": .string("default")]),
            ]), .object([
                "member_id": .string("research"),
                "profile": .string("research"),
                "handle": .string("research"),
                "target": .object(["kind": .string("local"), "profile": .string("research")]),
            ])]),
            "authority_gateway_id": .string("gateway-1"),
            "authority_epoch": .integer(3),
            "revision": .integer(1),
            "created_at": .number(1_788_000_000),
            "updated_at": .number(1_788_000_001),
            "latest_seq": .integer(1),
        ])
    }

    private static func event(
        roomID: String,
        eventID: String,
        sequence: Int = 1,
        kind: String = "message.user",
        text: String = "Hello",
        authorityEpoch: Int = 3,
        threadID: String = "thread-1",
        actor: BighelpJSONValue = .object([
            "kind": .string("user"),
            "id": .string("desktop"),
        ])
    ) -> BighelpJSONValue {
        .object([
            "room_id": .string(roomID),
            "seq": .integer(sequence),
            "event_id": .string(eventID),
            "kind": .string(kind),
            "actor": actor,
            "authority_epoch": .integer(authorityEpoch),
            "payload": .object([
                "text": .string(text),
                "thread_id": .string(threadID),
            ]),
            "created_at": .number(1_788_000_001),
        ])
    }

    private static func retryTask(
        roomID: String,
        taskID: String,
        status: String,
        executionGeneration: Int = 2,
        cancelGeneration: Int = 0
    ) -> BighelpJSONValue {
        .object([
            "room_id": .string(roomID),
            "task_id": .string(taskID),
            "thread_id": .string("thread-1"),
            "turn_id": .string("turn-1"),
            "status": .string(status),
            "execution_generation": .integer(executionGeneration),
            "cancel_generation": .integer(cancelGeneration),
        ])
    }

    private static func result(
        for request: BighelpLinkWorkspaceRequest,
        payload: [String: BighelpJSONValue]
    ) throws -> BighelpLinkWorkspaceResult {
        let payloadData = try JSONEncoder().encode(BighelpJSONValue.object(payload))
        let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
        let object: [String: Any] = [
            "version": 1,
            "type": "workspace.result",
            "requestId": request.requestID,
            "operation": request.operation.rawValue,
            "status": "completed",
            "payload": payloadObject,
            "sentAt": 1_788_000_001,
        ]
        return try JSONDecoder().decode(
            BighelpLinkWorkspaceResult.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}

@MainActor
private final class HermesBotModeMessagingStub: BighelpLinkWorkspaceMessaging {
    private let handler: (BighelpLinkWorkspaceRequest) throws -> BighelpLinkWorkspaceResult
    private(set) var requests: [BighelpLinkWorkspaceRequest] = []

    init(handler: @escaping (BighelpLinkWorkspaceRequest) throws -> BighelpLinkWorkspaceResult) {
        self.handler = handler
    }

    func performWorkspaceRequest(
        _ request: BighelpLinkWorkspaceRequest
    ) async throws -> BighelpLinkWorkspaceResult {
        requests.append(request)
        return try handler(request)
    }
}

@MainActor
private final class DeferredHermesBotModeMessagingStub: BighelpLinkWorkspaceMessaging {
    private(set) var request: BighelpLinkWorkspaceRequest?
    private var continuation: CheckedContinuation<BighelpLinkWorkspaceResult, Error>?

    func performWorkspaceRequest(
        _ request: BighelpLinkWorkspaceRequest
    ) async throws -> BighelpLinkWorkspaceResult {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequestStarts() async {
        while request == nil {
            await Task.yield()
        }
    }

    func resume(with result: Result<BighelpLinkWorkspaceResult, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
