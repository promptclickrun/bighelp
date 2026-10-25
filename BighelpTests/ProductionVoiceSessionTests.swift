import AVFoundation
import Foundation
import Speech
import Testing
@testable import Bighelp

@MainActor
struct ProductionVoiceSessionTests {
    @Test func steeringCompletionCannotReopenMicrophoneAfterVoiceBecomesInactive() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture()
        let model = VoiceModel(conversationID: "voice-background-steer", status: .working,
                               client: client, inputLevelSource: source)
        await model.startMonitoring()
        #expect(source.startCount == 1)
        #expect(model.submitTranscript("Change direction"))
        model.setMonitoringAllowed(false)
        for _ in 0..<30 { await Task.yield() }
        #expect(client.steeringRequests == ["Change direction"])
        #expect(source.startCount == 1)
        #expect(model.meterState == .idle)
        #expect(!model.allowsInputMonitoring)
    }

    @Test func heldSpeechSteersTheTurnStartedInsideVoiceWithoutReplacingIt() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture()
        let model = VoiceModel(conversationID: "voice-local-steer", mode: .walkieTalkie,
                               client: client, inputLevelSource: source)
        model.toggleAgentAudio()
        #expect(model.submitTranscript("Original work"))
        await client.waitUntilRequested()
        #expect(await model.beginWalkieTalkieCapture())
        source.emit(.init(text: "Use the second option", isFinal: false))
        #expect(model.endWalkieTalkieCapture(submit: true))
        for _ in 0..<30 { await Task.yield() }
        #expect(client.steeringRequests == ["Use the second option"])
        #expect(client.requests == ["Original work"])
        #expect(model.isAgentRunActive)
        client.completeReply(speaker: "Avery", text: "Completed the original work with your guidance.")
        await model.waitUntilTurnSettles()
        #expect(!model.isAgentRunActive)
    }

    @Test func sustainedRecognizedSpeechTriggersBargeInOnlyAfterProgression() {
        let detector = VoiceBargeInDetector()
        detector.begin(spokenText: "Here is the answer I was giving you")

        for _ in 0..<7 { detector.receiveLevel(0.3) }
        #expect(!detector.receiveTranscript("Hold on", isFinal: false))

        for _ in 0..<2 { detector.receiveLevel(0.3) }
        #expect(detector.receiveTranscript("Hold on please", isFinal: false))
    }

    /// The louder reply leaking back into the microphone isn't you talking.
    @Test func quietSpeakerLeakDoesNotOpenBargeIn() {
        let detector = VoiceBargeInDetector()
        detector.begin(spokenText: "Here is the answer I was giving you")
        for _ in 0..<12 { detector.receiveLevel(0.16) }
        #expect(!detector.receiveTranscript("wait a second", isFinal: true))
    }

    @Test func agentSpeechEchoDoesNotTriggerBargeIn() {
        let detector = VoiceBargeInDetector()
        detector.begin(spokenText: "Here is the answer I was giving you")
        for _ in 0..<12 { detector.receiveLevel(0.3) }

        #expect(!detector.receiveTranscript("Here is", isFinal: false))
        #expect(!detector.receiveTranscript("Here is the answer", isFinal: false))
    }

    @Test func slightlyMistranscribedAgentEchoDoesNotTriggerBargeIn() {
        let detector = VoiceBargeInDetector()
        detector.begin(spokenText: "First review the budget and prepare the notes")
        for _ in 0..<12 { detector.receiveLevel(0.3) }

        #expect(!detector.receiveTranscript("First review a budget", isFinal: false))
        #expect(!detector.receiveTranscript("First review a budget and prepare", isFinal: false))
    }

    @Test func sustainedFinalOnlySpeechCanTriggerBargeIn() {
        let detector = VoiceBargeInDetector()
        detector.begin(spokenText: "Here is the answer I was giving you")
        for _ in 0..<10 { detector.receiveLevel(0.3) }

        #expect(detector.receiveTranscript("Stop now", isFinal: true))
    }

    @Test func recognizedSpeechFinishesAfterNaturalSilence() {
        var endOfSpeechCount = 0
        let detector = VoiceEndOfSpeechDetector(
            baseSilence: .seconds(1.5),
            onEndOfSpeech: { endOfSpeechCount += 1 }
        )

        detector.receiveTranscript(.init(text: "What should I focus on?", isFinal: false))
        detector.receiveLevel(0.01, duration: .seconds(1))
        #expect(endOfSpeechCount == 0)

        detector.receiveLevel(0.01, duration: .seconds(0.5))

        #expect(endOfSpeechCount == 1)
    }

    @Test func renewedSpeechActivityPreventsPrematureFinish() {
        var endOfSpeechCount = 0
        let detector = VoiceEndOfSpeechDetector(
            baseSilence: .seconds(1.5),
            onEndOfSpeech: { endOfSpeechCount += 1 }
        )

        detector.receiveTranscript(.init(text: "Give me", isFinal: false))
        detector.receiveLevel(0.01, duration: .seconds(1))
        detector.receiveLevel(0.4, duration: .milliseconds(100))
        detector.receiveLevel(0.01, duration: .seconds(1))
        #expect(endOfSpeechCount == 0)

        // Talking longer earns a little more quiet before the turn ends.
        detector.receiveLevel(0.01, duration: .seconds(0.6))
        #expect(endOfSpeechCount == 1)
    }

    @Test func stoppingRecognitionCancelsPendingEndOfSpeech() {
        var endOfSpeechCount = 0
        let detector = VoiceEndOfSpeechDetector(
            baseSilence: .seconds(1.5),
            onEndOfSpeech: { endOfSpeechCount += 1 }
        )

        detector.receiveTranscript(.init(text: "Do not send this", isFinal: false))
        detector.receiveLevel(0.01, duration: .seconds(1))
        detector.reset()
        detector.receiveLevel(0.01, duration: .seconds(1))

        #expect(endOfSpeechCount == 0)
    }

    @Test func audioTapCallbackAcceptsBuffersFromAVFAudioQueue() async {
        let source = AVAudioEngineVoiceInputLevelSource()
        let request = SFSpeechAudioBufferRecognitionRequest()
        let generation: UInt64 = 47

        let received = await withCheckedContinuation { continuation in
            source.onLevel = { level, callbackGeneration in
                continuation.resume(returning: (level, callbackGeneration))
            }
            source.openForTesting(request: request)
            let callback = AVAudioEngineVoiceInputLevelSource.makeTapCallback(
                generation: generation,
                source: source
            )
            AudioTapInvocation(callback: callback).invokeOffMain()
        }

        #expect(received.0 > 0)
        #expect(received.1 == generation)
    }

    @Test func authorizationBridgeAcceptsBackgroundSystemCompletion() async {
        let granted = await VoiceAuthorizationBridge.value { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                completion(true)
            }
        }

        #expect(granted)
    }

    @Test func finalSpeechRunsOneHermesTurnAndReturnsToListeningAfterPlayback() async throws {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture()
        let model = VoiceModel(
            conversationID: "conversation_voice_0001",
            agentName: "Avery",
            client: client,
            inputLevelSource: source
        )

        await model.startMonitoring()
        source.emit(.init(text: "What should I focus on?", isFinal: true))
        await client.waitUntilRequested()

        #expect(model.status == .working)
        #expect(model.transcriptRows.last?.speaker == "You")
        #expect(model.transcriptRows.last?.text == "What should I focus on?")
        #expect(client.requests == ["What should I focus on?"])

        client.emitDraft("Review the")
        #expect(model.liveAgentTranscript == "Review the")
        client.completeReply(speaker: "Avery", text: "Review the budget first.")
        await client.waitUntilSpeaking()

        #expect(model.status == .speaking)
        #expect(model.transcriptRows.last?.speaker == "Avery")
        #expect(model.transcriptRows.last?.text == "Review the budget first.")

        client.completeSpeech()
        await model.waitUntilTurnSettles()
        #expect(model.status == .listening)
        #expect(model.liveAgentTranscript == nil)
    }

    @Test func speakingResponseKeepsMicrophoneReadyForBargeIn() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture()
        let model = VoiceModel(
            conversationID: "conversation_voice_barge_in_monitoring",
            client: client,
            inputLevelSource: source
        )

        await model.startMonitoring()
        source.emit(.init(text: "Tell me the plan", isFinal: true))
        await client.waitUntilRequested()
        client.completeReply(speaker: "Avery", text: "First, review the budget.")
        await client.waitUntilSpeaking()

        await model.startMonitoring()

        #expect(model.status == .speaking)
        #expect(model.meterState == .monitoring)
        #expect(source.startCount == 2)
    }

    @Test func finalizedAgentEchoRestartsBargeInRecognitionWithoutStoppingPlayback() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture()
        let model = VoiceModel(
            conversationID: "conversation_voice_barge_in_echo_restart",
            client: client,
            inputLevelSource: source
        )

        await model.startMonitoring()
        source.emit(.init(text: "Tell me the plan", isFinal: true))
        await client.waitUntilRequested()
        client.completeReply(speaker: "Avery", text: "First, review the budget.")
        await client.waitUntilSpeaking()
        await model.startMonitoring()

        source.emit(.init(text: "First, review the budget.", isFinal: true))
        for _ in 0..<10 { await Task.yield() }

        #expect(client.stopSpeakingCount == 0)
        #expect(model.status == .speaking)
        #expect(model.meterState == .monitoring)
        #expect(source.startCount == 3)
    }

    @Test func foregroundMonitoringRestartRetainsAgentEchoSuppression() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture()
        let model = VoiceModel(
            conversationID: "conversation_voice_barge_in_foreground",
            client: client,
            inputLevelSource: source
        )

        await model.startMonitoring()
        source.emit(.init(text: "Tell me the plan", isFinal: true))
        await client.waitUntilRequested()
        client.completeReply(speaker: "Avery", text: "First, review the budget.")
        await client.waitUntilSpeaking()
        await model.startMonitoring()

        model.stopMonitoring()
        await model.startMonitoring()
        for _ in 0..<10 { source.emitLevel(0.3) }
        source.emit(.init(text: "First review", isFinal: false))
        source.emit(.init(text: "First review the budget", isFinal: false))

        #expect(client.stopSpeakingCount == 0)
        #expect(model.status == .speaking)
    }

    @Test func finalOnlySpeechInterruptsPlaybackAndStartsTheFollowUp() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture()
        let model = VoiceModel(
            conversationID: "conversation_voice_barge_in_final_only",
            client: client,
            inputLevelSource: source
        )

        await model.startMonitoring()
        source.emit(.init(text: "Tell me the plan", isFinal: true))
        await client.waitUntilRequested()
        client.completeReply(speaker: "Avery", text: "First, review the budget and prepare the notes.")
        await client.waitUntilSpeaking()
        await model.startMonitoring()

        for _ in 0..<10 { source.emitLevel(0.3) }
        source.emit(.init(text: "Stop now", isFinal: true))
        for _ in 0..<20 { await Task.yield() }

        #expect(client.stopSpeakingCount == 1)
        #expect(client.requests == ["Tell me the plan", "Stop now"])
    }

    @Test func acceptedFinalBargeInSurvivesAnImmediateMonitoringStop() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture(defersStopSpeakingCompletion: true)
        let model = VoiceModel(
            conversationID: "conversation_voice_barge_in_final_stop_race",
            client: client,
            inputLevelSource: source
        )

        await model.startMonitoring()
        source.emit(.init(text: "Tell me the plan", isFinal: true))
        await client.waitUntilRequested()
        client.completeReply(speaker: "Avery", text: "First, review the budget and prepare the notes.")
        await client.waitUntilSpeaking()
        await model.startMonitoring()

        for _ in 0..<10 { source.emitLevel(0.3) }
        source.emit(.init(text: "Stop now", isFinal: true))
        model.stopMonitoring()
        client.completeStoppedSpeech()
        for _ in 0..<20 { await Task.yield() }

        #expect(client.requests == ["Tell me the plan", "Stop now"])
    }

    @Test func sustainedSpeechInterruptsPlaybackAndPreservesTheCompleteFollowUp() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture()
        let model = VoiceModel(
            conversationID: "conversation_voice_barge_in_turn",
            client: client,
            inputLevelSource: source
        )

        await model.startMonitoring()
        source.emit(.init(text: "Tell me the plan", isFinal: true))
        await client.waitUntilRequested()
        client.completeReply(speaker: "Avery", text: "First, review the budget and then prepare the notes.")
        await client.waitUntilSpeaking()
        await model.startMonitoring()

        for _ in 0..<10 { source.emitLevel(0.3) }
        source.emit(.init(text: "Wait a", isFinal: false))
        #expect(client.stopSpeakingCount == 0)
        source.emit(.init(text: "Wait a moment", isFinal: false))
        source.emit(.init(text: "Wait a moment, I need to add something", isFinal: true))
        for _ in 0..<20 { await Task.yield() }

        #expect(client.stopSpeakingCount == 1)
        #expect(client.requests == [
            "Tell me the plan",
            "Wait a moment, I need to add something",
        ])
        #expect(model.transcriptRows.last?.text == "Wait a moment, I need to add something")
    }

    @Test func mutedAgentAudioSkipsPlaybackButStillShowsTheHermesReply() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture(immediateReply: .init(
            speaker: "Avery",
            text: "Here is the result.",
            timelineItems: []
        ))
        let model = VoiceModel(
            conversationID: "conversation_voice_0002",
            agentName: "Avery",
            client: client,
            inputLevelSource: source
        )
        model.toggleAgentAudio()

        await model.startMonitoring()
        source.emit(.init(text: "Give me the result", isFinal: true))
        await model.waitUntilTurnSettles()

        #expect(client.speechRequests.isEmpty)
        #expect(model.status == .listening)
        #expect(model.transcriptRows.last?.text == "Here is the result.")
    }

    @Test func endingVoiceHandsAnActiveHermesTurnOffUntilItsFinalReply() async {
        let source = VoiceRecognitionSourceFixture()
        let client = VoiceConversationClientFixture()
        var started: [String] = []
        var completed: [VoiceAgentReply] = []
        let model = VoiceModel(
            conversationID: "conversation_voice_handoff_0001",
            agentName: "Avery",
            client: client,
            inputLevelSource: source,
            onStartedTurn: { started.append($0) },
            onCompletedTurn: { _, reply in completed.append(reply) }
        )

        await model.startMonitoring()
        source.emit(.init(text: "Finish this after I close voice", isFinal: true))
        await client.waitUntilRequested()
        #expect(started == ["Finish this after I close voice"])

        #expect(await model.end())
        #expect(!model.isActive)
        #expect(completed.isEmpty)

        let final = TimelineItem(
            id: "voice-handoff-final",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Avery")),
            content: .message("Finished after handoff."),
            metadata: .init(delivery: "Delivered")
        )
        client.completeReply(
            speaker: "Avery",
            text: "Finished after handoff.",
            timelineItems: [final]
        )
        await model.waitUntilTurnSettles()

        #expect(completed.map(\.timelineItems) == [[final]])
        #expect(client.speechRequests.isEmpty)
    }

    @Test func productionVoiceClientUsesSteerInsteadOfNormalSend() async throws {
        let conversation = StreamingVoiceConversationFixture()
        let client = BighelpVoiceSessionClient(conversation: conversation,
            output: VoiceSpeechOutputFixture(), speechRate: { 1 })
        try await client.steer("Use the other option", conversationID: "active-chat")
        #expect(conversation.steeringBehaviors == [.steer])
        #expect(conversation.requests.isEmpty)
    }

    @Test func productionClientMapsStreamingConversationAndSpeechOutput() async throws {
        let conversation = StreamingVoiceConversationFixture()
        let output = VoiceSpeechOutputFixture()
        let client = BighelpVoiceSessionClient(
            conversation: conversation,
            output: output,
            speechRate: { 0.53 }
        )
        var drafts: [String] = []

        let reply = try await client.respond(
            to: "Status update",
            conversationID: "conversation_voice_0003",
            onDraft: { drafts.append($0) }
        )
        try await client.speak(reply.text)

        #expect(conversation.requests == ["Status update"])
        #expect(drafts == ["Draft answer"])
        #expect(reply.speaker == "Avery")
        #expect(reply.text == "Final answer")
        #expect(output.requests == [.init(text: "Final answer", rate: 0.53)])
    }

    @Test func linkSpeechOutputRequestsBoundHermesAudioAndPlaysItNatively() async throws {
        let messaging = VoiceLinkMessagingFixture()
        let playback = VoiceAudioPlaybackFixture()
        let output = BighelpLinkVoiceSpeechOutput(
            messaging: messaging,
            sessionID: "session_voice_fixture_0004",
            agentID: "finance",
            playback: playback,
            requestID: { "voice_request_fixture_0004" },
            now: { Date(timeIntervalSince1970: 1_788_000_004) }
        )

        try await output.speak("Final spoken answer", rate: 1.15)

        #expect(messaging.requests == [
            BighelpLinkVoiceSpeakRequest(
                requestID: "voice_request_fixture_0004",
                sessionID: "session_voice_fixture_0004",
                agentID: "finance",
                text: "Final spoken answer",
                speed: 1.15,
                sentAt: 1_788_000_004
            ),
        ])
        #expect(playback.requests == [
            .init(audio: Data("remote audio".utf8), mimeType: "audio/mpeg"),
        ])
    }

    @Test func stoppingMicrophoneWhilePlaybackHoldsSessionDoesNotDeactivate() throws {
        let session = VoiceAudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)

        let microphone = try coordinator.acquire(for: .conversation)
        let playback = try coordinator.acquire(for: .conversation)
        #expect(session.activations == 1)
        #expect(session.isActive)

        microphone.release()
        #expect(session.isActive)
        #expect(session.deactivations == 0)

        playback.release()
        #expect(session.isActive == false)
        #expect(session.deactivations == 1)
    }

    /// A voice sample in Settings has nothing listening, so it plays at media
    /// volume. Voice chat used to play everything at earpiece-call volume.
    @Test func aSampleWithNothingListeningPlaysAtMediaVolume() throws {
        let session = VoiceAudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)

        let sample = try coordinator.acquire(for: .playback)
        #expect(session.configurations == [.playback])
        sample.release()

        let microphone = try coordinator.acquire(for: .conversation)
        #expect(session.configurations == [.playback, .conversation])
        microphone.release()
    }

    @Test func theMicrophoneJoiningASampleSwitchesToTheChatSetup() throws {
        let session = VoiceAudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)

        let sample = try coordinator.acquire(for: .playback)
        let microphone = try coordinator.acquire(for: .conversation)
        let reply = try coordinator.acquire(for: .conversation)
        #expect(session.configurations == [.playback, .conversation])
        #expect(session.activations == 1)

        sample.release()
        microphone.release()
        reply.release()
        #expect(session.isActive == false)
    }

    @Test func failedActivationDoesNotStrandAClaim() {
        let session = VoiceAudioSessionFixture()
        session.activationError = VoiceSessionError.unsupported
        let coordinator = VoiceAudioSessionCoordinator(session: session)

        #expect(throws: (any Error).self) {
            _ = try coordinator.acquire(for: .conversation)
        }
        #expect(coordinator.claimCount == 0)
        #expect(session.isActive == false)
    }

    @Test func aLiveCallRefusesClaimsAndNeverTouchesTheSession() throws {
        let session = VoiceAudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)

        let call = try coordinator.holdForLiveCall()
        #expect(throws: VoiceAudioSessionError.heldByLiveCall) { _ = try coordinator.acquire(for: .conversation) }
        #expect(throws: VoiceAudioSessionError.heldByLiveCall) { _ = try coordinator.acquire(for: .playback) }
        #expect(throws: VoiceAudioSessionError.heldByLiveCall) { _ = try coordinator.holdForLiveCall() }
        #expect(coordinator.claimCount == 0)

        call.release()
        call.release()
        #expect(session.configurations.isEmpty && session.activations == 0 && session.deactivations == 0)

        let claim = try coordinator.acquire(for: .conversation)
        #expect(session.activations == 1)
        claim.release()
    }

    @Test func aLiveCallCannotTakeTheSessionFromAClaim() throws {
        let session = VoiceAudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)

        let claim = try coordinator.acquire(for: .conversation)
        #expect(throws: VoiceAudioSessionError.heldByLiveCall) { _ = try coordinator.holdForLiveCall() }
        #expect(session.isActive)
        claim.release()
        #expect(session.deactivations == 1)
        _ = try coordinator.holdForLiveCall()
    }

    @Test func aStaleCallLeaseCannotLiftANewerCallsHold() throws {
        let coordinator = VoiceAudioSessionCoordinator(session: VoiceAudioSessionFixture())

        let first = try coordinator.holdForLiveCall()
        first.release()
        let second = try coordinator.holdForLiveCall()
        first.release()
        #expect(throws: VoiceAudioSessionError.heldByLiveCall) { _ = try coordinator.acquire(for: .playback) }
        second.release()
        _ = try coordinator.acquire(for: .playback)
    }

    @Test func replyPlaybackDuringALiveCallFailsQuietlyAndLeavesNoClaim() async throws {
        let session = VoiceAudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        let playback = AVAudioPlayerVoicePlayback(sessionCoordinator: coordinator)
        let call = try coordinator.holdForLiveCall()
        var events: [VoicePlaybackEvent] = []

        do {
            try await playback.play(Self.silentWAV(), mimeType: "audio/wav") { events.append($0) }
            Issue.record("Playback started over a live call")
        } catch {
            #expect(error as? VoiceAudioSessionError == .heldByLiveCall)
        }

        #expect(events == [.failed])
        #expect(coordinator.claimCount == 0)
        #expect(session.activations == 0 && session.deactivations == 0)
        call.release()
    }

    @Test func staleClaimReleaseCannotDeactivateASessionANewerOwnerHolds() throws {
        let session = VoiceAudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)

        let first = try coordinator.acquire(for: .conversation)
        first.release()
        #expect(session.isActive == false)

        let second = try coordinator.acquire(for: .conversation)
        #expect(session.isActive)

        first.release()
        #expect(session.isActive)
        #expect(coordinator.claimCount == 1)

        second.release()
        #expect(session.isActive == false)
    }

    @Test func undecodableAudioReleasesTheSessionClaim() async {
        let session = VoiceAudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        let playback = AVAudioPlayerVoicePlayback(sessionCoordinator: coordinator)

        await #expect(throws: (any Error).self) {
            try await playback.play(Data(repeating: 0x41, count: 512), mimeType: "audio/mpeg")
        }

        #expect(coordinator.claimCount == 0)
        #expect(session.isActive == false)
    }

    @Test func supersededPlayerCallbackDoesNotTearDownAnActiveSession() async throws {
        let session = VoiceAudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        let playback = AVAudioPlayerVoicePlayback(sessionCoordinator: coordinator)

        let microphone = try coordinator.acquire(for: .conversation)
        let superseded = try AVAudioPlayer(data: Self.silentWAV())

        playback.audioPlayerDidFinishPlaying(superseded, successfully: true)
        playback.audioPlayerDecodeErrorDidOccur(superseded, error: nil)
        try await Task.sleep(for: .milliseconds(50))

        #expect(session.isActive)
        #expect(session.deactivations == 0)
        #expect(coordinator.claimCount == 1)

        microphone.release()
        #expect(session.isActive == false)
    }

    private static func silentWAV(sampleCount: Int = 256) -> Data {
        let sampleRate = 44_100
        let bitsPerSample = 16
        let channels = 1
        let dataSize = sampleCount * channels * bitsPerSample / 8
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        text("RIFF")
        u32(UInt32(36 + dataSize))
        text("WAVE")
        text("fmt ")
        u32(16)
        u16(1)
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bitsPerSample / 8))
        u16(UInt16(channels * bitsPerSample / 8))
        u16(UInt16(bitsPerSample))
        text("data")
        u32(UInt32(dataSize))
        data.append(Data(repeating: 0, count: dataSize))
        return data
    }
}

private final class AudioTapInvocation: @unchecked Sendable {
    private let callback: AVAudioNodeTapBlock

    init(callback: @escaping AVAudioNodeTapBlock) {
        self.callback = callback
    }

    func invokeOffMain() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            buffer.frameLength = 1
            buffer.floatChannelData?[0][0] = 0.5
            callback(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
        }
    }
}

private final class VoiceAudioSessionFixture: VoiceAudioSessionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var isActive = false
        var activations = 0
        var deactivations = 0
        var activationError: (any Error)?
        var configurations: [VoiceAudioUse] = []
    }

    var isActive: Bool { read(\.isActive) }
    var activations: Int { read(\.activations) }
    var deactivations: Int { read(\.deactivations) }
    var configurations: [VoiceAudioUse] { read(\.configurations) }

    var activationError: (any Error)? {
        get { read(\.activationError) }
        set {
            lock.lock()
            defer { lock.unlock() }
            state.activationError = newValue
        }
    }

    func configure(for use: VoiceAudioUse) throws {
        lock.lock()
        defer { lock.unlock() }
        state.configurations.append(use)
    }

    func setActive(_ active: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if active {
            if let error = state.activationError { throw error }
            state.isActive = true
            state.activations += 1
        } else {
            state.isActive = false
            state.deactivations += 1
        }
    }

    private func read<Value>(_ keyPath: KeyPath<State, Value>) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return state[keyPath: keyPath]
    }
}

@MainActor
private final class VoiceRecognitionSourceFixture: VoiceInputLevelSource {
    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?
    private var generation: UInt64 = 0
    private(set) var startCount = 0

    func start(generation: UInt64) async throws {
        self.generation = generation
        startCount += 1
    }

    func stop() {}

    func emit(_ update: VoiceRecognitionUpdate) {
        onTranscript?(update, generation)
    }

    func emitLevel(_ level: Float) {
        onLevel?(level, generation)
    }
}

@MainActor
private final class VoiceConversationClientFixture: VoiceSessionClient {
    private var responseContinuation: CheckedContinuation<VoiceAgentReply, Error>?
    private var speechContinuation: CheckedContinuation<Void, Error>?
    private var draftCallback: ((String) -> Void)?
    private let immediateReply: VoiceAgentReply?
    private let defersStopSpeakingCompletion: Bool
    private(set) var requests: [String] = []
    private(set) var steeringRequests: [String] = []
    func steer(_ transcript: String, conversationID: String) async throws {
        steeringRequests.append(transcript)
    }
    private(set) var speechRequests: [String] = []
    private(set) var stopSpeakingCount = 0

    init(
        immediateReply: VoiceAgentReply? = nil,
        defersStopSpeakingCompletion: Bool = false
    ) {
        self.immediateReply = immediateReply
        self.defersStopSpeakingCompletion = defersStopSpeakingCompletion
    }

    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        requests.append(transcript)
        draftCallback = onDraft
        if let immediateReply { return immediateReply }
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func speak(_ text: String) async throws {
        speechRequests.append(text)
        try await withCheckedThrowingContinuation { continuation in
            speechContinuation = continuation
        }
    }

    func stopSpeaking() {
        stopSpeakingCount += 1
        guard !defersStopSpeakingCompletion else { return }
        completeStoppedSpeech()
    }

    func completeStoppedSpeech() {
        speechContinuation?.resume(throwing: CancellationError())
        speechContinuation = nil
    }

    func endSession(conversationID: String) async throws {
        stopSpeaking()
    }

    func waitUntilRequested() async {
        while requests.isEmpty { await Task.yield() }
    }

    func emitDraft(_ text: String) {
        draftCallback?(text)
    }

    func completeReply(
        speaker: String,
        text: String,
        timelineItems: [TimelineItem] = []
    ) {
        responseContinuation?.resume(returning: .init(
            speaker: speaker,
            text: text,
            timelineItems: timelineItems
        ))
        responseContinuation = nil
    }

    func waitUntilSpeaking() async {
        while speechRequests.isEmpty { await Task.yield() }
    }

    func completeSpeech() {
        speechContinuation?.resume(returning: ())
        speechContinuation = nil
    }
}

@MainActor
private final class StreamingVoiceConversationFixture: StreamingConversationClient, MidSessionConversationClient {
    private(set) var steeringBehaviors: [MidSessionChatBehavior] = []
    func sendMidSession(message: String, attachments: [ChatAttachment], conversationID: String,
                        behavior: MidSessionChatBehavior, onDraft: @escaping (TimelineItem) -> Void) async throws -> MidSessionSubmissionOutcome {
        steeringBehaviors.append(behavior)
        return .accepted
    }
    private(set) var requests: [String] = []

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        try await send(message: message, conversationID: conversationID, onDraft: { _ in })
    }

    func send(
        message: String,
        conversationID: String,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> ConversationResponse {
        requests.append(message)
        onDraft(Self.item(id: "draft", text: "Draft answer"))
        return ConversationResponse(items: [Self.item(id: "final", text: "Final answer")])
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }

    private static func item(id: String, text: String) -> TimelineItem {
        TimelineItem(
            id: id,
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Avery")),
            content: .message(text),
            metadata: .init()
        )
    }
}

@MainActor
private final class VoiceSpeechOutputFixture: VoiceSpeechOutput {
    struct Request: Equatable {
        let text: String
        let rate: Float
    }

    private(set) var requests: [Request] = []

    func speak(_ text: String, rate: Float) async throws {
        requests.append(.init(text: text, rate: rate))
    }

    func stop() {}
}

@MainActor
private final class VoiceLinkMessagingFixture: BighelpLinkVoiceMessaging {
    private(set) var requests: [BighelpLinkVoiceSpeakRequest] = []

    func synthesize(
        _ request: BighelpLinkVoiceSpeakRequest
    ) async throws -> BighelpLinkVoiceAudio {
        requests.append(request)
        return BighelpLinkVoiceAudio(
            audio: Data("remote audio".utf8),
            mimeType: "audio/mpeg",
            provider: "OpenAI"
        )
    }
}

@MainActor
private final class VoiceAudioPlaybackFixture: VoiceAudioPlayback {
    struct Request: Equatable {
        let audio: Data
        let mimeType: String
    }

    private(set) var requests: [Request] = []

    func play(_ audio: Data, mimeType: String) async throws {
        requests.append(.init(audio: audio, mimeType: mimeType))
    }

    func stop() {}
}
