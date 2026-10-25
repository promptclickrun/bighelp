import Foundation

enum NativeMessageReactionRowIdentity {
    private static let marker: [UInt8] = Array(":row:".utf8)

    /// Extracts only the exact canonical durable-row suffix emitted by the native
    /// history projectors. Display text, timestamps, source order, and role are
    /// deliberately not correlation inputs.
    static func rowID(from itemID: String) -> Int? {
        let bytes = Array(itemID.utf8)
        guard bytes.count > marker.count else { return nil }

        var markerStart: Int?
        if bytes.count >= marker.count {
            for index in stride(from: bytes.count - marker.count, through: 0, by: -1) {
                if bytes[index..<(index + marker.count)].elementsEqual(marker) {
                    markerStart = index
                    break
                }
            }
        }
        guard let markerStart, markerStart > 0 else { return nil }

        let digitsStart = markerStart + marker.count
        guard digitsStart < bytes.count else { return nil }
        var value = 0
        for byte in bytes[digitsStart...] {
            guard (48...57).contains(byte) else { return nil }
            let (multiplied, multiplicationOverflow) = value.multipliedReportingOverflow(by: 10)
            let (advanced, additionOverflow) = multiplied.addingReportingOverflow(Int(byte - 48))
            guard !multiplicationOverflow, !additionOverflow else { return nil }
            value = advanced
        }
        return value
    }

    static func exactItemIDs(for rowID: Int, in items: [TimelineItem]) -> [String] {
        guard rowID >= 0 else { return [] }
        return items.compactMap { item in
            self.rowID(from: item.id) == rowID ? item.id : nil
        }
    }

    static func timelineRole(from wireRole: String) -> TimelineRole? {
        if wireRole.utf8.elementsEqual("user".utf8) { return .human }
        if wireRole.utf8.elementsEqual("assistant".utf8) { return .assistant }
        return nil
    }
}

extension NativeMessageReaction {
    /// Nil for an author the app doesn't draw (only the person and the agent react).
    init?(_ value: DirectHermesMessageReaction.Reaction) {
        let author: NativeMessageReactionAuthor
        if value.author.utf8.elementsEqual("user".utf8) {
            author = .user
        } else if value.author.utf8.elementsEqual("agent".utf8) {
            author = .agent
        } else {
            return nil
        }
        self.init(emoji: value.emoji, author: author, occurredAt: value.at, isSeen: value.seen)
    }
}

enum NativeAffectionReactionPresentation {
    /// Stock Hermes currently publishes only `vibe`. It is decorative attention,
    /// not task success, and never supplies enough identity to decorate a row.
    static func companionReaction(for signal: NativeAffectionReactionSignal?) -> CompanionReaction? {
        guard let signal, signal.kind.utf8.elementsEqual("vibe".utf8) else { return nil }
        return .attention
    }
}
