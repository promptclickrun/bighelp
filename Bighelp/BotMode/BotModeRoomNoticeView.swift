import SwiftUI

/// A quiet centered line in a group chat: who took a message ("Pixel gave this to Scout"), or a
/// discussion Hermes paused at its cap. While nothing has moved a paused discussion on, it is a
/// small card with Continue and Stop.
struct BotModeRoomNoticeView: View {
    let notice: BotModeRoomNoticeRow
    let isContinuing: Bool
    let isStopping: Bool
    let problem: String?
    let onContinue: () -> Void
    let onStop: () -> Void

    var body: some View {
        if case .paused(_, true) = notice.kind {
            pausedCard
        } else {
            line
        }
    }

    private var line: some View {
        Text(notice.text)
            .font(.bighelp(.caption))
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BighelpTokens.space4)
            .accessibilityIdentifier("chat.group-notice")
    }

    private var pausedCard: some View {
        BighelpCard {
            VStack(spacing: BighelpTokens.space12) {
                Text(notice.text)
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BighelpTokens.space12) { actions }
                    VStack(spacing: BighelpTokens.space8) { actions }
                }
                if let problem {
                    Text(problem)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.group-paused.problem")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.group-paused")
    }

    private var actions: some View {
        Group {
            // Words, not a loader: the chat plays one loader at a time, on its live work.
            Button(isContinuing ? "Continuing…" : "Continue", action: onContinue)
                .bighelpProminentButtonStyle()
                .frame(minHeight: BighelpTokens.hitTarget)
                .disabled(isContinuing || isStopping)
                .accessibilityIdentifier("chat.group-paused.continue")
            Button("Stop", action: onStop)
                .buttonStyle(.bordered)
                .frame(minHeight: BighelpTokens.hitTarget)
                .disabled(isStopping)
                .accessibilityIdentifier("chat.group-paused.stop")
        }
    }

    @BighelpThemeReader private var theme
}
