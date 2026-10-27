import Foundation

/// Hermes' built-in speech (TTS) providers as of Hermes 0.21, and the settings
/// each one reads from `tts.<id>` in an agent's config.yaml. Providers set up on
/// the host as custom commands (`tts.providers.<name>`) come from the host's
/// config instead, as `.custom`.
struct VoiceProviderSpec: Equatable, Sendable {
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

    static let builtIn: [VoiceProviderSpec] = [
        .init(id: "piper", title: "Piper", kind: .onYourComputer,
              voiceField: "voice", defaultVoice: "en_US-lessac-medium"),
        .init(id: "kittentts", title: "KittenTTS", kind: .onYourComputer,
              voiceField: "voice", defaultVoice: "Jasper",
              modelField: "model", defaultModel: "KittenML/kitten-tts-nano-0.8-int8"),
        // NeuTTS clones a voice from a reference recording set up on the host.
        .init(id: "neutts", title: "NeuTTS", kind: .onYourComputer),
        .init(id: "edge", title: "Microsoft Edge", kind: .free,
              voiceField: "voice", defaultVoice: "en-US-AriaNeural"),
        .init(id: "openai", title: "OpenAI", kind: .cloud,
              voiceField: "voice", defaultVoice: "alloy",
              modelField: "model", defaultModel: "gpt-4o-mini-tts",
              keyNames: ["VOICE_TOOLS_OPENAI_KEY", "OPENAI_API_KEY"], supportsServerURL: true),
        .init(id: "elevenlabs", title: "ElevenLabs", kind: .cloud,
              voiceField: "voice_id", defaultVoice: "pNInz6obpgDQGcFmaJgB",
              modelField: "model_id", defaultModel: "eleven_multilingual_v2",
              keyNames: ["ELEVENLABS_API_KEY"]),
        .init(id: "gemini", title: "Google Gemini", kind: .cloud,
              voiceField: "voice", defaultVoice: "Kore",
              modelField: "model", defaultModel: "gemini-2.5-flash-preview-tts",
              keyNames: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]),
        .init(id: "xai", title: "xAI", kind: .cloud,
              voiceField: "voice_id", defaultVoice: "eve", keyNames: ["XAI_API_KEY"]),
        .init(id: "mistral", title: "Mistral Voxtral", kind: .cloud,
              voiceField: "voice_id", defaultVoice: "c69964a6-ab8b-4f8a-9465-ec0925096ec8",
              modelField: "model", defaultModel: "voxtral-mini-tts-2603",
              keyNames: ["MISTRAL_API_KEY"]),
        .init(id: "minimax", title: "MiniMax", kind: .cloud,
              voiceField: "voice_id", defaultVoice: "English_expressive_narrator",
              modelField: "model", defaultModel: "speech-02-hd",
              keyNames: ["MINIMAX_API_KEY"]),
        // DeepInfra picks a model from its live catalog when none is set.
        .init(id: "deepinfra", title: "DeepInfra", kind: .cloud,
              voiceField: "voice", defaultVoice: "default", modelField: "model",
              keyNames: ["DEEPINFRA_API_KEY"]),
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
        self.init(id: spec.id, title: spec.title, voiceID: voiceID, apiKeyConfigured: apiKeyConfigured,
                  model: model, serverURL: serverURL, kind: spec.kind,
                  hasVoice: spec.voiceField != nil, hasModel: spec.modelField != nil,
                  needsAPIKey: !spec.keyNames.isEmpty, supportsServerURL: spec.supportsServerURL)
    }
}
