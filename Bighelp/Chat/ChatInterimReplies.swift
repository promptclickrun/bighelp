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
        _ entries: [ChatTranscriptEntry], isSending: Bool, isBotMode: Bool,
        activityEvents: [ChatActivityEvent] = []
    ) -> [ChatTranscriptEntry] {
        // In a room several agents answer at once; each reply is someone's answer.
        guard !isBotMode else { return entries }
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

    /// Simple Bot mode: each turn's interim messages move under one "{Agent}'s reasoning" row, where the
    /// first of them was. With Show reasoning on it's open, filling in as the bot works; off, they're
    /// hidden. The message that ends a turn is its answer and always shows as a message.
    static func groupingForSimpleBots(_ rows: [ChatTurnDisplayRow], agentName: String,
                                      showsReasoning: Bool) -> [ChatTurnDisplayRow] {
        var result: [ChatTurnDisplayRow] = []
        var group: Int?
        for row in rows {
            guard case .entry(.message(let item)) = row else {
                result.append(row)
                continue
            }
            if item.role == .human {
                group = nil
                result.append(row)
            } else if item.metadata.isInterimReply {
                guard showsReasoning else { continue }
                if let index = group, case .reasoning(var reasoning) = result[index] {
                    reasoning.entries.append(.message(item))
                    result[index] = .reasoning(reasoning)
                } else {
                    group = result.count
                    result.append(.reasoning(ChatInterimReasoning(
                        id: "reasoning:\(item.id)", agentName: agentName, entries: [.message(item)])))
                }
            } else {
                result.append(row)
            }
        }
        return result
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

/// Simple Bot mode's "{Agent}'s reasoning" row: the bot's interim messages follow it in the same quiet
/// look, on the same line down their left.
struct ChatInterimReasoningHeader: View {
    let agentName: String
    @BighelpThemeReader private var theme

    var body: some View {
        Label {
            Text("\(agentName)\u{2019}s reasoning")
                .font(.bighelp(.subheadline, weight: .medium))
        } icon: {
            Image(systemName: "brain")
                .font(.bighelp(.footnote))
        }
        .foregroundStyle(theme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, BighelpTokens.space8)
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("chat.reasoning.header")
    }
}
