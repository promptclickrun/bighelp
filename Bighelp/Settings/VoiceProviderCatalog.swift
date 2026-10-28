import Foundation

/// Hermes' built-in speech (TTS) providers as of Hermes 0.21, and the settings
/// each one reads from `tts.<id>` in an agent's config.yaml. Providers set up on
/// the host as custom commands (`tts.providers.<name>`) and speech plugins (such
/// as Phonon) come from the host's config instead, as `.custom`.
struct VoiceProviderSpec: Equatable, Sendable {
    /// Where an agent's config.yaml keeps the voice for a provider. Hermes reads
    /// it from a different place for each kind, so a voice written to the wrong
    /// one is ignored and every agent keeps sounding the same.
    enum VoiceLocation: Sendable, Equatable {
        /// `tts.<id>.<field>`: Hermes' built-in providers.
        case section
        /// A speech plugin. Hermes passes a plugin only the top-level `tts.voice`;
        /// the plugin itself falls back to its own `tts.<id>.voice`.
        case plugin
        /// A custom command: `{voice}` comes from `tts.providers.<id>.voice`.
        case commandProvider
    }

    enum Kind: Int, Comparable, CaseIterable, Sendable {
        /// Runs on this iPhone or iPad (`OnDeviceVoiceModel`): no account, key or internet.
        /// Chosen per agent on the device; the computer never sees it.
        case onThisDevice
        /// Runs on the person's own computer: no account, no key.
        case onYourComputer
        /// A custom command set up on the computer (`tts.providers.<name>`).
        case custom
        /// Free cloud voices, no key.
        case free
        /// A cloud service billed to the person's own API key.
        case cloud

        @MainActor var title: String {
            switch self {
            case .onThisDevice: String(localized: "Runs on this \(OnDeviceVoiceModel.deviceName)")
            case .onYourComputer: "Runs on your computer"
            case .custom: "Custom (set up on your computer)"
            case .free: "Free"
            case .cloud: "Cloud (your API key)"
            }
        }

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let title: String
    let kind: Kind
    /// The `tts.<id>` field that picks the voice, if the provider has one.
    var voiceField: String? = nil
    var defaultVoice = ""
    var modelField: String? = nil
    var defaultModel = ""
    /// Env names Hermes reads the key from. The app saves to the first.
    var keyNames: [String] = []
    /// OpenAI's `base_url`, which points it at a self-hosted OpenAI-compatible
    /// server such as Kokoro or Speaches.
    var supportsServerURL = false
    var voiceLocation: VoiceLocation = .section
    /// The voices and models its pickers list: the ones Hermes itself offers, first.
    var voices: [VoiceOption] = []
    var models: [VoiceOption] = []
    /// It also takes voices that aren't listed (a cloned voice, one of hundreds online), so its voice
    /// picker offers Other.
    var acceptsOtherVoices = false
    /// An empty model is the provider's own pick.
    var allowsAutomaticModel = false

    /// A custom command provider (`tts.providers.<id>`): the voice is its own
    /// `voice` entry, whatever the command does with it, and may be left empty
    /// for the command's own default.
    static func commandProvider(_ id: String) -> VoiceProviderSpec {
        VoiceProviderSpec(id: id, title: id, kind: .custom, voiceField: "voice", voiceLocation: .commandProvider,
                          acceptsOtherVoices: true)
    }

    /// A speech plugin the app has no catalog entry for, such as Phonon. The
    /// plugin lists its own voices (`voice-catalog`).
    static func plugin(_ id: String) -> VoiceProviderSpec {
        VoiceProviderSpec(id: id, title: id, kind: .custom, voiceField: "voice", voiceLocation: .plugin)
    }

    static let builtIn: [VoiceProviderSpec] = [
        .init(id: "piper", title: "Piper", kind: .onYourComputer,
              voiceField: "voice", defaultVoice: "en_US-lessac-medium",
              voices: VoiceProviderLists.piperVoices, acceptsOtherVoices: true),
        .init(id: "kittentts", title: "KittenTTS", kind: .onYourComputer,
              voiceField: "voice", defaultVoice: "Jasper",
              modelField: "model", defaultModel: "KittenML/kitten-tts-nano-0.8-int8",
              voices: VoiceProviderLists.kittenVoices, models: VoiceProviderLists.kittenModels),
        // NeuTTS clones a voice from a reference recording set up on the host.
        .init(id: "neutts", title: "NeuTTS", kind: .onYourComputer),
        .init(id: "edge", title: "Microsoft Edge", kind: .free,
              voiceField: "voice", defaultVoice: "en-US-AriaNeural",
              voices: VoiceProviderLists.edgeVoices, acceptsOtherVoices: true),
        .init(id: "openai", title: "OpenAI", kind: .cloud,
              voiceField: "voice", defaultVoice: "alloy",
              modelField: "model", defaultModel: "gpt-4o-mini-tts",
              keyNames: ["VOICE_TOOLS_OPENAI_KEY", "OPENAI_API_KEY"], supportsServerURL: true,
              voices: VoiceProviderLists.openAIVoices, models: VoiceProviderLists.openAIModels),
        // Voices come from the agent's own account; Adam is Hermes' default.
        .init(id: "elevenlabs", title: "ElevenLabs", kind: .cloud,
              voiceField: "voice_id", defaultVoice: "pNInz6obpgDQGcFmaJgB",
              modelField: "model_id", defaultModel: "eleven_multilingual_v2",
              keyNames: ["ELEVENLABS_API_KEY"],
              voices: [VoiceOption(id: "pNInz6obpgDQGcFmaJgB", name: "Adam")],
              models: VoiceProviderLists.elevenLabsModels, acceptsOtherVoices: true),
        .init(id: "gemini", title: "Google Gemini", kind: .cloud,
              voiceField: "voice", defaultVoice: "Kore",
              modelField: "model", defaultModel: "gemini-2.5-flash-preview-tts",
              keyNames: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
              voices: VoiceProviderLists.geminiVoices, models: VoiceProviderLists.geminiModels),
        // Hermes offers Eve, or a custom voice made in the xAI console.
        .init(id: "xai", title: "xAI", kind: .cloud,
              voiceField: "voice_id", defaultVoice: "eve", keyNames: ["XAI_API_KEY"],
              voices: [VoiceOption(id: "eve", name: "Eve")], acceptsOtherVoices: true),
        .init(id: "mistral", title: "Mistral Voxtral", kind: .cloud,
              voiceField: "voice_id", defaultVoice: "c69964a6-ab8b-4f8a-9465-ec0925096ec8",
              modelField: "model", defaultModel: "voxtral-mini-tts-2603",
              keyNames: ["MISTRAL_API_KEY"],
              voices: [VoiceOption(id: "c69964a6-ab8b-4f8a-9465-ec0925096ec8", name: "Paul", detail: "Neutral")],
              models: [VoiceOption(id: "voxtral-mini-tts-2603", name: "Voxtral Mini TTS")],
              acceptsOtherVoices: true),
        .init(id: "minimax", title: "MiniMax", kind: .cloud,
              voiceField: "voice_id", defaultVoice: "English_expressive_narrator",
              modelField: "model", defaultModel: "speech-02-hd",
              keyNames: ["MINIMAX_API_KEY"],
              voices: VoiceProviderLists.miniMaxVoices, models: VoiceProviderLists.miniMaxModels,
              acceptsOtherVoices: true),
        // DeepInfra picks a model from its live catalog when none is set.
        .init(id: "deepinfra", title: "DeepInfra", kind: .cloud,
              voiceField: "voice", defaultVoice: "default", modelField: "model",
              keyNames: ["DEEPINFRA_API_KEY"],
              voices: [VoiceOption(id: "default", name: "Default")], acceptsOtherVoices: true,
              allowsAutomaticModel: true),
    ]

    static func builtIn(_ id: String) -> VoiceProviderSpec? {
        builtIn.first { $0.id == id }
    }

    /// A provider this app doesn't know, such as the Nous subscription or a
    /// newer Hermes provider: it can be kept selected, with nothing to edit.
    static func unknown(_ id: String) -> VoiceProviderSpec {
        VoiceProviderSpec(id: id, title: id == "nous" ? "Nous subscription" : id, kind: .cloud)
    }
}

extension VoiceProviderConfiguration {
    init(spec: VoiceProviderSpec, voiceID: String, apiKeyConfigured: Bool, model: String, serverURL: String) {
        // A custom command's voice is optional (`takesVoice`): empty runs the command's own.
        self.init(id: spec.id, title: spec.title, voiceID: voiceID, apiKeyConfigured: apiKeyConfigured,
                  model: model, serverURL: serverURL, kind: spec.kind,
                  hasVoice: spec.voiceField != nil && spec.voiceLocation != .commandProvider,
                  hasModel: spec.modelField != nil,
                  needsAPIKey: !spec.keyNames.isEmpty, supportsServerURL: spec.supportsServerURL,
                  voiceLocation: spec.voiceLocation)
    }
}

/// The voices and models Hermes offers for its built-in providers (its desktop app's lists), with
/// names people can read. Providers that take more than these offer Other in their voice picker.
enum VoiceProviderLists {
    /// Every OpenAI voice; `tts-1` and `tts-1-hd` speak only `tts1Voices`.
    static let openAIVoices: [VoiceOption] = [
        "alloy", "ash", "ballad", "cedar", "coral", "echo", "fable", "marin", "nova", "onyx", "sage",
        "shimmer", "verse",
    ].map { VoiceOption(id: $0, name: $0.capitalized) }
    static let tts1Voices: Set<String> = ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]
    static let tts1Models: Set<String> = ["tts-1", "tts-1-hd"]
    static let openAIModels: [VoiceOption] = [
        VoiceOption(id: "gpt-4o-mini-tts", name: "GPT-4o mini TTS", detail: "Every voice"),
        VoiceOption(id: "tts-1", name: "TTS-1", detail: "Fastest"),
        VoiceOption(id: "tts-1-hd", name: "TTS-1 HD", detail: "Clearer, a little slower"),
    ]

    static let elevenLabsModels: [VoiceOption] = [
        VoiceOption(id: "eleven_multilingual_v2", name: "Multilingual v2", detail: "Natural, many languages"),
        VoiceOption(id: "eleven_v3", name: "Eleven v3", detail: "Most expressive"),
        VoiceOption(id: "eleven_flash_v2_5", name: "Flash v2.5", detail: "Fastest, many languages"),
        VoiceOption(id: "eleven_turbo_v2_5", name: "Turbo v2.5", detail: "Fast, many languages"),
        VoiceOption(id: "eleven_flash_v2", name: "Flash v2", detail: "Fastest, English"),
        VoiceOption(id: "eleven_turbo_v2", name: "Turbo v2", detail: "Fast, English"),
    ]

    /// Gemini's prebuilt voices, each with the style Google gives it.
    static let geminiVoices: [VoiceOption] = ([
        ("Zephyr", "Bright"), ("Puck", "Upbeat"), ("Charon", "Informative"), ("Kore", "Firm"),
        ("Fenrir", "Excitable"), ("Leda", "Youthful"), ("Orus", "Firm"), ("Aoede", "Breezy"),
        ("Callirrhoe", "Easy-going"), ("Autonoe", "Bright"), ("Enceladus", "Breathy"), ("Iapetus", "Clear"),
        ("Umbriel", "Easy-going"), ("Algieba", "Smooth"), ("Despina", "Smooth"), ("Erinome", "Clear"),
        ("Algenib", "Gravelly"), ("Rasalgethi", "Informative"), ("Laomedeia", "Upbeat"), ("Achernar", "Soft"),
        ("Alnilam", "Firm"), ("Schedar", "Even"), ("Gacrux", "Mature"), ("Pulcherrima", "Forward"),
        ("Achird", "Friendly"), ("Zubenelgenubi", "Casual"), ("Vindemiatrix", "Gentle"), ("Sadachbia", "Lively"),
        ("Sadaltager", "Knowledgeable"), ("Sulafat", "Warm"),
    ] as [(String, String)]).map { VoiceOption(id: $0.0, name: $0.0, detail: $0.1) }
    static let geminiModels: [VoiceOption] = [
        VoiceOption(id: "gemini-2.5-flash-preview-tts", name: "Gemini 2.5 Flash", detail: "Fast"),
        VoiceOption(id: "gemini-2.5-pro-preview-tts", name: "Gemini 2.5 Pro", detail: "Highest quality"),
    ]

    /// English voices from Microsoft's free list, which has hundreds more in other languages.
    static let edgeVoices: [VoiceOption] = {
        let locales: [(code: String, language: String, names: [String])] = [
            ("en-US", "English (US)", ["Aria", "Jenny", "Guy", "Andrew", "Brian", "Emma", "Ava", "Christopher",
                                       "Eric", "Michelle", "Roger", "Steffan"]),
            ("en-GB", "English (UK)", ["Sonia", "Ryan", "Libby", "Maisie", "Thomas"]),
            ("en-AU", "English (Australia)", ["Natasha", "William"]),
            ("en-CA", "English (Canada)", ["Clara", "Liam"]),
            ("en-IE", "English (Ireland)", ["Emily", "Connor"]),
            ("en-IN", "English (India)", ["Neerja", "Prabhat"]),
        ]
        return locales.flatMap { locale in
            locale.names.map { VoiceOption(id: "\(locale.code)-\($0)Neural", name: $0, group: locale.language) }
        }
    }()

    /// English voices from Piper's catalog, which covers dozens of languages. Hermes downloads one
    /// the first time it speaks.
    static let piperVoices: [VoiceOption] = {
        let us = "English (US)", uk = "English (UK)"
        let voices: [(id: String, name: String, quality: String, group: String)] = [
            ("en_US-lessac-medium", "Lessac", "medium", us), ("en_US-lessac-high", "Lessac", "high", us),
            ("en_US-amy-medium", "Amy", "medium", us), ("en_US-ryan-medium", "Ryan", "medium", us),
            ("en_US-ryan-high", "Ryan", "high", us), ("en_US-joe-medium", "Joe", "medium", us),
            ("en_US-kristin-medium", "Kristin", "medium", us), ("en_US-hfc_female-medium", "HFC Female", "medium", us),
            ("en_US-hfc_male-medium", "HFC Male", "medium", us), ("en_US-libritts-high", "LibriTTS", "high", us),
            ("en_GB-alan-medium", "Alan", "medium", uk), ("en_GB-alba-medium", "Alba", "medium", uk),
            ("en_GB-cori-medium", "Cori", "medium", uk), ("en_GB-jenny_dioco-medium", "Jenny", "medium", uk),
            ("en_GB-northern_english_male-medium", "Northern English Male", "medium", uk),
            ("en_GB-southern_english_female-low", "Southern English Female", "low", uk),
        ]
        return voices.map { voice in
            let detail = switch voice.quality {
            case "high": String(localized: "Best sound")
            case "low": String(localized: "Smallest download")
            default: String(localized: "Balanced")
            }
            return VoiceOption(id: voice.id, name: voice.name, detail: detail, group: voice.group)
        }
    }()

    static let kittenVoices: [VoiceOption] = ["Jasper", "Bella", "Luna", "Bruno", "Rosie", "Hugo", "Kiki", "Leo"]
        .map { VoiceOption(id: $0, name: $0) }
    static let kittenModels: [VoiceOption] = [
        VoiceOption(id: "KittenML/kitten-tts-nano-0.8-int8", name: "Nano", detail: "Smallest, quickest to load"),
        VoiceOption(id: "KittenML/kitten-tts-micro-0.8-int8", name: "Micro", detail: "In between"),
        VoiceOption(id: "KittenML/kitten-tts-mini-0.8-int8", name: "Mini", detail: "Largest, best sound"),
    ]

    /// MiniMax's own English voices; a cloned voice goes in Other.
    static let miniMaxVoices: [VoiceOption] = ([
        ("English_expressive_narrator", "Expressive Narrator"), ("English_Graceful_Lady", "Graceful Lady"),
        ("English_Insightful_Speaker", "Insightful Speaker"), ("English_radiant_girl", "Radiant Girl"),
        ("English_Persuasive_Man", "Persuasive Man"), ("Wise_Woman", "Wise Woman"),
        ("Friendly_Person", "Friendly Person"), ("Deep_Voice_Man", "Deep Voice Man"), ("Calm_Woman", "Calm Woman"),
        ("Casual_Guy", "Casual Guy"), ("Lively_Girl", "Lively Girl"), ("Patient_Man", "Patient Man"),
    ] as [(String, String)]).map { VoiceOption(id: $0.0, name: $0.1) }
    static let miniMaxModels: [VoiceOption] = [
        VoiceOption(id: "speech-02-hd", name: "Speech-02 HD", detail: "Best sound"),
        VoiceOption(id: "speech-02-turbo", name: "Speech-02 Turbo", detail: "Faster"),
    ]
}
