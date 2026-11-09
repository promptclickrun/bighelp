import SwiftUI

/// "Claude Opus 4.6 · Thinking: High" for the chat on screen.
struct ChatModelSummaryPresentation: Equatable {
    let modelName: String
    let reasoning: String
    let providerID: String?
    let providerName: String?

    @MainActor
    init(controls: SessionRuntimeControlModel) {
        modelName = controls.modelDisplayName
        if let label = controls.currentReasoningLabel {
            reasoning = "Thinking: \(label)"
        } else {
            reasoning = controls.isLoadingReasoning ? "Thinking: checking…" : "Thinking: unknown"
        }
        providerID = controls.currentProvider
        providerName = controls.currentProvider.map { provider in
            AIProviderBrandRegistry.displayName(
                id: provider,
                authoritativeName: controls.modelProviders.first { $0.id == provider }?.name
            )
        }
    }
}

/// The chat's model and reasoning where people look during a chat: the context
/// pop-up, the avatar's profile and Info. Tapping it opens Model settings,
/// except while the agent is replying (the choice is fixed until the turn ends).
struct ChatModelSummaryRow: View {
    let controls: SessionRuntimeControlModel
    var onChange: (() -> Void)?

    var body: some View {
        let summary = ChatModelSummaryPresentation(controls: controls)
        let isLocked = ChatRuntimeSelectionLockout.isLocked(isTurnActive: controls.isTurnActive)
        Group {
            if let onChange {
                Button(action: onChange) { label(summary, showsChange: !isLocked) }
                    .buttonStyle(.plain)
                    .disabled(isLocked)
                    .accessibilityHint(isLocked
                        ? ChatRuntimeSelectionLockout.accessibilityHint
                        : "Opens Model settings for this chat.")
            } else {
                label(summary, showsChange: false)
            }
        }
        .accessibilityIdentifier("chat.model-summary")
        .task(id: controls.isTurnActive) { await controls.loadSummaryIfNeeded() }
    }

    private func label(_ summary: ChatModelSummaryPresentation, showsChange: Bool) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Group {
                if let providerID = summary.providerID {
                    AIProviderMarkView(providerID: providerID, providerName: summary.providerName ?? providerID,
                                       context: .chatSessionCompactControl, size: 22)
                } else {
                    Image(systemName: "cpu").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.action)
                }
            }
            .frame(width: 32, height: 32)
            .background(theme.incomingMessageBackground, in: .rect(cornerRadius: 9))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.modelName)
                    .bighelpFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(summary.reasoning)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .accessibilityIdentifier("chat.model-summary.reasoning")
            }
            Spacer(minLength: BighelpTokens.space8)
            if showsChange {
                Text("Change")
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.action)
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model: \(summary.modelName). \(summary.reasoning)")
    }

    @BighelpThemeReader private var theme
}
