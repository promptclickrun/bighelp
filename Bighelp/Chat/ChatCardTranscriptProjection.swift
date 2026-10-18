import Foundation

/// Removes transient/live card rows only when the same validated card identity
/// is durably carried by an assistant message. Text similarity is never used.
enum ChatCardTranscriptProjection {
    static func removingSupersededLiveCards(
        from entries: [ChatTranscriptEntry]
    ) -> [ChatTranscriptEntry] {
        var durableCardIDs = Set<String>()
        for entry in entries {
            guard case .message(let item) = entry,
                  item.role == .assistant,
                  case .message(let text) = item.content else { continue }
            durableCardIDs.formUnion(ChatCardMessageProjection.cardIDs(in: ReferenceCodec.decode(text).prose))
        }
        guard !durableCardIDs.isEmpty else { return entries }
        return entries.filter { entry in
            guard case .message(let item) = entry else { return true }
            switch item.content {
            case .generativeUI(let card):
                return !durableCardIDs.contains(card.id)
            case .bighelpCard(let card):
                return !durableCardIDs.contains(card.id)
            default:
                return true
            }
        }
    }
}
