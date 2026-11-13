import SwiftUI

/// What waits for the person, from the shell's Needs you entries (`RootShellView.needsYouEntries`):
/// how many, and the first one's bot and one line.
struct TodayNeedsYouSummary: Equatable {
    let count: Int
    /// The first waiting item's bot (its profile ID for its face), and what it asks, in one line.
    let agentID: String?
    let botName: String
    let line: String
    var imageURL: URL? = nil
}

/// Shares waiting in ☰ › Shared with bighelp (`PendingShareCenter`).
@MainActor
struct TodayPendingShares {
    let count: Int
    let open: () -> Void
}

/// Today's top card while something waits: it opens the Needs you deck, where every answer is given.
struct TodayNeedsYouCard: View {
    let summary: TodayNeedsYouSummary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                if let agentID = summary.agentID {
                    SimpleBotFace(agentID: agentID, name: summary.botName, imageURL: summary.imageURL, size: 40)
                } else {
                    TodayCardSymbol(systemImage: "hand.raised.fill", tint: theme.action)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: BighelpTokens.space8) {
                        Text("Needs you")
                            .font(.bighelp(.headline, weight: .bold))
                            .foregroundStyle(theme.primaryText)
                        Spacer(minLength: BighelpTokens.space8)
                        Text(summary.count, format: .number)
                            .font(.bighelp(.subheadline, weight: .bold))
                            .foregroundStyle(theme.actionForeground)
                            .padding(.horizontal, BighelpTokens.space8)
                            .frame(minWidth: 24, minHeight: 24)
                            .background(theme.action, in: Capsule())
                    }
                    Text(summary.botName)
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Text(summary.line)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(BighelpTokens.space16)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .bighelpSurface(.card, isInteractive: true)
            .contentShape(RoundedRectangle(cornerRadius: BighelpTokens.cardCornerRadius, style: .continuous))
        }
        .bighelpPlainButtonStyle()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens what's waiting")
        .accessibilityIdentifier("today.needs-you")
    }

    @BighelpThemeReader private var theme
}

/// "Shared with bighelp" while shares wait, in the same quiet style.
struct TodaySharesCard: View {
    let shares: TodayPendingShares

    var body: some View {
        Button(action: shares.open) {
            HStack(spacing: BighelpTokens.space12) {
                TodayCardSymbol(systemImage: "square.and.arrow.down", tint: theme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shared with bighelp")
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("\(shares.count) waiting")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(BighelpTokens.space16)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .bighelpSurface(.card, isInteractive: true)
            .contentShape(RoundedRectangle(cornerRadius: BighelpTokens.cardCornerRadius, style: .continuous))
        }
        .bighelpPlainButtonStyle()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.shares")
    }

    @BighelpThemeReader private var theme
}

private struct TodayCardSymbol: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.bighelp(.body, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}
