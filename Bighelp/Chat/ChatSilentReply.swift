import Foundation

/// Hermes' silence rules (`gateway/response_filters.py`), so the app shows what Hermes itself
/// would deliver. Silence is a delivery decision: the saved row keeps the marker.
enum ChatSilentReply {
    /// `LIVE_GATEWAY_SILENT_MARKERS`, including the Chinese forms newer Hermes recognizes.
    static let markers: Set<String> = ["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY", "[静默]", "静默", "[沉默]", "沉默"]
    /// What Hermes' gateway sends when a person's message got only a marker (`gateway/run_turn.py`).
    static let notice = "⚠️ The model returned only a silence marker for a message that needed a reply. "
        + "Try again or rephrase."
    /// Longer than any marker could plausibly be, even with stray punctuation.
    private static let markerLengthCap = 64

    enum Lane: Equatable { case chat, room, scheduled }
    enum Presentation: Equatable { case show, hide, notice }

    /// Hermes' exact rule: the whole reply is a marker, allowing stray edge punctuation.
    static func isMarker(_ text: String) -> Bool {
        candidates(text).contains(where: markers.contains)
    }

    /// While a reply streams, text that could still become a marker ("NO" on the way to
    /// "NO_REPLY") stays hidden, so a marker never shows and then disappears.
    static func mayBecomeMarker(_ text: String) -> Bool {
        candidates(text).contains { candidate in
            !candidate.isEmpty && markers.contains { $0.hasPrefix(candidate) }
        }
    }

    /// Whether a turn nobody typed may end in silence (Hermes' `silence_allowed`): an off-screen
    /// note (a widget tap, or an older bighelp reaction note), an internal notification, or a
    /// message not addressed to the agent.
    static func silenceAllowed(displayKind: String?, replyExpected: Bool?) -> Bool {
        displayKind == "hidden" || displayKind == "internal_notification" || replyExpected == false
    }

    /// A live reply. Saved history already applied the turn's real kind; here the only signal is
    /// what came right before: a bare marker answering the person's own message becomes Hermes'
    /// notice, and one answering something unseen (an off-screen note) disappears. Group chats and
    /// scheduled runs keep every bare marker quiet. An agent that reacted to the person's message
    /// (`bighelp_react_to_message`) and then sent a marker answered with the reaction: Hermes
    /// retries a reply with no text, so the marker is how a reaction ends the turn.
    static func presentation(of item: TimelineItem, after previous: TimelineItem?, lane: Lane,
                             answeredWithReaction: Bool = false) -> Presentation {
        guard item.role == .assistant, item.sender.kind != .system, case .message(let text) = item.content else {
            return .show
        }
        if item.metadata.delivery == "Streaming" { return mayBecomeMarker(text) ? .hide : .show }
        guard isMarker(text) else { return .show }
        guard lane == .chat, let previous, previous.role == .human, !answeredWithReaction else { return .hide }
        return .notice
    }

    /// `items` as shown: silent replies removed, a bare marker to a person replaced by the notice.
    /// `previous` is the conversation message just before `items`, when they continue a list.
    /// `reactedTo` says whether the agent reacted to a person's message.
    static func presented(_ items: [TimelineItem], lane: Lane, after previous: TimelineItem? = nil,
                          reactedTo: (TimelineItem) -> Bool = { _ in false }) -> [TimelineItem] {
        var previous = previous
        return items.compactMap { item in
            defer { if isConversationMessage(item) { previous = item } }
            let answeredWithReaction = previous.map { $0.role == .human && reactedTo($0) } ?? false
            switch presentation(of: item, after: previous, lane: lane, answeredWithReaction: answeredWithReaction) {
            case .show: return item
            case .hide: return nil
            case .notice: return noticeItem(replacing: item)
            }
        }
    }

    static func isConversationMessage(_ item: TimelineItem) -> Bool {
        guard item.sender.kind != .system, case .message = item.content else { return false }
        return true
    }

    static func noticeItem(replacing item: TimelineItem) -> TimelineItem {
        TimelineItem(id: item.id, role: item.role, sender: item.sender, content: .message(notice),
                     metadata: item.metadata, attachments: item.attachments)
    }

    /// Hermes' canonical forms of a marker-sized reply: trimmed, uppercased, whitespace collapsed,
    /// with and without stray edge punctuation. Square brackets stay, so "[SILENT" isn't "SILENT".
    private static func candidates(_ text: String) -> [String] {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = stripped.unicodeScalars
        // A scalar is at most four UTF-8 bytes; the byte count is free, the scalar count isn't.
        guard !scalars.isEmpty, stripped.utf8.count <= markerLengthCap * 4,
              scalars.count <= markerLengthCap else { return [] }
        var start = scalars.startIndex, end = scalars.endIndex
        while start < end, isEdgePunctuation(scalars[start]) { start = scalars.index(after: start) }
        while end > start, isEdgePunctuation(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        let depunctuated = String(scalars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let forms = depunctuated == stripped ? [stripped] : [stripped, depunctuated]
        return forms.map { $0.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }

    private static func isEdgePunctuation(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar != "[", scalar != "]" else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }
}
