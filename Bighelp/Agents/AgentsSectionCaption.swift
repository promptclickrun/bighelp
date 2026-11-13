import SwiftUI

/// Uppercase, letterspaced section caption ("PINNED", "GROUP CHATS").
struct AgentsSectionCaption: View {
    let title: String

    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.08)
            .foregroundStyle(theme.secondaryText)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }

    @BighelpThemeReader private var theme
}
