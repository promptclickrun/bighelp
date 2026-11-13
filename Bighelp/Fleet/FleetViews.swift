import SwiftUI

/// Which host a row belongs to, shown only when there's more than one.
struct FleetHostTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.bighelp(.caption2).weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(theme.secondaryText.opacity(0.12), in: .capsule)
            .accessibilityLabel("on \(name)")
    }

    @BighelpThemeReader private var theme
}

/// A section caption as the Sessions list draws them: small, bold, spaced capitals.
struct FleetSectionCaption: View {
    let title: LocalizedStringKey
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11
    @BighelpThemeReader private var theme

    var body: some View {
        Text(title)
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}
