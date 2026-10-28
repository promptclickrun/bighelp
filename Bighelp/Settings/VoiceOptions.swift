import Foundation

/// A voice or model a speech provider offers, as its picker lists it.
struct VoiceOption: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// A short second line: its style, its language, or what it's good at.
    var detail: String? = nil
    /// The picker's section, such as a language; nil lists it with the rest.
    var group: String? = nil
}

/// What a voice or model picker shows for the provider being edited.
struct VoiceOptionList: Equatable, Sendable {
    var options: [VoiceOption]
    /// The provider also takes a value that isn't listed, typed in Other.
    var allowsOther = false
}

/// The voices (and models) a provider lists from the computer: the agent's own ElevenLabs voices, or
/// what a speech plugin such as Phonon offers.
struct VoiceHostCatalog: Equatable, Sendable {
    var voices: [VoiceOption]
    var models: [VoiceOption] = []
    var defaultVoice: String? = nil
}

enum VoiceHostCatalogState: Equatable, Sendable {
    case loading
    case loaded(VoiceHostCatalog)
    /// The bighelp plugin on the computer is too old to list a speech plugin's voices.
    case needsPluginUpdate
    /// The list can't be read now; why, in plain words.
    case unavailable(String)
}

enum VoiceOptionsError: Error, Equatable {
    case needsPluginUpdate
    case unavailable(String)
}

/// Reads the voices a provider lists on the computer. Built-in providers' lists ship with the app.
@MainActor
protocol VoiceOptionsClient: AnyObject {
    func catalog(agentID: String, provider: VoiceProviderConfiguration) async throws -> VoiceHostCatalog
}

extension VoiceProviderConfiguration {
    /// A voice can be chosen. A custom command's voice is optional (empty is the command's own); every
    /// other provider with a voice needs one (`hasVoice`).
    var takesVoice: Bool { hasVoice || voiceLocation == .commandProvider }

    /// Its voices come from the computer, not the app's own list.
    var listsVoicesOnComputer: Bool { id == "elevenlabs" || voiceLocation == .plugin }
}

/// What a provider's voice and model pickers list: Hermes' own names first, what the computer lists
/// where it can, and always the value in use, so opening a picker never loses it.
enum VoiceOptions {
    static func voices(for provider: VoiceProviderConfiguration, model: String, serverURL: String,
                       host: VoiceHostCatalogState?, current: String) -> VoiceOptionList {
        let spec = VoiceProviderSpec.builtIn(provider.id)
        var list = VoiceOptionList(options: spec?.voices ?? [], allowsOther: spec?.acceptsOtherVoices ?? false)
        switch provider.voiceLocation {
        case .commandProvider:
            list = VoiceOptionList(options: [VoiceOption(id: "", name: String(localized: "Default"),
                                                         detail: String(localized: "The command's own voice"))],
                                   allowsOther: true)
        case .plugin:
            // Until the plugin lists them, only the voice in use shows; a plugin that lists none takes any.
            if case .loaded(let catalog) = host {
                list = VoiceOptionList(options: catalog.voices, allowsOther: catalog.voices.isEmpty)
            } else {
                list = VoiceOptionList(options: [])
            }
        case .section:
            if provider.listsVoicesOnComputer, case .loaded(let catalog) = host, !catalog.voices.isEmpty {
                list.options = catalog.voices
            }
        }
        if isSelfHosted(provider, serverURL: serverURL) {
            // A self-hosted server (Kokoro, Speaches) has voices of its own.
            list.allowsOther = true
        } else if provider.id == "openai",
                  VoiceProviderLists.tts1Models.contains(model.trimmingCharacters(in: .whitespacesAndNewlines)) {
            list.options = list.options.filter { VoiceProviderLists.tts1Voices.contains($0.id) }
        }
        return keeping(current, in: list, known: spec?.voices ?? [])
    }

    static func models(for provider: VoiceProviderConfiguration, serverURL: String, current: String) -> VoiceOptionList {
        let spec = VoiceProviderSpec.builtIn(provider.id)
        var list = VoiceOptionList(options: spec?.models ?? [])
        if spec?.allowsAutomaticModel == true {
            list.options.insert(VoiceOption(id: "", name: String(localized: "Automatic"),
                                            detail: String(localized: "\(provider.title) picks one")), at: 0)
            list.allowsOther = true
        }
        if isSelfHosted(provider, serverURL: serverURL) { list.allowsOther = true }
        return keeping(current, in: list, known: spec?.models ?? [])
    }

    /// The name a voice goes by, for rows that show it.
    static func voiceName(_ id: String, provider: VoiceProviderConfiguration, model: String, serverURL: String,
                          host: VoiceHostCatalogState?) -> String {
        name(id, in: voices(for: provider, model: model, serverURL: serverURL, host: host, current: ""))
    }

    static func modelName(_ id: String, provider: VoiceProviderConfiguration, serverURL: String) -> String {
        name(id, in: models(for: provider, serverURL: serverURL, current: ""))
    }

    private static func name(_ id: String, in list: VoiceOptionList) -> String {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let option = list.options.first(where: { $0.id == value }) { return option.name }
        return value.isEmpty ? String(localized: "Default") : value
    }

    private static func isSelfHosted(_ provider: VoiceProviderConfiguration, serverURL: String) -> Bool {
        provider.supportsServerURL && !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `known` names a value the list left out, such as Hermes' default ElevenLabs voice when the
    /// account's own list doesn't have it.
    private static func keeping(_ current: String, in list: VoiceOptionList, known: [VoiceOption]) -> VoiceOptionList {
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !list.options.contains(where: { $0.id == value }) else { return list }
        var kept = list
        let option = known.first { $0.id == value }.map { VoiceOption(id: $0.id, name: $0.name, detail: $0.detail) }
            ?? VoiceOption(id: value, name: value, detail: String(localized: "Not in the list"))
        kept.options.insert(option, at: 0)
        return kept
    }
}
