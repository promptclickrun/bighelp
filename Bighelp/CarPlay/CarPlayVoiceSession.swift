#if os(iOS)
import AVFAudio
import Foundation
import Observation
import Speech

/// What CarPlay needs from the app, set when bighelp starts.
@MainActor
enum BighelpCarPlayServices {
    static var workspace: (@MainActor () async throws -> BighelpShortcutWorkspace)?
    static var settings: SettingsStore?
    /// Makes a computer the one bighelp uses (Settings › CarPlay's), as a Shortcut does.
    static var useGateway: (@MainActor (UUID) throws -> Void)?
    /// The computers, for Settings › CarPlay.
    static var gateways: (@MainActor () -> [BighelpShortcutGateway])?
    /// The agents on a computer (nil: the one in use), for Settings › CarPlay.
    static var agents: (@MainActor (UUID?) async throws -> [BighelpShortcutAgent])?
    /// Faces: saved characters and the computer they're saved for.
    static var companion: CompanionStore?
    static var companionScope: (@MainActor () -> String)?
}

/// A hands-free voice chat with the agent last picked in the car (else the
/// default agent), for the car. The iPhone is
/// usually locked, so its own voice screen can't listen; this runs the same
/// voice session without a screen, using the voice chosen in Settings.
@MainActor
@Observable
final class CarPlayVoiceSession {
    enum Phase: Equatable {
        case connecting, listening, working, speaking, paused
        case problem(String)
    }

    /// Nothing runs until `start`.
    private(set) var phase: Phase = .paused
    private(set) var agentName = "your agent"
    /// The agent being talked to, and its picture, for the car's screen.
    private(set) var agent: CarPlayAgent?
    private(set) var agentImageURL: URL?
    /// The agents on this computer, for the car's list (names and pictures only).
    private(set) var agents: [CarPlayAgent] = []
    private(set) var agentImageURLs: [String: URL] = [:]
    /// The step the agent is on, in plain words, as voice mode shows it; nil between steps.
    private(set) var step: String?
    /// This turn's earlier steps, newest first, a few at most.
    private(set) var earlierSteps: [String] = []
    /// The chat this car connection is in; Talk after a pause goes on in it.
    private(set) var chatID: String?
    private(set) var isMuted = false

    private let workspace: () async throws -> BighelpShortcutWorkspace
    private let settings: () -> SettingsStore?
    private let microphoneAllowed: () -> Bool
    private let speechAllowed: () -> Bool
    private let preference: CarPlayAgentPreference
    private var continuity = CarPlayChatContinuity()
    private var voice: VoiceModel?
    private var live: LiveVoiceModel?
    private var following: Task<Void, Never>?
    /// The chat's live state, for its steps.
    private var chat: ChatModel?
    private var releaseHost: (@MainActor () -> Void)?
    private var generation = 0
    /// What a start is waiting on, so a stall says which step it was.
    private var waitingOn = CarPlayConnectStep.computer
    private var watchdog: Task<Void, Never>?
    /// How long a start may take before the car says what's wrong instead of "Connecting…".
    var connectLimit: Duration = .seconds(20)

    init(
        workspace: @escaping () async throws -> BighelpShortcutWorkspace = {
            guard let provider = BighelpCarPlayServices.workspace else { throw BighelpShortcutServiceError.connectionUnavailable }
            return try await provider()
        },
        settings: @escaping () -> SettingsStore? = { BighelpCarPlayServices.settings },
        microphoneAllowed: @escaping () -> Bool = { AVAudioApplication.shared.recordPermission == .granted },
        speechAllowed: @escaping () -> Bool = { SFSpeechRecognizer.authorizationStatus() == .authorized },
        preference: CarPlayAgentPreference = CarPlayAgentPreference()
    ) {
        self.workspace = workspace
        self.settings = settings
        self.microphoneAllowed = microphoneAllowed
        self.speechAllowed = speechAllowed
        self.preference = preference
    }

    /// Listens. `agentID` is a pick from the car's list: it's saved and talked
    /// to. Without it, the agent already in this connection, else the saved
    /// pick, else the default. The same agent goes on in the same chat; another
    /// agent, or a new connection, starts a new one.
    func start(agentID: String? = nil) async {
        stop()
        generation += 1
        let current = generation
        phase = .connecting
        isMuted = false
        let mode = settings()?.voiceConversationMode ?? .turnBased
        guard microphoneAllowed(), mode == .codexLive || speechAllowed() else {
            phase = .problem(Self.permissionProblem)
            return
        }
        Telemetry.featureUsed(.carplayVoice)
        // Keep the host connection while the car is connected, even with the iPhone locked.
        releaseHost = BighelpShortcutService.holdHostConnection()
        waitingOn = .computer
        watch(current)
        // The computer picked in Settings › CarPlay, if bighelp is using another one.
        if let host = preference.hostID { try? BighelpCarPlayServices.useGateway?(host) }
        do {
            let workspace = try await workspace()
            guard current == generation else { return }
            let agents = workspace.agents.profiles.map(CarPlayAgent.init)
            self.agents = agents
            agentImageURLs = Dictionary(workspace.agents.profiles.compactMap { profile in
                workspace.agents.avatarURL(for: profile).map { (profile.id, $0) }
            }, uniquingKeysWith: { first, _ in first })
            guard let agent = CarPlayAgentChoice.resolve(
                requestedID: agentID ?? continuity.agentID ?? preference.agentID, in: agents,
                fallbackID: workspace.agents.resolvedAgent(explicitID: nil)?.id)
            else {
                phase = .problem("Pick an agent in bighelp on your iPhone first.")
                return releaseHostConnection()
            }
            if agentID == agent.id { preference.agentID = agent.id }
            agentName = agent.name
            self.agent = agent
            agentImageURL = agentImageURLs[agent.id]
            chat = nil
            step = nil
            earlierSteps = []
            waitingOn = .chat
            let (sessionID, _) = try await workspace.readyChat(
                agentID: agent.id, reusing: continuity.reusableSessionID(for: agent.id))
            guard current == generation else { return }
            continuity.remember(sessionID: sessionID, agentID: agent.id)
            chatID = sessionID
            chat = workspace.featureStore.preparedChatModel(id: sessionID)
            let presentation = workspace.featureStore.makeVoicePresentation(
                for: sessionID,
                mode: .pressToTalk,
                transcription: settings()?.voiceTranscription ?? .onDevice,
                conversationMode: mode,
                liveProvider: settings()?.liveVoiceProvider ?? .codexSubscription,
                liveVoice: settings().map { $0.liveVoice(for: $0.liveVoiceProvider) }
                    ?? LiveVoiceProvider.codexSubscription.defaultVoice
            )
            waitingOn = .voice
            if let live = presentation.liveModel {
                self.live = live
                live.start()
                // Live voice declines quietly when its connection is from before a reconnect.
                if live.phase == .idle {
                    phase = .problem(CarPlayConnectStep.voice.problem)
                    return releaseHostConnection()
                }
            } else {
                // Without live voice, this device hears the words itself.
                guard speechAllowed() else {
                    phase = .problem(Self.permissionProblem)
                    return releaseHostConnection()
                }
                voice = presentation.model
                presentation.model.setMonitoringAllowed(true)
            }
            follow()
        } catch {
            guard current == generation else { return }
            phase = .problem("bighelp couldn't reach your computer. Check that it's on and online.")
            releaseHostConnection()
        }
    }

    /// Ends the conversation; a running reply still finishes in the chat.
    func stop() {
        // A start still connecting must not begin listening after this.
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        following?.cancel()
        following = nil
        live?.end()
        live = nil
        if let voice {
            voice.setMonitoringAllowed(false)
            Task { await voice.end() }
        }
        voice = nil
        releaseHostConnection()
        if case .problem = phase {} else { phase = .paused }
    }

    /// The agents for the car's list, names only, cut to `limit`, the one in
    /// use marked. Holds the host connection while it asks.
    func agentRows(limit: Int = CarPlayAgentChoice.maximumListed) async throws -> [CarPlayAgentRow] {
        let release = BighelpShortcutService.holdHostConnection()
        defer { release() }
        let workspace = try await workspace()
        let agents = workspace.agents.profiles.map(CarPlayAgent.init)
        let current = CarPlayAgentChoice.resolve(
            requestedID: continuity.agentID ?? preference.agentID, in: agents,
            fallbackID: workspace.agents.resolvedAgent(explicitID: nil)?.id)
        return CarPlayAgentChoice.rows(for: agents, currentID: current?.id, limit: limit)
    }

    private static let permissionProblem =
        "Open bighelp on your iPhone once and allow the microphone and speech recognition."

    func toggleMute() {
        isMuted.toggle()
        if let live { live.setMuted(isMuted) }
        if let voice, voice.isMicrophoneMuted != isMuted { voice.toggleMicrophone() }
        sync()
    }

    /// A start that's still connecting after `connectLimit` stops and says which step stalled,
    /// so the car never sits on "Connecting…".
    private func watch(_ current: Int) {
        watchdog?.cancel()
        let limit = connectLimit
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.generation == current, self.phase == .connecting else { return }
            let step = self.waitingOn
            self.stop()
            self.phase = .problem(step.problem)
        }
    }

    private func releaseHostConnection() {
        releaseHost?()
        releaseHost = nil
    }

    /// Mirrors the voice session and keeps it listening between turns (the
    /// phone's voice screen does this when it's on screen).
    private func follow() {
        following?.cancel()
        following = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sync()
                await self.nextChange()
            }
        }
    }

    private func nextChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = CarPlayOnce(continuation)
            withObservationTracking {
                _ = voice?.status
                _ = voice?.meterState
                _ = voice?.isAgentRunActive
                _ = live?.phase
                _ = live?.workStatus
                _ = live?.errorMessage
                _ = chat?.liveStepPhrase
                _ = chat?.isSending
            } onChange: {
                once.resume()
            }
            // Mic permission and similar can change without an observed property.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                once.resume()
            }
        }
    }

    private func sync() {
        followSteps()
        if let live {
            phase = switch live.phase {
            case .idle, .preparing, .connecting: .connecting
            case .live: live.workStatus == .working ? .working : .listening
            case .interrupted, .ended: .paused
            case .failed: .problem(live.errorMessage ?? "Live voice isn't available. Choose TTS voice in bighelp's Settings.")
            }
            return
        }
        guard let voice else { return }
        switch voice.status {
        case .listening: phase = .listening
        case .working: phase = .working
        case .speaking: phase = .speaking
        case .paused: phase = .paused
        case .unavailable: phase = .problem("Voice isn't available right now.")
        }
        if voice.meterState == .unavailable {
            phase = .problem("bighelp can't hear you. Check microphone access for bighelp on your iPhone.")
        } else if voice.allowsInputMonitoring, voice.meterState == .idle {
            Task { await voice.startMonitoring() }
        }
    }
}

extension CarPlayVoiceSession {
    /// How many earlier steps the car shows under the current one.
    nonisolated static let earlierStepLimit = 3

    /// The chat's current step, and the ones before it this turn; a new turn starts over.
    fileprivate func followSteps() {
        let next = chat?.liveStepPhrase
        guard next != step else {
            if chat?.isSending != true, step == nil, !earlierSteps.isEmpty { earlierSteps = [] }
            return
        }
        (step, earlierSteps) = Self.steps(after: step, earlier: earlierSteps, next: next, isWorking: chat?.isSending == true)
    }

    /// Plain rules for the car's step lines: a new step pushes the last one down; the turn's end
    /// clears them; the same step twice in a row is one line.
    nonisolated static func steps(after current: String?, earlier: [String], next: String?,
                                  isWorking: Bool) -> (String?, [String]) {
        guard isWorking else { return (nil, []) }
        guard let current, current != next else { return (next, earlier) }
        return (next, Array(([current] + earlier.filter { $0 != current }).prefix(earlierStepLimit)))
    }
}

/// The steps a car's start goes through, each with what the car says if it stalls there.
enum CarPlayConnectStep: Equatable {
    case computer, chat, voice

    var problem: String {
        switch self {
        case .computer: "bighelp couldn't reach your computer. Check that it's on and online."
        case .chat: "Your computer answered, but the chat didn't start. Try again."
        case .voice: "The chat is ready, but voice didn't start. Try again."
        }
    }
}

/// Resumes a continuation once, whichever comes first.
private final class CarPlayOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
#endif
