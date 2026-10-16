import Foundation
import Observation

/// A voice call with a group chat. What you say posts to the room like typing;
/// each member's reply is spoken in order, in that member's own Hermes voice.
/// The microphone stays on between replies, and talking over a reply stops it.
@MainActor
@Observable
final class TeamCallModel: Identifiable {
    struct Member: Identifiable, Equatable, Sendable {
        /// The room's member ID.
        let id: String
        let profileID: String
        let name: String
        let imageURL: URL?
        /// Whose voice it speaks with: its profile here, or `peerID/profile`
        /// for an agent on another computer, so the two never share one.
        let voiceKey: String

        init(id: String, profileID: String, name: String, imageURL: URL?, voiceKey: String? = nil) {
            self.id = id
            self.profileID = profileID
            self.name = name
            self.imageURL = imageURL
            self.voiceKey = voiceKey ?? profileID
        }
    }

    struct Line: Identifiable, Equatable, Sendable {
        let id: String
        /// Nil for you.
        let memberID: String?
        let speaker: String
        let text: String
    }

    /// What the call is doing, in plain words.
    enum Activity: Equatable, Sendable {
        case connecting
        case listening
        case hearingYou
        case transcribing
        case sending
        case thinking
        case speaking(memberID: String)
        case muted
        case ended
    }

    let id = UUID()
    let title: String
    let members: [Member]
    let userName: String
    /// Your picture and name for your tile; "You" labels it.
    let userAvatar: (name: String, imageURL: URL?)
    private(set) var isActive = true
    private(set) var isMicrophoneMuted = false
    private(set) var speakingMemberID: String?
    private(set) var outputLevel: Double = 0
    private(set) var inputLevel: Float = 0
    private(set) var partialTranscript: String?
    private(set) var isTranscribing = false
    /// The words being spoken right now.
    private(set) var spokenText: String?
    private(set) var lines: [Line] = []
    private(set) var errorMessage: String?
    private(set) var microphoneState: VoiceInputMeterState = .idle
    private(set) var settings: TeamCallVoiceSettings
    private(set) var isSending = false
    private(set) var hasStarted = false
    /// Members are still answering.
    private(set) var isRoomWorking = false
    /// Replies are waiting to be spoken or playing.
    private(set) var hasQueuedSpeech = false

    private let link: any TeamCallRoomLink
    private let input: any VoiceInputLevelSource
    private let transcription: VoiceTranscriptionSource
    private let hostTranscriber: (@MainActor (Data) async throws -> String)?
    private let deviceRecognizerAvailable: @MainActor () -> Bool
    private let loadSettings: @MainActor () async -> TeamCallVoiceSettings?
    private let onEnded: @MainActor () -> Void
    @ObservationIgnored private var pipeline: TeamCallSpeechPipeline!
    @ObservationIgnored private let bargeIn: TeamCallBargeIn
    @ObservationIgnored private var knownEventIDs: Set<String> = []
    @ObservationIgnored private var outbox: [String] = []
    @ObservationIgnored private var sendsInFlight = 0
    /// Person messages seen in the room; a new one means the last send landed.
    @ObservationIgnored private var humanEventCount = 0
    /// The message on its way, and how many person messages the room had
    /// when it left: one more means Hermes has it.
    @ObservationIgnored private var admission: (token: UUID, humanEvents: Int)?
    @ObservationIgnored private var isWaitingForIdleRoom = false
    @ObservationIgnored private var micMode: MicMode = .off
    @ObservationIgnored private var micGeneration: UInt64 = 0
    @ObservationIgnored private var isMicrophoneAllowed = false
    @ObservationIgnored private var inputSmoother = VoiceInputLevelSmoother()
    @ObservationIgnored private var settingsTask: Task<Void, Never>?

    private enum MicMode: Equatable {
        case off
        /// Your turn: the words go to the room when you pause.
        case turn
        /// A reply is playing: listening only for you cutting in.
        case bargeIn
        /// You cut in: the rest of what you say goes to the room.
        case collecting
    }

    init(
        title: String,
        members: [Member],
        userName: String = "You",
        userAvatar: (name: String, imageURL: URL?) = ("You", nil),
        link: any TeamCallRoomLink,
        voice: @escaping @MainActor (String) -> (any TeamCallVoice)?,
        player: any TeamCallAudioPlayer,
        input: any VoiceInputLevelSource,
        transcription: VoiceTranscriptionSource = .onDevice,
        hostTranscriber: (@MainActor (Data) async throws -> String)? = nil,
        deviceRecognizerAvailable: @escaping @MainActor () -> Bool = { true },
        settings: TeamCallVoiceSettings = .init(),
        loadSettings: @escaping @MainActor () async -> TeamCallVoiceSettings? = { nil },
        now: @escaping () -> ContinuousClock.Instant = { .now },
        onEnded: @escaping @MainActor () -> Void = {}
    ) {
        self.title = title
        self.members = members
        self.userName = userName
        self.userAvatar = userAvatar
        self.link = link
        self.input = input
        self.transcription = transcription
        self.hostTranscriber = hostTranscriber
        self.deviceRecognizerAvailable = deviceRecognizerAvailable
        self.settings = settings
        self.loadSettings = loadSettings
        self.onEnded = onEnded
        bargeIn = TeamCallBargeIn(settings: settings, now: now)
        let voiceKeys = Dictionary(members.map { ($0.id, $0.voiceKey) }, uniquingKeysWith: { first, _ in first })
        var voices: [String: any TeamCallVoice] = [:]
        pipeline = TeamCallSpeechPipeline(player: player) { memberID in
            guard let key = voiceKeys[memberID] else { return nil }
            if let cached = voices[key] { return cached }
            let made = voice(key)
            voices[key] = made
            return made
        }
        pipeline.onStart = { [weak self] segment in self?.segmentStarted(segment) }
        pipeline.onLevel = { [weak self] level in
            self?.outputLevel = level.isFinite ? min(max(level, 0), 1) : 0
        }
        pipeline.onFinish = { [weak self] _ in
            self?.outputLevel = 0
            self?.syncQueuedSpeech()
        }
        pipeline.onFailure = { [weak self] segment in self?.segmentFailed(segment) }
        pipeline.onIdle = { [weak self] in self?.repliesFinished() }
    }

    // MARK: - Presentation

    var activity: Activity {
        guard isActive else { return .ended }
        if let speakingMemberID { return .speaking(memberID: speakingMemberID) }
        if isTranscribing { return .transcribing }
        if partialTranscript?.isEmpty == false { return .hearingYou }
        if !hasStarted { return .connecting }
        if isSending && admission != nil { return .sending }
        if isRoomWorking || hasQueuedSpeech { return .thinking }
        if isMicrophoneMuted { return .muted }
        return .listening
    }

    var statusText: String {
        switch activity {
        case .connecting: "Starting…"
        case .listening: "Listening"
        case .hearingYou: "Hearing you…"
        case .transcribing: "Turning that into text…"
        case .sending: "Sending…"
        case .thinking: "Thinking…"
        case .speaking(let memberID): "\(member(memberID)?.name ?? "Someone") is talking"
        case .muted: "You're muted"
        case .ended: "Call ended"
        }
    }

    /// The one line that matters now: who's talking and what they're saying.
    var caption: Line? {
        if let speakingMemberID, let spokenText {
            return Line(id: "speaking", memberID: speakingMemberID,
                        speaker: member(speakingMemberID)?.name ?? "", text: spokenText)
        }
        if let partialTranscript, !partialTranscript.isEmpty {
            return Line(id: "you-live", memberID: nil, speaker: userName, text: partialTranscript)
        }
        return lines.last
    }

    /// Hermes' own hint for its first `voice.stop_phrases` entry.
    var stopHint: String? {
        settings.stopPhrases.first.map { "Say \u{201C}\($0)\u{201D} to hang up." }
    }

    /// Your turns are heard by this device's speech recognition.
    var transcriptionNeedsDeviceSpeech: Bool {
        transcription == .onDevice || hostTranscriber == nil
    }

    func member(_ id: String) -> Member? {
        members.first { $0.id == id }
    }

    // MARK: - Lifecycle

    /// Starts listening to the room; the microphone follows `setMicrophoneAllowed`.
    func start() {
        guard isActive, !hasStarted else { return }
        hasStarted = true
        let events = link.events
        knownEventIDs = Set(events.map(\.id))
        humanEventCount = events.filter { $0.memberID == nil }.count
        isRoomWorking = link.isWorking
        link.observe { [weak self] in self?.roomChanged() }
        settingsTask = Task { @MainActor [weak self] in
            guard let self, let loaded = await self.loadSettings(), self.isActive else { return }
            self.apply(settings: loaded)
        }
        reconcileMicrophone()
    }

    /// The screen is visible, the app is in front and the microphone is allowed.
    func setMicrophoneAllowed(_ allowed: Bool) {
        isMicrophoneAllowed = allowed
        reconcileMicrophone()
    }

    /// After the person allows the microphone or speech recognition in Settings.
    func retryMicrophone() {
        guard microphoneState == .unavailable else { return }
        microphoneState = .idle
        errorMessage = nil
        reconcileMicrophone()
    }

    func toggleMicrophone() {
        isMicrophoneMuted.toggle()
        if isMicrophoneMuted {
            partialTranscript = nil
            pipeline.isHeld = false
            stopMicrophone()
        }
        reconcileMicrophone()
    }

    /// Hangs up. Messages already sent keep going in the room.
    func end() {
        guard isActive else { return }
        isActive = false
        settingsTask?.cancel()
        stopMicrophone()
        pipeline.interrupt()
        syncQueuedSpeech()
        speakingMemberID = nil
        spokenText = nil
        partialTranscript = nil
        outbox.removeAll()
        link.stopObserving()
        onEnded()
    }

    // MARK: - Room

    private func roomChanged() {
        guard isActive else { return }
        for event in link.events where !knownEventIDs.contains(event.id) {
            knownEventIDs.insert(event.id)
            guard let memberID = event.memberID else {
                humanEventCount += 1
                continue
            }
            receiveReply(event, memberID: memberID)
        }
        if let admission, humanEventCount > admission.humanEvents {
            self.admission = nil
        }
        isRoomWorking = link.isWorking
        flushOutbox()
        reconcileMicrophone()
    }

    private func receiveReply(_ event: TeamCallRoomEvent, memberID: String) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !ChatSilentReply.isMarker(text), text != "(pass)" else { return }
        let member = member(memberID)
        lines.append(Line(id: event.id, memberID: memberID, speaker: member?.name ?? "Agent", text: text))
        trimLines()
        let minimum = member.map { settings.firstSentenceMinimum(for: $0.voiceKey) }
            ?? TeamCallVoiceSettings.defaultFirstSentenceMinimum
        pipeline.enqueue(replyID: event.id, memberID: memberID,
                         chunks: TeamCallSpeechSplitter.chunks(text, firstSentenceMinimum: minimum))
        syncQueuedSpeech()
    }

    private func syncQueuedSpeech() {
        hasQueuedSpeech = pipeline.isBusy
    }

    private func submit(_ text: String) {
        lines.append(Line(id: UUID().uuidString, memberID: nil, speaker: userName, text: text))
        trimLines()
        outbox.append(text)
        flushOutbox()
    }

    /// One message at a time until the room has it, so what you say lands in
    /// the order you said it. A room that can't take another message while it
    /// answers keeps the next one until it settles.
    private func flushOutbox() {
        guard isActive, admission == nil, let text = outbox.first else { return }
        if isWaitingForIdleRoom {
            guard !link.isWorking else { return }
            isWaitingForIdleRoom = false
        }
        outbox.removeFirst()
        let token = UUID()
        admission = (token, humanEventCount)
        sendsInFlight += 1
        isSending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.link.send(text)
            } catch BotModeRoomError.runAlreadyActive {
                self.outbox.insert(text, at: 0)
                self.isWaitingForIdleRoom = true
            } catch is CancellationError {
            } catch {
                // Once the room shows the message, Hermes has it: a later
                // failure belongs to its round, not to the delivery.
                if self.isActive, self.admission?.token == token {
                    self.errorMessage = "That didn't reach the group. Try saying it again."
                }
            }
            self.sendsInFlight -= 1
            self.isSending = self.sendsInFlight > 0
            if self.admission?.token == token { self.admission = nil }
            self.flushOutbox()
        }
    }

    // MARK: - Speech

    private func apply(settings: TeamCallVoiceSettings) {
        self.settings = settings
        bargeIn.update(settings: settings)
        input.silenceLimit = settings.silenceLimit
        reconcileMicrophone()
    }

    private func segmentStarted(_ segment: TeamCallSegment) {
        speakingMemberID = segment.memberID
        spokenText = segment.text
        bargeIn.beginReply(segment.text)
    }

    private func segmentFailed(_ segment: TeamCallSegment) {
        guard isActive, segment.isFirstOfReply else { return }
        let name = member(segment.memberID)?.name ?? "A member"
        errorMessage = "\(name)'s voice couldn't play. Their reply is in the chat."
    }

    private func repliesFinished() {
        syncQueuedSpeech()
        speakingMemberID = nil
        spokenText = nil
        outputLevel = 0
        bargeIn.endReplies()
        reconcileMicrophone()
    }

    // MARK: - Microphone

    private var desiredMicMode: MicMode {
        guard isActive, hasStarted, isMicrophoneAllowed, !isMicrophoneMuted,
              microphoneState != .unavailable else { return .off }
        if micMode == .collecting { return .collecting }
        guard pipeline.isBusy, !pipeline.isHeld else { return .turn }
        return settings.bargeIn && deviceRecognizerAvailable() ? .bargeIn : .off
    }

    private func reconcileMicrophone() {
        let desired = desiredMicMode
        guard desired != micMode else { return }
        switch desired {
        case .off: stopMicrophone()
        case .turn, .bargeIn: startMicrophone(desired)
        case .collecting: break
        }
    }

    private func startMicrophone(_ mode: MicMode) {
        stopMicrophone()
        micMode = mode
        micGeneration &+= 1
        let generation = micGeneration
        inputSmoother.reset()
        input.onLevel = { [weak self] level, callbackGeneration in
            self?.receive(level: level, generation: callbackGeneration)
        }
        input.onTranscript = { [weak self] update, callbackGeneration in
            self?.receive(update: update, generation: callbackGeneration)
        }
        input.onUnavailable = { [weak self] error, callbackGeneration in
            self?.receiveUnavailable(error, generation: callbackGeneration)
        }
        input.onTranscribing = { [weak self] transcribing, callbackGeneration in
            guard let self, callbackGeneration == self.micGeneration else { return }
            self.isTranscribing = transcribing
        }
        // Cutting in is caught on this device; only your own turns go to Hermes.
        let usesHost = mode == .turn && transcription == .hermes && hostTranscriber != nil
        input.transcription = usesHost ? .hermes : .onDevice
        input.hostTranscriber = usesHost ? hostTranscriber : nil
        input.endsAfterSilence = mode == .turn
        input.silenceLimit = settings.silenceLimit
        microphoneState = .starting
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.input.start(generation: generation)
                guard generation == self.micGeneration else { return }
                self.microphoneState = .monitoring
            } catch {
                guard generation == self.micGeneration else { return }
                self.micMode = .off
                self.microphoneState = .unavailable
                self.errorMessage = Self.microphoneMessage(error as? VoiceInputLevelError)
            }
        }
    }

    private func stopMicrophone() {
        micGeneration &+= 1
        micMode = .off
        input.stop()
        input.onLevel = nil
        input.onTranscript = nil
        input.onUnavailable = nil
        input.onTranscribing = nil
        inputLevel = 0
        isTranscribing = false
        if microphoneState != .unavailable { microphoneState = .idle }
    }

    private func receive(level: Float, generation: UInt64) {
        guard generation == micGeneration else { return }
        switch micMode {
        case .bargeIn: bargeIn.receiveLevel(level)
        case .turn where partialTranscript == nil: bargeIn.calibrate(quietLevel: level)
        default: break
        }
        inputLevel = inputSmoother.update(target: level)
    }

    private func receive(update: VoiceRecognitionUpdate, generation: UInt64) {
        guard generation == micGeneration, isActive else { return }
        let text = String(update.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000))
        switch micMode {
        case .off:
            return
        case .bargeIn:
            guard !text.isEmpty, bargeIn.receiveTranscript(text, isFinal: update.isFinal) else {
                // Apple's recognizer ends its session with a final result;
                // start a fresh one so you can still cut in.
                if update.isFinal {
                    bargeIn.restartListening()
                    startMicrophone(.bargeIn)
                }
                return
            }
            // You're talking: stop the voice now and listen.
            pipeline.interrupt()
            syncQueuedSpeech()
            repliesFinishedForBargeIn()
            micMode = .collecting
            input.endsAfterSilence = true
            if update.isFinal {
                finishTurn(text)
            } else {
                partialTranscript = text
            }
        case .turn, .collecting:
            if update.isFinal {
                finishTurn(text)
            } else if !text.isEmpty {
                partialTranscript = text
                // Replies wait while you talk, then play.
                pipeline.isHeld = true
            }
        }
    }

    private func repliesFinishedForBargeIn() {
        speakingMemberID = nil
        spokenText = nil
        outputLevel = 0
        bargeIn.endReplies()
    }

    private func finishTurn(_ text: String) {
        partialTranscript = nil
        stopMicrophone()
        pipeline.isHeld = false
        if !text.isEmpty, !text.contains("\0") {
            if TeamCallStopPhrase.matches(text, phrases: settings.stopPhrases) {
                end()
                return
            }
            errorMessage = nil
            submit(text)
        }
        reconcileMicrophone()
    }

    private func receiveUnavailable(_ error: VoiceInputLevelError, generation: UInt64) {
        guard generation == micGeneration, isActive else { return }
        if error == .hostTranscriptionFailed {
            errorMessage = "Your computer couldn't turn that into text. Try again, or switch Speech to text to This device in Voice settings."
            partialTranscript = nil
            pipeline.isHeld = false
            stopMicrophone()
            reconcileMicrophone()
            return
        }
        stopMicrophone()
        microphoneState = .unavailable
        errorMessage = Self.microphoneMessage(error)
    }

    private static func microphoneMessage(_ error: VoiceInputLevelError?) -> String {
        switch error {
        case .permissionDenied: "bighelp can't use the microphone. Allow it in Settings to talk."
        case .speechPermissionDenied, .speechUnavailable:
            "Speech recognition isn't available. Allow it in Settings, or switch Speech to text to Hermes in Voice settings."
        case .interrupted: "The call was interrupted. End it and start again."
        default: "The microphone couldn't start. End the call and try again."
        }
    }

    private func trimLines() {
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
    }
}
