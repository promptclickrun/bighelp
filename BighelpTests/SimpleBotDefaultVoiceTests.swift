import Foundation
import Testing
@testable import Bighelp

@MainActor
struct SimpleBotDefaultVoiceTests {
    private static let tts = AgentVoicePreference(mode: .turnBased, liveProvider: .codexSubscription,
                                                  liveVoice: "cove", hasOwnMode: false)

    @Test
    func theRowNamesTheProviderAndVoiceTheBotSpeaksWith() async {
        let store = VoiceSettingsStore(agentID: "finance", client: DefaultVoiceProbe())
        await store.load()

        #expect(SimpleBotDefaultVoiceSummary.text(voice: Self.tts, store: store) == "OpenAI · Alloy")
    }

    @Test
    func aProviderWithoutAVoiceShowsOnlyItsName() async throws {
        let client = DefaultVoiceProbe()
        client.configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "local",
            providers: [.init(id: "local", title: "Your computer", voiceID: "", apiKeyConfigured: true,
                              hasVoice: false, needsAPIKey: false)])
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()

        #expect(SimpleBotDefaultVoiceSummary.text(voice: Self.tts, store: store) == "Your computer")
    }

    @Test
    func gptLiveShowsItsOwnVoiceNotTheTTSOne() async {
        let store = VoiceSettingsStore(agentID: "finance", client: DefaultVoiceProbe())
        await store.load()
        let live = AgentVoicePreference(mode: .codexLive, liveProvider: .codexSubscription, liveVoice: "cove",
                                        hasOwnMode: true)

        #expect(SimpleBotDefaultVoiceSummary.text(voice: live, store: store) == "Full Duplex · GPT-Live · Cove")
    }

    @Test
    func theRowStaysQuietUntilTheVoiceLoads() {
        let store = VoiceSettingsStore(agentID: "finance", client: DefaultVoiceProbe())

        #expect(SimpleBotDefaultVoiceSummary.text(voice: Self.tts, store: store) == nil)
        #expect(SimpleBotDefaultVoiceSummary.text(voice: Self.tts, store: nil) == nil)
    }

    @Test
    func savingNamesTheNewVoiceInTheRowButOpenEditsDont() async {
        let client = DefaultVoiceProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.chooseVoice("echo")
        #expect(SimpleBotDefaultVoiceSummary.text(voice: Self.tts, store: store) == "OpenAI · Alloy")
        await store.save()

        #expect(SimpleBotDefaultVoiceSummary.text(voice: Self.tts, store: store) == "OpenAI · Echo")
    }

    @Test
    func discardingEditsPutsTheSavedVoiceBack() async {
        let store = VoiceSettingsStore(agentID: "finance", client: DefaultVoiceProbe())
        await store.load()
        store.selectProvider("elevenlabs")
        store.chooseVoice("rachel")
        store.apiKey = "secret"
        #expect(store.hasUnsavedChanges)

        store.discardEdits()

        #expect(!store.hasUnsavedChanges)
        #expect(store.providerID == "openai")
        #expect(store.voiceID == "alloy")
        #expect(store.apiKey.isEmpty)
    }

    @Test
    func theVoiceTypeHereIsJustThisBots() throws {
        let suite = "bighelp.tests.default-voice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.voiceConversationMode = .turnBased
        let choices = AgentVoiceChoices(defaults: defaults)
        let model = SimpleBotVoiceModel(agentID: "finance", voice: SimpleBotVoiceSettings(
            settings: settings, choices: choices, computer: "computer-a", connection: { nil }, makeStore: { nil }))

        model.setMode(.codexLive)
        model.setLiveVoice("maple")

        #expect(model.preference.mode == .codexLive)
        #expect(model.summary == "Full Duplex · GPT-Live · Maple", "The row says the bot's own voice")
        #expect(settings.voiceConversationMode == .turnBased, "Every other agent keeps the default")
        #expect(settings.liveVoice(for: .codexSubscription) == LiveVoiceProvider.codexSubscription.defaultVoice)

        model.useDefaultMode()
        #expect(model.preference.mode == .turnBased)
        #expect(!model.preference.hasOwnMode)
    }

    @Test
    func aReconnectGetsAStoreOfItsOwnSoSaveKeepsWorking() async throws {
        let suite = "bighelp.tests.default-voice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DefaultVoiceProbe()
        let connection = ConnectionProbe()
        let model = SimpleBotVoiceModel(agentID: "finance", voice: SimpleBotVoiceSettings(
            settings: SettingsStore(defaults: defaults), choices: AgentVoiceChoices(defaults: defaults),
            computer: "computer-a", connection: { connection.key },
            makeStore: {
                let key = connection.key
                return VoiceSettingsStore(agentID: "finance", client: client, isCurrent: { connection.key == key })
            }))

        await model.follow()
        let first = try #require(model.store)
        #expect(first.configuration != nil)

        // Back from the background: the old connection's store can't save any more.
        connection.key = "connection-2"
        first.chooseVoice("echo")
        #expect(!first.canSave)
        await model.follow()

        let second = try #require(model.store)
        #expect(second !== first)
        #expect(first.configuration == nil, "The old store is retired")
        second.chooseVoice("echo")
        #expect(second.canSave)
        await second.save()
        #expect(client.updates.map(\.voiceID) == ["echo"])

        second.chooseVoice("nova")
        await model.follow()
        #expect(model.store === second, "The same connection keeps the store and its edits")
        #expect(second.voiceID == "nova")
    }
}

@MainActor
private final class ConnectionProbe {
    var key: String? = "connection-1"
}

@MainActor
private final class DefaultVoiceProbe: VoiceSettingsClient {
    var configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "openai",
        providers: [.init(id: "openai", title: "OpenAI", voiceID: "alloy", apiKeyConfigured: true),
                    .init(id: "elevenlabs", title: "ElevenLabs", voiceID: "", apiKeyConfigured: false)])
    private(set) var updates: [VoiceSettingsUpdate] = []

    func load(agentID: String) async throws -> VoiceSettingsConfiguration { configuration }

    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration {
        updates.append(settings)
        configuration = VoiceSettingsConfiguration(revision: "revision-\(updates.count + 1)", providerID: settings.providerID,
            providers: configuration.providers.map { provider in
                provider.id == settings.providerID
                    ? VoiceProviderConfiguration(id: provider.id, title: provider.title,
                        voiceID: settings.voiceID, apiKeyConfigured: provider.apiKeyConfigured,
                        model: provider.model, serverURL: provider.serverURL, kind: provider.kind,
                        hasVoice: provider.hasVoice, hasModel: provider.hasModel,
                        needsAPIKey: provider.needsAPIKey, supportsServerURL: provider.supportsServerURL,
                        voiceLocation: provider.voiceLocation)
                    : provider
            })
        return configuration
    }
}
