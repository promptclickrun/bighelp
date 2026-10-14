import SwiftUI

/// A failed turn under its reply: what went wrong in one plain sentence, and
/// one or two buttons that fix it (`ChatTurnFailurePresentation`). Hermes'
/// own reply above it keeps the details.
struct ChatTurnFailureCard: View {
    let model: ChatModel
    let failedTurn: ChatModel.FailedTurn
    let scheduledRetry: ChatScheduledRetry?
    /// Settings › AI providers; nil leaves those buttons out.
    let onOpenProviderAccounts: (() -> Void)?
    let onNewChat: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        // Redraws once just after the limit lifts, so "Try again at 3:00 PM" becomes
        // "Try again". The schedule's own date can be a future entry, so read the clock.
        TimelineView(.explicit([failedTurn.failure.resetsAt].compactMap { $0?.addingTimeInterval(1) })) { _ in
            let now = Date()
            if let presentation = ChatTurnFailurePresentation.resolve(
                failedTurn.failure, canResend: failedTurn.canResend, now: now) {
                card(presentation, now: now)
            }
        }
    }

    private func card(_ presentation: ChatTurnFailurePresentation, now: Date) -> some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Label {
                    Text(presentation.sentence)
                        .accessibilityIdentifier("chat.turn-failure.sentence")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                        .accessibilityHidden(true)
                }
                .bighelpFont(.body)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                if let scheduledRetry {
                    scheduledLine(scheduledRetry, now: now)
                }
                let fixes = presentation.fixes.filter(isAvailable)
                if !fixes.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: BighelpTokens.space8) { buttons(fixes, now: now) }
                        VStack(alignment: .leading, spacing: BighelpTokens.space8) { buttons(fixes, now: now) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.turn-failure")
    }

    private func scheduledLine(_ schedule: ChatScheduledRetry, now: Date) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Text("Sends again at \(BighelpResetTime.describe(schedule.at, now: now).short) while this chat is open.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.turn-failure.scheduled")
            Spacer(minLength: 0)
            Button("Cancel") { model.cancelScheduledRetry() }
                .buttonStyle(BighelpV2ButtonStyle(emphasis: .quiet))
                .accessibilityLabel("Cancel the timed retry")
                .accessibilityIdentifier("chat.turn-failure.cancel-scheduled")
        }
    }

    @ViewBuilder
    private func buttons(_ fixes: [ChatTurnFailureFix], now: Date) -> some View {
        ForEach(Array(fixes.enumerated()), id: \.offset) { index, fix in
            Button(title(fix, now: now)) { perform(fix) }
                .buttonStyle(BighelpV2ButtonStyle(emphasis: index == 0 ? .primary : .secondary))
                .disabled(isDisabled(fix))
                .accessibilityIdentifier("chat.turn-failure.fix.\(fix.identifier)")
        }
    }

    private func title(_ fix: ChatTurnFailureFix, now: Date) -> String {
        switch fix {
        case .tryAgain: "Try again"
        case .tryAgainAt(let date): "Try again at \(BighelpResetTime.describe(date, now: now).short)"
        case .useAnotherModel: "Use another model"
        case .pickAnotherModel: "Pick another model"
        case .fixSignIn: "Fix sign-in"
        case .checkProviders: "Check AI providers"
        case .addCredit: "Add credit"
        case .startNewChat: "Start a new chat"
        }
    }

    private func isAvailable(_ fix: ChatTurnFailureFix) -> Bool {
        switch fix {
        case .fixSignIn, .checkProviders: onOpenProviderAccounts != nil
        case .useAnotherModel, .pickAnotherModel: model.runtimeControls != nil
        default: true
        }
    }

    private func isDisabled(_ fix: ChatTurnFailureFix) -> Bool {
        switch fix {
        case .tryAgain: model.isSending
        // Already counting down.
        case .tryAgainAt: scheduledRetry != nil || model.isSending
        default: false
        }
    }

    private func perform(_ fix: ChatTurnFailureFix) {
        switch fix {
        case .tryAgain: Task { await model.retryFailedTurn() }
        case .tryAgainAt(let date): model.scheduleRetry(at: date)
        case .useAnotherModel, .pickAnotherModel: model.requestSessionControls()
        case .fixSignIn, .checkProviders: onOpenProviderAccounts?()
        case .addCredit(let url): openURL(url)
        case .startNewChat: onNewChat()
        }
    }

    @BighelpThemeReader private var theme
}
