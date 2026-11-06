#if DEBUG
import Foundation

/// A demo group chat Hermes runs itself (`-preview-group-settings`): a lead who passed a message
/// on, an automatic pick, a message sent straight to one bot by its @mention, and a discussion
/// paused at its cap. Group Settings saves here (`groups.context`), and Continue and Stop on the
/// paused discussion act as Hermes does.
@MainActor
final class GroupSettingsDemoClient: HermesBotModeCatalogClient, HermesBotModeRoomSettingsClient {
    static let launchArgument = "-preview-group-settings"
    /// Saving settings fails the way it does on a room another computer runs.
    static let refusesSettingsArgument = "-preview-group-settings-refused"
    static let roomID = "group-settings-demo"
    private static let gatewayID = "fixture-gateway"
    private static let thread = "loopdy-group-settings-demo"
    private static let members: [(profile: String, handle: String, name: String)] = [
        ("finance", "avery", "Avery Park"), ("home", "jordan", "Jordan Lee"), ("travel", "mina", "Mina Shah"),
    ]

    private var events: [HermesBotModeEvent] = []
    private var context: [String: BighelpJSONValue] = [
        "purpose": .string("Plan the spring garden party"),
        "notes": .string("The party is on Saturday, May 9, at 4 PM.\nKeep the budget under $300."),
        "routing": .string("lead"), "lead_member_id": .string("member-finance"),
    ]
    private let refusesSettings: Bool
    private var nextSequence: Int { (events.last?.sequence ?? 0) + 1 }

    init(refusesSettings: Bool = false) {
        self.refusesSettings = refusesSettings
        let lead = post("Can someone check the shopping list?")
        record(gatewayEvent("room.assignment", [
            "discussion_event_id": .string(lead.eventID), "thread_id": .string(Self.thread),
            "task_id": .string("dtask:demo-lead"), "lead_member_id": .string("member-finance"),
            "member_ids": .array([.string("member-home")]), "fallback": .boolean(false),
        ]))
        record(reply("member-home", "I’ll go through it tonight and add anything that’s missing.", to: lead))
        let mention = post("@mina can you book the tables and chairs?")
        record(reply("member-travel", "Booked: six tables and 30 chairs, delivered Saturday at noon.", to: mention))
        let routed = post("What should the invitation say?")
        record(gatewayEvent("room.routed", [
            "discussion_event_id": .string(routed.eventID), "thread_id": .string(Self.thread),
            "member_ids": .array([.string("member-finance"), .string("member-home")]),
            "everyone": .boolean(false), "fallback": .boolean(false),
        ]))
        record(reply("member-home", "Short and warm: the date, the time, and “bring a chair if you can.”", to: routed))
        record(reply("member-finance", "Add that food and drinks are covered, so nobody brings a dish.", to: routed))
        let discussion = post("Let’s pick a theme for the decorations.")
        let ideas = [
            "Wildflowers in jars on every table.", "A lantern path to the garden gate.",
            "Paper bunting in three colors.", "Herb pots that guests can take home.",
            "Mismatched vintage plates.", "A chalkboard menu by the door.", "Fairy lights in the trees.",
            "Lemonade in glass jars.", "Picnic blankets on the lawn.", "One long table under the trees.",
        ]
        for (index, idea) in ideas.enumerated() {
            record(reply(Self.members[index % Self.members.count].profile.memberID, idea, to: discussion))
        }
        record(gatewayEvent("room.activity", [
            "status": .string("bounded"), "reason_code": .string("max_messages"),
            "thread_id": .string(Self.thread), "discussion_event_id": .string(discussion.eventID),
        ]))
    }

    func groupsCapabilities() async throws -> HermesBotModeCapabilities {
        .init(
            protocolVersion: 2, driver: true, persistentProcess: true,
            authorityGatewayID: Self.gatewayID, roomLink: [:],
            features: HermesBotModeCapabilities.requiredFeatures,
            methods: HermesBotModeCapabilities.requiredOperations
                + ["groups.list", "groups.rename", "groups.context", "groups.continue"],
            maxLogLimit: 500
        )
    }

    func groupsList(offset: Int, limit: Int) async throws -> HermesBotModeRoomListPage {
        .init(rooms: offset == 0 ? [state] : [], nextOffset: nil)
    }

    func groupsState(roomID: String, includeDisbanded: Bool) async throws -> HermesBotModeRoomState {
        guard roomID == Self.roomID else { throw BotModeRoomError.roomNotFound }
        return state
    }

    func groupsLog(roomID: String, sinceSequence: Int, limit: Int, includeDisbanded: Bool) async throws -> HermesBotModeLogPage {
        guard roomID == Self.roomID else { throw BotModeRoomError.roomNotFound }
        let page = Array(events.filter { $0.sequence > sinceSequence }.prefix(limit))
        let latest = events.last?.sequence ?? 0
        return .init(events: page, cursor: page.last?.sequence ?? max(sinceSequence, 0), latestSequence: latest,
                     hasMore: (page.last?.sequence ?? latest) < latest,
                     authority: .init(gatewayID: Self.gatewayID, epoch: 1))
    }

    func groupsContext(roomID: String, intent: HermesBotModeContextIntent) async throws -> HermesBotModeRoomContext {
        guard roomID == Self.roomID else { throw BotModeRoomError.roomNotFound }
        if refusesSettings {
            throw WorkspaceClientError.rejected(code: "4125", message: .init("This Group Chat is managed by another gateway."))
        }
        let request = intent.request(roomID: roomID)
        let routing = request["routing"] ?? context["routing"] ?? .string("everyone")
        context = [
            "purpose": request["purpose"] ?? .string(""), "notes": request["notes"] ?? .string(""),
            "routing": routing,
            "lead_member_id": routing == .string("lead")
                ? request["lead_member_id"] ?? context["lead_member_id"] ?? .string("") : .string(""),
        ]
        record(HermesBotModeEvent(
            roomID: Self.roomID, sequence: nextSequence, eventID: intent.eventID, kind: "room.context_set",
            actor: ["kind": .string("system"), "id": .string("room-control")], authorityEpoch: 1,
            payload: context, createdAt: Date().timeIntervalSince1970
        ))
        return try HermesBotModeRoomContext(json: .object(context)).unwrapped()
    }

    /// Like Hermes: the paused discussion goes on for another round, then settles.
    func groupsContinue(roomID: String, discussionEventID: String) async throws -> HermesBotModeEvent {
        guard roomID == Self.roomID,
              let discussion = events.first(where: { $0.eventID == discussionEventID }) else {
            throw BotModeRoomError.roomNotFound
        }
        let continued = gatewayEvent("room.continued", [
            "discussion_event_id": .string(discussionEventID), "thread_id": .string(Self.thread), "grant": .integer(1),
        ])
        record(continued)
        record(reply("member-finance", "Let’s go with wildflowers and lanterns. It fits the budget.", to: discussion))
        record(gatewayEvent("room.activity", [
            "status": .string("settled"), "thread_id": .string(Self.thread),
            "discussion_event_id": .string(discussionEventID),
        ]))
        return continued
    }

    func groupsSend(roomID: String, eventID: String, payload: HermesBotModeUserPayload) async throws -> HermesBotModeSendResult {
        guard roomID == Self.roomID else { throw BotModeRoomError.roomNotFound }
        let user = post(payload.text, thread: payload.threadID)
        record(reply("member-home", "Got it. I’ll take that one.", to: user))
        record(gatewayEvent("room.activity", [
            "status": .string("settled"), "thread_id": .string(payload.threadID),
            "discussion_event_id": .string(user.eventID),
        ]))
        return HermesBotModeSendResult(event: user, clientEventID: eventID, accepted: true, driverStarted: true)
    }

    func groupsStop(roomID: String, cancelID: String) async throws {
        guard roomID == Self.roomID else { throw BotModeRoomError.roomNotFound }
        guard !events.contains(where: { $0.kind == "room.stop_requested" && $0.payload["cancel_id"]?.string == cancelID })
        else { return }
        record(gatewayEvent("room.stop_requested", ["cancel_id": .string(cancelID)]))
    }

    func groupsCreate(roomID: String, name: String, members: [HermesBotModeRoomMember]) async throws -> HermesBotModeRoomState {
        throw BotModeRoomError.executionUnavailable
    }

    func groupsRename(roomID: String, eventID: String, name: String) async throws -> HermesBotModeRoomState {
        throw BotModeRoomError.executionUnavailable
    }

    func groupsRetry(roomID: String, taskID: String, attempt: HermesBotModeRetryAttempt?) async throws -> HermesBotModeRetryResult {
        throw BotModeRoomError.executionUnavailable
    }

    private var state: HermesBotModeRoomState {
        .init(
            roomID: Self.roomID, name: "Garden party crew",
            members: Self.members.map { member in
                .init(memberID: member.profile.memberID, profile: member.profile, handle: member.handle,
                      displayName: member.name,
                      target: ["kind": .string("local"), "profile": .string(member.profile)])
            },
            authorityGatewayID: Self.gatewayID, authorityEpoch: 1, revision: 1,
            createdAt: 1_788_000_000, updatedAt: 1_788_000_001, latestSequence: events.last?.sequence ?? 0,
            disbandedAt: nil,
            driverStatus: [
                "running": .boolean(true), "working": .boolean(false), "pending_actions": .array([]),
                "max_rounds": .integer(3), "max_continues": .integer(5),
                "routing_modes": .array([.string("everyone"), .string("lead"), .string("auto")]),
            ],
            context: HermesBotModeRoomContext(json: .object(context))
        )
    }

    private func record(_ event: HermesBotModeEvent) { events.append(event) }

    /// The person's message, added to the log.
    private func post(_ text: String, thread: String = GroupSettingsDemoClient.thread) -> HermesBotModeEvent {
        let event = HermesBotModeEvent(
            roomID: Self.roomID, sequence: nextSequence, eventID: "user:demo-\(nextSequence)", kind: "message.user",
            actor: ["kind": .string("user"), "id": .string("desktop")], authorityEpoch: 1,
            payload: ["text": .string(text), "thread_id": .string(thread)],
            createdAt: Date().timeIntervalSince1970
        )
        record(event)
        return event
    }

    private func reply(_ memberID: String, _ text: String, to discussion: HermesBotModeEvent) -> HermesBotModeEvent {
        HermesBotModeEvent(
            roomID: Self.roomID, sequence: nextSequence, eventID: "dmessage:demo-\(nextSequence)",
            kind: "message.member",
            actor: ["kind": .string("member"), "id": .string(memberID)], authorityEpoch: 1,
            payload: ["text": .string(text), "member_id": .string(memberID),
                      "discussion_event_id": .string(discussion.eventID),
                      "thread_id": .string(discussion.threadID ?? Self.thread)],
            createdAt: Date().timeIntervalSince1970
        )
    }

    private func gatewayEvent(_ kind: String, _ payload: [String: BighelpJSONValue]) -> HermesBotModeEvent {
        HermesBotModeEvent(
            roomID: Self.roomID, sequence: nextSequence, eventID: "\(kind):demo-\(nextSequence)", kind: kind,
            actor: ["kind": .string("gateway"), "id": .string(Self.gatewayID)], authorityEpoch: 1,
            payload: payload, createdAt: Date().timeIntervalSince1970
        )
    }
}

private extension String {
    var memberID: String { "member-\(self)" }
}

private extension Optional {
    func unwrapped() throws -> Wrapped {
        guard let self else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        return self
    }
}
#endif
