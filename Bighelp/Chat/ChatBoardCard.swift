import Foundation

/// An idea, Feed post or goal attached to a message: Let's do it sends "Let's do it!" with the
/// idea, and Discuss puts the post or goal in the message box above what the person types.
///
/// Like a reply (`ChatReplyQuote`), it travels in the message's own text, so the agent reads
/// all of it and a reloaded chat still draws the card:
///
///     [Idea (Home): "Start a Sunday meal plan"]
///     Each Sunday I draft five dinners…
///     [End of idea]
///
///     Let's do it!
///
/// The block comes first, then a blank line, then the person's words.
struct ChatBoardCard: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case idea = "Idea"
        case feedPost = "Feed post"
        case goal = "Goal"

        var closer: String { "[End of \(rawValue.lowercased())]" }

        var systemImage: String {
            switch self {
            case .idea: "lightbulb"
            case .feedPost: "dot.radiowaves.up.forward"
            case .goal: "target"
            }
        }
    }

    static let maximumTitleLength = 200
    static let maximumDetailLength = 60
    /// The whole message still goes as one card reply (`ChatOutgoingMessage.maximumCardReplyBytes`).
    static let maximumBodyBytes = 6_000

    let kind: Kind
    /// One line.
    let title: String
    /// Where it's filed: an idea's section, a goal's category. One line, may be empty.
    let detail: String
    /// The item's own text, as written.
    let body: String

    init(kind: Kind, title: String, detail: String = "", body: String) {
        self.kind = kind
        self.title = Self.line(title, limit: Self.maximumTitleLength)
        self.detail = Self.line(detail.filter { !"[]():\"".contains($0) }, limit: Self.maximumDetailLength)
        self.body = Self.bounded(body.trimmingCharacters(in: .whitespacesAndNewlines)
            // The body can't end the block early.
            .replacingOccurrences(of: kind.closer, with: "(End of \(kind.rawValue.lowercased()))"))
    }

    /// The block the agent reads.
    var block: String {
        let label = detail.isEmpty ? kind.rawValue : "\(kind.rawValue) (\(detail))"
        let opener = "[\(label): \"\(title)\"]"
        return body.isEmpty ? opener + "\n" + kind.closer : opener + "\n" + body + "\n" + kind.closer
    }

    /// The text sent: the block, a blank line, then the message.
    func prefixing(_ message: String) -> String {
        message.isEmpty ? block : block + "\n\n" + message
    }

    /// Reads a card back from a message's text. Nil when the text doesn't start with one.
    static func split(_ text: String) -> (card: ChatBoardCard, body: String)? {
        let source = text.drop(while: \.isNewline)
        guard source.first == "[" else { return nil }
        let lineEnd = source.firstIndex(where: \.isNewline) ?? source.endIndex
        let line = source[..<lineEnd]
        guard line.count <= maximumTitleLength + maximumDetailLength + 32, line.hasSuffix("\"]"),
              let separator = line.range(of: ": \"") else { return nil }
        let label = line[line.index(after: line.startIndex)..<separator.lowerBound]
        guard let kind = Kind.allCases.first(where: { label == $0.rawValue || label.hasPrefix($0.rawValue + " (") })
        else { return nil }
        var detail = ""
        if label != kind.rawValue {
            guard label.hasSuffix(")") else { return nil }
            detail = String(label.dropFirst(kind.rawValue.count + 2).dropLast())
        }
        let title = String(line[separator.upperBound...].dropLast(2))
        guard !title.isEmpty else { return nil }
        let rest = source[lineEnd...].dropFirst()
        guard let close = rest.range(of: kind.closer) else { return nil }
        let before = rest[..<close.lowerBound]
        // The closer is a line of its own.
        guard before.isEmpty || before.last?.isNewline == true else { return nil }
        let body = String(before.dropLast(before.isEmpty ? 0 : 1))
        var message = rest[close.upperBound...]
        guard message.isEmpty || message.first?.isNewline == true else { return nil }
        for _ in 0..<2 where message.first?.isNewline == true { message = message.dropFirst() }
        return (ChatBoardCard(kind: kind, title: title, detail: detail, body: body), String(message))
    }

    private static func line(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func bounded(_ text: String) -> String {
        guard text.utf8.count > maximumBodyBytes else { return text }
        var kept = Substring(text)
        while kept.utf8.count > maximumBodyBytes - 3 { kept = kept.dropLast(max(1, (kept.utf8.count - maximumBodyBytes) / 4)) }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

extension AgentBoardItem {
    /// This item as a card on a message.
    var chatCard: ChatBoardCard {
        switch kind {
        case .idea:
            ChatBoardCard(kind: .idea, title: title, detail: section, body: body)
        case .feed:
            ChatBoardCard(kind: .feedPost, title: title, detail: source, body: body)
        case .goal:
            ChatBoardCard(kind: .goal, title: title,
                          detail: goalCategory.map { $0 == .other ? "" : $0.groupTitle } ?? "",
                          body: [body, note.isEmpty ? "" : "Latest: \(note)"].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
    }
}
