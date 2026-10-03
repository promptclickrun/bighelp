import Foundation

/// A reply to an earlier message in the chat.
///
/// Hermes' `prompt.submit` has no reply field, so the reply travels the way
/// Hermes itself hands replies from Telegram, Discord or Signal to the model:
/// a quote line before the message, `[Replying to your previous message: "…"]`.
/// The line is the message's own text, so it is in the host's saved history
/// and a reloaded chat still draws the message as a reply. The quote is one
/// line and bounded, so the line can always be read back.
struct ChatReplyQuote: Equatable, Sendable {
    enum Author: Equatable, Sendable {
        /// The agent this one-to-one chat talks to: Hermes' "your previous message".
        case agent
        /// The person sending the reply.
        case me
        /// Someone else in a group chat: another agent or person.
        case named(String)
        /// Hermes' own form, `[Replying to: "…"]`, from other platforms' chats.
        case unnamed
    }

    /// The quote is a reminder of which message, not a copy of it.
    static let maximumSnippetLength = 500
    static let maximumNameLength = 40

    let author: Author
    /// One line, at most `maximumSnippetLength` characters plus an ellipsis.
    let snippet: String

    /// Quotes `text`: one line, bounded, without a quote it carried itself, and
    /// with `@` handles disarmed so a group chat doesn't route on quoted words.
    init(author: Author, quoting text: String) {
        self.author = Self.sanitized(author)
        let body = Self.split(text)?.body ?? text
        var line = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if line.count > Self.maximumSnippetLength {
            line = String(line.prefix(Self.maximumSnippetLength))
                .trimmingCharacters(in: .whitespaces) + "…"
        }
        if line.isEmpty { line = "…" }
        snippet = line.replacingOccurrences(of: "@", with: Self.quotedAt)
    }

    /// Quotes a message in this chat. In a group every agent is named; in a
    /// one-to-one chat the agent's own messages are "your previous message".
    @MainActor
    init(replyingTo item: TimelineItem, senderName: String, isGroup: Bool) {
        let author: Author = switch (item.role, item.sender.kind) {
        case (.human, .user) where item.sender.id == UserIdentity.stableID: .me
        case (.assistant, .agent) where !isGroup: .agent
        default: .named(senderName)
        }
        self.init(author: author, quoting: Self.quotedText(of: item))
    }

    /// What a message says, as words: no Markdown marks, file lines or card code.
    @MainActor
    static func quotedText(of item: TimelineItem) -> String {
        let words: String
        switch item.content {
        case .message(let text) where item.role == .human:
            words = HermesUserMessageDisplay.preview(split(text)?.body ?? text, attachments: item.attachments)
        case .message(let text):
            let prose = ReferenceCodec.decode(
                DirectHermesGeneratedMediaClient.pendingFiles(text, role: item.role).text).prose
            words = ChatCardMessageProjection(source: prose, role: .assistant).segments.map { segment in
                switch segment {
                case .markdown(let document): document.visiblePlainText
                case .card(let card): card.title
                case .table(let table): MarkdownDocument(blocks: [.table(table)]).visiblePlainText
                case .rule, .pendingCard, .unavailableCard: ""
                }
            }.filter { !$0.isEmpty }.joined(separator: " ")
        case .budgetSummary: words = "Budget and plan"
        case .weatherAndTasks: words = "Weather and priority tasks"
        case .approvalRequest: words = "Approval request"
        case .generativeUI(let card): words = card.title
        case .bighelpCard(let card): words = card.title
        }
        guard words.allSatisfy(\.isWhitespace) else { return words }
        return item.attachments.contains { $0.kind == .image } ? "Photo"
            : item.attachments.isEmpty ? "" : "Attachment"
    }

    private init(decodedAuthor author: Author, snippet: String) {
        self.author = author
        self.snippet = snippet
    }

    /// The line the model reads.
    var header: String {
        "[Replying to\(Self.whoText(author)): \"\(snippet)\"]"
    }

    /// The text sent for a reply: the quote line, a blank line, then the message.
    func prefixing(_ body: String) -> String {
        body.isEmpty ? header : header + "\n\n" + body
    }

    /// Reads a reply back from a message's text. Nil when the text isn't one.
    static func split(_ text: String) -> (quote: ChatReplyQuote, body: String)? {
        let source = text.drop(while: \.isNewline)
        guard source.hasPrefix(opener) else { return nil }
        let lineEnd = source.firstIndex(where: \.isNewline) ?? source.endIndex
        let line = source[..<lineEnd]
        guard line.count <= maximumLineLength, line.hasSuffix(closer) else { return nil }
        let inner = line.dropFirst(opener.count).dropLast(closer.count)
        guard let separator = inner.range(of: ": \"") else { return nil }
        let who = String(inner[..<separator.lowerBound])
        let snippet = String(inner[separator.upperBound...])
        guard !snippet.isEmpty, snippet.count <= maximumSnippetLength + 1 else { return nil }
        let author: Author
        switch who {
        case "": author = .unnamed
        case " " + agentPhrase: author = .agent
        case " " + mePhrase: author = .me
        default:
            guard who.hasPrefix(" ") else { return nil }
            let name = String(who.dropFirst())
            guard !name.isEmpty, name.count <= maximumNameLength,
                  sanitizedName(name) == name else { return nil }
            author = .named(name)
        }
        var body = source[lineEnd...]
        // The blank line between the quote and the message.
        for _ in 0..<2 where body.first?.isNewline == true { body = body.dropFirst() }
        return (ChatReplyQuote(decodedAuthor: author, snippet: snippet), String(body))
    }

    /// "Replying to Avery", "Replying to yourself".
    func title(agentName: String) -> String {
        switch author {
        case .agent:
            let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Replying to your agent" : "Replying to \(name)"
        case .me: return "Replying to yourself"
        case .named(let name): return "Replying to \(name)"
        case .unnamed: return "Replying to a message"
        }
    }

    /// The quote as people read it, with its handles' `@` back.
    var displaySnippet: String {
        snippet.replacingOccurrences(of: Self.quotedAt, with: "@")
    }

    private static let opener = "[Replying to"
    private static let closer = "\"]"
    private static let agentPhrase = "your previous message"
    private static let mePhrase = "my previous message"
    /// A quoted `@name` is written with a full-width at sign, so it reads the
    /// same to the model but isn't a mention that routes a group chat.
    private static let quotedAt = "\u{FF20}"
    /// The snippet, the longest name and the brackets.
    private static let maximumLineLength = maximumSnippetLength + 1 + maximumNameLength + 64

    private static func whoText(_ author: Author) -> String {
        switch author {
        case .agent: " " + agentPhrase
        case .me: " " + mePhrase
        case .named(let name): " " + name
        case .unnamed: ""
        }
    }

    private static func sanitized(_ author: Author) -> Author {
        guard case .named(let name) = author else { return author }
        let clean = sanitizedName(name)
        return clean.isEmpty ? .unnamed : .named(clean)
    }

    /// Names can't hold the line's own punctuation, a mention or a line break.
    private static func sanitizedName(_ name: String) -> String {
        let kept = name.filter { !"[]\":@".contains($0) }
        let line = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(line.prefix(maximumNameLength)).trimmingCharacters(in: .whitespaces)
    }
}

extension ChatModel {
    /// The composer's text as sent: a reply's quote line first. A command goes
    /// out as typed, since a line before it would stop it from running.
    var outgoingDraftText: String {
        guard let replyDraft, !draft.hasPrefix("/") else { return draft }
        return replyDraft.prefixing(draft)
    }

    /// The draft as saved: the reply's quote line, then the text. A draft with
    /// references keeps their exact bytes and saves without the reply.
    var persistedDraft: String {
        let canonical = canonicalReferenceDraft
        guard let replyDraft, referenceSelections.isEmpty, referenceSubmission == nil else { return canonical }
        return replyDraft.prefixing(canonical)
    }

    /// Long-press › Reply: the composer quotes this message until it's sent or cancelled.
    func reply(to item: TimelineItem, senderName: String) {
        replyDraft = ChatReplyQuote(replyingTo: item, senderName: senderName, isGroup: isBotMode)
    }
}
