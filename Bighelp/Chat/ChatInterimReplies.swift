import SwiftUI

/// Marks agent messages written on the way to the answer ("Let me check your
/// files…") so they read quieter than the answer itself, like thinking.
///
/// Every message stays in place and fully readable; only its look changes.
/// A message is interim when the agent kept working after it (tools or
/// thinking), including work the chat hides. In a finished turn the last
/// message is always the answer.
@MainActor
enum ChatInterimReplies {
    /// `activityEvents` is all of the chat's work, shown or hidden: with tool
    /// calls hidden the transcript has no work in it, but the notes before
    /// that work are still the agent thinking out loud.
    static func marking(
        _ entries: [ChatTranscriptEntry], isSending: Bool, isBotMode: Bool, isSimpleBots: Bool = false,
        activityEvents: [ChatActivityEvent] = []
    ) -> [ChatTranscriptEntry] {
        // In a room several agents answer at once; each reply is someone's answer. Simple Bot mode
        // reads like texting: every message the bot sends is a text, never grey or folded away.
        guard !isBotMode, !isSimpleBots else { return entries }
        let turnStarts = entries.indices.filter {
            if case .message(let item) = entries[$0], item.role == .human { return true }
            return false
        }
        let workOrders = activityEvents.filter(\.isPresentable).compactMap(\.sourceOrder).sorted()
        var result = entries
        var start = 0
        for (index, end) in (turnStarts + [entries.count]).enumerated() {
            let isLastTurn = index == turnStarts.count
            let lower = start > 0 ? order(of: entries[start - 1]) : nil
            let upper = end < entries.count ? order(of: entries[end]) : nil
            let hiddenWork = lastOrder(in: workOrders, after: lower, before: upper)
            markTurn(&result, range: start..<end, inFlight: isLastTurn && isSending, lastHiddenWork: hiddenWork)
            start = end + 1
        }
        return result
    }

    private static func markTurn(
        _ entries: inout [ChatTranscriptEntry], range: Range<Int>, inFlight: Bool, lastHiddenWork: Int?
    ) {
        guard !range.isEmpty else { return }
        let replies = range.filter { isReply(entries[$0]) }
        guard let lastReply = replies.last else { return }
        let lastWork = range.last { index in
            if case .activity = entries[index] { return true }
            return false
        }
        for index in replies {
            let shownWorkFollows = lastWork.map { index < $0 } ?? false
            let hiddenWorkFollows = order(of: entries[index]).flatMap { reply in
                lastHiddenWork.map { reply < $0 }
            } ?? false
            let workFollows = shownWorkFollows || hiddenWorkFollows
            let interim = workFollows && (inFlight || index < lastReply)
            guard interim, case .message(let item) = entries[index] else { continue }
            entries[index] = .message(item.markedInterim())
        }
    }

    private static func order(of entry: ChatTranscriptEntry) -> Int? {
        guard case .message(let item) = entry else { return nil }
        return item.metadata.sourceOrder
    }

    /// The latest work strictly inside one turn's order bounds.
    private static func lastOrder(in sorted: [Int], after lower: Int?, before upper: Int?) -> Int? {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if upper.map({ sorted[middle] < $0 }) ?? true { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let candidate = sorted[low - 1]
        return lower.map { candidate > $0 } ?? true ? candidate : nil
    }

    /// Plain agent prose only; cards, approvals and media keep their own look.
    private static func isReply(_ entry: ChatTranscriptEntry) -> Bool {
        guard case .message(let item) = entry, item.role == .assistant,
              case .message(let text) = item.content else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Interim messages and thinking share one look: no bubble, smaller muted text,
/// and a thin line down the left, so the answer stands out.
struct ChatInterimReplyStyle: ViewModifier {
    static let textScale: CGFloat = 0.88
    static let ruleWidth: CGFloat = 2
    let theme: BighelpTheme

    func body(content: Content) -> some View {
        content
            .padding(.leading, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(theme.secondaryText.opacity(0.28))
                    .frame(width: Self.ruleWidth)
                    .padding(.vertical, BighelpTokens.space4)
                    .accessibilityHidden(true)
            }
            .padding(.leading, BighelpTokens.space8)
    }
}
