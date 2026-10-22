import SwiftUI

/// A member turn Hermes lost track of when its host stopped. The room waits on
/// it, and Discard is the only way on, so it asks once before discarding.
struct BotModeDiscardCard: View {
    let discardID: String
    let agentName: String
    let isSubmitting: Bool
    let errorMessage: String?
    let onDiscard: () -> Void

    @State private var isConfirming = false

    var body: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Label("\(agentName)’s answer was cut off", systemImage: "exclamationmark.circle.fill")
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Text(isConfirming
                     ? "\(agentName) may have done part of it already. Discarding doesn’t undo that."
                     : "The host stopped while \(agentName) was answering. Discard that answer so the group can go on.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.danger)
                        .accessibilityIdentifier("chat.bot-discard.error.\(discardID)")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BighelpTokens.space12) { actions }
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) { actions }
                }
                .disabled(isSubmitting)
                if isSubmitting {
                    ProgressView("Discarding")
                }
            }
        }
        .accessibilityIdentifier("chat.bot-discard.\(discardID)")
    }

    private var actions: some View {
        Group {
            if isConfirming {
                Button("Discard answer", role: .destructive) {
                    isConfirming = false
                    onDiscard()
                }
                .bighelpProminentButtonStyle()
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("chat.bot-discard.confirm.\(discardID)")
                Button("Cancel") { isConfirming = false }
                    .buttonStyle(.bordered)
                    .frame(minHeight: BighelpTokens.hitTarget)
            } else {
                Button("Discard") { isConfirming = true }
                    .buttonStyle(.bordered)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("chat.bot-discard.discard.\(discardID)")
            }
        }
    }

    @BighelpThemeReader private var theme
}
