import Foundation

enum AIProviderArtwork: Equatable, Sendable {
    case official(assetName: String)
    case fallback
}

struct AIProviderOfficialArtworkGeometry: Equatable, Sendable {
    let insetFraction: CGFloat
    let opticalScale: CGFloat
    let clipsToFrame: Bool
}

enum AIProviderBrand: String, CaseIterable, Equatable, Sendable {
    case openAI
    /// ChatGPT sign-in through Codex, apart from OpenAI's API.
    case codex
    case anthropic
    /// A Claude subscription (Claude Code), apart from Anthropic's API.
    case claude
    case google
    case nous
    case openRouter
    case xAI
    case mistral
    case deepSeek
    case groq
    case cerebras
    case together
    case fireworks
    case perplexity
    case azure
    case bedrock
    case cohere
    case ollama
    case lmStudio
    case moonshot
    case minimax
    case zAI
    case huggingFace
    case venice
    case nvidia
    case githubCopilot
    case custom

    /// Used only when a catalog has no usable host-reported provider name.
    /// A resolved brand never rewrites an authoritative catalog label.
    var fallbackDisplayName: String? {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .claude: "Claude"
        case .codex: "Codex"
        case .google: "Google"
        case .nous: "Nous Research"
        case .openRouter: "OpenRouter"
        case .xAI: "xAI"
        case .mistral: "Mistral"
        case .deepSeek: "DeepSeek"
        case .groq: "Groq"
        case .cerebras: "Cerebras"
        case .together: "Together AI"
        case .fireworks: "Fireworks AI"
        case .perplexity: "Perplexity"
        case .azure: "Azure"
        case .bedrock: "AWS Bedrock"
        case .cohere: "Cohere"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .moonshot: "Kimi / Moonshot"
        case .minimax: "MiniMax"
        case .zAI: "Z.AI / GLM"
        case .huggingFace: "Hugging Face"
        case .venice: "Venice AI"
        case .nvidia: "NVIDIA NIM"
        case .githubCopilot: "GitHub Copilot"
        case .custom: nil
        }
    }

    var artwork: AIProviderArtwork {
        switch self {
        case .openAI: .official(assetName: "ProviderLogoOpenAI")
        case .anthropic: .official(assetName: "ProviderLogoAnthropic")
        case .claude: .official(assetName: "ProviderLogoClaude")
        case .codex: .official(assetName: "ProviderLogoCodex")
        case .google: .official(assetName: "ProviderLogoGoogle")
        case .openRouter: .official(assetName: "ProviderLogoOpenRouter")
        case .mistral: .official(assetName: "ProviderLogoMistral")
        case .lmStudio: .official(assetName: "ProviderLogoLMStudio")
        case .huggingFace: .official(assetName: "ProviderLogoHuggingFace")
        case .venice: .official(assetName: "ProviderLogoVenice")
        case .githubCopilot: .official(assetName: "ProviderLogoGitHubCopilot")
        case .nous: .official(assetName: "ProviderLogoNous")
        case .xAI, .deepSeek, .groq, .cerebras,
             .together, .fireworks, .perplexity, .azure, .bedrock, .cohere,
             .ollama, .moonshot, .minimax, .zAI, .nvidia, .custom:
            .fallback
        }
    }

    var logoAssetName: String? {
        switch artwork {
        case let .official(assetName): assetName
        case .fallback: nil
        }
    }

    var officialArtworkGeometry: AIProviderOfficialArtworkGeometry {
        switch self {
        case .openAI:
            AIProviderOfficialArtworkGeometry(
                insetFraction: 0,
                opticalScale: 2,
                clipsToFrame: false
            )
        case .codex:
            // The glyph fills about 75% of its canvas; bring it level with other marks.
            AIProviderOfficialArtworkGeometry(
                insetFraction: 0.10,
                opticalScale: 1.3,
                clipsToFrame: false
            )
        default:
            AIProviderOfficialArtworkGeometry(
                insetFraction: 0.10,
                opticalScale: 1,
                clipsToFrame: false
            )
        }
    }

    var monogram: String {
        switch self {
        case .openAI: "◎"
        case .anthropic: "AI"
        case .claude: "C"
        case .codex: "CX"
        case .google: "G"
        case .nous: "N"
        case .openRouter: "OR"
        case .xAI: "𝕏"
        case .mistral: "M"
        case .deepSeek: "DS"
        case .groq: "GQ"
        case .cerebras: "C"
        case .together: "T"
        case .fireworks: "FW"
        case .perplexity: "P"
        case .azure: "A"
        case .bedrock: "AWS"
        case .cohere: "C"
        case .ollama: "O"
        case .lmStudio: "LM"
        case .moonshot: "K"
        case .minimax: "MM"
        case .zAI: "Z"
        case .huggingFace: "HF"
        case .venice: "V"
        case .nvidia: "NV"
        case .githubCopilot: "GH"
        case .custom: "◇"
        }
    }
}

enum AIProviderBrandRegistry {
    static let indexedProviderIDs: Set<String> = Set(aliases.keys)

    static func resolve(id: String, name: String) -> AIProviderBrand {
        let normalizedID = normalize(id)
        if let exact = aliases[normalizedID] { return exact }
        let normalizedName = normalize(name)
        if let exact = aliases[normalizedName] { return exact }
        for (alias, brand) in aliases where normalizedName.contains(alias) {
            return brand
        }
        return .custom
    }

    /// Preserves the host label byte-for-byte when present. Branding is a
    /// fallback concern only; several distinct providers can share one brand.
    static func displayName(id: String, authoritativeName: String?) -> String {
        if let authoritativeName, !authoritativeName.isEmpty {
            return authoritativeName
        }
        let normalizedID = normalize(id)
        return fallbackLabels[normalizedID]
            ?? resolve(id: id, name: "").fallbackDisplayName
            ?? id
    }

    /// Exact ID-keyed fallbacks from the Hermes provider source contract.
    /// They are deliberately not inferred from catalog position.
    private static let fallbackLabels: [String: String] = [
        "githubcopilot": "GitHub Copilot",
        "copilot": "GitHub Copilot",
        "githubcopilotacp": "GitHub Copilot ACP",
        "copilotacp": "GitHub Copilot ACP",
        "copilotadaptive": "Copilot Adaptive",
    ]

    private static let aliases: [String: AIProviderBrand] = [
        "openai": .openAI,
        "openaicodex": .codex,
        "codex": .codex,
        "anthropic": .anthropic,
        "claude": .claude,
        "claudecode": .claude,
        "google": .google,
        "googlegemini": .google,
        "gemini": .google,
        "vertexai": .google,
        "nous": .nous,
        "nousresearch": .nous,
        "openrouter": .openRouter,
        "xai": .xAI,
        "grok": .xAI,
        "mistral": .mistral,
        "deepseek": .deepSeek,
        "groq": .groq,
        "cerebras": .cerebras,
        "together": .together,
        "togetherai": .together,
        "fireworks": .fireworks,
        "fireworksai": .fireworks,
        "perplexity": .perplexity,
        "azure": .azure,
        "azureopenai": .azure,
        "bedrock": .bedrock,
        "amazonbedrock": .bedrock,
        "awsbedrock": .bedrock,
        "cohere": .cohere,
        "ollama": .ollama,
        "lmstudio": .lmStudio,
        "moonshot": .moonshot,
        "moonshotai": .moonshot,
        "kimi": .moonshot,
        "minimax": .minimax,
        "zai": .zAI,
        "zhipu": .zAI,
        "glm": .zAI,
        "huggingface": .huggingFace,
        "venice": .venice,
        "veniceai": .venice,
        "nvidia": .nvidia,
        "nim": .nvidia,
        "githubcopilot": .githubCopilot,
        "copilot": .githubCopilot,
        "githubcopilotacp": .githubCopilot,
        "copilotacp": .githubCopilot,
        "copilotadaptive": .githubCopilot,
    ]

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}
