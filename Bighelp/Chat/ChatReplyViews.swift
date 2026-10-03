import SwiftUI

/// "Replying to Avery: …" above the message box, in the rail's glass, lined up
/// with the message field like the attachment tag. ✕ cancels the reply.
struct ChatReplyDraftBar: View {
    let quote: ChatReplyQuote
    let agentName: String
    let onCancel: () -> Void
    /// The width of what sits left of the message field (the + button and its gap).
    var leadingInset: CGFloat = BighelpTokens.hitTarget + BighelpTokens.space8

    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.bighelp(.footnote).weight(.semibold))
                .foregroundStyle(theme.action)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.title(agentName: agentName))
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(quote.displaySnippet)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(quote.title(agentName: agentName)): \(quote.displaySnippet)")
            .accessibilityIdentifier("chat.reply-draft.quote")
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.bighelp(.caption).weight(.bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(theme.secondaryText.opacity(0.14), in: .circle)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .bighelpPlainButtonStyle(.circle)
            .bighelpIconLabel("Cancel reply")
            .accessibilityIdentifier("chat.reply-draft.cancel")
        }
        .padding(.leading, BighelpTokens.space12)
        .frame(minHeight: BighelpTokens.hitTarget)
        .bighelpNavigationGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.reply-draft")
        .padding(.leading, leadingInset)
        .padding(.trailing, BighelpTokens.hitTarget + BighelpTokens.space8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The message a person's message answers, small and quiet above its bubble.
struct ChatReplyQuoteView: View {
    let quote: ChatReplyQuote
    let agentName: String
    let alignsTrailing: Bool

    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .imageScale(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.title(agentName: agentName))
                    .bighelpMessageFont(.metadata, weight: .semibold)
                Text(quote.displaySnippet)
                    .bighelpMessageFont(.metadata)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.vertical, BighelpTokens.space8)
        .background(theme.incomingMessageBackground.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 300, alignment: alignsTrailing ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(quote.title(agentName: agentName)): \(quote.displaySnippet)")
        .accessibilityIdentifier("chat.message.reply-quote")
    }
}
