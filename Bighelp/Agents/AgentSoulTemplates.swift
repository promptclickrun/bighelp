import Foundation

/// A built-in personality for a new agent: a complete SOUL.md (bundled as
/// `Resources/SoulTemplates/soul-<id>.md`). Its text says `{{agent_name}}`
/// wherever the agent's name goes; the studio fills that in.
struct AgentSoulTemplate: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// What it's for; becomes the new agent's role.
    let profile: String
    /// How it sounds; becomes the new agent's About line.
    let voice: String
    /// The hard case it's written to handle well, shown on its card.
    let strength: String
    let systemImage: String
    /// Its topic in the pickers; Other when the catalog names none the app knows.
    var category: TemplateCategory = .other
    /// A catalog template's personality text, carried inline; bundled ones read their file.
    var inlineSoul: String? = nil
    /// Who shared a community template, shown as "by @credit".
    var credit: String? = nil
    var isCommunity = false
    /// When the catalog last changed it; nil for bundled ones.
    var updatedAt: Date? = nil
    /// Fill-in fields for its other `{{key}}`s (services/catalog/docs/TEMPLATE_VARIABLES.md).
    var variables: [TemplateVariable] = []
    /// Its ID on the person's computer, for one of My Templates (`MyTemplatesStore`).
    var savedTemplateID: String? = nil

    /// One of the person's own, saved on their computer.
    var isMine: Bool { savedTemplateID != nil }

    /// The personality text with `{{agent_name}}` still in it.
    var soul: String? {
        if let inlineSoul { return inlineSoul }
        guard let url = Bundle.main.url(forResource: "soul-\(id)", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }

    /// A saved bot's vibe is its About line, which may already end a sentence.
    var about: String {
        guard let last = voice.last, !".!?".contains(last) else { return voice }
        return voice + "."
    }

    /// Its role and strength for a card: each field shows as "[Its label]".
    var cardRole: String { TemplateVariables.preview(profile, variables: variables) }
    var cardStrength: String { TemplateVariables.preview(strength, variables: variables) }

    /// The form to fill before it's used, or nil when the name is all it needs.
    func form(agentName: String, savedUserName: String) -> TemplateForm? {
        TemplateForm(texts: [soul ?? "", profile, strength], declared: variables, agentName: agentName,
                     savedUserName: savedUserName)
    }

    /// The catalog's templates when there are some, otherwise the bundled ones.
    @MainActor static var all: [AgentSoulTemplate] { TemplateCatalogStore.shared.agentTemplates }

    /// Each with the topic the catalog gives it, so the fallback sorts the same way.
    static let bundled: [AgentSoulTemplate] = [
        .init(id: "anchor", title: "Anchor", profile: "Everyday generalist", voice: "Warm, direct, adaptable",
              strength: "Helps with vague requests without turning simple tasks into an interview.",
              systemImage: "sun.max", category: .agent("personal")),
        .init(id: "compass", title: "Compass", profile: "Chief-of-staff partner", voice: "Concise, discreet, decisive",
              strength: "Sorts out conflicting priorities without inventing authority or commitments.",
              systemImage: "safari", category: .agent("productivity")),
        .init(id: "spark", title: "Spark", profile: "Focus companion", voice: "Gentle, concrete, encouraging",
              strength: "Helps you get started, and start again after a gap, without shame.",
              systemImage: "bolt", category: .agent("productivity")),
        .init(id: "lumen", title: "Lumen", profile: "Learning partner", voice: "Patient, curious, accessible",
              strength: "Explains things another way when the first one doesn't land, at any age.",
              systemImage: "lightbulb", category: .agent("education")),
        .init(id: "lens", title: "Lens", profile: "Research partner", voice: "Measured, precise, inquisitive",
              strength: "Resists confirmation bias and says when evidence is missing, not disproved.",
              systemImage: "magnifyingglass", category: .agent("science")),
        .init(id: "forge", title: "Forge", profile: "Engineering partner", voice: "Candid, pragmatic, technical",
              strength: "Keeps a plausible fix, passing checks and a working result apart.",
              systemImage: "hammer", category: .agent("coding")),
        .init(id: "beacon", title: "Beacon", profile: "Incident partner", voice: "Calm, brief, factual",
              strength: "Communicates under pressure without false certainty or early all-clears.",
              systemImage: "light.beacon.max", category: .agent("coding")),
        .init(id: "counterpoint", title: "Counterpoint", profile: "Strategy challenger",
              voice: "Independent, fair, incisive",
              strength: "Challenges big assumptions without becoming reflexively contrarian.",
              systemImage: "arrow.left.arrow.right", category: .agent("leadership")),
        .init(id: "muse", title: "Muse", profile: "Creative collaborator", voice: "Inventive, vivid, playful",
              strength: "Takes a real new direction after a no, and keeps fiction apart from fact.",
              systemImage: "paintpalette", category: .agent("creative")),
        .init(id: "quill", title: "Quill", profile: "Editor and writing partner", voice: "Clear, attentive, restrained",
              strength: "Improves your writing without changing its meaning, voice or promises.",
              systemImage: "pencil.line", category: .agent("creative")),
        .init(id: "bridge", title: "Bridge", profile: "Support and resolution partner",
              voice: "Patient, courteous, firm",
              strength: "Handles anger and demands for guarantees without fake fixes or scripted empathy.",
              systemImage: "bubble.left.and.bubble.right", category: .agent("business")),
        .init(id: "hearth", title: "Hearth", profile: "Household companion", voice: "Warm, practical, considerate",
              strength: "Handles a shared home: different people, preferences and private things.",
              systemImage: "house", category: .agent("personal")),
        .init(id: "harbor", title: "Harbor", profile: "Reflective companion", voice: "Gentle, attentive, grounded",
              strength: "Offers support without encouraging dependence or claiming human feelings.",
              systemImage: "heart", category: .agent("health")),
        .init(id: "waypoint", title: "Waypoint", profile: "Consequential-information guide",
              voice: "Careful, plainspoken, calm",
              strength: "Explains sensitive matters without posing as a professional or promising outcomes.",
              systemImage: "signpost.right", category: .agent("personal")),
        .init(id: "fable", title: "Fable", profile: "Playful storyteller", voice: "Imaginative, lightly theatrical",
              strength: "Stays in character for fun, and drops it the moment you need it plain.",
              systemImage: "book", category: .agent("creative")),
    ]

    @MainActor static func template(_ id: String) -> AgentSoulTemplate? { all.first { $0.id == id } }
}

/// The `{{agent_name}}` placeholder in personality text.
enum AgentNamePlaceholder {
    static let token = "{{agent_name}}"

    /// The text with every placeholder replaced by `name`. An empty name keeps
    /// the placeholder, so it still shows where the name will go.
    static func fill(_ text: String, name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: name)
    }

    /// A saved agent's instructions, with its own name turned back into the
    /// placeholder so a new agent made from it gets its own name. Only whole,
    /// same-case matches of the name are swapped.
    static func generalize(_ text: String, name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2, !text.contains(token) else { return text }
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                   withTemplate: NSRegularExpression.escapedTemplate(for: token))
    }
}
