import AVFoundation
import Foundation
import Observation
import UIKit
#if canImport(PhononTTS) && !targetEnvironment(macCatalyst) && !os(visionOS)
import PhononTTS
#endif

enum OnDeviceSpeechError: Error, Equatable {
    /// This device can't run the model, or it isn't downloaded.
    case unavailable
}

/// Speaks with an on-device voice model. One voice at a time for the whole app: a new utterance
/// cuts off the last, and only whoever started one can stop it. Audio plays as the model makes
/// it, 80 ms at a time, so a reply starts at once and a long one never waits for its end.
@MainActor @Observable
final class OnDeviceSpeechEngine {
    static let shared = OnDeviceSpeechEngine()
    static let sampleText = DirectHermesVoiceSettingsClient.sampleText

    /// iPhone and iPad on iOS 18 or later: Phonon's Core ML models need at least that.
    nonisolated static var isSupported: Bool {
        #if canImport(PhononTTS) && !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }

    /// The voice a Settings preview is playing.
    private(set) var previewingVoice: String?
    /// The first load after a download compiles the model for this device, about 10 s.
    private(set) var isPreparing = false

    @ObservationIgnored private let installer: OnDeviceVoiceInstaller
    /// A `PhononSpeaker`, kept loaded between replies (loading takes about half a second).
    @ObservationIgnored private var speaker: AnyObject?
    @ObservationIgnored private var loading: (modelID: String, task: Task<any Sendable, any Error>)?
    @ObservationIgnored private var current: (owner: ObjectIdentifier, task: Task<Void, any Error>)?
    @ObservationIgnored private let previewOwner = NSObject()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(installer: OnDeviceVoiceInstaller = .shared) {
        self.installer = installer
        let center = NotificationCenter.default
        // A call or another app took the audio: what was playing can't finish.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { if began { self?.stopCurrent() } }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.current == nil else { return }
                self.speaker = nil
            }
        })
    }

    func canSpeak(_ model: OnDeviceVoiceModel) -> Bool {
        Self.isSupported && installer.isInstalled(model)
    }

    /// Speaks `text` (Markdown is read as plain text) in `voice`. Returns when it has played, and
    /// throws `CancellationError` when stopped or cut off.
    func speak(_ text: String, model: OnDeviceVoiceModel, voice: String, rate: Float, use: VoiceAudioUse,
               owner: AnyObject,
               onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void = { _ in }) async throws {
        guard canSpeak(model) else { throw OnDeviceSpeechError.unavailable }
        let speakable = String(MarkdownDocument(text).visiblePlainText.prefix(20_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speakable.isEmpty else { return }
        // The last utterance lets go of the audio graph before this one takes it: both use one
        // player, and its teardown would stop this one's sound.
        let previous = current?.task
        stopCurrent()
        let job = Task { @MainActor in
            _ = await previous?.result
            try Task.checkCancellation()
            try await self.play(speakable, model: model, voice: voice, rate: rate, use: use, onPlayback: onPlayback)
        }
        current = (ObjectIdentifier(owner), job)
        defer { if current?.task == job { current = nil } }
        try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// `text` in `voice` as WAV, without playing it: a team call makes each member's next piece
    /// while another member speaks, and plays them in turn through its own player.
    func synthesize(_ text: String, model: OnDeviceVoiceModel, voice: String) async throws -> Data {
        guard canSpeak(model) else { throw OnDeviceSpeechError.unavailable }
        let speakable = String(MarkdownDocument(text).visiblePlainText.prefix(20_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speakable.isEmpty else { throw VoiceSessionError.emptyResponse }
        #if canImport(PhononTTS) && !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 18.0, *) {
            let speaker = try await loadedSpeaker(model)
            let samples = try await speaker.samples(speakable, voice: voice.isEmpty ? model.defaultVoice : voice,
                                                    fallbackVoice: model.defaultVoice)
            return Self.wav(samples, sampleRate: Int(Phonon.sampleRate))
        }
        #endif
        throw OnDeviceSpeechError.unavailable
    }

    /// Mono 16-bit PCM WAV, the shape every system player takes.
    nonisolated static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + payload)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(payload)
        data.reserveCapacity(data.count + samples.count * 2)
        for sample in samples { append(Int16((min(max(sample, -1), 1) * Float(Int16.max)).rounded())) }
        return data
    }

    /// Stops what `owner` started; someone else's speech plays on.
    func stop(owner: AnyObject) {
        guard current?.owner == ObjectIdentifier(owner) else { return }
        stopCurrent()
    }

    /// Settings' voice list: hear a voice before choosing it.
    func preview(_ voice: String, model: OnDeviceVoiceModel) async {
        previewingVoice = voice
        defer { if previewingVoice == voice { previewingVoice = nil } }
        try? await speak(Self.sampleText, model: model, voice: voice, rate: 1, use: .playback, owner: previewOwner)
    }

    func stopPreview() {
        stop(owner: previewOwner)
        previewingVoice = nil
    }

    private func stopCurrent() {
        current?.task.cancel()
        current = nil
    }

    private func play(_ text: String, model: OnDeviceVoiceModel, voice: String, rate: Float, use: VoiceAudioUse,
                      onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        #if canImport(PhononTTS) && !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 18.0, *) {
            let speaker = try await loadedSpeaker(model)
            try Task.checkCancellation()
            try await speaker.speak(text, voice: voice.isEmpty ? model.defaultVoice : voice,
                                    fallbackVoice: model.defaultVoice, rate: rate, use: use, onPlayback: onPlayback)
            return
        }
        #endif
        throw OnDeviceSpeechError.unavailable
    }

    #if canImport(PhononTTS) && !targetEnvironment(macCatalyst) && !os(visionOS)
    @available(iOS 18.0, *)
    private func loadedSpeaker(_ model: OnDeviceVoiceModel) async throws -> PhononSpeaker {
        if let speaker = speaker as? PhononSpeaker, speaker.modelID == model.id { return speaker }
        if let loading, loading.modelID == model.id, let speaker = try await loading.task.value as? PhononSpeaker {
            return speaker
        }
        let directory = installer.directory(for: model)
        isPreparing = Phonon.needsCompiling(directory)
        let task = Task<any Sendable, any Error> { @MainActor in
            PhononSpeaker(modelID: model.id, phonon: try await Phonon.load(models: directory, language: .english))
        }
        loading = (model.id, task)
        defer {
            if loading?.task == task { loading = nil }
            isPreparing = false
        }
        guard let loaded = try await task.value as? PhononSpeaker else { throw OnDeviceSpeechError.unavailable }
        speaker = loaded
        return loaded
    }
    #endif
}

#if canImport(PhononTTS) && !targetEnvironment(macCatalyst) && !os(visionOS)
/// One loaded Phonon model and the audio graph it plays through: player, then speed (pitch kept).
@available(iOS 18.0, *)
@MainActor
private final class PhononSpeaker {
    let modelID: String
    private let phonon: Phonon
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let speed = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Phonon.sampleRate, channels: 1)!

    init(modelID: String, phonon: Phonon) {
        self.modelID = modelID
        self.phonon = phonon
        engine.attach(player)
        engine.attach(speed)
        engine.connect(player, to: speed, format: format)
        engine.connect(speed, to: engine.mainMixerNode, format: format)
    }

    /// One voice's samples at a time: a voice switch and its utterance must not interleave with
    /// another member's, or the second would speak in the first one's voice.
    private var samplesTail: Task<Void, Never>?

    func samples(_ text: String, voice: String, fallbackVoice: String) async throws -> [Float] {
        let previous = samplesTail
        let job = Task { @MainActor [phonon] () throws -> [Float] in
            _ = await previous?.result
            if phonon.voice != voice {
                do { try await phonon.setVoice(voice) } catch { try await phonon.setVoice(fallbackVoice) }
            }
            return try await phonon.synthesize(text)
        }
        samplesTail = Task { _ = await job.result }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    func speak(_ text: String, voice: String, fallbackVoice: String, rate: Float, use: VoiceAudioUse,
               onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        if phonon.voice != voice {
            // A voice the model no longer has speaks in its own default.
            do { try await phonon.setVoice(voice) } catch { try await phonon.setVoice(fallbackVoice) }
        }
        let events = PlaybackEvents(deliver: onPlayback)
        let claim: VoiceAudioSessionClaim
        do {
            claim = try VoiceAudioSessionCoordinator.shared.acquire(for: use)
        } catch {
            events.send(.failed)
            throw error
        }
        defer {
            player.stop()
            engine.stop()
            claim.release()
        }
        speed.rate = min(max(rate, 0.5), 2)
        let queue = PhononPlaybackQueue(player: player, format: format) { event in
            Task { @MainActor in events.send(event) }
        }
        // Headphones or a car coming or going stop the engine; what was scheduled never plays.
        let routeChange = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in queue.cancel() }
        defer { NotificationCenter.default.removeObserver(routeChange) }
        do {
            try engine.start()
            player.play()
            try await phonon.speak(text) { samples in queue.enqueue(samples) }
            // Phonon returns early, without throwing, when its task is cancelled.
            try Task.checkCancellation()
            try await queue.drained()
            events.send(.finished)
        } catch {
            queue.cancel()
            events.send(.failed)
            throw error
        }
    }
}

/// Playback events in order, and none after the utterance ends.
@MainActor
private final class PlaybackEvents {
    private let deliver: @MainActor (VoicePlaybackEvent) -> Void
    private var isOpen = true

    init(deliver: @escaping @MainActor (VoicePlaybackEvent) -> Void) {
        self.deliver = deliver
    }

    func send(_ event: VoicePlaybackEvent) {
        guard isOpen else { return }
        if event == .finished || event == .failed { isOpen = false }
        deliver(event)
    }
}

/// Schedules Phonon's chunks as they come, from its thread, and knows when the last has played.
private final class PhononPlaybackQueue: @unchecked Sendable {
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let event: @Sendable (VoicePlaybackEvent) -> Void
    private let lock = NSLock()
    private var scheduled = 0
    private var played = 0
    private var isGenerated = false
    private var isCancelled = false
    private var drain: CheckedContinuation<Void, any Error>?

    init(player: AVAudioPlayerNode, format: AVAudioFormat, event: @escaping @Sendable (VoicePlaybackEvent) -> Void) {
        self.player = player
        self.format = format
        self.event = event
    }

    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let level = Self.level(samples)
        let isFirst = lock.withLock { () -> Bool in
            scheduled += 1
            return scheduled == 1
        }
        if isFirst { event(.started) }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.didPlay(level: level)
        }
    }

    /// Waits for every scheduled chunk to play.
    func drained() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = lock.withLock { () -> Bool? in
                    isGenerated = true
                    if isCancelled { return false }
                    if played >= scheduled { return true }
                    drain = continuation
                    return nil
                }
                switch outcome {
                case true?: continuation.resume()
                case false?: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            isCancelled = true
            defer { drain = nil }
            return drain
        }
        waiting?.resume(throwing: CancellationError())
    }

    private func didPlay(level: Double) {
        event(.level(level))
        let waiting = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            played += 1
            guard isGenerated, played >= scheduled else { return nil }
            defer { drain = nil }
            return drain
        }
        waiting?.resume()
    }

    /// 0...1, for the voice orb.
    private static func level(_ samples: [Float]) -> Double {
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return min(1, Double(sqrt(power)) * 4)
    }
}
#endif
