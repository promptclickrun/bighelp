import Foundation
import Testing
@testable import Bighelp

@MainActor
struct VoiceSettingsStoreTests {
    @Test func loadsCurrentHostConfigurationWithoutReadingBackTheSecret() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        #expect(store.providerID == "openai")
        #expect(store.voiceID == "alloy")
        #expect(store.configuration?.providers.first?.apiKeyConfigured == true)
        #expect(store.apiKey.isEmpty)
        #expect(!store.canSave)
    }

    @Test func savesProviderVoiceAndReplacementKeyOnlyAfterHostConfirmation() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.selectProvider("elevenlabs")
        store.voiceID = "fixture-voice-id"
        store.apiKey = "fixture-provider-key"
        #expect(store.canSave)
        await store.save()
        #expect(client.updates == [VoiceSettingsUpdate(expectedRevision: "revision-1",
            providerID: "elevenlabs", voiceID: "fixture-voice-id", apiKey: "fixture-provider-key")])
        #expect(store.configuration?.revision == "revision-2")
        #expect(store.providerID == "elevenlabs")
        #expect(store.apiKey.isEmpty)
        #expect(store.confirmation == "Voice settings saved.")
        #expect(!store.canSave)
    }

    @Test func unchangedSettingsAndSameProviderDoNotWriteOrConfirm() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.selectProvider("openai")
        await store.save()
        #expect(client.updates.isEmpty)
        #expect(store.confirmation == nil)
    }

    @Test func switchingProvidersClearsTheOtherProvidersUnsentKey() async {
        let store = VoiceSettingsStore(agentID: "finance", client: VoiceSettingsProbe())
        await store.load()
        store.apiKey = "unsent-openai-key"
        store.selectProvider("elevenlabs")
        #expect(store.apiKey.isEmpty)
        #expect(store.voiceID == "")
    }

    @Test func failedSaveKeepsEditsAndDoesNotClaimSuccess() async {
        let client = VoiceSettingsProbe()
        client.saveError = VoiceSettingsError.conflict
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.voiceID = "nova"
        await store.save()
        #expect(store.configuration?.revision == "revision-1")
        #expect(store.voiceID == "nova")
        #expect(store.confirmation == nil)
        #expect(store.errorMessage != nil)
    }
    @Test func lateLoadAndSaveCannotPublishAfterHostOwnershipChanges() async {
        let client = VoiceSettingsProbe()
        client.configuration = Self.configuration(
            providerID: "openai",
            transcriptionProviderID: "",
            elevenLabsKeyConfigured: false
        )
        client.holdLoad = true
        let owner = VoiceSettingsOwner()
        let store = VoiceSettingsStore(agentID: "finance", client: client, isCurrent: { owner.current })
        let loading = Task { await store.load() }
        while client.pendingLoad == nil { await Task.yield() }
        owner.current = false
        client.pendingLoad?.resume(returning: client.configuration)
        await loading.value
        #expect(store.configuration == nil)
        #expect(store.errorMessage == nil)

        owner.current = true
        client.holdLoad = false
        await store.load()
        store.selectTranscriptionProvider("elevenlabs")
        store.transcriptionAPIKey = "fixture-switch-key"
        store.chooseTranscriptionModel("scribe_v1")
        client.holdSave = true
        let saving = Task { await store.save() }
        while client.pendingSave == nil { await Task.yield() }
        owner.current = false
        store.invalidate()
        client.pendingSave?.resume()
        await saving.value
        #expect(store.configuration == nil)
        #expect(store.confirmation == nil)
        #expect(store.apiKey.isEmpty)
        #expect(store.transcriptionAPIKey.isEmpty)
        #expect(store.transcriptionProviderID.isEmpty)
    }

    @Test func doubleSaveIsIgnoredAndLateSuccessPreservesNewerEdits() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.voiceID = "nova"
        client.holdSave = true
        let saving = Task { await store.save() }
        while client.pendingSave == nil { await Task.yield() }
        await store.save()
        store.voiceID = "coral"
        client.pendingSave?.resume()
        await saving.value
        #expect(client.updates.count == 1)
        #expect(store.configuration?.providers.first?.voiceID == "nova")
        #expect(store.voiceID == "coral")
        #expect(store.confirmation == nil)
        #expect(store.canSave)
    }

    @Test func clearingASecretForBackgroundPrivacyDoesNotLoseSaveConfirmation() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.apiKey = "fixture-replacement-key"
        client.holdSave = true
        let saving = Task { await store.save() }
        while client.pendingSave == nil { await Task.yield() }
        store.clearAPIKey()
        #expect(store.apiKey.isEmpty)
        client.pendingSave?.resume()
        await saving.value
        #expect(store.confirmation == "Voice settings saved.")
        #expect(!store.canSave)
    }

    @Test func changingOnlyVoiceDoesNotTransmitAKeyReplacement() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.voiceID = "nova"
        await store.save()
        #expect(client.updates.first?.apiKey == nil)
        #expect(store.selectedProvider?.apiKeyConfigured == true)
    }

    @Test func scribeNeedsTheSharedKeyAndSavesOnlyAnExplicitlyPickedModel() async {
        let client = VoiceSettingsProbe()
        client.configuration = Self.configuration(
            providerID: "openai",
            transcriptionProviderID: "",
            elevenLabsKeyConfigured: false
        )
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()

        #expect(store.transcriptionProviderID.isEmpty)
        store.selectTranscriptionProvider("elevenlabs")
        #expect(!store.canSave, "Scribe cannot be saved until its shared key exists")
        store.transcriptionAPIKey = "fixture-elevenlabs-key"
        #expect(store.canSave)
        await store.save()

        #expect(client.updates.last == VoiceSettingsUpdate(
            expectedRevision: "revision-1",
            providerID: "openai",
            voiceID: "alloy",
            apiKey: nil,
            transcription: .init(
                providerID: "elevenlabs",
                apiKey: "fixture-elevenlabs-key",
                model: nil
            )
        ))
        #expect(store.transcriptionProviderID == "elevenlabs")
        #expect(store.transcriptionModel == "scribe_v2")
        #expect(store.transcriptionAPIKey.isEmpty)
        #expect(store.configuration?.providerID == "openai", "The STT save must not change TTS")

        store.chooseTranscriptionModel("scribe_v1")
        await store.save()
        #expect(client.updates.last?.transcription == .init(
            providerID: "elevenlabs",
            apiKey: nil,
            model: "scribe_v1"
        ))
    }

    @Test func anExistingMissingSTTKeyDoesNotBlockATalkingVoiceEdit() async {
        let client = VoiceSettingsProbe()
        client.configuration = Self.configuration(
            providerID: "openai",
            transcriptionProviderID: "elevenlabs",
            elevenLabsKeyConfigured: false
        )
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()

        store.voiceID = "nova"
        #expect(store.canSave)
        await store.save()

        #expect(client.updates.last?.transcription == nil)
        #expect(client.updates.last?.voiceID == "nova")
    }

    @Test func transcriptionDraftsDoNotLeakAcrossBots() async {
        let client = VoiceSettingsProbe()
        client.configurations["finance"] = Self.configuration(
            providerID: "openai",
            transcriptionProviderID: "elevenlabs",
            elevenLabsKeyConfigured: true
        )
        client.configurations["travel"] = Self.configuration(
            providerID: "openai",
            transcriptionProviderID: "local",
            elevenLabsKeyConfigured: false
        )

        let finance = VoiceSettingsStore(agentID: "finance", client: client)
        await finance.load()
        finance.transcriptionAPIKey = "finance-only-replacement"
        finance.chooseTranscriptionModel("scribe_v1")

        let travel = VoiceSettingsStore(agentID: "travel", client: client)
        await travel.load()

        #expect(travel.transcriptionProviderID == "local")
        #expect(travel.transcriptionAPIKey.isEmpty)
        #expect(travel.transcriptionModel != finance.transcriptionModel)
        #expect(finance.transcriptionModel == "scribe_v1")
    }

    private static func configuration(
        providerID: String,
        transcriptionProviderID: String,
        elevenLabsKeyConfigured: Bool
    ) -> VoiceSettingsConfiguration {
        VoiceSettingsConfiguration(
            revision: "revision-1",
            providerID: providerID,
            providers: [
                .init(id: "openai", title: "OpenAI", voiceID: "alloy", apiKeyConfigured: true),
                .init(id: "elevenlabs", title: "ElevenLabs", voiceID: "", apiKeyConfigured: elevenLabsKeyConfigured),
            ],
            transcriptionProviderID: transcriptionProviderID,
            transcriptionProviders: [
                .init(id: "", title: "Automatic", model: "", apiKeyConfigured: false,
                      modelOptions: [], needsAPIKey: false),
                .init(id: "local", title: "On your computer", model: "base", apiKeyConfigured: false,
                      modelOptions: [.init(id: "base", name: "Base")], needsAPIKey: false),
                .init(id: "elevenlabs", title: "ElevenLabs Scribe",
                      model: "scribe_v2", apiKeyConfigured: elevenLabsKeyConfigured,
                      modelOptions: [
                          .init(id: "scribe_v2", name: "Scribe v2"),
                          .init(id: "scribe_v1", name: "Scribe v1"),
                      ],
                      needsAPIKey: true),
            ]
        )
    }

    @Test func localProviderSavesWithoutAKeyAndSamplesOnlySavedSettings() async {
        let client = VoiceSettingsProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "openai", providers: [
            .init(id: "openai", title: "OpenAI", voiceID: "alloy", apiKeyConfigured: true),
            .init(spec: VoiceProviderSpec.builtIn("piper")!, voiceID: "en_US-lessac-medium",
                  apiKeyConfigured: false, model: "", serverURL: ""),
        ])
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        #expect(store.canPlaySample)
        store.selectProvider("piper")
        #expect(store.voiceID == "en_US-lessac-medium")
        #expect(store.canSave)
        #expect(!store.canPlaySample)
        await store.save()
        #expect(client.updates.last == VoiceSettingsUpdate(expectedRevision: "revision-1",
            providerID: "piper", voiceID: "en_US-lessac-medium", apiKey: nil))
        #expect(store.confirmation == "Voice settings saved.")
        #expect(store.canPlaySample)
        await store.playSample()
        #expect(client.samples == 1)
        #expect(store.sampleError == nil)
    }

    @Test func failedSampleOnALocalProviderPointsAtTheSetupCommand() async {
        let client = VoiceSettingsProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "piper", providers: [
            .init(spec: VoiceProviderSpec.builtIn("piper")!, voiceID: "en_US-lessac-medium",
                  apiKeyConfigured: false, model: "", serverURL: ""),
        ])
        client.sampleError = WorkspaceClientError.rejected(code: nil)
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        await store.playSample()
        #expect(store.sampleError?.contains("hermes setup tts") == true)
    }

    @Test func aSampleHermesMustRestartForSaysSo() async {
        let client = VoiceSettingsProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "elevenlabs", providers: [
            .init(spec: VoiceProviderSpec.builtIn("elevenlabs")!, voiceID: "voice-1",
                  apiKeyConfigured: true, model: "", serverURL: ""),
        ])
        client.sampleError = DirectHermesVoiceError.hostRestartRequired
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        await store.playSample()
        #expect(store.sampleError?.contains("Restart Hermes") == true)
        #expect(store.sampleError?.contains("API key") == false)
    }

    @Test func serverAddressMustBeAWebAddress() async {
        let client = VoiceSettingsProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "openai", providers: [
            .init(spec: VoiceProviderSpec.builtIn("openai")!, voiceID: "alloy", apiKeyConfigured: true,
                  model: "gpt-4o-mini-tts", serverURL: ""),
        ])
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.serverURL = "not a server"
        #expect(!store.canSave)
        store.serverURL = "http://10.0.0.5:8880/v1"
        #expect(store.canSave)
        await store.save()
        #expect(client.updates.last?.serverURL == "http://10.0.0.5:8880/v1")
        #expect(client.updates.last?.model == nil)
    }

    @Test func aCustomCommandProviderSavesWithoutAVoice() async {
        let client = VoiceSettingsProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "openai", providers: [
            .init(id: "openai", title: "OpenAI", voiceID: "alloy", apiKeyConfigured: true),
            .init(spec: .commandProvider("kokoro"), voiceID: "", apiKeyConfigured: false, model: "", serverURL: ""),
        ])
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.selectProvider("kokoro")
        #expect(store.voiceID.isEmpty)
        #expect(store.canSave, "An empty voice runs the command's own")
        await store.save()
        #expect(client.updates.last == VoiceSettingsUpdate(expectedRevision: "revision-1",
            providerID: "kokoro", voiceID: "", apiKey: nil))
        #expect(store.confirmation == "Voice settings saved.")

        store.chooseVoice("af_bella")
        #expect(store.canSave)
        #expect(store.voiceChoices?.allowsOther == true)
    }

    @Test func pickedVoicesAndModelsAreWhatSaveSends() async {
        let client = VoiceSettingsProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "openai", providers: [
            .init(spec: VoiceProviderSpec.builtIn("openai")!, voiceID: "ballad", apiKeyConfigured: true,
                  model: "gpt-4o-mini-tts", serverURL: ""),
        ])
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        #expect(store.voiceName == "Ballad")
        #expect(store.modelName == "GPT-4o mini TTS")

        store.chooseModel("tts-1")
        #expect(store.voiceID == "alloy", "tts-1 has no Ballad, so the voice goes back to the default")
        #expect(store.voiceChoices?.options.contains { $0.id == "ballad" } == false)
        store.chooseVoice("coral")
        await store.save()
        #expect(client.updates.last == VoiceSettingsUpdate(expectedRevision: "revision-1",
            providerID: "openai", voiceID: "coral", apiKey: nil, model: "tts-1"))
    }

    @Test func aPluginsVoicesComeFromTheComputerOnce() async {
        let client = VoiceSettingsProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "phonon", providers: [
            .init(spec: .plugin("phonon"), voiceID: "Ava", apiKeyConfigured: false, model: "", serverURL: ""),
        ])
        let options = VoiceOptionsProbe()
        options.answer = VoiceHostCatalog(voices: [.init(id: "Ava", name: "Ava Warm"), .init(id: "Kai", name: "Kai")])
        let store = VoiceSettingsStore(agentID: "finance", client: client, options: options)
        await store.load()
        #expect(store.voiceChoices?.options.map(\.id) == ["Ava"], "Before the list, only the voice in use")

        await store.loadHostCatalog()
        await store.loadHostCatalog()

        #expect(options.calls == ["finance/phonon"])
        #expect(store.voiceChoices?.options.map(\.id) == ["Ava", "Kai"])
        #expect(store.voiceChoices?.allowsOther == false)
        #expect(store.voiceName == "Ava Warm")
        store.invalidate()
        #expect(store.hostCatalogs.isEmpty)
    }

    @Test func anOlderPluginKeepsTheVoiceInUseAndSaysToUpdate() async {
        let client = VoiceSettingsProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "phonon", providers: [
            .init(spec: .plugin("phonon"), voiceID: "Ava", apiKeyConfigured: false, model: "", serverURL: ""),
        ])
        let options = VoiceOptionsProbe()
        options.error = VoiceOptionsError.needsPluginUpdate
        let store = VoiceSettingsStore(agentID: "finance", client: client, options: options)
        await store.load()
        await store.loadHostCatalog()

        #expect(store.hostCatalog == .needsPluginUpdate)
        #expect(store.voiceChoices == VoiceOptionList(options: [
            VoiceOption(id: "Ava", name: "Ava", detail: "Not in the list"),
        ]))
        #expect(!store.canSave)
    }

    @Test func anUnexpectedListFailureIsPlainWordsAndAsksAgainNextTime() async {
        let client = VoiceSettingsProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "elevenlabs", providers: [
            .init(spec: VoiceProviderSpec.builtIn("elevenlabs")!, voiceID: "pNInz6obpgDQGcFmaJgB",
                  apiKeyConfigured: true, model: "eleven_multilingual_v2", serverURL: ""),
        ])
        let options = VoiceOptionsProbe()
        options.error = WorkspaceClientError.transportUnavailable
        let store = VoiceSettingsStore(agentID: "finance", client: client, options: options)
        await store.load()
        await store.loadHostCatalog()
        guard case .unavailable(let reason) = store.hostCatalog else {
            Issue.record("Expected a plain reason")
            return
        }
        #expect(reason.contains("ElevenLabs"))
        #expect(store.voiceName == "Adam", "Hermes' default voice still has its name")

        options.error = nil
        options.answer = VoiceHostCatalog(voices: [.init(id: "clone-1", name: "My voice")])
        await store.loadHostCatalog()
        #expect(options.calls.count == 2)
        #expect(store.voiceChoices?.options.map(\.id) == ["pNInz6obpgDQGcFmaJgB", "clone-1"])
    }
}

@MainActor
private final class VoiceSettingsProbe: VoiceSettingsClient {
    var updates: [VoiceSettingsUpdate] = []
    var configurations: [String: VoiceSettingsConfiguration] = [:]
    var saveError: (any Error)?
    var holdLoad = false
    var holdSave = false
    var pendingLoad: CheckedContinuation<VoiceSettingsConfiguration, Never>?
    var pendingSave: CheckedContinuation<Void, Never>?
    var samples = 0
    var sampleError: (any Error)?

    func playSample(agentID: String) async throws {
        samples += 1
        if let sampleError { throw sampleError }
    }
    var configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "openai",
        providers: [.init(id: "openai", title: "OpenAI", voiceID: "alloy", apiKeyConfigured: true),
                    .init(id: "elevenlabs", title: "ElevenLabs", voiceID: "", apiKeyConfigured: false)])

    func load(agentID: String) async throws -> VoiceSettingsConfiguration {
        if holdLoad { return await withCheckedContinuation { pendingLoad = $0 } }
        return configurations[agentID] ?? configuration
    }
    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration {
        updates.append(settings)
        if holdSave { await withCheckedContinuation { pendingSave = $0 } }
        if let saveError { throw saveError }
        let current = configurations[agentID] ?? configuration
        let savedTranscriptionProviderID = settings.transcription?.providerID
            ?? current.transcriptionProviderID
        let saved = VoiceSettingsConfiguration(revision: "revision-2", providerID: settings.providerID,
            providers: current.providers.map { provider in
                provider.id == settings.providerID
                    ? VoiceProviderConfiguration(id: provider.id, title: provider.title,
                        voiceID: settings.voiceID, apiKeyConfigured: settings.apiKey != nil || provider.apiKeyConfigured,
                        model: settings.model ?? provider.model, serverURL: settings.serverURL ?? provider.serverURL,
                        kind: provider.kind, hasVoice: provider.hasVoice, hasModel: provider.hasModel,
                        needsAPIKey: provider.needsAPIKey, supportsServerURL: provider.supportsServerURL,
                        voiceLocation: provider.voiceLocation)
                    : provider
            },
            transcriptionProviderID: savedTranscriptionProviderID,
            transcriptionProviders: current.transcriptionProviders.map { provider in
                guard provider.id == settings.transcription?.providerID else { return provider }
                return VoiceTranscriptionProviderConfiguration(
                    id: provider.id,
                    title: provider.title,
                    model: settings.transcription?.model ?? provider.model,
                    apiKeyConfigured: provider.apiKeyConfigured || settings.transcription?.apiKey != nil,
                    modelOptions: provider.modelOptions,
                    needsAPIKey: provider.needsAPIKey
                )
            })
        configurations[agentID] = saved
        configuration = saved
        return saved
    }
}

@MainActor private final class VoiceSettingsOwner { var current = true }

@MainActor
private final class VoiceOptionsProbe: VoiceOptionsClient {
    var answer = VoiceHostCatalog(voices: [])
    var error: (any Error)?
    private(set) var calls: [String] = []

    func catalog(agentID: String, provider: VoiceProviderConfiguration) async throws -> VoiceHostCatalog {
        calls.append(agentID + "/" + provider.id)
        if let error { throw error }
        return answer
    }
}
