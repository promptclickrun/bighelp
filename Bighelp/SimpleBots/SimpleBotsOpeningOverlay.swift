import SwiftUI

/// Over Bots mode while a bot's chat opens: the bighelp loader, what's opening (and on which
/// gateway, when it's another one), and Cancel.
struct SimpleBotsOpeningOverlay: View {
    let botName: String?
    var gatewayName: String? = nil
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
                    Text(botName.map { String(localized: "Opening \($0)…") } ?? String(localized: "Opening…"))
                        .bighelpFont(.sectionTitle, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                    if let gatewayName {
                        Text("On \(gatewayName)")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
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

/// The loader for a chat opening on the gateway in use (`SimpleBotsChatOpening`). Only this view reads
/// the opening chat, and only while one opens, so a chat's streaming never redraws the shell.
struct SimpleBotsChatOpeningLayer: View {
    let opening: SimpleBotsChatOpening
    let readiness: () -> SimpleBotsChatOpening.Readiness
    let onCancel: () -> Void

    var body: some View {
        let state = opening.current == nil ? .waiting : readiness()
        ZStack {
            if opening.isShowing, let current = opening.current {
                SimpleBotsOpeningOverlay(botName: current.name, onCancel: onCancel)
                    .transition(.opacity)
            }
        }
        .onChange(of: state) { _, state in opening.update(state) }
    }
}
