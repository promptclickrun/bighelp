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

    private(set) var phase: Phase = .connecting
    private(set) var agentName = "your agent"
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
    private var releaseHost: (@MainActor () -> Void)?
    private var generation = 0

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
        // Keep the host connection while the car is connected, even with the iPhone locked.
        releaseHost = BighelpShortcutService.holdHostConnection()
        do {
            let workspace = try await workspace()
            guard current == generation else { return }
            let agents = workspace.agents.profiles.map(CarPlayAgent.init)
            guard let agent = CarPlayAgentChoice.resolve(
                requestedID: agentID ?? continuity.agentID ?? preference.agentID, in: agents,
                fallbackID: workspace.agents.resolvedAgent(explicitID: nil)?.id)
            else {
                phase = .problem("Pick an agent in bighelp on your iPhone first.")
                return releaseHostConnection()
            }
            if agentID == agent.id { preference.agentID = agent.id }
            agentName = agent.name
            let (sessionID, _) = try await workspace.readyChat(
                agentID: agent.id, reusing: continuity.reusableSessionID(for: agent.id))
            guard current == generation else { return }
            continuity.remember(sessionID: sessionID, agentID: agent.id)
            chatID = sessionID
            let presentation = workspace.featureStore.makeVoicePresentation(
                for: sessionID,
                mode: .pressToTalk,
                transcription: settings()?.voiceTranscription ?? .onDevice,
                conversationMode: mode,
                liveProvider: settings()?.liveVoiceProvider ?? .codexSubscription,
                liveVoice: settings().map { $0.liveVoice(for: $0.liveVoiceProvider) }
                    ?? LiveVoiceProvider.codexSubscription.defaultVoice
            )
            if let live = presentation.liveModel {
                self.live = live
                live.start()
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
