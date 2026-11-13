import SwiftUI

/// 11pt bold, letterspaced, uppercase section caption used across the Agent Studio.
struct AgentStudioCaption: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.bighelp(.caption2).weight(.bold))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    @BighelpThemeReader private var theme
}
