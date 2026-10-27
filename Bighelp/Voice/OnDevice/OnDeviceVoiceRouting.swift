import Foundation

/// An agent's speech for voice chats and Auto TTS: its on-device voice when one is chosen for it
/// on this device and downloaded, else the computer's own speech provider. Checked on each reply,
/// so a change in Settings reaches the next one.
@MainActor
final class OnDeviceRoutedSpeechOutput: VoiceSpeechOutput {
    private let host: any VoiceSpeechOutput
    private let choice: @MainActor () -> OnDeviceVoiceChoices.Choice?
    private let engine: OnDeviceSpeechEngine
    private let use: VoiceAudioUse

    init(host: any VoiceSpeechOutput, use: VoiceAudioUse = .conversation,
         engine: OnDeviceSpeechEngine = .shared,
         choice: @escaping @MainActor () -> OnDeviceVoiceChoices.Choice?) {
        self.host = host
        self.use = use
        self.engine = engine
        self.choice = choice
    }

    func speak(_ text: String, rate: Float) async throws {
        try await speak(text, rate: rate) { _ in }
    }

    func speak(_ text: String, rate: Float,
               onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        if let choice = choice(), let model = OnDeviceVoiceModel.model(id: choice.modelID), engine.canSpeak(model) {
            try await engine.speak(text, model: model, voice: choice.voice, rate: rate, use: use, owner: self,
                                   onPlayback: onPlayback)
        } else {
            try await host.speak(text, rate: rate, onPlayback: onPlayback)
        }
    }

    func stop() {
        engine.stop(owner: self)
        host.stop()
    }
}

/// Adds this device's voices to each agent's speech providers in Voice settings. Choosing one is
/// saved on this device for that agent (`OnDeviceVoiceChoices`); the computer's own provider
/// stays as it was, for its other apps. Choosing a computer provider again clears it.
@MainActor
final class OnDeviceVoiceSettingsClient: VoiceSettingsClient {
    private let host: any VoiceSettingsClient
    private let computer: String
    private let choices: OnDeviceVoiceChoices
    private let engine: OnDeviceSpeechEngine
    private let models: [OnDeviceVoiceModel]
    /// The computer's revision behind each merged one this client handed out.
    private var hostRevisions: [String: String] = [:]

    /// `computer` is the connection's `cacheScopeID`.
    init(host: any VoiceSettingsClient, computer: String, choices: OnDeviceVoiceChoices = .shared,
         engine: OnDeviceSpeechEngine = .shared, models: [OnDeviceVoiceModel] = OnDeviceVoiceModel.all) {
        self.host = host
        self.computer = computer
        self.choices = choices
        self.engine = engine
        self.models = models
    }

    func load(agentID: String) async throws -> VoiceSettingsConfiguration {
        merged(try await host.load(agentID: agentID), agentID: agentID)
    }

    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration {
        guard let hostRevision = hostRevisions[settings.expectedRevision] else { throw VoiceSettingsError.conflict }
        if let model = models.first(where: { $0.providerID == settings.providerID }) {
            let current = merged(try await host.load(agentID: agentID), agentID: agentID)
            guard current.revision == settings.expectedRevision else { throw VoiceSettingsError.conflict }
            let voice = settings.voiceID.isEmpty ? model.defaultVoice : settings.voiceID
            choices.set(.init(modelID: model.id, voice: voice), computer: computer, agentID: agentID)
            return merged(try await host.load(agentID: agentID), agentID: agentID)
        }
        let forwarded = VoiceSettingsUpdate(expectedRevision: hostRevision, providerID: settings.providerID,
                                            voiceID: settings.voiceID, apiKey: settings.apiKey,
                                            model: settings.model, serverURL: settings.serverURL)
        let saved = try await host.update(agentID: agentID, settings: forwarded)
        choices.set(nil, computer: computer, agentID: agentID)
        return merged(saved, agentID: agentID)
    }

    func playSample(agentID: String) async throws {
        guard let choice = choices.choice(computer: computer, agentID: agentID),
              let model = models.first(where: { $0.id == choice.modelID }) else {
            return try await host.playSample(agentID: agentID)
        }
        try await engine.speak(OnDeviceSpeechEngine.sampleText, model: model, voice: choice.voice, rate: 1,
                               use: .playback, owner: self)
    }

    /// The computer's providers after this device's, and this device's voice selected when the
    /// agent has one here.
    private func merged(_ base: VoiceSettingsConfiguration, agentID: String) -> VoiceSettingsConfiguration {
        let choice = choices.choice(computer: computer, agentID: agentID)
        let chosen = models.first { $0.id == choice?.modelID }
        let local = models.map { model in
            VoiceProviderConfiguration(
                id: model.providerID, title: model.title,
                voiceID: model == chosen ? choice?.voice ?? model.defaultVoice : model.defaultVoice,
                apiKeyConfigured: false, kind: .onThisDevice, hasVoice: true, needsAPIKey: false)
        }
        let revision = base.revision + "|" + (choice.map { "\($0.modelID)/\($0.voice)" } ?? "")
        hostRevisions[revision] = base.revision
        return VoiceSettingsConfiguration(revision: revision, providerID: chosen?.providerID ?? base.providerID,
                                          providers: local + base.providers)
    }
}
