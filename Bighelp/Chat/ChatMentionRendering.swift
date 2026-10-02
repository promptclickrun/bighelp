import UIKit

@MainActor
enum ChatMentionRendering {
    static func apply(to text: NSMutableAttributedString, identities: [ChatMentionIdentity], traits: UITraitCollection) {
        guard text.string.contains("@") else { return }
        let names = Dictionary(grouping: identities) { MentionParser.normalizedForMatching($0.handle) }
        let tokens = (try? MentionParser.tokens(in: text.string, rejectingInvalid: false)) ?? []
        for token in tokens.reversed() {
            let name: String
            if token.handle == "all" || token.handle == "everyone" {
                name = "All"
            } else if let matches = names[token.handle], matches.count == 1 {
                name = matches[0].name
            } else {
                continue
            }
            var isProse = true
            text.enumerateAttributes(in: token.range) { attributes, _, _ in
                if attributes[.link] != nil || attributes[.backgroundColor] != nil {
                    isProse = false
                }
            }
            guard isProse,
                  let font = text.attribute(.font, at: token.range.location, effectiveRange: nil) as? UIFont,
                  let color = text.attribute(.foregroundColor, at: token.range.location, effectiveRange: nil) as? UIColor
            else { continue }
            let attachment = ChatMentionAttachment(
                originalText: (text.string as NSString).substring(with: token.range),
                displayName: name, font: font, foreground: color.resolvedColor(with: traits))
            let pill = NSMutableAttributedString(attachment: attachment)
            var attributes = text.attributes(at: token.range.location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            pill.addAttributes(attributes, range: NSRange(location: 0, length: pill.length))
            text.replaceCharacters(in: token.range, with: pill)
        }
    }

    static func plainText(_ text: NSAttributedString, usingNames: Bool = false) -> String {
        guard text.string.contains("\u{fffc}") else { return text.string }
        var result = ""
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let mention = value as? ChatMentionAttachment {
                result += usingNames ? mention.displayName : mention.originalText
            } else {
                result += (text.string as NSString).substring(with: range)
            }
        }
        return result
    }

    /// Reuse unchanged pills so an appended answer does not invalidate its prefix.
    static func reuseAttachments(in text: NSMutableAttributedString, from previous: NSAttributedString) {
        guard text.string.contains("\u{fffc}"), previous.string.contains("\u{fffc}") else { return }
        var attachments: [String: [ChatMentionAttachment]] = [:]
        previous.enumerateAttribute(.attachment, in: NSRange(location: 0, length: previous.length)) { value, _, _ in
            guard let mention = value as? ChatMentionAttachment else { return }
            attachments[mention.originalText, default: []].append(mention)
        }
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let mention = value as? ChatMentionAttachment,
                  let existing = attachments[mention.originalText]?.first(where: { $0.matches(mention) }) else { return }
            text.addAttribute(.attachment, value: existing, range: range)
        }
    }
}
