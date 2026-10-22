#if DEBUG
import Foundation

/// Demo team calls (`-use-demo-fixtures`): canned voices, a microphone that
/// asks one question, and (`-preview-team-call`) a hosted room whose members
/// answer like a real Hermes room does, as finished messages one after another.
@MainActor
final class TeamCallDemoServices: TeamCallServices {
    var usesDeviceMicrophone: Bool { false }
    func supportsVoice(profileIDs: [String]) -> Bool { !profileIDs.isEmpty }
    func makeVoice(profileID: String) -> (any TeamCallVoice)? { TeamCallDemoVoice() }
    func makePlayer() -> any TeamCallAudioPlayer { TeamCallDemoPlayer() }
    func makeInput() -> any VoiceInputLevelSource { TeamCallDemoInput() }
    func makeTranscriber(profileID: String) -> (@MainActor (Data) async throws -> String)? { nil }
    func loadSettings(profileIDs: [String]) async -> TeamCallVoiceSettings? { nil }
}

/// "Synthesizes" by handing the words back; the demo player times them.
@MainActor
final class TeamCallDemoVoice: TeamCallVoice {
    func synthesize(_ text: String) async throws -> TeamCallAudio {
        try await Task.sleep(for: .milliseconds(150))
        return TeamCallAudio(data: Data(text.utf8), mimeType: "audio/x-bighelp-demo")
    }
}

/// Plays nothing aloud: reports a speaking level for as long as the words
/// would take to say.
@MainActor
final class TeamCallDemoPlayer: TeamCallAudioPlayer {
    private var generation: UInt64 = 0

    func play(_ audio: TeamCallAudio, onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        generation &+= 1
        let owned = generation
        let words = String(decoding: audio.data, as: UTF8.self)
        let duration = min(max(Double(words.count) * 0.045, 1.2), 5)
        onPlayback(.started)
        var elapsed = 0.0
        while elapsed < duration {
            try await Task.sleep(for: .milliseconds(80))
            guard owned == generation else { throw CancellationError() }
            elapsed += 0.08
            onPlayback(.level(0.35 + 0.3 * abs(sin(elapsed * 7))))
        }
        onPlayback(.finished)
    }

    func stop() {
        generation &+= 1
    }
}

/// Hears one question at the start of the call, then quiet.
@MainActor
final class TeamCallDemoInput: VoiceInputLevelSource {
    static let question = "Can you each give me one idea for Saturday?"

    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?
    var endsAfterSilence = true
    private var generation: UInt64 = 0
    private var hasAsked = false

    func start(generation: UInt64) async throws {
        self.generation = generation
        guard endsAfterSilence, !hasAsked else { return }
        hasAsked = true
        Task { @MainActor [weak self] in
            for (delay, words) in [(900, "Can you each"), (500, "Can you each give me one idea")] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, self.generation == generation else { return }
                self.onLevel?(0.32, generation)
                self.onTranscript?(.init(text: words, isFinal: false), generation)
            }
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.generation == generation else { return }
            self.onTranscript?(.init(text: Self.question, isFinal: true), generation)
        }
    }

    func stop() {
        generation &+= 1
    }
}

/// A hosted room that takes messages and has its members answer them.
@MainActor
final class TeamCallDemoGroupsClient: HermesBotModeCatalogClient {
    static let launchArgument = "-preview-team-call"
    /// The first message's answers wait until the room is stopped, and the
    /// first Stop's answer is lost before it reaches the room, so the chat
    /// shows Stop again.
    static let losesFirstStopArgument = "-preview-group-stop-lost"
    static let roomID = "team-call-demo"
    private static let gatewayID = "fixture-gateway"
    private static let members: [(profile: String, handle: String, name: String)] = [
        ("finance", "avery", "Avery Park"), ("home", "jordan", "Jordan Lee"), ("travel", "mina", "Mina Shah"),
    ]
    private static let rounds: [[String]] = [
        [
            "Keep it under eighty dollars and you can do a picnic and the evening film in the park. I'll set that aside today.",
            "I'll make sandwiches and lemonade on Friday night, so Saturday morning is easy. Want me to add it to the list?",
            "The botanical garden is free before ten. Leave by nine fifteen and you'll beat the crowds.",
        ],
        [
            "Sounds good to me. I'll keep an eye on the budget.",
            "Done. It's on the list.",
            "I'll send directions in the morning.",
        ],
    ]

    private var events: [HermesBotModeEvent]
    private var scheduled: [HermesBotModeEvent] = []
    private var round = 0
    private var nextSequence: Int { (events.last?.sequence ?? 0) + 1 }
    private var holdsAnswersUntilStopped: Bool
    private var losesNextStop: Bool

    init(losesFirstStop: Bool = false) {
        holdsAnswersUntilStopped = losesFirstStop
        losesNextStop = losesFirstStop
        events = []
        events = [
            event(kind: "message.user", text: "Let's plan a relaxed Saturday for all of us.", member: nil, sequence: 1),
            event(kind: "message.member", text: "Happy to help. Tell us what you have in mind.",
                  member: "member-home", sequence: 2),
        ]
    }

    func groupsCapabilities() async throws -> HermesBotModeCapabilities {
        .init(
            protocolVersion: 2, driver: true, persistentProcess: true,
            authorityGatewayID: Self.gatewayID, roomLink: [:],
            features: HermesBotModeCapabilities.requiredFeatures,
            methods: HermesBotModeCapabilities.requiredOperations + ["groups.list", "groups.rename"],
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
        // Members finish one at a time: each read lets the next answer land.
        if !scheduled.isEmpty, !holdsAnswersUntilStopped { events.append(scheduled.removeFirst()) }
        let page = Array(events.filter { $0.sequence > sinceSequence }.prefix(limit))
        let latest = events.last?.sequence ?? 0
        return .init(events: page, cursor: page.last?.sequence ?? max(sinceSequence, 0), latestSequence: latest,
                     hasMore: (page.last?.sequence ?? latest) < latest,
                     authority: .init(gatewayID: Self.gatewayID, epoch: 1))
    }

    func groupsSend(roomID: String, eventID: String, payload: HermesBotModeUserPayload) async throws -> HermesBotModeSendResult {
        guard roomID == Self.roomID else { throw BotModeRoomError.roomNotFound }
        let user = event(kind: "message.user", text: payload.text, member: nil, thread: payload.threadID)
        events.append(user)
        let replies = Self.rounds[min(round, Self.rounds.count - 1)]
        round += 1
        var sequence = user.sequence
        scheduled = zip(Self.members, replies).map { member, reply in
            sequence += 1
            return event(kind: "message.member", text: reply, member: "member-\(member.profile)",
                         thread: payload.threadID, discussion: user.eventID, sequence: sequence)
        }
        sequence += 1
        scheduled.append(HermesBotModeEvent(
            roomID: Self.roomID, sequence: sequence, eventID: "demo-settled-\(sequence)", kind: "room.activity",
            actor: ["kind": .string("driver")], authorityEpoch: 1,
            payload: ["status": .string("settled"), "discussion_event_id": .string(user.eventID),
                      "thread_id": .string(payload.threadID)],
            createdAt: Date().timeIntervalSince1970
        ))
        return HermesBotModeSendResult(event: user, clientEventID: eventID, accepted: true, driverStarted: true)
    }

    func groupsCreate(roomID: String, name: String, members: [HermesBotModeRoomMember]) async throws -> HermesBotModeRoomState {
        throw BotModeRoomError.executionUnavailable
    }

    func groupsRename(roomID: String, eventID: String, name: String) async throws -> HermesBotModeRoomState {
        throw BotModeRoomError.executionUnavailable
    }

    /// Like Hermes: one `room.stop_requested` per cancel ID, then the
    /// members' work ends.
    func groupsStop(roomID: String, cancelID: String) async throws {
        guard roomID == Self.roomID else { throw BotModeRoomError.roomNotFound }
        if losesNextStop {
            losesNextStop = false
            throw WorkspaceClientError.transportUnavailable
        }
        holdsAnswersUntilStopped = false
        scheduled.removeAll()
        guard !events.contains(where: { $0.kind == "room.stop_requested" && $0.payload["cancel_id"]?.string == cancelID })
        else { return }
        events.append(HermesBotModeEvent(
            roomID: Self.roomID, sequence: nextSequence, eventID: "demo-stop-\(nextSequence)",
            kind: "room.stop_requested", actor: ["kind": .string("gateway"), "id": .string(Self.gatewayID)],
            authorityEpoch: 1, payload: ["cancel_id": .string(cancelID)], createdAt: Date().timeIntervalSince1970
        ))
    }

    func groupsRetry(roomID: String, taskID: String) async throws -> HermesBotModeRetryResult {
        throw BotModeRoomError.executionUnavailable
    }

    private var state: HermesBotModeRoomState {
        .init(
            roomID: Self.roomID, name: "Weekend planners",
            members: Self.members.map { member in
                .init(memberID: "member-\(member.profile)", profile: member.profile, handle: member.handle,
                      displayName: member.name,
                      target: ["kind": .string("local"), "profile": .string(member.profile)])
            },
            authorityGatewayID: Self.gatewayID, authorityEpoch: 1, revision: 1,
            createdAt: 1_788_000_000, updatedAt: 1_788_000_001, latestSequence: events.last?.sequence ?? 0,
            disbandedAt: nil, driverStatus: ["working": .boolean(!scheduled.isEmpty)]
        )
    }

    private func event(
        kind: String, text: String, member: String?, thread: String = "loopdy-team-call-demo",
        discussion: String? = nil, sequence: Int? = nil
    ) -> HermesBotModeEvent {
        let sequence = sequence ?? nextSequence
        var payload: [String: BighelpJSONValue] = ["text": .string(text), "thread_id": .string(thread)]
        if let member { payload["member_id"] = .string(member) }
        if let discussion { payload["discussion_event_id"] = .string(discussion) }
        return HermesBotModeEvent(
            roomID: Self.roomID, sequence: sequence, eventID: "demo-event-\(sequence)", kind: kind,
            actor: member.map { ["member_id": .string($0)] } ?? ["kind": .string("user")],
            authorityEpoch: 1, payload: payload, createdAt: Date().timeIntervalSince1970
        )
    }
}
#endif
