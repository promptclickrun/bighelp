import SwiftUI

extension ChatBoardCard {
    /// The same pastel the item has on its page: an idea's section, a post's source, a goal's
    /// category.
    var blockColor: BighelpBlockColor {
        BighelpBlockColor.pastel(for: detail.isEmpty ? title : detail.lowercased())
    }

    /// "Idea · Home", "Goal".
    var label: String {
        let kind = switch kind {
        case .idea: String(localized: "Idea")
        case .feedPost: String(localized: "Feed post")
        case .goal: String(localized: "Goal")
        }
        return detail.isEmpty ? kind : "\(kind) · \(detail)"
    }
}

/// The idea, post or goal a sent message carries, inside the person's bubble above their words.
struct ChatBoardCardView: View {
    let card: ChatBoardCard

    @BighelpThemeReader private var theme

    var body: some View {
        let block = card.blockColor
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            HStack(spacing: BighelpTokens.space8) {
                Image(systemName: card.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(block.ink)
                    .frame(width: 24, height: 24)
                    .background(block.fill(dark: theme.isDarkPalette),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                Text(card.label)
                    .font(.bighelp(.caption, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Text(card.title)
                .font(.bighelp(.body, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !card.body.isEmpty {
                // One paragraph, as the Ideas tiles show it.
                Text(MarkdownDocument(card.body).visiblePlainText
                    .split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(4)
            }
        }
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.vertical, BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // After dark the page's own black sets it apart from the bubble around it.
        .background(theme.isDarkPalette ? theme.canvas : theme.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.board-card")
    }
}

/// The idea, post or goal the draft is about, inside the message box above the text. ✕ takes
/// it off; the text stays.
struct ChatBoardCardDraftView: View {
    let card: ChatBoardCard
    let onRemove: () -> Void

    @BighelpThemeReader private var theme

    var body: some View {
        let block = card.blockColor
        HStack(spacing: BighelpTokens.space8) {
            Image(systemName: card.kind.systemImage)
                .font(.bighelp(.footnote).weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(card.label)
                    .font(.bighelp(.caption2, weight: .semibold))
                    .opacity(0.75)
                Text(card.title)
                    .font(.bighelp(.subheadline, weight: .semibold))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.board-card-draft.title")
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.bighelp(.caption).weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(block.ink.opacity(0.12), in: .circle)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .bighelpPlainButtonStyle(.circle)
            .bighelpIconLabel(String(localized: "Remove \(card.title)"))
            .accessibilityIdentifier("chat.board-card-draft.remove")
        }
        .foregroundStyle(block.ink)
        .padding(.leading, BighelpTokens.space12)
        .background(block.fill(dark: theme.isDarkPalette), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.board-card-draft")
    }
}
