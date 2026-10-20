import SwiftUI

/// A branded menu row: icon tile, title, optional detail, and a trailing mark.
struct BighelpMenuRowLabel: View {
    enum Trailing { case chevron, selected, none, new }

    let title: String
    var detail: String?
    let symbol: String
    var trailing: Trailing = .chevron

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            switch trailing {
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            case .selected:
                Image(systemName: "checkmark.circle.fill")
                    .font(.bighelp(.title3))
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
            case .none:
                EmptyView()
            case .new:
                // Like the bottom bar's dot: something here hasn't been seen.
                Circle()
                    .fill(theme.action)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("New")
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// A recent chat in the menu: who it's with, its title and when it last moved.
struct BighelpMenuChatRow: View {
    let chat: SessionSummary
    let agent: (String) -> (name: String, imageURL: URL?)?

    var body: some View {
        let lead = chat.kind == .direct ? chat.agentIDs.first.flatMap(agent) : nil
        HStack(spacing: BighelpTokens.space12) {
            if let lead, let id = chat.agentIDs.first {
                AvatarView(stableID: id, displayName: lead.name, imageURL: lead.imageURL, size: 30)
            } else {
                Image(systemName: "person.3.fill")
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.action)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.action.opacity(0.14)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? "New chat" : chat.title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(lead?.name ?? "Group chat")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: BighelpTokens.space8)
            if chat.isActive {
                Circle().fill(theme.action).frame(width: 8, height: 8)
                    .accessibilityLabel("Working")
            }
            Text(chat.updatedAt, format: .relative(presentation: .named, unitsStyle: .narrow))
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

extension View {
    /// Mac: a menu row's separator spans the row, as wide as the hover highlight, in the
    /// theme's line color. Inset to the text and in the highlight's gray, it merged with the
    /// highlight into a stepped edge. Elsewhere the row keeps the list's separator.
    func bighelpMenuRowSeparator() -> some View {
        modifier(BighelpMenuRowSeparator())
    }
}

private struct BighelpMenuRowSeparator: ViewModifier {
    @BighelpThemeReader private var theme

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        // Both ends: the trailing one otherwise stops at the list's own 16-point margin.
        content
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
            .listRowSeparatorTint(theme.separator)
        #else
        content
        #endif
    }
}

/// A menu row's layout. The content sits 16 points in from the panel's edge everywhere.
/// On the Mac the row keeps 4 points on every side and the label takes the other 12, so the
/// hover highlight, the label's own frame, sits 4 points inside the panel all around, as the
/// Finder's and Mail's sidebars do, instead of floating 12 points inside with the first and
/// last rows' corners cut by the panel's. Elsewhere the highlight is the label grown by 4 points.
enum BighelpMenuRowLayout {
    static var insets: EdgeInsets {
        let vertical: CGFloat = BighelpPlatform.isMac ? edgeInset : 2
        return EdgeInsets(top: vertical, leading: edgeInset, bottom: vertical, trailing: edgeInset)
    }

    static var labelInset: CGFloat { BighelpPlatform.isMac ? BighelpTokens.space12 : 0 }

    /// How far the highlight grows past the label.
    static var highlightPadding: CGFloat { BighelpPlatform.isMac ? 0 : BighelpTokens.space4 }

    static var outline: BighelpPointerOutline {
        .rounded(BighelpPlatform.isMac ? BighelpTokens.radius8 : BighelpTokens.radius12)
    }

    private static var edgeInset: CGFloat { BighelpPlatform.isMac ? BighelpTokens.space4 : BighelpTokens.space16 }
}
