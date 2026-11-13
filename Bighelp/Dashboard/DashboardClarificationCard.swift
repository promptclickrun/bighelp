import SwiftUI

/// A question Hermes asked, answered in place: in a chat (`ChatView+Timeline`) and in Needs you.
struct DashboardClarificationAttentionCard: View {
    let itemID: String
    let request: DashboardClarificationRequest
    let model: DashboardModel
    let accessibilityPrefix: String
    let sessionTitle: String?
    let onOpenSession: (() -> Void)?

    init(
        itemID: String,
        request: DashboardClarificationRequest,
        model: DashboardModel,
        accessibilityPrefix: String = "dashboard",
        sessionTitle: String? = nil,
        onOpenSession: (() -> Void)? = nil
    ) {
        self.itemID = itemID
        self.request = request
        self.model = model
        self.accessibilityPrefix = accessibilityPrefix
        self.sessionTitle = sessionTitle
        self.onOpenSession = onOpenSession
        self.draft = model.clarificationDraft(itemID: itemID, request: request)
    }

    @Bindable private var draft: DashboardClarificationDraft

    private var accessibilityIdentifiers: DashboardClarificationAccessibilityIdentifiers {
        DashboardClarificationAccessibilityIdentifiers(prefix: accessibilityPrefix)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isExpired = request.isExpired(at: context.date)
            let canRespond = !isExpired
            BighelpCard {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    Label("Clarification needed", systemImage: "questionmark.bubble.fill")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(isExpired ? theme.tertiaryText : theme.warning)
                    if let sessionTitle, let onOpenSession {
                        Button(action: onOpenSession) {
                            Label(sessionTitle, systemImage: "bubble.left.and.bubble.right")
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.action)
                        .accessibilityHint("Opens the conversation that asked this question")
                        .accessibilityIdentifier("\(accessibilityPrefix).clarification.session.\(itemID)")
                    }

                    ForEach(Array(request.questions.enumerated()), id: \.offset) { questionIndex, question in
                        questionView(question, questionIndex: questionIndex, canRespond: canRespond)
                    }

                    if ClarificationAnswers.acceptsOwnWords(shapes) {
                        ownWordsField(canRespond: canRespond)
                    }

                    BighelpPillControl(
                        isEnabled: completedResponse() != nil && canRespond && !isResolving
                    ) {
                        submitCompletedResponse()
                    } label: {
                        Text("Done")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .accessibilityIdentifier(accessibilityIdentifiers.done)

                    status(at: context.date)

                    if let message = model.clarificationDeliveryMessages[itemID] {
                        Text(message)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(accessibilityIdentifiers.fallbackMessage)
                    }
                }
            }
            .opacity(isExpired ? 0.68 : 1)
        }
        .accessibilityIdentifier(accessibilityIdentifiers.card(itemID: itemID))
    }

    private var isResolving: Bool {
        model.resolvingAttentionIDs.contains(itemID)
    }

    @ViewBuilder
    private func questionView(
        _ question: DashboardClarificationQuestion,
        questionIndex: Int,
        canRespond: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(question.question)
                .bighelpFont(.label)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier(accessibilityIdentifiers.question(questionIndex))

            if let locked = question.lockedAnswer {
                Label(locked, systemImage: "lock.fill")
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .accessibilityLabel("Locked answer: \(locked)")
            } else {
                ForEach(Array(question.choices.enumerated()), id: \.offset) { choiceIndex, choice in
                    let selected = draft.selectedIndices(questionIndex: questionIndex).contains(choiceIndex)
                    BighelpPillControl(
                        isSelected: selected,
                        isEnabled: canRespond && !isResolving
                    ) {
                        choose(
                            question: question,
                            questionIndex: questionIndex,
                            choiceIndex: choiceIndex
                        )
                    } label: {
                        HStack(spacing: BighelpTokens.space8) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .accessibilityHidden(true)
                            Text(choice)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityIdentifier(
                        accessibilityIdentifiers.choice(
                            questionIndex: questionIndex,
                            choiceIndex: choiceIndex
                        )
                    )
                }
            }
        }
    }

    private var shapes: [ClarificationAnswers.Question] { request.questions.map(\.answerShape) }

    /// One field for the whole card. On a single question it replaces the
    /// picked choice; on several it answers each one without a choice.
    private func ownWordsField(canRespond: Bool) -> some View {
        TextField(
            request.questions.count > 1 ? "Or answer in your own words" : "Type another response",
            text: Binding(
                get: { draft.customResponse },
                set: { value in
                    draft.customResponse = value
                    if request.questions.count == 1, !value.isEmpty {
                        draft.setSelectedIndices([], questionIndex: 0)
                        draft.selectedChoices = []
                    }
                }
            ),
            axis: .vertical
        )
        .lineLimit(1...4)
        .bighelpFont(.body)
        .disabled(!canRespond || isResolving)
        .submitLabel(.done)
        .onSubmit { submitCompletedResponse() }
        .accessibilityIdentifier(accessibilityIdentifiers.customResponse)
        .bighelpSurface(.composer)
    }

    private func choose(
        question: DashboardClarificationQuestion,
        questionIndex: Int,
        choiceIndex: Int
    ) {
        guard question.choices.indices.contains(choiceIndex) else { return }
        var selected = draft.selectedIndices(questionIndex: questionIndex)
        if question.isMultiSelect {
            if selected.contains(choiceIndex) { selected.remove(choiceIndex) }
            else { selected.insert(choiceIndex) }
        } else {
            selected = [choiceIndex]
        }
        if request.questions.count == 1 { draft.customResponse = "" }
        draft.setSelectedIndices(selected, questionIndex: questionIndex)
        if questionIndex == 0 {
            draft.selectedChoices = Set(selected.compactMap { index in
                question.choices.indices.contains(index) ? question.choices[index] : nil
            })
        }

        guard let response = completedResponse(), !requiresExplicitDone() else { return }
        submit(response)
    }

    private func completedResponse() -> DashboardClarificationResponse? {
        let selections = Dictionary(uniqueKeysWithValues: request.questions.indices.map {
            ($0, draft.selectedIndices(questionIndex: $0))
        })
        guard let values = ClarificationAnswers.answers(for: shapes, selections: selections,
                                                        ownWords: draft.customResponse) else { return nil }
        let response = DashboardClarificationResponse(answers: zip(request.questions, values).map {
            DashboardClarificationAnswer(questionID: $0.id, value: $1)
        })
        return request.accepts(response) ? response : nil
    }

    private func requiresExplicitDone() -> Bool {
        ClarificationAnswers.needsDone(shapes, ownWords: draft.customResponse)
    }

    private func submitCompletedResponse() {
        guard let response = completedResponse() else { return }
        submit(response)
    }

    private func submit(_ response: DashboardClarificationResponse) {
        guard !isResolving else { return }
        Task { await model.respondToClarification(itemID: itemID, response: response) }
    }

    @ViewBuilder
    private func status(at date: Date) -> some View {
        if request.isExpired(at: date) {
            Label("Expired · no response was sent", systemImage: "clock.badge.xmark")
                .foregroundStyle(theme.tertiaryText)
                .accessibilityIdentifier(accessibilityIdentifiers.expired)
        } else if isResolving {
            HStack(spacing: BighelpTokens.space8) {
                BighelpThinkingOrb(scenario: .working, scale: .inline)
                Text("Sending response…")
            }
        } else if let expiresAt = request.expiresAt {
            Label(Self.remaining(until: expiresAt, from: date), systemImage: "clock")
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier(accessibilityIdentifiers.countdown)
        } else {
            Text("Awaiting your response")
                .foregroundStyle(theme.secondaryText)
        }
    }

    private static func remaining(until expiry: Date, from date: Date) -> String {
        let remaining = max(0, Int(expiry.timeIntervalSince(date)))
        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        if hours > 0 { return "Expires in \(hours)h \(minutes)m" }
        if minutes > 0 { return "Expires in \(minutes)m \(seconds)s" }
        return "Expires in \(seconds)s"
    }

    @BighelpThemeReader private var theme

}

struct DashboardClarificationAccessibilityIdentifiers: Equatable, Sendable {
    let prefix: String

    func card(itemID: String) -> String {
        identifier("card.\(itemID)")
    }

    func choice(_ choice: String) -> String {
        identifier("choice.\(choice)")
    }

    func question(_ index: Int) -> String {
        identifier("question.\(index)")
    }

    func choice(questionIndex: Int, choiceIndex: Int) -> String {
        identifier("question.\(questionIndex).choice.\(choiceIndex)")
    }

    var sendSelected: String { identifier("send-selected") }
    var customResponse: String { identifier("custom-response") }
    var submitCustom: String { identifier("submit-custom") }
    var done: String { identifier("done") }
    var expired: String { identifier("expired") }
    var countdown: String { identifier("countdown") }
    var fallbackMessage: String { identifier("fallback-message") }
    var retryCleanup: String { identifier("retry-cleanup") }

    private func identifier(_ component: String) -> String {
        "\(prefix).clarification.\(component)"
    }
}

enum ClarificationComposerLayout {
    static var inputMinimumHeight: CGFloat { BighelpTokens.hitTarget }

    static func leadingBalanceWidth(trailingControlWidth: CGFloat) -> CGFloat {
        max(0, trailingControlWidth)
    }
}
