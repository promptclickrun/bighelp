import Foundation

/// One kind of picture's settings as the person sees them: every value filled in.
struct ImageActionsEffectivePreset: Equatable, Sendable {
    var offer: Bool
    var instructions: String
    var question: String
    var messages: ImageDraftMessages
}

/// What a value is when the person hasn't changed it. The plugin sends its own with the settings;
/// the built-in copy is the contract's table, for the demo and for a reply without them.
struct ImageActionsDefaults: Equatable, Sendable {
    var presets: [ImageDraftPreset: ImageActionsEffectivePreset]

    subscript(preset: ImageDraftPreset) -> ImageActionsEffectivePreset {
        presets[preset] ?? Self.standard.presets[preset]!
    }

    static let standard = ImageActionsDefaults(presets: [
        .businessCard: ImageActionsEffectivePreset(
            offer: true,
            instructions: "Read the contact details printed on the card. Leave a field out when it isn't on the card.",
            question: "Do you want a contact from this card?",
            messages: ImageDraftMessages(
                review: "Check the details before saving to {{destination}}.",
                missingFields: "Please check: {{fields}}.",
                saved: "Saved {{name}} to {{destination}}.",
                failed: "That didn't save. {{reason}}",
                outcomeUnknown: "It's not clear the contact saved. Check Contacts before you try again.")),
        .eventPoster: ImageActionsEffectivePreset(
            offer: true,
            instructions: "Read the event's title, date, time and place. Don't guess a missing year, time zone or end time.",
            question: "Do you want this event in your calendar?",
            messages: ImageDraftMessages(
                review: "Check the date and time before adding it to {{destination}}.",
                missingFields: "Please check: {{fields}}.",
                saved: "Added {{name}} to {{destination}}.",
                failed: "That didn't save. {{reason}}",
                outcomeUnknown: "It's not clear the event saved. Check Calendar before you try again.")),
    ])

    /// The plugin's `defaults`, read leniently: a value that doesn't read keeps the built-in one.
    /// Takes `{business_card: …}` or `{presets: {business_card: …}}`.
    static func lenient(_ value: BighelpJSONValue?) -> ImageActionsDefaults {
        let root = value?.object?["presets"]?.object ?? value?.object ?? [:]
        var result = standard
        for preset in ImageDraftPreset.allCases {
            guard let object = root[preset.rawValue]?.object else { continue }
            var filled = standard[preset]
            if let offer = object["offer"]?.boolean { filled.offer = offer }
            if let text = object["instructions"]?.string,
               (try? ImageActionsSettings.checkInstructions(text)) != nil { filled.instructions = text }
            if let text = object["question"]?.string,
               (try? ImageActionsSettings.checkQuestion(text)) != nil { filled.question = text }
            let messages = object["messages"]?.object ?? [:]
            for key in ImageActionMessageKey.allCases {
                guard let text = messages[key.rawValue]?.string,
                      (try? ImageActionTemplate.validate(text, for: key)) != nil else { continue }
                filled.messages.set(text, for: key)
            }
            result.presets[preset] = filled
        }
        return result
    }
}

extension ImageDraftMessages {
    mutating func set(_ text: String, for key: ImageActionMessageKey) {
        switch key {
        case .review: review = text
        case .missingFields: missingFields = text
        case .saved: saved = text
        case .failed: failed = text
        case .outcomeUnknown: outcomeUnknown = text
        }
    }
}

/// An agent's own changes for one kind of picture. Nil is the default.
struct ImageActionsPresetOverrides: Equatable, Sendable {
    var offer: Bool?
    var instructions: String?
    var question: String?
    var messages: [ImageActionMessageKey: String] = [:]

    init(offer: Bool? = nil, instructions: String? = nil, question: String? = nil,
         messages: [ImageActionMessageKey: String] = [:]) {
        self.offer = offer
        self.instructions = instructions
        self.question = question
        self.messages = messages
    }

    var isEmpty: Bool { offer == nil && instructions == nil && question == nil && messages.isEmpty }
}

enum ImageActionsSettingsError: Error, Equatable, Sendable {
    /// Not the document's shape: unknown keys, wrong types, another schema version.
    case invalid
    /// More than 16 KiB.
    case tooLarge
    case instructions(ImageDraftPreset, ImageActionTemplateError)
    case question(ImageDraftPreset, ImageActionTemplateError)
    case message(ImageDraftPreset, ImageActionMessageKey, ImageActionTemplateError)
}

/// Photo actions settings for one agent (docs/IMAGE_DRAFTS.md › Photo actions settings), checked
/// the way the plugin checks them, so Save is refused here before the computer refuses it.
struct ImageActionsSettings: Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumBytes = 16 * 1_024
    static let maximumInstructions = 4_000
    static let maximumQuestion = ImageDraftWire.maximumMessageLength

    var revision: Int
    var presets: [ImageDraftPreset: ImageActionsPresetOverrides]

    init(revision: Int = 0, presets: [ImageDraftPreset: ImageActionsPresetOverrides] = [:]) {
        self.revision = revision
        self.presets = presets
    }

    subscript(preset: ImageDraftPreset) -> ImageActionsPresetOverrides {
        get { presets[preset] ?? ImageActionsPresetOverrides() }
        set { presets[preset] = newValue.isEmpty ? nil : newValue }
    }

    /// Strict: the shape the plugin keeps, every value checked.
    init(json value: BighelpJSONValue) throws(ImageActionsSettingsError) {
        guard let root = value.object, Set(root.keys).isSubset(of: ["schemaVersion", "revision", "presets"]),
              root["schemaVersion"]?.integer == Self.schemaVersion,
              let revision = root["revision"]?.integer, revision >= 0 else { throw .invalid }
        var presets: [ImageDraftPreset: ImageActionsPresetOverrides] = [:]
        switch root["presets"] {
        case nil, .null?: break
        case .object(let object)?:
            for (name, item) in object {
                guard let preset = ImageDraftPreset(rawValue: name) else { throw .invalid }
                let overrides = try Self.overrides(item, preset: preset)
                if !overrides.isEmpty { presets[preset] = overrides }
            }
        default: throw .invalid
        }
        self.init(revision: revision, presets: presets)
        try validate()
    }

    private static func overrides(_ value: BighelpJSONValue, preset: ImageDraftPreset) throws(ImageActionsSettingsError)
        -> ImageActionsPresetOverrides {
        if value == .null { return ImageActionsPresetOverrides() }
        guard let object = value.object,
              Set(object.keys).isSubset(of: ["offer", "instructions", "question", "messages"]) else { throw .invalid }
        var result = ImageActionsPresetOverrides()
        switch object["offer"] {
        case nil, .null?: break
        case .boolean(let on)?: result.offer = on
        default: throw .invalid
        }
        func text(_ key: String) throws(ImageActionsSettingsError) -> String? {
            switch object[key] {
            case nil, .null?: return nil
            case .string(let text)?: return text
            default: throw .invalid
            }
        }
        result.instructions = try text("instructions")
        result.question = try text("question")
        switch object["messages"] {
        case nil, .null?: break
        case .object(let messages)?:
            for (name, item) in messages {
                guard let key = ImageActionMessageKey(rawValue: name) else { throw .invalid }
                switch item {
                case .null: continue
                case .string(let text): result.messages[key] = text
                default: throw .invalid
                }
            }
        default: throw .invalid
        }
        return result
    }

    /// Lenient, for a reply: whatever doesn't read is left at its default. A reply with no revision is revision 0.
    static func lenient(_ value: BighelpJSONValue?) -> ImageActionsSettings {
        if let value, let strict = try? ImageActionsSettings(json: value) { return strict }
        let root = value?.object ?? [:]
        var settings = ImageActionsSettings(revision: max(0, root["revision"]?.integer ?? 0))
        let presets = root["presets"]?.object ?? [:]
        for preset in ImageDraftPreset.allCases {
            guard let object = presets[preset.rawValue]?.object else { continue }
            var overrides = ImageActionsPresetOverrides()
            overrides.offer = object["offer"]?.boolean
            if let text = object["instructions"]?.string, (try? checkInstructions(text)) != nil { overrides.instructions = text }
            if let text = object["question"]?.string, (try? checkQuestion(text)) != nil { overrides.question = text }
            for key in ImageActionMessageKey.allCases {
                if let text = object["messages"]?.object?[key.rawValue]?.string,
                   (try? ImageActionTemplate.validate(text, for: key)) != nil { overrides.messages[key] = text }
            }
            settings[preset] = overrides
        }
        return settings
    }

    func validate() throws(ImageActionsSettingsError) {
        for (preset, overrides) in presets {
            if let text = overrides.instructions {
                do throws(ImageActionTemplateError) { try Self.checkInstructions(text) } catch { throw .instructions(preset, error) }
            }
            if let text = overrides.question {
                do throws(ImageActionTemplateError) { try Self.checkQuestion(text) } catch { throw .question(preset, error) }
            }
            for (key, text) in overrides.messages {
                do throws(ImageActionTemplateError) { try ImageActionTemplate.validate(text, for: key) } catch { throw .message(preset, key, error) }
            }
        }
        guard let data = try? JSONEncoder.imageDraftsCanonical.encode(json), data.count <= Self.maximumBytes else {
            throw .tooLarge
        }
    }

    /// Plain text up to 4,000 characters; spaces only is refused. No placeholders here.
    static func checkInstructions(_ text: String) throws(ImageActionTemplateError) {
        guard ImageDraftText.trimmed(text) != nil else { throw .empty }
        guard ImageDraftText.length(text) <= maximumInstructions else { throw .tooLong }
        guard ImageDraftText.isPlain(text, oneLine: false) else { throw .notPlainText }
    }

    /// 1–500 characters of plain text; spaces only is refused.
    static func checkQuestion(_ text: String) throws(ImageActionTemplateError) {
        guard ImageDraftText.trimmed(text) != nil else { throw .empty }
        guard ImageDraftText.length(text) <= maximumQuestion else { throw .tooLong }
        guard ImageDraftText.isPlain(text, oneLine: false) else { throw .notPlainText }
    }

    /// The document `image-actions/save` sends. Defaults are left out (absent means default).
    var json: BighelpJSONValue {
        var presets: [String: BighelpJSONValue] = [:]
        for (preset, overrides) in self.presets where !overrides.isEmpty {
            var object: [String: BighelpJSONValue] = [:]
            if let offer = overrides.offer { object["offer"] = .boolean(offer) }
            if let text = overrides.instructions { object["instructions"] = .string(text) }
            if let text = overrides.question { object["question"] = .string(text) }
            if !overrides.messages.isEmpty {
                object["messages"] = .object(Dictionary(uniqueKeysWithValues: overrides.messages.map { ($0.key.rawValue, .string($0.value)) }))
            }
            presets[preset.rawValue] = .object(object)
        }
        return .object(["schemaVersion": .integer(Self.schemaVersion), "revision": .integer(revision),
                        "presets": .object(presets)])
    }

    func effective(_ preset: ImageDraftPreset, defaults: ImageActionsDefaults = .standard) -> ImageActionsEffectivePreset {
        var result = defaults[preset]
        let overrides = self[preset]
        if let offer = overrides.offer { result.offer = offer }
        if let text = overrides.instructions { result.instructions = text }
        if let text = overrides.question { result.question = text }
        for (key, text) in overrides.messages { result.messages.set(text, for: key) }
        return result
    }

    /// Sets a value, keeping it only when it differs from the default, so an unchanged field stays "default".
    mutating func set(instructions text: String, for preset: ImageDraftPreset, defaults: ImageActionsDefaults = .standard) {
        self[preset].instructions = text == defaults[preset].instructions ? nil : text
    }

    mutating func set(question text: String, for preset: ImageDraftPreset, defaults: ImageActionsDefaults = .standard) {
        self[preset].question = text == defaults[preset].question ? nil : text
    }

    mutating func set(message text: String, _ key: ImageActionMessageKey, for preset: ImageDraftPreset,
                      defaults: ImageActionsDefaults = .standard) {
        self[preset].messages[key] = text == defaults[preset].messages[key] ? nil : text
    }

    mutating func set(offer: Bool, for preset: ImageDraftPreset, defaults: ImageActionsDefaults = .standard) {
        self[preset].offer = offer == defaults[preset].offer ? nil : offer
    }

    /// Back to the defaults for one kind of picture.
    mutating func reset(_ preset: ImageDraftPreset) {
        presets[preset] = nil
    }

    mutating func resetAll() {
        presets = [:]
    }
}

extension JSONEncoder {
    /// Sorted keys, no escaped slashes: the one byte form the app hashes and measures.
    static var imageDraftsCanonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
