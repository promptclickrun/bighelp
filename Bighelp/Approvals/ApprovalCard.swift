import SwiftUI

struct ApprovalCard: View {
    let model: ApprovalModel

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            heading
            requestFacts
            consequence
            Divider()
            status
            actions
            Text("Opening these details does not submit a decision.")
                .bighelpFont(.metadata)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("approval.authority-boundary")
        }
        .padding(BighelpTokens.space16)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.card")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Label("Approval details", systemImage: "exclamationmark.triangle.fill")
                .bighelpFont(.sectionTitle)
                .foregroundStyle(theme.warning)
                .accessibilityAddTraits(.isHeader)

            Text(model.request.action)
                .bighelpFont(.screenTitle)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var requestFacts: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            approvalFact("Requester", model.request.requester)
            approvalFact("Vendor", model.request.vendor)
            approvalFact("Amount", model.request.amount, usesTabularNumerals: true)
            approvalFact("Due date", model.request.dueDate)
            approvalFact("Category", model.request.category)
            approvalFact("Source invoice", model.request.sourceInvoice, usesTabularNumerals: true)
        }
    }

    private var consequence: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text("What happens next")
                .bighelpFont(.label)
                .foregroundStyle(theme.primaryText)
            Text(model.request.consequence)
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        HStack(alignment: .center, spacing: BighelpTokens.space8) {
            switch model.status {
            case .idle:
                Image(systemName: "circle.dashed")
                    .accessibilityHidden(true)
                Text("Awaiting your decision.")
            case .pending:
                BighelpThinkingOrb(scenario: .working, scale: .inline)
                    .accessibilityHidden(true)
                Text("Submitting decision…")
            case .resolved(let decision):
                Image(systemName: decision.authorizesRequest ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(decision.authorizesRequest ? theme.success : theme.danger)
                    .accessibilityHidden(true)
                Text(resolvedStatusText(decision))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.danger)
                    .accessibilityHidden(true)
                Text(message)
            }
        }
        .bighelpFont(.body, weight: .semibold)
        .foregroundStyle(theme.primaryText)
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .padding(.horizontal, BighelpTokens.space12)
        .background(statusBackground, in: .rect(cornerRadius: BighelpTokens.radius12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Approval status")
        .accessibilityValue(statusText)
        .accessibilityIdentifier("approval.status")
    }

    private var actions: some View {
        VStack(spacing: BighelpTokens.space12) {
            ForEach(model.availableDecisions, id: \.self) { decision in
                decisionButton(decision)
            }
        }
    }

    @ViewBuilder
    private func decisionButton(_ decision: ApprovalDecision) -> some View {
        let presentation = ApprovalActionPresentation.resolve(for: decision)
        if decision == .once {
            approvalButton(decision, presentation: presentation)
                .bighelpProminentButtonStyle()
                .tint(theme.action)
        } else {
            approvalButton(decision, presentation: presentation)
                .buttonStyle(.bordered)
                .tint(presentation.isDestructive ? theme.danger : theme.action)
        }
    }

    private func approvalButton(
        _ decision: ApprovalDecision,
        presentation: ApprovalActionPresentation
    ) -> some View {
        Button(role: presentation.isDestructive ? .destructive : nil) {
            Task { await model.submit(decision) }
        } label: {
            Text(decision.buttonTitle)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .center)
        }
        .disabled(!allowsSubmission)
        .accessibilityHint(decision.accessibilityHint)
        .accessibilityIdentifier("approval.\(decision.rawValue)")
    }

    private func approvalFact(
        _ label: String,
        _ value: String,
        usesTabularNumerals: Bool = false
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: BighelpTokens.space12)
                factValue(value, usesTabularNumerals: usesTabularNumerals)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(label)
                    .foregroundStyle(theme.secondaryText)
                factValue(value, usesTabularNumerals: usesTabularNumerals)
            }
        }
        .bighelpFont(.body)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func factValue(_ value: String, usesTabularNumerals: Bool) -> some View {
        if usesTabularNumerals {
            Text(value)
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()
        } else {
            Text(value)
                .foregroundStyle(theme.primaryText)
        }
    }

    private var statusText: String {
        switch model.status {
        case .idle:
            "Awaiting your decision."
        case .pending:
            "Busy. Submitting decision."
        case .resolved(let decision):
            resolvedStatusText(decision)
        case .failed(let message):
            "Failed. \(message)"
        }
    }

    private var statusBackground: Color {
        switch model.status {
        case .idle, .pending:
            theme.warning.opacity(0.12)
        case .resolved(let decision):
            (decision.authorizesRequest ? theme.success : theme.danger).opacity(0.12)
        case .failed:
            theme.danger.opacity(0.12)
        }
    }

    private var allowsSubmission: Bool {
        switch model.status {
        case .idle, .failed:
            true
        case .pending, .resolved:
            false
        }
    }

    private func resolvedStatusText(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .once: "Approved this time."
        case .session: "Approved for this chat."
        case .always: "Always approved."
        case .deny: "Denied by Hermes."
        }
    }

    @BighelpThemeReader private var theme

}

#Preview("Approval") {
    ScrollView {
        ApprovalCard(
            model: ApprovalModel(
                request: .vendorFixture,
                client: ApprovalFixtureClient(confirmationDelay: .zero)
            )
        )
        .padding(BighelpTokens.space20)
    }
    .background(BighelpTheme.light.canvas)
}

#Preview("Approval - Accessibility Extra Large") {
    ScrollView {
        ApprovalCard(
            model: ApprovalModel(
                request: .vendorFixture,
                client: ApprovalFixtureClient(confirmationDelay: .zero)
            )
        )
        .padding(BighelpTokens.space20)
    }
    .background(BighelpTheme.light.canvas)
    .dynamicTypeSize(.accessibility3)
}
