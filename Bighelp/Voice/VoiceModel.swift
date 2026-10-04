import Foundation
import Observation

@MainActor
@Observable
final class VoiceModel {
    let conversationID: String
    let agentName: String
    let mode: VoiceMode
    /// Where turns become text: this device, or Hermes on the computer.
    let transcription: VoiceTranscriptionSource
    private(set) var isAgentAudioMuted = false
    private(set) var isMicrophoneMuted = false
    private(set) var status: VoiceStatus
    private(set) var isActive = true
    private(set) var isEndPending = false
    private(set) var endErrorMessage: String?
    private(set) var inputLevel: Float = 0
    private(set) var outputLevel: Double = 0
    private(set) var isPlaybackActive = false
    private(set) var meterState: VoiceInputMeterState = .idle
    private(set) var isReduceMotionEnabled = false
    private(set) var transcriptRows: [VoiceTranscriptRow]
    private(set) var partialUserTranscript: String?
    private(set) var liveAgentTranscript: String?
    private(set) var turnErrorMessage: String?
    private(set) var isWalkieTalkieCapturing = false
    private(set) var isAgentRunActive: Bool
    /// A finished turn is being turned into text on the computer.
    private(set) var isTranscribing = false
    /// The person is mid-sentence (words are coming in), so nothing plays over them.
    private(set) var isUserSpeaking = false
    /// The reply is being made into audio and hasn't started playing.
    private var isAwaitingReplyAudio = false

    /// Dead space: the person has finished and the agent's reply isn't playing yet, while it's
    /// transcribed, while the agent works, and while its reply is made into audio. Talking again
    /// or the reply starting ends it.
    var wantsHoldMusic: Bool {
        guard isActive, !isEndPending, !isAgentAudioMuted, !isUserSpeaking, !isWalkieTalkieCapturing else { return false }
        return isTranscribing || isAwaitingWalkieTalkieTranscript || status == .working
            || (status == .speaking && isAwaitingReplyAudio)
    }

    private let client: any VoiceSessionClient
    private let inputLevelSource: any VoiceInputLevelSource
    private let userName: () -> String
    private let now: () -> Date
    private let onStartedTurn: (String) -> Void
    private let onSteeredTurn: (String) -> Void
    private let onCompletedTurn: (String, VoiceAgentReply) -> Void
    private let onFailedTurn: () -> Void
    @ObservationIgnored private let holdMusic: (any VoiceHoldMusicPlaying)?
    @ObservationIgnored private var isHoldMusicPlaying = false
    private var monitoringGeneration: UInt64 = 0
    private var turnGeneration: UInt64 = 0
    private var playbackGeneration: UInt64 = 0
    private var inputSmoother = VoiceInputLevelSmoother()
    private var bargeInDetector = VoiceBargeInDetector()
    private var turnTask: Task<Void, Never>?
    private var steeringTask: Task<Void, Never>?
    private var isMonitoringAllowed = true

    func setMonitoringAllowed(_ allowed: Bool) {
        isMonitoringAllowed = allowed
        if !allowed {
            cancelWalkieTalkieCapture()
            stopMonitoring()
        }
    }
    private var isTurnHandedOff = false
    private var isCollectingBargeIn = false
    private var pendingBargeInTranscript: String?
    private var currentSpokenReply: String?
    private var walkieTalkieTranscript: String?
    private var walkieTalkieGeneration: UInt64 = 0
    /// A released walkie-talkie turn waiting for the computer's transcript.
    private var isAwaitingWalkieTalkieTranscript = false

    init(
        conversationID: String,
        agentName: String = "bighelp",
        status: VoiceStatus = .listening,
        isAgentRunActive: Bool? = nil,
        mode: VoiceMode = .pressToTalk,
        transcription: VoiceTranscriptionSource = .onDevice,
        client: any VoiceSessionClient,
        inputLevelSource: any VoiceInputLevelSource = SilentVoiceInputLevelSource(),
        transcriptRows: [VoiceTranscriptRow] = [],
        userName: @escaping () -> String = { "You" },
        now: @escaping () -> Date = Date.init,
        onStartedTurn: @escaping (String) -> Void = { _ in },
        onSteeredTurn: @escaping (String) -> Void = { _ in },
        onCompletedTurn: @escaping (String, VoiceAgentReply) -> Void = { _, _ in },
        onFailedTurn: @escaping () -> Void = {},
        holdMusic: (any VoiceHoldMusicPlaying)? = nil
    ) {
        self.conversationID = conversationID
        self.agentName = agentName
        self.status = status
        self.isAgentRunActive = isAgentRunActive ?? (status == .working)
        self.mode = mode
        self.transcription = transcription
        self.client = client
        self.inputLevelSource = inputLevelSource
        self.transcriptRows = transcriptRows
        self.userName = userName
        self.now = now
        self.onStartedTurn = onStartedTurn
        self.onSteeredTurn = onSteeredTurn
        self.onCompletedTurn = onCompletedTurn
        self.onFailedTurn = onFailedTurn
        self.holdMusic = holdMusic
        followHoldMusic()
    }

    /// Starts and stops the hold music as `wantsHoldMusic` changes, from every path that changes it.
    private func followHoldMusic() {
        guard let holdMusic else { return }
        let wanted = withObservationTracking { wantsHoldMusic } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followHoldMusic() }
        }
        guard wanted != isHoldMusicPlaying else { return }
        isHoldMusicPlaying = wanted
        if wanted { holdMusic.start() } else { holdMusic.stop() }
    }

    func toggleAgentAudio() {
        isAgentAudioMuted.toggle()
        if isAgentAudioMuted {
            client.stopSpeaking()
            resetPlaybackPresentation()
            if status == .speaking {
                stopMonitoring()
                currentSpokenReply = nil
                status = .listening
            }
        }
    }

    func toggleMicrophone() {
        isMicrophoneMuted.toggle()
        if isMicrophoneMuted {
            cancelWalkieTalkieCapture()
            stopMonitoring()
        }
    }

    func selectStatus(_ status: VoiceStatus) {
        self.status = status
        if !shouldMonitor {
            stopMonitoring()
        }
    }

    func reconcileAgentRun(isActive: Bool) {
        guard isAgentRunActive != isActive else { return }
        isAgentRunActive = isActive
        guard turnTask == nil else { return }
        if isActive, status == .listening {
            status = .working
        } else if !isActive, status == .working {
            if !isWalkieTalkieCapturing { stopMonitoring() }
            status = .listening
        }
    }

    func setReduceMotion(_ enabled: Bool) {
        guard isReduceMotionEnabled != enabled else { return }
        isReduceMotionEnabled = enabled
        if enabled {
            inputSmoother.reset()
            inputLevel = 0
        }
    }

    func startMonitoring() async {
        guard shouldMonitor else {
            stopMonitoring()
            return
        }
        guard meterState != .monitoring, meterState != .starting else { return }

        monitoringGeneration &+= 1
        let generation = monitoringGeneration
        inputSmoother.reset()
        if status == .speaking, let currentSpokenReply {
            bargeInDetector.begin(spokenText: currentSpokenReply)
        }
        inputLevel = 0
        meterState = .starting
        inputLevelSource.onLevel = { [weak self] level, callbackGeneration in
            self?.receive(level: level, generation: callbackGeneration)
        }
        inputLevelSource.onTranscript = { [weak self] update, callbackGeneration in
            self?.receive(update: update, generation: callbackGeneration)
        }
        inputLevelSource.onUnavailable = { [weak self] error, callbackGeneration in
            self?.receiveUnavailable(error, generation: callbackGeneration)
        }
        inputLevelSource.onTranscribing = { [weak self] transcribing, callbackGeneration in
            guard let self, self.owns(callbackGeneration) else { return }
            self.isTranscribing = transcribing
        }
        // Interruptions while the agent speaks are caught on this device;
        // only the person's own turns go to Hermes.
        let usesHost = transcription == .hermes && status != .speaking
        inputLevelSource.transcription = usesHost ? .hermes : .onDevice
        if usesHost {
            let client = self.client
            inputLevelSource.hostTranscriber = { @MainActor audio in try await client.transcribe(audio) }
        } else {
            inputLevelSource.hostTranscriber = nil
        }

        do {
            inputLevelSource.endsAfterSilence = mode != .walkieTalkie
            try await inputLevelSource.start(generation: generation)
            guard owns(generation) else { return }
            guard shouldMonitor else {
                inputLevelSource.stop()
                return
            }
            meterState = .monitoring
        } catch {
            guard owns(generation) else { return }
            inputLevelSource.onLevel = nil
            inputLevelSource.onTranscript = nil
            inputLevelSource.onUnavailable = nil
            inputLevelSource.stop()
            inputLevel = 0
            meterState = .unavailable
        }
    }

    func stopMonitoring() {
        monitoringGeneration &+= 1
        inputLevelSource.stop()
        inputLevelSource.onLevel = nil
        inputLevelSource.onTranscript = nil
        inputLevelSource.onUnavailable = nil
        inputSmoother.reset()
        bargeInDetector.reset()
        isCollectingBargeIn = false
        isTranscribing = false
        isUserSpeaking = false
        inputLevel = 0
        partialUserTranscript = nil
        meterState = .idle
    }

    /// True when Send can end the turn now instead of waiting for quiet.
    var canSendNow: Bool {
        mode == .pressToTalk && status == .listening && meterState == .monitoring && !isTranscribing
            && partialUserTranscript?.isEmpty == false
    }

    /// Ends the turn now: what's been said so far goes to the agent.
    func sendNow() {
        guard canSendNow else { return }
        inputLevelSource.finishNow()
    }

    func waitForMonitoringStart() async {
        while shouldMonitor && meterState != .monitoring && meterState != .unavailable {
            await Task.yield()
        }
    }

    func waitUntilTurnSettles() async {
        while turnTask != nil || steeringTask != nil || status == .working || status == .speaking {
            await Task.yield()
        }
    }

    @discardableResult
    func beginWalkieTalkieCapture() async -> Bool {
        guard let generation = armWalkieTalkieCapture() else { return false }
        return await startArmedWalkieTalkieCapture(generation: generation)
    }

    func armWalkieTalkieCapture() -> UInt64? {
        guard mode == .walkieTalkie,
              !isWalkieTalkieCapturing,
              (status == .listening || isAgentRunActive),
              steeringTask == nil,
              isActive,
              !isMicrophoneMuted else { return nil }
        walkieTalkieTranscript = nil
        partialUserTranscript = nil
        isWalkieTalkieCapturing = true
        walkieTalkieGeneration &+= 1
        return walkieTalkieGeneration
    }

    func startArmedWalkieTalkieCapture(generation: UInt64) async -> Bool {
        guard !Task.isCancelled,
              generation == walkieTalkieGeneration,
              isWalkieTalkieCapturing
        else { return false }
        await startMonitoring()
        guard generation == walkieTalkieGeneration,
              isWalkieTalkieCapturing
        else { return false }
        guard meterState == .monitoring else {
            cancelWalkieTalkieCapture()
            return false
        }
        return true
    }

    @discardableResult
    func endWalkieTalkieCapture(submit: Bool) -> Bool {
        guard mode == .walkieTalkie, isWalkieTalkieCapturing else { return false }
        let transcript = walkieTalkieTranscript
        walkieTalkieGeneration &+= 1
        isWalkieTalkieCapturing = false
        walkieTalkieTranscript = nil
        if submit, transcription == .hermes, meterState == .monitoring {
            // The computer transcribes the recording; the turn goes out when it answers.
            isAwaitingWalkieTalkieTranscript = true
            inputLevelSource.finishNow()
            return true
        }
        stopMonitoring()
        guard submit, let transcript else { return false }
        return submitTranscript(transcript)
    }

    func cancelWalkieTalkieCapture() {
        walkieTalkieGeneration &+= 1
        isAwaitingWalkieTalkieTranscript = false
        guard isWalkieTalkieCapturing || walkieTalkieTranscript != nil else { return }
        isWalkieTalkieCapturing = false
        walkieTalkieTranscript = nil
        stopMonitoring()
    }

    /// Starts a voice turn from a trusted external transcript, such as the
    /// companion Watch. The existing voice client remains the only backend
    /// authority; the external device supplies words, not credentials.
    @discardableResult
    func submitTranscript(_ transcript: String) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 10_000,
              !normalized.contains("\0"),
              isActive else { return false }
        if isAgentRunActive {
            guard steeringTask == nil else { return false }
            beginSteeringTurn(transcript: normalized)
            return true
        }
        guard turnTask == nil, status == .listening else { return false }
        beginTurn(transcript: normalized)
        return true
    }

    @discardableResult
    func end() async -> Bool {
        guard isActive, !isEndPending else { return false }

        stopMonitoring()
        walkieTalkieGeneration &+= 1
        isWalkieTalkieCapturing = false
        walkieTalkieTranscript = nil
        currentSpokenReply = nil
        pendingBargeInTranscript = nil
        resetPlaybackPresentation()
        let handsOffRunningTurn = turnTask != nil || status == .working
        isTurnHandedOff = handsOffRunningTurn
        client.stopSpeaking()
        isEndPending = true
        endErrorMessage = nil

        do {
            try await client.endSession(conversationID: conversationID)
            isEndPending = false
            isActive = false
            return true
        } catch {
            isTurnHandedOff = false
            isEndPending = false
            endErrorMessage = Self.endFailureMessage
            return false
        }
    }

    private static let endFailureMessage = "Voice chat could not end. Try again."

    var allowsInputMonitoring: Bool {
        isMonitoringAllowed && isActive
            && !isMicrophoneMuted
            && (status == .listening || status == .speaking || isAgentRunActive)
            && (mode == .pressToTalk || isWalkieTalkieCapturing)
    }

    private var shouldMonitor: Bool { allowsInputMonitoring }

    private func owns(_ generation: UInt64) -> Bool {
        generation == monitoringGeneration
    }

    private func receive(level: Float, generation: UInt64) {
        guard owns(generation), meterState == .monitoring, shouldMonitor else { return }
        if status == .speaking {
            bargeInDetector.receiveLevel(level)
        }
        guard !isReduceMotionEnabled else {
            inputLevel = 0
            return
        }
        inputLevel = inputSmoother.update(target: level)
    }

    private func receive(update: VoiceRecognitionUpdate, generation: UInt64) {
        guard owns(generation) else { return }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAwaitingWalkieTalkieTranscript, update.isFinal {
            isAwaitingWalkieTalkieTranscript = false
            stopMonitoring()
            if !text.isEmpty, !text.contains("\0") { _ = submitTranscript(String(text.prefix(100_000))) }
            return
        }
        guard meterState == .monitoring, shouldMonitor else { return }
        if update.isFinal, text.isEmpty { isUserSpeaking = false }
        if update.isFinal, text.isEmpty, mode == .pressToTalk, !isCollectingBargeIn {
            // Nothing was heard after all: listen again.
            restartListening()
            return
        }
        guard !text.isEmpty, !text.contains("\0") else { return }
        isUserSpeaking = !update.isFinal
        if mode == .walkieTalkie {
            guard isWalkieTalkieCapturing,
                  status == .listening || isAgentRunActive
            else { return }
            let boundedText = String(text.prefix(100_000))
            walkieTalkieTranscript = boundedText
            partialUserTranscript = boundedText
            return
        }
        if status == .speaking {
            if bargeInDetector.receiveTranscript(text, isFinal: update.isFinal) {
                isCollectingBargeIn = true
                let boundedText = String(text.prefix(100_000))
                partialUserTranscript = boundedText
                currentSpokenReply = nil
                client.stopSpeaking()
                resetPlaybackPresentation()
                status = .listening
                if update.isFinal {
                    submitBargeInTranscript(boundedText)
                }
            } else if update.isFinal {
                restartBargeInMonitoring()
            }
            return
        }
        if isCollectingBargeIn {
            if update.isFinal {
                submitBargeInTranscript(String(text.prefix(100_000)))
            } else {
                partialUserTranscript = String(text.prefix(100_000))
            }
            return
        }
        if isAgentRunActive {
            if update.isFinal {
                _ = submitTranscript(String(text.prefix(100_000)))
            } else {
                partialUserTranscript = String(text.prefix(100_000))
            }
            return
        }
        if update.isFinal {
            beginTurn(transcript: String(text.prefix(100_000)))
        } else {
            partialUserTranscript = String(text.prefix(100_000))
        }
    }

    private func beginTurn(transcript: String) {
        guard turnTask == nil, status == .listening, isActive else { return }
        stopMonitoring()
        turnGeneration &+= 1
        let generation = turnGeneration
        turnErrorMessage = nil
        liveAgentTranscript = nil
        resetPlaybackPresentation()
        transcriptRows.append(
            VoiceTranscriptRow(
                id: UUID().uuidString,
                speaker: normalizedUserName,
                time: Self.timeFormatter.string(from: now()),
                text: transcript
            )
        )
        onStartedTurn(transcript)
        isAgentRunActive = true
        status = .working
        turnTask = Task { @MainActor [weak self] in
            await self?.performTurn(transcript: transcript, generation: generation)
        }
    }

    private func beginSteeringTurn(transcript: String) {
        guard isAgentRunActive, steeringTask == nil, isActive else { return }
        stopMonitoring()
        turnErrorMessage = nil
        transcriptRows.append(
            VoiceTranscriptRow(
                id: UUID().uuidString,
                speaker: normalizedUserName,
                time: Self.timeFormatter.string(from: now()),
                text: transcript
            )
        )
        steeringTask = Task { @MainActor [weak self] in
            await self?.performSteeringTurn(transcript: transcript)
        }
    }

    private func performSteeringTurn(transcript: String) async {
        defer {
            steeringTask = nil
            if mode == .pressToTalk, shouldMonitor {
                Task { @MainActor [weak self] in
                    await self?.startMonitoring()
                }
            }
        }
        do {
            try await client.steer(transcript, conversationID: conversationID)
            guard isActive else { return }
            onSteeredTurn(transcript)
            partialUserTranscript = nil
        } catch is CancellationError {
            // Ending Voice Mode owns cancellation presentation; cancelling local
            // audio or capture must never become an agent cancellation request.
        } catch {
            guard isActive else { return }
            turnErrorMessage = "Voice guidance could not be sent. Try speaking again."
        }
    }

    private func performTurn(transcript: String, generation: UInt64) async {
        defer {
            if generation == turnGeneration {
                turnTask = nil
                beginPendingBargeInTurnIfNeeded()
            }
        }
        do {
            let reply = try await client.respond(
                to: transcript,
                conversationID: conversationID,
                onDraft: { [weak self] draft in
                    guard let self, generation == self.turnGeneration, self.status == .working,
                          !ChatSilentReply.mayBecomeMarker(draft) else { return }
                    self.liveAgentTranscript = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            )
            guard generation == turnGeneration, isActive || isTurnHandedOff else { return }
            isAgentRunActive = false
            // The person spoke, so a bare marker gets Hermes' notice (ChatSilentReply).
            let normalizedReply = ChatSilentReply.isMarker(reply.text)
                ? ChatSilentReply.notice : reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedReply.isEmpty else { throw VoiceSessionError.emptyResponse }
            if isTurnHandedOff {
                onCompletedTurn(transcript, reply)
                status = .listening
                isTurnHandedOff = false
                return
            }
            liveAgentTranscript = nil
            transcriptRows.append(
                VoiceTranscriptRow(
                    id: UUID().uuidString,
                    speaker: reply.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? agentName
                        : reply.speaker,
                    time: Self.timeFormatter.string(from: now()),
                    text: normalizedReply
                )
            )
            onCompletedTurn(transcript, reply)
            if isAgentAudioMuted || isWalkieTalkieCapturing {
                status = .listening
                return
            }
            isAwaitingReplyAudio = true
            status = .speaking
            currentSpokenReply = normalizedReply
            bargeInDetector.begin(spokenText: normalizedReply)
            let ownedPlaybackGeneration = playbackGeneration
            try await client.speak(normalizedReply) { [weak self] event in
                self?.receivePlayback(event, generation: generation, playbackGeneration: ownedPlaybackGeneration)
            }
            guard generation == turnGeneration, isActive else { return }
            resetPlaybackPresentation()
            currentSpokenReply = nil
            stopMonitoring()
            status = .listening
        } catch is CancellationError {
            if generation == turnGeneration, isTurnHandedOff {
                isAgentRunActive = false
                onFailedTurn()
                status = .listening
                isTurnHandedOff = false
                return
            }
            guard generation == turnGeneration, isActive else { return }
            isAgentRunActive = false
            resetPlaybackPresentation()
            if !isCollectingBargeIn, pendingBargeInTranscript == nil {
                stopMonitoring()
                currentSpokenReply = nil
            }
            status = .listening
        } catch {
            if generation == turnGeneration, isTurnHandedOff {
                isAgentRunActive = false
                onFailedTurn()
                status = .listening
                isTurnHandedOff = false
                return
            }
            guard generation == turnGeneration, isActive else { return }
            isAgentRunActive = false
            resetPlaybackPresentation()
            stopMonitoring()
            currentSpokenReply = nil
            liveAgentTranscript = nil
            turnErrorMessage = "Voice response could not be completed. Try speaking again."
            status = .listening
        }
    }

    private func submitBargeInTranscript(_ transcript: String) {
        isCollectingBargeIn = false
        bargeInDetector.reset()
        if turnTask == nil {
            beginTurn(transcript: transcript)
        } else {
            pendingBargeInTranscript = transcript
        }
    }

    private func restartBargeInMonitoring() {
        let spokenReply = currentSpokenReply
        stopMonitoring()
        currentSpokenReply = spokenReply
        if let spokenReply {
            bargeInDetector.begin(spokenText: spokenReply)
        }
        Task { @MainActor [weak self] in
            await self?.startMonitoring()
        }
    }

    private func beginPendingBargeInTurnIfNeeded() {
        guard let transcript = pendingBargeInTranscript else { return }
        pendingBargeInTranscript = nil
        beginTurn(transcript: transcript)
    }

    private func receivePlayback(_ event: VoicePlaybackEvent, generation: UInt64, playbackGeneration: UInt64) {
        guard generation == turnGeneration,
              playbackGeneration == self.playbackGeneration,
              isActive, !isAgentAudioMuted, status == .speaking else { return }
        isAwaitingReplyAudio = false
        switch event {
        case .started:
            isPlaybackActive = true
            outputLevel = 0
        case .level(let level):
            guard isPlaybackActive else { return }
            outputLevel = level.isFinite ? min(max(level, 0), 1) : 0
        case .finished, .failed:
            resetPlaybackPresentation()
        }
    }

    private func resetPlaybackPresentation() {
        isAwaitingReplyAudio = false
        playbackGeneration &+= 1
        isPlaybackActive = false
        outputLevel = 0
    }

    private func restartListening() {
        stopMonitoring()
        Task { @MainActor [weak self] in await self?.startMonitoring() }
    }

    private func receiveUnavailable(_ error: VoiceInputLevelError, generation: UInt64) {
        guard owns(generation), isActive else { return }
        if error == .hostTranscriptionFailed {
            isAwaitingWalkieTalkieTranscript = false
            turnErrorMessage = "Your computer couldn't turn that into text. Try again, or switch Speech to text to This device in Voice settings."
            if mode == .pressToTalk { restartListening() } else { stopMonitoring() }
            return
        }
        inputLevelSource.stop()
        inputLevelSource.onLevel = nil
        inputLevelSource.onTranscript = nil
        inputLevelSource.onUnavailable = nil
        inputLevel = 0
        meterState = .unavailable
        isWalkieTalkieCapturing = false
        walkieTalkieTranscript = nil
        _ = error
    }

    private var normalizedUserName: String {
        let value = userName().trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "You" : value
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

enum VoiceInputMeterState: Equatable, Sendable {
    case idle
    case starting
    case monitoring
    case unavailable
}
