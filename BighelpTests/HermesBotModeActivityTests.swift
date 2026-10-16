import Foundation
import Testing
@testable import Bighelp

@MainActor
struct HermesBotModeActivityTests {
    @Test func clientUsesFixedRoutesAndDoesNotMistakeSourceSequenceGapsForLoss() async throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "activity-owner"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        var operations: [HermesBotModeActivityOperation] = []
        let client = NativeHermesBotModeActivityClient(owner: owner, currentOwner: { owner }) { operation, payload in
            operations.append(operation)
            #expect(payload["roomId"] == .string("room"))
            switch operation {
            case .open: return Self.page()
            case .poll:
                #expect(payload["after"] == .integer(0))
                return Self.page(events: [
                    Self.event(sequence: 1, sourceSequence: 2),
                    Self.event(sequence: 2, sourceSequence: 90, kind: "tool.completed"),
                ])
            case .close:
                return ["schemaVersion": .integer(1), "roomId": .string("room"),
                        "streamId": .string("stream"), "closed": .boolean(true)]
            }
        }
        let opened = try await client.open(roomID: "room")
        let page = try await client.poll(roomID: "room", streamID: opened.streamId, after: 0, limit: 8)
        #expect(page.upstreamLoss == "unobservable")
        #expect(page.droppedTotal == 0)
        #expect(page.events.last?.kind == .completed)
        #expect(page.events.last?.result.state == .unavailable)
        try await client.close(roomID: "room", streamID: page.streamId)
        #expect(operations == [.open, .poll, .close])
        #expect(HermesBotModeActivityOperation.poll.path == "/api/plugins/loopdy/native/groups/activity/poll")
    }

    @Test func activityDecoderRejectsUnknownFieldsAndMismatchedCoordinates() throws {
        var wrongRoom = Self.page(events: [Self.event(sequence: 1)])
        wrongRoom["roomId"] = .string("other")
        var extra = Self.page(events: [Self.event(sequence: 1)])
        extra["success"] = .boolean(true)
        let gap = Self.page(events: [Self.event(sequence: 2)])
        var detail = try #require(Self.event(sequence: 1).object)
        detail["arguments"] = .object(["state": .string("omitted_sensitive"), "text": .string("must not arrive")])
        for value in [wrongRoom, extra, gap, Self.page(events: [.object(detail)])] {
            #expect(throws: WorkspaceClientError.invalidResponse) {
                try NativeHermesBotModeActivityClient.decodePage(value, roomID: "room", streamID: "stream", after: 0, limit: 8)
            }
        }
    }

    @Test func authenticatedOwnerChangeRejectsLateActivityResponse() async throws {
        let original = WorkspaceOwner(authority: try .fixture(id: "activity-owner"),
                                      authenticationGeneration: UUID(), connectionGeneration: UUID())
        let box = ActivityOwnerBox(owner: original)
        let client = NativeHermesBotModeActivityClient(owner: original, currentOwner: { box.owner }) { _, _ in
            box.owner = nil
            return Self.page()
        }
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await client.open(roomID: "room")
        }
    }

    @Test func transientStoreClearsRowsAndModelOwnedDisclosureOnReset() async throws {
        let opened = try NativeHermesBotModeActivityClient.decodePage(Self.page(), roomID: "room", streamID: nil, after: 0, limit: 8)
        let first = try NativeHermesBotModeActivityClient.decodePage(
            Self.page(events: [Self.event(sequence: 1)]), roomID: "room", streamID: "stream", after: 0, limit: 8
        )
        let client = ActivityTestClient(opened: opened, pages: [first])
        let store = BotModeActivityStore()
        store.configure(client)
        let viewer = UUID()
        store.begin(roomID: "room", viewerID: viewer, memberIDs: ["member"],
                    isRetired: { _ in false }, reconcile: {})
        for _ in 0..<100 where store.snapshots["room"]?.tools.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        let id = try #require(store.snapshots["room"]?.tools.first?.id)
        store.toggleTool(id)
        #expect(store.expandedToolIDs.contains(id))
        store.configure(nil)
        #expect(store.snapshots.isEmpty)
        #expect(store.expandedToolIDs.isEmpty)
        for _ in 0..<100 where client.closed.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(client.closed == ["stream"])
    }

    @Test func bufferResetClearsOnlyTransientRowsAndRequestsCanonicalReconciliation() async throws {
        let opened = try NativeHermesBotModeActivityClient.decodePage(Self.page(), roomID: "room", streamID: nil, after: 0, limit: 8)
        let first = try NativeHermesBotModeActivityClient.decodePage(
            Self.page(events: [Self.event(sequence: 1)]), roomID: "room", streamID: "stream", after: 0, limit: 8
        )
        var value = Self.page()
        value["cursor"] = .integer(3)
        value["highWater"] = .integer(3)
        value["resetRequired"] = .boolean(true)
        value["resetReason"] = .string("buffer_loss")
        value["droppedTotal"] = .integer(2)
        let reset = try NativeHermesBotModeActivityClient.decodePage(value, roomID: "room", streamID: "stream", after: 1, limit: 8)
        let client = ActivityTestClient(opened: opened, pages: [first, reset])
        let store = BotModeActivityStore(pollInterval: .zero)
        store.configure(client)
        var reconciliations = 0
        let viewer = UUID()
        store.begin(roomID: "room", viewerID: viewer, memberIDs: ["member"],
                    isRetired: { _ in false }, reconcile: { reconciliations += 1 })
        for _ in 0..<100 where reconciliations == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reconciliations == 1)
        #expect(store.snapshots["room"]?.tools.isEmpty == true)
        #expect(store.snapshots["room"]?.message.contains("interrupted") == true)
        store.end(roomID: "room", viewerID: viewer)
    }

    @Test func typingIsAskedForOnlyWhenTheHostOffersIt() async throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "activity-owner"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        for includes in [false, true] {
            var opened: [String: BighelpJSONValue] = [:]
            let client = NativeHermesBotModeActivityClient(owner: owner, currentOwner: { owner },
                                                           includesResponding: includes) { _, payload in
                opened = payload
                return Self.page()
            }
            _ = try await client.open(roomID: "room")
            #expect(opened["include"] == (includes ? .array([.string("member.responding")]) : nil))
        }
    }

    @Test func writingReportsDecodeBesideToolsAndNeverCarryText() throws {
        let page = try NativeHermesBotModeActivityClient.decodePage(
            Self.page(events: [Self.event(sequence: 1), Self.responding(sequence: 2, member: "bob")]),
            roomID: "room", streamID: "stream", after: 0, limit: 8
        )
        #expect(page.events.map(\.observationSequence) == [1])
        #expect(page.responding.map(\.memberId) == ["bob"])
        #expect(page.cursor == 2)
        var withText = try #require(Self.responding(sequence: 1).object)
        withText["text"] = .string("draft words")
        let gap = Self.page(events: [Self.event(sequence: 1), Self.responding(sequence: 3)])
        for value in [Self.page(events: [.object(withText)]), gap] {
            #expect(throws: WorkspaceClientError.invalidResponse) {
                try NativeHermesBotModeActivityClient.decodePage(value, roomID: "room", streamID: "stream", after: 0, limit: 8)
            }
        }
    }

    @Test func typingShowsWhoWritesAndLeavesWhenReportsStop() async throws {
        let clock = TypingClock()
        let client = GatedActivityClient()
        let store = BotModeActivityStore(pollInterval: .zero, typingTimeout: 6, now: { clock.now })
        store.configure(client)
        let viewer = UUID()
        store.begin(roomID: "room", viewerID: viewer, memberIDs: ["alice", "bob"],
                    isRetired: { _ in false }, reconcile: {})
        client.send(try Self.decoded([Self.responding(sequence: 1, member: "bob"),
                                      Self.responding(sequence: 2, member: "alice")]))
        for _ in 0..<200 where store.typingMemberIDs(roomID: "room").count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.typingMemberIDs(roomID: "room") == ["bob", "alice"])
        store.finishTyping(roomID: "room", memberID: "bob", taskID: "task")
        #expect(store.typingMemberIDs(roomID: "room") == ["alice"])
        clock.now = clock.now.addingTimeInterval(7)
        client.send(try Self.decoded([], cursor: 2))
        for _ in 0..<200 where !store.typingMemberIDs(roomID: "room").isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.typingMemberIDs(roomID: "room").isEmpty)
        store.end(roomID: "room", viewerID: viewer)
    }

    @Test func typingLeavesWhenTheMembersReplyReachesTheRoomLog() async throws {
        let source = BotModeRoom.fixture(id: "room", memberIDs: ["finance", "research"])
        let room = try BotModeRoom(id: source.id, members: source.members, visibleEvents: source.visibleEvents,
                                   nativeRoomID: source.id, nativeLogCursor: 0)
        let native = NativeBotModeTestClient(capabilities: .fixture())
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], nativeClient: native)
        let feed = GatedActivityClient()
        store.configureNativeActivityClient(feed)
        let viewer = UUID()
        store.beginNativeActivity(roomID: room.id, viewerID: viewer)
        feed.send(try Self.decoded([Self.responding(sequence: 1, member: "finance")]))
        for _ in 0..<200 where store.activity.typingMemberIDs(roomID: room.id).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.activity.typingMemberIDs(roomID: room.id) == ["finance"])
        native.logPages = [[.fixture(roomID: room.id, sequence: 1, eventID: "reply", kind: "message.member", payload: [
            "text": .string("Done"), "thread_id": .string("thread"),
            "member_id": .string("finance"), "task_id": .string("task"),
        ])]]
        try await store.syncNativeRoom(roomID: room.id)
        #expect(store.activity.typingMemberIDs(roomID: room.id).isEmpty)
        store.activity.end(roomID: room.id, viewerID: viewer)
    }

    static func decoded(_ events: [BighelpJSONValue], cursor: Int? = nil) throws -> HermesBotModeActivityPage {
        var value = page(events: events)
        if let cursor { value["cursor"] = .integer(cursor); value["highWater"] = .integer(cursor) }
        let after = (events.first?.object?["observationSequence"]?.integer).map { $0 - 1 } ?? cursor ?? 0
        return try NativeHermesBotModeActivityClient.decodePage(value, roomID: "room", streamID: "stream",
                                                               after: after, limit: 8)
    }

    static func responding(sequence: Int, member: String = "alice") -> BighelpJSONValue {
        .object([
            "observationSequence": .integer(sequence), "observedAt": .integer(1_100),
            "roomId": .string("room"), "memberId": .string(member), "threadId": .string("thread"),
            "turnId": .string("turn"), "taskId": .string("task"), "executionGeneration": .integer(1),
            "sourceSequence": .integer(sequence), "kind": .string("member.responding"),
        ])
    }

    static func page(events: [BighelpJSONValue] = []) -> [String: BighelpJSONValue] {
        let cursor = events.last?.object?["observationSequence"]?.integer ?? 0
        return [
            "schemaVersion": .integer(1), "runtimeId": .string("runtime"), "roomId": .string("room"),
            "streamId": .string("stream"), "sourceState": .string(events.isEmpty ? "registered_unobserved" : "observed"),
            "upstreamLoss": .string("unobservable"), "openedAt": .integer(1_000),
            "expiresAt": .integer(61_000), "cursor": .integer(cursor), "highWater": .integer(cursor),
            "hasMore": .boolean(false), "resetRequired": .boolean(false), "resetReason": .null,
            "droppedTotal": .integer(0), "projectionDrops": .integer(0), "events": .array(events),
        ]
    }

    static func event(sequence: Int, sourceSequence: Int = 1, kind: String = "tool.started") -> BighelpJSONValue {
        .object([
            "observationSequence": .integer(sequence), "observedAt": .integer(1_100),
            "roomId": .string("room"), "memberId": .string("member"), "threadId": .string("thread"),
            "turnId": .string("turn"), "taskId": .string("task"), "executionGeneration": .integer(1),
            "sourceSequence": .integer(sourceSequence), "kind": .string(kind),
            "tool": .object(["id": .string("tool-1"), "name": .string("calendar"), "durationMs": .null]),
            "arguments": .object(["state": .string("unavailable"), "text": .null]),
            "result": .object(["state": .string("unavailable"), "text": .null]),
        ])
    }
}

@MainActor
private final class ActivityOwnerBox {
    var owner: WorkspaceOwner?
    init(owner: WorkspaceOwner) { self.owner = owner }
}

@MainActor
private final class ActivityTestClient: HermesBotModeActivityClient {
    let opened: HermesBotModeActivityPage
    var pages: [HermesBotModeActivityPage]
    var closed: [String] = []
    init(opened: HermesBotModeActivityPage, pages: [HermesBotModeActivityPage]) {
        self.opened = opened
        self.pages = pages
    }
    func open(roomID: String) async throws -> HermesBotModeActivityPage { opened }
    func poll(roomID: String, streamID: String, after: Int, limit: Int) async throws -> HermesBotModeActivityPage {
        if !pages.isEmpty { return pages.removeFirst() }
        try await Task.sleep(for: .seconds(60))
        throw WorkspaceClientError.transportUnavailable
    }
    func close(roomID: String, streamID: String) async throws { closed.append(streamID) }
}

@MainActor
private final class TypingClock {
    var now = Date(timeIntervalSince1970: 1_788_000_000)
}

/// Answers each poll with the next page the test sends, waiting until there is one.
@MainActor
private final class GatedActivityClient: HermesBotModeActivityClient {
    private var pages: [HermesBotModeActivityPage] = []
    func send(_ page: HermesBotModeActivityPage) { pages.append(page) }
    func open(roomID: String) async throws -> HermesBotModeActivityPage {
        try NativeHermesBotModeActivityClient.decodePage(HermesBotModeActivityTests.page(), roomID: roomID,
                                                         streamID: nil, after: 0, limit: 8)
    }
    func poll(roomID: String, streamID: String, after: Int, limit: Int) async throws -> HermesBotModeActivityPage {
        while pages.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        return pages.removeFirst()
    }
    func close(roomID: String, streamID: String) async throws {}
}
