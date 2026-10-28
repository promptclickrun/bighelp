import Foundation
import Testing
@testable import Bighelp

@MainActor
struct VoiceOptionsTests {
    private func provider(_ id: String, voice: String = "", model: String = "", serverURL: String = "")
        -> VoiceProviderConfiguration {
        VoiceProviderConfiguration(spec: VoiceProviderSpec.builtIn(id)!, voiceID: voice, apiKeyConfigured: true,
                                   model: model, serverURL: serverURL)
    }

    /// Hermes falls back to these when nothing is set, so each picker must be able to show them.
    @Test func everyBuiltInProviderListsHermesDefaults() {
        for spec in VoiceProviderSpec.builtIn {
            if spec.voiceField != nil {
                #expect(spec.voices.contains { $0.id == spec.defaultVoice }, "\(spec.id) voices")
            }
            if spec.modelField != nil, !spec.defaultModel.isEmpty {
                #expect(spec.models.contains { $0.id == spec.defaultModel }, "\(spec.id) models")
            }
            #expect(Set(spec.voices.map(\.id)).count == spec.voices.count, "\(spec.id) voices are unique")
        }
    }

    @Test func openAIsOlderModelsListOnlyTheVoicesTheySpeak() {
        let all = VoiceOptions.voices(for: provider("openai"), model: "gpt-4o-mini-tts", serverURL: "", host: nil,
                                      current: "")
        let older = VoiceOptions.voices(for: provider("openai"), model: "tts-1-hd", serverURL: "", host: nil,
                                        current: "")

        #expect(all.options.map(\.id).contains("marin"))
        #expect(!older.options.map(\.id).contains("marin"))
        #expect(!all.allowsOther, "OpenAI's own voices are a closed list")
    }

    @Test func aSelfHostedServerTakesAnyVoiceAndModel() {
        let openAI = provider("openai", serverURL: "http://10.0.0.5:8880/v1")

        #expect(VoiceOptions.voices(for: openAI, model: "kokoro", serverURL: openAI.serverURL, host: nil,
                                    current: "").allowsOther)
        #expect(VoiceOptions.models(for: openAI, serverURL: openAI.serverURL, current: "").allowsOther)
        #expect(!VoiceOptions.models(for: provider("openai"), serverURL: "", current: "").allowsOther)
    }

    @Test func aCustomCommandOffersItsOwnDefaultAndOther() {
        let command = VoiceProviderConfiguration(spec: .commandProvider("kokoro"), voiceID: "", apiKeyConfigured: false,
                                                 model: "", serverURL: "")

        let list = VoiceOptions.voices(for: command, model: "", serverURL: "", host: nil, current: "")

        #expect(list.options.map(\.id) == [""])
        #expect(list.allowsOther)
        #expect(VoiceOptions.voiceName("", provider: command, model: "", serverURL: "", host: nil) == "Default")
    }

    @Test func aModelTheProviderPicksItselfIsAutomatic() {
        let list = VoiceOptions.models(for: provider("deepinfra"), serverURL: "", current: "")

        #expect(list.options.first?.id == "")
        #expect(list.options.first?.name == "Automatic")
        #expect(list.allowsOther)
    }

    @Test func aVoiceThatIsntListedStaysChosen() {
        let list = VoiceOptions.voices(for: provider("edge"), model: "", serverURL: "", host: nil,
                                       current: "fr-FR-DeniseNeural")

        #expect(list.options.first?.id == "fr-FR-DeniseNeural")
        #expect(list.allowsOther, "Edge has hundreds more voices than it lists")
        #expect(VoiceOptions.voiceName("en-GB-SoniaNeural", provider: provider("edge"), model: "", serverURL: "",
                                       host: nil) == "Sonia")
    }
}
