import Foundation
import Testing
@testable import Bighelp

@MainActor
struct SimpleBotDefaultVoiceTests {
    @Test
    func theRowNamesTheProviderAndVoiceTheBotSpeaksWith() async {
        let store = VoiceSettingsStore(agentID: "finance", client: DefaultVoiceProbe())
        await store.load()

        #expect(SimpleBotDefaultVoiceSummary.text(mode: .turnBased, liveProvider: .codexSubscription,
                                                  liveVoice: "cove", store: store) == "OpenAI · alloy")
    }

    @Test
    func aProviderWithoutAVoiceShowsOnlyItsName() async throws {
        let client = DefaultVoiceProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "local",
            providers: [.init(id: "local", title: "Your computer", voiceID: "", apiKeyConfigured: true,
                              hasVoice: false, needsAPIKey: false)])
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()

        #expect(SimpleBotDefaultVoiceSummary.text(mode: .turnBased, liveProvider: .codexSubscription,
                                                  liveVoice: "cove", store: store) == "Your computer")
    }

    @Test
    func gptLiveShowsItsOwnVoiceNotTheTTSOne() async {
        let store = VoiceSettingsStore(agentID: "finance", client: DefaultVoiceProbe())
        await store.load()

        #expect(SimpleBotDefaultVoiceSummary.text(mode: .codexLive, liveProvider: .codexSubscription,
                                                  liveVoice: "cove", store: store) == "GPT Live · Cove")
    }

    @Test
    func theRowStaysQuietUntilTheVoiceLoads() {
        let store = VoiceSettingsStore(agentID: "finance", client: DefaultVoiceProbe())

        #expect(SimpleBotDefaultVoiceSummary.text(mode: .turnBased, liveProvider: .codexSubscription,
                                                  liveVoice: "cove", store: store) == nil)
    }

    @Test
    func savingNamesTheNewVoiceInTheRow() async {
        let client = DefaultVoiceProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.voiceID = "echo"
        await store.save()

        #expect(SimpleBotDefaultVoiceSummary.text(mode: .turnBased, liveProvider: .codexSubscription,
                                                  liveVoice: "cove", store: store) == "OpenAI · echo")
    }

    @Test
    func discardingEditsPutsTheSavedVoiceBackAndKeepsTheRowText() async {
        let store = VoiceSettingsStore(agentID: "finance", client: DefaultVoiceProbe())
        await store.load()
        store.selectProvider("elevenlabs")
        store.voiceID = "rachel"
        store.apiKey = "secret"
        #expect(store.hasUnsavedChanges)

        store.discardEdits()

        #expect(!store.hasUnsavedChanges)
        #expect(store.providerID == "openai")
        #expect(store.voiceID == "alloy")
        #expect(store.apiKey.isEmpty)
        #expect(SimpleBotDefaultVoiceSummary.text(mode: .turnBased, liveProvider: .codexSubscription,
                                                  liveVoice: "cove", store: store) == "OpenAI · alloy")
    }

    @Test
    func theGPTLiveChoiceKeepsEveryAgentOnTheDevicesMode() throws {
        let suite = "bighelp.tests.default-voice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)

        SimpleBotDefaultVoiceChoice.apply(.codexLive, to: settings)
        #expect(settings.voiceConversationMode == .codexLive)
        SimpleBotDefaultVoiceChoice.apply(.turnBased, to: settings)
        #expect(settings.voiceConversationMode == .turnBased)
    }
}

@MainActor
private final class DefaultVoiceProbe: VoiceSettingsClient {
    var configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "openai",
        providers: [.init(id: "openai", title: "OpenAI", voiceID: "alloy", apiKeyConfigured: true),
                    .init(id: "elevenlabs", title: "ElevenLabs", voiceID: "", apiKeyConfigured: false)])

    func load(agentID: String) async throws -> VoiceSettingsConfiguration { configuration }

    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration {
        configuration = VoiceSettingsConfiguration(revision: "revision-2", providerID: settings.providerID,
            providers: configuration.providers.map { provider in
                provider.id == settings.providerID
                    ? VoiceProviderConfiguration(id: provider.id, title: provider.title,
                        voiceID: settings.voiceID, apiKeyConfigured: provider.apiKeyConfigured,
                        model: provider.model, serverURL: provider.serverURL, kind: provider.kind,
                        hasVoice: provider.hasVoice, hasModel: provider.hasModel,
                        needsAPIKey: provider.needsAPIKey, supportsServerURL: provider.supportsServerURL)
                    : provider
            })
        return configuration
    }
}
