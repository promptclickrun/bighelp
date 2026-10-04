import AVFoundation
import Foundation
import Speech

enum VoiceInputLevelError: Error, Equatable, Sendable {
    case permissionDenied
    case noInputAvailable
    case engineFailed
    case interrupted
    case speechPermissionDenied
    case speechUnavailable
    case hostTranscriptionFailed
}

enum VoiceAuthorizationBridge {
    static func value<Result: Sendable>(
        _ request: @escaping @Sendable (@escaping @Sendable (Result) -> Void) -> Void
    ) async -> Result {
        await withCheckedContinuation { continuation in
            request { result in
                continuation.resume(returning: result)
            }
        }
    }
}

/// Requires both sustained foreground audio and progressive recognized speech
/// before playback can be interrupted. Either signal alone is treated as noise.
@MainActor
final class VoiceBargeInDetector {
    private let activityThreshold: Float
    private let requiredActiveSamples: Int
    private var activeSamples = 0
    private var previousTranscript = ""
    private var spokenText = ""

    /// Replies now play at speaker volume, so more of them reaches the
    /// microphone; interrupting takes a little more than the old 0.14.
    init(activityThreshold: Float = 0.18, requiredActiveSamples: Int = 8) {
        self.activityThreshold = activityThreshold
        self.requiredActiveSamples = requiredActiveSamples
    }

    func begin(spokenText: String) {
        reset()
        self.spokenText = Self.normalized(spokenText)
    }

    func receiveLevel(_ level: Float) {
        if level >= activityThreshold {
            activeSamples = min(activeSamples + 1, requiredActiveSamples * 2)
        } else {
            activeSamples = max(activeSamples - 2, 0)
        }
    }

    func receiveTranscript(_ text: String, isFinal: Bool) -> Bool {
        let candidate = Self.normalized(text)
        defer { previousTranscript = candidate }
        guard activeSamples >= requiredActiveSamples,
              Self.hasMeaningfulPhrase(candidate),
              !Self.isLikelyEcho(candidate, of: spokenText)
        else { return false }
        if isFinal { return true }
        guard !previousTranscript.isEmpty,
              candidate != previousTranscript,
              candidate.hasPrefix(previousTranscript)
        else { return false }
        return true
    }

    func reset() {
        activeSamples = 0
        previousTranscript = ""
        spokenText = ""
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func hasMeaningfulPhrase(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return words.count >= 2 && words.joined().count >= 6
    }

    private static func isLikelyEcho(_ candidate: String, of spokenText: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if spokenText.contains(candidate) { return true }
        let spokenWords = Set(spokenText.split(separator: " "))
        let candidateWords = candidate.split(separator: " ")
        guard !candidateWords.isEmpty else { return false }
        let overlap = candidateWords.filter { spokenWords.contains($0) }.count
        return Double(overlap) / Double(candidateWords.count) >= 0.7
    }
}

/// Serializes audio appends with recognition finalization so a tap callback
/// can never append another buffer after `endAudio()`. It also holds the
/// current recognition request, which is replaced when the recognizer is
/// restarted mid-turn, and the turn's recording for Hermes.
private final class VoiceAudioBufferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recorder: VoiceTurnRecorder?

    func open(request: SFSpeechAudioBufferRecognitionRequest?, recorder: VoiceTurnRecorder?) {
        lock.lock()
        isOpen = true
        self.request = request
        self.recorder = recorder
        lock.unlock()
    }

    func replace(request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    /// Stops appends and hands back the recording, if any.
    @discardableResult
    func close() -> VoiceTurnRecorder? {
        lock.lock()
        defer { lock.unlock() }
        isOpen = false
        request = nil
        let recording = recorder
        recorder = nil
        return recording
    }

    enum Append { case closed, appended, recordingFull }

    func append(_ buffer: AVAudioPCMBuffer) -> Append {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return .closed }
        request?.append(buffer)
        if let recorder, !recorder.append(buffer) { return .recordingFull }
        return .appended
    }
}

@MainActor
protocol VoiceInputLevelSource: AnyObject {
    var onLevel: ((Float, UInt64) -> Void)? { get set }
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)? { get set }
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)? { get set }
    /// True while a finished turn is being transcribed on the computer.
    var onTranscribing: ((Bool, UInt64) -> Void)? { get set }

    var endsAfterSilence: Bool { get set }
    /// Where the turn's final text comes from. With `.hermes`, the audio is
    /// recorded and sent to `hostTranscriber`; on-device captions still show
    /// while speaking when speech recognition is available.
    var transcription: VoiceTranscriptionSource { get set }
    var hostTranscriber: (@MainActor (Data) async throws -> String)? { get set }
    /// The longest pause that still waits for more (Hermes' `voice.silence_duration`).
    var silenceLimit: Duration? { get set }
    func start(generation: UInt64) async throws
    /// Ends the turn now, as if the speaker had gone quiet.
    func finishNow()
    func stop()
}

extension VoiceInputLevelSource {
    var endsAfterSilence: Bool {
        get { true }
        set { }
    }
    var onTranscribing: ((Bool, UInt64) -> Void)? {
        get { nil }
        set { }
    }
    var transcription: VoiceTranscriptionSource {
        get { .onDevice }
        set { }
    }
    var hostTranscriber: (@MainActor (Data) async throws -> String)? {
        get { nil }
        set { }
    }
    var silenceLimit: Duration? {
        get { nil }
        set { }
    }
    func finishNow() {}
}

@MainActor
final class SilentVoiceInputLevelSource: VoiceInputLevelSource {
    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?

    func start(generation: UInt64) async throws {}

    func stop() {}
}

/// The production microphone seam. It owns its tap and reports levels on the
/// main actor; the voice model owns generation checks and lifecycle policy.
///
/// A turn ends when the speaker goes quiet long enough (or `finishNow`), never
/// because the recognizer decided on its own: when Apple's recognizer ends a
/// result early or fails mid-turn, it's restarted and the words so far are kept.
@MainActor
final class AVAudioEngineVoiceInputLevelSource: VoiceInputLevelSource {
    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?
    var onTranscribing: ((Bool, UInt64) -> Void)?
    var transcription: VoiceTranscriptionSource = .onDevice
    var hostTranscriber: (@MainActor (Data) async throws -> String)?
    var silenceLimit: Duration? {
        didSet { endOfSpeechDetector.silenceLimit = silenceLimit }
    }

    private let audioSession: AVAudioSession
    private let sessionCoordinator: VoiceAudioSessionCoordinator
    nonisolated(unsafe) private let audioEngine: AVAudioEngine
    nonisolated(unsafe) private let teardownHook: (() -> Void)?
    nonisolated(unsafe) private var tapInstalled = false
    nonisolated(unsafe) private var recognitionTask: SFSpeechRecognitionTask?
    nonisolated(unsafe) private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    nonisolated(unsafe) private var sessionClaim: VoiceAudioSessionClaim?
    private var recognizer: SFSpeechRecognizer?
    private var activeGeneration: UInt64 = 0
    /// Bumped whenever the recognition task is replaced, so a stale task's
    /// late results are ignored.
    private var recognitionID: UInt64 = 0
    private var recognitionRestarts = 0
    private var isFinishingRecognition = false
    private var hasDeliveredFinal = false
    private var transcript = VoiceTranscriptAccumulator()
    var endsAfterSilence = true
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var configurationObserver: NSObjectProtocol?
    nonisolated private let audioBufferGate = VoiceAudioBufferGate()
    private lazy var endOfSpeechDetector = VoiceEndOfSpeechDetector { [weak self] in
        self?.finishTurn()
    }

    /// A recognizer that keeps ending early isn't going to recover this turn.
    private static let maximumRecognitionRestarts = 12

    init(
        audioSession: AVAudioSession = .sharedInstance(),
        audioEngine: AVAudioEngine = AVAudioEngine(),
        sessionCoordinator: VoiceAudioSessionCoordinator = .shared,
        teardownHook: (() -> Void)? = nil
    ) {
        self.audioSession = audioSession
        self.audioEngine = audioEngine
        self.sessionCoordinator = sessionCoordinator
        self.teardownHook = teardownHook
    }

    func start(generation: UInt64) async throws {
        guard !audioEngine.isRunning, !tapInstalled else { return }
        activeGeneration = generation
        isFinishingRecognition = false
        hasDeliveredFinal = false
        recognitionRestarts = 0
        transcript.reset()
        endOfSpeechDetector.reset()

        let permissionGranted = Self.hasMicrophoneAuthorization
        guard activeGeneration == generation else {
            throw VoiceInputLevelError.interrupted
        }
        guard permissionGranted else {
            stop()
            throw VoiceInputLevelError.permissionDenied
        }
        let usesHost = transcription == .hermes && hostTranscriber != nil
        // Hermes does the transcribing; on-device captions are a bonus there.
        guard usesHost || Self.hasSpeechAuthorization else {
            stop()
            throw VoiceInputLevelError.speechPermissionDenied
        }
        guard activeGeneration == generation else {
            throw VoiceInputLevelError.interrupted
        }

        do {
            sessionClaim = try sessionCoordinator.acquire(for: .conversation)

            let inputNode = audioEngine.inputNode
            let format = inputNode.inputFormat(forBus: 0)
            guard format.channelCount > 0 else {
                throw VoiceInputLevelError.noInputAvailable
            }

            if Self.hasSpeechAuthorization,
               let recognizer = SFSpeechRecognizer(locale: Locale.current),
               recognizer.isAvailable, recognizer.supportsOnDeviceRecognition {
                self.recognizer = recognizer
            } else if usesHost {
                recognizer = nil
            } else {
                throw VoiceInputLevelError.speechUnavailable
            }
            let recorder = usesHost ? try VoiceTurnRecorder(inputFormat: format) : nil
            endOfSpeechDetector.countsVoiceAsSpeech = recognizer == nil
            let request = recognizer.map { startRecognition(with: $0, generation: generation) }

            let tapCallback = Self.makeTapCallback(generation: generation, source: self)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: tapCallback)
            tapInstalled = true
            audioBufferGate.open(request: request, recorder: recorder)
            audioEngine.prepare()
            try audioEngine.start()
            installInterruptionObserver()
            installConfigurationObserver()
        } catch let error as VoiceInputLevelError {
            stop()
            throw error
        } catch {
            stop()
            throw VoiceInputLevelError.engineFailed
        }
    }

    /// Starts (or restarts) on-device recognition for this turn.
    private func startRecognition(
        with recognizer: SFSpeechRecognizer,
        generation: UInt64
    ) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        recognitionRequest = request
        recognitionID &+= 1
        let taskID = recognitionID
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let segmentEnded = result?.speechRecognitionMetadata != nil
            let failed = result == nil && error != nil
            Task { @MainActor [weak self] in
                self?.receiveRecognition(text: text, isFinal: isFinal, segmentEnded: segmentEnded, failed: failed,
                                         generation: generation, taskID: taskID)
            }
        }
        return request
    }

    private func receiveRecognition(
        text: String?, isFinal: Bool, segmentEnded: Bool, failed: Bool, generation: UInt64, taskID: UInt64
    ) {
        guard activeGeneration == generation, taskID == recognitionID, !hasDeliveredFinal else { return }
        if let text { transcript.receive(text, segmentEnded: segmentEnded || isFinal) }
        let words = transcript.text
        guard isFinal || failed else {
            guard !words.isEmpty else { return }
            let update = VoiceRecognitionUpdate(text: words, isFinal: false)
            endOfSpeechDetector.receiveTranscript(update)
            onTranscript?(update, generation)
            return
        }
        if isFinishingRecognition {
            // The turn ended here (quiet, Send, or release): these are its words.
            if transcription == .hermes, hostTranscriber != nil { return }
            deliverFinal(words, generation: generation)
            return
        }
        if failed, words.isEmpty, transcription == .onDevice {
            let callback = onUnavailable
            stop()
            callback?(.speechUnavailable, generation)
            return
        }
        // The recognizer ended on its own while the person is still talking:
        // keep their words and listen on with a fresh recognizer.
        restartRecognition(generation: generation)
    }

    private func restartRecognition(generation: UInt64) {
        transcript.commitSegment()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognitionRestarts += 1
        guard let recognizer, recognizer.isAvailable, recognitionRestarts <= Self.maximumRecognitionRestarts else {
            audioBufferGate.replace(request: nil)
            // Without on-device recognition the turn can still end on quiet.
            endOfSpeechDetector.countsVoiceAsSpeech = true
            if transcription == .onDevice { finishTurn() }
            return
        }
        audioBufferGate.replace(request: startRecognition(with: recognizer, generation: generation))
    }

    func finishNow() {
        guard tapInstalled || recognitionTask != nil else { return }
        finishTurn()
    }

    /// Stops listening and produces the turn's final text.
    private func finishTurn() {
        guard !isFinishingRecognition, !hasDeliveredFinal else { return }
        isFinishingRecognition = true
        endOfSpeechDetector.reset()
        let recorder = audioBufferGate.close()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        let generation = activeGeneration
        if transcription == .hermes, let hostTranscriber {
            let recording = recorder?.finish()
            // Hermes has the audio; the on-device words are only a fallback now.
            recognitionRequest?.endAudio()
            recognitionTask?.finish()
            transcribeOnHost(recording, with: hostTranscriber, generation: generation)
            return
        }
        recorder?.discard()
        guard let recognitionRequest, let recognitionTask else {
            deliverFinal(transcript.text, generation: generation)
            return
        }
        recognitionRequest.endAudio()
        recognitionTask.finish()
        // The recognizer's last word usually lands within a moment; don't keep someone
        // waiting for it. If it hasn't answered, the words so far still count.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.activeGeneration == generation else { return }
            self.deliverFinal(self.transcript.text, generation: generation)
        }
    }

    private func transcribeOnHost(
        _ recording: Data?, with transcriber: @escaping @MainActor (Data) async throws -> String, generation: UInt64
    ) {
        onTranscribing?(true, generation)
        Task { @MainActor [weak self] in
            var text: String?
            if let recording {
                text = try? await transcriber(recording)
            }
            guard let self, self.activeGeneration == generation, !self.hasDeliveredFinal else { return }
            self.onTranscribing?(false, generation)
            if let text {
                self.deliverFinal(text, generation: generation)
                return
            }
            // The computer couldn't transcribe it: this device's words are
            // better than losing the turn.
            let fallback = self.transcript.text
            if !fallback.isEmpty {
                self.deliverFinal(fallback, generation: generation)
            } else {
                let callback = self.onUnavailable
                self.stop()
                callback?(.hostTranscriptionFailed, generation)
            }
        }
    }

    private func deliverFinal(_ text: String, generation: UInt64) {
        guard activeGeneration == generation, !hasDeliveredFinal else { return }
        hasDeliveredFinal = true
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        onTranscript?(.init(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isFinal: true), generation)
    }

    func stop() {
        activeGeneration &+= 1
        endOfSpeechDetector.reset()
        audioBufferGate.close()?.discard()
        teardownResources()
        transcript.reset()
        recognizer = nil
        onLevel = nil
        onTranscript = nil
        onUnavailable = nil
        onTranscribing = nil
    }

    deinit {
        audioBufferGate.close()?.discard()
        teardownResources()
        teardownHook?()
    }

    nonisolated private func teardownResources() {
        audioBufferGate.close()?.discard()
        removeInterruptionObserver()
        removeConfigurationObserver()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        sessionClaim?.release()
        sessionClaim = nil
    }

    nonisolated private static var hasMicrophoneAuthorization: Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            true
        case .denied, .undetermined:
            false
        @unknown default:
            false
        }
    }

    nonisolated private static var hasSpeechAuthorization: Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .notDetermined, .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    private func installInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        let observerGeneration = activeGeneration
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] note in
            guard
                let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                type == .began
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeGeneration == observerGeneration else { return }
                let callback = self.onUnavailable
                self.stop()
                callback?(.interrupted, observerGeneration)
            }
        }
    }

    /// A car or headset taking over the microphone changes the route under a turn:
    /// iOS stops the engine and the input may arrive in another format. Without
    /// picking it up again no more sound came in, so the turn never heard quiet,
    /// had no words for Send, and stayed listening.
    private func installConfigurationObserver() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reattachInput() }
        }
    }

    /// Listens again on the new input, keeping the words heard so far.
    func reattachInput() {
        guard tapInstalled, !isFinishingRecognition, !hasDeliveredFinal else { return }
        let generation = activeGeneration
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        tapInstalled = false
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            let callback = onUnavailable
            stop()
            callback?(.noInputAvailable, generation)
            return
        }
        // A recognition request takes one format; start a fresh one, keeping the words.
        if recognitionRequest != nil { restartRecognition(generation: generation) }
        guard activeGeneration == generation, !isFinishingRecognition else { return }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format,
                             block: Self.makeTapCallback(generation: generation, source: self))
        tapInstalled = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            let callback = onUnavailable
            stop()
            callback?(.engineFailed, generation)
        }
    }

    nonisolated private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    nonisolated private func removeInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    nonisolated static func makeTapCallback(
        generation: UInt64,
        source: AVAudioEngineVoiceInputLevelSource
    ) -> AVAudioNodeTapBlock {
        { [weak source] buffer, _ in
            guard let source else { return }
            let appended = source.audioBufferGate.append(buffer)
            guard appended != .closed else { return }
            let level = rmsLevel(buffer)
            let duration = bufferDuration(buffer)
            Task { @MainActor [weak source] in
                source?.receiveLevel(level, duration: duration, generation: generation)
                // As long a turn as Hermes accepts: send what's there.
                if appended == .recordingFull { source?.finishTurn() }
            }
        }
    }

    /// Opens the gate for a tap-only test, without an engine or recognizer.
    func openForTesting(request: SFSpeechAudioBufferRecognitionRequest?) {
        audioBufferGate.open(request: request, recorder: nil)
    }

    private func receiveLevel(_ level: Float, duration: Duration, generation: UInt64) {
        onLevel?(level, generation)
        guard activeGeneration == generation, !isFinishingRecognition, endsAfterSilence else { return }
        endOfSpeechDetector.receiveLevel(level, duration: duration)
    }

    nonisolated private static func bufferDuration(_ buffer: AVAudioPCMBuffer) -> Duration {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { return .zero }
        return .seconds(Double(buffer.frameLength) / sampleRate)
    }

    nonisolated private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard
            let channelData = buffer.floatChannelData,
            buffer.format.channelCount > 0
        else { return 0 }

        let sampleCount = Int(buffer.frameLength)
        guard sampleCount > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for index in 0..<sampleCount {
            let sample = samples[index]
            sum += sample * sample
        }
        return min(max(sqrt(sum / Float(sampleCount)) * 3.2, 0), 1)
    }
}
