import AVFoundation
import Foundation

@MainActor
protocol VoiceSpeechOutput: AnyObject {
    func speak(_ text: String, rate: Float) async throws
    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws
    func stop()
}

extension VoiceSpeechOutput {
    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        onPlayback(.started)
        do {
            try await speak(text, rate: rate)
            onPlayback(.finished)
        } catch {
            onPlayback(.failed)
            throw error
        }
    }
}

@MainActor
protocol VoiceAudioPlayback: AnyObject {
    func play(_ audio: Data, mimeType: String) async throws
    func play(
        _ audio: Data,
        mimeType: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws
    func stop()
}

extension VoiceAudioPlayback {
    func play(
        _ audio: Data,
        mimeType: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        onPlayback(.started)
        do {
            try await play(audio, mimeType: mimeType)
            onPlayback(.finished)
        } catch {
            onPlayback(.failed)
            throw error
        }
    }
}

@MainActor
final class BighelpVoiceSessionClient: VoiceSessionClient {
    private let conversation: any ConversationClient
    private let output: any VoiceSpeechOutput
    private let speechRate: () -> Float

    init(
        conversation: any ConversationClient,
        output: any VoiceSpeechOutput,
        speechRate: @escaping () -> Float
    ) {
        self.conversation = conversation
        self.output = output
        self.speechRate = speechRate
    }

    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        let response: ConversationResponse
        if let streaming = conversation as? any StreamingConversationClient {
            response = try await streaming.send(
                message: transcript,
                conversationID: conversationID,
                onDraft: { item in
                    guard case .message(let text) = item.content else { return }
                    onDraft(text)
                }
            )
        } else {
            response = try await conversation.send(
                message: transcript,
                conversationID: conversationID
            )
        }

        guard let item = response.items.last(where: { item in
            guard item.role == .assistant, case .message(let text) = item.content else {
                return false
            }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), case .message(let text) = item.content else {
            throw VoiceSessionError.emptyResponse
        }
        return VoiceAgentReply(
            speaker: item.sender.snapshot.name,
            text: text,
            timelineItems: response.items
        )
    }

    func steer(_ transcript: String, conversationID: String) async throws {
        guard let conversation = conversation as? any MidSessionConversationClient else {
            throw VoiceSessionError.unsupported
        }
        _ = try await conversation.sendMidSession(
            message: transcript,
            attachments: [],
            conversationID: conversationID,
            behavior: .steer,
            onDraft: { _ in }
        )
    }

    func speak(_ text: String) async throws {
        try await output.speak(text, rate: min(max(speechRate(), 0.25), 4.0))
    }

    func speak(
        _ text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        try await output.speak(
            text,
            rate: min(max(speechRate(), 0.25), 4.0),
            onPlayback: onPlayback
        )
    }

    func stopSpeaking() {
        output.stop()
    }

    func endSession(conversationID: String) async throws {
        output.stop()
    }
}

@MainActor
final class BighelpLinkVoiceSpeechOutput: VoiceSpeechOutput {
    private let messaging: any BighelpLinkVoiceMessaging
    private let sessionID: String
    private let agentID: String
    private let playback: any VoiceAudioPlayback
    private let requestID: () -> String
    private let now: () -> Date
    private var generation: UInt64 = 0

    init(
        messaging: any BighelpLinkVoiceMessaging,
        sessionID: String,
        agentID: String,
        playback: any VoiceAudioPlayback = AVAudioPlayerVoicePlayback(),
        requestID: @escaping () -> String = { "voice_\(UUID().uuidString)" },
        now: @escaping () -> Date = Date.init
    ) {
        self.messaging = messaging
        self.sessionID = sessionID
        self.agentID = agentID
        self.playback = playback
        self.requestID = requestID
        self.now = now
    }

    func speak(_ text: String, rate: Float) async throws {
        try await speak(text, rate: rate) { _ in }
    }

    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        generation &+= 1
        let ownedGeneration = generation
        playback.stop()
        let audio = try await messaging.synthesize(
            BighelpLinkVoiceSpeakRequest(
                requestID: requestID(),
                sessionID: sessionID,
                agentID: agentID,
                text: String(normalized.prefix(20_000)),
                speed: min(max(rate, 0.25), 4),
                sentAt: Int(now().timeIntervalSince1970)
            )
        )
        try Task.checkCancellation()
        guard generation == ownedGeneration else { throw CancellationError() }
        try await playback.play(
            audio.audio,
            mimeType: audio.mimeType,
            onPlayback: onPlayback
        )
    }

    func stop() {
        generation &+= 1
        playback.stop()
    }
}

@MainActor
final class AVAudioPlayerVoicePlayback: NSObject, VoiceAudioPlayback, AVAudioPlayerDelegate {
    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private let use: VoiceAudioUse
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var sessionClaim: VoiceAudioSessionClaim?
    private var playbackEvent: (@MainActor (VoicePlaybackEvent) -> Void)?
    private var meterTask: Task<Void, Never>?

    /// `.playback` for samples nothing listens to; a voice chat's replies are
    /// part of the conversation.
    init(sessionCoordinator: VoiceAudioSessionCoordinator = .shared, use: VoiceAudioUse = .conversation) {
        self.sessionCoordinator = sessionCoordinator
        self.use = use
        super.init()
    }

    func play(_ audio: Data, mimeType: String) async throws {
        try await play(audio, mimeType: mimeType) { _ in }
    }

    func play(
        _ audio: Data,
        mimeType: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        guard !audio.isEmpty, audio.count <= BighelpLinkVoiceAudioChunk.maximumAudioBytes else {
            onPlayback(.failed)
            throw VoiceSessionError.emptyResponse
        }
        stop()
        playbackEvent = onPlayback

        do {
            sessionClaim = try sessionCoordinator.acquire(for: use)
        } catch {
            playbackEvent?(.failed)
            playbackEvent = nil
            throw error
        }

        let nextPlayer: AVAudioPlayer
        do {
            nextPlayer = try AVAudioPlayer(data: audio)
            guard nextPlayer.prepareToPlay() else { throw VoiceSessionError.emptyResponse }
        } catch {
            playbackEvent?(.failed)
            playbackEvent = nil
            releaseSession()
            throw error
        }
        nextPlayer.delegate = self
        nextPlayer.isMeteringEnabled = true
        player = nextPlayer

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard nextPlayer.play() else {
                    self.continuation = nil
                    self.player = nil
                    self.playbackEvent?(.failed)
                    self.playbackEvent = nil
                    self.releaseSession()
                    continuation.resume(throwing: VoiceSessionError.emptyResponse)
                    return
                }
                self.playbackEvent?(.started)
                self.startMetering(player: nextPlayer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        let pending = continuation
        continuation = nil
        meterTask?.cancel()
        meterTask = nil
        player?.stop()
        player = nil
        playbackEvent?(.failed)
        playbackEvent = nil
        releaseSession()
        pending?.resume(throwing: CancellationError())
    }

    private func startMetering(player: AVAudioPlayer) {
        let identity = ObjectIdentifier(player)
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
                guard let self, let current = self.player,
                      ObjectIdentifier(current) == identity else { return }
                current.updateMeters()
                let decibels = Double(current.averagePower(forChannel: 0))
                let linear = decibels.isFinite ? pow(10, decibels / 20) : 0
                self.playbackEvent?(.level(min(max(sqrt(linear), 0), 1)))
            }
        }
    }

    private func releaseSession() {
        sessionClaim?.release()
        sessionClaim = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(for: identity, success: flag, error: nil)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(for: identity, success: false, error: error)
        }
    }

    /// A callback from a superseded player must not settle the current
    /// operation or tear down the session it now owns.
    private func finishPlayback(for identity: ObjectIdentifier, success: Bool, error: (any Error)?) {
        guard let current = player, ObjectIdentifier(current) == identity else { return }
        let pending = continuation
        continuation = nil
        meterTask?.cancel()
        meterTask = nil
        player = nil
        playbackEvent?(success ? .finished : .failed)
        playbackEvent = nil
        releaseSession()
        if success {
            pending?.resume(returning: ())
        } else {
            pending?.resume(throwing: error ?? VoiceSessionError.emptyResponse)
        }
    }
}

/// The chat's Speak button: the agent's own voice from its computer, and this phone's system voice
/// when the computer can't say it (no connection, no provider, a provider error). Auto TTS keeps
/// `OnDeviceRoutedSpeechOutput`; this is asked for one reply at a time, after the person has already
/// read it on screen, so a tap has to produce sound rather than an error nobody is looking at.
@MainActor
final class HostReplySpeechOutput: VoiceSpeechOutput {
    private let host: (any VoiceSpeechOutput)?
    private let system: any VoiceSpeechOutput
    private var generation: UInt64 = 0

    init(host: (any VoiceSpeechOutput)?, system: any VoiceSpeechOutput = SystemSpeechOutput()) {
        self.host = host
        self.system = system
    }

    func speak(_ text: String, rate: Float) async throws {
        try await speak(text, rate: rate) { _ in }
    }

    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        try Task.checkCancellation()
        generation &+= 1
        let ownedGeneration = generation

        if let host {
            do {
                try await host.speak(text, rate: rate, onPlayback: onPlayback)
                return
            } catch is CancellationError {
                // A second tap stopped it: the phone's voice must not pick the sentence up.
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                guard !Task.isCancelled, generation == ownedGeneration else {
                    throw CancellationError()
                }
            }
        }

        try Task.checkCancellation()
        guard generation == ownedGeneration else { throw CancellationError() }
        try await system.speak(text, rate: rate, onPlayback: onPlayback)
    }

    func stop() {
        generation &+= 1
        host?.stop()
        system.stop()
    }
}

/// This phone's own voice, the one Siri reads with, for a reply the agent's computer can't say.
/// Nothing to download and nothing sent anywhere: the words stay on the device.
@MainActor
final class SystemSpeechOutput: VoiceSpeechOutput {
    /// The synthesizer answers on the thread that asked it to speak; every answer carries the
    /// utterance's identity back to the main actor so a cancelled earlier utterance can never
    /// settle a newer reading.
    @MainActor
    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        var onEnd: (@MainActor (ObjectIdentifier, Bool) -> Void)?

        nonisolated func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
        ) {
            let identity = ObjectIdentifier(utterance)
            Task { @MainActor [weak self] in
                self?.onEnd?(identity, false)
            }
        }

        nonisolated func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
        ) {
            let identity = ObjectIdentifier(utterance)
            Task { @MainActor [weak self] in
                self?.onEnd?(identity, true)
            }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = Delegate()
    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private var sessionClaim: VoiceAudioSessionClaim?
    private var activeUtterance: ObjectIdentifier?
    private var pending: CheckedContinuation<Void, any Error>?
    private var playbackEvent: (@MainActor (VoicePlaybackEvent) -> Void)?

    init(sessionCoordinator: VoiceAudioSessionCoordinator = .shared) {
        self.sessionCoordinator = sessionCoordinator
        synthesizer.delegate = delegate
        delegate.onEnd = { [weak self] identity, cancelled in
            self?.finish(for: identity, cancelled: cancelled)
        }
    }

    func speak(_ text: String, rate: Float) async throws {
        try await speak(text, rate: rate) { _ in }
    }

    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Whatever was being said ends first, and its finish must not reach this reading.
        stop()
        sessionClaim = try sessionCoordinator.acquire(for: .playback)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Self.rate(for: rate)
        let identity = ObjectIdentifier(utterance)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    releaseSession()
                    onPlayback(.failed)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                activeUtterance = identity
                pending = continuation
                playbackEvent = onPlayback
                onPlayback(.started)
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        activeUtterance = nil
        let spoken = pending
        pending = nil
        let event = playbackEvent
        playbackEvent = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        releaseSession()
        event?(.failed)
        spoken?.resume(throwing: CancellationError())
    }

    private func finish(for identity: ObjectIdentifier, cancelled: Bool) {
        guard activeUtterance == identity else { return }
        activeUtterance = nil
        let spoken = pending
        pending = nil
        let event = playbackEvent
        playbackEvent = nil
        releaseSession()
        event?(cancelled ? .failed : .finished)
        if cancelled {
            spoken?.resume(throwing: CancellationError())
        } else {
            spoken?.resume(returning: ())
        }
    }

    /// Hermes speaks at a multiplier of its own rate; the system voice takes a 0–1 rate placed
    /// around its default, so the two speeds mean the same thing.
    static func rate(for multiplier: Float) -> Float {
        min(max(AVSpeechUtteranceDefaultSpeechRate * multiplier,
                AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private func releaseSession() {
        sessionClaim?.release()
        sessionClaim = nil
    }
}
