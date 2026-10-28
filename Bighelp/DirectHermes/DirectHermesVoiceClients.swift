import CryptoKit
import Foundation

/// A single-use close prepared from the active Direct connection before its
/// owner is retired. It deliberately owns only the immutable authority needed
/// for the allocated voice call and uses a fresh ephemeral HTTP session for
/// this fixed native route.
@MainActor
final class DirectHermesVoiceCloseCleanup {
    private enum Credential {
        case bearer(String)
        case session(String)
    }

    private let endpoint: DirectHermesEndpoint
    private let credential: Credential
    private let requestGuard: DirectHermesNativeRequestGuard
    private let owner: WorkspaceOwner
    private let body: [String: BighelpJSONValue]
    private var consumed = false

    init?(
        endpoint: DirectHermesEndpoint,
        authentication: DirectHermesStoredAuthentication,
        owner: WorkspaceOwner,
        nativeContextETag: String,
        agentID: String,
        sessionID: String,
        voiceID: String
    ) {
        guard owner.authority.kind == .direct,
              Self.validIdentifier(agentID), Self.validIdentifier(sessionID), Self.validIdentifier(voiceID),
              let requestGuard = try? DirectHermesNativeRequestGuard(etag: nativeContextETag) else {
            return nil
        }
        switch authentication {
        case .bearer(let accessToken, _, _):
            guard (try? DirectHermesSecretValidation.validate(accessToken)) != nil else { return nil }
            credential = .bearer(accessToken)
        case .legacyLoopbackToken(let token), .dashboardSession(let token, _):
            guard (try? DirectHermesSecretValidation.validate(token)) != nil else { return nil }
            credential = .session(token)
        }
        self.endpoint = endpoint
        self.owner = owner
        self.requestGuard = requestGuard
        body = [
            "agentId": .string(agentID),
            "sessionId": .string(sessionID),
            "voiceId": .string(voiceID),
        ]
    }

    /// Best effort by design: the allocated call may already be closed. The
    /// handle cannot refresh, persist, or retarget credentials and can run once.
    func close() async {
        guard !consumed else { return }
        consumed = true
        let http = DirectHermesHTTP(endpoint: endpoint)
        defer { http.invalidate() }
        do {
            let response: DirectHermesHTTP.Response
            switch credential {
            case .bearer(let token):
                response = try await http.send(
                    route: "/api/plugins/loopdy/native/voice/close", method: "POST", body: body,
                    bearer: token, maximumResponseBytes: 16_384, nativeGuard: requestGuard
                )
            case .session(let token):
                response = try await http.send(
                    route: "/api/plugins/loopdy/native/voice/close", method: "POST", body: body,
                    legacyToken: token, maximumResponseBytes: 16_384, nativeGuard: requestGuard
                )
            }
            guard (200...299).contains(response.http.statusCode),
                  response.http.value(forHTTPHeaderField: "X-Loopdy-Request-ID") == requestGuard.requestIDHeader,
                  DirectHermesNativeRequestGuard.contextTag(response.http.value(forHTTPHeaderField: "ETag")) == requestGuard.etag else { return }
        } catch {
            // Retirement must not re-open or retarget an owner to report a
            // best-effort cleanup failure.
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Native voice settings and synthesis use the authenticated workspace
/// transport. The transport owns the Hermes route mapping; this layer only
/// validates the bounded voice models and the returned audio envelope.
@MainActor
final class DirectHermesVoiceSettingsClient: VoiceSettingsClient {
    static let sampleText = "Hi, this is how I'll sound when we talk."

    private let scope: DirectHermesCoreRequestScope
    private let workspace: any WorkspaceOperationPerforming
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private var sampleOutput: DirectHermesVoiceSpeechOutput?

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        scope = .init(workspace: workspace, owner: owner, currentOwner: currentOwner)
        self.workspace = workspace
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func load(agentID: String) async throws -> VoiceSettingsConfiguration {
        let profile = try Self.profile(agentID)
        let state = try await read(profile: profile)
        return state.configuration
    }

    func playSample(agentID: String) async throws {
        let profile = try Self.profile(agentID)
        sampleOutput?.stop()
        let output = DirectHermesVoiceSpeechOutput(workspace: workspace, owner: owner, profileID: profile,
                                                   playback: AVAudioPlayerVoicePlayback(use: .playback),
                                                   currentOwner: currentOwner)
        sampleOutput = output
        defer { if sampleOutput === output { sampleOutput = nil } }
        try await output.speak(Self.sampleText, rate: 1)
    }

    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration {
        let profile = try Self.profile(agentID)
        guard Self.validText(settings.providerID, maximum: 64),
              Self.validText(settings.voiceID, maximum: 160, allowEmpty: true),
              Self.validText(settings.expectedRevision, maximum: 256),
              Self.validText(settings.model ?? "", maximum: 160, allowEmpty: true),
              (settings.serverURL ?? "").isEmpty || VoiceSettingsStore.validServerURL(settings.serverURL ?? "") else {
            throw VoiceSettingsError.invalidResponse
        }
        if let key = settings.apiKey {
            guard Self.validText(key, maximum: 4_096) else {
                throw VoiceSettingsError.invalidResponse
            }
        }
        let current = try await read(profile: profile)
        guard current.configuration.revision == settings.expectedRevision else {
            throw VoiceSettingsError.conflict
        }
        guard let selected = current.configuration.providers.first(where: { $0.id == settings.providerID }),
              !selected.hasVoice || !settings.voiceID.isEmpty,
              settings.apiKey == nil || selected.needsAPIKey else {
            throw VoiceSettingsError.invalidResponse
        }
        let spec = VoiceProviderSpec.builtIn(settings.providerID)
        let voiceChanged = selected.takesVoice && selected.voiceID != settings.voiceID
        if current.configuration.providerID == settings.providerID, !voiceChanged, settings.apiKey == nil,
           settings.model == nil, settings.serverURL == nil {
            return current.configuration
        }

        if let key = settings.apiKey, let keyName = spec?.keyNames.first {
            let result = try await perform(.keysSet, profile: profile, payload: [
                "profile": .string(profile), "key": .string(keyName), "value": .string(key)
            ])
            guard result["ok"]?.boolean == true else { throw VoiceSettingsError.invalidResponse }
        }

        // Hermes deep-merges this over the agent's config, so only the fields
        // named here change.
        var tts: [String: BighelpJSONValue] = ["provider": .string(settings.providerID)]
        var section: [String: BighelpJSONValue] = [:]
        if selected.takesVoice {
            switch selected.voiceLocation {
            case .section:
                if let field = spec?.voiceField { section[field] = .string(settings.voiceID) }
            case .plugin:
                // Hermes hands a plugin only the top-level voice, and the plugin
                // falls back to its own section, so both stay in step.
                tts["voice"] = .string(settings.voiceID)
                section["voice"] = .string(settings.voiceID)
            case .commandProvider:
                // The command's {voice} comes from its own provider entry; empty is the command's own.
                tts["providers"] = .object([settings.providerID: .object(["voice": .string(settings.voiceID)])])
            }
        }
        if let model = settings.model, let spec, let field = spec.modelField {
            // A merge can't delete a key, so clearing the model restores the default.
            let value = model.isEmpty ? spec.defaultModel : model
            if !value.isEmpty { section[field] = .string(value) }
        }
        if let serverURL = settings.serverURL, spec?.supportsServerURL == true {
            // An empty base_url makes Hermes use the provider's own server.
            section["base_url"] = .string(serverURL)
        }
        // Clearing an inline key is the canonical writer's required step
        // before saving VOICE_TOOLS_OPENAI_KEY, otherwise config precedence
        // can continue to select the stale value.
        if settings.providerID == "openai", settings.apiKey != nil { section["api_key"] = .string("") }
        if !section.isEmpty { tts[settings.providerID] = .object(section) }
        let result = try await perform(.workspaceConfigSet, profile: profile, payload: [
            "profile": .string(profile), "config": .object(["tts": .object(tts)])
        ])
        guard result["ok"]?.boolean == true else { throw VoiceSettingsError.invalidResponse }

        let verified = try await read(profile: profile)
        guard verified.configuration.providerID == settings.providerID,
              let saved = verified.configuration.providers.first(where: { $0.id == settings.providerID }),
              !saved.takesVoice || saved.voiceID == settings.voiceID,
              settings.apiKey == nil || saved.apiKeyConfigured,
              settings.serverURL == nil || saved.serverURL == settings.serverURL else {
            throw VoiceSettingsError.invalidResponse
        }
        return verified.configuration
    }

    private func perform(
        _ operation: WorkspaceOperation,
        profile: String,
        payload: [String: BighelpJSONValue]
    ) async throws -> [String: BighelpJSONValue] {
        do {
            try scope.require(.voiceOutput, profile: profile)
            return try await scope.perform(operation, payload)
        } catch let error as WorkspaceClientError {
            switch error {
            case .conflict:
                throw VoiceSettingsError.conflict
            case .unavailable(.unsupportedOperation), .unavailable(.pluginRequired),
                 .unavailable(.unsupportedHost), .unavailable(.hostRestartRequired):
                throw VoiceSettingsError.unsupported
            default:
                throw error
            }
        }
    }

    private struct ReadState {
        let configuration: VoiceSettingsConfiguration
    }

    private func read(profile: String) async throws -> ReadState {
        let config = try await perform(.workspaceConfigGet, profile: profile, payload: [
            "profile": .string(profile)
        ])
        let keys = try await perform(.keysList, profile: profile, payload: [
            "profile": .string(profile)
        ])
        return ReadState(configuration: try Self.configuration(
            config: config, keys: keys, agentID: profile
        ))
    }

    private static func profile(_ value: String) throws -> String {
        guard validText(value, maximum: 128) else { throw VoiceSettingsError.invalidResponse }
        do {
            return try DirectHermesCoreRequestScope.profile(value)
        } catch {
            throw VoiceSettingsError.invalidResponse
        }
    }

    private static func configuration(
        config: [String: BighelpJSONValue],
        keys: [String: BighelpJSONValue],
        agentID: String
    ) throws -> VoiceSettingsConfiguration {
        let tts = config["tts"]?.object ?? [:]
        let selected = normalizedProvider(tts["provider"]?.string)
        let providers = try providerSpecs(selected: selected, tts: tts).map { spec in
            let section = tts[spec.id]?.object ?? [:]
            let voiceID: String
            switch spec.voiceLocation {
            case .section:
                voiceID = try field(spec.voiceField, in: section, fallback: spec.defaultVoice)
            case .plugin:
                let own = try field(spec.voiceField, in: section, fallback: spec.defaultVoice)
                let topLevel = spec.id == selected ? try field("voice", in: tts, fallback: "") : ""
                voiceID = topLevel.isEmpty ? own : topLevel
            case .commandProvider:
                let entry = tts["providers"]?.object?[spec.id]?.object ?? [:]
                voiceID = try field("voice", in: entry, fallback: "")
            }
            return VoiceProviderConfiguration(
                spec: spec,
                voiceID: voiceID,
                apiKeyConfigured: keyConfigured(spec, section: section, keys: keys),
                model: try field(spec.modelField, in: section, fallback: spec.defaultModel),
                serverURL: spec.supportsServerURL ? try field("base_url", in: section, fallback: "") : ""
            )
        }
        let revisionInput: [String: BighelpJSONValue] = [
            "agentId": .string(agentID),
            "providerId": .string(selected),
            "providers": .array(providers.map { provider in
                .object([
                    "providerId": .string(provider.id),
                    "voiceId": .string(provider.voiceID),
                    "model": .string(provider.model),
                    "serverUrl": .string(provider.serverURL),
                    "apiKeyConfigured": .boolean(provider.apiKeyConfigured),
                ])
            }),
        ]
        let bytes = try JSONEncoder.sorted.encode(BighelpJSONValue.object(revisionInput))
        let revision = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return VoiceSettingsConfiguration(revision: revision, providerID: selected, providers: providers)
    }

    /// The selected provider first when the app doesn't know it (a speech plugin
    /// such as Phonon), then every built-in provider, then the host's own
    /// command providers.
    private static func providerSpecs(selected: String, tts: [String: BighelpJSONValue]) -> [VoiceProviderSpec] {
        var result = VoiceProviderSpec.builtIn
        let custom = (tts["providers"]?.object ?? [:])
            .filter { name, value in
                guard validName(name), VoiceProviderSpec.builtIn(name) == nil,
                      let command = value.object?["command"]?.string else { return false }
                return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .keys.sorted()
            .map { VoiceProviderSpec.commandProvider($0) }
        result += custom
        if !result.contains(where: { $0.id == selected }) {
            // Hermes picks `nous` itself, so only a named plugin gets a voice field.
            let spec = selected == "nous" || !validName(selected) ? VoiceProviderSpec.unknown(selected) : .plugin(selected)
            result.insert(spec, at: 0)
        }
        return result
    }

    private static func validName(_ value: String) -> Bool {
        validText(value, maximum: 64) && value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }
    }

    private static func normalizedProvider(_ value: String?) -> String {
        guard let value, validName(value) else { return "edge" }
        return value.lowercased()
    }

    private static func field(_ name: String?, in section: [String: BighelpJSONValue], fallback: String) throws -> String {
        guard let name else { return "" }
        let value = section[name]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result = value.isEmpty ? fallback : value
        guard validText(result, maximum: 512, allowEmpty: true) else { throw VoiceSettingsError.invalidResponse }
        return result
    }

    private static func keyConfigured(
        _ spec: VoiceProviderSpec,
        section: [String: BighelpJSONValue],
        keys: [String: BighelpJSONValue]
    ) -> Bool {
        if spec.id == "openai", let inline = section["api_key"]?.string,
           !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return spec.keyNames.contains { keys[$0]?.object?["is_set"]?.boolean == true }
    }

    private static func validText(_ value: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// The voices a provider lists on the computer, for Voice settings' pickers: the agent's own
/// ElevenLabs voices (Hermes' `/api/audio/elevenlabs/voices`, as its desktop app reads them) and a
/// speech plugin's, such as Phonon (the bighelp plugin's `voice-catalog`).
@MainActor
final class DirectHermesVoiceOptionsClient: VoiceOptionsClient {
    /// The plugin's bounds (`native-voice-catalog-v1`): at most 500 voices and 50 models, each name at
    /// most 160 bytes.
    nonisolated static let maximumVoices = 500
    nonisolated static let maximumModels = 50

    private let scope: DirectHermesCoreRequestScope
    private let elevenLabsVoices: (@MainActor (String) async throws -> DirectHermesVoiceCatalog)?

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
         elevenLabsVoices: (@MainActor (String) async throws -> DirectHermesVoiceCatalog)? = nil) {
        scope = .init(workspace: workspace, owner: owner, currentOwner: currentOwner)
        self.elevenLabsVoices = elevenLabsVoices
    }

    /// The lists of the computer `connections` uses now; nil while none is connected.
    static func connected(_ connections: WorkspaceConnectionStore?) -> DirectHermesVoiceOptionsClient? {
        guard let connections, let owner = connections.owner, owner.authority.kind == .direct,
              let workspace = connections.workspace else { return nil }
        let current: @MainActor () -> WorkspaceOwner? = { [weak connections] in connections?.owner }
        return DirectHermesVoiceOptionsClient(workspace: workspace, owner: owner, currentOwner: current,
            elevenLabsVoices: { [weak connections] profile in
                guard let http = connections?.hosts.selectedWorkspace?.nativeClient else {
                    throw WorkspaceClientError.ownerChanged
                }
                return try await DirectHermesVoiceConfigurationClient(http: http, owner: owner, currentOwner: current)
                    .listElevenLabsVoices(profileID: profile)
            })
    }

    func catalog(agentID: String, provider: VoiceProviderConfiguration) async throws -> VoiceHostCatalog {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        if provider.id == "elevenlabs" { return try await elevenLabs(profile: profile) }
        guard provider.voiceLocation == .plugin else { return VoiceHostCatalog(voices: []) }
        let value: [String: BighelpJSONValue]
        do {
            value = try await scope.perform(.voiceCatalog, [
                "profile": .string(profile), "provider": .string(provider.id),
            ])
        } catch let error as WorkspaceClientError {
            switch error {
            case .unavailable(.unsupportedOperation), .unavailable(.pluginRequired):
                // A plugin from before `voice-catalog`, or none at all.
                throw VoiceOptionsError.needsPluginUpdate
            default:
                throw error
            }
        }
        return try Self.pluginCatalog(value, provider: provider.id)
    }

    private func elevenLabs(profile: String) async throws -> VoiceHostCatalog {
        guard let elevenLabsVoices else {
            throw VoiceOptionsError.unavailable(String(localized: "Connect to your computer to see your ElevenLabs voices."))
        }
        let catalog = try await elevenLabsVoices(profile)
        guard catalog.isAvailable else {
            throw VoiceOptionsError.unavailable(catalog.unavailableReason == "unauthorized"
                ? String(localized: "ElevenLabs didn't accept the saved API key. Check it, then try again.")
                : String(localized: "Save an ElevenLabs API key to choose from your own voices."))
        }
        // Your own voices (cloned, designed) before ElevenLabs' ready-made ones.
        let readyMade = String(localized: "Ready-made"), yours = String(localized: "Your voices")
        let voices = catalog.voices.map { voice in
            VoiceOption(id: voice.id, name: voice.name.isEmpty ? voice.id : voice.name,
                        group: Self.category(of: voice) == "premade" ? readyMade : yours)
        }
        return VoiceHostCatalog(voices: voices.filter { $0.group == yours } + voices.filter { $0.group == readyMade })
    }

    /// Hermes labels each voice "Name (category)".
    private static func category(of voice: DirectHermesVoiceDescriptor) -> String {
        guard voice.label.hasSuffix(")"), let open = voice.label.lastIndex(of: "(") else { return "" }
        return String(voice.label[voice.label.index(after: open)..<voice.label.index(before: voice.label.endIndex)])
            .lowercased()
    }

    /// The plugin's answer. Rows it can't read are skipped, not the whole list; an answer for another
    /// provider is refused.
    nonisolated static func pluginCatalog(_ value: [String: BighelpJSONValue], provider: String) throws -> VoiceHostCatalog {
        guard value["ok"]?.boolean == true else { throw WorkspaceClientError.invalidResponse }
        if let named = value["provider"]?.string, named != provider { throw WorkspaceClientError.invalidResponse }
        let defaultVoice = value["defaultVoice"]?.string.flatMap { validName($0) ? $0 : nil }
        return VoiceHostCatalog(voices: options(value["voices"], limit: maximumVoices, withLanguage: true),
                                models: options(value["models"], limit: maximumModels, withLanguage: false),
                                defaultVoice: defaultVoice)
    }

    private nonisolated static func options(_ value: BighelpJSONValue?, limit: Int,
                                            withLanguage: Bool) -> [VoiceOption] {
        var seen = Set<String>()
        return (value?.array ?? []).prefix(limit).compactMap { row -> VoiceOption? in
            guard let object = row.object, let id = object["id"]?.string, validName(id),
                  seen.insert(id).inserted else { return nil }
            let name = object["name"]?.string.flatMap { validName($0) ? $0 : nil } ?? id
            let language = withLanguage ? object["language"]?.string.flatMap { validName($0) ? $0 : nil } : nil
            return VoiceOption(id: id, name: name,
                               group: language.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 })
        }
    }

    private nonisolated static func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 160
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum DirectHermesVoiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidAudioResponse
    /// Hermes installed what the voice needs but runs without it until it restarts.
    case hostRestartRequired
    /// Hermes couldn't install what the voice needs. `extra` is its `hermes pm` add-on, when known.
    case voicePackageMissing(extra: String?)

    var errorDescription: String? {
        switch self {
        case .invalidAudioResponse: "Hermes sent audio this device can't play."
        case .hostRestartRequired: "This voice is installed on your computer now. Restart Hermes there to use it."
        case .voicePackageMissing(let extra):
            extra.map { "Hermes couldn't install this voice on your computer. Run hermes pm install --extra \($0) there, then restart Hermes." }
                ?? "Hermes couldn't install this voice on your computer."
        }
    }
}

@MainActor
final class DirectHermesVoiceSpeechOutput: VoiceSpeechOutput {
    private let scope: DirectHermesCoreRequestScope
    private let profileID: String
    private let playback: any VoiceAudioPlayback
    private var generation: UInt64 = 0
    private var warmUp: WarmUp?

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        profileID: String,
        playback: any VoiceAudioPlayback = AVAudioPlayerVoicePlayback(),
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        scope = .init(workspace: workspace, owner: owner, currentOwner: currentOwner)
        self.profileID = profileID
        self.playback = playback
    }

    func speak(_ text: String, rate: Float) async throws {
        try await speak(text, rate: rate) { _ in }
    }

    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        // Hermes' public /api/audio/speak contract accepts text only; speed is
        // part of the host's resolved TTS configuration.
        _ = rate
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        generation &+= 1
        let ownedGeneration = generation
        playback.stop()
        let audio = try await synthesize(text)
        guard generation == ownedGeneration else { throw CancellationError() }
        try await playback.play(audio.data, mimeType: audio.mimeType, onPlayback: onPlayback)
    }

    /// This profile's voice for `text`, without playing it, so a caller can
    /// make the next piece while another plays (team calls).
    func synthesize(_ text: String) async throws -> TeamCallAudio {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw VoiceSessionError.emptyResponse }
        let profile = try DirectHermesCoreRequestScope.profile(profileID)
        try scope.require(.voiceOutput, profile: profile)
        let warmUp = try await warm(profile)
        let value: [String: BighelpJSONValue]
        do {
            value = try await scope.perform(.voiceSpeak, [
                "profile": .string(profile),
                "text": .string(String(normalized.prefix(20_000))),
            ])
        } catch let error as WorkspaceClientError where error != .ownerChanged {
            throw warmUp.failure ?? error
        }
        try Task.checkCancellation()
        let audio = try Self.audio(value)
        return TeamCallAudio(data: audio.data, mimeType: audio.mimeType)
    }

    func stop() {
        generation &+= 1
        playback.stop()
    }

    /// What Hermes said when it warmed this voice.
    private struct WarmUp {
        /// Why speaking may fail: the voice's package is missing, or needs a restart.
        let failure: DirectHermesVoiceError?
    }

    /// Hermes installs a cloud voice's package (ElevenLabs, Edge, Mistral) the
    /// first time it's used. Warming it first, as Hermes desktop does when voice
    /// turns on, gives that install three minutes instead of speech's 20 seconds,
    /// and says why when Hermes can't install it or must restart to load it (speech
    /// only says "not installed"). Once per output, released right away: a local
    /// voice stays loaded for Hermes' keep-warm time. An older Hermes just speaks.
    private func warm(_ profile: String) async throws -> WarmUp {
        if let warmUp { return warmUp }
        let lease = "bighelp:voice:\(UUID().uuidString.lowercased())"
        let receipt: [String: BighelpJSONValue]
        do {
            receipt = try await scope.perform(.voiceWarm, [
                "profile": .string(profile), "lease": .string(lease), "active": .boolean(true),
            ])
        } catch WorkspaceClientError.ownerChanged {
            throw WorkspaceClientError.ownerChanged
        } catch {
            receipt = [:]
        }
        _ = try? await scope.perform(.voiceWarm, [
            "profile": .string(profile), "lease": .string(lease), "active": .boolean(false),
        ])
        let result = WarmUp(failure: Self.warmUpFailure(receipt))
        warmUp = result
        return result
    }

    private static func warmUpFailure(_ receipt: [String: BighelpJSONValue]) -> DirectHermesVoiceError? {
        guard receipt["action"]?.string == "error" else { return nil }
        let reason = String(receipt["error"]?.string?.prefix(2_048) ?? "")
        if reason.localizedCaseInsensitiveContains("restart Hermes") { return .hostRestartRequired }
        // Hermes' add-on for each voice whose package installs on first use.
        let extras = ["elevenlabs": "tts-premium", "edge": "edge-tts", "mistral": "mistral"]
        return .voicePackageMissing(extra: receipt["provider"]?.string.flatMap { extras[$0] })
    }

    private static func audio(_ value: [String: BighelpJSONValue]) throws -> (data: Data, mimeType: String) {
        guard value["ok"]?.boolean == true,
              let dataURL = value["data_url"]?.string,
              let comma = dataURL.firstIndex(of: ",") else {
            throw DirectHermesVoiceError.invalidAudioResponse
        }
        let metadata = String(dataURL[..<comma])
        let payload = String(dataURL[dataURL.index(after: comma)...])
        guard metadata.hasPrefix("data:"), metadata.contains(";base64") else {
            throw DirectHermesVoiceError.invalidAudioResponse
        }
        let rawMIME = String(metadata.dropFirst(5).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        let mimeType = rawMIME.lowercased()
        guard validMIME(mimeType),
              value["mime_type"]?.string?.lowercased() == mimeType,
              payload.utf8.count <= ((BighelpLinkVoiceAudioChunk.maximumAudioBytes + 2) / 3) * 4 + 4,
              let data = Data(base64Encoded: payload),
              !data.isEmpty,
              data.count <= BighelpLinkVoiceAudioChunk.maximumAudioBytes else {
            throw DirectHermesVoiceError.invalidAudioResponse
        }
        return (data, mimeType)
    }

    private static func validMIME(_ value: String) -> Bool {
        guard value.utf8.count <= 128,
              value.hasPrefix("audio/"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        return String(value.dropFirst(6)).unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".+-".contains(Character($0)))
        }
    }
}

@MainActor
final class DirectHermesVoiceSessionClient: VoiceSessionClient {
    private let conversation: DirectHermesConversationClient
    private let output: any VoiceSpeechOutput
    private let speechRate: () -> Float
    private let transcriber: (@MainActor (Data) async throws -> String)?

    init(
        conversation: DirectHermesConversationClient,
        output: any VoiceSpeechOutput,
        speechRate: @escaping () -> Float,
        transcriber: (@MainActor (Data) async throws -> String)? = nil
    ) {
        self.conversation = conversation
        self.output = output
        self.speechRate = speechRate
        self.transcriber = transcriber
    }

    func transcribe(_ audio: Data) async throws -> String {
        guard let transcriber else { throw VoiceSessionError.unsupported }
        return try await transcriber(audio)
    }

    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        guard conversationID == conversation.conversationID else {
            throw WorkspaceClientError.ownerChanged
        }
        let response = try await conversation.sendForVoice(message: transcript)
        guard let item = response.items.last(where: { item in
            guard item.role == .assistant, case .message(let text) = item.content else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), case .message(let text) = item.content else {
            throw VoiceSessionError.emptyResponse
        }
        onDraft(text)
        return VoiceAgentReply(speaker: item.sender.snapshot.name, text: text, timelineItems: response.items)
    }

    func steer(_ transcript: String, conversationID: String) async throws {
        _ = try await conversation.sendMidSession(
            message: transcript,
            attachments: [],
            conversationID: conversationID,
            behavior: .steer,
            onDraft: { _ in }
        )
    }

    func speak(_ text: String) async throws {
        try await output.speak(text, rate: speechRate())
    }

    func speak(
        _ text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        try await output.speak(text, rate: speechRate(), onPlayback: onPlayback)
    }

    func stopSpeaking() {
        output.stop()
    }

    func endSession(conversationID: String) async throws {
        output.stop()
    }
}
