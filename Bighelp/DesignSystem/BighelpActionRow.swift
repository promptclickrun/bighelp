import SwiftUI

/// A page's main action as a list row: an icon, what it does in a few words,
/// and one short line of why (like "12 commits behind"). Used where people
/// come to do one thing, such as updating Hermes or restarting its gateway.
struct BighelpActionRow: View {
    let title: String
    var detail: String?
    let systemImage: String
    var tint: Color?
    var isWorking = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: BighelpTokens.space12) {
                BighelpIconTile(systemName: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(tint ?? theme.action)
                    if let detail {
                        Text(detail)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: BighelpTokens.space8)
                if isWorking {
                    BighelpSpinner(size: 16, color: tint)
                }
            }
            .frame(minHeight: 52)
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12), padding: BighelpTokens.space4)
    }

    @BighelpThemeReader private var theme
}
