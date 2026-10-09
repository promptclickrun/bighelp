import Foundation

/// Preserve newer host modes instead of displaying an unknown value as Off.
struct FastMode: Equatable, Sendable {
    let value: String

    init(_ value: String) {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "off", "normal": self.value = "normal"
        case "on", "fast", "priority": self.value = "fast"
        default: self.value = value
        }
    }

    static let off = FastMode("normal")
    static let on = FastMode("fast")

    var title: String {
        switch value {
        case "normal": "Off"
        case "fast": "On"
        case "auto": "Auto (set on host)"
        case "cold": "Cold (set on host)"
        default: "Set on host"
        }
    }

    /// The host catalog describes the model, not the provider route. Aggregators
    /// and custom endpoints must not inherit a first-party model's speed flag.
    static func unavailableReason(provider: BighelpLinkModelProvider?, model: String) -> String? {
        guard let provider else { return "Choose a model to check Fast Mode support." }
        let firstParty: Bool
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? model
        switch provider.id {
        case "openai", "openai-codex": firstParty = name.hasPrefix("gpt-") && !name.contains("codex")
        case "anthropic": firstParty = name.hasPrefix("claude-")
        case "xai": firstParty = name.hasPrefix("grok-")
        default: firstParty = false
        }
        guard !provider.isCustom, firstParty else {
            return "Fast Mode is not supported by this model and provider."
        }
        guard let models = provider.fastModeModels else {
            return "Update Hermes to check Fast Mode support for this model."
        }
        return models.contains(model) ? nil : "Fast Mode is not supported by this model and provider."
    }
}

struct SessionFastMode: Equatable, Sendable {
    let mode: FastMode?
    let unavailableReason: String?

    var title: String { unavailableReason == nil ? (mode?.title ?? "Unknown") : "Unavailable" }
}

@MainActor
protocol SessionFastModeControlling {
    func loadFastMode(sessionID: String, agentID: String) async throws -> SessionFastMode
    func setFastMode(_ mode: FastMode, sessionID: String, agentID: String) async throws -> SessionFastMode
}
