import AVFoundation
import Foundation
import Testing
@testable import Bighelp

/// Hold music fills a voice chat's dead space: from the moment the person stops talking until the
/// agent's reply starts playing. It stops the moment the person talks again or the reply plays.
@MainActor
struct VoiceHoldMusicTests {
    @Test func playsFromTheTurnUntilTheReplyStartsPlaying() async throws {
        let music = HoldMusicFixture()
        let client = SteppedVoiceClient()
        let source = HoldInputSource()
        let model = VoiceModel(conversationID: "hold-session", client: client, inputLevelSource: source, holdMusic: music)
        await model.startMonitoring()
        #expect(!music.isPlaying, "Nothing plays while listening")

        source.emitTranscript("What's on my calendar?", isFinal: false)
        await settle()
        #expect(!music.isPlaying, "Nothing plays while the person talks")

        source.emitTranscript("What's on my calendar?", isFinal: true)
        await client.waitForRespond()
        await settle()
        #expect(model.status == .working)
        #expect(music.isPlaying, "The agent is working: hold music")

        client.reply("Two meetings today.")
        await client.waitForSpeak()
        await settle()
        #expect(model.status == .speaking)
        #expect(music.isPlaying, "The reply is still being made into audio")

        client.startPlayback()
        await settle()
        #expect(!music.isPlaying, "The agent is about to speak: stop")

        client.finishPlayback()
        await model.waitUntilTurnSettles()
        await settle()
        #expect(!music.isPlaying)
        #expect(music.starts == 1 && music.stops == 1)
    }

    @Test func stopsWhenThePersonTalksAndResumesWhileTheAgentStillWorks() async throws {
        let music = HoldMusicFixture()
        let client = SteppedVoiceClient()
        let source = HoldInputSource()
        let model = VoiceModel(conversationID: "hold-session", client: client, inputLevelSource: source, holdMusic: music)
        await model.startMonitoring()
        source.emitTranscript("Plan my week.", isFinal: true)
        await client.waitForRespond()
        await settle()
        #expect(music.isPlaying)

        // Still working; the person adds something.
        await model.startMonitoring()
        source.emitTranscript("Oh, and", isFinal: false)
        await settle()
        #expect(!music.isPlaying, "Talking again stops it at once")

        source.emitTranscript("Oh, and skip Friday.", isFinal: true)
        await client.waitForSteer()
        await settle()
        #expect(music.isPlaying, "Back to waiting on the agent")
        #expect(music.starts == 2)

        client.reply("Done.")
        await client.waitForSpeak()
        client.startPlayback()
        await settle()
        #expect(!music.isPlaying)
        client.finishPlayback()
        await model.waitUntilTurnSettles()
    }

    @Test func mutedAgentAudioAndEndingStopIt() async throws {
        let music = HoldMusicFixture()
        let client = SteppedVoiceClient()
        let source = HoldInputSource()
        let model = VoiceModel(conversationID: "hold-session", client: client, inputLevelSource: source, holdMusic: music)
        await model.startMonitoring()
        source.emitTranscript("Summarize my inbox.", isFinal: true)
        await client.waitForRespond()
        await settle()
        #expect(music.isPlaying)

        model.toggleAgentAudio()
        await settle()
        #expect(!music.isPlaying, "Agent audio off means no hold music")
        model.toggleAgentAudio()
        await settle()
        #expect(music.isPlaying)

        _ = await model.end()
        await settle()
        #expect(!music.isPlaying, "Ending the chat stops it")
    }

    @Test func playsWhileTheComputerTurnsSpeechIntoText() async throws {
        let music = HoldMusicFixture()
        let source = HoldInputSource()
        let model = VoiceModel(conversationID: "hold-session", transcription: .hermes, client: SteppedVoiceClient(),
                               inputLevelSource: source, holdMusic: music)
        await model.startMonitoring()
        source.onTranscribing?(true, source.latestGeneration)
        await settle()
        #expect(music.isPlaying, "Waiting on the transcript is dead space too")
        source.onTranscribing?(false, source.latestGeneration)
        await settle()
        #expect(!music.isPlaying)
    }

    @Test func theLoopPlaysLoopsAndHoldsTheAudioSessionOnlyWhilePlaying() async throws {
        #expect(Bundle.main.url(forResource: AVAudioPlayerHoldMusic.resourceName, withExtension: "wav") != nil)
        let session = AudioSessionFixture()
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        let music = AVAudioPlayerHoldMusic(sessionCoordinator: coordinator)
        music.start()
        #expect(music.isPlaying)
        #expect(coordinator.claimCount == 1 && session.configured == [.conversation])
        music.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!music.isPlaying)
        #expect(coordinator.claimCount == 0, "The session is let go between waits")
        music.start()
        #expect(music.isPlaying && coordinator.claimCount == 1)
        music.stop()
        try await Task.sleep(for: .milliseconds(200))
    }

    /// A reply from Hermes' default voice (Edge TTS, en-US-AriaNeural) measures -21.7 dBFS RMS
    /// (-20.3 LUFS). The loop must be easy to hear next to it, and still a little under it.
    @Test func theLoopPlaysALittleUnderAReply() throws {
        let url = try #require(Bundle.main.url(forResource: AVAudioPlayerHoldMusic.resourceName, withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let count = Int(buffer.frameLength)
        var sum = 0.0
        var peak: Float = 0
        for index in 0..<count {
            sum += Double(samples[index] * samples[index])
            peak = max(peak, abs(samples[index]))
        }
        let rms = 10 * log10(sum / Double(count)) + 20 * log10(Double(AVAudioPlayerHoldMusic.volume))
        let replyRMS = -21.7
        #expect(rms < replyRMS, "Under the reply: \(rms) dBFS")
        #expect(rms > replyRMS - 3, "Easy to hear next to the reply: \(rms) dBFS")
        #expect(peak < 0.5, "Room left before it clips: \(peak)")
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private final class AudioSessionFixture: VoiceAudioSessionControlling, @unchecked Sendable {
    private(set) var configured: [VoiceAudioUse] = []
    func configure(for use: VoiceAudioUse) throws { configured.append(use) }
    func setActive(_ active: Bool) throws {}
}

@MainActor
private final class HoldMusicFixture: VoiceHoldMusicPlaying {
    private(set) var isPlaying = false
    private(set) var starts = 0
    private(set) var stops = 0

    func start() {
        isPlaying = true
        starts += 1
    }

    func stop() {
        isPlaying = false
        stops += 1
    }
}

@MainActor
private final class SteppedVoiceClient: VoiceSessionClient {
    private var respondContinuation: CheckedContinuation<VoiceAgentReply, Error>?
    private var speakContinuation: CheckedContinuation<Void, Error>?
    private var onPlayback: (@MainActor (VoicePlaybackEvent) -> Void)?
    private var steered = false

    func respond(to transcript: String, conversationID: String,
                 onDraft: @escaping (String) -> Void) async throws -> VoiceAgentReply {
        try await withCheckedThrowingContinuation { respondContinuation = $0 }
    }

    func steer(_ transcript: String, conversationID: String) async throws {
        steered = true
    }

    func speak(_ text: String, onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        self.onPlayback = onPlayback
        try await withCheckedThrowingContinuation { speakContinuation = $0 }
    }

    func stopSpeaking() {
        speakContinuation?.resume(throwing: CancellationError())
        speakContinuation = nil
    }

    func endSession(conversationID: String) async throws {
        respondContinuation?.resume(throwing: CancellationError())
        respondContinuation = nil
    }

    func waitForRespond() async { while respondContinuation == nil { await Task.yield() } }
    func waitForSpeak() async { while speakContinuation == nil { await Task.yield() } }
    func waitForSteer() async { while !steered { await Task.yield() } }

    func reply(_ text: String) {
        respondContinuation?.resume(returning: VoiceAgentReply(speaker: "Avery", text: text, timelineItems: []))
        respondContinuation = nil
    }

    func startPlayback() { onPlayback?(.started) }

    func finishPlayback() {
        onPlayback?(.finished)
        speakContinuation?.resume()
        speakContinuation = nil
    }
}

@MainActor
private final class HoldInputSource: VoiceInputLevelSource {
    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?
    var onTranscribing: ((Bool, UInt64) -> Void)?
    var endsAfterSilence = true
    var transcription: VoiceTranscriptionSource = .onDevice
    var hostTranscriber: (@MainActor (Data) async throws -> String)?
    private(set) var latestGeneration: UInt64 = 0

    func start(generation: UInt64) async throws { latestGeneration = generation }
    func stop() {}
    func finishNow() {}

    func emitTranscript(_ text: String, isFinal: Bool) {
        onTranscript?(VoiceRecognitionUpdate(text: text, isFinal: isFinal), latestGeneration)
    }
}
