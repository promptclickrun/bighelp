import Foundation
import Testing
@testable import Bighelp

/// Group chats on both Hermes `groups.*` paths, from what a throwaway Hermes v0.22.4 host
/// answered (`Fixtures/HermesGroups`): its standalone dashboard's path (`legacy-path`, the
/// code v0.22.2 serves) and its gateway listener's session path (`session-path`). The
/// `crash_*` vectors are a member turn cut off by stopping the host mid-turn.
@MainActor
struct HermesGroupsHostPathTests {
    enum HostPath: String, CaseIterable, Sendable {
        case legacy = "legacy-path"
        case session = "session-path"
    }

    @Test(arguments: HostPath.allCases)
    func eitherPathRunsGroupChats(path: HostPath) async throws {
        let host = try HermesGroupsVectorHost(path)
        let capabilities = try await host.client.groupsCapabilities()

        #expect(capabilities.supportsNativeExecution)
        switch path {
        case .legacy:
            #expect(capabilities.seatableProfiles == nil)
            #expect(capabilities.canSeat(profile: "anyone"))
        case .session:
            #expect(capabilities.seatableProfiles == ["default", "nova"])
            #expect(capabilities.canSeat(profile: "nova"))
            #expect(!capabilities.canSeat(profile: "parked"))
        }
    }

    @Test
    func sessionPathOffersNoRoomLink() async throws {
        let host = try HermesGroupsVectorHost(.session)
        await #expect(throws: HermesBotModeRoomLink.Problem.unavailable("unsupported")) {
            _ = try await host.client.groupsRoomLink(profile: "default")
        }
    }

    @Test(arguments: HostPath.allCases)
    func roomCreateSendLogStopAndDisbandReadOnEitherPath(path: HostPath) async throws {
        let host = try HermesGroupsVectorHost(path)
        let create = try host.object("create", "params")
        let members = try JSONDecoder().decode([HermesBotModeRoomMember].self,
                                               from: JSONEncoder().encode(try #require(create["members"])))
        let roomID = try #require(create["room_id"]?.string)

        let room = try await host.client.groupsCreate(roomID: roomID, name: try #require(create["name"]?.string),
                                                      members: members)
        #expect(room.members.map(\.profile) == ["default", "nova"])
        #expect(try await host.client.groupsList(offset: 0, limit: 100).rooms.map(\.roomID) == [roomID])
        #expect(try await host.client.groupsState(roomID: roomID, includeDisbanded: false).driverStatus != nil)

        let send = try host.object("send", "params")
        let payload = try #require(send["payload"]?.object)
        let receipt = try await host.client.groupsSend(
            roomID: roomID, eventID: try #require(send["event_id"]?.string),
            payload: .init(text: try #require(payload["text"]?.string),
                           threadID: try #require(payload["thread_id"]?.string)))
        #expect(receipt.event.kind == "message.user")

        let cancelID = try #require((try host.object("stop", "params"))["cancel_id"]?.string)
        let log = try await host.client.groupsLog(roomID: roomID, sinceSequence: 0, limit: 500, includeDisbanded: false)
        let stop = try #require(log.events.first { $0.kind == "room.stop_requested" })
        #expect(stop.payload["cancel_id"] == .string(cancelID))
        #expect(log.events.contains { $0.kind == "turn.cancelled" })
        #expect(log.events.filter { $0.kind == "message.member" }.count >= 2)

        try await host.client.groupsStop(roomID: roomID, cancelID: cancelID)
        try await host.client.groupsDisband(roomID: roomID)
    }

    /// A host stopped mid-turn. The older path lists a retry by task ID, refuses any other
    /// key (`retry_refusals`), and runs it; the retried turn's `turn.settled` names no
    /// execution generation. The session path lists the attempt with its member and
    /// generation and refuses a retry without them; after a crash it refuses even the
    /// exact attempt (`unknown_execution`), which the app shows instead of waiting.
    @Test(arguments: HostPath.allCases)
    func retryAfterACrashSendsEachPathItsShape(path: HostPath) async throws {
        let host = try HermesGroupsVectorHost(path, crash: "crash_retry")
        let store = try host.store()
        _ = try await store.openNativeRoom(roomID: host.roomID)
        #expect(store.pendingNativeRetryTaskIDs(roomID: host.roomID) == [host.actionTaskID])

        let retry = Task { try await store.retry(roomID: host.roomID) }
        let deadline = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            retry.cancel()
        }
        defer { deadline.cancel() }
        let result = await retry.result

        let sent = try host.object("crash_retry", "params")
        #expect(host.sentPayloads(.groupsRetry) == [sent])
        switch path {
        case .legacy:
            #expect(throws: Never.self) { try result.get() }
            #expect(store.room(id: host.roomID)?.visibleEvents.contains {
                $0.kind == .agent && $0.text?.hasPrefix("Canned reply") == true
            } == true)
        case .session:
            #expect(throws: WorkspaceClientError.rejected(code: "unknown_execution")) { try result.get() }
        }
        #expect(store.room(id: host.roomID)?.isRunning == false)
    }

    /// Only Discard gets a room past a turn the session path lost track of.
    @Test
    func discardSendsTheExactListedAttempt() async throws {
        let host = try HermesGroupsVectorHost(.session, crash: "crash_discard")
        let store = try host.store()
        _ = try await store.openNativeRoom(roomID: host.roomID)
        let discard = try #require(store.pendingNativeDiscards(roomID: host.roomID).first)
        #expect(discard.memberID == "default")
        #expect(discard.taskID == host.actionTaskID)
        #expect(store.pendingNativeRetryTaskIDs(roomID: host.roomID).isEmpty)

        try await store.discardNative(roomID: host.roomID, discard: discard)

        let sent = try host.object("crash_discard", "params")
        #expect(host.sentPayloads(.groupsDiscard) == [sent])
        #expect(store.pendingNativeDiscards(roomID: host.roomID).isEmpty)
        await #expect(throws: BotModeRoomError.nativeDiscardStale) {
            try await store.discardNative(roomID: host.roomID, discard: discard)
        }
    }

    @Test
    func discardReceiptMustNameTheDiscardedAttempt() async throws {
        let host = try HermesGroupsVectorHost(.session, crash: "crash_discard")
        var reply = try host.object("crash_discard", "reply")
        var task = try #require(reply["task"]?.object)
        task["status"] = .string("queued")
        reply["task"] = .object(task)
        host.discardReply = reply
        let action = try #require(HermesBotModePendingDiscard.decode(
            roomID: host.roomID, driverStatus: try host.object("crash_discard", "driver_status")).first)

        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await host.client.groupsDiscard(roomID: host.roomID, discard: action)
        }
    }

    @Test
    func directRoutesCarryTheSessionPathAttempt() throws {
        let attempt: [String: BighelpJSONValue] = [
            "room_id": .string("room"), "task_id": .string("dtask:1"),
            "member_id": .string("default"), "execution_generation": .integer(1),
        ]
        #expect(try DirectHermesWorkspaceClient.route(.groupsRetry, payload: attempt) == .rpc("groups.retry", attempt))
        #expect(try DirectHermesWorkspaceClient.route(.groupsDiscard, payload: attempt) == .rpc("groups.discard", attempt))
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.groupsRetry, payload: attempt.merging(["extra": .integer(1)]) { $1 })
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.groupsDiscard, payload: attempt.filter { $0.key != "member_id" })
        }
    }

    /// The session path pages only the rooms this connection may see, so its next
    /// cursor can skip past `offset + limit`.
    @Test
    func sessionPathRoomListMaySkipRoomsThisConnectionCannotSee() async throws {
        let host = try HermesGroupsVectorHost(.session)
        let rooms = try #require((try host.object("list"))["rooms"]?.array)
        host.listReply = ["rooms": .array(rooms), "next_offset": .integer(4)]

        #expect(try await host.client.groupsList(offset: 0, limit: 1).nextOffset == 4)

        host.listReply = ["rooms": .array(rooms), "next_offset": .integer(0)]
        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await host.client.groupsList(offset: 0, limit: 1)
        }
    }
}

/// A Hermes host that answers with one path's recorded replies, and refuses a request the
/// way that path did.
@MainActor
private final class HermesGroupsVectorHost: WorkspaceOperationPerforming {
    let path: HermesGroupsHostPathTests.HostPath
    let vector: [String: BighelpJSONValue]
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    var listReply: [String: BighelpJSONValue]?
    var discardReply: [String: BighelpJSONValue]?
    private(set) var requests: [(operation: WorkspaceOperation, payload: [String: BighelpJSONValue])] = []
    private let crash: [String: BighelpJSONValue]
    private var events: [BighelpJSONValue] = []
    private var driverStatus: BighelpJSONValue = .null
    private var disbanded = false
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    lazy var client = BighelpLinkHermesBotModeClient(workspace: self, owner: owner!)

    init(_ path: HermesGroupsHostPathTests.HostPath, crash scenario: String? = nil) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/HermesGroups/\(path.rawValue).json")
        let vector = try JSONDecoder().decode([String: BighelpJSONValue].self, from: Data(contentsOf: url))
        let crash = scenario.flatMap { vector[$0]?.object } ?? [:]
        self.path = path
        self.vector = vector
        self.crash = crash
        owner = WorkspaceOwner(authority: try .fixture(id: UUID().uuidString),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
        events = crash["events"]?.array ?? []
        driverStatus = crash["driver_status"] ?? .null
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var roomID: String { events.first?.object?["room_id"]?.string ?? "" }
    var actionTaskID: String {
        driverStatus.object?["pending_actions"]?.array?.first?.object?["task_id"]?.string
            ?? crash["params"]?.object?["task_id"]?.string ?? ""
    }

    func store() throws -> BotModeRoomStore {
        let repository = DemoRepository<[BotModeRoom]>(directory: directory, name: BotModeRoomCacheSchema.repositoryName,
            seed: [], currentSchemaVersion: BotModeRoomCacheSchema.currentVersion)
        return BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: client)
    }

    func sentPayloads(_ operation: WorkspaceOperation) -> [[String: BighelpJSONValue]] {
        requests.filter { $0.operation == operation }.map(\.payload)
    }

    func object(_ keys: String...) throws -> [String: BighelpJSONValue] {
        var value: BighelpJSONValue? = .object(vector)
        for key in keys { value = value?.object?[key] }
        return try #require(value?.object)
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        _ = try DirectHermesWorkspaceClient.route(operation, payload: payload)
        requests.append((operation, payload))
        switch operation {
        case .groupsCapabilities: return try object("capabilities")
        case .groupsCreate: return try object("create", "reply")
        case .groupsList: return try listReply ?? object("list")
        case .groupsSend: return try object("send", "reply")
        case .groupsStop: return try object("stop", "reply")
        case .groupsDisband:
            disbanded = true
            return try object("disband")
        case .groupsState:
            if disbanded { return try object("state_disbanded") }
            guard !events.isEmpty else { return try object("state") }
            var room = try object("state", "room")
            room["room_id"] = .string(roomID)
            room["latest_seq"] = .integer(events.count)
            return ["room": .object(room), "driver_status": driverStatus]
        case .groupsLog:
            guard !events.isEmpty else { return try object("log") }
            let since = payload["since_seq"]?.integer ?? 0
            return ["events": .array(events.filter { ($0.object?["seq"]?.integer ?? 0) > since }),
                    "cursor": .integer(events.count), "latest_seq": .integer(events.count),
                    "has_more": .boolean(false), "authority": .object(try object("log", "authority"))]
        case .groupsRetry, .groupsDiscard:
            return try act(payload)
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }

    /// The recorded answer to the recorded request; anything else is refused the way that
    /// path refused it (`retry_refusals`).
    private func act(_ payload: [String: BighelpJSONValue]) throws -> [String: BighelpJSONValue] {
        guard .object(payload) == crash["params"] else {
            throw WorkspaceClientError.rejected(code: path == .legacy ? "4000" : "invalid_params")
        }
        if let error = crash["error"]?.object {
            throw WorkspaceClientError.rejected(code: error["message"]?.string)
        }
        events += crash["events_after"]?.array ?? []
        driverStatus = .object(["running": .boolean(true), "working": .boolean(false), "blocked": .boolean(false),
                                "counts": .object([:]), "pending_actions": .array([]), "peer_routes": .array([])])
        return try discardReply ?? #require(crash["reply"]?.object)
    }
}
