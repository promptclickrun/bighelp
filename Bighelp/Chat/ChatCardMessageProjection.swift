import Foundation

/// Ordered projection of assistant Markdown. The original message remains the
/// copy/export authority; this projection is presentation-only.
struct ChatCardMessageProjection: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        case markdown(MarkdownDocument)
        case card(BighelpCardEnvelope)
        /// A pipe table, drawn as a grid; the text around it stays selectable text.
        case table(MarkdownTable)
        case rule
        /// A card whose payload is still streaming in (#18): a loader, never its
        /// code, shaped like the kind the partial card already names.
        case pendingCard(ChatPendingCardKind)
        /// A finished message's card that never closed or isn't valid.
        case unavailableCard
    }

    /// Text runs stay one selectable document; tables and rules become their own segments.
    static func segments(for document: MarkdownDocument) -> [Segment] {
        var segments: [Segment] = []
        var run: [MarkdownBlock] = []
        func flush() {
            if !run.isEmpty { segments.append(.markdown(MarkdownDocument(blocks: run))) }
            run.removeAll()
        }
        for block in document.blocks {
            switch block {
            case .table(let table): flush(); segments.append(.table(table))
            case .rule: flush(); segments.append(.rule)
            default: run.append(block)
            }
        }
        flush()
        return segments.isEmpty ? [.markdown(document)] : segments
    }

    static let fenceLanguage = "loopdy-card"
    static let maximumCardBytes = 65_536

    let segments: [Segment]
    let cardIDs: Set<String>

    /// The cards an assistant message names. Most messages have none, and laying each one
    /// out to find out made a long chat parse every message on every redraw.
    static func cardIDs(in source: String) -> Set<String> {
        guard source.contains("```\(fenceLanguage)") else { return [] }
        return ChatCardMessageProjection(source: source, role: .assistant).cardIDs
    }

    /// Cards, tables or rules: the message is drawn part by part at full width.
    var hasRichContent: Bool {
        !cardIDs.isEmpty || segments.contains { if case .markdown = $0 { false } else { true } }
    }

    /// `isStreaming`: the reply is still arriving, so an open card fence (or a
    /// half-typed fence marker at the very end) is a card on its way.
    init(source: String, role: TimelineRole, isStreaming: Bool = false) {
        guard role == .assistant else {
            segments = Self.segments(for: MarkdownDocument(source))
            cardIDs = []
            return
        }

        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        let opening = "```\(Self.fenceLanguage)"
        var cardIsComing = false
        if isStreaming, let last = lines.last {
            let marker = last.trimmingCharacters(in: .whitespaces)
            // "```" alone may open any code block, but it's hidden for the
            // moment it takes to see which one.
            if marker.count >= 3, marker.count < opening.count, opening.hasPrefix(marker) {
                lines.removeLast()
                cardIsComing = marker.count > 3
            }
        }
        var projected: [Segment] = []
        var markdownLines: [String] = []
        var identities = Set<String>()
        var index = 0

        func flushMarkdown() {
            guard !markdownLines.isEmpty else { return }
            let source = markdownLines.joined(separator: "\n")
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                projected.append(contentsOf: Self.segments(for: MarkdownDocument(source)))
            }
            markdownLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.drop(while: { $0 == " " })
            let indentation = line.count - trimmed.count
            guard indentation <= 3, trimmed == opening else {
                markdownLines.append(line)
                index += 1
                // A card shown inside an ordinary code example is not a card
                // instruction. Consume the outer Markdown fence as one block.
                if indentation <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                    let fenceLength = trimmed.prefix(while: { $0 == marker }).count
                    if fenceLength >= 3 {
                        while index < lines.count {
                            let candidate = lines[index]
                            markdownLines.append(candidate)
                            index += 1
                            let closing = candidate.drop(while: { $0 == " " })
                            let count = closing.prefix(while: { $0 == marker }).count
                            if candidate.count - closing.count <= 3, count >= fenceLength,
                               closing.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { break }
                        }
                    }
                }
                continue
            }

            var closingIndex: Int?
            var cursor = index + 1
            while cursor < lines.count {
                if lines[cursor].trimmingCharacters(in: .whitespaces) == "```" {
                    closingIndex = cursor
                    break
                }
                cursor += 1
            }
            guard let closingIndex else {
                flushMarkdown()
                var partial = ""
                for line in lines[(index + 1)...] where partial.utf8.count < 2_048 { partial += line + "\n" }
                projected.append(isStreaming ? .pendingCard(ChatPendingCardKind(partialCard: partial)) : .unavailableCard)
                index = lines.count
                continue
            }

            let body = lines[(index + 1)..<closingIndex].joined(separator: "\n")
            guard let data = body.data(using: .utf8),
                  data.count <= Self.maximumCardBytes,
                  let envelope = try? JSONDecoder().decode(BighelpCardEnvelope.self, from: data),
                  identities.insert(envelope.id).inserted else {
                flushMarkdown()
                projected.append(.unavailableCard)
                index = closingIndex + 1
                continue
            }

            flushMarkdown()
            projected.append(.card(envelope))
            index = closingIndex + 1
        }

        flushMarkdown()
        if cardIsComing { projected.append(.pendingCard(.generic)) }
        segments = projected.isEmpty ? Self.segments(for: MarkdownDocument(lines.joined(separator: "\n"))) : projected
        cardIDs = identities
    }
}
