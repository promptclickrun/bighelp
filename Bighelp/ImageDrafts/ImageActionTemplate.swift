import Foundation

/// The review messages an agent's Photo actions settings can change. Each key takes only its own
/// placeholders (docs/IMAGE_DRAFTS.md › Photo actions settings).
enum ImageActionMessageKey: String, CaseIterable, Codable, Sendable {
    case review
    case missingFields = "missing_fields"
    case saved
    case failed
    case outcomeUnknown = "outcome_unknown"

    var placeholders: Set<String> {
        switch self {
        case .review: ["destination"]
        case .missingFields: ["fields"]
        case .saved: ["destination", "name"]
        case .failed: ["reason"]
        case .outcomeUnknown: []
        }
    }
}

enum ImageActionTemplateError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case notPlainText
    /// A `{{` without its `}}`, a stray `}}`, or something between them that isn't a name.
    case unbalanced
    /// A name this message doesn't take.
    case unknownPlaceholder(String)
}

/// Plain-text messages with `{{name}}` placeholders. The app substitutes once: a value that holds
/// `{{name}}` stays as written, and nothing in a message is read as markup or a link.
enum ImageActionTemplate {
    static let maximumLength = ImageDraftWire.maximumMessageLength
    static let maximumNameLength = 32

    static func validate(_ text: String, for key: ImageActionMessageKey) throws(ImageActionTemplateError) {
        guard ImageDraftText.trimmed(text) != nil else { throw .empty }
        guard ImageDraftText.length(text) <= maximumLength else { throw .tooLong }
        guard ImageDraftText.isPlain(text, oneLine: false) else { throw .notPlainText }
        for name in try placeholders(in: text) where !key.placeholders.contains(name) {
            throw .unknownPlaceholder(name)
        }
    }

    /// The names of the placeholders, in order.
    static func placeholders(in text: String) throws(ImageActionTemplateError) -> [String] {
        try tokens(in: text).compactMap { token in
            if case .placeholder(let name) = token { return name }
            return nil
        }
    }

    /// The message with each placeholder replaced by its value, in one pass. Values lose control
    /// characters (a line break stays); a placeholder without a value is left as written.
    static func render(_ template: String, values: [String: String]) -> String {
        guard let tokens = try? tokens(in: template) else { return template }
        var output = ""
        for token in tokens {
            switch token {
            case .text(let text): output += text
            case .placeholder(let name):
                if let value = values[name] { output += clean(value) } else { output += "{{\(name)}}" }
            }
        }
        return output
    }

    private enum Token: Equatable {
        case text(String)
        case placeholder(String)
    }

    private static func tokens(in text: String) throws(ImageActionTemplateError) -> [Token] {
        var tokens: [Token] = []
        var plain = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if scalar == "}" && next == "}" { throw .unbalanced }
            guard scalar == "{" && next == "{" else {
                plain.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            var cursor = index + 2
            var name = String.UnicodeScalarView()
            while cursor < scalars.count, scalars[cursor] != "}" {
                let value = scalars[cursor].value
                // Lowercase letters and underscores only, so `{{ name }}` or `{{{name}}}` is a mistake.
                guard (97...122).contains(value) || value == 95, name.count < maximumNameLength else { throw .unbalanced }
                name.append(scalars[cursor])
                cursor += 1
            }
            guard !name.isEmpty, cursor + 1 < scalars.count, scalars[cursor + 1] == "}" else { throw .unbalanced }
            if !plain.isEmpty { tokens.append(.text(plain)); plain = "" }
            tokens.append(.placeholder(String(name)))
            index = cursor + 2
        }
        if !plain.isEmpty { tokens.append(.text(plain)) }
        return tokens
    }

    private static func clean(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            ImageDraftText.isControl(scalar) && scalar != "\n" ? " " : scalar
        }))
    }
}
