import Foundation
import Testing
@testable import Bighelp

/// A team call speaks each member's reply in that member's own voice, in the
/// order the room got them, makes the next audio while the current one plays,
/// stops at once when you talk over it, and posts what you say to the room.
@MainActor
struct TeamCallTests {
    // MARK: Splitting replies

    @Test func theFirstSentenceIsSpokenOnItsOwnOnceItIsLongEnough() {
        let chunks = TeamCallSpeechSplitter.chunks(
            "The garden is free before ten. Leave by nine fifteen. Bring water.",
            firstSentenceMinimum: 20
        )
        #expect(chunks == ["The garden is free before ten.", "Leave by nine fifteen. Bring water."])
    }

    @Test func aShortOpenerRidesWithTheNextSentence() {
        let chunks = TeamCallSpeechSplitter.chunks("Sure. I'll set that aside today. Done.", firstSentenceMinimum: 20)
        #expect(chunks.first == "Sure. I'll set that aside today.")
        #expect(chunks.count == 2)
    }

    @Test func laterSentencesAreGroupedSoALongReplyIsFewRequests() {
        let sentence = "This sentence is about forty characters."
        let text = Array(repeating: sentence, count: 20).joined(separator: " ")
        let chunks = TeamCallSpeechSplitter.chunks(text, firstSentenceMinimum: 20)
        #expect(chunks.first == sentence)
        #expect(chunks.count < 6)
        #expect(chunks.dropFirst().allSatisfy { $0.count <= TeamCallSpeechSplitter.laterChunkLength })
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func aReplyWithoutSentenceEndsIsOnePiece() {
        #expect(TeamCallSpeechSplitter.chunks("ok", firstSentenceMinimum: 20) == ["ok"])
        #expect(TeamCallSpeechSplitter.chunks("  \n ", firstSentenceMinimum: 20).isEmpty)
    }

    // MARK: Hermes settings

    @Test func hermesVoiceSettingsAreHonored() {
        let settings = TeamCallVoiceSettings.resolve(configs: [
            ("finance", [
                "voice": .object([
                    "barge_in": .boolean(false),
                    "barge_in_grace_seconds": .number(0.8),
                    "barge_in_threshold_multiplier": .integer(4),
                    "silence_duration": .number(2.5),
                    "stop_phrases": .array([.string("Hang up!"), .string("goodbye")]),
                ]),
                "tts": .object(["streaming": .object(["min_len": .integer(6)])]),
            ]),
            ("home", ["voice": .object(["barge_in": .boolean(true)])]),
        ])
        #expect(settings.bargeIn == false, "The first readable member's voice settings lead the call")
        #expect(settings.bargeInGrace == .milliseconds(800))
        #expect(settings.bargeInThresholdMultiplier == 4)
        #expect(settings.silenceLimit == .milliseconds(2_500))
        #expect(settings.stopPhrases == ["hang up", "goodbye"])
        #expect(settings.firstSentenceMinimum(for: "finance") == 6)
        #expect(settings.firstSentenceMinimum(for: "home") == 20)
    }

    @Test func missingOrOddSettingsKeepHermesDefaults() {
        let settings = TeamCallVoiceSettings.resolve(configs: [
            ("finance", ["voice": .object(["barge_in": .string("maybe"), "stop_phrases": .object([:])])]),
        ])
        #expect(settings == TeamCallVoiceSettings())
        let off = TeamCallVoiceSettings.resolve(configs: [("a", ["voice": .object(["stop_phrases": .array([])])])])
        #expect(off.stopPhrases.isEmpty, "An empty list turns stop phrases off, like Hermes")
        let single = TeamCallVoiceSettings.resolve(configs: [("a", ["voice": .object(["stop_phrases": .string("Bye")])])])
        #expect(single.stopPhrases == ["bye"])
    }

    @Test func onlyTheWholeUtteranceIsAStopPhrase() {
        #expect(TeamCallStopPhrase.matches("Stop.", phrases: ["stop"]))
        #expect(TeamCallStopPhrase.matches("  stop! ", phrases: ["stop"]))
        #expect(!TeamCallStopPhrase.matches("stop doing that and try again", phrases: ["stop"]))
        #expect(!TeamCallStopPhrase.matches("stop", phrases: []))
    }

    // MARK: Pipeline

    @Test func theNextAudioIsMadeWhileTheCurrentOnePlays() async {
        let rig = PipelineRig()
        rig.pipeline.enqueue(replyID: "r1", memberID: "a", chunks: ["One.", "Two."])
        rig.pipeline.enqueue(replyID: "r2", memberID: "b", chunks: ["Three."])
        await eventually { rig.player.played.count == 1 }
        #expect(rig.player.played == ["One."])
        #expect(rig.synthesized == ["a:One.", "a:Two.", "b:Three."],
                "Later pieces, and the next member's reply, are made while the first plays")
        rig.player.finishCurrent()
        await eventually { rig.player.played.count == 2 }
        rig.player.finishCurrent()
        await eventually { rig.player.played.count == 3 }
        #expect(rig.player.played == ["One.", "Two.", "Three."])
        rig.player.finishCurrent()
        await eventually { rig.idleCount == 1 }
        #expect(!rig.pipeline.isBusy)
        #expect(rig.synthesized.count == 3, "Each piece is made once")
    }

    @Test func aSlowVoiceDoesNotLetALaterReplyJumpTheQueue() async {
        let rig = PipelineRig()
        rig.voices["a"]?.delay = .milliseconds(150)
        rig.pipeline.enqueue(replyID: "r1", memberID: "a", chunks: ["Slow first."])
        rig.pipeline.enqueue(replyID: "r2", memberID: "b", chunks: ["Fast second."])
        await eventually { rig.player.played.count == 1 }
        #expect(rig.player.played == ["Slow first."])
    }

    @Test func interruptStopsAtOnceAndDropsTheRest() async {
        let rig = PipelineRig()
        rig.pipeline.enqueue(replyID: "r1", memberID: "a", chunks: ["One.", "Two."])
        rig.pipeline.enqueue(replyID: "r2", memberID: "b", chunks: ["Three."])
        await eventually { rig.player.played.count == 1 }
        rig.pipeline.interrupt()
        #expect(rig.player.stopCount >= 1)
        #expect(!rig.pipeline.isBusy)
        await settle()
        #expect(rig.player.played == ["One."], "Nothing more plays after you cut in")
        rig.pipeline.enqueue(replyID: "r3", memberID: "b", chunks: ["Fresh."])
        await eventually { rig.player.played.count == 2 }
        #expect(rig.player.played.last == "Fresh.")
    }

    @Test func aVoiceThatFailsSkipsToTheNextReply() async {
        let rig = PipelineRig()
        rig.voices["a"]?.fails = true
        var failed: [String] = []
        rig.pipeline.onFailure = { failed.append($0.text) }
        rig.pipeline.enqueue(replyID: "r1", memberID: "a", chunks: ["Broken."])
        rig.pipeline.enqueue(replyID: "r2", memberID: "b", chunks: ["Works."])
        await eventually { rig.player.played.count == 1 }
        #expect(failed == ["Broken."])
        #expect(rig.player.played == ["Works."])
    }

    // MARK: The call

    @Test func membersRepliesAreSpokenInOrderInTheirOwnVoices() async {
        let rig = CallRig()
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        rig.link.reply(from: "member-a", "Picnic first. Then a film in the park.")
        rig.link.reply(from: "member-b", "I'll pack the sandwiches tonight.")
        await eventually { rig.player.played.count == 1 }
        #expect(rig.model.speakingMemberID == "member-a")
        #expect(rig.model.caption?.text == "Picnic first. Then a film in the park.")
        rig.player.finishCurrent()
        await eventually { rig.player.played.count == 2 }
        #expect(rig.model.speakingMemberID == "member-b")
        rig.player.finishCurrent()
        await eventually { rig.model.speakingMemberID == nil }
        #expect(rig.player.played == ["Picnic first. Then a film in the park.", "I'll pack the sandwiches tonight."])
        #expect(rig.synthesized.allSatisfy { $0.hasPrefix("alpha:") || $0.hasPrefix("beta:") })
        #expect(rig.synthesized.first == "alpha:Picnic first. Then a film in the park.")
        #expect(rig.synthesized.last == "beta:I'll pack the sandwiches tonight.")
        #expect(rig.model.lines.map(\.speaker) == ["Avery", "Jordan"])
    }

    @Test func anAgentOnAnotherComputerSpeaksWithItsOwnVoiceNotTheLocalSameProfiles() async {
        // Both are each computer's "default" profile.
        let rig = CallRig(members: [
            .init(id: "default", profileID: "default", name: "Lab agent", imageURL: nil),
            .init(id: "default-desk", profileID: "default", name: "Desk agent", imageURL: nil,
                  voiceKey: TeamCallPeerVoices.key(peerID: "desk", profileID: "default")),
        ])
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        rig.link.reply(from: "default", "Hello from the lab.")
        rig.link.reply(from: "default-desk", "Hello from the desk.")
        await eventually { rig.player.played.count == 1 }
        rig.player.finishCurrent()
        await eventually { rig.player.played.count == 2 }
        rig.player.finishCurrent()
        #expect(rig.synthesized == ["default:Hello from the lab.", "desk/default:Hello from the desk."])
        #expect(rig.model.lines.map(\.speaker) == ["Lab agent", "Desk agent"])
    }

    @Test func repliesFromBeforeTheCallAreNotReadOut() async {
        let rig = CallRig()
        rig.link.reply(from: "member-a", "Old news.", notify: false)
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        rig.link.reply(from: "member-b", "New.")
        await eventually { rig.player.played.count == 1 }
        #expect(rig.player.played == ["New."])
    }

    @Test func passesAndSilentRepliesAreNotSpoken() async {
        let rig = CallRig()
        rig.model.start()
        rig.link.reply(from: "member-a", "[SILENT]")
        rig.link.reply(from: "member-b", "Here.")
        await eventually { rig.player.played.count == 1 }
        #expect(rig.player.played == ["Here."])
    }

    @Test func whatYouSayPostsToTheRoomAndTheMicListensAgain() async {
        let rig = CallRig()
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        await eventually { rig.input.isRunning }
        #expect(rig.input.endsAfterSilence, "Your turn ends when you pause")
        rig.input.say("What should we do on Saturday", final: false)
        #expect(rig.model.activity == .hearingYou)
        rig.input.say("What should we do on Saturday?", final: true)
        await eventually { rig.link.sent == ["What should we do on Saturday?"] }
        await eventually { rig.input.isRunning }
        #expect(rig.input.startCount == 2, "Hands-free: listening starts again right away")
        #expect(rig.model.lines.last?.speaker == "You")
    }

    @Test func talkingOverAReplyStopsItAndSendsWhatYouSaid() async {
        let rig = CallRig()
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        rig.link.reply(from: "member-a", "Here is a long plan for the whole weekend with many steps.")
        rig.link.reply(from: "member-b", "And here is mine.")
        await eventually { rig.player.played.count == 1 }
        await eventually { rig.input.isRunning && !rig.input.endsAfterSilence }
        rig.clock.advance(by: .seconds(1))
        rig.input.level(0.5, times: 10)
        rig.input.say("wait actually", final: false)
        rig.input.say("wait actually let's stay home", final: false)
        #expect(rig.player.stopCount >= 1, "The voice stops the moment you cut in")
        #expect(rig.model.speakingMemberID == nil)
        #expect(rig.model.activity == .hearingYou)
        rig.input.say("Wait, actually let's stay home.", final: true)
        await eventually { rig.link.sent == ["Wait, actually let's stay home."] }
        await settle()
        #expect(rig.player.played.count == 1, "The rest of the queued replies are dropped")
    }

    @Test func theReplysOwnEchoDoesNotInterrupt() async {
        let rig = CallRig()
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        rig.link.reply(from: "member-a", "The botanical garden is free before ten.")
        await eventually { rig.player.played.count == 1 }
        await eventually { rig.input.isRunning && !rig.input.endsAfterSilence }
        rig.clock.advance(by: .seconds(1))
        rig.input.level(0.5, times: 10)
        rig.input.say("the botanical", final: false)
        rig.input.say("the botanical garden is free", final: false)
        #expect(rig.player.stopCount == 0)
        #expect(rig.model.speakingMemberID == "member-a")
    }

    @Test func afterAnEchoFinishesTheMicKeepsListeningForYou() async {
        let rig = CallRig()
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        rig.link.reply(from: "member-a", "The botanical garden is free before ten.")
        await eventually { rig.player.played.count == 1 }
        await eventually { rig.input.isRunning && !rig.input.endsAfterSilence }
        let starts = rig.input.startCount
        // Apple's recognizer ends its session with a final result.
        rig.input.say("the botanical garden is free before ten", final: true)
        await eventually { rig.input.startCount == starts + 1 && rig.input.isRunning }
        #expect(rig.player.stopCount == 0)
        #expect(!rig.input.endsAfterSilence)
    }

    @Test func soundRightAfterAReplyStartsDoesNotCountDuringTheGrace() async {
        let rig = CallRig()
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        rig.link.reply(from: "member-a", "Here is a long plan for the whole weekend.")
        await eventually { rig.player.played.count == 1 }
        await eventually { rig.input.isRunning && !rig.input.endsAfterSilence }
        rig.input.level(0.5, times: 10)
        rig.input.say("wait actually", final: false)
        rig.input.say("wait actually let's stay home", final: false)
        #expect(rig.player.stopCount == 0, "Within voice.barge_in_grace_seconds the room's sound is ignored")
    }

    @Test func withBargeInOffTheMicrophoneRestsWhileAMemberTalks() async {
        var settings = TeamCallVoiceSettings()
        settings.bargeIn = false
        let rig = CallRig(settings: settings)
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        await eventually { rig.input.isRunning }
        rig.link.reply(from: "member-a", "One thing.")
        await eventually { rig.player.played.count == 1 }
        await eventually { !rig.input.isRunning }
        rig.player.finishCurrent()
        await eventually { rig.input.isRunning }
        #expect(rig.input.endsAfterSilence, "Your turn again once the reply ends")
    }

    @Test func repliesWaitWhileYouAreTalking() async {
        let rig = CallRig()
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        await eventually { rig.input.isRunning }
        rig.input.say("I was thinking", final: false)
        rig.link.reply(from: "member-a", "Okay.")
        await settle()
        #expect(rig.player.played.isEmpty, "A reply doesn't talk over you")
        rig.input.say("I was thinking about Sunday.", final: true)
        await eventually { rig.player.played == ["Okay."] }
        #expect(rig.link.sent == ["I was thinking about Sunday."])
    }

    @Test func aStopPhraseEndsTheCallWithoutSendingIt() async {
        var ended = 0
        let rig = CallRig(onEnded: { ended += 1 })
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        await eventually { rig.input.isRunning }
        rig.input.say("Stop.", final: true)
        #expect(rig.model.activity == .ended)
        #expect(ended == 1)
        #expect(rig.link.sent.isEmpty)
        #expect(!rig.input.isRunning)
    }

    @Test func aBusyRoomGetsTheNextMessageOnceItSettles() async {
        let rig = CallRig()
        rig.link.rejectsWhileWorking = true
        rig.link.isWorking = true
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        await eventually { rig.input.isRunning }
        rig.input.say("Add ice cream too.", final: true)
        await eventually { rig.link.attempts == 1 }
        await settle()
        #expect(rig.link.sent.isEmpty)
        rig.link.isWorking = false
        rig.link.notify()
        await eventually { rig.link.sent == ["Add ice cream too."] }
    }

    @Test func messagesGoOutInTheOrderYouSaidThem() async {
        let rig = CallRig()
        rig.link.holdsSends = true
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        await eventually { rig.input.isRunning }
        rig.input.say("First thing.", final: true)
        await eventually { rig.link.attempts == 1 && rig.input.isRunning }
        rig.input.say("Second thing.", final: true)
        await settle()
        #expect(rig.link.attempts == 1, "The second waits until the room has the first")
        rig.link.admitHeldSend()
        await eventually { rig.link.attempts == 2 }
        rig.link.admitHeldSend()
        await eventually { rig.link.sent == ["First thing.", "Second thing."] }
    }

    @Test func anEarlierSendFailingLaterDoesNotBlameTheNextOne() async {
        let rig = CallRig()
        rig.link.holdsSends = true
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        await eventually { rig.input.isRunning }
        rig.input.say("First thing.", final: true)
        await eventually { rig.link.attempts == 1 && rig.input.isRunning }
        // Hermes has the first message; its round is still going.
        rig.link.landHeldMessage()
        rig.input.say("Second thing.", final: true)
        await eventually { rig.link.attempts == 2 }
        rig.link.failFirstHeldSend()
        await settle()
        #expect(rig.model.errorMessage == nil, "The first message reached the room before its round failed")
        rig.link.admitHeldSend()
        await eventually { rig.link.sent.contains("Second thing.") }
    }

    @Test func mutingStopsListeningAndUnmutingResumes() async {
        let rig = CallRig()
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        await eventually { rig.input.isRunning }
        rig.model.toggleMicrophone()
        #expect(!rig.input.isRunning)
        #expect(rig.model.activity == .muted)
        rig.model.toggleMicrophone()
        await eventually { rig.input.isRunning }
    }

    @Test func endingTheCallStopsTheVoiceButNotTheRoom() async {
        let rig = CallRig()
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        rig.link.reply(from: "member-a", "Talking now.")
        await eventually { rig.player.played.count == 1 }
        rig.model.end()
        #expect(rig.player.stopCount >= 1)
        #expect(!rig.input.isRunning)
        #expect(!rig.link.isObserving)
        #expect(rig.link.stopRequests == 0, "Hanging up never stops the agents' work")
    }

    @Test func hermesSettingsLoadedAfterStartApply() async {
        var loaded = TeamCallVoiceSettings()
        loaded.silenceLimit = .seconds(2)
        loaded.stopPhrases = ["goodbye"]
        let rig = CallRig(loadSettings: { loaded })
        rig.model.start()
        rig.model.setMicrophoneAllowed(true)
        await eventually { rig.model.settings.stopPhrases == ["goodbye"] }
        await eventually { rig.input.isRunning }
        #expect(rig.input.silenceLimit == .seconds(2))
        #expect(rig.model.stopHint == "Say \u{201C}goodbye\u{201D} to hang up.")
        rig.input.say("stop", final: true)
        await eventually { rig.link.sent == ["stop"] }
        #expect(rig.model.activity != .ended)
    }

    @Test func theDemoRoomAnswersWithFinishedMessagesOneAfterAnother() async throws {
        let client = TeamCallDemoGroupsClient()
        let before = try await client.groupsLog(roomID: TeamCallDemoGroupsClient.roomID, sinceSequence: 0,
                                                limit: 50, includeDisbanded: false)
        let result = try await client.groupsSend(
            roomID: TeamCallDemoGroupsClient.roomID, eventID: "bot-user-1",
            payload: HermesBotModeUserPayload(text: "Ideas?", threadID: "loopdy-team-call-demo")
        )
        #expect(result.accepted)
        var members: [String] = []
        var cursor = before.cursor
        for _ in 0..<6 {
            let page = try await client.groupsLog(roomID: TeamCallDemoGroupsClient.roomID, sinceSequence: cursor,
                                                  limit: 50, includeDisbanded: false)
            members += page.events.filter { $0.kind == "message.member" }.compactMap { $0.payload["member_id"]?.string }
            cursor = page.cursor
        }
        #expect(members == ["member-finance", "member-home", "member-travel"])
    }
}

// MARK: - Fakes

@MainActor
private func eventually(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out", sourceLocation: sourceLocation)
}

@MainActor
private func settle() async {
    for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
private final class FakeVoice: TeamCallVoice {
    let name: String
    var delay: Duration = .zero
    var fails = false
    private let log: (String) -> Void

    init(name: String, log: @escaping (String) -> Void) {
        self.name = name
        self.log = log
    }

    func synthesize(_ text: String) async throws -> TeamCallAudio {
        log("\(name):\(text)")
        if delay > .zero { try await Task.sleep(for: delay) }
        if fails { throw VoiceSessionError.emptyResponse }
        return TeamCallAudio(data: Data(text.utf8), mimeType: "audio/mpeg")
    }
}

/// Plays until told to finish, like a real clip; `stop()` cuts it off.
@MainActor
private final class FakePlayer: TeamCallAudioPlayer {
    private(set) var played: [String] = []
    private(set) var stopCount = 0
    private var current: CheckedContinuation<Void, any Error>?

    func play(_ audio: TeamCallAudio, onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        played.append(String(decoding: audio.data, as: UTF8.self))
        onPlayback(.started)
        onPlayback(.level(0.4))
        try await withCheckedThrowingContinuation { continuation in
            current = continuation
        }
        onPlayback(.finished)
    }

    func finishCurrent() {
        let pending = current
        current = nil
        pending?.resume()
    }

    func stop() {
        stopCount += 1
        let pending = current
        current = nil
        pending?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class PipelineRig {
    let player = FakePlayer()
    var synthesized: [String] = []
    var voices: [String: FakeVoice] = [:]
    var idleCount = 0
    var pipeline: TeamCallSpeechPipeline!

    init() {
        for name in ["a", "b"] {
            voices[name] = FakeVoice(name: name) { [unowned self] in self.synthesized.append($0) }
        }
        pipeline = TeamCallSpeechPipeline(player: player) { [unowned self] in self.voices[$0] }
        pipeline.onIdle = { [unowned self] in self.idleCount += 1 }
    }
}

/// A hosted room as the call sees it: your message lands in the log, and
/// members' replies arrive later as finished messages.
@MainActor
private final class FakeRoomLink: TeamCallRoomLink {
    private(set) var events: [TeamCallRoomEvent] = []
    var isWorking = false
    var rejectsWhileWorking = false
    var holdsSends = false
    private(set) var sent: [String] = []
    private(set) var attempts = 0
    private(set) var stopRequests = 0
    private var onChange: (@MainActor () -> Void)?
    private var held: [(text: String, landed: Bool, continuation: CheckedContinuation<Void, any Error>)] = []
    private var counter = 0

    var isObserving: Bool { onChange != nil }

    func send(_ text: String) async throws {
        attempts += 1
        if rejectsWhileWorking, isWorking { throw BotModeRoomError.runAlreadyActive }
        if holdsSends {
            try await withCheckedThrowingContinuation { continuation in
                held.append((text, false, continuation))
            }
            return
        }
        land(text)
    }

    /// Hermes takes the oldest held message and finishes its round.
    func admitHeldSend() {
        guard !held.isEmpty else { return }
        let next = held.removeFirst()
        if !next.landed { land(next.text) }
        next.continuation.resume()
    }

    /// The oldest held message shows in the room; its round keeps going.
    func landHeldMessage() {
        guard let index = held.firstIndex(where: { !$0.landed }) else { return }
        held[index].landed = true
        land(held[index].text)
    }

    func failFirstHeldSend() {
        guard !held.isEmpty else { return }
        held.removeFirst().continuation.resume(throwing: BotModeRoomError.nativeSendRejected)
    }

    func reply(from memberID: String, _ text: String, notify: Bool = true) {
        counter += 1
        events.append(TeamCallRoomEvent(id: "event-\(counter)", memberID: memberID, text: text))
        if notify { self.notify() }
    }

    func notify() {
        onChange?()
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func stopObserving() {
        onChange = nil
    }

    private func land(_ text: String) {
        sent.append(text)
        counter += 1
        events.append(TeamCallRoomEvent(id: "event-\(counter)", memberID: nil, text: text))
        notify()
    }
}

@MainActor
private final class FakeInput: VoiceInputLevelSource {
    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?
    var onTranscribing: ((Bool, UInt64) -> Void)?
    var endsAfterSilence = true
    var transcription: VoiceTranscriptionSource = .onDevice
    var hostTranscriber: (@MainActor (Data) async throws -> String)?
    var silenceLimit: Duration?
    private(set) var isRunning = false
    private(set) var startCount = 0
    private var generation: UInt64 = 0

    func start(generation: UInt64) async throws {
        self.generation = generation
        isRunning = true
        startCount += 1
    }

    func stop() {
        isRunning = false
    }

    func say(_ text: String, final: Bool) {
        guard isRunning else { return }
        onTranscript?(VoiceRecognitionUpdate(text: text, isFinal: final), generation)
    }

    func level(_ value: Float, times: Int) {
        guard isRunning else { return }
        for _ in 0..<times { onLevel?(value, generation) }
    }
}

private final class TestClock: @unchecked Sendable {
    private(set) var now = ContinuousClock.now

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
    }
}

@MainActor
private final class CallRig {
    let link = FakeRoomLink()
    let player = FakePlayer()
    let input = FakeInput()
    let clock = TestClock()
    var synthesized: [String] = []
    var model: TeamCallModel!

    init(
        members: [TeamCallModel.Member] = [
            .init(id: "member-a", profileID: "alpha", name: "Avery", imageURL: nil),
            .init(id: "member-b", profileID: "beta", name: "Jordan", imageURL: nil),
        ],
        settings: TeamCallVoiceSettings = .init(),
        loadSettings: @escaping @MainActor () async -> TeamCallVoiceSettings? = { nil },
        onEnded: @escaping @MainActor () -> Void = {}
    ) {
        let clock = clock
        model = TeamCallModel(
            title: "Weekend planners",
            members: members,
            link: link,
            voice: { [unowned self] profileID in
                FakeVoice(name: profileID) { [unowned self] in self.synthesized.append($0) }
            },
            player: player,
            input: input,
            settings: settings,
            loadSettings: loadSettings,
            now: { clock.now },
            onEnded: onEnded
        )
    }
}
