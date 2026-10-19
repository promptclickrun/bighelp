import SwiftUI

/// Hermes compacting a chat's context: its earlier messages folded into a summary, the
/// same chat with a lighter memory. Asked for with Advanced › Compact, or done by Hermes
/// on its own when the context fills during a turn. Drives `ChatCompactionRail`.
///
/// Hermes tags any lifecycle line that mentions compression as "compacting", notices included
/// (a helper model's smaller window, "Session compressed 2 times"), and it announces automatic
/// attempts (Preflight, Pre-API, idle, a context engine such as LCM) before it knows whether
/// there is anything to fold. Only a commit sends "compacted". So notices never start the rail,
/// an automatic attempt shows only once it's still running after `showAfter`, and Done shows
/// only when Hermes confirms the work.
struct ChatCompaction: Equatable {
    enum Phase: Equatable {
        /// Hermes announced an automatic attempt; not shown until it's still running after `showAfter`.
        case announced
        case compacting
        case done
    }

    /// One compaction, so a finished one's hold can't clear a newer one.
    let id = UUID()
    var phase: Phase = .compacting
    let startedAt: Date
    /// Advanced › Compact: its receipt ends it, not the turn's next event.
    var isRequested = false
    /// How many messages Hermes said it's compacting, when it says.
    var messages: Int?
    var tokensBefore: Int?
    var tokensAfter: Int?

    var isShown: Bool { phase != .announced }

    /// How long Done stays before the rail goes.
    static let doneHold: Duration = .seconds(2)
    /// An automatic attempt shows after this: a no-op ends sooner, a real summary takes longer.
    static let showAfter: Duration = .seconds(2)
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

    /// Whether a "compacting" status is compaction work rather than a notice about it. Hermes'
    /// warnings and errors carry ⚠ or ❌; the rest name what they report.
    static func isProgress(_ status: String) -> Bool {
        if status.contains("⚠") || status.contains("❌") { return false }
        let lowered = status.lowercased()
        let notices = ["accuracy may degrade", "auto-lowered", "blocked", "compaction complete", "failed",
                       "unavailable", "disabled", "skipped"]
        return !notices.contains { lowered.contains($0) }
    }
}

extension ChatModel {
    /// Advanced › Compact started, or Hermes said more about the compaction running: shown at once.
    func beginCompaction(status: String? = nil) {
        let counts: (messages: Int?, tokens: Int?) = status.map(ChatCompaction.counts(in:)) ?? (nil, nil)
        if var current = compaction, current.phase != .done {
            current.messages = counts.messages ?? current.messages
            current.tokensBefore = counts.tokens ?? current.tokensBefore
            current.phase = .compacting
            compaction = current
            return
        }
        var started = ChatCompaction(startedAt: .now, messages: counts.messages,
                                     tokensBefore: counts.tokens ?? sessionContext?.contextUsed)
        started.isRequested = true
        compaction = started
        expireCompaction(started.id)
    }

    /// Hermes announced an automatic compaction (`status` is its progress line). It shows only if
    /// it's still running after `ChatCompaction.showAfter`, so an attempt with nothing to fold never flashes.
    func announceCompaction(status: String) {
        let counts = ChatCompaction.counts(in: status)
        if var current = compaction, current.phase != .done {
            current.messages = counts.messages ?? current.messages
            current.tokensBefore = counts.tokens ?? current.tokensBefore
            compaction = current
            return
        }
        let announced = ChatCompaction(phase: .announced, startedAt: .now, messages: counts.messages,
                                       tokensBefore: counts.tokens ?? sessionContext?.contextUsed)
        compaction = announced
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ChatCompaction.showAfter)
            guard let self, self.compaction?.id == announced.id, self.compaction?.phase == .announced else { return }
            self.compaction?.phase = .compacting
        }
        expireCompaction(announced.id)
    }

    /// Hermes committed a compaction ("compacted"): Done, even if its start went unseen.
    func confirmCompaction() {
        if compaction == nil || compaction?.phase == .done {
            compaction = ChatCompaction(phase: .compacting, startedAt: .now)
        }
        finishCompaction()
    }

    /// The turn moved on with no commit from Hermes: nothing was folded, so the rail goes without a Done.
    func endUnconfirmedCompaction() {
        guard let current = compaction, current.phase != .done, !current.isRequested else { return }
        compaction = nil
    }

    /// Advanced › Compact's request outlasted its wait: the compaction may carry on, and from
    /// here the turn's events end it, as an automatic one's do.
    func releaseRequestedCompaction() {
        compaction?.isRequested = false
    }

    /// Hermes finished: Done shows what it saved for a moment, then the rail goes. Hermes'
    /// receipt for Compact comes just after its status, so it can refine a Done on show.
    func finishCompaction(tokensBefore: Int? = nil, tokensAfter: Int? = nil) {
        guard var finished = compaction else { return }
        finished.tokensBefore = tokensBefore ?? finished.tokensBefore
        // The chat's usage may not have caught up yet: an unchanged reading isn't what's left.
        let current = sessionContext.map(\.contextUsed).flatMap { used in
            finished.tokensBefore.map { used < $0 } == true ? used : nil
        }
        finished.tokensAfter = tokensAfter ?? finished.tokensAfter ?? current
        guard finished.phase != .done else {
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

    private func expireCompaction(_ id: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ChatCompaction.staleAfter)
            guard let self, self.compaction?.id == id, self.compaction?.phase != .done else { return }
            self.compaction = nil
        }
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
