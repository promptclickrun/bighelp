import CryptoKit
import Foundation

/// Agents' HTML apps (docs/HTML_APPS.md, plugin feature `native-html-apps-v1`): an agent makes an
/// interactive page with `bighelp_show_app`, the chat shows a native card for it, and Open App
/// shows the page full screen. The chat never draws the HTML itself.
enum HTMLAppWire {
    static let feature = "native-html-apps-v1"
    static let type = "html_app"
    /// What the speaker note adds to `renders` when the plugin lists the feature.
    static let renders = [type]
    static let maximumHTMLBytes = 16_777_216
    static let maximumDescriptionLength = 240
    static let maximumTitleLength = 60
}

/// A card's one `html_app` element: which app, what it says, and what it can do. The validator and
/// the card read it through the same initializer, so a card that validates always opens.
struct HTMLAppCard: Equatable, Sendable {
    let appID: String
    let title: String
    let description: String
    let sendsAnswers: Bool
    let isLive: Bool

    init(appID: String, title: String, description: String, sendsAnswers: Bool, isLive: Bool) {
        self.appID = appID
        self.title = title
        self.description = description
        self.sendsAnswers = sendsAnswers
        self.isLive = isLive
    }

    init(props: [String: BighelpJSONValue], title: String) throws {
        let keys: Set<String> = ["app_id", "description", "sends_answers", "live"]
        guard Set(props.keys) == keys,
              let appID = props["app_id"]?.string, Self.isAppID(appID),
              case .string(let description)? = props["description"],
              // Counted as the plugin counts them (Unicode scalars, Python's `len`).
              description.unicodeScalars.count <= HTMLAppWire.maximumDescriptionLength,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .boolean(let sendsAnswers)? = props["sends_answers"],
              case .boolean(let isLive)? = props["live"] else { throw BighelpCardValidationError.invalid }
        self.init(appID: appID, title: title, description: description, sendsAnswers: sendsAnswers, isLive: isLive)
    }

    /// `a_` and 32 lowercase hex digits, as the plugin makes them.
    static func isAppID(_ value: String) -> Bool {
        let digits = value.utf8.dropFirst(2)
        return value.hasPrefix("a_") && digits.count == 32
            && digits.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func app(in card: BighelpCardDocument) -> HTMLAppCard? {
        guard let elements = card.document["elements"]?.object else { return nil }
        for element in elements.values {
            guard let object = element.object, object["type"]?.string == HTMLAppWire.type,
                  let props = object["props"]?.object else { continue }
            return try? HTMLAppCard(props: props, title: card.title)
        }
        return nil
    }

    /// The validator's composition rule: an app is its card's only element.
    static func validateComposition(_ elements: [String: BighelpJSONValue]) throws {
        let apps = elements.values.filter { $0.object?["type"]?.string == HTMLAppWire.type }.count
        guard apps == 0 || elements.count == 1 else { throw BighelpCardValidationError.invalid }
    }
}

enum HTMLAppAnswerError: Error, Equatable {
    /// Not text, or not names with text, numbers, yes or no, or lists.
    case invalid
    case tooLong
}

/// What an app's `bighelp.sendAnswer` gives: text, or named values in the page's order (the page
/// sends an object as its entries, `[[name, value], …]`). It goes to the agent as the person's next
/// message, in plain words, the same as a form's answer (`CardReplyText`).
struct HTMLAppAnswer: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case text(String)
        case fields([CardReplyText.Answer])
    }

    static let maximumFields = 40
    static let maximumNameLength = 80
    /// Room left in a card reply for the heading and the app's title.
    private static let headingAllowance = 256

    let content: Content

    @MainActor
    init(json: String) throws(HTMLAppAnswerError) {
        guard let value = try? JSONDecoder().decode(BighelpJSONValue.self, from: Data(json.utf8)) else {
            throw .invalid
        }
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw .invalid }
            content = .text(trimmed)
        case .array(let entries):
            guard (1...Self.maximumFields).contains(entries.count) else { throw .invalid }
            content = .fields(try entries.map { entry throws(HTMLAppAnswerError) in
                guard case .array(let pair) = entry, pair.count == 2, let rawName = pair[0].string else { throw .invalid }
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.unicodeScalars.count <= Self.maximumNameLength else { throw .invalid }
                return CardReplyText.Answer(label: name, text: try Self.words(pair[1]))
            })
        default:
            throw .invalid
        }
        guard message(title: "").utf8.count + Self.headingAllowance <= ChatOutgoingMessage.maximumCardReplyBytes else {
            throw .tooLong
        }
    }

    func message(title: String) -> String {
        switch content {
        case .text(let text): "My answer from “\(title)”:\n\(text)"
        case .fields(let answers): CardReplyText.form(title: title, answers: answers)
        }
    }

    private static func words(_ value: BighelpJSONValue) throws(HTMLAppAnswerError) -> String {
        switch value {
        case .string(let text): return text
        case .boolean(let on): return on ? "Yes" : "No"
        case .integer, .number: return number(value) ?? ""
        case .array(let items):
            return try items.map { item throws(HTMLAppAnswerError) in
                switch item {
                case .string(let text): return text
                case .integer, .number: return number(item) ?? ""
                default: throw .invalid
                }
            }.joined(separator: ", ")
        default:
            throw .invalid
        }
    }

    /// Whole numbers without a decimal point; others as Swift writes them, the same on every phone.
    private static func number(_ value: BighelpJSONValue) -> String? {
        switch value {
        case .integer(let number): return String(number)
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
            return String(number)
        default: return nil
        }
    }
}

enum HTMLAppHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
