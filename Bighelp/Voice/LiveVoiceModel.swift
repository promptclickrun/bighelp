import Foundation
import Observation

@MainActor
protocol LiveVoiceAudioPeer: AnyObject {
    var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)? { get set }
    var onAudioRoute: (@MainActor (String) -> Void)? { get set }
    var onInterruption: (@MainActor (Bool) -> Void)? { get set }
    func makeOffer() async throws -> String
    func applyAnswer(_ sdp: String) async throws
    func setMuted(_ muted: Bool)
    func setPlaybackMuted(_ muted: Bool)
    func setSpeakerEnabled(_ enabled: Bool) throws
    func setDefaultSpeakerOutput() throws
    func resumeAudio() throws
    func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics
    func close()
}

extension BighelpRealtimeAudioPeer: LiveVoiceAudioPeer {}

enum LiveVoiceWorkStatus: Equatable, Sendable {
    case idle
    case working
    case resultSent

    var title: String {
        switch self {
        case .idle: ""
        case .working: "Working with Hermes"
        case .resultSent: "Result sent to voice"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: ""
        case .working: "arrow.triangle.2.circlepath"
        case .resultSent: "checkmark.circle"
        }
    }
}

/// Retained only by the live-voice presentation. Does not observe/rebuild the chat
/// transcript for audio meters and never invokes the legacy speech recognizer.
@MainActor
@Observable
final class LiveVoiceModel {
    enum Phase: Equatable {
        case idle, preparing, connecting, live, interrupted, ended, failed
        var title: String {
            switch self {
            case .idle: "Ready for live voice"
            case .preparing: "Preparing live voice"
            case .connecting: "Connecting audio"
            case .live: "Live voice connected"
            case .interrupted: "Audio paused"
            case .ended: "Live voice ended"
            case .failed: "Live voice unavailable"
            }
        }
    }

    struct Transcript: Identifiable, Equatable {
        let id: UUID
        let role: String
        var text: String
    }

    let owner: LiveVoiceOwner
    let agentName: String
    private(set) var provider: LiveVoiceProvider = .codexSubscription
    private(set) var voice = "cove"
    private(set) var phase: Phase = .idle
    private(set) var isMuted = false
    private(set) var isSpeakerMuted = false
    private(set) var speakerEnabled = false
    private(set) var supportsSpeechInterrupt = false
    private(set) var audioRoute = "System audio route"
    private(set) var errorMessage: String?
    private(set) var cleanupMessage: String?
    private(set) var transcripts: [Transcript] = []
    private(set) var userCaption = ""
    private(set) var assistantCaption = ""
    private(set) var workStatus: LiveVoiceWorkStatus = .idle
    private(set) var jobs: [LiveVoiceJob] = []
    private(set) var controllingJobIDs: Set<String> = []
    private(set) var jobErrors: [String: String] = [:]
    private(set) var isRefreshingJobs = false
    private(set) var media = BighelpRealtimeAudioPeer.MediaStatistics()
    /// Your microphone's and the agent's loudness (0–1) in the last media reading, for a visualizer.
    var inputLevel: Double { media.inputAudioLevel }
    var outputLevel: Double { media.outputAudioLevel }
    private(set) var mediaStatus = "No native media observed"

    @ObservationIgnored private let client: LiveVoiceControlClient
    @ObservationIgnored private let makePeer: @MainActor () -> any LiveVoiceAudioPeer
    @ObservationIgnored private var peer: (any LiveVoiceAudioPeer)?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    /// Observed twin of `closingTask`: Start re-enables the moment host
    /// cleanup settles, so a failed call can be retried on the same screen.
    private(set) var isClosing = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var voiceID: String?
    @ObservationIgnored private var providerStarted = false
    @ObservationIgnored private var nativeConnected = false
    @ObservationIgnored private var answerApplied = false
    @ObservationIgnored private var offerSubmitted = false
    @ObservationIgnored private var jobsRevision: UInt64 = 0
    @ObservationIgnored private var jobsRequest = UUID()
    @ObservationIgnored private var isSpeechControlPending = false
    @ObservationIgnored private var admittedDelegationIDs: Set<String> = []

    init(
        agentName: String,
        provider: LiveVoiceProvider = .codexSubscription,
        voice: String? = nil,
        client: LiveVoiceControlClient,
        makePeer: @escaping @MainActor () -> any LiveVoiceAudioPeer = { BighelpRealtimeAudioPeer() }
    ) {
        self.agentName = agentName
        self.provider = provider
        let selectedVoice = voice ?? provider.defaultVoice
        self.voice = provider.voices.contains(selectedVoice) ? selectedVoice : provider.defaultVoice
        self.client = client
        owner = client.owner
        self.makePeer = makePeer
    }

    var isCallOpen: Bool { [.preparing, .connecting, .live, .interrupted].contains(phase) }
    var canStart: Bool { !isCallOpen && !isClosing && client.hasCurrentOwner }
    var canControlAudio: Bool { phase == .live || phase == .interrupted }
    var activeJobCount: Int { jobs.filter { !$0.isTerminal }.count }

    func configure(provider: LiveVoiceProvider, voice: String) {
        guard canStart, provider.voices.contains(voice) else { return }
        self.provider = provider
        self.voice = voice
    }

    /// No auto-start in onAppear. A Start tap is the sole microphone/auth gate.
    func start() {
        guard canStart else { return }
        generation = UUID()
        let token = generation
        let id = "voice_\(UUID().uuidString)"
        voiceID = id
        phase = .preparing
        errorMessage = nil
        cleanupMessage = nil
        providerStarted = false
        nativeConnected = false
        answerApplied = false
        offerSubmitted = false
        isMuted = false
        isSpeakerMuted = false
        speakerEnabled = false
        media = .init()
        mediaStatus = "No native media observed"
        userCaption = ""
        assistantCaption = ""
        workStatus = .idle
        admittedDelegationIDs = []
        transcripts = []
        // The prior voice's jobs stay in its host-owned inbox. Do not silently
        // attach their results or controls to this fresh voice generation.
        jobs = []
        jobErrors = [:]
        controllingJobIDs = []
        jobsRevision &+= 1
        let selectedProvider = provider
        let selectedVoice = voice
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await client.status(provider: selectedProvider)
                try requireCurrent(token)
                supportsSpeechInterrupt = status["interruptSupported"]?.boolean == true
                guard status["available"]?.boolean != false, status["enabled"]?.boolean != false else {
                    throw LiveVoiceControlError.unavailable
                }
                let nextPeer = makePeer()
                peer = nextPeer
                bind(nextPeer, generation: token)
                let offer = try await nextPeer.makeOffer()
                try requireCurrent(token)
                try nextPeer.setDefaultSpeakerOutput()
                speakerEnabled = true
                phase = .connecting
                offerSubmitted = true
                let answer = try await client.offer(
                    voiceID: id, provider: selectedProvider, voice: selectedVoice, sdp: offer
                )
                try requireCurrent(token)
                try await nextPeer.applyAnswer(answer)
                try requireCurrent(token)
                answerApplied = true
                reconcileReadiness()
                startMonitor(generation: token)
            } catch {
                guard generation == token else { return }
                fail(error, generation: token)
            }
            if generation == token { startTask = nil }
        }
    }

    /// Immediately stops native media, then requests host detach/close. Accepted
    /// jobs are never cancelled here, on disappearance, or on interruption.
    func end() {
        guard isCallOpen || peer != nil else { return }
        let id = offerSubmitted ? voiceID : nil
        stopLocal()
        phase = .ended
        if let id { requestClose(id) }
    }

    /// App composition must call synchronously before switching host/account or
    /// replacing the exact owning session. Never retarget this retained client.
    func invalidateOwner() {
        stopLocal()
        client.invalidate()
        phase = .ended
        voiceID = nil
        transcripts = []
        userCaption = ""
        assistantCaption = ""
        workStatus = .idle
        admittedDelegationIDs = []
        jobs = []
        jobErrors = [:]
        errorMessage = nil
        cleanupMessage = nil
    }

    func setMuted(_ muted: Bool) {
        guard canControlAudio else { return }
        isMuted = muted
        peer?.setMuted(muted)
    }

    func setSpeakerMuted(_ muted: Bool) {
        guard canControlAudio else { return }
        isSpeakerMuted = muted
        peer?.setPlaybackMuted(muted)
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        guard canControlAudio else { return }
        do {
            try peer?.setSpeakerEnabled(enabled)
            speakerEnabled = enabled
        } catch { errorMessage = Self.safeMessage(error) }
    }

    func resumeAudio() {
        guard phase == .interrupted, client.hasCurrentOwner else { return }
        do {
            try peer?.resumeAudio()
            // Route loss may have muted the native track. Restore only this
            // explicitly chosen microphone state, never an automatic unmute.
            peer?.setMuted(isMuted)
            phase = .connecting
            reconcileReadiness()
        } catch { errorMessage = Self.safeMessage(error) }
    }

    func interruptSpeech() async {
        guard phase == .live, let id = voiceID, !isSpeechControlPending else { return }
        let token = generation
        isSpeechControlPending = true
        defer { if generation == token { isSpeechControlPending = false } }
        do {
            try await client.interruptSpeech(voiceID: id)
            try requireCurrent(token)
            // A control receipt is not evidence that audible output stopped.
        } catch {
            guard generation == token else { return }
            errorMessage = Self.safeMessage(error)
        }
    }

    func refreshJobs() async {
        guard let id = voiceID, client.hasCurrentOwner else { return }
        let token = generation
        let revision = jobsRevision
        let requestID = UUID()
        jobsRequest = requestID
        isRefreshingJobs = true
        defer { if jobsRequest == requestID { isRefreshingJobs = false } }
        do {
            let snapshot = try await client.jobs(voiceID: id)
            guard generation == token, jobsRequest == requestID, jobsRevision == revision,
                  client.hasCurrentOwner else { return }
            jobs = snapshot
        } catch {
            guard generation == token, jobsRequest == requestID, client.hasCurrentOwner else { return }
            errorMessage = "Could not refresh voice tasks. Existing task state has been kept."
        }
    }

    func controlJob(_ jobID: String, action: LiveVoiceJobAction) async {
        guard let id = voiceID, client.hasCurrentOwner,
              let job = jobs.first(where: { $0.id == jobID }), job.isControllable,
              !controllingJobIDs.contains(jobID) else { return }
        let token = generation
        controllingJobIDs.insert(jobID)
        jobErrors.removeValue(forKey: jobID)
        jobsRevision &+= 1
        defer { if generation == token { controllingJobIDs.remove(jobID) } }
        do {
            try await client.control(voiceID: id, job: job, action: action)
            guard generation == token, client.hasCurrentOwner else { return }
            jobsRevision &+= 1
            await refreshJobs()
        } catch {
            guard generation == token, client.hasCurrentOwner else { return }
            jobErrors[jobID] = "The task change was not confirmed. Refresh its status before trying again."
        }
    }

    /// Forward only the authenticated transport's voice.live.event payload and
    /// its captured owner, including events arriving before offer completion.
    func receive(_ payload: [String: BighelpJSONValue], owner eventOwner: LiveVoiceOwner) {
        guard eventOwner == owner, client.hasCurrentOwner,
              let id = voiceID, payload["voiceId"]?.string == id,
              let event = payload["event"]?.object, let kind = event["kind"]?.string else { return }
        if kind == "job", let document = event["job"]?.object,
           let job = try? LiveVoiceJob(document: document) {
            applyJob(job)
            return
        }
        guard isCallOpen else { return }
        switch kind {
        case "started":
            providerStarted = true
            reconcileReadiness()
        case "sideband_attached":
            guard provider == .apiKey else { return }
            providerStarted = true
            reconcileReadiness()
        case "transcript_delta":
            guard let text = event["text"]?.string, text.utf8.count <= 32_768 else { return }
            switch event["role"]?.string {
            case "user": userCaption = String((userCaption + text).suffix(8_000))
            case "assistant": assistantCaption = String((assistantCaption + text).suffix(8_000))
            default: break
            }
        case "transcript_done":
            guard let role = event["role"]?.string, ["user", "assistant"].contains(role),
                  let text = event["text"]?.string, text.utf8.count <= 32_768 else { return }
            transcripts.append(Transcript(id: UUID(), role: role, text: String(text.prefix(8_000))))
            if transcripts.count > 40 { transcripts.removeFirst(transcripts.count - 40) }
            if role == "user" { userCaption = "" } else { assistantCaption = "" }
        case "audio_cleared":
            assistantCaption = ""
            // No task state transition and no cancellation operation.
        case "delegation_status":
            applyDelegationStatus(event)
        case "provider_error":
            if event["fatal"]?.boolean == false {
                errorMessage = "Voice reported a temporary error. Your call is still connected."
            } else {
                fail(LiveVoiceControlError.unavailable, generation: generation)
            }
        case "transport_closed", "closed":
            stopLocal()
            phase = .ended
            cleanupMessage = "The host closed live voice. Accepted tasks were not cancelled."
        default: break // Unknown events cannot execute/control tasks.
        }
    }

    private func applyJob(_ job: LiveVoiceJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            guard jobs[index].runID == job.runID, job.revision >= jobs[index].revision else { return }
            jobs[index] = job
        } else {
            guard jobs.count < 200 else { return }
            jobs.append(job)
        }
        jobsRevision &+= 1
    }

    private func applyDelegationStatus(_ event: [String: BighelpJSONValue]) {
        guard let id = event["delegationId"]?.string,
              !id.isEmpty, id.utf8.count <= 180,
              let state = event["state"]?.string else { return }
        switch state {
        case "working":
            if admittedDelegationIDs.count < 8 || admittedDelegationIDs.contains(id) {
                admittedDelegationIDs.insert(id)
            }
            if !admittedDelegationIDs.isEmpty { workStatus = .working }
        case "result_sent":
            guard admittedDelegationIDs.remove(id) != nil else { return }
            workStatus = admittedDelegationIDs.isEmpty ? .resultSent : .working
        default:
            break
        }
    }

    private func bind(_ peer: any LiveVoiceAudioPeer, generation token: UUID) {
        peer.onConnectionState = { [weak self] state in
            guard let self, self.generation == token, self.isCallOpen else { return }
            self.nativeConnected = state == .connected
            if state == .failed || state == .closed {
                self.fail(BighelpRealtimeAudioPeer.Failure.negotiation, generation: token)
            } else if state == .disconnected {
                self.phase = .connecting
            } else {
                self.reconcileReadiness()
            }
        }
        peer.onAudioRoute = { [weak self] route in
            guard let self, self.generation == token else { return }
            self.audioRoute = route
        }
        peer.onInterruption = { [weak self] interrupted in
            guard let self, self.generation == token, self.isCallOpen else { return }
            if interrupted { self.phase = .interrupted }
            else if self.phase == .interrupted, self.nativeConnected {
                self.phase = .connecting
                self.reconcileReadiness()
            }
        }
    }

    private func reconcileReadiness() {
        guard isCallOpen, phase != .interrupted else { return }
        if providerStarted && nativeConnected && answerApplied && media.audioDeviceRunning { phase = .live }
    }

    private func requireCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, isCallOpen, client.hasCurrentOwner else {
            throw LiveVoiceControlError.wrongOwner
        }
    }

    /// One more media reading now: a visualizer wants several a second, the monitor takes one.
    func refreshLevels() async {
        guard isCallOpen, let peer else { return }
        let token = generation
        guard let statistics = try? await peer.statistics(), generation == token else { return }
        media = statistics
    }

    private func startMonitor(generation token: UUID) {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            var disconnectedSince: ContinuousClock.Instant? = .now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == token, self.isCallOpen else { return }
                guard self.client.hasCurrentOwner else { self.invalidateOwner(); return }
                if self.phase == .live || self.phase == .interrupted {
                    disconnectedSince = nil
                } else {
                    if disconnectedSince == nil { disconnectedSince = .now }
                    if let disconnectedSince, ContinuousClock.now - disconnectedSince > .seconds(20) {
                        self.fail(BighelpRealtimeAudioPeer.Failure.timeout, generation: token)
                        return
                    }
                }
                if let peer = self.peer {
                    do {
                        let statistics = try await peer.statistics()
                        guard self.generation == token else { return }
                        self.media = statistics
                        self.reconcileReadiness()
                        self.mediaStatus = statistics.hasInboundMedia && statistics.hasOutboundMedia
                            ? "Native audio packets sent and received"
                            : statistics.hasInboundMedia ? "Native audio packets received" : "Waiting for native audio packets"
                    } catch {
                        guard self.generation == token else { return }
                        self.mediaStatus = "Native media statistics unavailable"
                    }
                }
            }
        }
    }

    private func stopLocal() {
        generation = UUID()
        startTask?.cancel()
        startTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        peer?.onConnectionState = nil
        peer?.onAudioRoute = nil
        peer?.onInterruption = nil
        peer?.close()
        peer = nil
        nativeConnected = false
        isSpeechControlPending = false
        controllingJobIDs = []
        isRefreshingJobs = false
        jobsRequest = UUID()
    }

    private func fail(_ error: any Error, generation token: UUID) {
        guard generation == token else { return }
        let id = offerSubmitted ? voiceID : nil
        stopLocal()
        phase = .failed
        errorMessage = Self.safeMessage(error)
        if let id { requestClose(id) }
    }

    private func requestClose(_ id: String) {
        guard client.hasCurrentOwner else { return }
        cleanupMessage = "Audio stopped on this device. Confirming host cleanup…"
        isClosing = true
        closingTask = Task { @MainActor [weak self, client] in
            defer {
                self?.closingTask = nil
                self?.isClosing = false
            }
            do {
                try await client.close(voiceID: id)
                guard let self, self.voiceID == id, client.hasCurrentOwner else { return }
                self.cleanupMessage = "Host acknowledged closing voice. Accepted tasks continue independently."
            } catch {
                guard let self, self.voiceID == id, client.hasCurrentOwner else { return }
                self.cleanupMessage = "Audio stopped on this device. Host cleanup is unconfirmed; tasks were not cancelled."
            }
        }
    }

    static func safeMessage(_ error: any Error) -> String {
        if let error = error as? BighelpRealtimeAudioPeer.Failure { return error.localizedDescription }
        if let error = error as? LiveVoiceControlError { return error.localizedDescription }
        // Plain words for host answers. Never surface arbitrary provider or
        // transport text, SDP or headers.
        switch error as? WorkspaceClientError {
        case .authenticationRequired?:
            return "Sign in to your computer again, then try live voice."
        case .unavailable?:
            return "Live voice isn't set up on your computer. Use TTS voice mode instead."
        case .rejected(let code, _)? where code == "voice_already_active":
            return "Another live voice call is still open with your computer. End it, then try again."
        case .rejected(let code, _)? where code == "profile_not_found":
            return "This agent is no longer on your computer."
        case .rejected(let code?, _)? where code.hasPrefix("voice_provider_"):
            return providerMessage(String(code.dropFirst("voice_provider_".count)))
        case .ownerChanged?:
            return "Your connection to your computer changed. Close voice and open it again."
        case .some:
            return "Your computer couldn't start the Codex voice call. Try again, or use TTS voice mode."
        case nil:
            return "Live voice couldn't connect. Try again, or use TTS voice mode."
        }
    }

    /// The plugin's fixed provider reason (`voice_provider_<reason>`) in plain words.
    private static func providerMessage(_ reason: String) -> String {
        switch reason {
        case "authentication_failed", "ambiguous_auth":
            "Codex sign-in on your computer didn't work. Run `hermes auth add openai-codex` there, then try again."
        case "credentials_unavailable":
            "bighelp couldn't read this agent's Codex sign-in on your computer. Update the bighelp plugin and restart Hermes, then try again."
        case "access_denied":
            "Your Codex account can't start live voice right now."
        case "rate_limited":
            "Codex is limiting voice calls right now. Wait a minute, then try again."
        case "setup_timeout", "startup_timeout", "session_not_started":
            "Codex took too long to start the call. Try again."
        case "invalid_sdp", "audio_only_required", "invalid_call_identity", "invalid_public_answer":
            "Codex and this \(BighelpPlatform.isMac ? "Mac" : "phone") couldn't agree on audio settings. Try again."
        case "unsupported_voice":
            "That voice isn't available for live voice. Pick another in Settings › Voice."
        case "explicit_api_key_mode_required":
            "API-key live voice needs an OpenAI key on your computer."
        default:
            "Codex couldn't start the voice call. Try again, or use TTS voice mode."
        }
    }
}
