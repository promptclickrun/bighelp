import Foundation

@MainActor
final class BighelpVoiceSettingsClient: VoiceSettingsClient {
    private let workspace: BighelpLinkWorkspaceClient
    private let isCurrent: @MainActor () -> Bool

    init(workspace: BighelpLinkWorkspaceClient, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.workspace = workspace
        self.isCurrent = isCurrent
    }

    func load(agentID: String) async throws -> VoiceSettingsConfiguration {
        try await perform(.voiceSettingsGet, agentID: agentID, payload: ["agentId": .string(agentID)])
    }

    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration {
        guard settings.transcription == nil else { throw VoiceSettingsError.unsupported }
        guard ["openai", "elevenlabs"].contains(settings.providerID),
              Self.validText(settings.voiceID, maximum: 160),
              Self.validText(settings.expectedRevision, maximum: 256) else { throw VoiceSettingsError.invalidResponse }
        var payload: [String: BighelpJSONValue] = [
            "agentId": .string(agentID), "expectedRevision": .string(settings.expectedRevision),
            "providerId": .string(settings.providerID), "voiceId": .string(settings.voiceID),
            "confirmed": .boolean(true),
        ]
        if let key = settings.apiKey {
            guard Self.validText(key, maximum: 4096) else { throw VoiceSettingsError.invalidResponse }
            payload["apiKey"] = .string(key)
        }
        return try await perform(.voiceSettingsSet, agentID: agentID, payload: payload)
    }

    private func perform(_ operation: BighelpLinkWorkspaceOperation, agentID: String,
                         payload: [String: BighelpJSONValue]) async throws -> VoiceSettingsConfiguration {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard Self.validText(agentID, maximum: 128) else { throw VoiceSettingsError.invalidResponse }
        do {
            let value = try await workspace.perform(operation, payload: payload)
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            return try Self.decode(value, agentID: agentID)
        } catch BighelpLinkLiveSocketError.hostUpdateRequired {
            throw VoiceSettingsError.unsupported
        } catch BighelpLinkWorkspaceClientError.remote(let status, _, _) where status == .conflict {
            throw VoiceSettingsError.conflict
        }
    }

    static func decode(_ value: [String: BighelpJSONValue], agentID: String) throws -> VoiceSettingsConfiguration {
        guard value["agentId"]?.string == agentID,
              let revision = value["revision"]?.string, validText(revision, maximum: 256),
              let selected = value["providerId"]?.string, validText(selected, maximum: 64),
              let rows = value["providers"]?.array, (2...16).contains(rows.count) else {
            throw VoiceSettingsError.invalidResponse
        }
        let providers = try rows.map { row -> VoiceProviderConfiguration in
            guard let fields = row.object,
                  let id = fields["providerId"]?.string, validText(id, maximum: 64),
                  let title = fields["title"]?.string, validText(title, maximum: 80),
                  let voice = fields["voiceId"]?.string, validText(voice, maximum: 256, allowEmpty: true),
                  let configured = fields["apiKeyConfigured"]?.boolean else {
                throw VoiceSettingsError.invalidResponse
            }
            return VoiceProviderConfiguration(id: id, title: title, voiceID: voice, apiKeyConfigured: configured)
        }
        let ids = Set(providers.map(\.id))
        guard ids.count == providers.count, ids.isSuperset(of: ["openai", "elevenlabs", selected]) else {
            throw VoiceSettingsError.invalidResponse
        }
        return VoiceSettingsConfiguration(revision: revision, providerID: selected, providers: providers)
    }

    private static func validText(_ value: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

#if DEBUG
@MainActor
final class VoiceSettingsPreviewClient: VoiceSettingsClient {
    private var saved: [String: VoiceSettingsConfiguration] = [:]

    private static let initial = VoiceSettingsConfiguration(
        revision: "fixture-1", providerID: "openai",
        providers: (VoiceProviderSpec.builtIn + [VoiceProviderSpec(id: "kokoro", title: "kokoro", kind: .custom)])
            .map { spec in
                VoiceProviderConfiguration(spec: spec, voiceID: spec.voiceField == nil ? "" : spec.defaultVoice,
                                           apiKeyConfigured: spec.id == "openai", model: spec.defaultModel,
                                           serverURL: "")
            },
        transcriptionProviderID: "",
        transcriptionProviders: VoiceTranscriptionProviderSpec.builtIn.map {
            VoiceTranscriptionProviderConfiguration(
                spec: $0,
                model: $0.defaultModel,
                apiKeyConfigured: $0.id == "elevenlabs"
            )
        })

    func load(agentID: String) async throws -> VoiceSettingsConfiguration {
        saved[agentID] ?? Self.initial
    }

    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration {
        let old = try await load(agentID: agentID)
        guard old.revision == settings.expectedRevision else { throw VoiceSettingsError.conflict }
        var transcriptionProviders = old.transcriptionProviders.map { provider in
            guard provider.id == settings.transcription?.providerID else { return provider }
            return VoiceTranscriptionProviderConfiguration(
                id: provider.id,
                title: provider.title,
                model: settings.transcription?.model ?? provider.model,
                apiKeyConfigured: provider.apiKeyConfigured || settings.transcription?.apiKey != nil,
                modelOptions: provider.modelOptions,
                needsAPIKey: provider.needsAPIKey,
                kind: provider.kind,
                hasModel: provider.hasModel
            )
        }
        if let selected = settings.transcription?.providerID,
           !transcriptionProviders.contains(where: { $0.id == selected }) {
            let spec = VoiceTranscriptionProviderSpec.builtIn(selected)
                ?? VoiceTranscriptionProviderSpec.custom(selected)
            transcriptionProviders.append(.init(
                spec: spec,
                model: settings.transcription?.model ?? spec.defaultModel,
                apiKeyConfigured: settings.transcription?.apiKey != nil
            ))
        }
        let updated = VoiceSettingsConfiguration(revision: UUID().uuidString, providerID: settings.providerID,
            providers: old.providers.map {
                guard $0.id == settings.providerID else { return $0 }
                var provider = VoiceProviderConfiguration(id: $0.id, title: $0.title,
                    voiceID: $0.hasVoice ? settings.voiceID : "",
                    apiKeyConfigured: $0.apiKeyConfigured || settings.apiKey != nil,
                    model: settings.model ?? $0.model, serverURL: settings.serverURL ?? $0.serverURL,
                    kind: $0.kind, hasVoice: $0.hasVoice, hasModel: $0.hasModel,
                    needsAPIKey: $0.needsAPIKey, supportsServerURL: $0.supportsServerURL)
                if provider.hasModel, provider.model.isEmpty,
                   let spec = VoiceProviderSpec.builtIn(provider.id) { provider.model = spec.defaultModel }
                return provider
            },
            transcriptionProviderID: settings.transcription?.providerID ?? old.transcriptionProviderID,
            transcriptionProviders: transcriptionProviders)
        saved[agentID] = updated
        return updated
    }

    func transcriptionCatalog(agentID: String) async throws -> VoiceTranscriptionHostCatalog {
        VoiceTranscriptionHostCatalog(
            providers: VoiceTranscriptionProviderSpec.builtIn.map {
                .init(id: $0.id, models: $0.models)
            } + [.init(id: "parakeet", models: [.init(id: "default", name: "Default")])]
        )
    }

    func playSample(agentID: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}
#endif
