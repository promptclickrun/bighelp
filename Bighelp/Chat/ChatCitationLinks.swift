import Foundation

/// Presentation-only links. The message remains the authority for copying, sharing and previews.
enum ChatCitationLinks {
    private static let definition = try! NSRegularExpression(
        pattern: #"^ {0,3}(?:[-*+] )?\[([1-9][0-9]{0,5})\]:?[\t ]+(.+)$"#)
    private static let marker = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_\\])\[([1-9][0-9]{0,5})\]"#)

    static func resolve(in source: String) -> [Int: URL] {
        guard source.utf8.contains(91) else { return [:] }
        var links: [Int: URL] = [:]
        var ambiguous: Set<Int> = []
        var fence: (character: Character, count: Int)?
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix(while: { $0 == character }).count
                if let open = fence {
                    if open.character == character, count >= open.count,
                       trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                } else if count >= 3 {
                    fence = (character, count)
                }
                continue
            }
            guard fence == nil,
                  let match = definition.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let number = Int((line as NSString).substring(with: match.range(at: 1))) else { continue }
            let remainder = (line as NSString).substring(with: match.range(at: 2))
            let text = ChatInlineMarkdown.attributedText(remainder)
            let urls = Set(text.runs.compactMap { run -> URL? in
                guard run.inlinePresentationIntent?.contains(.code) != true else { return nil }
                return run.link
            })
            guard urls.count == 1, let url = urls.first,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false,
                  url.user == nil, url.password == nil else {
                ambiguous.insert(number)
                continue
            }
            if let previous = links[number], previous != url { ambiguous.insert(number) }
            links[number] = url
        }
        for number in ambiguous { links.removeValue(forKey: number) }
        return links
    }

    static func applying(to source: AttributedString, links: [Int: URL]) -> AttributedString {
        guard !links.isEmpty else { return source }
        let visible = String(source.characters)
        guard visible.utf8.contains(91) else { return source }
        var result = source
        for match in marker.matches(in: visible, range: NSRange(visible.startIndex..., in: visible)) {
            guard let number = Int((visible as NSString).substring(with: match.range(at: 1))),
                  let url = links[number], let range = Range(match.range, in: visible),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            let runs = result[lower..<upper].runs
            guard !runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) else {
                continue
            }
            // Leave reference labels alone; their URLs already use the normal link renderer.
            let line = (visible as NSString).lineRange(for: match.range)
            let prefix = (visible as NSString).substring(with: NSRange(location: line.location,
                length: match.range.location - line.location)).trimmingCharacters(in: .whitespaces)
            let suffix = visible[range.upperBound...]
            if prefix.isEmpty, suffix.first == ":" || suffix.first == " " || suffix.first == "\t" { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}
