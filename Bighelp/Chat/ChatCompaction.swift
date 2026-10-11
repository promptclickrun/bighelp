import SwiftUI

/// Hermes compacting a chat's context: its earlier messages folded into a summary, the
/// same chat with a lighter memory. Asked for with This chat › Compact, or done by Hermes
/// on its own when the context fills during a turn. Drives `ChatCompactionRail`.
struct ChatCompaction: Equatable {
    enum Phase: Equatable { case compacting, done }

    /// One compaction, so a finished one's hold can't clear a newer one.
    let id = UUID()
    var phase: Phase = .compacting
    let startedAt: Date
    /// How many messages Hermes said it's compacting, when it says.
    var messages: Int?
    var tokensBefore: Int?
    var tokensAfter: Int?

    /// How long Done stays before the rail goes.
    static let doneHold: Duration = .seconds(2)
    /// A compaction whose end never arrived (a lost connection) stops showing after this.
    static let staleAfter: Duration = .seconds(600)

    /// Hermes' own status while it compacts: "⠋ compressing 48 messages (~41,200 tok)…"
    /// for one asked for, and its lifecycle text for one it starts itself.
    static func counts(in status: String) -> (messages: Int?, tokens: Int?) {
        func number(before suffix: String) -> Int? {
            guard let range = status.range(of: #"[\d,]+(?= "# + suffix + ")", options: .regularExpression) else {
                return nil
            }
            return Int(status[range].replacingOccurrences(of: ",", with: ""))
        }
        let tokens = status.range(of: #"(?<=~)[\d,]+(?= ?tok)"#, options: .regularExpression)
            .flatMap { Int(status[$0].replacingOccurrences(of: ",", with: "")) }
        return (number(before: "messages"), tokens)
    }
}

extension ChatModel {
    /// Hermes started compacting this chat, or said more about the compaction it's running.
    func beginCompaction(status: String? = nil) {
        let counts: (messages: Int?, tokens: Int?) = status.map(ChatCompaction.counts(in:)) ?? (nil, nil)
        if var current = compaction, current.phase == .compacting {
            current.messages = counts.messages ?? current.messages
            current.tokensBefore = counts.tokens ?? current.tokensBefore
            compaction = current
            return
        }
        let started = ChatCompaction(startedAt: .now, messages: counts.messages,
                                     tokensBefore: counts.tokens ?? sessionContext?.contextUsed)
        compaction = started
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ChatCompaction.staleAfter)
            guard let self, self.compaction?.id == started.id, self.compaction?.phase == .compacting else { return }
            self.compaction = nil
        }
    }

    /// Hermes finished: Done shows what it saved for a moment, then the rail goes. Hermes'
    /// receipt for Compact comes just after its status, so it can refine a Done on show.
    func finishCompaction(tokensBefore: Int? = nil, tokensAfter: Int? = nil) {
        guard var finished = compaction else { return }
        finished.tokensBefore = tokensBefore ?? finished.tokensBefore
        finished.tokensAfter = tokensAfter ?? finished.tokensAfter ?? sessionContext?.contextUsed
        guard finished.phase == .compacting else {
            compaction = finished
            return
        }
        finished.phase = .done
        compaction = finished
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ChatCompaction.doneHold)
            guard let self, self.compaction?.id == finished.id else { return }
            self.compaction = nil
        }
    }

    /// Nothing was compacted (too little to fold, or Hermes declined): no Done to show.
    func cancelCompaction() {
        compaction = nil
    }
}

/// The chip above the message box while Hermes compacts the chat: a four-step bar that
/// moves once a second (none with Reduce Motion), then a check with what it saved.
struct ChatCompactionRail: View {
    let compaction: ChatCompaction

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme: BighelpTheme

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: isDone ? "checkmark" : "arrow.down.right.and.arrow.up.left")
                .font(.bighelp(.footnote).weight(.semibold))
                .foregroundStyle(isDone ? theme.success : theme.action)
                .frame(width: 28, height: 28)
                .background(Circle().fill((isDone ? theme.success : theme.action).opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !isDone { steps }
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .bighelpSurface(.capsuleControl)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityIdentifier(isDone ? "chat.compaction.done" : "chat.compaction.running")
    }

    private var isDone: Bool { compaction.phase == .done }

    private var title: String {
        if isDone { return "Compacted" }
        return compaction.messages.map { "Compacting \($0) messages" } ?? "Compacting context"
    }

    private var detail: String {
        let before = compaction.tokensBefore.map(Self.tokens)
        if isDone {
            if let before, let after = compaction.tokensAfter.map(Self.tokens) { return "\(before) → \(after) tokens · same chat" }
            return "Same chat, lighter memory"
        }
        return before.map { "~\($0) tokens into a summary" } ?? "Earlier messages into a summary"
    }

    /// Steps once a second rather than animating continuously; still with Reduce Motion.
    @ViewBuilder
    private var steps: some View {
        if reduceMotion {
            stepBar(lit: 2)
        } else {
            TimelineView(.periodic(from: compaction.startedAt, by: 1)) { context in
                stepBar(lit: Int(context.date.timeIntervalSince(compaction.startedAt)) % 4 + 1)
            }
        }
    }

    private func stepBar(lit: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? theme.action : theme.action.opacity(0.18))
                    .frame(width: 30, height: 3)
            }
        }
        .padding(.top, 3)
        .accessibilityHidden(true)
    }

    private static func tokens(_ count: Int) -> String {
        count >= 1_000 ? "\((Double(count) / 1_000).formatted(.number.precision(.fractionLength(0))))k" : "\(count)"
    }
}
