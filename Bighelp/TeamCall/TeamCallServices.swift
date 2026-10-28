import Foundation

/// What a team call needs from the room's host. The call button shows only
/// when every member can speak there.
@MainActor
protocol TeamCallServices: AnyObject {
    /// False when the microphone is simulated, so no permission is asked.
    var usesDeviceMicrophone: Bool { get }
    func supportsVoice(profileIDs: [String]) -> Bool
    /// The member's own voice: Hermes synthesizes with that profile's `tts.*`.
    func makeVoice(profileID: String) -> (any TeamCallVoice)?
    func makePlayer() -> any TeamCallAudioPlayer
    func makeInput() -> any VoiceInputLevelSource
    /// Hermes speech to text, used when Settings chose it.
    func makeTranscriber(profileID: String) -> (@MainActor (Data) async throws -> String)?
    /// The members' Hermes voice settings, or nil when none could be read.
    func loadSettings(profileIDs: [String]) async -> TeamCallVoiceSettings?
}

extension DirectHermesVoiceSpeechOutput: TeamCallVoice {}

/// Plays team call audio through the conversation audio session, alongside
/// the microphone.
@MainActor
final class SystemTeamCallAudioPlayer: TeamCallAudioPlayer {
    private let playback = AVAudioPlayerVoicePlayback(use: .conversation)

    func play(_ audio: TeamCallAudio, onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        try await playback.play(audio.data, mimeType: audio.mimeType, onPlayback: onPlayback)
    }

    func stop() {
        playback.stop()
    }
}

/// A Direct Hermes host's voices, microphone and settings, bound to the
/// connection that was current when the call started.
@MainActor
final class DirectHermesTeamCallServices: TeamCallServices {
    private weak var connections: WorkspaceConnectionStore?
    private let authority: WorkspaceAuthority

    init(connections: WorkspaceConnectionStore, authority: WorkspaceAuthority) {
        self.connections = connections
        self.authority = authority
    }

    var usesDeviceMicrophone: Bool { true }

    private var current: (workspace: DirectHermesWorkspaceClient, owner: WorkspaceOwner)? {
        guard let connections, let owner = connections.owner, owner.authority == authority,
              let workspace = connections.workspace else { return nil }
        return (workspace, owner)
    }

    func supportsVoice(profileIDs: [String]) -> Bool {
        guard let current, !profileIDs.isEmpty else { return false }
        return profileIDs.allSatisfy {
            current.workspace.capabilities.supports(.voiceOutput, owner: current.owner, profileID: $0)
        }
    }

    func makeVoice(profileID: String) -> (any TeamCallVoice)? {
        guard let current else { return nil }
        // A voice chosen for this agent on this device (Settings › Voice) speaks here too, as in its chats.
        if let choice = OnDeviceVoiceChoices.shared.choice(computer: authority.cacheScopeID, agentID: profileID),
           let model = OnDeviceVoiceModel.model(id: choice.modelID), OnDeviceSpeechEngine.shared.canSpeak(model) {
            return OnDeviceTeamCallVoice(model: model, voice: choice.voice, engine: .shared)
        }
        return DirectHermesVoiceSpeechOutput(
            workspace: current.workspace, owner: current.owner, profileID: profileID,
            currentOwner: { [weak connections] in connections?.owner }
        )
    }

    func makePlayer() -> any TeamCallAudioPlayer {
        SystemTeamCallAudioPlayer()
    }

    func makeInput() -> any VoiceInputLevelSource {
        AVAudioEngineVoiceInputLevelSource()
    }

    func makeTranscriber(profileID: String) -> (@MainActor (Data) async throws -> String)? {
        guard let connections, let current else { return nil }
        return connections.hosts.selectedWorkspace?.nativeClient?.makeVoiceTranscriber(
            profileID: profileID, owner: current.owner,
            currentOwner: { [weak connections] in connections?.owner }
        )
    }

    func loadSettings(profileIDs: [String]) async -> TeamCallVoiceSettings? {
        guard let current else { return nil }
        var configs: [(profileID: String, config: [String: BighelpJSONValue])] = []
        for profileID in profileIDs {
            let scope = DirectHermesCoreRequestScope(
                workspace: current.workspace, owner: current.owner,
                currentOwner: { [weak connections] in connections?.owner }
            )
            // A host that won't share one profile's settings leaves that
            // member on Hermes' defaults.
            guard let profile = try? DirectHermesCoreRequestScope.profile(profileID),
                  (try? scope.require(.voiceOutput, profile: profile)) != nil,
                  let config = try? await scope.perform(.workspaceConfigGet, ["profile": .string(profile)])
            else { continue }
            configs.append((profileID, config))
        }
        return configs.isEmpty ? nil : TeamCallVoiceSettings.resolve(configs: configs)
    }
}

/// A member whose voice runs on this device: each piece is made here, as WAV, and played in turn.
@MainActor
final class OnDeviceTeamCallVoice: TeamCallVoice {
    private let model: OnDeviceVoiceModel
    private let voice: String
    private let engine: OnDeviceSpeechEngine

    init(model: OnDeviceVoiceModel, voice: String, engine: OnDeviceSpeechEngine) {
        self.model = model
        self.voice = voice
        self.engine = engine
    }

    func synthesize(_ text: String) async throws -> TeamCallAudio {
        TeamCallAudio(data: try await engine.synthesize(text, model: model, voice: voice), mimeType: "audio/wav")
    }
}
