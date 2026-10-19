import SwiftUI

/// Over Simple Bot mode's home while a bot on another gateway opens: the bighelp loader, what's
/// opening and where, and Cancel.
struct SimpleBotsOpeningOverlay: View {
    let botName: String?
    let gatewayName: String
    let onCancel: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            theme.canvas.opacity(0.35).ignoresSafeArea()
            VStack(spacing: BighelpTokens.space16) {
                BighelpNoodleView(motion: .loader, size: 72)
                    .accessibilityHidden(true)
                VStack(spacing: BighelpTokens.space4) {
                    Text(botName.map { "Opening \($0)…" } ?? "Opening…")
                        .bighelpFont(.sectionTitle, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                    Text("On \(gatewayName)")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
                Button("Cancel", action: onCancel)
                    .bighelpFont(.label)
                    .foregroundStyle(theme.secondaryText)
                    .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("simple-bots.opening.cancel")
            }
            .padding(BighelpTokens.space24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.opening")
    }
}
