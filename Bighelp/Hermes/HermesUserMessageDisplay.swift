import Foundation

/// Hermes saves a user turn the way it reached the model: a photo adds an
/// `[Image attached at: <path>]` hint, image parts flatten to `[screenshot]`,
/// and memory plugins append a fenced `<memory-context>` block of recalled
/// notes (which can name older photos). A chat shows what the person sent:
/// their words, plus a stock `@image:` reference that the media resolver turns
/// back into their own photo.
enum HermesUserMessageDisplay {
    /// The caption Hermes substitutes when a photo is sent without text.
    static let defaultImageCaption = "What do you see in this image?"

    static func text(_ raw: String) -> String {
        guard raw.contains("memory-context") || raw.contains("[Image attached")
                || raw.contains("[System note:") else { return raw }
        var text = raw
            .replacing(/(?is)<\s*memory-context\s*>.*?<\s*\/\s*memory-context\s*>/, with: "")
        // A truncated row can lose its closing fence; nothing after it is the person's.
        if let open = text.firstRange(of: /(?i)<\s*memory-context\s*>/) {
            text = String(text[..<open.lowerBound])
        }
        text = text
            .replacing(/(?i)\[System note:\s*The following is recalled memory context,[^\]]*\]/, with: "")
            .replacing(/(?i)<\s*\/\s*memory-context\s*>/, with: "")

        var images: [String] = []
        var sawImage = false
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.wholeMatch(of: /\[Image attached at: (.+)\]/) {
                sawImage = true
                if let reference = reference(String(match.1)) { images.append("@image:" + reference) }
            } else if trimmed.wholeMatch(of: /\[Image attached: .+\]/) != nil {
                sawImage = true
            } else {
                lines.append(line)
            }
        }
        if sawImage {
            lines.removeAll { ["[screenshot]", "[image]"].contains($0.trimmingCharacters(in: .whitespaces)) }
        }
        var body = lines.joined(separator: "\n")
            .replacing(/\n{3,}/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sawImage, body == defaultImageCaption { body = "" }
        return ([body].filter { !$0.isEmpty } + images).joined(separator: "\n")
    }

    /// One-line chat list preview: attachment references read as "Photo" or
    /// "Attachment" instead of host paths, and a reply shows its own words.
    static func preview(_ raw: String, attachments: [ChatAttachment] = []) -> String {
        var photos = attachments.contains { $0.kind == .image }
        var files = !attachments.isEmpty
        let shown = text(raw)
        let words = (ChatReplyQuote.split(shown)?.body ?? shown).components(separatedBy: "\n").filter { line in
            if line.hasPrefix("@image:") { photos = true; return false }
            if line.hasPrefix("@file:") { files = true; return false }
            return true
        }
        let body = words.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        return photos ? "Photo" : files ? "Attachment" : ""
    }

    /// A whole-line `@image:` value; paths with spaces or brackets are quoted.
    private static func reference(_ path: String) -> String? {
        guard !path.contains(where: { $0.isWhitespace || "[]\"'`".contains($0) }) else {
            guard let quote = ["\"", "'", "`"].first(where: { !path.contains($0) }),
                  !path.contains(where: \.isNewline) else { return nil }
            return quote + path + quote
        }
        return path
    }
}
