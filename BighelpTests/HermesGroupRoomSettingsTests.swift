import Foundation
import Testing
@testable import Bighelp

/// A group chat's settings (who answers a message that names nobody, its purpose and shared
/// notes), the lines that say who took a message, and Continue on a paused discussion, in the
/// shapes Hermes 0.23 writes them (`Fixtures/HermesGroups/room-settings.json`).
@MainActor
struct HermesGroupRoomSettingsTests {
    // MARK: Reading the settings

    @Test
    func roomStateCarriesItsSettingsAndWhatItsRuntimeRuns() async throws {
        let host = try RoomSettingsHost()

        let state = try await host.client.groupsState(roomID: host.roomID, includeDisbanded: false)

        #expect(state.context == HermesBotModeRoomContext(
            purpose: "Ship the spring launch on time", notes: "The launch date is April 14.\nKeep replies short.",
            routing: .lead, leadMemberID: "pixel"))
        let support = HermesBotModeRoutingSupport(driverStatus: state.driverStatus)
        #expect(support.modes == [.everyone, .lead, .auto])
        #expect(support.maximumContinues == 5)
        // The saved copy of a room never keeps its settings.
        #expect(state.persistentMetadata.context == nil)
    }

    @Test
    func aRoomWithoutContextHasNoSettings() async throws {
        let host = try RoomSettingsHost()
        host.state["context"] = nil

        let state = try await host.client.groupsState(roomID: host.roomID, includeDisbanded: false)

        #expect(state.context == nil)
        #expect(state.members.count == 3)
    }

    @Test
    func contextIsReadLeniently() {
        #expect(HermesBotModeRoomContext(json: nil) == nil)
        #expect(HermesBotModeRoomContext(json: .string("lead")) == nil)
        // Hermes from before routing keeps only purpose and notes: the app never sends routing then.
        #expect(HermesBotModeRoomContext(json: .object(["purpose": .string("Plan"), "notes": .string("")]))
                == HermesBotModeRoomContext(purpose: "Plan", routing: nil))
        #expect(HermesBotModeRoomContext(json: .object([
            "purpose": .integer(5), "notes": .null, "routing": .string("rotate"),
            "lead_member_id": .string("pixel"), "added_later": .boolean(true),
        ])) == HermesBotModeRoomContext(routing: nil))
        #expect(HermesBotModeRoomContext(json: .object([
            "routing": .string("everyone"), "lead_member_id": .string("pixel"),
        ]))?.leadMemberID == nil)
        let leadless = HermesBotModeRoomContext(json: .object([
            "routing": .string("lead"), "lead_member_id": .string(""),
        ]))
        #expect(leadless?.routing == .lead)
        #expect(leadless?.leadMemberID == nil)
    }

    @Test
    func routingSupportKeepsOnlyModesItKnows() {
        let support = HermesBotModeRoutingSupport(driverStatus: [
            "routing_modes": .array([.string("everyone"), .string("rotate"), .integer(3), .string("auto")]),
            "max_continues": .string("5"),
        ])
        #expect(support.modes == [.everyone, .auto])
        #expect(support.maximumContinues == nil)
        #expect(HermesBotModeRoutingSupport(driverStatus: nil).modes.isEmpty)
        let auto = HermesBotModeRoomSettings(context: .init(routing: .auto), support: .init())
        #expect(auto.offersAutomaticRouting, "A room already on auto keeps the choice")
        #expect(!HermesBotModeRoomSettings(context: .init(), support: .init(modes: [.everyone, .lead]))
            .offersAutomaticRouting)
    }

    // MARK: Saving

    @Test
    func aSaveSendsItsEventIDAndLeavesOutWhatItDoesNotChange() throws {
        let keep = HermesBotModeContextIntent(eventID: "context-1", context: .init(purpose: "Plan", routing: nil))
        #expect(keep.request(roomID: "room") == [
            "room_id": .string("room"), "event_id": .string("context-1"),
            "purpose": .string("Plan"), "notes": .string(""),
        ])
        let lead = HermesBotModeContextIntent(eventID: "context-2",
                                              context: .init(routing: .lead, leadMemberID: "pixel"))
        #expect(lead.request(roomID: "room")["routing"] == .string("lead"))
        #expect(lead.request(roomID: "room")["lead_member_id"] == .string("pixel"))
        let auto = HermesBotModeContextIntent(eventID: "context-3", context: .init(routing: .auto))
        #expect(auto.request(roomID: "room")["routing"] == .string("auto"))
        #expect(auto.request(roomID: "room")["lead_member_id"] == nil, "Hermes clears the lead itself")

        let routed = try DirectHermesWorkspaceClient.route(.groupsContext, payload: lead.request(roomID: "room"))
        #expect(routed == .rpc("groups.context", lead.request(roomID: "room")))
        #expect(throws: WorkspaceClientError.invalidRequest) {
            _ = try DirectHermesWorkspaceClient.route(.groupsContext, payload: ["room_id": .string("room")])
        }
    }

    @Test
    func theSavedTextIsWhatHermesKeeps() {
        #expect(HermesBotModeRoomContext.savedPurpose("  Ship \n the   launch  ") == "Ship the launch")
        #expect(HermesBotModeRoomContext.savedNotes("\n  Keep it short.\n\n") == "Keep it short.")
        #expect(HermesBotModeRoomContext.notesBytes(" é ") == 2)
        #expect(HermesBotModeRoomContext(purpose: String(repeating: "a", count: 500)).isSavable)
        #expect(!HermesBotModeRoomContext(purpose: String(repeating: "a", count: 501)).isSavable)
        #expect(!HermesBotModeRoomContext(notes: String(repeating: "é", count: 2_049)).isSavable)
        #expect(!HermesBotModeRoomContext(routing: .lead).isSavable, "Lead routing needs a lead")
        #expect(HermesBotModeContextIntent(eventID: "a", context: .init(purpose: "Plan"))
            .isSameEdit(as: .init(purpose: " Plan ")))
        #expect(!HermesBotModeContextIntent(eventID: "a", context: .init(purpose: "Plan"))
            .isSameEdit(as: .init(purpose: "Plan", routing: .auto)))
    }

    @Test
    func theClientChecksHermesSavedThisSave() async throws {
        let host = try RoomSettingsHost()
        let params = try host.object("context_params")
        let intent = HermesBotModeContextIntent(
            eventID: try #require(params["event_id"]?.string),
            context: .init(purpose: "Ship the spring launch on time", notes: "The launch date is April 14.",
                           routing: .auto))
        #expect(intent.request(roomID: host.roomID) == params)

        let saved = try await host.client.groupsContext(roomID: host.roomID, intent: intent)
        #expect(saved.routing == .auto)
        #expect(saved.leadMemberID == nil)

        host.contextReplyEventID = "context-someone-else"
        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await host.client.groupsContext(roomID: host.roomID, intent: intent)
        }
    }

    @Test
    func aSaveHermesDidNotConfirmGoesAgainWithTheSameEventID() async throws {
        let host = try RoomSettingsHost()
        let store = try await host.openRoom()
        host.contextFailures = [WorkspaceClientError.outcomeUnknown]
        let edit = HermesBotModeRoomContext(purpose: "Ship the spring launch on time",
                                            notes: "The launch date is April 14.", routing: .auto)

        await store.saveNativeRoomContext(roomID: host.roomID, edit)
        let pending = try #require(store.room(id: host.roomID)?.nativePendingContext)
        #expect(pending.problem == "Your changes weren’t confirmed. Check the connection, then try again.")
        #expect(store.nativeRoomSettings[host.roomID]?.context.routing == .lead, "Nothing changed yet")

        await store.saveNativeRoomContext(roomID: host.roomID, edit)

        let sent = host.sentPayloads(.groupsContext).map { $0["event_id"] }
        #expect(sent.count == 2)
        #expect(sent[0] == sent[1])
        #expect(store.room(id: host.roomID)?.nativePendingContext == nil)
        #expect(store.nativeRoomSettings[host.roomID]?.context.routing == .auto)
    }

    @Test
    func aChangedEditGetsItsOwnEventID() async throws {
        let host = try RoomSettingsHost()
        let store = try await host.openRoom()
        host.contextFailures = [WorkspaceClientError.transportUnavailable]
        await store.saveNativeRoomContext(roomID: host.roomID, .init(purpose: "First", routing: .everyone))
        await store.saveNativeRoomContext(roomID: host.roomID, .init(purpose: "Second", routing: .everyone))

        let sent = host.sentPayloads(.groupsContext)
        #expect(sent.count == 2)
        #expect(sent[0]["event_id"] != sent[1]["event_id"])
        #expect(sent[1]["purpose"] == .string("Second"))
    }

    @Test
    func aRefusedSaveKeepsTheEditAndSaysWhy() async throws {
        let host = try RoomSettingsHost()
        let store = try await host.openRoom()
        let refusal = try #require(host.vector["authority_refusal"]?.string)
        host.contextFailures = [WorkspaceClientError.rejected(code: nil, message: .init(refusal))]

        await store.saveNativeRoomContext(roomID: host.roomID, .init(purpose: "Plan", routing: .everyone))

        let pending = try #require(store.room(id: host.roomID)?.nativePendingContext)
        #expect(pending.purpose == "Plan")
        #expect(pending.problem == "Another computer runs this group chat. Change its settings there.")

        try store.discardNativeRoomContextEdit(roomID: host.roomID)
        #expect(store.room(id: host.roomID)?.nativePendingContext == nil)
    }

    @Test
    func settingsComeFromEachReadOfTheRoom() async throws {
        let host = try RoomSettingsHost()
        let store = try await host.openRoom()
        #expect(store.nativeRoomSettings[host.roomID]?.context.leadMemberID == "pixel")
        #expect(store.nativeRoomSettings[host.roomID]?.offersAutomaticRouting == true)

        host.state["context"] = nil
        try await store.syncNativeRoom(roomID: host.roomID)
        #expect(store.nativeRoomSettings[host.roomID] == nil, "A room without context shows no settings")
    }

    @Test
    func aReadThatStartedBeforeASaveNeverUndoesIt() async throws {
        let host = try RoomSettingsHost()
        let store = try await host.openRoom()
        let stale = try await host.client.groupsState(roomID: host.roomID, includeDisbanded: false)
        let stamp = store.nativeRoomSettingsStamp(roomID: host.roomID)

        await store.saveNativeRoomContext(roomID: host.roomID, .init(purpose: "Plan", routing: .auto))
        store.recordNativeRoomSettings(roomID: host.roomID, state: stale, readSince: stamp)

        #expect(store.nativeRoomSettings[host.roomID]?.context.routing == .auto, "The older read is dropped")
        store.recordNativeRoomSettings(roomID: host.roomID, state: stale,
                                       readSince: store.nativeRoomSettingsStamp(roomID: host.roomID))
        #expect(store.nativeRoomSettings[host.roomID]?.context.routing == .lead, "A read after the save counts")
    }

    @Test
    func anEditDiscardedWhileItWasOnItsWayStaysDiscarded() async throws {
        let host = try RoomSettingsHost()
        let store = try await host.openRoom()
        host.contextFailures = [WorkspaceClientError.transportUnavailable]
        host.beforeContextAnswer = { try? store.discardNativeRoomContextEdit(roomID: host.roomID) }

        await store.saveNativeRoomContext(roomID: host.roomID, .init(purpose: "Plan", routing: .auto))

        #expect(store.room(id: host.roomID)?.nativePendingContext == nil)
    }

    @Test
    func routingLinesCountTowardTheOrderAfterARelaunch() throws {
        let host = try RoomSettingsHost()
        let assignment = try host.events("routing_events")[0]
        let room = try BotModeRoom(
            id: host.roomID, members: [BotModeMember(profileID: "pixel", handle: "pixel", sessionID: "",
                                                     nativeMemberID: "pixel")],
            visibleEvents: [.human(text: "Hello", id: "user:1", sourceOrder: 10)], nativeRoomID: host.roomID,
            nativeNotices: [BotModeRoomNotice(event: assignment, sourceOrder: 50)])
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room])

        #expect(store.takePresentationOrder() == 51, "A message after the line lands after it")
    }

    // MARK: Continue

    @Test
    func continueNamesTheDiscussionAndChecksTheAnswer() async throws {
        let host = try RoomSettingsHost()
        let params = try host.object("continue_params")
        let discussion = try #require(params["discussion_event_id"]?.string)

        let event = try await host.client.groupsContinue(roomID: host.roomID, discussionEventID: discussion)

        #expect(event.kind == "room.continued")
        #expect(host.sentPayloads(.groupsContinue) == [params])
        #expect(try DirectHermesWorkspaceClient.route(.groupsContinue, payload: params) == .rpc("groups.continue", params))
        await #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            _ = try await host.client.groupsContinue(roomID: host.roomID, discussionEventID: "user:other")
        }
    }

    @Test
    func aRefusedContinueSaysWhatHermesSaid() async throws {
        let host = try RoomSettingsHost()
        let store = try await host.openRoom()
        let refusal = try #require(host.vector["continue_refusal"]?.string)
        host.continueFailure = WorkspaceClientError.rejected(code: nil, message: .init(refusal))

        await store.continueNativeDiscussion(roomID: host.roomID, discussionEventID: "user:7d1c2a")

        #expect(store.nativeContinueProblems["user:7d1c2a"]
                == "This discussion can’t continue. Hermes said: This discussion already used every Continue.")
        #expect(!store.nativeContinuesInFlight.contains("user:7d1c2a"))
    }

    // MARK: Lines in the chat

    @Test
    func routingLinesSayWhoTookTheMessage() throws {
        let host = try RoomSettingsHost()
        let events = try host.events("routing_events")
        let rows = BotModeRoomNoticePresentation.rows(
            notices: notices(events), messages: [], names: ["pixel": "Pixel", "scout": "Scout", "echo": "Echo"],
            maximumContinues: 5)

        #expect(rows.map(\.row.text) == [
            "Pixel gave this to Scout",
            "Pixel is taking this",
            "Assigned to Scout and Echo",
            "Assigned to everyone",
            "Couldn’t choose who answers, so everyone will",
        ])
        #expect(rows.allSatisfy { $0.row.kind == .routing })
    }

    @Test
    func aLineNeverShowsAMemberWhoLeft() throws {
        let host = try RoomSettingsHost()
        let events = try host.events("routing_events")
        let rows = BotModeRoomNoticePresentation.rows(
            notices: notices([events[0], events[2]]), messages: [], names: ["echo": "Echo"], maximumContinues: 5)

        #expect(rows.map(\.row.text) == ["Assigned to Echo"], "Lines name only members still in the room")
    }

    @Test
    func onlyHermesOwnRoutingAndPauseEventsAreKept() throws {
        let host = try RoomSettingsHost()
        let events = try host.events("routing_events")
        #expect(events.allSatisfy(BotModeRoomNotice.keeps))
        #expect(BotModeRoomNotice.keeps(Self.pause(discussion: "user:1", sequence: 3)))
        #expect(!BotModeRoomNotice.keeps(Self.event("room.activity", sequence: 3,
                                                     payload: ["status": .string("settled")])))
        #expect(!BotModeRoomNotice.keeps(Self.event("room.routed", sequence: 3, actorKind: "user",
                                                     payload: events[2].payload)))
        #expect(BotModeRoomNotice.keeps(Self.event("room.stop_requested", sequence: 3,
                                                   payload: ["cancel_id": .string("stop-1")])))
    }

    @Test
    func aPausedDiscussionOffersContinueUntilSomethingMovesItOn() {
        let messages = [Self.userMessage("user:1", thread: "t1", sequence: 1)]
            + (2...4).map { Self.memberMessage(discussion: "user:1", thread: "t1", sequence: $0) }
        let pause = Self.pause(discussion: "user:1", thread: "t1", sequence: 5)
        let names = ["scout": "Scout"]

        let paused = BotModeRoomNoticePresentation.rows(notices: notices([pause]), messages: messages, names: names,
                                                        maximumContinues: 5)
        #expect(paused.map(\.row.text) == ["Paused after 3 messages."])
        #expect(paused.first?.row.kind == .paused(discussionEventID: "user:1", isActionable: true))

        let continued = Self.event("room.continued", sequence: 6, payload: [
            "discussion_event_id": .string("user:1"), "thread_id": .string("t1"), "grant": .integer(1),
        ])
        let afterContinue = BotModeRoomNoticePresentation.rows(
            notices: notices([pause, continued]), messages: messages, names: names, maximumContinues: 5)
        #expect(afterContinue.map(\.row.kind) == [.paused(discussionEventID: "user:1", isActionable: false), .continued])
        #expect(afterContinue.last?.row.text == "Continued")

        let stop = Self.event("room.stop_requested", sequence: 6, payload: ["cancel_id": .string("stop-1")])
        let afterStop = BotModeRoomNoticePresentation.rows(
            notices: notices([pause, stop]), messages: messages, names: names, maximumContinues: 5)
        #expect(afterStop.map(\.row.kind) == [.paused(discussionEventID: "user:1", isActionable: false)])

        let next = messages + [Self.userMessage("user:2", thread: "t1", sequence: 6)]
        let afterNext = BotModeRoomNoticePresentation.rows(
            notices: notices([pause]), messages: next, names: names, maximumContinues: 5)
        #expect(afterNext.first?.row.kind == .paused(discussionEventID: "user:1", isActionable: false))

        let otherThread = messages + [Self.userMessage("user:3", thread: "t2", sequence: 6)]
        let stillPaused = BotModeRoomNoticePresentation.rows(
            notices: notices([pause]), messages: otherThread, names: names, maximumContinues: 5)
        #expect(stillPaused.first?.row.kind == .paused(discussionEventID: "user:1", isActionable: true))
    }

    @Test
    func continueGoesOnceTheDiscussionUsedEveryContinue() {
        let messages = [Self.userMessage("user:1", thread: "t1", sequence: 1),
                        Self.memberMessage(discussion: "user:1", thread: "t1", sequence: 2)]
        var log: [HermesBotModeEvent] = []
        var sequence = 3
        for grant in 1...5 {
            log.append(Self.pause(discussion: "user:1", thread: "t1", sequence: sequence))
            log.append(Self.event("room.continued", sequence: sequence + 1, payload: [
                "discussion_event_id": .string("user:1"), "thread_id": .string("t1"), "grant": .integer(grant),
            ]))
            sequence += 2
        }
        log.append(Self.pause(discussion: "user:1", thread: "t1", sequence: sequence))

        let limited = BotModeRoomNoticePresentation.rows(notices: notices(log), messages: messages, names: [:],
                                                         maximumContinues: 5)
        #expect(limited.last?.row.kind == .paused(discussionEventID: "user:1", isActionable: false))
        #expect(limited.last?.row.text == "Paused after 1 message.")
        let unknown = BotModeRoomNoticePresentation.rows(notices: notices(log), messages: messages, names: [:],
                                                         maximumContinues: nil)
        #expect(unknown.last?.row.kind == .paused(discussionEventID: "user:1", isActionable: true))
    }

    @Test
    func theRoomLogKeepsRoutingLinesBesideTheMessages() async throws {
        let host = try RoomSettingsHost()
        let assignment = try host.events("routing_events")[0]
        host.log = [Self.userMessage("user:11aa", thread: "loopdy-settings-room", sequence: 1), assignment,
                    Self.memberMessage(discussion: "user:11aa", thread: "loopdy-settings-room", sequence: 3)]
        let store = try await host.openRoom()

        let room = try #require(store.room(id: host.roomID))
        #expect(room.nativeNotices.map(\.event.eventID) == ["dassign:9a1b"])
        let orders = room.visibleEvents.compactMap(\.sourceOrder)
        let notice = try #require(room.nativeNotices.first?.sourceOrder)
        #expect(orders.count == 2)
        #expect(orders[0] < notice && notice < orders[1])

        let reloaded = try JSONDecoder().decode(BotModeRoom.self, from: JSONEncoder().encode(room))
        #expect(reloaded.nativeNotices == room.nativeNotices)
    }

    // MARK: Helpers

    private func notices(_ events: [HermesBotModeEvent]) -> [BotModeRoomNotice] {
        events.enumerated().map { BotModeRoomNotice(event: $0.element, sourceOrder: $0.offset + 1) }
    }

    private static func event(
        _ kind: String, sequence: Int, actorKind: String = "gateway", payload: [String: BighelpJSONValue]
    ) -> HermesBotModeEvent {
        HermesBotModeEvent(roomID: "settings-room", sequence: sequence, eventID: "\(kind)-\(sequence)", kind: kind,
                           actor: ["kind": .string(actorKind), "id": .string("install:gateway")], authorityEpoch: 1,
                           payload: payload, createdAt: 1_792_631_000 + Double(sequence))
    }

    private static func pause(discussion: String, thread: String = "t1", sequence: Int) -> HermesBotModeEvent {
        event("room.activity", sequence: sequence, payload: [
            "status": .string("bounded"), "reason_code": .string("max_messages"),
            "thread_id": .string(thread), "discussion_event_id": .string(discussion),
        ])
    }

    private static func userMessage(_ id: String, thread: String, sequence: Int) -> HermesBotModeEvent {
        HermesBotModeEvent(roomID: "settings-room", sequence: sequence, eventID: id, kind: "message.user",
                           actor: ["kind": .string("user"), "id": .string("desktop")], authorityEpoch: 1,
                           payload: ["text": .string("Can someone check the launch list?"), "thread_id": .string(thread)],
                           createdAt: 1_792_631_000 + Double(sequence))
    }

    private static func memberMessage(discussion: String, thread: String, sequence: Int) -> HermesBotModeEvent {
        HermesBotModeEvent(roomID: "settings-room", sequence: sequence, eventID: "dmessage:\(sequence)",
                           kind: "message.member",
                           actor: ["kind": .string("member"), "id": .string("scout"), "profile": .string("scout")],
                           authorityEpoch: 1,
                           payload: ["text": .string("On it."), "member_id": .string("scout"),
                                     "discussion_event_id": .string(discussion), "thread_id": .string(thread),
                                     "round_index": .integer(0), "member_index": .integer(0)],
                           createdAt: 1_792_631_000 + Double(sequence))
    }
}

/// A Hermes 0.23 host with one room Hermes runs itself, answering from `room-settings.json`.
@MainActor
private final class RoomSettingsHost: WorkspaceOperationPerforming {
    let vector: [String: BighelpJSONValue]
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    var state: [String: BighelpJSONValue]
    var log: [HermesBotModeEvent] = []
    var contextFailures: [any Error] = []
    /// Runs while a save waits for its answer.
    var beforeContextAnswer: (() -> Void)?
    /// Answers a save with another save's event, as a confused host might.
    var contextReplyEventID: String?
    var continueFailure: (any Error)?
    private(set) var requests: [(operation: WorkspaceOperation, payload: [String: BighelpJSONValue])] = []
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private static let gatewayID = "install:5e551011f00dfeed5e551011f00dfeed"

    lazy var client = BighelpLinkHermesBotModeClient(workspace: self, owner: owner!)

    init() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/HermesGroups/room-settings.json")
        vector = try JSONDecoder().decode([String: BighelpJSONValue].self, from: Data(contentsOf: url))
        state = try #require(vector["state"]?.object)
        owner = WorkspaceOwner(authority: try .fixture(id: UUID().uuidString),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var roomID: String { state["room"]?.object?["room_id"]?.string ?? "" }

    func object(_ key: String) throws -> [String: BighelpJSONValue] {
        try #require(vector[key]?.object)
    }

    func events(_ key: String) throws -> [HermesBotModeEvent] {
        try JSONDecoder().decode([HermesBotModeEvent].self, from: JSONEncoder().encode(try #require(vector[key])))
    }

    func sentPayloads(_ operation: WorkspaceOperation) -> [[String: BighelpJSONValue]] {
        requests.filter { $0.operation == operation }.map(\.payload)
    }

    /// A store with the room opened from this host, as a chat opens it.
    func openRoom() async throws -> BotModeRoomStore {
        let repository = DemoRepository<[BotModeRoom]>(directory: directory, name: BotModeRoomCacheSchema.repositoryName,
            seed: [], currentSchemaVersion: BotModeRoomCacheSchema.currentVersion)
        let store = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository, nativeClient: client)
        _ = try await store.openNativeRoom(roomID: roomID)
        return store
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        _ = try DirectHermesWorkspaceClient.route(operation, payload: payload)
        requests.append((operation, payload))
        switch operation {
        case .groupsCapabilities:
            return [
                "protocol_version": .integer(2), "driver": .boolean(true), "persistent_process": .boolean(true),
                "authority_gateway_id": .string(Self.gatewayID), "room_link": .object([:]),
                "features": .array(HermesBotModeCapabilities.requiredFeatures.map(BighelpJSONValue.string)),
                "methods": .array((HermesBotModeCapabilities.requiredOperations
                    + ["groups.list", "groups.rename", "groups.context", "groups.continue"]).map(BighelpJSONValue.string)),
                "max_log_limit": .integer(500),
            ]
        case .groupsState:
            var room = try #require(state["room"]?.object)
            room["latest_seq"] = .integer(log.count)
            var reply = state
            reply["room"] = .object(room)
            return reply
        case .groupsLog:
            let since = payload["since_seq"]?.integer ?? 0
            let page = log.filter { $0.sequence > since }
            return [
                "events": try JSONDecoder().decode(BighelpJSONValue.self, from: JSONEncoder().encode(page)),
                "cursor": .integer(log.count), "latest_seq": .integer(log.count), "has_more": .boolean(false),
                "authority": .object(["gateway_id": .string(Self.gatewayID), "epoch": .integer(1)]),
            ]
        case .groupsContext:
            beforeContextAnswer?()
            if !contextFailures.isEmpty { throw contextFailures.removeFirst() }
            var reply = try object("context_reply")
            var event = try #require(reply["event"]?.object)
            event["event_id"] = contextReplyEventID.map(BighelpJSONValue.string) ?? payload["event_id"]
            let saved: BighelpJSONValue = .object([
                "purpose": payload["purpose"] ?? .string(""), "notes": payload["notes"] ?? .string(""),
                "routing": payload["routing"] ?? state["context"]?.object?["routing"] ?? .string("everyone"),
                "lead_member_id": payload["lead_member_id"] ?? .string(""),
            ])
            event["payload"] = saved
            reply["event"] = .object(event)
            reply["context"] = saved
            state["context"] = saved
            return reply
        case .groupsContinue:
            if let continueFailure { throw continueFailure }
            let reply = try object("continue_reply")
            guard payload["discussion_event_id"] == reply["event"]?.object?["payload"]?.object?["discussion_event_id"] else {
                var other = reply
                var event = try #require(reply["event"]?.object)
                event["payload"] = .object(["discussion_event_id": .string("user:7d1c2a"),
                                            "thread_id": .string("loopdy-settings-room"), "grant": .integer(1)])
                other["event"] = .object(event)
                return other
            }
            return reply
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }
}
